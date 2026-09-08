function Initialize-SecureAuditDirectory {
    <#
      A new log directory receives a protected ACL. An existing directory is
      never silently re-permissioned; it is accepted only when its owner and
      every write-capable ACE are limited to the approved local principals.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "The audit directory must be an absolute local path. Received '$Path'."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath -notmatch '^[A-Za-z]:\\') {
        throw "The audit directory must use a fully qualified local Windows drive path. Received '$fullPath'."
    }
    $windowsIdentity = $null
    try {
        $windowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $currentSid = $windowsIdentity.User
    }
    finally {
        if ($null -ne $windowsIdentity) { $windowsIdentity.Dispose() }
    }
    if ($null -eq $currentSid) {
        throw 'The current Windows security identifier could not be determined for the audit-directory ACL.'
    }

    $systemSid = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-18'
    $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-544'
    $approvedWriteSids = @(
        [string]$systemSid.Value,
        [string]$administratorsSid.Value,
        [string]$currentSid.Value
    )

    $created = -not [System.IO.Directory]::Exists($fullPath)
    if ($created) {
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true,$false)
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        foreach ($sid in @(
                $systemSid,
                $administratorsSid,
                $currentSid
            )) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow
            )
            [void]$security.AddAccessRule($rule)
        }
        # Apply the protected DACL in the same framework call that creates the
        # directory; there is no inherited-permission window between steps.
        $directory = [System.IO.Directory]::CreateDirectory($fullPath,$security)
    }
    else {
        $directory = [System.IO.Directory]::CreateDirectory($fullPath)
    }
    if (-not $directory.Exists) {
        throw "Audit directory '$fullPath' could not be created or opened."
    }

    Assert-PathHasNoReparsePoint -Path $directory.FullName -BoundaryDescription 'The audit directory'

    $directorySecurity = $directory.GetAccessControl(
        [System.Security.AccessControl.AccessControlSections]::Access -bor
        [System.Security.AccessControl.AccessControlSections]::Owner
    )
    $ownerSid = $directorySecurity.GetOwner(
        [System.Security.Principal.SecurityIdentifier]
    ).Value
    if ($approvedWriteSids -notcontains $ownerSid) {
        throw "Audit directory '$fullPath' is owned by unapproved SID '$ownerSid'. Set the owner to SYSTEM, local Administrators, or the executing account before running this production tool."
    }
    $dangerousRights = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
        [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
    # Log integrity depends on every write-capable ACE, not only well-known
    # broad groups. An attacker-specific SID must not be able to alter or delete
    # this run's audit record either.
    $unsafeRules = @($directorySecurity.GetAccessRules(
            $true,
            $true,
            [System.Security.Principal.SecurityIdentifier]
        ) | Where-Object {
            $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
            $approvedWriteSids -notcontains $_.IdentityReference.Value -and
            ($_.FileSystemRights -band $dangerousRights) -ne 0
        })
    if ($unsafeRules.Count -gt 0) {
        $ruleSummary = @($unsafeRules | ForEach-Object {
                "$($_.IdentityReference.Value)=$($_.FileSystemRights)"
            }) -join '; '
        throw "Audit directory '$fullPath' grants write-capable access to an unapproved principal ($ruleSummary). Secure the directory so only SYSTEM, local Administrators, and the executing account can modify logs."
    }

    return [pscustomobject]@{
        Directory = $directory
        Created   = $created
        Owner     = [string]$ownerSid
    }
}

