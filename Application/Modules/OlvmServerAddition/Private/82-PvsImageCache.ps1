function Get-PvsImageChoiceCacheKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][guid]$SiteId,
        [Parameter(Mandatory = $true)][guid]$StoreId
    )

    return ('{0}|{1}' -f
        $SiteId.ToString('D').ToLowerInvariant(),
        $StoreId.ToString('D').ToLowerInvariant())
}

function Initialize-PvsImageWarmupRequests {
    <# Creates one deterministic read-only work item per immutable Site and Store. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [object[]]$Collections
    )

    $representatives = @{}
    foreach ($collection in @($Collections)) {
        if ($null -eq $collection -or
            [string]::IsNullOrWhiteSpace([string]$collection.SiteId)) {
            throw 'PVS returned a Device Collection without an immutable Site ID while preparing the vDisk cache.'
        }
        $siteKey = ([guid]$collection.SiteId).ToString('D').ToLowerInvariant()
        if (-not $representatives.ContainsKey($siteKey)) {
            $representatives[$siteKey] = $collection
        }
    }

    $requests = New-Object 'System.Collections.Generic.List[object]'
    $requestKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($siteKey in @($representatives.Keys | Sort-Object)) {
        if (-not $script:PvsStoreChoicesCache.ContainsKey($siteKey)) {
            continue
        }
        $collection = $representatives[$siteKey]
        foreach ($store in @([object[]]$script:PvsStoreChoicesCache[$siteKey] | Sort-Object Name)) {
            $siteId = [guid]$collection.SiteId
            $storeId = [guid]$store.StoreId
            $cacheKey = Get-PvsImageChoiceCacheKey -SiteId $siteId -StoreId $storeId
            if (-not $requestKeys.Add($cacheKey)) {
                continue
            }
            [void]$requests.Add([pscustomobject]@{
                    CacheKey          = $cacheKey
                    SiteId            = $siteId
                    SiteName          = [string]$collection.SiteName
                    CollectionDisplay = [string]$collection.Display
                    StoreId           = $storeId
                    StoreName         = [string]$store.Name
                })
        }
    }
    $script:PvsImageWarmupRequests = [object[]]$requests.ToArray()
    return [object[]]$script:PvsImageWarmupRequests
}

function Add-PvsImageWarmupRequest {
    <# Adds a newly discovered Site and Store pair without duplicating work. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Request)

    $matches = @($script:PvsImageWarmupRequests | Where-Object {
            [string]$_.CacheKey -ieq [string]$Request.CacheKey
        })
    if ($matches.Count -eq 0) {
        $script:PvsImageWarmupRequests = [object[]]@(
            @($script:PvsImageWarmupRequests) +
            @([pscustomobject]@{
                    CacheKey          = [string]$Request.CacheKey
                    SiteId            = [guid]$Request.SiteId
                    SiteName          = [string]$Request.SiteName
                    CollectionDisplay = [string]$Request.CollectionDisplay
                    StoreId           = [guid]$Request.StoreId
                    StoreName         = [string]$Request.StoreName
                })
        )
    }
}
