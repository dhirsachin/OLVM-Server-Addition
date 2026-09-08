#region GUI status and responsiveness helpers

function Set-ExecutionStatusVisibility {
    <# Shows the main status area only for tracked operations or the background vDisk read. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Visible
    )

    $visibility = if ($Visible) { 'Visible' } else { 'Collapsed' }
    foreach ($name in @('Status','ExecutionNote')) {
        $controlVariable = Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $controlVariable -or $null -eq $controlVariable.Value) {
            continue
        }
        $controlVariable.Value.Visibility = $visibility
        if (-not $Visible) {
            $controlVariable.Value.Text = ''
            $controlVariable.Value.Foreground = 'DimGray'
        }
    }
}

function Set-GuiStatus {
    <#
      Renders status text without creating an audit event. Callers that have
      already written the authoritative ERROR/WARN use this seam to avoid a
      second INFO record with the same failure details.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [string]$Color = 'Black',

        [switch]$SuppressRenderingErrors
    )

    try {
        if (-not $script:IsOperationRunning -and
            -not $script:IsPvsImageLoadPending -and
            -not $script:IsPvsImageWorkerQuiescing) {
            Set-ExecutionStatusVisibility -Visible $false
            return
        }

        Set-ExecutionStatusVisibility -Visible $true
        $script:Status.Text = $Text
        $script:Status.Foreground = $Color

        # Preserve synchronous rendering so the latest status remains visible
        # before the next infrastructure call begins.
        $windowVariable = Get-Variable -Name window -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $windowVariable -and $null -ne $windowVariable.Value) {
            $windowVariable.Value.Dispatcher.Invoke(
                [System.Action]{},
                [System.Windows.Threading.DispatcherPriority]::Render
            )
        }
    }
    catch {
        if (-not $SuppressRenderingErrors) {
            throw
        }
        # Recovery and retained-state reporting continue if the GUI is closing.
    }
}

function Set-Status {
    <# Compatibility wrapper that audits once, then renders synchronously. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [string]$Color = 'Black',

        [string]$Stage = 'Operator status',

        [string]$MachineName = '-'
    )

    Write-RunLog -Level INFO -Stage $Stage -MachineName $MachineName -Message $Text
    Set-GuiStatus -Text $Text -Color $Color
}

function Set-RecoveryStatus {
    <# Compatibility wrapper that retains once, then renders without throwing. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [string]$Color = 'Black',

        [string]$Stage = 'Recovery',

        [string]$MachineName = '-'
    )

    Write-RecoveryLog -Level INFO -Stage $Stage -MachineName $MachineName -Message $Text
    Set-GuiStatus -Text $Text -Color $Color -SuppressRenderingErrors
}

function Start-ExecutionTracking {
    <# Starts one operator-visible Validation or Provisioning operation. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Validation','Provisioning')]
        [string]$OperationName
    )

    if ($script:IsOperationRunning) {
        throw "Cannot start '$OperationName' because '$($script:CurrentOperationName)' is still running."
    }
    if ($script:IsPvsImageLoadPending) {
        throw "Cannot start '$OperationName' while the selected PVS Store's vDisk list is still loading."
    }
    if ($script:IsPvsImageCacheWarmupActive) {
        throw "Cannot start '$OperationName' while optional background vDisk cache warming is still active."
    }
    if ($script:IsPvsImageWorkerQuiescing -or
        $null -ne $script:PvsImageLoadPowerShell -or
        $null -ne $script:PvsImageLoadRunspace -or
        $null -ne $script:PvsImageLoadAsyncResult) {
        throw "Cannot start '$OperationName' until the optional background vDisk reader has stopped and released its PVS session."
    }

    # Commit the audit boundary before exposing a running state. If logging is
    # unavailable, the caller receives the failure while the GUI remains idle.
    Write-RunLog -Level INFO -Stage 'Execution' -Message "Starting $OperationName. GUI inputs and actions will remain locked until it finishes; the window must remain open."

    $script:IsOperationRunning = $true
    $script:CurrentOperationName = $OperationName
    $script:BusyCloseAttemptLogged = $false
    $script:OperationStopwatch.Restart()

    $script:Status.Text = "$OperationName in progress..."
    $script:Status.Foreground = 'DarkOrange'
    $script:ExecutionNote.Text = "Execution in progress: $OperationName. Please wait and do not close the window; inputs and actions are locked."
    $script:ExecutionNote.Foreground = 'DarkOrange'
    Set-ExecutionStatusVisibility -Visible $true
    Set-UiBusy -Busy $true
}

function Suspend-ExecutionClockForConfirmation {
    <# Excludes operator decision time from the provisioning execution total. #>
    [CmdletBinding()]
    param()

    if (-not $script:IsOperationRunning) {
        return
    }

    $script:OperationStopwatch.Stop()
    $script:ExecutionNote.Text = 'Waiting for final confirmation. Review the confirmation dialog before continuing.'
    $script:ExecutionNote.Foreground = 'DarkOrange'
}

