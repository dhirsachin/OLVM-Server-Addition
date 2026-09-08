function Get-SelectionDefaultDnsDomain {
    <# Provides the infrastructure-derived default through the Application selection boundary. #>
    [CmdletBinding()]
    param()

    Get-LocalDnsDomain
}

function Reset-SelectionOlvmRouteCache {
    <# Clears OLVM selection state through the Application selection boundary. #>
    [CmdletBinding()]
    param()

    Reset-OlvmRouteCache
}

function Get-SelectionOuChoices {
    <# Returns OU choices without exposing the directory adapter to Presentation. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DnsDomain
    )

    Get-OuChoicesForDomain -DnsDomain $DnsDomain
}

function Get-SelectionPvsStoreChoices {
    <# Returns Store choices without exposing the PVS adapter to Presentation. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Collection
    )

    Get-PvsStoreChoicesForCollection -Collection $Collection
}

function Assert-SelectionPvsImageSnapshot {
    <# Verifies the selected image through the Application selection boundary. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Collection,

        [Parameter(Mandatory = $true)]
        [psobject]$Store,

        [Parameter(Mandatory = $true)]
        [psobject]$ExpectedImage
    )

    Assert-PvsImageSnapshotUnchanged `
        -Collection $Collection `
        -Store $Store `
        -ExpectedImage $ExpectedImage
}

function Resolve-SelectionAdOrganizationalUnit {
    <# Resolves an exact OU without exposing the directory adapter to Presentation. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName,

        [Parameter(Mandatory = $true)]
        [string]$Server
    )

    Resolve-AdOrganizationalUnit `
        -DistinguishedName $DistinguishedName `
        -Server $Server
}

function Initialize-PvsStoreChoicesCache {
    <#
      Warms Store navigation data once per immutable PVS Site during startup.
      vDisk readiness remains lazy and is never inferred from this cache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [object[]]$Collections
    )

    $script:PvsStoreChoicesCache = @{}
    $script:PvsStoreChoiceErrors = @{}
    $representatives = @{}
    foreach ($collection in @($Collections)) {
        if ($null -eq $collection -or
            [string]::IsNullOrWhiteSpace([string]$collection.SiteId)) {
            throw 'PVS returned a Device Collection without an immutable Site ID.'
        }
        $siteKey = ([guid]$collection.SiteId).ToString('D').ToLowerInvariant()
        if (-not $representatives.ContainsKey($siteKey)) {
            $representatives[$siteKey] = $collection
        }
    }

    $loadedSites = 0
    $failedSites = 0
    $storeCount = 0
    foreach ($siteKey in @($representatives.Keys | Sort-Object)) {
        $collection = $representatives[$siteKey]
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $stores = @(Get-PvsStoreChoicesForCollection -Collection $collection)
            $script:PvsStoreChoicesCache[$siteKey] = [object[]]$stores
            $loadedSites++
            $storeCount += $stores.Count
            Write-RunLog -Level SUCCESS -Stage 'PVS Store startup' -Message "Preloaded $($stores.Count) Store choice(s) for PVS Site '$($collection.SiteName)' (SiteId '$siteKey') in $($timer.ElapsedMilliseconds) ms. A Store was not auto-selected."
        }
        catch {
            $failedSites++
            $errorMessage = $_.Exception.Message
            $script:PvsStoreChoiceErrors[$siteKey] = [pscustomobject]@{
                SiteId       = $siteKey
                SiteName     = [string]$collection.SiteName
                ErrorMessage = $errorMessage
                FailedAtUtc  = [DateTime]::UtcNow
            }
            Write-RecoveryLog -Level WARN -Stage 'PVS Store startup' -Message "Optional Store discovery failed for PVS Site '$($collection.SiteName)' (SiteId '$siteKey') after $($timer.ElapsedMilliseconds) ms: $errorMessage Assign Image remains optional; choosing Yes for this Site will retry discovery."
        }
        finally {
            $timer.Stop()
        }
    }
    return [pscustomobject]@{
        SiteCount   = $representatives.Count
        LoadedSites = $loadedSites
        FailedSites = $failedSites
        StoreCount  = $storeCount
    }
}
