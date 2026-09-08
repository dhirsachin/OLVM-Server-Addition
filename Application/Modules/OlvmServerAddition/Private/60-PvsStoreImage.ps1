function Get-PvsStoreIdFromObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$InputObject)

    $value = Get-FirstPropertyValue -InputObject $InputObject -Names @('StoreId','Guid','Id')
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw 'PVS returned a Store without an immutable Store ID.'
    }
    return ([guid]$value)
}

function Get-PvsDiskLocatorIdFromObject {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$InputObject)

    $value = Get-FirstPropertyValue -InputObject $InputObject -Names @('DiskLocatorId','Guid','Id')
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw 'PVS returned a vDisk without an immutable DiskLocator ID.'
    }
    return ([guid]$value)
}

function Get-PvsStoreChoicesForCollection {
    <# Returns only Stores that expose at least one vDisk to this collection Site. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Collection
    )

    if ([string]::IsNullOrWhiteSpace([string]$Collection.SiteId)) {
        throw "PVS collection '$($Collection.Display)' does not expose a Site ID."
    }
    $diskInfos = @(Get-PvsDiskInfo -SiteId ([guid]$Collection.SiteId) -ErrorAction Stop)
    $storeIds = @($diskInfos |
        ForEach-Object { [string](Get-FirstPropertyValue -InputObject $_ -Names @('StoreId')) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)

    $choices = New-Object 'System.Collections.Generic.List[object]'
    foreach ($storeIdText in $storeIds) {
        $storeMatches = @(Get-PvsStore -StoreId ([guid]$storeIdText) -ErrorAction Stop)
        if ($storeMatches.Count -ne 1) {
            throw "PVS returned $($storeMatches.Count) Stores for Store ID '$storeIdText'; expected one."
        }
        $store = $storeMatches[0]
        $storeId = Get-PvsStoreIdFromObject -InputObject $store
        $storeName = [string](Get-FirstPropertyValue -InputObject $store -Names @('Name','StoreName'))
        if ([string]::IsNullOrWhiteSpace($storeName)) {
            throw "PVS Store '$storeId' has no usable name."
        }
        [void]$choices.Add([pscustomobject]@{
                StoreId = $storeId
                Name    = $storeName
                Display = $storeName
            })
    }
    return [object[]]@($choices.ToArray() | Sort-Object Display)
}

function New-PvsImageIneligibleException {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Message)

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['PvsImageDeterministicallyIneligible'] = $true
    return $exception
}