function Resume-ExecutionClockAfterConfirmation {
    <# Resumes the same accumulated stopwatch after the operator selects Yes. #>
    [CmdletBinding()]
    param()

    if (-not $script:IsOperationRunning) {
        return
    }

    $script:OperationStopwatch.Start()
    $script:ExecutionNote.Text = "Execution in progress: $($script:CurrentOperationName). Please wait and do not close the window; inputs and actions are locked."
    $script:ExecutionNote.Foreground = 'DarkOrange'
}

function Stop-ExecutionTracking {
    <# Always called from a button-handler finally block. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Finished','Cancelled','Stopped')]
        [string]$Outcome
    )

    if (-not $script:IsOperationRunning) {
        Set-UiBusy -Busy $false
        Set-ExecutionStatusVisibility -Visible $false
        return
    }

    $operationName = $script:CurrentOperationName
    $script:OperationStopwatch.Stop()
    $elapsedText = Format-ElapsedTime -Elapsed $script:OperationStopwatch.Elapsed

    Write-RecoveryLog `
        -Level $(if ($Outcome -eq 'Finished') { 'SUCCESS' } else { 'WARN' }) `
        -Stage 'Execution' `
        -Message "$operationName $($Outcome.ToLowerInvariant()) after $elapsedText."

    $script:IsOperationRunning = $false
    $script:CurrentOperationName = ''
    $script:BusyCloseAttemptLogged = $false
    Set-UiBusy -Busy $false

    if ($Outcome -eq 'Finished' -and $operationName -eq 'Validation') {
        $validationBuildState = Get-ValidationBuildState
        $outcomeCounts = Get-ValidationOutcomeCounts -Records ([object[]]@($validationBuildState.ValidationRecords))
        $readyCount = $outcomeCounts.Ready
        $skippedCount = $outcomeCounts.SkippedExisting
        $blockedCount = $outcomeCounts.Blocked
        $skippedText = if ($skippedCount -gt 0) { ", $skippedCount skipped" } else { '' }

        if ($readyCount -gt 0 -and $blockedCount -eq 0) {
            $completionMessage = "Validation completed in $elapsedText. $readyCount ready, 0 blocked$skippedText. Review the details, then select Build."
            $completionLevel = 'SUCCESS'
        }
        elseif ($readyCount -gt 0 -and $blockedCount -gt 0) {
            $completionMessage = "Validation completed in $elapsedText. $readyCount ready, $blockedCount blocked$skippedText. Select Build to process only the Ready servers; Blocked rows will be skipped unchanged."
            $completionLevel = 'WARN'
        }
        elseif ($readyCount -eq 0 -and $skippedCount -gt 0 -and $blockedCount -eq 0) {
            $completionMessage = "Validation completed in $elapsedText. 0 ready, 0 blocked, $skippedCount skipped. No provisioning is required."
            $completionLevel = 'SUCCESS'
        }
        else {
            $completionMessage = "Validation completed in $elapsedText. $readyCount ready, $blockedCount blocked$skippedText. No Ready servers are available to build."
            $completionLevel = 'WARN'
        }

        Write-RecoveryLog -Level $completionLevel -Stage 'Execution' -Message $completionMessage
    }

    # Completion, cancellation, and failure details remain in the run log and
    # Results. The main status area returns to an empty collapsed state.
    Set-ExecutionStatusVisibility -Visible $false
}

function Reset-PowerOnChoice {
    <# Power-on is optional and always returns to the safe No selection. #>
    [CmdletBinding()]
    param()

    foreach ($name in @('PowerOnYes','PowerOnNo')) {
        if ($null -eq (Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue)) {
            return
        }
    }

    $script:PowerOnYes.IsChecked = $false
    $script:PowerOnNo.IsChecked = $true
}

function Sync-OptionalImagePowerUiState {
    <#
      Keeps optional image and power controls consistent after ordinary input
      changes and after Set-UiBusy re-enables the rest of the form. Backend
      validation repeats the same safety rule and never trusts GUI state alone.
    #>
    [CmdletBinding()]
    param()

    foreach ($name in @('Collection','AssignImageYes','AssignImageNo','PvsStore','PvsImage','PowerOnYes','PowerOnNo')) {
        if ($null -eq (Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue)) {
            return
        }
    }

    $canEdit = (-not $script:IsOperationRunning -and
        -not $script:IsPvsImageLoadPending -and
        -not $script:IsPvsImageWorkerQuiescing -and
        -not $script:IsResettingGui -and
        -not $script:IsCompletedRunReviewMode -and
        $script:AuditTrailHealthy)
    $assignImage = ($script:AssignImageYes.IsChecked -eq $true)
    $hasCollection = ($null -ne $script:Collection.SelectedItem)
    $hasStore = ($assignImage -and $null -ne $script:PvsStore.SelectedItem)
    $hasValidatedImage = ($assignImage -and
        $null -ne $script:SelectedPvsImage -and
        $null -ne $script:PvsImage.SelectedItem)

    $script:PvsStore.IsEnabled = ($canEdit -and $assignImage -and $hasCollection)
    $script:PvsImage.IsEnabled = ($canEdit -and $hasStore -and $script:PvsImage.Items.Count -gt 0)
    $script:PowerOnYes.IsEnabled = ($canEdit -and $hasValidatedImage)
    $script:PowerOnNo.IsEnabled = ($canEdit -and $hasValidatedImage)

    if (-not $hasValidatedImage) {
        Reset-PowerOnChoice
    }
}

function Set-UiBusy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Busy
    )

    $stateBusy = ($script:IsOperationRunning -or
        $script:IsPvsImageLoadPending -or
        $script:IsPvsImageWorkerQuiescing)
    $effectiveBusy = ($Busy -or $stateBusy)
    $controlsMayRun = (-not $effectiveBusy -and
        -not $script:IsCompletedRunReviewMode -and
        $script:AuditTrailHealthy)
    $script:Preview.IsEnabled = $controlsMayRun
    if ($effectiveBusy -or -not $script:AuditTrailHealthy) {
        $script:Create.IsEnabled = $false
    }

    $overlayVariable = Get-Variable -Name BusyOverlay -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $overlayVariable) {
        $showBusyOverlay = $stateBusy
        $overlayVariable.Value.Visibility = if ($showBusyOverlay) { 'Visible' } else { 'Collapsed' }
        if ($showBusyOverlay) {
            # Move keyboard focus away from any previously selected input. The
            # overlay already intercepts all pointer interaction.
            $null = $overlayVariable.Value.Focus()
        }
    }

    $inputVariable = Get-Variable -Name InputControls -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $inputVariable) {
        foreach ($control in $inputVariable.Value) {
            $control.IsEnabled = $controlsMayRun
        }
    }

    $sectionVariable = Get-Variable -Name InputSections -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $sectionVariable) {
        foreach ($section in $sectionVariable.Value) {
            $section.IsEnabled = $controlsMayRun
        }
    }

    $idleForInteraction = -not $effectiveBusy
    $script:ResultGrid.IsEnabled = $idleForInteraction
    $script:ViewDetails.IsEnabled = ($idleForInteraction -and $null -ne $script:ResultGrid.SelectedItem)
    $script:OpenLog.IsEnabled = $idleForInteraction
    $resetVariable = Get-Variable -Name Reset -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $resetVariable) {
        $resetVariable.Value.IsEnabled = ($idleForInteraction -and
            -not $script:IsResettingAuditSession -and
            $script:AuditTrailHealthy -and
            $null -eq $script:ActiveFarmBuildLock)
    }

    $showBusyProgress = $stateBusy
    $script:Progress.Visibility = if ($showBusyProgress) { 'Visible' } else { 'Collapsed' }
    $script:Progress.IsIndeterminate = $showBusyProgress
    Sync-OptionalImagePowerUiState
}

function Set-CompletedRunReviewMode {
    <#
      Keeps a completed Run ID immutable. Results, details, the log, and the
      main-window close action remain available, but no input or new
      Validation can reuse the completed audit session.
    #>
    [CmdletBinding()]
    param()

    $script:IsCompletedRunReviewMode = $true
    Set-UiBusy -Busy $false
    $script:Preview.IsEnabled = $false
    $script:Create.IsEnabled = $false
    $script:ResultGrid.IsEnabled = $true
    $script:ViewDetails.IsEnabled = ($null -ne $script:ResultGrid.SelectedItem)
    $script:OpenLog.IsEnabled = ($null -ne $script:LogWriter -and
        -not [string]::IsNullOrWhiteSpace([string]$script:LogPath))
}

function Set-WindowInitialBounds {
    <# Keeps child dialogs inside the owner window on the owner's monitor. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$TargetWindow,

        [ValidateRange(0, 100)]
        [double]$Margin = 8
    )

    # Every tool dialog has the responsive main window as its Owner. Sizing to
    # that owner avoids SystemParameters.WorkArea, which represents only the
    # primary monitor in many RDP and mixed-monitor sessions.
    if ($null -ne $TargetWindow.Owner -and
        $TargetWindow.Owner.ActualWidth -gt 0 -and
        $TargetWindow.Owner.ActualHeight -gt 0) {
        $availableWidth = [math]::Max(400, $TargetWindow.Owner.ActualWidth - (2 * $Margin))
        $availableHeight = [math]::Max(350, $TargetWindow.Owner.ActualHeight - (2 * $Margin))
        if ($TargetWindow.MinWidth -gt $availableWidth) { $TargetWindow.MinWidth = $availableWidth }
        if ($TargetWindow.MinHeight -gt $availableHeight) { $TargetWindow.MinHeight = $availableHeight }
        $TargetWindow.Width = [math]::Min($TargetWindow.Width, $availableWidth)
        $TargetWindow.Height = [math]::Min($TargetWindow.Height, $availableHeight)
        $TargetWindow.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
        return
    }

    # Startup-only fallback for an ownerless dialog.
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $availableWidth = [math]::Max(400, $workArea.Width - (2 * $Margin))
    $availableHeight = [math]::Max(350, $workArea.Height - (2 * $Margin))
    if ($TargetWindow.MinWidth -gt $availableWidth) { $TargetWindow.MinWidth = $availableWidth }
    if ($TargetWindow.MinHeight -gt $availableHeight) { $TargetWindow.MinHeight = $availableHeight }
    $TargetWindow.Width = [math]::Min($TargetWindow.Width, $availableWidth)
    $TargetWindow.Height = [math]::Min($TargetWindow.Height, $availableHeight)
    $TargetWindow.Left = $workArea.Left + [math]::Max($Margin, ($workArea.Width - $TargetWindow.Width) / 2)
    $TargetWindow.Top = $workArea.Top + $Margin
}

function Get-MainWindowMonitorContext {
    <#
      Returns the monitor work area in native pixels plus the DPI scale reported
      by the current WPF host. Native coordinates are retained for positioning;
      powershell.exe still controls whether rendering is system- or per-monitor
      DPI aware.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$TargetWindow,

        [switch]$UseCursorMonitor
    )

    $interop = [System.Windows.Interop.WindowInteropHelper]::new($TargetWindow)
    $handle = $interop.Handle
    if ($handle -eq [IntPtr]::Zero) {
        throw 'The main window handle is not available yet.'
    }

    $monitor = if ($UseCursorMonitor) {
        [OlvmServerAddition.NativeWindowPlacement]::GetMonitorAtCursor()
    }
    else {
        [OlvmServerAddition.NativeWindowPlacement]::MonitorFromWindow(
            $handle,
            [OlvmServerAddition.NativeWindowPlacement]::MonitorDefaultToNearest
        )
    }
    if ($monitor -eq [IntPtr]::Zero) {
        throw 'Windows could not identify the monitor containing the main window.'
    }

    $work = [OlvmServerAddition.NativeWindowPlacement]::GetWorkArea($monitor)
    $workWidth = [int]($work.Right - $work.Left)
    $workHeight = [int]($work.Bottom - $work.Top)
    if ($workWidth -le 0 -or $workHeight -le 0) {
        throw 'Windows returned an invalid monitor work area.'
    }

    $scaleX = 1.0
    $scaleY = 1.0
    $source = [System.Windows.Interop.HwndSource]::FromHwnd($handle)
    if ($null -ne $source -and $null -ne $source.CompositionTarget) {
        $transform = $source.CompositionTarget.TransformToDevice
        if ($transform.M11 -gt 0) { $scaleX = [double]$transform.M11 }
        if ($transform.M22 -gt 0) { $scaleY = [double]$transform.M22 }
    }

    # When the PowerShell host supports per-monitor DPI, its WPF scale can
    # update just after a move. Including it allows the follow-up SizeChanged
    # event to perform one corrected fit. System-DPI-aware hosts keep one scale.
    $signature = '{0}:{1},{2},{3},{4}:{5},{6}' -f `
        $monitor.ToInt64().ToString('X'),$work.Left,$work.Top,$work.Right,$work.Bottom,`
        [math]::Round($scaleX,4),[math]::Round($scaleY,4)

    return [pscustomobject]@{
        Handle       = $handle
        Monitor      = $monitor
        Work         = $work
        WorkWidth    = $workWidth
        WorkHeight   = $workHeight
        ScaleX       = $scaleX
        ScaleY       = $scaleY
        Signature    = $signature
    }
}

function Update-MainWindowResponsiveLayout {
    <#
      Reflows only the presentation layer. Results remains the sole star-sized
      root row, so it receives all vertical space left after the input sections.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$TargetWindow
    )

    # Window.SizeChanged can run before the child Grid finishes its next layout
    # pass, so calculate from the new Window width instead of a stale Grid
    # ActualWidth. The cap matches MainLayout.MaxWidth.
    $layoutWidth = [math]::Max(
        0,
        [math]::Min(1160, [double]$TargetWindow.ActualWidth - 36)
    )
    if ($layoutWidth -le 0) {
        return
    }

    # Provisioning and naming choices share matching column breakpoints. This
    # preserves the intended left-to-right workflow while preventing clipping
    # when the tool is used through a narrower laptop or RDP work area.
    $settingsMode = if ($layoutWidth -lt 840) {
        'Narrow'
    }
    elseif ($layoutWidth -lt 1080) {
        'TwoColumn'
    }
    else {
        'ThreeColumn'
    }
    if ($script:ResponsiveSettingsMode -ne $settingsMode) {
        switch ($settingsMode) {
            'Narrow' {
                $script:ProvisioningSettingsLayout.Columns = 2
                $script:ProvisioningSettingsLayout.Rows = 3
                $script:NamingSettingsLayout.Columns = 2
                $script:NamingSettingsLayout.Rows = 2
            }
            'TwoColumn' {
                $script:ProvisioningSettingsLayout.Columns = 2
                $script:ProvisioningSettingsLayout.Rows = 3
                $script:NamingSettingsLayout.Columns = 3
                $script:NamingSettingsLayout.Rows = 1
            }
            default {
                $script:ProvisioningSettingsLayout.Columns = 3
                $script:ProvisioningSettingsLayout.Rows = 2
                $script:NamingSettingsLayout.Columns = 3
                $script:NamingSettingsLayout.Rows = 1
            }
        }
        $script:ResponsiveSettingsMode = $settingsMode
        if ($script:GuiDisplayed) {
            Write-RecoveryLog -Level INFO -Stage 'GUI layout' -Message "Provisioning and Server naming settings changed to $settingsMode mode at a content width of $([math]::Round($layoutWidth)) DIPs."
        }
    }

    # Use one centered width for all four sections so their boundaries align.
    # Results remains the sole star-height row and therefore still receives
    # the vertical space needed for large batches.
    $inputSectionWidth = [math]::Max(320, [math]::Min(1120, $layoutWidth))
    $inputContentWidth = [math]::Max(300, [math]::Min(1080, $inputSectionWidth - 24))
    foreach ($section in @(
            $script:ProvisioningSettingsGroup,
            $script:NamingSettingsGroup,
            $script:DestinationGroup,
            $script:ResultsGroup)) {
        $section.Width = $inputSectionWidth
        $section.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    }
    $script:HeaderPanel.Width = $inputSectionWidth
    $script:HeaderPanel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $script:ActionBar.Width = $inputSectionWidth
    $script:ActionBar.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
    $script:ProvisioningSettingsLayout.Width = $inputContentWidth
    $script:NamingSettingsLayout.Width = $inputContentWidth
    $script:NamingSettingsLayout.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    $script:DestinationLayout.Width = $inputContentWidth

    # Keep data-entry fields compact on wide displays. Stack before the AD
    # panel becomes too narrow to show a normal full OU path beside Browse.
    $destinationMode = if ($layoutWidth -lt 1100) { 'Stacked' } else { 'TwoColumn' }
    if ($script:ResponsiveDestinationMode -ne $destinationMode) {
        $serverColumn = $script:DestinationLayout.ColumnDefinitions[0]
        $adColumn = $script:DestinationLayout.ColumnDefinitions[1]
        if ($destinationMode -eq 'Stacked') {
            $serverColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $adColumn.Width = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Pixel)
            [System.Windows.Controls.Grid]::SetRow($script:ServerInputPanel, 0)
            [System.Windows.Controls.Grid]::SetColumn($script:ServerInputPanel, 0)
            [System.Windows.Controls.Grid]::SetRow($script:AdDestinationPanel, 1)
            [System.Windows.Controls.Grid]::SetColumn($script:AdDestinationPanel, 0)
        }
        else {
            # Give the OU path more room while keeping the server editor large
            # enough for the required ServerName, IPv4Address input format.
            $serverColumn.Width = [System.Windows.GridLength]::new(42, [System.Windows.GridUnitType]::Star)
            $adColumn.Width = [System.Windows.GridLength]::new(58, [System.Windows.GridUnitType]::Star)
            [System.Windows.Controls.Grid]::SetRow($script:ServerInputPanel, 0)
            [System.Windows.Controls.Grid]::SetColumn($script:ServerInputPanel, 0)
            [System.Windows.Controls.Grid]::SetRow($script:AdDestinationPanel, 0)
            [System.Windows.Controls.Grid]::SetColumn($script:AdDestinationPanel, 1)
        }
        $script:ResponsiveDestinationMode = $destinationMode
        if ($script:GuiDisplayed) {
            Write-RecoveryLog -Level INFO -Stage 'GUI layout' -Message "Server and AD destination inputs changed to $destinationMode mode at a content width of $([math]::Round($layoutWidth)) DIPs."
        }
    }

    # Compact metrics recover useful Results height on laptop/RDP work areas.
    # Labels and help remain visible; only spacing and editor heights change.
    $densityMode = if ($TargetWindow.ActualHeight -lt 780 -or $layoutWidth -lt 1000) { 'Compact' } else { 'Normal' }
    if ($script:ResponsiveDensityMode -ne $densityMode) {
        $compact = ($densityMode -eq 'Compact')
        $script:MainLayout.Margin = if ($compact) {
            [System.Windows.Thickness]::new(6)
        }
        else {
            [System.Windows.Thickness]::new(8)
        }
        $sectionPadding = if ($compact) { 4 } else { 5 }
        foreach ($section in @(
                $script:ProvisioningSettingsGroup,
                $script:NamingSettingsGroup,
                $script:DestinationGroup,
                $script:ResultsGroup)) {
            $section.Padding = [System.Windows.Thickness]::new($sectionPadding)
            $section.Margin = if ($compact) {
                [System.Windows.Thickness]::new(0,0,0,3)
            }
            else {
                [System.Windows.Thickness]::new(0,0,0,4)
            }
        }
        $settingsPanels = @($script:ProvisioningSettingsLayout.Children) +
            @($script:NamingSettingsLayout.Children)
        foreach ($settingsPanel in $settingsPanels) {
            $settingsPanel.Margin = if ($compact) {
                [System.Windows.Thickness]::new(3,2,3,2)
            }
            else {
                [System.Windows.Thickness]::new(4,3,4,3)
            }
        }
        # The server editor remains deliberately shorter than the adjacent AD
        # panel; scrolling still supports the full 50-entry batch.
        $script:ServerListBorder.Height = if ($compact) { 48 } else { 56 }
        $script:HeaderPanel.Margin = if ($compact) {
            [System.Windows.Thickness]::new(0,0,0,3)
        }
        else {
            [System.Windows.Thickness]::new(0,0,0,4)
        }
        $script:ImportServers.Content = if ($compact) {
            'Import file...'
        }
        else {
            'Import CSV / Excel...'
        }
        $script:ResponsiveDensityMode = $densityMode
        if ($script:GuiDisplayed) {
            Write-RecoveryLog -Level INFO -Stage 'GUI layout' -Message "Display density changed to $densityMode mode at $([math]::Round($layoutWidth))x$([math]::Round($TargetWindow.ActualHeight)) DIPs."
        }
    }
}

function Set-MainWindowResponsiveBounds {
    <#
      Opens at the compact design size instead of consuming the monitor. The
      work-area percentages are only upper safety limits on smaller displays;
      responsive reflow then keeps every control reachable without clipping.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$TargetWindow,

        [Parameter(Mandatory = $true)]
        [psobject]$MonitorContext,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    if ($TargetWindow.WindowState -ne [System.Windows.WindowState]::Normal) {
        Update-MainWindowResponsiveLayout -TargetWindow $TargetWindow
        return
    }

    $work = $MonitorContext.Work
    $maximumWidthPixels = [math]::Floor(1160 * $MonitorContext.ScaleX)
    $maximumHeightPixels = [math]::Floor(820 * $MonitorContext.ScaleY)
    $targetWidth = [int][math]::Min(
        [math]::Floor($MonitorContext.WorkWidth * 0.94),
        $maximumWidthPixels
    )
    $targetHeight = [int][math]::Min(
        [math]::Floor($MonitorContext.WorkHeight * 0.95),
        $maximumHeightPixels
    )

    # Preserve the normal supported minimum where the monitor permits it. On a
    # smaller work area, lower the WPF minimum only enough to keep the complete
    # outer window reachable; compact presentation is then best effort.
    $workWidthDips = $MonitorContext.WorkWidth / $MonitorContext.ScaleX
    $workHeightDips = $MonitorContext.WorkHeight / $MonitorContext.ScaleY
    $TargetWindow.MinWidth = [math]::Min(900, [math]::Max(320, $workWidthDips - 20))
    $TargetWindow.MinHeight = [math]::Min(700, [math]::Max(360, $workHeightDips - 20))

    $left = [int]($work.Left + [math]::Floor(($MonitorContext.WorkWidth - $targetWidth) / 2))
    $top = [int]($work.Top + [math]::Floor(($MonitorContext.WorkHeight - $targetHeight) / 2))

    $script:IsApplyingResponsiveBounds = $true
    try {
        [OlvmServerAddition.NativeWindowPlacement]::SetBounds(
            $MonitorContext.Handle,
            $left,
            $top,
            $targetWidth,
            $targetHeight
        )
    }
    finally {
        $script:IsApplyingResponsiveBounds = $false
    }
    # Commit the cache only after Windows accepts the new rectangle. A failed
    # placement therefore remains eligible for retry on the next layout event.
    $script:ResponsiveWorkAreaSignature = $MonitorContext.Signature

    if (($workWidthDips -lt 900 -or $workHeightDips -lt 720) -and
        -not $script:ResponsiveWarningLogged) {
        $script:ResponsiveWarningLogged = $true
        Write-RecoveryLog -Level WARN -Stage 'GUI layout' -Message "The available monitor work area is only $([math]::Round($workWidthDips))x$([math]::Round($workHeightDips)) DIPs. The tool is using best-effort compact layout; 900x720 DIPs or larger is recommended."
    }

    Write-RecoveryLog -Level INFO -Stage 'GUI layout' -Message "$Reason Applied compact responsive bounds ${targetWidth}x${targetHeight} native pixels within work area $($MonitorContext.WorkWidth)x$($MonitorContext.WorkHeight); DPI scale=$([math]::Round($MonitorContext.ScaleX,2))x$([math]::Round($MonitorContext.ScaleY,2))."
    Update-MainWindowResponsiveLayout -TargetWindow $TargetWindow
}

function Sync-MainWindowResponsiveState {
    <# Re-fits only for startup or an actual monitor/work-area change. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$TargetWindow,

        [switch]$ForceFit,

        [switch]$UseCursorMonitor,

        [string]$Reason = 'Monitor or work area changed.'
    )

    if ($script:IsApplyingResponsiveBounds) {
        return
    }

    try {
        $context = Get-MainWindowMonitorContext -TargetWindow $TargetWindow -UseCursorMonitor:$UseCursorMonitor
        $workAreaChanged = ($script:ResponsiveWorkAreaSignature -ne $context.Signature)
        if (($ForceFit -or $workAreaChanged) -and
            $TargetWindow.WindowState -eq [System.Windows.WindowState]::Normal) {
            Set-MainWindowResponsiveBounds -TargetWindow $TargetWindow -MonitorContext $context -Reason $Reason
        }
        else {
            Update-MainWindowResponsiveLayout -TargetWindow $TargetWindow
        }
    }
    catch {
        if (-not $script:ResponsiveWarningLogged) {
            $script:ResponsiveWarningLogged = $true
            Write-RecoveryLog -Level WARN -Stage 'GUI layout' -Message "Per-monitor layout adjustment was skipped: $($_.Exception.Message)"
        }
        Update-MainWindowResponsiveLayout -TargetWindow $TargetWindow
    }
}

function Refresh-Grid {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$FocusRecord
    )

    $validationBuildState = Get-ValidationBuildState
    $validationRecords = $validationBuildState.ValidationRecords
    $script:ResultGrid.ItemsSource = $null
    $script:ResultGrid.ItemsSource = $validationRecords
    if ($null -ne $validationRecords -and @($validationRecords).Count -gt 0) {
        $recordArray = @($validationRecords)
        $recordToShow = if ($null -ne $FocusRecord) {
            $FocusRecord
        }
        else {
            $recordArray[$recordArray.Count - 1]
        }
        $script:ResultGrid.SelectedItem = $recordToShow

        # Keep the newest Preview/provisioning result visible as rows arrive.
        # Auto-scrolling is presentation-only: a closing or damaged window must
        # never interrupt validation, creation, verification, or retained-state reporting.
        try {
            $script:ResultGrid.UpdateLayout()
            $script:ResultGrid.ScrollIntoView($recordToShow)
            $script:ResultGrid.UpdateLayout()
        }
        catch {
            Write-RecoveryLog -Level WARN -Stage 'GUI refresh' -MachineName ([string]$recordToShow.MachineName) -Message "The active result row could not be brought into view: $($_.Exception.Message)"
        }
        $viewVariable = Get-Variable -Name ViewDetails -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $viewVariable) {
            $viewVariable.Value.IsEnabled = -not $script:IsOperationRunning
        }
    }
    else {
        $viewVariable = Get-Variable -Name ViewDetails -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $viewVariable) {
            $viewVariable.Value.IsEnabled = $false
        }
    }
}

function Refresh-GridRecoverySafe {
    <# A closing or damaged GUI must never interrupt reconciliation after a write. #>
    [CmdletBinding()]
    param(
        [string]$MachineName = '-',

        [AllowNull()]
        [object]$FocusRecord
    )

    try {
        Refresh-Grid -FocusRecord $FocusRecord
    }
    catch {
        Write-RecoveryLog -Level WARN -Stage 'GUI refresh' -MachineName $MachineName -Message "The results grid could not be refreshed after a production operation: $($_.Exception.Message)"
    }
}

function Set-ProgressRecoverySafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [double]$Value,

        [string]$MachineName = '-'
    )

    try {
        $script:Progress.Value = $Value
    }
    catch {
        Write-RecoveryLog -Level WARN -Stage 'GUI progress' -MachineName $MachineName -Message "The progress bar could not be updated after a production operation: $($_.Exception.Message)"
    }
}

function Get-ResultDetailsText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Record
    )

    # Result records span read-only Validation, retained-plan Build execution,
    # and optional power-on. Show only fields that the current phase actually
    # evaluated so safe defaults cannot be mistaken for completed checks.
    $detailLines = New-Object 'System.Collections.Generic.List[string]'
    $addDetailLine = {
        param(
            [Parameter(Mandatory = $true)][string]$Label,
            [AllowNull()][object]$Value
        )

        $text = [string]$Value
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [void]$detailLines.Add("${Label}: $text")
        }
    }

    & $addDetailLine 'Line' $Record.Line
    & $addDetailLine 'Machine' $Record.MachineName
    & $addDetailLine 'IP address' $Record.IPAddress
    & $addDetailLine 'OLVM MAC' $Record.MacAddress
    & $addDetailLine 'OLVM VM status at Validation' $Record.OlvmVmStatus
    & $addDetailLine 'FQDN' $Record.Fqdn
    & $addDetailLine 'DHCP name' $Record.DhcpName
    & $addDetailLine 'PVS collection' $Record.PvsCollection

    $configuredPvsImage = [string]$Record.ConfiguredPvsImage
    if ([string]::IsNullOrWhiteSpace($configuredPvsImage)) {
        $configuredPvsImage = [string]$Record.PvsImage
    }
    & $addDetailLine 'Configured / next-boot vDisk' $configuredPvsImage
    & $addDetailLine 'Current streamed vDisk at Validation' $Record.CurrentStreamedPvsImage
    & $addDetailLine 'Reboot personality' $Record.RebootDay

    [void]$detailLines.Add('')
    $validationOutcome = [string]$Record.ValidationOutcome
    switch ($validationOutcome) {
        'Exact' {
            & $addDetailLine 'Validation outcome' 'Exact - the requested stored provisioning configuration matched the selected settings.'
        }
        'Passed' {
            & $addDetailLine 'Validation outcome' 'Passed - the retained action plan is ready for operator confirmation.'
        }
        'Blocked' {
            & $addDetailLine 'Validation outcome' 'Blocked - this row has no Build action and will be skipped unchanged if other Ready rows are built.'
        }
        default {
            & $addDetailLine 'Validation outcome' $validationOutcome
        }
    }
    & $addDetailLine 'Stage' $Record.Stage
    & $addDetailLine 'Result' $Record.Result

    $validationAdAction = [string]$Record.ValidationAdAction
    if (-not [string]::IsNullOrWhiteSpace($validationAdAction)) {
        $validationAdText = switch ($validationAdAction) {
            'ReuseExact' { 'Exact existing AD/PVS binding validated (ReuseExact).' }
            'Create' { 'Missing account planned for Build (Create).' }
            default { $validationAdAction }
        }
        & $addDetailLine 'AD validation' $validationAdText
    }
    & $addDetailLine 'Build action' $Record.BuildAction
    if (-not [string]::IsNullOrWhiteSpace($validationOutcome) -and
        $validationOutcome -ne 'InProgress') {
        & $addDetailLine 'Power-on requested after Build' $(if ($Record.PowerRequested -eq $true) { 'Yes' } else { 'No' })
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Record.ActionSummary)) {
        [void]$detailLines.Add('')
        & $addDetailLine 'Validation action plan (raw)' $Record.ActionSummary
    }

    $showBuildAd = ($Record.AdBuildEvaluated -eq $true)
    $showNonAdResult = ($Record.NonAdPrerequisitesEvaluated -eq $true)
    $powerRequested = ($Record.PowerRequested -eq $true)
    $buildStarted = ($Record.BuildStarted -eq $true)
    $showPowerOverride = ($Record.PowerOverrideEligible -eq $true -or
        [string]$Record.PowerOverrideDecision -notin @('','NotOffered') -or
        -not [string]::IsNullOrWhiteSpace([string]$Record.PowerOverrideOperator) -or
        $null -ne $Record.PowerOverrideTimestamp)
    $showPowerResult = ($buildStarted -and $powerRequested -and
        -not [string]::IsNullOrWhiteSpace([string]$Record.PowerResult))

    if ($showBuildAd -or $showNonAdResult -or $showPowerOverride -or $showPowerResult) {
        [void]$detailLines.Add('')
        [void]$detailLines.Add('Build and optional power information:')
        if ($showBuildAd) {
            & $addDetailLine 'AD build status' $Record.AdStatus
            & $addDetailLine 'AD build details' $Record.AdDetails
        }
        if ($showNonAdResult) {
            & $addDetailLine 'Non-AD prerequisites verified' $(if ($Record.NonAdPrerequisitesVerified -eq $true) { 'Yes' } else { 'No' })
        }
        if ($showPowerOverride) {
            & $addDetailLine 'AD-warning power override eligible' $(if ($Record.PowerOverrideEligible -eq $true) { 'Yes' } else { 'No' })
            & $addDetailLine 'AD-warning power override decision' $Record.PowerOverrideDecision
            & $addDetailLine 'AD-warning power override operator' $Record.PowerOverrideOperator
            & $addDetailLine 'AD-warning power override timestamp (UTC)' $Record.PowerOverrideTimestamp
        }
        if ($showPowerResult) {
            & $addDetailLine 'Power result' $Record.PowerResult
            & $addDetailLine 'Power details' $Record.PowerDetails
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Record.Details)) {
        [void]$detailLines.Add('')
        [void]$detailLines.Add('Details:')
        [void]$detailLines.Add([string]$Record.Details)
    }
    return ($detailLines -join [Environment]::NewLine)
}

function Show-ResultDetailsDialog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Record
    )

    $detailText = Get-ResultDetailsText -Record $Record
    $dialog = New-Object System.Windows.Window -Property @{
        Title                 = "Result details - $($Record.MachineName)"
        Width                 = 900
        Height                = 500
        MinWidth              = 600
        MinHeight             = 350
        WindowStartupLocation = 'CenterOwner'
        WindowStyle           = 'SingleBorderWindow'
        ResizeMode            = 'CanResize'
        Owner                 = $script:Window
    }
    $grid = New-Object System.Windows.Controls.Grid
    $grid.Margin = '14'
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))
    $textBox = New-Object System.Windows.Controls.TextBox -Property @{
        Text                        = $detailText
        IsReadOnly                  = $true
        AcceptsReturn               = $true
        TextWrapping                = 'Wrap'
        VerticalScrollBarVisibility = 'Auto'
        HorizontalScrollBarVisibility = 'Disabled'
        FontFamily                  = 'Segoe UI'
        Padding                     = '8'
    }
    [void]$grid.Children.Add($textBox)
    $closeButton = New-Object System.Windows.Controls.Button -Property @{
        Content             = 'Close'
        IsDefault           = $true
        IsCancel            = $true
        MinWidth            = 90
        Margin              = '0,10,0,0'
        HorizontalAlignment = 'Right'
    }
    [System.Windows.Controls.Grid]::SetRow($closeButton, 1)
    [void]$grid.Children.Add($closeButton)
    $closeButton.Add_Click({ $dialog.Close() })
    $dialog.Content = $grid
    Set-WindowInitialBounds -TargetWindow $dialog
    [void]$dialog.ShowDialog()
}

function Wait-GuiResponsive {
    [CmdletBinding()]
    param(
        [ValidateRange(0, 600)]
        [int]$Seconds
    )

    if ($Seconds -le 0) { return }
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 250
        try {
            [void]$script:Window.Dispatcher.Invoke(
                [System.Action]{ },
                [System.Windows.Threading.DispatcherPriority]::Background
            )
        }
        catch {
            # A damaged presentation must not alter infrastructure outcomes.
        }
    }
}

#endregion GUI status and responsiveness helpers
