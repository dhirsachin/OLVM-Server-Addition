function Test-PvsImageLoadRequestCurrent {
    <# A completed worker may publish only to the exact GUI state that launched it. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Request)

    if (-not $script:IsPvsImageLoadPending -or
        $null -eq $script:PvsImageLoadRequest -or
        [string]$script:PvsImageLoadRequest.RequestId -cne [string]$Request.RequestId -or
        [long]$script:PvsImageLoadGeneration -ne [long]$Request.Generation -or
        [string]$script:RunId -cne [string]$Request.RunId -or
        $script:IsResettingGui -or
        $script:IsResettingAuditSession -or
        $script:IsOperationRunning -or
        $script:AssignImageYes.IsChecked -ne $true -or
        $null -eq $script:Collection.SelectedItem -or
        $null -eq $script:PvsStore.SelectedItem) {
        return $false
    }

    return (([guid]$script:Collection.SelectedItem.SiteId -eq [guid]$Request.SiteId) -and
        ([guid]$script:PvsStore.SelectedItem.StoreId -eq [guid]$Request.StoreId))
}

function Set-PvsImageChoicesFromResult {
    <# Validates and publishes one cache or worker result on the WPF dispatcher. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Request,
        [AllowEmptyCollection()][object[]]$Candidates = @(),
        [AllowEmptyCollection()][string[]]$Exclusions = @(),
        [Parameter(Mandatory = $true)][ValidateSet('cache','background PVS query','background cache')][string]$Source,
        [long]$DurationMs = -1,

        [switch]$CacheOnly
    )

    $candidateList = New-Object 'System.Collections.Generic.List[object]'
    $diskIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) {
            throw 'The PVS vDisk query returned an empty candidate record.'
        }
        $candidateSiteId = [guid]$candidate.SiteId
        $candidateStoreId = [guid]$candidate.StoreId
        $candidateDiskId = [guid]$candidate.DiskLocatorId
        if ($candidateSiteId -ne [guid]$Request.SiteId -or
            $candidateStoreId -ne [guid]$Request.StoreId) {
            throw "The PVS vDisk query returned candidate '$($candidate.Name)' outside the selected Site and Store."
        }
        $diskIdKey = $candidateDiskId.ToString('D')
        if (-not $diskIds.Add($diskIdKey)) {
            throw "The PVS vDisk query returned duplicate DiskLocator ID '$diskIdKey'."
        }
        [void]$candidateList.Add($candidate)
    }
    $validatedCandidates = [object[]]@($candidateList.ToArray() | Sort-Object Name)

    if ($Source -in @('background PVS query','background cache')) {
        $script:PvsImageChoicesCache[[string]$Request.CacheKey] = $validatedCandidates
        if ($script:PvsImageChoiceErrors.ContainsKey([string]$Request.CacheKey)) {
            [void]$script:PvsImageChoiceErrors.Remove([string]$Request.CacheKey)
        }
    }
    foreach ($exclusion in @($Exclusions)) {
        Write-RunLog -Level INFO -Stage 'PVS image selection' -Message "Excluded vDisk: $exclusion"
    }

    $durationText = if ($DurationMs -ge 0) { " in $DurationMs ms" } else { '' }
    if ($CacheOnly) {
        if ($validatedCandidates.Count -eq 0) {
            Write-RunLog -Level WARN -Stage 'PVS image cache' -Message "No Production-ready vDisk candidate is available in Store '$($Request.StoreName)'$durationText."
        }
        else {
            Write-RunLog -Level SUCCESS -Stage 'PVS image cache' -Message "Cached $($validatedCandidates.Count) Production-ready vDisk candidate(s) for Store '$($Request.StoreName)'$durationText."
        }
        return $validatedCandidates
    }

    $wasRefreshing = $script:IsRefreshingPvsImageChoices
    $script:IsRefreshingPvsImageChoices = $true
    try {
        $script:SelectedPvsImage = $null
        $script:PvsImage.ItemsSource = $validatedCandidates
        $script:PvsImage.SelectedIndex = -1
    }
    finally {
        $script:IsRefreshingPvsImageChoices = $wasRefreshing
    }

    if ($validatedCandidates.Count -eq 0) {
        Write-RunLog -Level WARN -Stage 'PVS image selection' -Message "No Production-ready vDisk candidate is available from $Source for Store '$($Request.StoreName)'$durationText."
        Set-Status -Text "No Production-ready vDisk is available in Store '$($Request.StoreName)'. Select another Store or set Assign Image to No." -Color 'DarkOrange' -Stage 'PVS image selection'
    }
    else {
        Write-RunLog -Level SUCCESS -Stage 'PVS image selection' -Message "Loaded $($validatedCandidates.Count) Production-ready vDisk candidate(s) from $Source for Store '$($Request.StoreName)'$durationText. No image was auto-selected."
        Set-Status -Text "Loaded $($validatedCandidates.Count) Production-ready vDisk(s) from '$($Request.StoreName)'. Select one for this batch." -Color 'DarkOrange' -Stage 'PVS image selection'
    }
    return $validatedCandidates
}