function Get-PvsImageSnapshot {
    <#
      Reconstructs one immutable Production-ready vDisk snapshot. A snapshot is
      never accepted solely because its display name looks like Production.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Collection,

        [Parameter(Mandatory = $true)]
        [psobject]$Store,

        [Parameter(Mandatory = $true)]
        [guid]$DiskLocatorId,

        [AllowNull()]
        [psobject]$DiskInfoSnapshot = $null
    )

    $storeId = [guid]$Store.StoreId
    # Image Browse already has one bounded Store inventory. Reuse that row to
    # avoid an N+1 full-Store query; Preview and every write/final gate omit it
    # and therefore still obtain a fresh authoritative snapshot.
    $diskInfos = if ($null -ne $DiskInfoSnapshot) {
        @($DiskInfoSnapshot)
    }
    else {
        @(Get-PvsDiskInfo `
            -SiteId ([guid]$Collection.SiteId) `
            -StoreId $storeId `
            -ErrorAction Stop)
    }
    $matches = @($diskInfos | Where-Object {
            (Get-PvsDiskLocatorIdFromObject -InputObject $_) -eq $DiskLocatorId
        })
    if ($matches.Count -ne 1) {
        throw "PVS returned $($matches.Count) vDisks for DiskLocator ID '$DiskLocatorId' in Store '$($Store.Name)'; expected one."
    }
    $disk = $matches[0]
    $diskSiteId = [guid](Get-FirstPropertyValue -InputObject $disk -Names @('SiteId'))
    $diskStoreId = [guid](Get-FirstPropertyValue -InputObject $disk -Names @('StoreId'))
    if ($diskSiteId -ne [guid]$Collection.SiteId -or $diskStoreId -ne $storeId) {
        throw "vDisk '$DiskLocatorId' no longer belongs to the selected Site and Store."
    }
    $enabled = ConvertTo-StrictBoolean `
        -Value (Get-FirstPropertyValue -InputObject $disk -Names @('Enabled')) `
        -Description "vDisk '$DiskLocatorId' Enabled"
    if (-not $enabled) {
        throw (New-PvsImageIneligibleException -Message 'The vDisk is disabled.')
    }

    $writeCacheText = [string](Get-FirstPropertyValue -InputObject $disk -Names @('WriteCacheType'))
    $writeCacheType = 0
    if (-not [int]::TryParse($writeCacheText, [ref]$writeCacheType)) {
        throw (New-PvsImageIneligibleException -Message "The vDisk returned unknown write-cache mode '$writeCacheText'.")
    }
    $modeNames = @{
        1  = 'Cache on Server'
        3  = 'Cache in Device RAM'
        4  = 'Cache on Device Hard Disk'
        7  = 'Cache on Server, Persistent'
        9  = 'Cache in Device RAM with Overflow on Hard Disk'
        11 = 'Server persistent async'
        12 = 'Cache in Device RAM with Overflow on Hard Disk async'
    }
    if (-not $modeNames.ContainsKey($writeCacheType)) {
        if ($writeCacheType -in @(0,10)) {
            throw (New-PvsImageIneligibleException -Message 'The vDisk is in Private mode and cannot be used by this batch workflow.')
        }
        throw (New-PvsImageIneligibleException -Message "The vDisk uses unsupported write-cache mode '$writeCacheType'.")
    }

    $versions = @(Get-PvsDiskVersion -DiskLocatorId $DiskLocatorId -ErrorAction Stop)
    $eligibleVersions = @($versions | Where-Object {
            $accessText = [string](Get-FirstPropertyValue -InputObject $_ -Names @('Access'))
            $pending = ConvertTo-StrictBoolean `
                -Value (Get-FirstPropertyValue -InputObject $_ -Names @('IsPending')) `
                -Description 'vDisk version IsPending'
            $goodInventory = ConvertTo-StrictBoolean `
                -Value (Get-FirstPropertyValue -InputObject $_ -Names @('GoodInventoryStatus')) `
                -Description 'vDisk version GoodInventoryStatus'
            ($accessText -in @('0','3')) -and -not $pending -and $goodInventory
        })
    $effective = @($eligibleVersions | Sort-Object `
            @{ Expression = { if ([string](Get-FirstPropertyValue -InputObject $_ -Names @('Access')) -eq '3') { 1 } else { 0 } }; Descending = $true },
            @{ Expression = { [int](Get-FirstPropertyValue -InputObject $_ -Names @('Version')) }; Descending = $true } |
        Select-Object -First 1)
    if ($effective.Count -ne 1) {
        throw (New-PvsImageIneligibleException -Message 'The vDisk has no non-pending Production or Override version with good server inventory.')
    }
    $effectiveVersion = [int](Get-FirstPropertyValue -InputObject $effective[0] -Names @('Version'))
    $effectiveAccess = [string](Get-FirstPropertyValue -InputObject $effective[0] -Names @('Access'))
    $accessName = if ($effectiveAccess -eq '3') { 'Override' } else { 'Production' }

    $inventory = @(Get-PvsDiskInventory `
        -DiskLocatorId $DiskLocatorId `
        -Version $effectiveVersion `
        -ErrorAction Stop)
    $servingInventory = @($inventory | Where-Object {
            $stateText = [string](Get-FirstPropertyValue -InputObject $_ -Names @('State'))
            $activeValue = Get-FirstPropertyValue -InputObject $_ -Names @('Active')
            $isActive = $false
            try { $isActive = ConvertTo-StrictBoolean -Value $activeValue -Description 'vDisk server inventory Active' } catch { $isActive = $false }
            $stateText -eq '0' -and $isActive
        })
    if ($servingInventory.Count -eq 0) {
        throw (New-PvsImageIneligibleException -Message 'No active PVS server reports an up-to-date inventory copy of the effective vDisk version.')
    }
    $servingServers = @($servingInventory |
        ForEach-Object { [string](Get-FirstPropertyValue -InputObject $_ -Names @('ServerName','Name')) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)
    if ($servingServers.Count -eq 0) {
        throw (New-PvsImageIneligibleException -Message 'The vDisk inventory is active, but PVS did not identify its serving server names.')
    }

    $diskName = [string](Get-FirstPropertyValue -InputObject $disk -Names @('DiskLocatorName','Name'))
    if ([string]::IsNullOrWhiteSpace($diskName)) {
        throw (New-PvsImageIneligibleException -Message "vDisk '$DiskLocatorId' has no usable name.")
    }
    $snapshot = [pscustomobject]@{
        DiskLocatorId          = $DiskLocatorId
        Name                   = $diskName
        SiteId                 = $diskSiteId
        SiteName               = [string](Get-FirstPropertyValue -InputObject $disk -Names @('SiteName'))
        StoreId                = $diskStoreId
        StoreName              = [string]$Store.Name
        Enabled                = $enabled
        WriteCacheType         = $writeCacheType
        Mode                   = [string]$modeNames[$writeCacheType]
        EffectiveVersion       = $effectiveVersion
        EffectiveAccess        = $effectiveAccess
        EffectiveVersionDisplay = "$effectiveVersion ($accessName)"
        ServingServers         = [string[]]$servingServers
        ServingServersDisplay  = $servingServers -join ', '
        DeviceCount            = Get-FirstPropertyValue -InputObject $disk -Names @('DeviceCount')
        Description            = [string](Get-FirstPropertyValue -InputObject $disk -Names @('Description'))
    }
    $snapshot | Add-Member -NotePropertyName Fingerprint -NotePropertyValue (
        '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f
            $snapshot.DiskLocatorId,
            $snapshot.SiteId,
            $snapshot.StoreId,
            $snapshot.WriteCacheType,
            $snapshot.EffectiveVersion,
            $snapshot.EffectiveAccess,
            ($snapshot.ServingServers -join ',').ToLowerInvariant()
    )
    return $snapshot
}

function Get-PvsImageCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Collection,
        [Parameter(Mandatory = $true)][psobject]$Store
    )

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $exclusions = New-Object 'System.Collections.Generic.List[string]'
    $diskInfos = @(Get-PvsDiskInfo `
        -SiteId ([guid]$Collection.SiteId) `
        -StoreId ([guid]$Store.StoreId) `
        -ErrorAction Stop)
    foreach ($disk in $diskInfos) {
        $name = [string](Get-FirstPropertyValue -InputObject $disk -Names @('DiskLocatorName','Name'))
        try {
            $diskId = Get-PvsDiskLocatorIdFromObject -InputObject $disk
            $snapshot = Get-PvsImageSnapshot `
                -Collection $Collection `
                -Store $Store `
                -DiskLocatorId $diskId `
                -DiskInfoSnapshot $disk
            [void]$candidates.Add($snapshot)
        }
        catch {
            if ([string]::IsNullOrWhiteSpace($name)) { $name = '<unnamed vDisk>' }
            if ($_.Exception.Data.Contains('PvsImageDeterministicallyIneligible') -and
                [bool]$_.Exception.Data['PvsImageDeterministicallyIneligible']) {
                [void]$exclusions.Add("$name - $($_.Exception.Message)")
            }
            else {
                throw "PVS could not read a complete vDisk state for '$name' in Store '$($Store.Name)': $($_.Exception.Message)"
            }
        }
    }
    return [pscustomobject]@{
        Candidates = [object[]]@($candidates.ToArray() | Sort-Object Name)
        Exclusions = [string[]]$exclusions.ToArray()
    }
}

