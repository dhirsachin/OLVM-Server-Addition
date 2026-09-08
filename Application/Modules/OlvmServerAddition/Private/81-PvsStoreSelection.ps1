function Read-PvsStoresForSelectedCollection {
    <# Binds the startup Site cache; only an explicit image request retries failure. #>
    [CmdletBinding()]
    param([switch]$RetryFailed)

    $collection = $script:Collection.SelectedItem
    if ($null -eq $collection) {
        $script:PvsStore.ItemsSource = @()
        $script:PvsStore.SelectedIndex = -1
        return [object[]]@()
    }

    $cacheKey = ([guid]$collection.SiteId).ToString('D').ToLowerInvariant()
    if ($script:PvsStoreChoicesCache.ContainsKey($cacheKey)) {
        $stores = [object[]]$script:PvsStoreChoicesCache[$cacheKey]
        $source = 'startup cache'
    }
    elseif ($script:PvsStoreChoiceErrors.ContainsKey($cacheKey) -and -not $RetryFailed) {
        $failure = $script:PvsStoreChoiceErrors[$cacheKey]
        $script:PvsStore.ItemsSource = @()
        $script:PvsStore.SelectedIndex = -1
        Write-RunLog -Level WARN -Stage 'PVS Store selection' -Message "Store choices for '$($collection.Display)' are unavailable because startup discovery failed: $($failure.ErrorMessage) Assign Image No remains available; choosing Yes will retry."
        Set-Status -Text "Store discovery failed at startup for '$($collection.Display)'. Assign Image remains No; selecting Yes will retry." -Color 'DarkOrange' -Stage 'PVS Store selection'
        return [object[]]@()
    }
    elseif ($RetryFailed -and $script:PvsStoreChoiceErrors.ContainsKey($cacheKey)) {
        if ($script:IsPvsImageCacheWarmupActive) {
            Complete-PvsImageBackgroundLoad
        }
        if ($script:IsPvsImageCacheWarmupActive) {
            throw "PVS Store discovery for '$($collection.Display)' cannot be retried while the separate background vDisk reader is active. Wait for background loading to finish, then select Assign Image Yes again."
        }
        Set-Status -Text "Retrying optional PVS Store discovery for '$($collection.Display)'..." -Stage 'PVS Store selection'
        try {
            $stores = @(Get-SelectionPvsStoreChoices -Collection $collection)
            $script:PvsStoreChoicesCache[$cacheKey] = [object[]]$stores
            [void]$script:PvsStoreChoiceErrors.Remove($cacheKey)
            $source = 'live retry after startup failure'
        }
        catch {
            $script:PvsStoreChoiceErrors[$cacheKey] = [pscustomobject]@{
                SiteId       = $cacheKey
                SiteName     = [string]$collection.SiteName
                ErrorMessage = $_.Exception.Message
                FailedAtUtc  = [DateTime]::UtcNow
            }
            throw "PVS Store discovery retry failed for '$($collection.Display)': $($_.Exception.Message)"
        }

        # The initial all-Store warmup queue omitted this Site because its
        # Store inventory was unavailable. Merge every recovered Store now,
        # not only the one the operator may subsequently select.
        foreach ($recoveredStore in @($stores)) {
            $siteId = [guid]$collection.SiteId
            $storeId = [guid]$recoveredStore.StoreId
            Add-PvsImageWarmupRequest -Request ([pscustomobject]@{
                    CacheKey          = Get-PvsImageChoiceCacheKey -SiteId $siteId -StoreId $storeId
                    SiteId            = $siteId
                    SiteName          = [string]$collection.SiteName
                    CollectionDisplay = [string]$collection.Display
                    StoreId           = $storeId
                    StoreName         = [string]$recoveredStore.Name
                })
        }
        if ($script:GuiDisplayed -and -not $script:IsOperationRunning) {
            try { $null = Start-PvsImageCacheWarmup }
            catch {
                Write-RecoveryLog -Level WARN -Stage 'PVS image cache' -Message "Optional background vDisk warming could not be started after Store discovery recovered for '$($collection.Display)': $($_.Exception.Message) The Store list remains available and selecting a Store will retry it on demand."
            }
        }
    }
    else {
        throw "PVS Store inventory for Site '$($collection.SiteName)' (SiteId '$cacheKey') was not initialized at application launch. Close and reopen the tool before assigning an image."
    }
    $script:PvsStore.ItemsSource = $stores
    $script:PvsStore.SelectedIndex = -1
    Write-RunLog -Level SUCCESS -Stage 'PVS Store selection' -Message "Loaded $($stores.Count) Store(s) for '$($collection.Display)' from $source. No Store or image was auto-selected."
    if ($stores.Count -eq 0) {
        Set-Status -Text 'No PVS Store with a visible vDisk was found. Select No for Assign Image to continue without a vDisk.' -Color 'DarkOrange' -Stage 'PVS Store selection'
    }
    else {
        Set-Status -Text "Loaded $($stores.Count) PVS Store(s). Select a Store and vDisk, or keep Assign Image set to No." -Color 'DarkOrange' -Stage 'PVS Store selection'
    }
    return [object[]]$stores
}