function Initialize-RunLog {
    [CmdletBinding()]
    param()

    # Store every run under the current Windows profile. The tool-specific
    # directory still receives the protected owner, ACL, local-path, and
    # reparse-point validation required for the production audit trail.
    $localAppData = [Environment]::GetFolderPath(
        [System.Environment+SpecialFolder]::LocalApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'Windows did not return a Local Application Data path for the audit log.'
    }
    $auditRoot = Join-Path (Join-Path $localAppData $script:StorageName) 'Logs'
    $stream = $null
    try {
        $auditDirectory = Initialize-SecureAuditDirectory -Path $auditRoot
        # Seven fractional-second digits keep the timestamp-only filename
        # unique in normal use. CreateNew below still guarantees no overwrite.
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fffffff'
        $fileName = 'OLVM Server Addition - {0}.log' -f $timestamp
        $script:LogPath = Join-Path $auditRoot $fileName

        # CreateNew guarantees that an existing log can never be overwritten.
        $stream = New-Object System.IO.FileStream(
            $script:LogPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
        if (([System.IO.File]::GetAttributes($script:LogPath) -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The newly created run log '$script:LogPath' is a reparse point."
        }
        $script:LogWriter = New-Object System.IO.StreamWriter(
            $stream,
            [System.Text.UTF8Encoding]::new($true)
        )
        $script:LogWriter.AutoFlush = $true

        # Persist and flush the header before declaring the audit trail healthy.
        $header = $script:LogLineFormat -f 'Timestamp','Level','Stage','VDA server','Message'
        $script:LogWriter.WriteLine($header)
        $script:LogWriter.WriteLine(('=' * [math]::Max(140,$header.Length)))
        $script:LogWriter.WriteLine(($script:LogLineFormat -f
                (Get-Date).ToString('dd-MM-yyyy HH:mm:ss',[System.Globalization.CultureInfo]::InvariantCulture),
                'SUCCESS',
                'Audit boundary',
                '-',
                "Secure per-user audit directory validated. Created=$($auditDirectory.Created); Owner=$($auditDirectory.Owner); ReparsePoints=False; UnapprovedWriteRules=False."))
    }
    catch {
        if ($null -ne $script:LogWriter) {
            try { $script:LogWriter.Dispose() } catch {}
            $script:LogWriter = $null
        }
        elseif ($null -ne $stream) {
            try { $stream.Dispose() } catch {}
        }
        throw "A unique run log could not be created under '$auditRoot'. The tool will not start because production actions require an audit trail. $($_.Exception.Message)"
    }
}

function Protect-LogValue {
    <#
      Creates a bounded, single-record scalar that is safe to retain in
      diagnostics. Secret removal deliberately happens before truncation so a
      long credential cannot leave a visible prefix in the retained value.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [ValidateRange(32, 1048576)]
        [int]$MaximumLength = 8192,

        [AllowEmptyString()]
        [string]$EmptyValue = ''
    )

    if ($null -eq $Value) {
        return $EmptyValue
    }

    $protectedValue = ($Value -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+',' ').Trim()
    if ([string]::IsNullOrWhiteSpace($protectedValue)) {
        return $EmptyValue
    }

    # URI user information may itself contain '@'. Greedy authority matching
    # therefore removes everything through the final '@' before host/path.
    $protectedValue = $protectedValue -replace '(?i)(https?://)[^/\s]+@','$1<redacted>:<redacted>@'

    # Header values are removed as a unit. For cookie diagnostics, retain only
    # an explicitly separate troubleshooting field such as request or host.
    $protectedValue = $protectedValue -replace '(?is)["'']?authorization["'']?\s*[:=]\s*(?:"(?:bearer|basic)\s+[^"]*"|''(?:bearer|basic)\s+[^'']*''|(?:bearer|basic)\s+[^\s,;|]+)','authorization=<redacted>'
    $protectedValue = $protectedValue -replace '(?is)\b(set-cookie|cookie)\s*:\s*.*?(?=\s+\b(?:request|host|server|status|operation|stage|attempt|manager|machine|vm|endpoint)\s*[:=]|[|]|$)','cookie=<redacted>'

    # PowerShell-style command arguments can carry quoted, multiword values.
    # Stop at the next named parameter so useful command context is retained.
    $protectedValue = $protectedValue -replace '(?is)(-(?:password|credential|securepassword|token|accesstoken|secret|apikey|clientsecret)\b(?:\s+|[:=]\s*))(?:"[^"]*"|''[^'']*''|.*?)(?=\s+-[A-Za-z][A-Za-z0-9-]*\b|$)','$1<redacted>'

    # Remove JSON, query-string, and key=value secrets. The unquoted branch is
    # intentionally lazy and ends at the next field/parameter delimiter, which
    # covers whitespace-bearing exception text without discarding safe context.
    $secretKeyPattern = 'password|passwd|pwd|token|access[-_]?token|refresh[-_]?token|id[-_]?token|secret|authorization|api[-_]?key|client[-_]?secret|session(?:[-_]?id)?|cookie|credential'
    $assignmentPattern = '(?is)(["'']?(?:' + $secretKeyPattern + ')["'']?\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|.*?)(?=\s+[A-Za-z][A-Za-z0-9_.-]*\s*[:=]|\s+-[A-Za-z][A-Za-z0-9-]*\b|[,;|&}]|$)'
    $protectedValue = $protectedValue -replace $assignmentPattern,'$1<redacted>'

    $protectedValue = (($protectedValue -replace '\|',' ') -replace '\s{2,}',' ').Trim()
    if ([string]::IsNullOrWhiteSpace($protectedValue)) {
        return $EmptyValue
    }
    if ($protectedValue.Length -gt $MaximumLength) {
        return $protectedValue.Substring(0, $MaximumLength - 16) + ' ... [truncated]'
    }
    return $protectedValue
}

function Protect-LogField {
    <# Prevents secret and record injection in bounded diagnostic identifiers. #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [ValidateRange(32, 1024)]
        [int]$MaximumLength = 128
    )

    return Protect-LogValue -Value $Value -MaximumLength $MaximumLength -EmptyValue '-'
}

function Protect-LogMessage {
    <# Removes secrets and record-separator controls before persistent logging. #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Message
    )

    return Protect-LogValue `
        -Value $Message `
        -MaximumLength $script:MaximumLogMessageCharacters `
        -EmptyValue ''
}

function New-DiagnosticRecord {
    <# Creates a safe, serialization-friendly diagnostic data-transfer object. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level,
        [Parameter(Mandatory)][string]$Stage,
        [string]$MachineName = '-',
        [Parameter(Mandatory)][string]$Message,
        [string]$Component = '',
        [string]$Operation = '',
        [string]$Endpoint = '',
        [AllowNull()]$Attempt,
        [string]$ExceptionType = '',
        [string]$FullyQualifiedErrorId = '',
        [string]$Disposition = '',
        [string]$Phase = '',
        [string]$TerminalDisposition = ''
    )

    return [pscustomobject][ordered]@{
        Timestamp             = [DateTime]::Now
        Level                 = [string]$Level
        Stage                 = Protect-LogValue -Value $Stage -MaximumLength 1024
        MachineName           = Protect-LogField -Value $MachineName
        Message               = Protect-LogMessage -Message $Message
        Component             = Protect-LogValue -Value $Component -MaximumLength 1024
        Operation             = Protect-LogValue -Value $Operation -MaximumLength 1024
        Endpoint              = Protect-LogValue -Value $Endpoint -MaximumLength 1024
        Attempt               = if ($null -eq $Attempt) { '' } else { [string]$Attempt }
        ExceptionType         = Protect-LogValue -Value $ExceptionType -MaximumLength 1024
        FullyQualifiedErrorId = Protect-LogValue -Value $FullyQualifiedErrorId -MaximumLength 1024
        Disposition           = Protect-LogValue -Value $Disposition -MaximumLength 1024
        Phase                 = Protect-LogValue -Value $Phase -MaximumLength 1024
        TerminalDisposition   = Protect-LogValue -Value $TerminalDisposition -MaximumLength 1024
    }
}

function Write-DiagnosticRecord {
    <# Renders a structured record through the established five-column audit. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$DiagnosticRecord
    )

    if ($null -eq $script:LogWriter) {
        throw 'The run log is unavailable. No production operation is permitted without logging.'
    }

    try {
        $timestampValue = if ($DiagnosticRecord.Timestamp -is [DateTime]) {
            [DateTime]$DiagnosticRecord.Timestamp
        }
        else {
            [DateTime]::Now
        }
        $timestamp = $timestampValue.ToString(
            'dd-MM-yyyy HH:mm:ss',
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $safeStage = Protect-LogValue -Value ([string]$DiagnosticRecord.Stage) -MaximumLength 1024
        $safeMachineName = Protect-LogField -Value ([string]$DiagnosticRecord.MachineName)
        $safeMessage = Protect-LogMessage -Message ([string]$DiagnosticRecord.Message)
        $line = $script:LogLineFormat -f $timestamp,$DiagnosticRecord.Level,$safeStage,$safeMachineName,$safeMessage
    }
    catch {
        try { $_.Exception.Data['DiagnosticWritePhase'] = 'Preparation' } catch {}
        throw
    }

    try {
        $script:LogWriter.WriteLine($line)
    }
    catch {
        try { $_.Exception.Data['DiagnosticWritePhase'] = 'Write' } catch {}
        throw
    }
}

function Write-RunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level,
        [Parameter(Mandatory)][string]$Stage,
        [string]$MachineName = '-',
        [Parameter(Mandatory)][string]$Message
    )

    if ($null -eq $script:LogWriter) {
        throw 'The run log is unavailable. No production operation is permitted without logging.'
    }

    try {
        $diagnosticRecord = New-DiagnosticRecord `
            -Level $Level `
            -Stage $Stage `
            -MachineName $MachineName `
            -Message $Message
        Write-DiagnosticRecord -DiagnosticRecord $diagnosticRecord
    }
    catch {
        $script:AuditTrailHealthy = $false
        if ([string]$_.Exception.Data['DiagnosticWritePhase'] -cne 'Write') {
            throw "Preparing a safe run-log entry failed. No further production operation is permitted. $($_.Exception.Message)"
        }
        throw "Writing to the run log failed. No further production operation is permitted. $($_.Exception.Message)"
    }
}

function Write-ExceptionLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$MachineName = '-'
    )

    $details = $ErrorRecord.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($ErrorRecord.ScriptStackTrace)) {
        $details = "$details | Stack: $($ErrorRecord.ScriptStackTrace)"
    }
    Write-RunLog -Level ERROR -Stage $Stage -MachineName $MachineName -Message $details
}

function Reset-RecoveryLogFallbackState {
    <# Starts a fresh process-local recovery transcript for one audit session. #>
    [CmdletBinding()]
    param()

    try {
        $script:RecoveryLogFallbackState = [pscustomobject][ordered]@{
            MaximumRecords  = [int]128
            Records         = New-Object 'System.Collections.Generic.List[object]'
            DroppedCount    = [long]0
            FirstWriterError = ''
        }
    }
    catch {
        # The recovery path is best-effort and must never prevent cleanup or
        # alter the already-determined result for a server row.
        $script:RecoveryLogFallbackState = $null
    }
}

function Add-RecoveryLogFallbackRecord {
    <# Retains one sanitized recovery event without throwing or writing again. #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Level,
        [AllowNull()][string]$Stage,
        [AllowNull()][string]$MachineName,
        [AllowNull()][string]$Message,
        [AllowNull()][string]$WriterError
    )

    try {
        if ($null -eq $script:RecoveryLogFallbackState) {
            Reset-RecoveryLogFallbackState
        }
        $state = $script:RecoveryLogFallbackState
        if ($null -eq $state) { return }

        if ([string]::IsNullOrWhiteSpace([string]$state.FirstWriterError)) {
            try {
                $safeWriterError = Protect-LogValue `
                    -Value $WriterError `
                    -MaximumLength 2048 `
                    -EmptyValue 'The primary audit writer failed without an available error message.'
            }
            catch {
                $safeWriterError = 'The primary audit writer failed; its technical detail could not be retained safely.'
            }
            $state.FirstWriterError = [string]$safeWriterError
        }

        $safeLevel = if ($Level -in @('INFO','WARN','ERROR','SUCCESS')) {
            [string]$Level
        }
        else {
            'ERROR'
        }
        try {
            $record = New-DiagnosticRecord `
                -Level $safeLevel `
                -Stage ([string]$Stage) `
                -MachineName ([string]$MachineName) `
                -Message ([string]$Message) `
                -Component 'Audit' `
                -Operation 'Recovery fallback' `
                -Disposition 'RetainedInMemory'
        }
        catch {
            $record = [pscustomobject][ordered]@{
                Timestamp             = [DateTime]::Now
                Level                 = 'ERROR'
                Stage                 = 'Recovery fallback'
                MachineName           = '-'
                Message               = 'A recovery event could not be formatted safely.'
                Component             = 'Audit'
                Operation             = 'Recovery fallback'
                Endpoint              = ''
                Attempt               = ''
                ExceptionType         = ''
                FullyQualifiedErrorId = ''
                Disposition           = 'RetainedInMemory'
                Phase                 = ''
                TerminalDisposition   = ''
            }
        }

        if ($state.Records.Count -ge [int]$state.MaximumRecords) {
            $state.Records.RemoveAt(0)
            $state.DroppedCount = [long]$state.DroppedCount + 1
        }
        [void]$state.Records.Add($record)
    }
    catch {
        # Do not allow diagnostic memory pressure or formatting trouble to
        # interrupt ownership-checked cleanup or change a workflow decision.
        return
    }
}

function Get-RecoveryLogFallbackSnapshot {
    <# Returns scalar/copy-only state suitable for later operator presentation. #>
    [CmdletBinding()]
    param()

    try {
        $state = $script:RecoveryLogFallbackState
        if ($null -eq $state) {
            return [pscustomobject][ordered]@{
                Records          = [object[]]@()
                DroppedCount     = [long]0
                FirstWriterError = ''
                MaximumRecords   = [int]128
            }
        }
        return [pscustomobject][ordered]@{
            Records          = [object[]]$state.Records.ToArray()
            DroppedCount     = [long]$state.DroppedCount
            FirstWriterError = [string]$state.FirstWriterError
            MaximumRecords   = [int]$state.MaximumRecords
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Records          = [object[]]@()
            DroppedCount     = [long]0
            FirstWriterError = 'Recovery-log fallback state could not be read.'
            MaximumRecords   = [int]128
        }
    }
}

function Format-RecoveryLogFallback {
    <# Builds one bounded, sanitized transcript string without persistent I/O. #>
    [CmdletBinding()]
    param(
        [AllowNull()][psobject]$Snapshot,
        [int]$MaximumCharacters = 8192
    )

    try {
        if ($null -eq $Snapshot) {
            $Snapshot = Get-RecoveryLogFallbackSnapshot
        }
        $maximum = [math]::Max(256,[math]::Min(65536,$MaximumCharacters))
        $records = @($Snapshot.Records)
        $firstWriterError = Protect-LogValue `
            -Value ([string]$Snapshot.FirstWriterError) `
            -MaximumLength 2048
        if ($records.Count -eq 0 -and [string]::IsNullOrWhiteSpace($firstWriterError)) {
            return ''
        }

        $lines = New-Object 'System.Collections.Generic.List[string]'
        [void]$lines.Add("Primary audit writer failure: $firstWriterError")
        [void]$lines.Add("Recovery records retained: $($records.Count); dropped: $([long]$Snapshot.DroppedCount).")
        foreach ($record in $records) {
            $timestamp = if ($record.Timestamp -is [DateTime]) {
                ([DateTime]$record.Timestamp).ToString(
                    'dd-MM-yyyy HH:mm:ss',
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            }
            else {
                '-'
            }
            $level = Protect-LogValue -Value ([string]$record.Level) -MaximumLength 128 -EmptyValue '-'
            $stage = Protect-LogValue -Value ([string]$record.Stage) -MaximumLength 256 -EmptyValue '-'
            $machine = Protect-LogValue -Value ([string]$record.MachineName) -MaximumLength 128 -EmptyValue '-'
            $message = Protect-LogValue -Value ([string]$record.Message) -MaximumLength 2048
            [void]$lines.Add("$timestamp | $level | $stage | $machine | $message")
        }
        $formatted = [string]::Join([Environment]::NewLine,[string[]]$lines)
        if ($formatted.Length -gt $maximum) {
            return $formatted.Substring(0,$maximum - 16) + ' ... [truncated]'
        }
        return $formatted
    }
    catch {
        return 'Recovery log details are unavailable.'
    }
}

function Write-RecoveryLog {
    <#
      Once a write has been attempted, outcome capture must continue even when
      the primary audit writer has failed. The primary writer is tried exactly
      once; a failure is retained only in bounded process-local memory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [string]$MachineName = '-',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    try {
        Write-RunLog -Level $Level -Stage $Stage -MachineName $MachineName -Message $Message
    }
    catch {
        # Never retry the failed persistent writer from this recovery path.
        $script:AuditTrailHealthy = $false
        Add-RecoveryLogFallbackRecord `
            -Level $Level `
            -Stage $Stage `
            -MachineName $MachineName `
            -Message $Message `
            -WriterError ([string]$_.Exception.Message)
    }
}