function Assert-PvsImageSnapshotUnchanged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Collection,
        [Parameter(Mandatory = $true)][psobject]$Store,
        [Parameter(Mandatory = $true)][psobject]$ExpectedImage
    )

    $fresh = Get-PvsImageSnapshot `
        -Collection $Collection `
        -Store $Store `
        -DiskLocatorId ([guid]$ExpectedImage.DiskLocatorId)
    if ([string]$fresh.Fingerprint -cne [string]$ExpectedImage.Fingerprint) {
        throw "Selected PVS image '$($ExpectedImage.Name)' changed after Validation. Expected mode '$($ExpectedImage.Mode)', version '$($ExpectedImage.EffectiveVersionDisplay)', and servers '$($ExpectedImage.ServingServersDisplay)'; current mode is '$($fresh.Mode)', version is '$($fresh.EffectiveVersionDisplay)', and servers are '$($fresh.ServingServersDisplay)'."
    }
    return $fresh
}

function Assert-PvsImageAssignedToDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][guid]$DeviceId,
        [Parameter(Mandatory = $true)][psobject]$Image
    )

    $mappings = @(Get-PvsDiskLocator -DeviceId $DeviceId -ErrorAction Stop)
    if ($mappings.Count -ne 1) {
        throw "PVS target '$DeviceId' has $($mappings.Count) vDisk assignments; expected exactly one."
    }
    $actualId = Get-PvsDiskLocatorIdFromObject -InputObject $mappings[0]
    if ($actualId -ne [guid]$Image.DiskLocatorId) {
        throw "PVS target '$DeviceId' is assigned to unexpected vDisk '$actualId'."
    }
    foreach ($propertyName in 'Enabled','EnabledForDevice') {
        $value = Get-FirstPropertyValue -InputObject $mappings[0] -Names @($propertyName)
        if ($null -ne $value -and
            -not (ConvertTo-StrictBoolean -Value $value -Description "vDisk mapping $propertyName")) {
            throw "The selected vDisk mapping is not enabled for PVS target '$DeviceId'."
        }
    }
    $enabledResult = Get-PvsDeviceDiskLocatorEnabled `
        -DeviceId $DeviceId `
        -DiskLocatorId ([guid]$Image.DiskLocatorId) `
        -ErrorAction Stop
    $enabledValue = if ($null -ne $enabledResult -and
        $null -ne $enabledResult.PSObject.Properties['Enabled']) {
        $enabledResult.PSObject.Properties['Enabled'].Value
    }
    else {
        $enabledResult
    }
    if (-not (ConvertTo-StrictBoolean -Value $enabledValue -Description 'Get-PvsDeviceDiskLocatorEnabled')) {
        throw "PVS reports the selected vDisk as disabled for target '$DeviceId'."
    }
    return $mappings[0]
}

