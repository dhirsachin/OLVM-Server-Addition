function Format-ElapsedTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Elapsed
    )

    $totalHours = [math]::Floor($Elapsed.TotalHours)
    return '{0:00}:{1:00}:{2:00}' -f $totalHours,$Elapsed.Minutes,$Elapsed.Seconds
}

function Write-StageTiming {
    <# Timing must never hide the infrastructure error being measured. The
       helper therefore records through the normal audit boundary but catches
       its own failures and only marks the audit trail unhealthy. #>
    [CmdletBinding()]
    param(
        [object]$Timer,
        [string]$Phase,
        [string]$Operation,
        [string]$Outcome,
        [string]$MachineName = '-',
        [string]$Endpoint = '-',
        [string]$Source = 'Live'
    )

    try {
        if ($Timer -isnot [System.Diagnostics.Stopwatch]) {
            throw 'A valid timing stopwatch is required.'
        }
        if ($Timer.IsRunning) {
            $Timer.Stop()
        }
        $safeEndpoint = Protect-LogField -Value ([string]$Endpoint) -MaximumLength 128
        $level = if ([string]$Outcome -in @('Succeeded','Complete','Finished','SkippedExisting')) {
            'SUCCESS'
        }
        else {
            'WARN'
        }
        Write-RunLog `
            -Level $level `
            -Stage 'Timing' `
            -MachineName ([string]$MachineName) `
            -Message ('Phase={0}; Operation={1}; Outcome={2}; DurationMs={3}; Endpoint={4}; Source={5}' -f
                $Phase,$Operation,$Outcome,$Timer.ElapsedMilliseconds,$safeEndpoint,$Source)
    }
    catch {
        $script:AuditTrailHealthy = $false
    }
}

