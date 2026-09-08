function Get-PvsTargetActionPlan {
    <# Classifies only exact reusable state; every partial mismatch blocks. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Record,
        [Parameter(Mandatory = $true)][psobject]$Collection
    )

    $nameMatches = @(Get-PvsDeviceIfPresent -Name $Record.MachineName)
    $macMatches = @(Get-PvsDeviceIfPresent -DeviceMac $Record.MacAddress)
    if ($nameMatches.Count -eq 0 -and $macMatches.Count -eq 0) {
        return [pscustomobject]@{
            Action = 'Create'
            Guid   = $null
            Device = $null
        }
    }
    if ($nameMatches.Count -ne 1 -or $macMatches.Count -ne 1) {
        throw "PVS state is partial, conflicting, or ambiguous for target '$($Record.MachineName)' and MAC '$($Record.MacAddress)'. Name matches=$($nameMatches.Count); MAC matches=$($macMatches.Count). Existing targets will not be overwritten or reconciled."
    }
    $byName = $nameMatches[0]
    $byMac = $macMatches[0]
    if ([guid]$byName.Guid -ne [guid]$byMac.Guid) {
        throw "PVS name '$($Record.MachineName)' and MAC '$($Record.MacAddress)' belong to different target GUIDs. Existing targets will not be reconciled."
    }
    if ([string]$byName.Name -cne [string]$Record.MachineName -or
        -not (Test-MacAddressEqual -First ([string]$byName.DeviceMac) -Second $Record.MacAddress) -or
        [string]$byName.SiteName -ine [string]$Collection.SiteName -or
        [string]$byName.CollectionName -ine [string]$Collection.Name) {
        throw "Existing PVS target '$($byName.Name)' / '$($byName.DeviceMac)' is not an exact match for requested target '$($Record.MachineName)' / '$($Record.MacAddress)' in '$($Collection.Display)'. It will not be moved or changed."
    }
    return [pscustomobject]@{
        Action = 'ReuseExact'
        Guid   = [guid]$byName.Guid
        Device = $byName
    }
}

function Get-PvsImageActionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$PvsPlan,
        [Parameter(Mandatory = $true)][psobject]$Settings
    )

    if ($PvsPlan.Action -eq 'Create') {
        return [pscustomobject]@{
            Action = if ($Settings.AssignPvsImage) { 'Create' } else { 'VerifyNone' }
        }
    }
    $deviceId = [guid]$PvsPlan.Guid
    if (-not $Settings.AssignPvsImage) {
        $null = Assert-PvsNoImageAssignedToDevice -DeviceId $deviceId
        return [pscustomobject]@{ Action = 'VerifyNone' }
    }
    $mappings = @(Get-PvsDiskLocator -DeviceId $deviceId -ErrorAction Stop)
    if ($mappings.Count -eq 0) {
        return [pscustomobject]@{ Action = 'Create' }
    }
    if ($mappings.Count -ne 1) {
        throw "Existing PVS target '$deviceId' has $($mappings.Count) vDisk mappings. V2 will not replace or reconcile them."
    }
    $null = Assert-PvsImageAssignedToDevice -DeviceId $deviceId -Image $Settings.Image
    return [pscustomobject]@{ Action = 'ReuseExact' }
}

function Get-AdActionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$MachineName,
        [Parameter(Mandatory = $true)][psobject]$OuMetadata,
        [Parameter(Mandatory = $true)][psobject]$DirectAccountSnapshot,
        [Parameter(Mandatory = $true)][psobject]$PvsPlan
    )

    if ($null -eq $DirectAccountSnapshot -or
        $DirectAccountSnapshot.Completed -ne $true -or
        $DirectAccountSnapshot.Entries -isnot [hashtable]) {
        throw 'The direct AD Validation snapshot is incomplete or invalid.'
    }
    $snapshotKey = $MachineName.ToUpperInvariant()
    if (-not $DirectAccountSnapshot.Entries.ContainsKey($snapshotKey)) {
        throw "The direct AD Validation snapshot omitted '$MachineName'."
    }
    $snapshotEntry = $DirectAccountSnapshot.Entries[$snapshotKey]
    $pvsAccount = Get-PvsAdComputerAccount -Name $MachineName -Domain $OuMetadata.DomainDnsName
    if ([string]$snapshotEntry.State -eq 'ConfirmedAbsent') {
        if ($null -ne $pvsAccount) {
            throw "PVS reports an AD account for '$($OuMetadata.DomainDnsName)\$MachineName' while the complete direct AD snapshot reports it absent. Resolve this ambiguous partial state before continuing."
        }
        if ($PvsPlan.Action -eq 'ReuseExact') {
            $null = Assert-PvsTargetEligibleForAd `
                -MachineName $MachineName `
                -ExpectedPvsGuid ([guid]$PvsPlan.Guid)
        }
        return [pscustomobject]@{
            Action    = 'Create'
            AdAccount = $null
        }
    }
    if ([string]$snapshotEntry.State -ne 'Found' -or $null -eq $snapshotEntry.Account) {
        throw "The direct AD Validation snapshot returned unsupported state '$($snapshotEntry.State)' for '$MachineName'."
    }
    if ($PvsPlan.Action -ne 'ReuseExact') {
        throw "AD account '$MachineName' exists, but there is no exact reusable PVS target. The existing account will not be reused or changed."
    }
    $directAccount = $snapshotEntry.Account
    $binding = Get-VerifiedAdPvsBinding `
        -MachineName $MachineName `
        -OuMetadata $OuMetadata `
        -ExpectedPvsGuid ([guid]$PvsPlan.Guid) `
        -ExpectedAdDistinguishedName ([string]$directAccount.DistinguishedName) `
        -ExpectedAdSid ([string]$directAccount.Sid) `
        -Stage 'AD continuation plan'
    return [pscustomobject]@{
        Action    = 'ReuseExact'
        AdAccount = $binding.AdAccount
    }
}