function Assert-PvsNoImageAssignedToDevice {
    <#
      Proves the negative image-selection state on the exact target GUID owned
      by this run. Optional image assignment must not silently accept a Store
      default, concurrent mapping, or other unexpected vDisk attachment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [guid]$DeviceId
    )

    $mappings = @(Get-PvsDiskLocator -DeviceId $DeviceId -ErrorAction Stop)
    if ($mappings.Count -ne 0) {
        throw "PVS target '$DeviceId' has $($mappings.Count) unexpected vDisk assignment(s), but this batch requested no image. The tool will not replace or remove an individual mapping."
    }
    return $true
}

function Set-PvsImageForNewTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Context,
        [Parameter(Mandatory = $true)][psobject]$State
    )

    $record = $Context.Record
    $settings = $Context.Settings
    Write-RunLog -Level INFO -Stage 'PVS image' -MachineName $record.MachineName -Message "Assigning vDisk '$($settings.Image.Name)' (DiskLocator '$($settings.Image.DiskLocatorId)') to target GUID '$($State.PvsGuid)'."
    # Last fail-closed audit gate immediately before the PVS image mutation.
    Assert-AuditTrailAvailable
    Assert-FarmBuildLockOwned
    $State.ImageStatus = 'Ambiguous'
    Add-PvsDiskLocatorToDevice `
        -DiskLocatorId ([guid]$settings.Image.DiskLocatorId) `
        -DeviceId ([guid]$State.PvsGuid) `
        -Confirm:$false `
        -ErrorAction Stop |
        Out-Null
    $null = Assert-PvsImageAssignedToDevice `
        -DeviceId ([guid]$State.PvsGuid) `
        -Image $settings.Image
    $State.ImageStatus = 'ConfirmedAssigned'
    Write-RunLog -Level SUCCESS -Stage 'PVS image' -MachineName $record.MachineName -Message "Assigned and verified vDisk '$($settings.Image.Name)' (DiskLocator '$($settings.Image.DiskLocatorId)', version '$($settings.Image.EffectiveVersionDisplay)') on PVS target GUID '$($State.PvsGuid)'."
}

function Assert-PvsCollectionAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Collection
    )

    $matches = @(Get-PvsCollection -Fields Guid,Name,SiteId,SiteName -ErrorAction Stop |
        Where-Object {
            [string]$_.Guid -eq [string]$Collection.Guid -and
            [string]$_.SiteId -eq [string]$Collection.SiteId -and
            [string]$_.Name -ieq [string]$Collection.Name -and
            [string]$_.SiteName -ieq [string]$Collection.SiteName
        })
    if ($matches.Count -ne 1) {
        throw "Selected PVS collection '$($Collection.Display)' is no longer available or is ambiguous."
    }
}
