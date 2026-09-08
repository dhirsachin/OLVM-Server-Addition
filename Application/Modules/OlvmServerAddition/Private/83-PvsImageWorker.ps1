function Close-PvsImageLoadResources {
    <# Disposes the isolated cache worker only after its pipeline is complete. #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:PvsImageLoadAsyncResult -and
        -not $script:PvsImageLoadAsyncResult.IsCompleted) {
        throw 'The background vDisk reader cannot be disposed before its pipeline has stopped.'
    }

    if ($null -ne $script:PvsImageLoadPollTimer) {
        try { $script:PvsImageLoadPollTimer.Stop() } catch {}
        $script:PvsImageLoadPollTimer = $null
    }
    if ($null -ne $script:PvsImageLoadPowerShell) {
        try { $script:PvsImageLoadPowerShell.Dispose() } catch {}
        $script:PvsImageLoadPowerShell = $null
    }
    if ($null -ne $script:PvsImageLoadRunspace) {
        try { $script:PvsImageLoadRunspace.Close() } catch {}
        try { $script:PvsImageLoadRunspace.Dispose() } catch {}
        $script:PvsImageLoadRunspace = $null
    }
    $script:PvsImageLoadAsyncResult = $null
    $script:PvsImageLoadStopAsyncResult = $null
    $script:PvsImageWarmupState = $null
    $script:PvsImageWarmupResultQueue = $null
    $script:IsPvsImageCacheWarmupActive = $false
}

function Stop-PvsImageCacheWarmup {
    <#
      Requests optional read-only warming to stop. This function never calls
      synchronous Stop/Close/Dispose on a live pipeline and never treats a
      cancellation request as proof that the PVS reader is quiescent.
    #>
    [CmdletBinding()]
    param(
        [switch]$StopActivePipeline,
        [string]$Reason = 'requested'
    )

    if (-not $script:IsPvsImageCacheWarmupActive -and
        $null -eq $script:PvsImageLoadRunspace -and
        $null -eq $script:PvsImageLoadPowerShell) {
        return $true
    }
    if (-not $script:IsPvsImageCacheWarmupActive) {
        return $true
    }
    if ($null -ne $script:PvsImageWarmupState) {
        try { $script:PvsImageWarmupState['StopRequested'] = $true } catch {}
    }
    Write-RecoveryLog -Level INFO -Stage 'PVS image cache' -Message "Requested optional background vDisk cache warming to stop because $Reason. Completed cache entries remain available for this application session."

    if ($StopActivePipeline -and
        $null -ne $script:PvsImageLoadPowerShell -and
        $null -eq $script:PvsImageLoadStopAsyncResult) {
        try {
            # BeginStop returns immediately. Completion is still proved only
            # by the original BeginInvoke result in the Dispatcher poll.
            $script:PvsImageLoadStopAsyncResult = $script:PvsImageLoadPowerShell.BeginStop($null,$null)
        }
        catch {
            Write-RecoveryLog -Level WARN -Stage 'PVS image cache' -Message "The asynchronous cancellation request was not accepted: $($_.Exception.Message) The worker will still stop cooperatively after its current Store query."
        }
    }
    return $false
}

