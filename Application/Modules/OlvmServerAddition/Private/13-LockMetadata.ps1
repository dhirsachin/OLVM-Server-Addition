function Get-CurrentOperatorName {
    [CmdletBinding()]
    param()

    $windowsIdentity = $null
    try {
        $windowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($null -ne $windowsIdentity -and
            -not [string]::IsNullOrWhiteSpace([string]$windowsIdentity.Name)) {
            return [string]$windowsIdentity.Name
        }
    }
    catch {}
    finally {
        if ($null -ne $windowsIdentity) { $windowsIdentity.Dispose() }
    }
    return [string]$env:USERNAME
}

function Read-JsonMetadataFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if (-not [System.IO.File]::Exists($Path)) { return $null }
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json -ErrorAction Stop)
    }
    catch { return $null }
}

function Initialize-SharedLockMetadataDirectory {
    <#
      Creates the machine-wide application-lock metadata directory with a
      stable ACL that does not depend on which administrator launched the
      first V2 session. SYSTEM and local Administrators may write; any
      authenticated operator may read the active-owner details.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "The shared lock directory must be an absolute local path. Received '$Path'."
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath -notmatch '^[A-Za-z]:\\') {
        throw "The shared lock directory must use a fully qualified local Windows drive path. Received '$fullPath'."
    }

    $systemSid = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-18'
    $administratorsSid = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-544'
    $authenticatedUsersSid = New-Object System.Security.Principal.SecurityIdentifier(
        [System.Security.Principal.WellKnownSidType]::AuthenticatedUserSid,
        $null
    )
    $approvedWriteSids = @([string]$systemSid.Value,[string]$administratorsSid.Value)
    $created = -not [System.IO.Directory]::Exists($fullPath)
    if ($created) {
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetAccessRuleProtection($true,$false)
        $security.SetOwner($administratorsSid)
        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        $propagation = [System.Security.AccessControl.PropagationFlags]::None
        $allow = [System.Security.AccessControl.AccessControlType]::Allow
        foreach ($sid in @($systemSid,$administratorsSid)) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                $propagation,
                $allow
            )
            [void]$security.AddAccessRule($rule)
        }
        $readRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $authenticatedUsersSid,
            [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            $propagation,
            $allow
        )
        [void]$security.AddAccessRule($readRule)
        $directory = [System.IO.Directory]::CreateDirectory($fullPath,$security)
    }
    else {
        $directory = [System.IO.Directory]::CreateDirectory($fullPath)
    }
    if (-not $directory.Exists) {
        throw "Shared lock directory '$fullPath' could not be created or opened."
    }

    Assert-PathHasNoReparsePoint -Path $directory.FullName -BoundaryDescription 'The shared lock directory'
    $directorySecurity = $directory.GetAccessControl(
        [System.Security.AccessControl.AccessControlSections]::Access -bor
        [System.Security.AccessControl.AccessControlSections]::Owner
    )
    $ownerSid = $directorySecurity.GetOwner(
        [System.Security.Principal.SecurityIdentifier]
    ).Value
    if ($approvedWriteSids -notcontains $ownerSid) {
        throw "Shared lock directory '$fullPath' is owned by unapproved SID '$ownerSid'. The owner must be SYSTEM or local Administrators."
    }
    $dangerousRights = [System.Security.AccessControl.FileSystemRights]::WriteData -bor
        [System.Security.AccessControl.FileSystemRights]::AppendData -bor
        [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
        [System.Security.AccessControl.FileSystemRights]::CreateDirectories -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership
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
        throw "Shared lock directory '$fullPath' grants write-capable access to an unapproved principal ($ruleSummary)."
    }
    return $directory
}

function Format-LockOwnerMessage {
    [CmdletBinding()]
    param(
        [AllowNull()][psobject]$Metadata,
        [string]$Fallback = 'Owner details are unavailable.'
    )

    if ($null -eq $Metadata) { return $Fallback }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @(
            @('User','User'),
            @('Server','Computer'),
            @('Started UTC','StartedUtc'),
            @('Run ID','RunId'),
            @('PID','ProcessId'))) {
        $property = $Metadata.PSObject.Properties[[string]$item[1]]
        $value = if ($null -eq $property) { '' } else { [string]$property.Value }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            [void]$parts.Add("$($item[0])=$value")
        }
    }
    if ($parts.Count -eq 0) { return $Fallback }
    return [string]::Join('; ', $parts.ToArray())
}
