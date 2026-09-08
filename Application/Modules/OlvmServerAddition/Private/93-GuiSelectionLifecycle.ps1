function Defer-GuiOperationForPvsImageWorker {
    <#
      Returns true only when the requested GUI operation was deferred. The
      operation is resumed from the Dispatcher after EndInvoke and resource
      cleanup prove that the separate PVS reader is no longer running.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Validation','Provisioning','Reset')]
        [string]$Operation
    )

    if ($script:IsPvsImageWorkerQuiescing) { return $true }
    if ($script:IsPvsImageCacheWarmupActive) {
        # Drain first so an already completed pipeline is finalized rather
        # than needlessly entering the deferred state.
        Complete-PvsImageBackgroundLoad
    }
    if (-not $script:IsPvsImageCacheWarmupActive) { return $false }

    $script:PvsImageDeferredOperation = $Operation
    $script:PvsImageDeferredCreateWasEnabled = [bool]$script:Create.IsEnabled
    $script:IsPvsImageWorkerQuiescing = $true
    $script:PvsImageQuiesceStartedUtc = [DateTime]::UtcNow
    $script:PvsImageQuiesceTimeoutReported = $false
    $displayName = if ($Operation -eq 'Provisioning') { 'Build' } else { $Operation }
    $null = Stop-PvsImageCacheWarmup `
        -StopActivePipeline `
        -Reason "$displayName is waiting to start"
    Set-UiBusy -Busy $true
    Set-Status -Text "Preparing $displayName..." -Color 'DarkOrange' -Stage 'PVS image cache'
    $script:ExecutionNote.Text = "Waiting for the background vDisk reader to close safely before $displayName starts."
    $script:ExecutionNote.Foreground = 'DarkOrange'
    return $true
}

function Invoke-DeferredGuiOperation {
    <# Resumes one operator action only after the PVS reader is fully closed. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Validation','Provisioning','Reset')][string]$Operation)

    $createWasEnabled = [bool]$script:PvsImageDeferredCreateWasEnabled
    $script:PvsImageDeferredOperation = ''
    $script:PvsImageDeferredCreateWasEnabled = $false
    $script:IsPvsImageWorkerQuiescing = $false
    $script:PvsImageQuiesceStartedUtc = $null
    $script:PvsImageQuiesceTimeoutReported = $false
    Set-UiBusy -Busy $false
    Set-ExecutionStatusVisibility -Visible $false

    if (-not $script:AuditTrailHealthy -or
        $script:IsPvsImageCacheWarmupActive -or
        $null -ne $script:PvsImageLoadPowerShell -or
        $null -ne $script:PvsImageLoadRunspace -or
        $null -ne $script:PvsImageLoadAsyncResult) {
        $script:Create.IsEnabled = ($createWasEnabled -and $script:AuditTrailHealthy)
        Write-RecoveryLog -Level ERROR -Stage 'PVS image cache' -Message "$Operation was not started because the background vDisk reader could not be proved fully stopped."
        [System.Windows.MessageBox]::Show(
            $script:Window,
            "$Operation was not started because the background vDisk reader could not be closed safely.`n`nThe requested action did not run. Review the run log and try again.",
            'Operation not started',
            'OK',
            'Error'
        ) | Out-Null
        return
    }

    $script:Create.IsEnabled = ($createWasEnabled -and $script:AuditTrailHealthy)
    switch ($Operation) {
        'Validation' {
            $script:Preview.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }
        'Provisioning' {
            $script:Create.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
        }
        'Reset' {
            Invoke-ManualResetGuiCore
        }
    }
}

function Complete-PvsImageSelectedWaitState {
    <# Releases the existing foreground lock while passive cache warming may continue. #>
    [CmdletBinding()]
    param()

    $script:IsPvsImageLoadPending = $false
    $script:PvsImageLoadRequest = $null
    $script:PvsImageSelectedLoadStartedUtc = $null
    $script:PvsImageSelectedLoadTimeoutReported = $false
    $script:PvsImageRestartPriorityRequest = $null
    if ($null -ne $script:Window) { $script:Window.Cursor = $null }
    try { Set-UiBusy -Busy $false } catch {}
    try { Set-ExecutionStatusVisibility -Visible $false } catch {}
    try { Sync-OptionalImagePowerUiState } catch {}
}

function Show-PvsImageSelectedLoadFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Request,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Message
    )

    Write-RecoveryLog -Level ERROR -Stage 'PVS image selection' -Message "Background vDisk discovery failed for Store '$($Request.StoreName)': $Message"
    $storeSelectionCleared = $false
    if ($script:AuditTrailHealthy) {
        $wasRefreshing = $script:IsRefreshingPvsImageChoices
        $script:IsRefreshingPvsImageChoices = $true
        try {
            $script:SelectedPvsImage = $null
            $script:PvsImage.ItemsSource = @()
            $script:PvsImage.SelectedIndex = -1
            $script:PvsStore.SelectedIndex = -1
            $storeSelectionCleared = $true
        }
        finally {
            $script:IsRefreshingPvsImageChoices = $wasRefreshing
        }
    }
    Complete-PvsImageSelectedWaitState
    $failureGuidance = if ($script:AuditTrailHealthy -and $storeSelectionCleared) {
        'The Store selection was cleared. Select it again to retry, choose another Store, or set Assign Image to No.'
    }
    elseif ($script:AuditTrailHealthy) {
        'Choose another Store, or switch Assign Image to No and back to Yes before retrying.'
    }
    else {
        "The run log is unavailable, so all further actions are disabled. Close and reopen the tool, then review '$script:LogPath'."
    }
    [System.Windows.MessageBox]::Show(
        $script:Window,
        "$Message`n`nNo vDisk was selected. $failureGuidance",
        'PVS image selection',
        'OK',
        'Error'
    ) | Out-Null
}