function New-PvsImageWorkerScript {
    <# Builds the complete isolated PVS vDisk worker source from its approved helper closure. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $workerFunctionNames = @(
        'Get-FirstPropertyValue',
        'ConvertTo-StrictBoolean',
        'New-PvsImageIneligibleException',
        'Get-PvsDiskLocatorIdFromObject',
        'Get-PvsImageSnapshot',
        'Get-PvsImageCandidates',
        'New-SerializableErrorIdentity'
    )
    $workerSource = New-Object System.Text.StringBuilder
    [void]$workerSource.AppendLine(@'
param(
    [string]$WorkerPvsSoapServer,
    [object[]]$WorkerRequests,
    [hashtable]$WorkerState,
    $WorkerResultQueue
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
'@)
    foreach ($functionName in $workerFunctionNames) {
        $command = Get-Command -Name $functionName -CommandType Function -ErrorAction Stop
        [void]$workerSource.AppendLine("function $functionName {")
        [void]$workerSource.AppendLine([string]$command.Definition)
        [void]$workerSource.AppendLine('}')
    }
    [void]$workerSource.AppendLine(@'
$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $queried = 0
$failed = 0
$stopped = $false
try {
    if ($null -eq (Get-PSSnapin -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Citrix.PVS.SnapIn -ErrorAction Stop
    }
    $requirements = @(
        [pscustomobject]@{ Name = 'Set-PvsConnection'; Parameters = @('Server') },
        [pscustomobject]@{ Name = 'Get-PvsDiskInfo'; Parameters = @('SiteId','StoreId') },
        [pscustomobject]@{ Name = 'Get-PvsDiskVersion'; Parameters = @('DiskLocatorId') },
        [pscustomobject]@{ Name = 'Get-PvsDiskInventory'; Parameters = @('DiskLocatorId','Version') }
    )
    foreach ($requirement in $requirements) {
        $matches = @(Get-Command -Name $requirement.Name -CommandType Cmdlet -ErrorAction Stop)
        if ($matches.Count -ne 1 -or [string]$matches[0].PSSnapIn.Name -cne 'Citrix.PVS.SnapIn') {
            throw "Background PVS command '$($requirement.Name)' did not resolve uniquely from Citrix.PVS.SnapIn."
        }
        foreach ($parameterName in $requirement.Parameters) {
            if (-not $matches[0].Parameters.ContainsKey($parameterName)) {
                throw "Background PVS command '$($requirement.Name)' does not expose required parameter '$parameterName'."
            }
        }
    }
    Set-PvsConnection -Server $WorkerPvsSoapServer -ErrorAction Stop | Out-Null

    $remaining = New-Object 'System.Collections.Generic.List[object]'
    $requestByKey = @{}
    foreach ($request in @($WorkerRequests)) {
        [void]$remaining.Add($request)
        $requestByKey[[string]$request.CacheKey] = $request
    }
    $successfulKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    while ($remaining.Count -gt 0) {
        if ([bool]$WorkerState['StopRequested']) {
            $stopped = $true
            break
        }
        $selectedIndex = 0
        $priorityKey = [string]$WorkerState['PriorityKey']
        $priorityRequest = $WorkerState['PriorityRequest']
        if ($null -ne $priorityRequest) {
            $priorityKey = [string]$priorityRequest.CacheKey
            $requestByKey[$priorityKey] = $priorityRequest
        }
        if (-not [string]::IsNullOrWhiteSpace($priorityKey)) {
            $priorityIndex = -1
            for ($index = 0; $index -lt $remaining.Count; $index++) {
                if ([string]$remaining[$index].CacheKey -ieq $priorityKey) {
                    $priorityIndex = $index
                    break
                }
            }
            if ($priorityIndex -ge 0 -and $null -ne $priorityRequest) {
                $remaining[$priorityIndex] = $priorityRequest
            }
            if ($priorityIndex -lt 0 -and
                $requestByKey.ContainsKey($priorityKey) -and
                -not $successfulKeys.Contains($priorityKey)) {
                [void]$remaining.Insert(0,$requestByKey[$priorityKey])
                $priorityIndex = 0
            }
            if ($priorityIndex -ge 0) { $selectedIndex = $priorityIndex }
            $WorkerState['PriorityKey'] = ''
            $WorkerState['PriorityRequest'] = $null
        }

        $request = $remaining[$selectedIndex]
        $remaining.RemoveAt($selectedIndex)
        $WorkerState['ActiveKey'] = [string]$request.CacheKey
        $storeTimer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $collection = [pscustomobject]@{
                SiteId   = [guid]$request.SiteId
                SiteName = [string]$request.SiteName
                Display  = [string]$request.CollectionDisplay
            }
            $store = [pscustomobject]@{
                StoreId = [guid]$request.StoreId
                Name    = [string]$request.StoreName
                Display = [string]$request.StoreName
            }
            $queryResult = Get-PvsImageCandidates -Collection $collection -Store $store
            $storeTimer.Stop()
            [void]$successfulKeys.Add([string]$request.CacheKey)
            $queried++
            $selectionRequestId = ''
            if ($null -ne $request.PSObject.Properties['RequestId']) {
                $selectionRequestId = [string]$request.RequestId
            }
            [void]$WorkerResultQueue.Enqueue([pscustomobject]@{
                    Kind              = 'Store'
                    Success           = $true
                    CacheKey          = [string]$request.CacheKey
                    SiteId            = ([guid]$request.SiteId).ToString('D')
                    SiteName          = [string]$request.SiteName
                    CollectionDisplay = [string]$request.CollectionDisplay
                    StoreId           = ([guid]$request.StoreId).ToString('D')
                    StoreName         = [string]$request.StoreName
                    SelectionRequestId = $selectionRequestId
                    Candidates        = [object[]]@($queryResult.Candidates)
                    Exclusions        = [string[]]@($queryResult.Exclusions)
                    ErrorMessage      = ''
                    DurationMs        = [long]$storeTimer.ElapsedMilliseconds
                    ErrorIdentity     = $null
                })
        }
        catch {
            $storeTimer.Stop()
            $failed++
            $selectionRequestId = ''
            if ($null -ne $request.PSObject.Properties['RequestId']) {
                $selectionRequestId = [string]$request.RequestId
            }
            [void]$WorkerResultQueue.Enqueue([pscustomobject]@{
                    Kind              = 'Store'
                    Success           = $false
                    CacheKey          = [string]$request.CacheKey
                    SiteId            = ([guid]$request.SiteId).ToString('D')
                    SiteName          = [string]$request.SiteName
                    CollectionDisplay = [string]$request.CollectionDisplay
                    StoreId           = ([guid]$request.StoreId).ToString('D')
                    StoreName         = [string]$request.StoreName
                    SelectionRequestId = $selectionRequestId
                    Candidates        = [object[]]@()
                    Exclusions        = [string[]]@()
                    ErrorMessage      = [string]$_.Exception.Message
                    DurationMs        = [long]$storeTimer.ElapsedMilliseconds
                    ErrorIdentity     = New-SerializableErrorIdentity `
                        -ErrorRecord $_ `
                        -Disposition 'Retryable'
                })
        }
        finally {
            $WorkerState['ActiveKey'] = ''
        }
    }
}
catch {
    [void]$WorkerResultQueue.Enqueue([pscustomobject]@{
            Kind         = 'Fatal'
            ErrorMessage = [string]$_.Exception.Message
            ErrorIdentity = New-SerializableErrorIdentity `
                -ErrorRecord $_ `
                -Disposition 'RequiresIntervention'
        })
}
finally {
    $totalTimer.Stop()
    [void]$WorkerResultQueue.Enqueue([pscustomobject]@{
            Kind       = 'Complete'
            Queried    = $queried
            Failed     = $failed
            Stopped    = $stopped
            DurationMs = [long]$totalTimer.ElapsedMilliseconds
        })
}
'@)

    return [string]$workerSource.ToString()
}
