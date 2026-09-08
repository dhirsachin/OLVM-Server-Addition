function Show-OlvmServerAdditionApplicationFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$FailureReport
    )

    try { Stop-StartupSplash } catch {}
    $displayMessage = "$($FailureReport.Message)`n`nRun log:`n$script:LogPath"
    if (-not $script:AuditTrailHealthy) {
        $recoveryTranscript = Format-RecoveryLogFallback -MaximumCharacters 8192
        if (-not [string]::IsNullOrWhiteSpace($recoveryTranscript)) {
            $displayMessage += "`n`nProcess-local recovery evidence (not written to the run log):`n$recoveryTranscript"
        }
    }
    try {
        [System.Windows.MessageBox]::Show(
            $displayMessage,
            [string]$FailureReport.Title,
            'OK',
            'Error'
        ) | Out-Null
    }
    catch {
        # Presentation failure must not replace the original fatal error that
        # Start-OlvmServerAdditionGui rethrows after its finally cleanup completes.
        try { Write-Error -Message $displayMessage -ErrorAction Continue } catch {}
    }
}

function Invoke-OlvmServerAdditionApplicationShutdown {
    [CmdletBinding()]
    param()

    Stop-StartupSplash
    if ($null -ne $script:OperationStopwatch) {
        try { $script:OperationStopwatch.Stop() } catch {}
    }
    if ($script:IsPvsImageCacheWarmupActive -or
        $null -ne $script:PvsImageLoadPowerShell -or
        $null -ne $script:PvsImageLoadRunspace) {
        $script:PvsImageDeferredOperation = ''
        $script:IsPvsImageWorkerQuiescing = $false
        $script:IsPvsImageLoadPending = $false
        $script:PvsImageLoadRequest = $null
        $script:PvsImageRestartPriorityRequest = $null
        $null = Stop-PvsImageCacheWarmup -StopActivePipeline -Reason 'the application is closing'
        $workerStopped = (-not $script:IsPvsImageCacheWarmupActive -and
            $null -eq $script:PvsImageLoadAsyncResult)
        if ($null -ne $script:PvsImageLoadAsyncResult) {
            try { $workerStopped = $script:PvsImageLoadAsyncResult.AsyncWaitHandle.WaitOne(5000) } catch {}
        }
        if ($workerStopped) {
            try { Complete-PvsImageBackgroundLoad } catch {
                Write-RecoveryLog -Level WARN -Stage 'PVS image cache' -Message "Final background vDisk reader cleanup reported: $($_.Exception.Message)"
            }
        }
        elseif ($null -ne $script:PvsImageLoadAsyncResult -and
            $script:PvsImageLoadAsyncResult.IsCompleted) {
            try { Complete-PvsImageBackgroundLoad } catch {}
        }
        else {
            Write-RecoveryLog -Level WARN -Stage 'PVS image cache' -Message 'The background vDisk reader did not acknowledge asynchronous shutdown within 5 seconds. No synchronous stop was attempted; process teardown is the final cleanup boundary.'
        }
    }
    try {
        Exit-FarmBuildLock -Lock $script:ActiveFarmBuildLock
    }
    catch {
        Write-RecoveryLog -Level ERROR -Stage 'Farm lock' -Message "Emergency farm-lock release could not be confirmed during application shutdown: $($_.Exception.Message) The process exit remains the final handle-release boundary."
    }
    if ($null -ne $script:LogWriter) {
        $endMessage = if ($script:GuiDisplayed) {
            'GUI session ended; closing this run log.'
        }
        else {
            'Application ended before the GUI was displayed; closing this run log.'
        }
        Write-RecoveryLog -Level INFO -Stage 'Run' -Message $endMessage
    }
    Close-RunLog
    Exit-ApplicationInstanceLock
}
