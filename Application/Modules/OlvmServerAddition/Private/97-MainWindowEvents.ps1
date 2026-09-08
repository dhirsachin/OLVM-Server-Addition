function Register-OlvmServerAdditionImportEvents {
    [CmdletBinding()]
    param()

    $script:ImportServers.Add_Click({
            if ($script:IsOperationRunning -or $script:IsPvsImageLoadPending) { return }

            $fileDialog = New-Object Microsoft.Win32.OpenFileDialog
            $fileDialog.Title = 'Import server names and IPv4 addresses'
            $fileDialog.Filter = 'Supported server files (*.csv;*.xlsx)|*.csv;*.xlsx|CSV files (*.csv)|*.csv|Excel workbooks (*.xlsx)|*.xlsx|All files (*.*)|*.*'
            $fileDialog.DefaultExt = '.csv'
            $fileDialog.CheckFileExists = $true
            $fileDialog.CheckPathExists = $true
            $fileDialog.Multiselect = $false
            $fileDialog.DereferenceLinks = $true
            if ($fileDialog.ShowDialog($script:Window) -ne $true) {
                return
            }

            # Import is an atomic input edit. A failed/cancelled import must not
            # invalidate an unchanged Preview or silently remove typed entries.
            $createWasEnabled = [bool]$script:Create.IsEnabled
            $importSucceeded = $false
            $listCommitStarted = $false
            Set-UiBusy -Busy $true
            $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
            # The parser runs synchronously on the UI thread. Commit the locked
            # input state and wait cursor before reading a potentially large file;
            # only tracked operations and the background vDisk read use the status area.
            [void]$script:Window.Dispatcher.Invoke(
                [System.Action]{ },
                [System.Windows.Threading.DispatcherPriority]::Render
            )
            try {
                Write-RunLog -Level INFO -Stage 'Server import' -Message "Reading server input file '$($fileDialog.FileName)'. No infrastructure checks or changes are performed during import."
                $import = Get-ServerImportFileBatch -Path $fileDialog.FileName -Owner $script:Window
                if ($import.Cancelled) {
                    Write-RunLog -Level INFO -Stage 'Server import' -Message 'Operator cancelled worksheet selection. The current server list and Validation state were not changed.'
                    return
                }

                if (-not [string]::IsNullOrWhiteSpace($script:ServerList.Text)) {
                    $script:Window.Cursor = $null
                    $replaceChoice = [System.Windows.MessageBox]::Show(
                        $script:Window,
                        "The server box already contains entries.`n`nReplace the current list with $($import.Count) server(s) from '$($import.SourceDisplay)'?`n`nYes = replace the list`nNo = cancel the import`n`nThis does not run Validation or make infrastructure changes.",
                        'Replace current server list?',
                        'YesNo',
                        'Warning'
                    )
                    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
                    if ($replaceChoice -ne 'Yes') {
                        Write-RunLog -Level INFO -Stage 'Server import' -Message "Operator declined to replace the current server list with $($import.Count) record(s) from '$($import.FullPath)'."
                        return
                    }
                }

                Write-RunLog -Level SUCCESS -Stage 'Server import' -Message "Validated $($import.Count) server record(s) from '$($import.FullPath)'$(if ($import.WorksheetName) { ", worksheet '$($import.WorksheetName)'" } else { '' }); HeaderSkipped=$($import.HeaderSkipped). Replacing the GUI server list."
                $listCommitStarted = $true
                $script:ServerList.Text = $import.Text
                $importSucceeded = $true
                Write-RecoveryLog -Level SUCCESS -Stage 'Server import' -Message "The GUI server list now contains $($import.Count) imported record(s). Validation remains required before selecting Build."
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-RecoveryLog -Level ERROR -Stage 'Server import' -Message "Import of '$($fileDialog.FileName)' failed: $errorMessage"
                if ($_.Exception.Data.Contains('ImportValidationErrors')) {
                    foreach ($validationError in [string[]]$_.Exception.Data['ImportValidationErrors']) {
                        Write-RecoveryLog -Level ERROR -Stage 'Server import row' -Message $validationError
                    }
                }
                $stateMessage = if ($listCommitStarted) {
                    $script:Create.IsEnabled = $false
                    Set-ValidationBuildState -BuildContexts $null
                    'The server-list update had already started. Review the current server box and run Validation again before selecting Build.'
                }
                else {
                    'No entries were imported and the current server list was not changed.'
                }
                $dialogMessage = if (-not $listCommitStarted -and
                    $errorMessage -match '(?i)no entries were imported|current server list was not changed') {
                    $errorMessage
                }
                else {
                    "$errorMessage`n`n$stateMessage"
                }
                [System.Windows.MessageBox]::Show(
                    $script:Window,
                    $dialogMessage,
                    'Server import failed',
                    'OK',
                    'Error'
                ) | Out-Null
            }
            finally {
                $script:Window.Cursor = $null
                Set-UiBusy -Busy $false
                if (-not $listCommitStarted -and $createWasEnabled -and $script:AuditTrailHealthy) {
                    # Set-UiBusy deliberately disables Create while parsing;
                    # restore it only because every original input is unchanged.
                    $script:Create.IsEnabled = $true
                }
                if ($importSucceeded -and $script:AuditTrailHealthy) {
                    try { $script:ServerList.Focus() | Out-Null } catch {}
                }
            }
        })
}
function Register-OlvmServerAdditionValidationBuildEvents {
    [CmdletBinding()]
    param()

    $script:Preview.Add_Click({
            if ($script:IsOperationRunning -or
                $script:IsPvsImageLoadPending -or
                $script:IsPvsImageWorkerQuiescing) { return }
            if (Defer-GuiOperationForPvsImageWorker -Operation Validation) { return }
            $canCreate = $false
            $operationOutcome = 'Stopped'
            $deferredErrorMessage = $null
            try {
                Start-ExecutionTracking -OperationName 'Validation'
                $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
                $canCreate = [bool](Invoke-Preview)
                $operationOutcome = 'Finished'
            }
            catch {
                $deferredErrorMessage = $_.Exception.Message
                Write-RecoveryLog -Level ERROR -Stage 'Validation' -Message $deferredErrorMessage
                Set-GuiStatus -Text "Validation failed: $deferredErrorMessage" -Color 'Red' -SuppressRenderingErrors
            }
            finally {
                $script:Window.Cursor = $null
                Stop-ExecutionTracking -Outcome $operationOutcome
                $script:Create.IsEnabled = ($canCreate -and $script:AuditTrailHealthy)
            }

            # The idle status area is intentionally blank. A terminal Validation
            # failure therefore uses a post-stop dialog, especially when the
            # run log itself caused the failure and cannot retain the reason.
            if (-not [string]::IsNullOrWhiteSpace($deferredErrorMessage)) {
                $validationFailureMessage = "$deferredErrorMessage`n`nRun log:`n$script:LogPath"
                if (-not $script:AuditTrailHealthy) {
                    $recoveryTranscript = Format-RecoveryLogFallback -MaximumCharacters 8192
                    if (-not [string]::IsNullOrWhiteSpace($recoveryTranscript)) {
                        $validationFailureMessage += "`n`nProcess-local recovery evidence (not written to the run log):`n$recoveryTranscript"
                    }
                }
                [System.Windows.MessageBox]::Show(
                    $script:Window,
                    $validationFailureMessage,
                    'OLVM Server Addition - Validation stopped',
                    'OK',
                    'Error'
                ) | Out-Null
            }
        })

    $script:Create.Add_Click({
            if ($script:IsOperationRunning -or
                $script:IsPvsImageLoadPending -or
                $script:IsPvsImageWorkerQuiescing) { return }
            if (Defer-GuiOperationForPvsImageWorker -Operation Provisioning) { return }
            $operationOutcome = 'Stopped'
            $provisionDisposition = $null
            $deferredErrorMessage = $null
            try {
                Start-ExecutionTracking -OperationName 'Provisioning'
                $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
                $provisionDisposition = [string](Invoke-Provision)
                $operationOutcome = if ($provisionDisposition -eq 'Cancelled') { 'Cancelled' } else { 'Finished' }
            }
            catch {
                $deferredErrorMessage = $_.Exception.Message
                Write-RecoveryLog -Level ERROR -Stage 'Provisioning' -Message $deferredErrorMessage
                Set-GuiStatus -Text "Provisioning stopped: $deferredErrorMessage Log: $script:LogPath" -Color 'Red' -SuppressRenderingErrors
            }
            finally {
                $script:Window.Cursor = $null
                Stop-ExecutionTracking -Outcome $operationOutcome
                $validationBuildState = Get-ValidationBuildState
                if ($provisionDisposition -eq 'Cancelled' -and
                    $script:AuditTrailHealthy -and
                    $null -ne $validationBuildState.BuildContexts -and
                    @($validationBuildState.BuildContexts).Count -gt 0) {
                    $script:Create.IsEnabled = $true
                }
            }

            # Terminal dialogs are shown after tracking stops, so the final
            # completion duration excludes time spent reading the dialog.
            if (-not [string]::IsNullOrWhiteSpace($deferredErrorMessage)) {
                $provisioningFailureMessage = "$deferredErrorMessage`n`nRun log:`n$script:LogPath"
                if (-not $script:AuditTrailHealthy) {
                    $recoveryTranscript = Format-RecoveryLogFallback -MaximumCharacters 8192
                    if (-not [string]::IsNullOrWhiteSpace($recoveryTranscript)) {
                        $provisioningFailureMessage += "`n`nProcess-local recovery evidence (not written to the run log):`n$recoveryTranscript"
                    }
                }
                [System.Windows.MessageBox]::Show(
                    $script:Window,
                    $provisioningFailureMessage,
                    'OLVM Server Addition - provisioning stopped',
                    'OK',
                    'Error'
                ) | Out-Null
            }
            elseif ($provisionDisposition -eq 'Finished') {
                $validationBuildState = Get-ValidationBuildState
                $completionPopup = New-ProvisionCompletionPopup `
                    -Records @($validationBuildState.ValidationRecords) `
                    -AuditTrailHealthy ([bool]$script:AuditTrailHealthy) `
                    -LogPath ([string]$script:LogPath)
                Set-CompletedRunReviewMode
                $postRunChoice = Show-PostRunChoiceDialog -Completion $completionPopup
                switch ($postRunChoice) {
                    'StartNewBuild' {
                        try {
                            Reset-GuiForNewBuild
                        }
                        catch {
                            $resetError = $_.Exception.Message
                            Write-RecoveryLog -Level ERROR -Stage 'New build' -Message $resetError
                            Set-CompletedRunReviewMode
                            [System.Windows.MessageBox]::Show(
                                $script:Window,
                                "$resetError`n`nClose the application before attempting another run.",
                                'A new build could not be started',
                                'OK',
                                'Error'
                            ) | Out-Null
                        }
                    }
                    'ExitApplication' {
                        Write-RecoveryLog -Level INFO -Stage 'Post-run choice' -Message 'Operator selected Exit Application.'
                        if ($null -ne $script:LogWriter) { $script:LogWriter.Flush() }
                        $script:Window.Close()
                    }
                    default {
                        Write-RecoveryLog -Level INFO -Stage 'Post-run choice' -Message 'Operator closed the post-run prompt. Current Results remain visible.'
                    }
                }
            }
        })
}
function Register-OlvmServerAdditionUtilityEvents {
    [CmdletBinding()]
    param()

    $script:OpenLog.Add_Click({
            if ($script:IsOperationRunning -or $script:IsPvsImageLoadPending) { return }
            try {
                Write-RunLog -Level INFO -Stage 'Run log' -Message 'Operator selected Open log.'
                $script:LogWriter.Flush()
                $notepadPath = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\notepad.exe'
                if (-not [System.IO.File]::Exists($notepadPath)) {
                    throw "Windows Notepad was not found at the trusted operating-system path '$notepadPath'."
                }
                Assert-PathHasNoReparsePoint -Path $notepadPath -BoundaryDescription 'The Notepad executable path'
                Start-Process -FilePath $notepadPath -ArgumentList ('"{0}"' -f $script:LogPath) -ErrorAction Stop | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-RecoveryLog -Level ERROR -Stage 'Run log' -Message $errorMessage
                if (-not $script:AuditTrailHealthy) {
                    Set-UiBusy -Busy $false
                    Set-GuiStatus -Text "The run log became unavailable. Provisioning is disabled; close the tool and review '$script:LogPath'." -Color 'Red' -SuppressRenderingErrors
                }
                [System.Windows.MessageBox]::Show(
                    $script:Window,
                    "The log could not be opened automatically. Copy this path and open it manually:`n`n$script:LogPath`n`n$errorMessage",
                    'Open run log',
                    'OK',
                    'Error'
                ) | Out-Null
            }
        })

    $script:Reset.Add_Click({
            if ($script:IsOperationRunning -or
                $script:IsPvsImageLoadPending -or
                $script:IsPvsImageWorkerQuiescing -or
                $script:IsResettingAuditSession -or
                $null -ne $script:ActiveFarmBuildLock) { return }

            $confirmation = [System.Windows.MessageBox]::Show(
                $script:Window,
                "Reset all current server entries, selected options, Validation state, and displayed Results?`n`nThe current run remains saved in:`n$script:LogPath`n`nA new Run ID and log will be created. Reset affects only this application and does not remove or roll back infrastructure already created.",
                'Reset and start from scratch',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning,
                [System.Windows.MessageBoxResult]::No
            )
            if ($confirmation -ne [System.Windows.MessageBoxResult]::Yes) {
                Write-RunLog -Level INFO -Stage 'Reset' -Message 'Operator cancelled Reset. Current inputs, selections, Validation state, and Results were retained.'
                return
            }
            if (Defer-GuiOperationForPvsImageWorker -Operation Reset) { return }
            Invoke-ManualResetGuiCore
        })
}
function Register-OlvmServerAdditionResultEvents {
    [CmdletBinding()]
    param()

    $script:ResultGrid.Add_SelectionChanged({
            if ($null -ne $script:ResultGrid.SelectedItem) {
                $script:ViewDetails.IsEnabled = (-not $script:IsOperationRunning -and
                    -not $script:IsPvsImageLoadPending)
            }
            else {
                $script:ViewDetails.IsEnabled = $false
            }
        })
    $script:ShowSelectedDetailsHandler = {
            if (-not $script:IsOperationRunning -and
                -not $script:IsPvsImageLoadPending -and
                $null -ne $script:ResultGrid.SelectedItem) {
                Show-ResultDetailsDialog -Record $script:ResultGrid.SelectedItem
            }
        }
    $script:ResultGrid.Add_MouseDoubleClick($script:ShowSelectedDetailsHandler)
    $script:ViewDetails.Add_Click($script:ShowSelectedDetailsHandler)
}
function Register-OlvmServerAdditionInputInvalidationEvents {
    [CmdletBinding()]
    param()

    $script:InvalidatePreviewHandler = {
        if ($script:IsResettingGui) { return }
        $script:Create.IsEnabled = $false
        $validationBuildState = Get-ValidationBuildState
        Set-ValidationBuildState -BuildContexts $null
        if ($null -ne $validationBuildState.ValidationRecords -and
            @($validationBuildState.ValidationRecords).Count -gt 0) {
            Set-ValidationBuildState -ValidationRecords ([object[]]@())
            Refresh-Grid
            Write-RecoveryLog -Level INFO -Stage 'Validation state' -Message 'Inputs changed. The previous Validation results were cleared; Validation is required before selecting Build.'
            Set-ExecutionStatusVisibility -Visible $false
        }
    }
    foreach ($control in @(
            $script:ServerList,$script:OrganizationalUnit)) {
        $control.Add_TextChanged($script:InvalidatePreviewHandler)
    }
    foreach ($control in @(
            $script:BootBios,$script:BootUefi,$script:PvsCaseUpper,$script:PvsCaseLower,
            $script:DhcpCaseUpper,$script:DhcpCaseLower,$script:ReservationHost,$script:ReservationFqdn)) {
        $control.Add_Checked($script:InvalidatePreviewHandler)
    }
}
function Register-OlvmServerAdditionImageSelectionEvents {
    [CmdletBinding()]
    param()

    $script:AssignImageYes.Add_Checked({
            if ($script:IsResettingGui -or $script:IsRefreshingPvsImageChoices -or
                $script:IsPvsImageLoadPending -or $script:IsOperationRunning) { return }
            & $script:InvalidatePreviewHandler
            $script:IsRefreshingPvsImageChoices = $true
            $script:SelectedPvsImage = $null
            $script:PvsImage.ItemsSource = @()
            $script:PvsImage.SelectedIndex = -1
            $script:PvsStore.SelectedIndex = -1
            Reset-PowerOnChoice
            try {
                if ($null -eq $script:Collection.SelectedItem) {
                    Set-Status -Text 'Optional image assignment is selected. Select a PVS device collection to display its preloaded Stores.' -Color 'DarkOrange' -Stage 'PVS image selection'
                }
                else {
                    Set-UiBusy -Busy $true
                    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
                    $null = Read-PvsStoresForSelectedCollection -RetryFailed
                }
            }
            catch {
                $message = $_.Exception.Message
                Write-RecoveryLog -Level ERROR -Stage 'PVS Store browse' -Message $message
                Set-GuiStatus -Text "Optional PVS image discovery failed: $message Select No for Assign Image to continue without a vDisk." -Color 'Red' -SuppressRenderingErrors
                [System.Windows.MessageBox]::Show(
                    $script:Window,
                    "$message`n`nImage assignment is optional. Select No for Assign Image to continue without a vDisk.",
                    'Optional PVS image discovery',
                    'OK',
                    'Error'
                ) | Out-Null
            }
            finally {
                $script:Window.Cursor = $null
                Set-UiBusy -Busy $false
                $script:IsRefreshingPvsImageChoices = $false
                Sync-OptionalImagePowerUiState
            }
        })
    $script:AssignImageNo.Add_Checked({
            if ($script:IsResettingGui -or $script:IsRefreshingPvsImageChoices -or
                $script:IsPvsImageLoadPending -or $script:IsOperationRunning) { return }
            & $script:InvalidatePreviewHandler
            $script:IsRefreshingPvsImageChoices = $true
            try {
                Reset-PowerOnChoice
                $script:SelectedPvsImage = $null
                $script:PvsImage.SelectedIndex = -1
                $script:PvsImage.ItemsSource = @()
                $script:PvsStore.SelectedIndex = -1
            }
            finally {
                $script:IsRefreshingPvsImageChoices = $false
                Sync-OptionalImagePowerUiState
            }
            Write-RunLog -Level INFO -Stage 'PVS image selection' -Message 'Optional PVS image assignment is not requested. Any previous Store and image selections were cleared, and post-build power was reset to No.'
            Set-Status -Text 'PVS image assignment is not requested. New targets will be verified with zero vDisk mappings; power-on is unavailable.' -Color 'DarkOrange' -Stage 'PVS image selection'
        })
    $script:Collection.Add_SelectionChanged({
            if ($script:IsResettingGui -or $script:IsRefreshingPvsImageChoices -or
                $script:IsPvsImageLoadPending -or $script:IsOperationRunning) { return }
            & $script:InvalidatePreviewHandler
            $script:IsRefreshingPvsImageChoices = $true
            Reset-PowerOnChoice
            $script:SelectedPvsImage = $null
            $script:PvsImage.ItemsSource = @()
            $script:PvsImage.SelectedIndex = -1
            $script:PvsStore.ItemsSource = @()
            $script:PvsStore.SelectedIndex = -1
            try {
                if ($null -ne $script:Collection.SelectedItem) {
                    Set-UiBusy -Busy $true
                    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
                    $retryFailedStorePreload = ($script:AssignImageYes.IsChecked -eq $true)
                    $null = Read-PvsStoresForSelectedCollection -RetryFailed:$retryFailedStorePreload
                    $selectedStoreSiteKey = ([guid]$script:Collection.SelectedItem.SiteId).ToString('D').ToLowerInvariant()
                    if ($script:AssignImageYes.IsChecked -ne $true -and
                        -not $script:PvsStoreChoiceErrors.ContainsKey($selectedStoreSiteKey)) {
                        Set-Status -Text "Selected PVS collection '$($script:Collection.SelectedItem.Display)'. Stores are preloaded but remain disabled until Assign Image is Yes." -Color 'DarkOrange' -Stage 'PVS collection selection'
                    }
                }
            }
            catch {
                $message = $_.Exception.Message
                $level = if ($script:AssignImageYes.IsChecked -eq $true) { 'ERROR' } else { 'WARN' }
                Write-RecoveryLog -Level $level -Stage 'PVS Store selection' -Message $message
                if ($script:AssignImageYes.IsChecked -eq $true) {
                    Set-GuiStatus -Text "Optional PVS image discovery failed: $message Select No for Assign Image to continue without a vDisk." -Color 'Red' -SuppressRenderingErrors
                    [System.Windows.MessageBox]::Show(
                        $script:Window,
                        "$message`n`nImage assignment is optional. Select No for Assign Image to continue without a vDisk.",
                        'Optional PVS image discovery',
                        'OK',
                        'Error'
                    ) | Out-Null
                }
            }
            finally {
                $script:Window.Cursor = $null
                Set-UiBusy -Busy $false
                $script:IsRefreshingPvsImageChoices = $false
                Sync-OptionalImagePowerUiState
            }
        })
    $script:PvsStore.Add_SelectionChanged({
            if ($script:IsResettingGui -or
                $script:IsRefreshingPvsImageChoices -or
                $script:IsPvsImageLoadPending -or
                $script:IsOperationRunning) { return }
            & $script:InvalidatePreviewHandler
            Reset-PowerOnChoice
            $script:IsRefreshingPvsImageChoices = $true
            try {
                $script:SelectedPvsImage = $null
                $script:PvsImage.ItemsSource = @()
                $script:PvsImage.SelectedIndex = -1
            }
            finally {
                $script:IsRefreshingPvsImageChoices = $false
            }
            if ($null -ne $script:PvsStore.SelectedItem -and
                $script:AssignImageYes.IsChecked -eq $true) {
                try {
                    $null = Start-PvsImagesForSelectedStoreLoad
                }
                catch {
                    $message = $_.Exception.Message
                    Write-RecoveryLog -Level ERROR -Stage 'PVS image selection' -Message $message
                    $failureGuidance = if ($script:AuditTrailHealthy) {
                        $wasRefreshing = $script:IsRefreshingPvsImageChoices
                        $script:IsRefreshingPvsImageChoices = $true
                        try {
                            $script:PvsStore.SelectedIndex = -1
                        }
                        finally {
                            $script:IsRefreshingPvsImageChoices = $wasRefreshing
                        }
                        'The Store selection was cleared. Select it again to retry, choose another Store, or set Assign Image to No.'
                    }
                    else {
                        "The run log is unavailable, so all further actions are disabled. Close and reopen the tool, then review '$script:LogPath'."
                    }
                    # Normalizes all controls through the audit-aware busy
                    # policy even when startup failed before a worker existed.
                    Set-UiBusy -Busy $false
                    [System.Windows.MessageBox]::Show(
                        $script:Window,
                        "$message`n`n$failureGuidance",
                        'PVS image selection',
                        'OK',
                        'Error'
                    ) | Out-Null
                }
            }
            Sync-OptionalImagePowerUiState
        })
    $script:PvsImage.Add_SelectionChanged({
            if ($script:IsResettingGui -or
                $script:IsRefreshingPvsImageChoices -or
                $script:IsPvsImageLoadPending -or
                $script:IsOperationRunning) { return }
            & $script:InvalidatePreviewHandler
            Reset-PowerOnChoice
            $script:SelectedPvsImage = $script:PvsImage.SelectedItem
            if ($null -ne $script:SelectedPvsImage) {
                Write-RunLog -Level SUCCESS -Stage 'PVS image selection' -Message "Operator selected vDisk '$($script:SelectedPvsImage.Name)' (DiskLocator '$($script:SelectedPvsImage.DiskLocatorId)', Store '$($script:SelectedPvsImage.StoreName)', effective version '$($script:SelectedPvsImage.EffectiveVersionDisplay)')."
                Set-Status -Text "Selected vDisk: $($script:SelectedPvsImage.Name). Optional power-on is available and remains set to No." -Stage 'PVS image selection'
            }
            Sync-OptionalImagePowerUiState
        })
}
function Register-OlvmServerAdditionOlvmPowerEvents {
    [CmdletBinding()]
    param()

    $script:OlvmManager.Add_SelectionChanged({
            if ($script:IsResettingGui -or $script:IsPvsImageLoadPending -or $script:IsOperationRunning) { return }
            & $script:InvalidatePreviewHandler
            Reset-SelectionOlvmRouteCache
            if ($null -ne $script:OlvmManager.SelectedItem) {
                $selectionMode = if ([string]$script:OlvmManager.SelectedItem.Mode -eq 'Explicit') {
                    'It will be tried first for each initial Validation lookup, with Auto-detect fallback if its query fails or the exact VM is absent.'
                }
                else {
                    'Configured-manager Auto-detect will be used.'
                }
                Write-RunLog -Level INFO -Stage 'OLVM selection' -Message "Operator selected '$($script:OlvmManager.SelectedItem.Display)' for the complete batch. $selectionMode"
            }
        })
    $script:PowerChoiceChangedHandler = {
        if ($script:IsResettingGui -or $script:IsRefreshingPvsImageChoices -or
            $script:IsPvsImageLoadPending -or $script:IsOperationRunning) { return }
        & $script:InvalidatePreviewHandler
    }
    $script:PowerOnYes.Add_Checked($script:PowerChoiceChangedHandler)
    $script:PowerOnNo.Add_Checked($script:PowerChoiceChangedHandler)
}
function Register-OlvmServerAdditionOuEvents {
    [CmdletBinding()]
    param()

    $script:OuSelector.Add_DropDownOpened({
            if ($script:IsResettingGui -or $script:IsPvsImageLoadPending -or
                $script:IsOperationRunning -or $script:IsRefreshingOuChoices) { return }
            $script:IsRefreshingOuChoices = $true
            $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
            try {
                $currentOuText = if ($null -ne $script:OuEditableTextBox) {
                    [string]$script:OuEditableTextBox.Text
                }
                else {
                    [string]$script:OuSelector.Text
                }
                $selectedOu = $script:OuSelector.SelectedItem
                # The displayed value of an existing selection is not a search.
                # Clear that implicit filter so reopening the list exposes every
                # cached OU and lets the operator replace a mistaken selection.
                $nextOuSearchText = if ($null -ne $selectedOu -and
                    ([string]$selectedOu.Display).Equals(
                        $currentOuText,
                        [System.StringComparison]::OrdinalIgnoreCase)) {
                    ''
                }
                else {
                    $currentOuText
                }
                $ouFilterChanged = -not ([string]$script:OuSearchText).Equals(
                    $nextOuSearchText,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
                $script:OuSearchText = $nextOuSearchText
                if ($null -eq $script:OuChoiceView) {
                    # A missing view means startup preload failed or the DNS
                    # domain changed. Keep the existing live retry behavior.
                    $null = Read-OuChoicesForCurrentDomain
                    if ($null -ne $script:OuChoiceView) {
                        $script:OuChoiceView.Refresh()
                    }
                }
                elseif ($ouFilterChanged) {
                    $script:OuChoiceView.Refresh()
                }
                Write-RunLog -Level INFO -Stage 'OU selection' -Message "OU dropdown opened for '$($script:AdDnsDomain.Text.Trim())'."
            }
            catch {
                $message = $_.Exception.Message
                Write-RecoveryLog -Level ERROR -Stage 'OU selection' -Message $message
                [System.Windows.MessageBox]::Show($script:Window,$message,'OU selection','OK','Error') | Out-Null
            }
            finally {
                $script:Window.Cursor = $null
                $script:IsRefreshingOuChoices = $false
            }
        })
    $script:OuSelector.Add_SelectionChanged({
            if ($script:IsResettingGui -or $script:IsRefreshingOuChoices -or
                $script:IsPvsImageLoadPending -or $script:IsOperationRunning) { return }
            & $script:InvalidatePreviewHandler
            $selectedOu = $script:OuSelector.SelectedItem
            if ($null -eq $selectedOu) {
                $script:OrganizationalUnit.Text = ''
                return
            }
            try {
                $metadata = Resolve-SelectionAdOrganizationalUnit `
                    -DistinguishedName ([string]$selectedOu.DistinguishedName) `
                    -Server $script:AdDnsDomain.Text.Trim().Trim('.')
                $script:OrganizationalUnit.Text = $metadata.DistinguishedName
                $script:OuSelector.Text = [string]$selectedOu.Display
                Write-RunLog -Level SUCCESS -Stage 'OU selection' -Message "Operator selected '$($selectedOu.Display)' (DN '$($metadata.DistinguishedName)')."
            }
            catch {
                $script:OrganizationalUnit.Text = ''
                $script:OuSelector.SelectedIndex = -1
                [System.Windows.MessageBox]::Show($script:Window,$_.Exception.Message,'OU selection','OK','Error') | Out-Null
            }
        })
    $script:OuSelector.Add_Loaded({
            if ($script:OuSearchHandlerAttached) { return }
            $script:OuSelector.ApplyTemplate()
            $editableTextBox = $script:OuSelector.Template.FindName('PART_EditableTextBox',$script:OuSelector)
            if ($null -eq $editableTextBox) { return }
            $script:OuEditableTextBox = $editableTextBox
            $script:OuSearchHandlerAttached = $true
            $editableTextBox.Add_TextChanged({
                    if ($script:IsResettingGui -or $script:IsRefreshingOuChoices -or
                        $script:IsPvsImageLoadPending -or $script:IsOperationRunning) { return }
                    $script:OuSearchText = [string]$script:OuEditableTextBox.Text
                    $selectedOu = $script:OuSelector.SelectedItem
                    if ($null -eq $selectedOu -or
                        -not ([string]$selectedOu.Display).Equals(
                            $script:OuSearchText,
                            [System.StringComparison]::OrdinalIgnoreCase)) {
                        $script:OrganizationalUnit.Text = ''
                    }
                    if ($null -ne $script:OuChoiceView) {
                        $script:OuChoiceView.Refresh()
                    }
                })
        })
    $script:AdDnsDomain.Add_TextChanged({
            if ($script:IsResettingGui -or $script:IsPvsImageLoadPending) { return }
            & $script:InvalidatePreviewHandler
            $script:OrganizationalUnit.Text = ''
            $script:IsRefreshingOuChoices = $true
            try {
                $script:OuSelector.SelectedIndex = -1
                $script:OuSelector.ItemsSource = @()
                $script:OuSelector.Text = ''
                $script:OuChoiceView = $null
                $script:OuSearchText = ''
            }
            finally {
                $script:IsRefreshingOuChoices = $false
            }
        })
}
function Register-OlvmServerAdditionWindowLifecycleEvents {
    [CmdletBinding()]
    param()

    $script:Window.Add_Closing({
            param($sender,$eventArgs)

            if ($script:IsOperationRunning) {
                $eventArgs.Cancel = $true
                $script:ExecutionNote.Text = "Execution in progress: $($script:CurrentOperationName). The close request was ignored; please wait for the operation to finish."
                $script:ExecutionNote.Foreground = 'DarkRed'
                if (-not $script:BusyCloseAttemptLogged) {
                    $script:BusyCloseAttemptLogged = $true
                    Write-RecoveryLog -Level WARN -Stage 'Execution' -Message "A window-close request was blocked while '$($script:CurrentOperationName)' was running."
                }
            }
            elseif ($script:IsPvsImageLoadPending) {
                Write-RecoveryLog -Level INFO -Stage 'PVS image selection' -Message 'Window close cancelled the selected-Store wait. The background reader received an asynchronous shutdown request.'
                Complete-PvsImageSelectedWaitState
                $null = Stop-PvsImageCacheWarmup -StopActivePipeline -Reason 'the application window is closing'
            }
            elseif ($script:IsPvsImageWorkerQuiescing) {
                $cancelledOperation = [string]$script:PvsImageDeferredOperation
                $script:PvsImageDeferredOperation = ''
                $script:PvsImageDeferredCreateWasEnabled = $false
                $script:IsPvsImageWorkerQuiescing = $false
                $script:PvsImageQuiesceStartedUtc = $null
                Write-RecoveryLog -Level INFO -Stage 'PVS image cache' -Message "Window close cancelled the pending '$cancelledOperation' action. It was not started; the background reader received an asynchronous shutdown request."
                $null = Stop-PvsImageCacheWarmup -StopActivePipeline -Reason 'the application window is closing'
            }
        })

    # Fit the main window after its native handle exists. The operator may
    # minimize but cannot resize or maximize it; monitor/DPI-driven size
    # changes still reflow and safely re-fit the restored window.
    $script:Window.Add_SourceInitialized({
            Sync-MainWindowResponsiveState `
                -TargetWindow $script:Window `
                -ForceFit `
                -UseCursorMonitor `
                -Reason 'Initial display.'
        })
    $script:Window.Add_SizeChanged({
            if (-not $script:IsApplyingResponsiveBounds) {
                Sync-MainWindowResponsiveState `
                    -TargetWindow $script:Window `
                    -Reason 'The main window size or monitor work area changed.'
            }
        })
    $script:Window.Add_LocationChanged({
            if (-not $script:IsApplyingResponsiveBounds) {
                Sync-MainWindowResponsiveState `
                    -TargetWindow $script:Window `
                    -Reason 'The window moved to a different monitor.'
            }
        })
    $script:Window.Add_StateChanged({
            Sync-MainWindowResponsiveState `
                -TargetWindow $script:Window `
                -Reason 'The window state or monitor changed.'
        })
    $script:Window.Add_ContentRendered({
            if (-not $script:GuiDisplayed) {
                $script:GuiDisplayed = $true
                Stop-StartupSplash
                Sync-MainWindowResponsiveState -TargetWindow $script:Window -ForceFit -Reason 'The rendered layout and monitor DPI were synchronized.'
                try {
                    $monitorContext = Get-MainWindowMonitorContext -TargetWindow $script:Window
                    Write-RecoveryLog -Level SUCCESS -Stage 'GUI' -Message "GUI displayed. Rendered size=$([math]::Round($script:Window.ActualWidth))x$([math]::Round($script:Window.ActualHeight)) DIPs; monitor work area=$($monitorContext.WorkWidth)x$($monitorContext.WorkHeight) native pixels; settings layout=$($script:ResponsiveSettingsMode); density=$($script:ResponsiveDensityMode)."
                }
                catch {
                    Write-RecoveryLog -Level SUCCESS -Stage 'GUI' -Message "GUI displayed. Rendered size=$([math]::Round($script:Window.ActualWidth))x$([math]::Round($script:Window.ActualHeight)) DIPs; per-monitor work-area details are unavailable."
                }
                if (-not $script:AuditTrailHealthy) {
                    Set-UiBusy -Busy $false
                    Set-ExecutionStatusVisibility -Visible $false
                }
                if ($script:AuditTrailHealthy) {
                    try { $null = Start-PvsImageCacheWarmup }
                    catch {
                        Write-RecoveryLog -Level WARN -Stage 'PVS image cache' -Message "Optional background vDisk cache warming could not be started: $($_.Exception.Message) Selecting a Store will retry it on demand."
                    }
                }
            }
        })
}

function Register-OlvmServerAdditionMainWindowEvents {
    [CmdletBinding()]
    param()

    Register-OlvmServerAdditionImportEvents
    Register-OlvmServerAdditionValidationBuildEvents
    Register-OlvmServerAdditionUtilityEvents
    Register-OlvmServerAdditionResultEvents
    Register-OlvmServerAdditionInputInvalidationEvents
    Register-OlvmServerAdditionImageSelectionEvents
    Register-OlvmServerAdditionOlvmPowerEvents
    Register-OlvmServerAdditionOuEvents
    Register-OlvmServerAdditionWindowLifecycleEvents
}
