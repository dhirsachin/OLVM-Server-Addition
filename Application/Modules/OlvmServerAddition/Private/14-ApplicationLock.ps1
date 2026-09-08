function Enter-ApplicationInstanceLock {
    <# One application instance per Windows server for the complete GUI lifetime. #>
    [CmdletBinding()]
    param()

    $mutexSecurity = New-Object System.Security.AccessControl.MutexSecurity
    $authenticatedUsers = New-Object System.Security.Principal.SecurityIdentifier(
        [System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid,
        $null
    )
    $accessRule = New-Object System.Security.AccessControl.MutexAccessRule(
        $authenticatedUsers,
        [System.Security.AccessControl.MutexRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $mutexSecurity.AddAccessRule($accessRule)

    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex(
        $false,
        'Global\OracleCerner.OLVMServerAddition.Application',
        [ref]$createdNew,
        $mutexSecurity
    )
    $owned = $false
    try {
        try {
            $owned = $mutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            $owned = $true
            $script:ApplicationLockWasAbandoned = $true
        }

        $commonData = [Environment]::GetFolderPath(
            [System.Environment+SpecialFolder]::CommonApplicationData
        )
        if (-not [string]::IsNullOrWhiteSpace($commonData)) {
            $lockDirectory = Join-Path (Join-Path $commonData $script:StorageName) 'Locks'
            $script:ApplicationLockMetadataPath = Join-Path $lockDirectory 'Application.json'
        }

        if (-not $owned) {
            $activeMetadata = if ([string]::IsNullOrWhiteSpace($script:ApplicationLockMetadataPath)) {
                $null
            }
            else {
                Read-JsonMetadataFile -Path $script:ApplicationLockMetadataPath
            }
            $ownerText = Format-LockOwnerMessage -Metadata $activeMetadata
            throw "Another OLVM Server Addition instance is already open on this server. $ownerText Close that instance before starting another one."
        }

        $script:ApplicationMutex = $mutex
        $script:ApplicationMutexOwned = $true
        $mutex = $null

        if (-not [string]::IsNullOrWhiteSpace($script:ApplicationLockMetadataPath)) {
            try {
                $lockDirectory = Split-Path -Parent $script:ApplicationLockMetadataPath
                $null = Initialize-SharedLockMetadataDirectory -Path $lockDirectory
                $metadata = [ordered]@{
                    User       = Get-CurrentOperatorName
                    Computer   = [string]$env:COMPUTERNAME
                    StartedUtc = [DateTime]::UtcNow.ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
                    ProcessId  = [int]$PID
                    RunId      = [string]$script:RunId
                    Version    = [string]$script:ToolVersion
                    LogPath    = [string]$script:LogPath
                }
                [System.IO.File]::WriteAllText(
                    $script:ApplicationLockMetadataPath,
                    ($metadata | ConvertTo-Json -Compress),
                    [System.Text.UTF8Encoding]::new($false)
                )
            }
            catch {
                # The mutex is authoritative. Metadata is informational only.
                $script:ApplicationLockMetadataWarning = $_.Exception.Message
            }
        }
    }
    catch {
        if ($null -ne $mutex) { $mutex.Dispose() }
        throw
    }
}

function Update-ApplicationLockMetadata {
    [CmdletBinding()]
    param()

    if (-not $script:ApplicationMutexOwned -or
        [string]::IsNullOrWhiteSpace($script:ApplicationLockMetadataPath)) {
        return
    }
    try {
        $existing = Read-JsonMetadataFile -Path $script:ApplicationLockMetadataPath
        $startedProperty = if ($null -eq $existing) { $null } else { $existing.PSObject.Properties['StartedUtc'] }
        $metadata = [ordered]@{
            User       = Get-CurrentOperatorName
            Computer   = [string]$env:COMPUTERNAME
            StartedUtc = if ($null -ne $startedProperty -and
                -not [string]::IsNullOrWhiteSpace([string]$startedProperty.Value)) {
                [string]$startedProperty.Value
            }
            else { [DateTime]::UtcNow.ToString('o') }
            ProcessId  = [int]$PID
            RunId      = [string]$script:RunId
            Version    = [string]$script:ToolVersion
            LogPath    = [string]$script:LogPath
        }
        [System.IO.File]::WriteAllText(
            $script:ApplicationLockMetadataPath,
            ($metadata | ConvertTo-Json -Compress),
            [System.Text.UTF8Encoding]::new($false)
        )
    }
    catch {}
}

function Exit-ApplicationInstanceLock {
    [CmdletBinding()]
    param()

    if ($script:ApplicationMutexOwned -and
        -not [string]::IsNullOrWhiteSpace($script:ApplicationLockMetadataPath)) {
        try {
            $metadata = Read-JsonMetadataFile -Path $script:ApplicationLockMetadataPath
            $runIdProperty = if ($null -eq $metadata) { $null } else { $metadata.PSObject.Properties['RunId'] }
            if ($null -eq $metadata -or
                ($null -ne $runIdProperty -and [string]$runIdProperty.Value -eq [string]$script:RunId)) {
                [System.IO.File]::Delete($script:ApplicationLockMetadataPath)
            }
        }
        catch {}
    }
    if ($script:ApplicationMutexOwned -and $null -ne $script:ApplicationMutex) {
        try { $script:ApplicationMutex.ReleaseMutex() } catch {}
    }
    if ($null -ne $script:ApplicationMutex) {
        try { $script:ApplicationMutex.Dispose() } catch {}
    }
    $script:ApplicationMutex = $null
    $script:ApplicationMutexOwned = $false
}
