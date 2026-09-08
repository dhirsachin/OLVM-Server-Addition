function Get-FarmBuildLockLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$FarmServers)

    $normalizedServers = @($FarmServers |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() } |
        Sort-Object -Unique)
    if ($normalizedServers.Count -eq 0) {
        throw 'The farm Build lock cannot be located because PVS returned no farm servers.'
    }
    $coordinator = [string]$normalizedServers[0]
    if ($coordinator -ieq [string]$env:COMPUTERNAME -or
        $coordinator.Split('.')[0] -ieq [string]$env:COMPUTERNAME) {
        $commonData = [Environment]::GetFolderPath(
            [System.Environment+SpecialFolder]::CommonApplicationData
        )
        $root = Join-Path (Join-Path $commonData $script:StorageName) 'FarmLocks'
    }
    else {
        $root = "\\$coordinator\C$\ProgramData\$($script:StorageName)\FarmLocks"
    }
    if ([string]::IsNullOrWhiteSpace($root)) {
        throw 'The farm Build lock root is empty.'
    }
    return [pscustomobject]@{
        Coordinator = $coordinator
        Root        = $root
        Path        = Join-Path $root 'Build.lock'
        FarmServers = [string[]]$normalizedServers
    }
}

function Read-FarmBuildLockMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $reader = $null
    try {
        if (-not [System.IO.File]::Exists($Path)) { return $null }
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch { return $null }
    finally {
        if ($null -ne $reader) { try { $reader.Dispose() } catch {} }
        elseif ($null -ne $stream) { try { $stream.Dispose() } catch {} }
    }
}

function Enter-FarmBuildLock {
    <#
      Holds one farm-visible file handle from before confirmation through the
      last optional power operation. A stale file is recoverable only after an
      explicit audited operator decision; file age is never used as proof.
    #>
    [CmdletBinding()]
    param()

    Assert-AuditTrailAvailable
    $farmServers = @(Get-DhcpServerNames)
    $location = Get-FarmBuildLockLocation -FarmServers $farmServers
    try {
        [void][System.IO.Directory]::CreateDirectory([string]$location.Root)
    }
    catch {
        throw "The farm-wide Build lock directory '$($location.Root)' could not be created or reached. Build is blocked; Validation remains read-only. $($_.Exception.Message)"
    }

    $stream = $null
    $createdNew = $false
    try {
        try {
            $stream = New-Object System.IO.FileStream(
                $location.Path,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::Read
            )
            $createdNew = $true
        }
        catch {
            $createError = $_.Exception.Message
            if (-not [System.IO.File]::Exists($location.Path)) {
                throw "The farm-wide Build lock '$($location.Path)' could not be created. Build is blocked. $createError"
            }
            $activeMetadata = Read-FarmBuildLockMetadata -Path $location.Path
            try {
                $stream = New-Object System.IO.FileStream(
                    $location.Path,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::ReadWrite,
                    [System.IO.FileShare]::Read
                )
            }
            catch {
                $openError = $_.Exception.Message
                $ownerText = Format-LockOwnerMessage -Metadata $activeMetadata -Fallback 'The active owner metadata could not be read.'
                throw "Another Build currently owns the PVS farm lock on '$($location.Coordinator)'. $ownerText Build cannot continue until that run releases the lock. Lock errors: create='$createError'; exclusive-open='$openError'"
            }
        }

        if (-not $createdNew) {
            $staleText = Format-LockOwnerMessage -Metadata $activeMetadata -Fallback 'Previous owner details are unavailable, or the stale file is empty.'
            Invoke-PresentationPort -Name 'SuspendExecutionClock'
            try {
                $recoveryChoice = Invoke-PresentationPort -Name 'StaleFarmLockRecovery' -Arguments @{ OwnerText = $staleText }
            }
            finally {
                Invoke-PresentationPort -Name 'ResumeExecutionClock'
            }
            if ($recoveryChoice -ne 'Yes') {
                Write-RunLog -Level WARN -Stage 'Farm lock' -Message "Operator declined stale-lock recovery on '$($location.Path)'. $staleText"
                throw 'Build was cancelled because stale farm-lock recovery was not approved.'
            }
            Write-RunLog -Level WARN -Stage 'Farm lock' -Message "Operator explicitly approved recovery of the unheld stale lock on '$($location.Path)'. Previous metadata: $staleText"
        }

        $metadata = [ordered]@{
            User          = Get-CurrentOperatorName
            Computer      = [string]$env:COMPUTERNAME
            StartedUtc    = [DateTime]::UtcNow.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
            ProcessId     = [int]$PID
            RunId         = [string]$script:RunId
            Version       = [string]$script:ToolVersion
            Coordinator   = [string]$location.Coordinator
            FarmServers   = [string[]]$location.FarmServers
            LogPath       = [string]$script:LogPath
        }
        $json = $metadata | ConvertTo-Json -Compress
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream.Position = 0
        $stream.SetLength(0)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        Write-RunLog -Level SUCCESS -Stage 'Farm lock' -Message "Acquired the farm-wide Build lock on coordinator '$($location.Coordinator)' at '$($location.Path)' for $($farmServers.Count) PVS server(s)."

        $lock = [pscustomobject]@{
            Stream      = $stream
            Path        = [string]$location.Path
            Coordinator = [string]$location.Coordinator
            Metadata    = [pscustomobject]$metadata
        }
        $script:ActiveFarmBuildLock = $lock
        $stream = $null
        return $lock
    }
    catch {
        if ($null -ne $stream) { try { $stream.Dispose() } catch {} }
        throw
    }
}

function Exit-FarmBuildLock {
    [CmdletBinding()]
    param([AllowNull()][psobject]$Lock = $script:ActiveFarmBuildLock)

    if ($null -eq $Lock) { return }
    $path = [string]$Lock.Path
    $released = $false
    try {
        if ($null -ne $Lock.Stream) {
            try { $Lock.Stream.Flush($true) } catch {
                Write-RecoveryLog -Level WARN -Stage 'Farm lock' -Message "The farm lock metadata flush failed immediately before release of '$path': $($_.Exception.Message)"
            }
            try {
                $Lock.Stream.Dispose()
            }
            catch {
                throw "The farm-wide Build lock handle '$path' could not be confirmed closed. The application will keep the lock state active and will not offer Start New Build. Close the application before another Build is attempted. $($_.Exception.Message)"
            }
        }
        $released = $true
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            try { [System.IO.File]::Delete($path) } catch {
                Write-RecoveryLog -Level WARN -Stage 'Farm lock' -Message "The farm lock handle was released, but stale metadata file '$path' could not be deleted. The next operator must use the audited stale-lock recovery prompt. $($_.Exception.Message)"
            }
        }
        Write-RecoveryLog -Level SUCCESS -Stage 'Farm lock' -Message "Released the farm-wide Build lock '$path'."
    }
    finally {
        if ($released) {
            $script:ActiveFarmBuildLock = $null
        }
    }
}