function Assert-AuditTrailAvailable {
    <# Every production mutation calls this immediately before its write path. #>
    [CmdletBinding()]
    param()

    if (-not $script:AuditTrailHealthy -or $null -eq $script:LogWriter) {
        throw "The run log is unavailable. No new production change is permitted. Close the tool, review '$script:LogPath', and start a new run."
    }
}

function Close-RunLog {
    [CmdletBinding()]
    param()

    if ($null -ne $script:LogWriter) {
        try { $script:LogWriter.Flush() } catch {}
        try { $script:LogWriter.Dispose() } catch {}
        $script:LogWriter = $null
    }
}

function Close-RunLogForRotation {
    <# A new in-process Run ID is allowed only after confirmed log closure. #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:LogWriter) {
        throw "The current run log '$($script:LogPath)' is not open and cannot be safely rotated."
    }

    $writer = $script:LogWriter
    try {
        $writer.Flush()
        $writer.Dispose()
    }
    catch {
        $script:AuditTrailHealthy = $false
        $script:LogWriter = $null
        throw "The current run log '$($script:LogPath)' could not be safely closed before Reset. No new run can start in this application session. $($_.Exception.Message)"
    }
    $script:LogWriter = $null
}

function Start-RunAuditSession {
    <# Creates one immutable audit session for initial launch or Start New Build. #>
    [CmdletBinding()]
    param([switch]$GenerateNewRunId)

    if ($GenerateNewRunId) {
        if ($null -ne $script:LogWriter) {
            throw 'The previous run log must be closed before a new audit session is started.'
        }
        $script:RunId = [guid]::NewGuid().ToString('N')
        $script:AuditTrailHealthy = $true
        $script:ValidationAttemptCount = [long]0
    }
    Initialize-RunLog
    Reset-RecoveryLogFallbackState
    Update-ApplicationLockMetadata

    $runIdentity = $null
    try {
        $runIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $identity = [string]$runIdentity.Name
    }
    catch {
        $identity = [string]$env:USERNAME
    }
    finally {
        if ($null -ne $runIdentity) { $runIdentity.Dispose() }
    }
    Write-RunLog -Level INFO -Stage 'Run' -Message "Started $($script:ToolName) v$($script:ToolVersion). RunId=$($script:RunId); Computer=$env:COMPUTERNAME; User=$identity; PowerShell=$($PSVersionTable.PSVersion); Script=$($script:LaunchScriptPath); PvsSoapServer=$script:PvsSoapServer; MaximumBatchSize=$($script:MaximumBatchSize); ImportFormats=csv,xlsx; CsvImportLimitBytes=$($script:MaximumCsvImportBytes); XlsxImportLimitBytes=$($script:MaximumXlsxImportBytes); StartupUi=ResponsiveSplashWithFallback; OlvmManagerSelection=SelectedManagerDirectConnectionWithValidationAutoFallback; OlvmLiveVmNicRead=ValidationAndPostWrite; StoreInventory=StartupPerSiteCached; ImageSelection=OptionalProductionReadySequentialBackgroundCache; RebootBalance=ValidationPlanMissingValuesIgnored; AdValidation=WritableDcBatchFanOut; AdBindingVerification=WritableDcFanOutPasses$($script:AdBindingVerificationAttempts)Delay$($script:AdBindingVerificationDelaySeconds)s; BuildPlan=NoSecondPreWriteValidationExactContinuationNoAutomaticRollback; FarmBuildLock=DeterministicCoordinatorHeldThroughPower; PostBuildPower=OptionalOptInWaves$($script:PowerWaveSize)WithAuditedAdWarningOverride; DhcpDescription=ExcludedFromCreateAndValidation; Log=$script:LogPath."
    if (-not [string]::IsNullOrWhiteSpace($script:ApplicationLockMetadataWarning)) {
        Write-RunLog -Level WARN -Stage 'Application lock' -Message "The same-server mutex is active, but shared owner metadata could not be published: $($script:ApplicationLockMetadataWarning)"
    }
}