function Invoke-TimedOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [string]$MachineName = '-',

        [string]$Endpoint = '-',

        [string]$Source = 'Live',

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = 'Failed'
    try {
        $result = & $Action
        $outcome = 'Succeeded'
        return $result
    }
    finally {
        Write-StageTiming `
            -Timer $timer `
            -Phase $Phase `
            -Operation $Operation `
            -Outcome $outcome `
            -MachineName $MachineName `
            -Endpoint $Endpoint `
            -Source $Source
    }
}
function Write-StartupLaunchTiming {
    <#
      Emits one bounded, non-sensitive launch timeline after the splash is
      rendered. Cross-process VBS/CMD durations use local wall-clock markers;
      all PowerShell-process durations use the monotonic Stopwatch clock.
      Missing or malformed optional markers are reported as NA and never block
      application startup.
    #>
    [CmdletBinding()]
    param(
        [long]$SplashTimestamp = 0
    )

    $markerNames = [string[]]@(
        'OLVM_SERVER_ADDITION_STARTUP_PROTOCOL',
        'OLVM_SERVER_ADDITION_STARTUP_ENTRY',
        'OLVM_SERVER_ADDITION_PACKAGE_LOCATION',
        'OLVM_SERVER_ADDITION_VBS_DAY',
        'OLVM_SERVER_ADDITION_VBS_MS',
        'OLVM_SERVER_ADDITION_CMD_CLOCK',
        'OLVM_SERVER_ADDITION_PS_LOCAL_MS',
        'OLVM_SERVER_ADDITION_PS_STAMP',
        'OLVM_SERVER_ADDITION_PVS_READY_STAMP',
        'OLVM_SERVER_ADDITION_MODULE_START_STAMP',
        'OLVM_SERVER_ADDITION_MODULE_READY_STAMP',
        'OLVM_SERVER_ADDITION_MODULE_LOAD_MODE'
    )
    try {
        $invariant = [System.Globalization.CultureInfo]::InvariantCulture
        $maximumSegmentMilliseconds = [long]1800000
        $millisecondsPerDay = [long]86400000
        $readIntegerMarker = {
            param([string]$Name)

            $rawValue = [Environment]::GetEnvironmentVariable(
                $Name,
                [EnvironmentVariableTarget]::Process
            )
            if ([string]::IsNullOrWhiteSpace($rawValue)) {
                return $null
            }
            $parsedValue = [long]0
            if (-not [long]::TryParse(
                    $rawValue,
                    [System.Globalization.NumberStyles]::Integer,
                    $invariant,
                    [ref]$parsedValue
                )) {
                return $null
            }
            return $parsedValue
        }
        $getDuration = {
            param($Start,$End,[double]$ClockFrequency)

            if ($null -eq $Start -or $null -eq $End -or $ClockFrequency -le 0) {
                return $null
            }
            $duration = [math]::Round(
                (([double]$End - [double]$Start) * 1000.0) / $ClockFrequency
            )
            if ($duration -lt 0 -or
                $duration -gt $maximumSegmentMilliseconds) {
                return $null
            }
            return [long]$duration
        }
        $formatDuration = {
            param($Value)

            if ($null -eq $Value) {
                return 'NA'
            }
            return ([long]$Value).ToString($invariant)
        }

        $protocolValue = [string][Environment]::GetEnvironmentVariable(
            'OLVM_SERVER_ADDITION_STARTUP_PROTOCOL',
            [EnvironmentVariableTarget]::Process
        )
        $hasLauncherProtocol = $protocolValue -ceq '1'
        $vbsDay = if ($hasLauncherProtocol) {
            & $readIntegerMarker 'OLVM_SERVER_ADDITION_VBS_DAY'
        }
        else { $null }
        $vbsMilliseconds = if ($hasLauncherProtocol) {
            & $readIntegerMarker 'OLVM_SERVER_ADDITION_VBS_MS'
        }
        else { $null }
        $powerShellLocalMilliseconds = & $readIntegerMarker 'OLVM_SERVER_ADDITION_PS_LOCAL_MS'
        $powerShellTimestamp = & $readIntegerMarker 'OLVM_SERVER_ADDITION_PS_STAMP'
        $pvsReadyTimestamp = & $readIntegerMarker 'OLVM_SERVER_ADDITION_PVS_READY_STAMP'
        $moduleStartTimestamp = & $readIntegerMarker 'OLVM_SERVER_ADDITION_MODULE_START_STAMP'
        $moduleReadyTimestamp = & $readIntegerMarker 'OLVM_SERVER_ADDITION_MODULE_READY_STAMP'

        $vbsLocalMilliseconds = $null
        if ($null -ne $vbsDay -and $vbsDay -ge 0 -and $vbsDay -le 100000 -and
            $null -ne $vbsMilliseconds -and $vbsMilliseconds -ge 0 -and
            $vbsMilliseconds -lt $millisecondsPerDay) {
            $vbsLocalMilliseconds = ($vbsDay * $millisecondsPerDay) +
                $vbsMilliseconds
        }

        $cmdLocalMilliseconds = $null
        $cmdClockText = if ($hasLauncherProtocol) {
            [string][Environment]::GetEnvironmentVariable(
                'OLVM_SERVER_ADDITION_CMD_CLOCK',
                [EnvironmentVariableTarget]::Process
            )
        }
        else { '' }
        $parsedCmdClock = [TimeSpan]::Zero
        $normalizedCmdClock = $cmdClockText.Trim().Replace(',','.')
        if ($null -ne $powerShellLocalMilliseconds -and
            -not [string]::IsNullOrWhiteSpace($normalizedCmdClock) -and
            [TimeSpan]::TryParse(
                $normalizedCmdClock,
                $invariant,
                [ref]$parsedCmdClock
            ) -and
            $parsedCmdClock.TotalMilliseconds -ge 0 -and
            $parsedCmdClock.TotalMilliseconds -lt $millisecondsPerDay) {
            $powerShellDay = [long][math]::Floor(
                $powerShellLocalMilliseconds / [double]$millisecondsPerDay
            )
            $cmdLocalMilliseconds = ($powerShellDay * $millisecondsPerDay) +
                [long][math]::Floor($parsedCmdClock.TotalMilliseconds)
            # A command timestamp later than PowerShell by more than one minute
            # represents the preceding day when startup crossed midnight.
            if ($cmdLocalMilliseconds -gt
                ($powerShellLocalMilliseconds + 60000)) {
                $cmdLocalMilliseconds -= $millisecondsPerDay
            }
        }

        $vbsToCmd = & $getDuration $vbsLocalMilliseconds $cmdLocalMilliseconds 1000.0
        $cmdToPowerShell = & $getDuration $cmdLocalMilliseconds $powerShellLocalMilliseconds 1000.0
        $stopwatchFrequency = [double][Diagnostics.Stopwatch]::Frequency
        $powerShellToPvsReady = & $getDuration $powerShellTimestamp $pvsReadyTimestamp $stopwatchFrequency
        $pvsReadyToModuleStart = & $getDuration $pvsReadyTimestamp $moduleStartTimestamp $stopwatchFrequency
        $moduleImport = & $getDuration $moduleStartTimestamp $moduleReadyTimestamp $stopwatchFrequency
        $moduleReadyToSplash = & $getDuration $moduleReadyTimestamp $SplashTimestamp $stopwatchFrequency
        $splashToModuleReady = & $getDuration $SplashTimestamp $moduleReadyTimestamp $stopwatchFrequency
        $powerShellToSplash = & $getDuration $powerShellTimestamp $SplashTimestamp $stopwatchFrequency

        $entryRaw = if ($hasLauncherProtocol) {
            [string][Environment]::GetEnvironmentVariable(
                'OLVM_SERVER_ADDITION_STARTUP_ENTRY',
                [EnvironmentVariableTarget]::Process
            )
        }
        else { 'PowerShell' }
        $entry = switch ($entryRaw.ToUpperInvariant()) {
            'VBS' { 'VBS'; break }
            'CMD' { 'CMD'; break }
            'POWERSHELL' { 'PowerShell'; break }
            default { 'PowerShell' }
        }
        $packageLocationRaw = if ($hasLauncherProtocol) {
            [string][Environment]::GetEnvironmentVariable(
                'OLVM_SERVER_ADDITION_PACKAGE_LOCATION',
                [EnvironmentVariableTarget]::Process
            )
        }
        else { '' }
        $packageLocation = switch ($packageLocationRaw.ToUpperInvariant()) {
            'LOCAL' { 'Local'; break }
            'MAPPEDNETWORK' { 'MappedNetwork'; break }
            'UNC' { 'UNC'; break }
            default { 'Unknown' }
        }
        $moduleLoadModeRaw = [string][Environment]::GetEnvironmentVariable(
            'OLVM_SERVER_ADDITION_MODULE_LOAD_MODE',
            [EnvironmentVariableTarget]::Process
        )
        $moduleLoadMode = switch ($moduleLoadModeRaw.ToUpperInvariant()) {
            'IMPORTED' { 'Imported'; break }
            'REUSED' { 'Reused'; break }
            default { 'Unknown' }
        }

        $entryToSplash = $null
        if ($entry -eq 'VBS' -and
            $null -ne $vbsToCmd -and
            $null -ne $cmdToPowerShell -and
            $null -ne $powerShellToSplash) {
            $entryToSplash = $vbsToCmd + $cmdToPowerShell +
                $powerShellToSplash
        }
        elseif ($entry -eq 'CMD' -and
            $null -ne $cmdToPowerShell -and
            $null -ne $powerShellToSplash) {
            $entryToSplash = $cmdToPowerShell + $powerShellToSplash
        }
        elseif ($entry -eq 'PowerShell' -and
            $null -ne $powerShellToSplash) {
            $entryToSplash = $powerShellToSplash
        }
        if ($null -ne $entryToSplash -and
            $entryToSplash -gt $maximumSegmentMilliseconds) {
            $entryToSplash = $null
        }

        $message = 'Protocol=1; Entry={0}; PackageLocation={1}; VbsToCmdMs={2}; CmdToPowerShellMs={3}; PowerShellToPvsReadyMs={4}; PvsReadyToModuleStartMs={5}; ModuleImportMs={6}; ModuleReadyToSplashDisplayedMs={7}; SplashDisplayedToModuleReadyMs={8}; EntryToSplashDisplayedMs={9}; ModuleLoadMode={10}; Clock=LauncherWallAndProcessMonotonic' -f
            $entry,
            $packageLocation,
            (& $formatDuration $vbsToCmd),
            (& $formatDuration $cmdToPowerShell),
            (& $formatDuration $powerShellToPvsReady),
            (& $formatDuration $pvsReadyToModuleStart),
            (& $formatDuration $moduleImport),
            (& $formatDuration $moduleReadyToSplash),
            (& $formatDuration $splashToModuleReady),
            (& $formatDuration $entryToSplash),
            $moduleLoadMode
        Write-RunLog -Level INFO -Stage 'Startup timing' -Message $message
    }
    catch {
        # Startup timing is diagnostic-only. The primary audit writer retains
        # its own fail-closed behavior; malformed optional markers do not.
    }
    finally {
        foreach ($markerName in $markerNames) {
            [Environment]::SetEnvironmentVariable(
                $markerName,
                $null,
                [EnvironmentVariableTarget]::Process
            )
        }
    }
}