function Receive-PvsImageBackgroundEnvelope {
    <# Publishes exactly one worker envelope while the Dispatcher guard is held. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Envelope)

    $kind = [string]$Envelope.Kind
    if ($kind -eq 'Fatal') {
        $script:PvsImageWarmupTerminalError = [string]$Envelope.ErrorMessage
        return
    }
    if ($kind -eq 'Complete') {
        $script:PvsImageWarmupTerminalEnvelope = $Envelope
        return
    }
    if ($kind -ne 'Store') { return }

    $request = [pscustomobject]@{
        CacheKey          = [string]$Envelope.CacheKey
        SiteId            = [guid]$Envelope.SiteId
        SiteName          = [string]$Envelope.SiteName
        CollectionDisplay = [string]$Envelope.CollectionDisplay
        StoreId           = [guid]$Envelope.StoreId
        StoreName         = [string]$Envelope.StoreName
    }
    $isCurrent = $false
    if ($script:IsPvsImageLoadPending -and
        $null -ne $script:PvsImageLoadRequest -and
        [string]$script:PvsImageLoadRequest.CacheKey -ieq [string]$request.CacheKey) {
        try { $isCurrent = Test-PvsImageLoadRequestCurrent -Request $script:PvsImageLoadRequest }
        catch { $isCurrent = $true }
    }
    $selectionRequestId = ''
    if ($null -ne $Envelope.PSObject.Properties['SelectionRequestId']) {
        $selectionRequestId = [string]$Envelope.SelectionRequestId
    }
    $failureBelongsToCurrentSelection = ($isCurrent -and
        -not [string]::IsNullOrWhiteSpace($selectionRequestId) -and
        [string]$script:PvsImageLoadRequest.RequestId -ceq $selectionRequestId)
    $currentSelectionRequest = if ($isCurrent) { $script:PvsImageLoadRequest } else { $null }

    if ($Envelope.Success -eq $true) {
        try {
            if ($isCurrent) {
                $published = @(Set-PvsImageChoicesFromResult `
                        -Request $currentSelectionRequest `
                        -Candidates ([object[]]@($Envelope.Candidates)) `
                        -Exclusions ([string[]]@($Envelope.Exclusions)) `
                        -Source 'background PVS query' `
                        -DurationMs ([long]$Envelope.DurationMs))
                $showNoCandidates = ($published.Count -eq 0)
                $selectedStoreName = [string]$currentSelectionRequest.StoreName
                Complete-PvsImageSelectedWaitState
                if ($showNoCandidates) {
                    [System.Windows.MessageBox]::Show(
                        $script:Window,
                        "No Production-ready vDisk is available in Store '$selectedStoreName'.`n`nChoose another Store or set Assign Image to No.",
                        'No eligible vDisk found',
                        'OK',
                        'Information'
                    ) | Out-Null
                }
            }
            else {
                $null = @(Set-PvsImageChoicesFromResult `
                        -Request $request `
                        -Candidates ([object[]]@($Envelope.Candidates)) `
                        -Exclusions ([string[]]@($Envelope.Exclusions)) `
                        -Source 'background cache' `
                        -DurationMs ([long]$Envelope.DurationMs) `
                        -CacheOnly)
            }
        }
        catch {
            $message = "The vDisk cache result for Store '$($request.StoreName)' was rejected: $($_.Exception.Message)"
            if ($script:PvsImageChoicesCache.ContainsKey([string]$request.CacheKey)) {
                [void]$script:PvsImageChoicesCache.Remove([string]$request.CacheKey)
            }
            $script:PvsImageChoiceErrors[[string]$request.CacheKey] = [pscustomobject]@{
                ErrorMessage = $message
                FailedAtUtc  = [DateTime]::UtcNow
            }
            if ($failureBelongsToCurrentSelection) {
                Show-PvsImageSelectedLoadFailure -Request $currentSelectionRequest -Message $message
            }
            else {
                Write-RecoveryLog -Level WARN -Stage 'PVS image cache' -Message $message
            }
        }
        return
    }

    $message = [string]$Envelope.ErrorMessage
    $script:PvsImageChoiceErrors[[string]$request.CacheKey] = [pscustomobject]@{
        ErrorMessage = $message
        FailedAtUtc  = [DateTime]::UtcNow
    }
    if ($failureBelongsToCurrentSelection) {
        Show-PvsImageSelectedLoadFailure -Request $currentSelectionRequest -Message $message
    }
    else {
        $retryNote = if ($isCurrent) {
            ' The user-selected retry remains queued and this earlier background failure will not complete it.'
        }
        else {
            ' Selecting that Store will retry it.'
        }
        Write-RecoveryLog -Level WARN -Stage 'PVS image cache' -Message "Optional background vDisk discovery failed for Store '$($request.StoreName)' after $($Envelope.DurationMs) ms: $message$retryNote"
    }
}

function Complete-PvsImageBackgroundLoad {
    <# Drains per-Store results on the WPF Dispatcher while one worker remains sequential. #>
    [CmdletBinding()]
    param()

    if (-not $script:IsPvsImageCacheWarmupActive -or
        $null -eq $script:PvsImageWarmupResultQueue) {
        return
    }
    if ($script:IsCompletingPvsImageBackgroundLoad) { return }
    $script:IsCompletingPvsImageBackgroundLoad = $true
    try {

    $envelope = $null
    while ($script:PvsImageWarmupResultQueue.TryDequeue([ref]$envelope)) {
        if ($null -ne $envelope) {
            Receive-PvsImageBackgroundEnvelope -Envelope $envelope
        }
        $envelope = $null
    }

    if ($null -eq $script:PvsImageLoadAsyncResult -or
        -not $script:PvsImageLoadAsyncResult.IsCompleted) {
        if ($script:IsPvsImageLoadPending -and
            $null -ne $script:PvsImageLoadRequest -and
            $null -ne $script:PvsImageSelectedLoadStartedUtc -and
            -not $script:PvsImageSelectedLoadTimeoutReported -and
            ([DateTime]::UtcNow - [DateTime]$script:PvsImageSelectedLoadStartedUtc).TotalSeconds -ge
                $script:PvsImageSelectedLoadTimeoutSeconds) {
            $script:PvsImageSelectedLoadTimeoutReported = $true
            $timedOutRequest = $script:PvsImageLoadRequest
            $null = Stop-PvsImageCacheWarmup `
                -StopActivePipeline `
                -Reason "the selected Store '$($timedOutRequest.StoreName)' exceeded its loading limit"
            Show-PvsImageSelectedLoadFailure `
                -Request $timedOutRequest `
                -Message "Loading vDisks from Store '$($timedOutRequest.StoreName)' exceeded $($script:PvsImageSelectedLoadTimeoutSeconds) seconds and was cancelled."
        }
        if ($script:IsPvsImageWorkerQuiescing -and
            $null -ne $script:PvsImageQuiesceStartedUtc -and
            -not $script:PvsImageQuiesceTimeoutReported -and
            ([DateTime]::UtcNow - [DateTime]$script:PvsImageQuiesceStartedUtc).TotalSeconds -ge
                $script:PvsImageQuiesceTimeoutSeconds) {
            $script:PvsImageQuiesceTimeoutReported = $true
            $deferredOperation = [string]$script:PvsImageDeferredOperation
            $deferredDisplayName = if ($deferredOperation -eq 'Provisioning') { 'Build' } else { $deferredOperation }
            $createWasEnabled = [bool]$script:PvsImageDeferredCreateWasEnabled
            $script:PvsImageDeferredOperation = ''
            $script:PvsImageDeferredCreateWasEnabled = $false
            $script:IsPvsImageWorkerQuiescing = $false
            $script:PvsImageQuiesceStartedUtc = $null
            Set-UiBusy -Busy $false
            $script:Create.IsEnabled = ($createWasEnabled -and $script:AuditTrailHealthy)
            Set-ExecutionStatusVisibility -Visible $false
            Write-RecoveryLog -Level ERROR -Stage 'PVS image cache' -Message "$deferredDisplayName was not started because the background vDisk reader did not stop within $($script:PvsImageQuiesceTimeoutSeconds) seconds. The requested action did not run."
            [System.Windows.MessageBox]::Show(
                $script:Window,
                "$deferredDisplayName was not started because the background vDisk reader did not close within $($script:PvsImageQuiesceTimeoutSeconds) seconds.`n`nThe requested action did not run. Wait for the reader to finish or close and reopen the tool.",
                'Operation not started',
                'OK',
                'Error'
            ) | Out-Null
        }
        return
    }

    # The worker can enqueue its final Store/Fatal/Complete records between
    # the first drain and the IsCompleted observation above. Once completed,
    # no more records can arrive, so this second drain closes that race before
    # the queue and terminal state are snapshotted and disposed.
    $envelope = $null
    while ($script:PvsImageWarmupResultQueue.TryDequeue([ref]$envelope)) {
        if ($null -ne $envelope) {
            Receive-PvsImageBackgroundEnvelope -Envelope $envelope
        }
        $envelope = $null
    }

    if ($null -ne $script:PvsImageLoadPollTimer) {
        $script:PvsImageLoadPollTimer.Stop()
    }
    $worker = $script:PvsImageLoadPowerShell
    $asyncResult = $script:PvsImageLoadAsyncResult
    $terminalEnvelope = $script:PvsImageWarmupTerminalEnvelope
    $terminalError = [string]$script:PvsImageWarmupTerminalError
    try {
        if ($null -ne $script:PvsImageLoadStopAsyncResult -and
            $script:PvsImageLoadStopAsyncResult.IsCompleted) {
            try { $worker.EndStop($script:PvsImageLoadStopAsyncResult) } catch {}
        }
        $unexpectedOutput = @($worker.EndInvoke($asyncResult))
        if ($worker.Streams.Error.Count -gt 0 -and [string]::IsNullOrWhiteSpace($terminalError)) {
            $terminalError = [string]$worker.Streams.Error[0].Exception.Message
        }
        if ($unexpectedOutput.Count -gt 0 -and [string]::IsNullOrWhiteSpace($terminalError)) {
            $terminalError = "The background vDisk cache worker returned $($unexpectedOutput.Count) unexpected pipeline object(s)."
        }
    }
    catch {
        if ([string]::IsNullOrWhiteSpace($terminalError)) {
            $terminalError = $_.Exception.Message
        }
    }
    finally {
        Close-PvsImageLoadResources
    }
    $script:PvsImageWarmupTerminalEnvelope = $null
    $script:PvsImageWarmupTerminalError = ''

    if ($null -ne $terminalEnvelope) {
        $level = if ([int]$terminalEnvelope.Failed -gt 0 -or
            -not [string]::IsNullOrWhiteSpace($terminalError)) { 'WARN' } else { 'SUCCESS' }
        $errorSuffix = if (-not [string]::IsNullOrWhiteSpace($terminalError)) {
            " Error=$terminalError"
        }
        else { '' }
        Write-RecoveryLog -Level $level -Stage 'PVS image cache' -Message "Background vDisk cache warming finished in $($terminalEnvelope.DurationMs) ms. Queried=$($terminalEnvelope.Queried); Failed=$($terminalEnvelope.Failed); Stopped=$($terminalEnvelope.Stopped).$errorSuffix"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($terminalError)) {
        Write-RecoveryLog -Level WARN -Stage 'PVS image cache' -Message "Background vDisk cache warming stopped unexpectedly: $terminalError"
    }

    if ($script:IsPvsImageLoadPending -and
        $null -ne $script:PvsImageLoadRequest -and
        $null -ne $script:PvsImageRestartPriorityRequest) {
        $restartRequest = $script:PvsImageRestartPriorityRequest
        # Permit only one terminal restart. A worker-level fatal on this retry
        # must surface to the selected-Store failure path, not loop forever.
        $script:PvsImageRestartPriorityRequest = $null
        try {
            $started = [bool](Start-PvsImageCacheWarmup -PriorityRequest $restartRequest)
            if ($started) { return }
            throw "The selected Store retry worker did not start."
        }
        catch {
            Show-PvsImageSelectedLoadFailure `
                -Request $script:PvsImageLoadRequest `
                -Message "The vDisk list for Store '$($restartRequest.StoreName)' could not be restarted: $($_.Exception.Message)"
            return
        }
    }

    if ($script:IsPvsImageLoadPending -and $null -ne $script:PvsImageLoadRequest) {
        $pendingRequest = $script:PvsImageLoadRequest
        $message = if (-not [string]::IsNullOrWhiteSpace($terminalError)) {
            $terminalError
        }
        else {
            "The background vDisk cache ended before Store '$($pendingRequest.StoreName)' was loaded."
        }
        Show-PvsImageSelectedLoadFailure -Request $pendingRequest -Message $message
        return
    }

    if ($script:IsPvsImageWorkerQuiescing -and
        -not [string]::IsNullOrWhiteSpace([string]$script:PvsImageDeferredOperation)) {
        $operation = [string]$script:PvsImageDeferredOperation
        Invoke-DeferredGuiOperation -Operation $operation
    }
    }
    finally {
        $script:IsCompletingPvsImageBackgroundLoad = $false
    }
}

function Start-PvsImageCacheWarmup {
    <# Starts one read-only worker that checks every missing Site and Store sequentially. #>
    [CmdletBinding()]
    param(
        [string]$PriorityCacheKey = '',
        [AllowNull()][psobject]$PriorityRequest = $null
    )

    if ($null -ne $PriorityRequest) {
        $PriorityCacheKey = [string]$PriorityRequest.CacheKey
    }

    if ($script:IsPvsImageCacheWarmupActive) {
        if (-not [string]::IsNullOrWhiteSpace($PriorityCacheKey) -and
            $null -ne $script:PvsImageWarmupState) {
            if ($null -ne $PriorityRequest) {
                $script:PvsImageWarmupState['PriorityRequest'] = $PriorityRequest
            }
            # PriorityKey is the cross-runspace readiness flag and is written
            # last so the worker cannot observe a key before its request.
            $script:PvsImageWarmupState['PriorityKey'] = $PriorityCacheKey
        }
        return $false
    }
    if ($script:IsOperationRunning -or $script:IsResettingAuditSession) {
        return $false
    }
    Assert-AuditTrailAvailable

    $requests = @($script:PvsImageWarmupRequests | Where-Object {
            -not $script:PvsImageChoicesCache.ContainsKey([string]$_.CacheKey)
        })
    if ($requests.Count -eq 0) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($PriorityCacheKey)) {
        $priority = @($requests | Where-Object { [string]$_.CacheKey -ieq $PriorityCacheKey })
        $remaining = @($requests | Where-Object { [string]$_.CacheKey -ine $PriorityCacheKey })
        $requests = @($priority + $remaining)
    }

    $workerSource = New-PvsImageWorkerScript

    $runspace = $null
    $worker = $null
    $pollTimer = $null
    $asyncResult = $null
    try {
        $state = [hashtable]::Synchronized(@{
                StopRequested = $false
                PriorityKey   = $PriorityCacheKey
                PriorityRequest = $PriorityRequest
                ActiveKey     = ''
            })
        $resultQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.Runspace = $runspace
        [void]$worker.AddScript($workerSource.ToString())
        [void]$worker.AddArgument([string]$script:PvsSoapServer)
        [void]$worker.AddArgument([object[]]$requests)
        [void]$worker.AddArgument($state)
        [void]$worker.AddArgument($resultQueue)

        $pollTimer = New-Object System.Windows.Threading.DispatcherTimer
        $pollTimer.Interval = [TimeSpan]::FromMilliseconds(150)
        $pollTimer.Add_Tick({ Complete-PvsImageBackgroundLoad })
        Write-RunLog -Level INFO -Stage 'PVS image cache' -Message "Starting sequential background warming for $($requests.Count) uncached PVS Store(s). The GUI remains available; successful results are cached by immutable Site and Store IDs."
        $script:PvsImageLoadRunspace = $runspace
        $script:PvsImageLoadPowerShell = $worker
        $script:PvsImageLoadAsyncResult = $null
        $script:PvsImageLoadPollTimer = $pollTimer
        $script:PvsImageWarmupState = $state
        $script:PvsImageWarmupResultQueue = $resultQueue
        $script:PvsImageWarmupTerminalEnvelope = $null
        $script:PvsImageWarmupTerminalError = ''
        $script:PvsImageLoadStopAsyncResult = $null
        $script:IsPvsImageCacheWarmupActive = $true
        $pollTimer.Start()
        # The Dispatcher cannot tick until this GUI event returns, so starting
        # its poller before BeginInvoke removes the only live-worker/no-poller
        # setup window without exposing a null async result to the callback.
        $asyncResult = $worker.BeginInvoke()
        $script:PvsImageLoadAsyncResult = $asyncResult
        return $true
    }
    catch {
        if ($null -ne $pollTimer) { try { $pollTimer.Stop() } catch {} }
        $pipelineLive = ($null -ne $asyncResult -and -not $asyncResult.IsCompleted)
        if ($pipelineLive) {
            # Retain every handle so later dispatcher activity can prove
            # completion and dispose safely. Never synchronously stop a live
            # Citrix pipeline from this GUI-thread error path.
            $script:PvsImageLoadRunspace = $runspace
            $script:PvsImageLoadPowerShell = $worker
            $script:PvsImageLoadAsyncResult = $asyncResult
            $script:PvsImageLoadPollTimer = $pollTimer
            $script:PvsImageWarmupState = $state
            $script:PvsImageWarmupResultQueue = $resultQueue
            $script:IsPvsImageCacheWarmupActive = $true
            try { $state['StopRequested'] = $true } catch {}
            try {
                $script:PvsImageLoadStopAsyncResult = $worker.BeginStop($null,$null)
            }
            catch {}
            try { $pollTimer.Start() } catch {}
        }
        else {
            if ($null -ne $worker -and $null -ne $asyncResult) {
                try { $null = $worker.EndInvoke($asyncResult) } catch {}
            }
            if ($null -ne $worker) { try { $worker.Dispose() } catch {} }
            if ($null -ne $runspace) { try { $runspace.Dispose() } catch {} }
            $script:PvsImageLoadRunspace = $null
            $script:PvsImageLoadPowerShell = $null
            $script:PvsImageLoadAsyncResult = $null
            $script:PvsImageLoadPollTimer = $null
            $script:PvsImageLoadStopAsyncResult = $null
            $script:IsPvsImageCacheWarmupActive = $false
            $script:PvsImageWarmupState = $null
            $script:PvsImageWarmupResultQueue = $null
            $script:PvsImageWarmupTerminalEnvelope = $null
            $script:PvsImageWarmupTerminalError = ''
        }
        throw
    }
}

function Start-PvsImagesForSelectedStoreLoad {
    <# Uses the session cache or prioritizes this Store in the shared worker. #>
    [CmdletBinding()]
    param()

    if ($script:IsPvsImageLoadPending) {
        throw 'A PVS vDisk list is already loading. Wait for it to finish before selecting another Store.'
    }
    if ($script:IsOperationRunning) {
        throw 'A PVS vDisk list cannot be loaded while Validation or Build is running.'
    }
    Assert-AuditTrailAvailable
    if ($script:IsPvsImageCacheWarmupActive) {
        # Publish any just-completed result before deciding whether this Store
        # is a cache hit or an explicit retry.
        Complete-PvsImageBackgroundLoad
    }

    $collection = $script:Collection.SelectedItem
    $store = $script:PvsStore.SelectedItem
    if ($null -eq $collection -or $null -eq $store) {
        return $false
    }
    $siteId = [guid]$collection.SiteId
    $storeId = [guid]$store.StoreId
    $cacheKey = Get-PvsImageChoiceCacheKey -SiteId $siteId -StoreId $storeId
    $script:PvsImageLoadGeneration++
    $request = [pscustomobject]@{
        RequestId         = [guid]::NewGuid().ToString('N')
        Generation        = [long]$script:PvsImageLoadGeneration
        RunId             = [string]$script:RunId
        CacheKey          = $cacheKey
        SiteId            = $siteId
        SiteName          = [string]$collection.SiteName
        CollectionDisplay = [string]$collection.Display
        StoreId           = $storeId
        StoreName         = [string]$store.Name
    }
    Add-PvsImageWarmupRequest -Request $request

    if ($script:PvsImageChoicesCache.ContainsKey($cacheKey)) {
        $cachedCandidates = [object[]]$script:PvsImageChoicesCache[$cacheKey]
        $publishedCandidates = @(Set-PvsImageChoicesFromResult `
                -Request $request `
                -Candidates $cachedCandidates `
                -Exclusions @() `
                -Source 'cache')
        Sync-OptionalImagePowerUiState
        if ($publishedCandidates.Count -eq 0) {
            [System.Windows.MessageBox]::Show(
                $script:Window,
                "No Production-ready vDisk is available in Store '$($request.StoreName)'.`n`nChoose another Store or set Assign Image to No.",
                'No eligible vDisk found',
                'OK',
                'Information'
            ) | Out-Null
        }
        return $false
    }

    if ($script:PvsImageChoiceErrors.ContainsKey($cacheKey)) {
        Write-RunLog -Level INFO -Stage 'PVS image selection' -Message "Retrying background vDisk discovery for Store '$($request.StoreName)' after its earlier cache attempt failed."
    }
    else {
        Write-RunLog -Level INFO -Stage 'PVS image selection' -Message "Prioritizing Store '$($request.StoreName)' in the sequential background vDisk cache."
    }

    $script:PvsImageLoadRequest = $request
    $script:PvsImageRestartPriorityRequest = $request
    $script:IsPvsImageLoadPending = $true
    $script:PvsImageSelectedLoadStartedUtc = [DateTime]::UtcNow
    $script:PvsImageSelectedLoadTimeoutReported = $false
    try {
        if ($script:IsPvsImageCacheWarmupActive) {
            $script:PvsImageWarmupState['PriorityRequest'] = $request
            $script:PvsImageWarmupState['PriorityKey'] = $cacheKey
        }
        else {
            $null = Start-PvsImageCacheWarmup -PriorityRequest $request
            if (-not $script:IsPvsImageCacheWarmupActive) {
                throw "The background vDisk cache could not be started for Store '$($request.StoreName)'."
            }
        }

        $script:Status.Text = "Loading vDisks from Store '$($request.StoreName)'..."
        $script:Status.Foreground = 'DarkOrange'
        $script:ExecutionNote.Text = ''
        Set-ExecutionStatusVisibility -Visible $true
        $script:ExecutionNote.Visibility = 'Collapsed'
        Set-UiBusy -Busy $true
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        return $true
    }
    catch {
        Complete-PvsImageSelectedWaitState
        throw
    }
}
function Reset-GuiForNewBuild {
    <# Starts a clean input/results session while preserving loaded modules. #>
    [CmdletBinding()]
    param(
        [ValidateSet('PostRunChoice','ManualReset')]
        [string]$Reason = 'PostRunChoice'
    )

    if ($script:IsOperationRunning) {
        throw 'A new build cannot start while an operation is running.'
    }
    if ($script:IsPvsImageLoadPending) {
        throw 'A new build cannot start while the selected PVS Store vDisk list is loading.'
    }
    if ($script:IsResettingAuditSession) {
        throw 'A reset is already in progress.'
    }
    if ($null -ne $script:ActiveFarmBuildLock) {
        throw 'A new build cannot start while the farm-wide Build lock is still held.'
    }
    Assert-AuditTrailAvailable
    if ($script:IsPvsImageCacheWarmupActive -or
        $script:IsPvsImageWorkerQuiescing -or
        $null -ne $script:PvsImageLoadPowerShell -or
        $null -ne $script:PvsImageLoadRunspace -or
        $null -ne $script:PvsImageLoadAsyncResult) {
        throw 'A new build cannot start until the background vDisk reader has stopped and released its PVS session.'
    }
    $previousRunId = [string]$script:RunId
    $previousLogPath = [string]$script:LogPath
    $validationBuildState = Get-ValidationBuildState
    $previousResultCount = @($validationBuildState.ValidationRecords).Count
    $previousPlanCount = @($validationBuildState.BuildContexts).Count
    $script:IsResettingAuditSession = $true
    try {
        if ($Reason -eq 'ManualReset') {
            Write-RunLog -Level INFO -Stage 'Reset' -Message "Operator confirmed Reset. Closing the current audit session and creating a new Run ID and log before clearing all current inputs, selections, Validation state, and displayed Results. VisibleResultCount=$previousResultCount; RetainedPlanCount=$previousPlanCount."
        }
        else {
            Write-RunLog -Level INFO -Stage 'Post-run choice' -Message "Operator selected Start New Build. Closing this completed audit session and creating a new Run ID and log. VisibleResultCount=$previousResultCount; RetainedPlanCount=$previousPlanCount."
        }
        Close-RunLogForRotation
        try {
            Start-RunAuditSession -GenerateNewRunId
        }
        catch {
            $script:AuditTrailHealthy = $false
            $attemptedLogPath = [string]$script:LogPath
            throw "A new audit session could not be started. The previous run remains saved under Run ID '$previousRunId' at '$previousLogPath'. Attempted new log path: '$attemptedLogPath'. $($_.Exception.Message)"
        }

        $script:IsCompletedRunReviewMode = $false
        $script:IsResettingGui = $true
        try {
        Set-ValidationBuildState -ValidationRecords ([object[]]@()) -BuildContexts $null
        # Store inventory is retained, but Reset refreshes the optional vDisk
        # inventory so a newly promoted or newly added Production-ready image
        # can appear without closing the application. Validation still
        # rechecks the selected vDisk authoritatively before any write.
        $script:PvsImageChoicesCache = @{}
        $script:PvsImageChoiceErrors = @{}
        $script:OuChoicesCache = @{}
        $script:OuChoiceView = $null
        $script:OuSearchText = ''
        Reset-SelectionOlvmRouteCache

        $script:ServerList.Text = ''
        $script:Collection.SelectedIndex = -1
        $script:PvsStore.ItemsSource = @()
        $script:PvsStore.SelectedIndex = -1
        $script:PvsImage.ItemsSource = @()
        $script:PvsImage.SelectedIndex = -1
        $script:SelectedPvsImage = $null
        $script:OuSelector.SelectedIndex = -1
        $script:OuSelector.ItemsSource = @()
        $script:OuSelector.Text = ''
        if ($null -ne $script:OuEditableTextBox) { $script:OuEditableTextBox.Text = '' }
        $script:OrganizationalUnit.Text = ''
        $script:AdDnsDomain.Text = Get-SelectionDefaultDnsDomain
        $null = Initialize-OuChoicesForCurrentDomain -Source 'New build'

        $script:AssignImageYes.IsChecked = $false
        $script:AssignImageNo.IsChecked = $true
        foreach ($radioButton in @(
                $script:BootBios,$script:BootUefi,$script:PvsCaseUpper,$script:PvsCaseLower,
                $script:DhcpCaseUpper,$script:DhcpCaseLower,$script:ReservationHost,$script:ReservationFqdn)) {
            $radioButton.IsChecked = $false
        }
        Reset-PowerOnChoice
        $script:OlvmManager.SelectedIndex = 0
        Sync-OptionalImagePowerUiState

        $script:Progress.Value = 0
        $script:Progress.Visibility = 'Collapsed'
        $script:Status.Text = ''
        $script:Status.Visibility = 'Collapsed'
        $script:ExecutionNote.Text = ''
        $script:ExecutionNote.Visibility = 'Collapsed'
        $script:Create.IsEnabled = $false
        $script:Preview.IsEnabled = $true
        $script:ViewDetails.IsEnabled = $false
        Refresh-Grid
        $script:OpenLog.ToolTip = "Open the current run log in Notepad: $script:LogPath"
        }
        finally {
            $script:IsResettingGui = $false
        }
        Set-UiBusy -Busy $false
        Update-ApplicationLockMetadata
        $resetSource = if ($Reason -eq 'ManualReset') { 'the Reset button' } else { 'Start New Build' }
        Write-RunLog -Level SUCCESS -Stage 'New build' -Message "The GUI was reset to safe defaults through $resetSource. PreviousRunId=$previousRunId; PreviousLog='$previousLogPath'. Loaded trusted modules, Device Collections, PVS Store inventory, and OLVM Manager inventory were retained; the optional vDisk cache will be refreshed in the background."
    }
    catch {
        # A partially completed in-process reset must never leave Validation or
        # Build enabled against an uncertain Run ID or audit-log boundary.
        $script:AuditTrailHealthy = $false
        throw
    }
    finally {
        $script:IsResettingAuditSession = $false
        $resetVariable = Get-Variable -Name Reset -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $resetVariable) {
            $resetVariable.Value.IsEnabled = ($script:AuditTrailHealthy -and
                -not $script:IsOperationRunning -and
                -not $script:IsPvsImageLoadPending -and
                $null -eq $script:ActiveFarmBuildLock)
        }
        if ($script:AuditTrailHealthy -and
            -not $script:IsOperationRunning -and
            -not $script:IsPvsImageLoadPending -and
            $script:GuiDisplayed) {
            try { $null = Start-PvsImageCacheWarmup }
            catch {
                Write-RecoveryLog -Level WARN -Stage 'PVS image cache' -Message "Optional background vDisk cache warming could not be restarted for the new build: $($_.Exception.Message) Selecting a Store will retry it on demand."
            }
        }
    }
}

function Invoke-ManualResetGuiCore {
    <# Runs a Reset that has already been confirmed by the operator. #>
    [CmdletBinding()]
    param()

    try {
        Reset-GuiForNewBuild -Reason ManualReset
    }
    catch {
        $resetError = $_.Exception.Message
        Write-RecoveryLog -Level ERROR -Stage 'Reset' -Message $resetError
        Set-UiBusy -Busy $false
        [System.Windows.MessageBox]::Show(
            $script:Window,
            "$resetError`n`nThe reset could not be completed safely. Close and reopen the application before attempting another run.",
            'Reset could not be completed',
            'OK',
            'Error'
        ) | Out-Null
    }
}
