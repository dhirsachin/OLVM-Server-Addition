function New-ProvisionCompletionPopup {
    <#
        Builds the short operator-facing completion message. Build and optional
        power outcomes remain separate so a power failure never changes the
        retained infrastructure result.
        Zero-value categories are deliberately omitted from the popup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records,

        [Parameter(Mandatory = $true)]
        [bool]$AuditTrailHealthy,

        [AllowEmptyString()]
        [string]$LogPath
    )

    $outcomeCounts = Get-BuildOutcomeCounts -Records $Records
    $completedCount = $outcomeCounts.CreatedAndVerified
    $skippedCount = $outcomeCounts.SkippedExisting
    $blockedExcludedCount = $outcomeCounts.BlockedExcluded
    $attentionCount = $outcomeCounts.AttentionRequired
    $partialCount = $outcomeCounts.PartialRetained
    $adWarningCount = $outcomeCounts.AdWarningAfterNonAdVerification
    $notAttemptedCount = $outcomeCounts.NotAttempted
    $poweredCount = $outcomeCounts.PoweredOn
    $poweredWithAdWarningCount = $outcomeCounts.PoweredOnWithAdWarning
    $alreadyUpCount = $outcomeCounts.AlreadyUp
    $alreadyUpWithAdWarningCount = $outcomeCounts.AlreadyUpWithAdWarning
    $powerFailedCount = $outcomeCounts.PowerFailed
    $powerKeptOffCount = $outcomeCounts.PowerKeptOff
    $powerNotAttemptedCount = $outcomeCounts.PowerNotAttempted
    $requiresReview = (-not $AuditTrailHealthy) -or
        $blockedExcludedCount -gt 0 -or
        $attentionCount -gt 0 -or
        $notAttemptedCount -gt 0 -or
        $powerFailedCount -gt 0 -or
        $powerNotAttemptedCount -gt 0

    $headline = if (-not $AuditTrailHealthy) {
        'Build finished, but the run log is unavailable.'
    }
    elseif ($attentionCount -gt 0) {
        'Build finished - review required.'
    }
    elseif ($notAttemptedCount -gt 0) {
        'Build did not process every server.'
    }
    elseif ($powerFailedCount -gt 0 -or $powerNotAttemptedCount -gt 0) {
        'Build finished, but some VMs were not powered on.'
    }
    elseif ($blockedExcludedCount -gt 0) {
        'Build completed for the Ready servers; blocked servers were excluded.'
    }
    elseif ($completedCount -eq 0 -and $skippedCount -gt 0) {
        'Every submitted server already had the exact stored provisioning configuration; no write was required.'
    }
    elseif ($skippedCount -gt 0) {
        'Build completed.'
    }
    else {
        'Build completed successfully.'
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add($headline)
    [void]$lines.Add('')

    if ($completedCount -gt 0) {
        [void]$lines.Add("Complete and verified: $completedCount")
    }
    if ($skippedCount -gt 0) {
        [void]$lines.Add("Exact stored provisioning configuration; no write required: $skippedCount")
    }
    if ($blockedExcludedCount -gt 0) {
        [void]$lines.Add("Blocked during Validation and excluded unchanged: $blockedExcludedCount")
    }
    if ($attentionCount -gt 0) {
        [void]$lines.Add("Require review: $attentionCount (partial state retained: $partialCount; AD warning after non-AD verification: $adWarningCount)")
    }
    if ($notAttemptedCount -gt 0) {
        [void]$lines.Add("Not attempted after processing stopped: $notAttemptedCount")
    }
    if ($poweredCount -gt 0) {
        [void]$lines.Add("Powered on and verified in OLVM: $poweredCount (with approved AD warning: $poweredWithAdWarningCount)")
    }
    if ($alreadyUpCount -gt 0) {
        [void]$lines.Add("Already up before this tool sent Start: $alreadyUpCount (with approved AD warning: $alreadyUpWithAdWarningCount)")
    }
    if ($powerFailedCount -gt 0) {
        [void]$lines.Add("Power-on failed; completed builds were retained: $powerFailedCount")
    }
    if ($powerKeptOffCount -gt 0) {
        [void]$lines.Add("Kept powered off after the AD-warning override was declined: $powerKeptOffCount")
    }
    if ($powerNotAttemptedCount -gt 0) {
        [void]$lines.Add("Power-on not attempted because the optional power phase stopped: $powerNotAttemptedCount")
    }
    if ($completedCount -eq 0 -and $skippedCount -eq 0 -and $blockedExcludedCount -eq 0 -and
        $attentionCount -eq 0 -and
        $notAttemptedCount -eq 0) {
        [void]$lines.Add('No servers were processed.')
    }

    if ($blockedExcludedCount -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('Blocked servers received no Build or power action. Review their Validation details before including them in a later run.')
    }

    if ($attentionCount -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('Review Results and the run log. A later Validation will reuse only exact retained components and plan only missing components; mismatched or ambiguous state remains blocked.')
    }
    elseif ($requiresReview) {
        [void]$lines.Add('')
        [void]$lines.Add('Review Results and the run log before retrying.')
    }
    elseif ($skippedCount -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add('Skipped servers were left unchanged.')
    }

    if (-not $AuditTrailHealthy) {
        [void]$lines.Add('')
        [void]$lines.Add('The run log became unavailable and may be incomplete. Manual review is required.')
    }

    [void]$lines.Add('')
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        [void]$lines.Add('Run log path is unavailable.')
    }
    else {
        [void]$lines.Add($(if ($AuditTrailHealthy) { 'Run log:' } else { 'Run log (may be incomplete):' }))
        [void]$lines.Add($LogPath)
    }

    if (-not $AuditTrailHealthy) {
        $recoveryTranscript = Format-RecoveryLogFallback -MaximumCharacters 8192
        if (-not [string]::IsNullOrWhiteSpace($recoveryTranscript)) {
            [void]$lines.Add('')
            [void]$lines.Add('Process-local recovery evidence (not written to the run log):')
            [void]$lines.Add($recoveryTranscript)
        }
    }

    return [pscustomobject]@{
        Title            = if ($requiresReview) { 'Build finished - review required' } else { 'Build completed' }
        Message          = [string]::Join([Environment]::NewLine, $lines.ToArray())
        LogPath          = [string]$LogPath
        CanStartNewBuild = [bool]$AuditTrailHealthy
    }
}

function Show-PostRunChoiceDialog {
    <# Results remain visible when the operator closes this dialog with X. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Completion)

    [xml]$postRunXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="760" Height="500" MinWidth="620" MinHeight="400"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResizeWithGrip"
        ShowInTaskbar="False" Background="#F4F6F8">
 <Grid Margin="16">
  <Grid.RowDefinitions>
   <RowDefinition Height="Auto"/><RowDefinition Height="12"/>
   <RowDefinition Height="*"/><RowDefinition Height="14"/>
   <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <TextBlock Name="Heading" FontSize="18" FontWeight="SemiBold" Foreground="#17365D"/>
  <Border Grid.Row="2" BorderBrush="#C9D2DC" BorderThickness="1" Background="White" Padding="12">
   <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <TextBlock Name="Summary" TextWrapping="Wrap" FontFamily="Segoe UI" FontSize="13"/>
   </ScrollViewer>
  </Border>
  <Grid Grid.Row="4">
   <Grid.ColumnDefinitions>
    <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="10"/>
    <ColumnDefinition Width="Auto"/><ColumnDefinition Width="10"/><ColumnDefinition Width="Auto"/>
   </Grid.ColumnDefinitions>
   <TextBlock Name="Hint" Grid.Column="0" VerticalAlignment="Center" TextWrapping="Wrap" Foreground="DimGray" Margin="0,0,16,0"/>
   <Button Name="OpenLog" Grid.Column="1" Content="Open Log" MinWidth="105" Padding="12,6"
           ToolTipService.ShowOnDisabled="True"/>
   <Button Name="StartNew" Grid.Column="3" Content="Start New Build" MinWidth="130" Padding="12,6" IsDefault="True"/>
   <Button Name="ExitApp" Grid.Column="5" Content="Exit Application" MinWidth="130" Padding="12,6"/>
  </Grid>
 </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader($postRunXaml)
    try { $dialog = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    $dialog.Owner = $script:Window
    $dialog.Title = [string]$Completion.Title
    $dialog.FindName('Heading').Text = [string]$Completion.Title
    $dialog.FindName('Summary').Text = [string]$Completion.Message
    $openLogButton = $dialog.FindName('OpenLog')
    $logPathProperty = $Completion.PSObject.Properties['LogPath']
    $completedLogPath = if ($null -eq $logPathProperty) { '' } else { [string]$logPathProperty.Value }
    $logPathAvailable = -not [string]::IsNullOrWhiteSpace($completedLogPath)
    $openLogButton.IsEnabled = $logPathAvailable
    $openLogButton.ToolTip = if ($logPathAvailable) {
        "Open the completed run log in Notepad:`n$completedLogPath"
    }
    else {
        'Run log path is unavailable.'
    }
    $startButton = $dialog.FindName('StartNew')
    $startButton.IsEnabled = [bool]$Completion.CanStartNewBuild
    $dialog.FindName('Hint').Text = if ($Completion.CanStartNewBuild) {
        'Start New Build clears this screen and opens a new Run ID and log. Close this dialog with X to keep the current Results visible in review-only mode.'
    }
    else {
        'A new run cannot start because the audit trail is unhealthy. Exit and review the displayed log path.'
    }

    $dialog.Tag = 'Stay'
    $openLogButton.Add_Click({
            if ([string]::IsNullOrWhiteSpace($completedLogPath)) {
                $openLogButton.IsEnabled = $false
                $openLogButton.ToolTip = 'Run log path is unavailable.'
                return
            }
            try {
                Write-RecoveryLog -Level INFO -Stage 'Run log' -Message 'Operator selected Open Log from the completed-run window.'
                if (-not [System.IO.File]::Exists($completedLogPath)) {
                    throw "The completed run log is unavailable at '$completedLogPath'."
                }
                $notepadPath = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\notepad.exe'
                if (-not [System.IO.File]::Exists($notepadPath)) {
                    throw "Windows Notepad was not found at the trusted operating-system path '$notepadPath'."
                }
                Assert-PathHasNoReparsePoint -Path $notepadPath -BoundaryDescription 'The Notepad executable path'
                Start-Process -FilePath $notepadPath -ArgumentList ('"{0}"' -f $completedLogPath) -ErrorAction Stop | Out-Null
            }
            catch {
                $errorMessage = $_.Exception.Message
                Write-RecoveryLog -Level ERROR -Stage 'Run log' -Message $errorMessage
                if (-not [System.IO.File]::Exists($completedLogPath)) {
                    $openLogButton.IsEnabled = $false
                    $openLogButton.ToolTip = "The completed run log is unavailable at:`n$completedLogPath"
                }
                [System.Windows.MessageBox]::Show(
                    $dialog,
                    "The completed run log could not be opened in Notepad.`n`nLog:`n$completedLogPath`n`n$errorMessage",
                    'Open Log',
                    'OK',
                    'Error'
                ) | Out-Null
            }
        })
    $startButton.Add_Click({
            $dialog.Tag = 'StartNewBuild'
            $dialog.DialogResult = $true
        })
    $dialog.FindName('ExitApp').Add_Click({
            $dialog.Tag = 'ExitApplication'
            $dialog.DialogResult = $false
        })
    $null = $dialog.ShowDialog()
    return [string]$dialog.Tag
}

function Get-ProvisioningConfirmationActionDisplay {
    <# Converts the retained raw plan into a display-only list of components
       that still require work. The raw plan remains authoritative for Build. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Record
    )

    if ([string]$Record.Result -eq 'SkippedExisting') {
        return 'Skip - configuration already exact'
    }
    if ([string]$Record.Result -eq 'Blocked') {
        return 'Skip - Validation blocked'
    }
    if ([string]$Record.Result -ne 'Ready') {
        return 'See technical details'
    }

    $summary = [string]$Record.ActionSummary
    if ([string]::IsNullOrWhiteSpace($summary)) {
        return 'See technical details'
    }

    $actionValue = '(?:Create|ReuseExact)'
    $dhcpTarget = "[^,;:]+:Reservation=$actionValue/Option67=$actionValue"
    $recognizedPlan = "^PVS=$actionValue;\s*vDisk=(?:Create|ReuseExact|VerifyNone);\s*Reboot=$actionValue;\s*DHCP=(?:ReuseExact|$dhcpTarget(?:,\s*$dhcpTarget)*);\s*AD=$actionValue$"
    if (-not [regex]::IsMatch(
            $summary,
            $recognizedPlan,
            [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        return 'See technical details'
    }

    $actions = New-Object 'System.Collections.Generic.List[string]'
    if ([regex]::IsMatch($summary,'(?:^|;\s*)PVS=Create(?=;|$)',[Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        [void]$actions.Add('PVS')
    }
    if ([regex]::IsMatch($summary,'(?:^|;\s*)vDisk=Create(?=;|$)',[Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        [void]$actions.Add('vDisk')
    }
    if ([regex]::IsMatch($summary,'(?:^|;\s*)Reboot=Create(?=;|$)',[Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        [void]$actions.Add('Reboot')
    }
    if ([regex]::IsMatch($summary,'(?:Reservation|Option67)=Create(?:/|,|;|$)',[Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        [void]$actions.Add('DHCP')
    }
    if ([regex]::IsMatch($summary,'(?:^|;\s*)AD=Create(?=;|$)',[Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        [void]$actions.Add('AD')
    }

    if ($actions.Count -eq 0) {
        return 'No provisioning changes'
    }
    return [string]::Join(', ', $actions.ToArray())
}

function Get-CompactConfirmationDisplay {
    <# Shortens presentation text without changing or discarding its full value. #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Value,

        [ValidateRange(16, 512)]
        [int]$MaximumLength = 64
    )

    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -le $MaximumLength) {
        return $Value
    }
    $suffixLength = [math]::Min(20, [math]::Floor(($MaximumLength - 3) / 3))
    $prefixLength = $MaximumLength - $suffixLength - 3
    return '{0}...{1}' -f
        $Value.Substring(0,$prefixLength),
        $Value.Substring($Value.Length - $suffixLength)
}

function New-ProvisioningConfirmationPresentation {
    <# Builds display-only content for the confirmation dialog. It never
       modifies Validation records, Settings, or the retained action plan. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Records,

        [Parameter(Mandatory = $true)]
        [psobject]$Settings,

        [Parameter(Mandatory = $true)]
        [int]$ReadyCount,

        [Parameter(Mandatory = $true)]
        [int]$SkippedExistingCount,

        [ValidateRange(0, 50)]
        [int]$BlockedCount = 0,

        [AllowEmptyString()]
        [string]$LogPath
    )

    $serverRows = [object[]]@($Records | ForEach-Object {
            [pscustomobject][ordered]@{
                Line        = $_.Line
                MachineName = $_.MachineName
                IPAddress   = $_.IPAddress
                RebootDay   = $_.RebootDay
                Action      = Get-ProvisioningConfirmationActionDisplay -Record $_
                PowerAction = switch ([string]$_.Result) {
                    'Ready' {
                        if ($Settings.AssignPvsImage -and $Settings.PowerOnAfterBuild) {
                            'Power on after verified build'
                        }
                        else {
                            'No power action'
                        }
                    }
                    'Blocked' { 'Skip - Validation blocked' }
                    'SkippedExisting' { 'Skip - configuration already exact' }
                    default { 'No power action' }
                }
            }
        })

    $submittedCount = @($Records).Count
    $readyNoun = if ($ReadyCount -eq 1) { 'server' } else { 'servers' }
    $blockedNoun = if ($BlockedCount -eq 1) { 'server' } else { 'servers' }
    $exactNoun = if ($SkippedExistingCount -eq 1) { 'server' } else { 'servers' }
    $exactVerb = if ($SkippedExistingCount -eq 1) { 'requires' } else { 'require' }
    $fullImage = if ($Settings.AssignPvsImage) {
        [string]$Settings.Image.Name
    }
    else {
        'Not assigned'
    }
    $storeDisplay = if ($Settings.AssignPvsImage) {
        [string]$Settings.Store.Name
    }
    else {
        'Not applicable'
    }
    $fullOu = [string]$Settings.OuMetadata.DisplayPath
    $managerDisplay = [string]$Settings.OlvmManagerDisplay
    $fallbackRule = if ([string]::IsNullOrWhiteSpace([string]$Settings.OlvmManager)) {
        'Auto-detect searches the configured OLVM Managers for each exact VM during initial Validation.'
    }
    else {
        'The selected OLVM Manager is tried first. Auto-detect runs only if that Manager cannot be queried or the exact VM is absent.'
    }

    $rawActionLines = [string[]]@($Records | ForEach-Object {
            $record = $_
            $rawAction = switch ([string]$record.Result) {
                'Ready' { [string]$record.ActionSummary }
                'Blocked' { 'Blocked during Validation; no retained Build action plan.' }
                'SkippedExisting' { 'Configuration already exact; no Build action required.' }
                default { [string]$record.ActionSummary }
            }
            '  Line {0} - {1} [{2}]: {3}' -f $record.Line,$record.MachineName,$record.Result,$rawAction
        })
    $technicalDetails = [string]::Join([Environment]::NewLine, [string[]]@(
            "PVS target-name case: $($Settings.PvsNameCase)",
            "DHCP reservation-name case: $($Settings.DhcpNameCase)",
            "DHCP reservation display name: $($Settings.ReservationName)",
            "Boot filename: $($Settings.BootFile)",
            "OLVM fallback: $fallbackRule",
            "Complete vDisk: $fullImage",
            "Complete AD OU: $fullOu",
            'Raw Validation action plans:',
            $rawActionLines,
            $(if ([string]::IsNullOrWhiteSpace($LogPath)) {
                    'Run log: Unavailable'
                }
                else {
                    "Run log: $LogPath"
                })
        ))

    $visibleRowCount = [math]::Min(10, [math]::Max(1, $submittedCount))
    $tableHeight = 32 + (27 * $visibleRowCount)
    $warningMessages = New-Object 'System.Collections.Generic.List[string]'
    if ($BlockedCount -gt 0) {
        [void]$warningMessages.Add("$BlockedCount Blocked $blockedNoun will be skipped unchanged. No Build or power action will run for those rows.")
    }
    if (-not $Settings.AssignPvsImage) {
        [void]$warningMessages.Add('No vDisk will be assigned. These targets cannot boot from PVS until an image is assigned.')
    }
    $warningText = [string]::Join([Environment]::NewLine, $warningMessages.ToArray())

    return [pscustomobject][ordered]@{
        ServerRows          = $serverRows
        ListHeading         = "$ReadyCount Ready $readyNoun will be built; $BlockedCount Blocked $blockedNoun will be skipped unchanged; $SkippedExistingCount exact $exactNoun $exactVerb no write."
        BlockedCount        = $BlockedCount
        HasBlockedRows      = ($BlockedCount -gt 0)
        CollectionDisplay   = [string]$Settings.Collection.Display
        ManagerDisplay      = $managerDisplay
        StoreDisplay        = $storeDisplay
        ImageDisplay        = Get-CompactConfirmationDisplay -Value $fullImage -MaximumLength 52
        ImageFull           = $fullImage
        BootDisplay         = [string]$Settings.BootLabel
        PowerDisplay        = if ($Settings.PowerOnAfterBuild) { 'Yes' } else { 'No' }
        AdDomainDisplay     = [string]$Settings.AdDnsDomain
        OuDisplay           = Get-CompactConfirmationDisplay -Value $fullOu -MaximumLength 68
        OuFull              = $fullOu
        Safeguards          = [string[]]@(
            'Existing mismatched infrastructure is never overwritten.',
            'Build uses the retained Validation plan; no second pre-write Validation runs.',
            'Completed work is retained if a later step or optional power-on fails; no automatic rollback occurs.'
        )
        HasWarning          = -not [string]::IsNullOrWhiteSpace($warningText)
        WarningText         = $warningText
        TechnicalDetails    = $technicalDetails
        VisibleRowCount     = $visibleRowCount
        TableHeight         = $tableHeight
        InitialDialogHeight = [math]::Min(780, [math]::Max(520, 455 + $tableHeight + $(if ([string]::IsNullOrWhiteSpace($warningText)) { 0 } else { 62 })))
    }
}

function Show-ProvisioningConfirmationDialog {
    <#
      Presents one final confirmation for the complete submitted batch. Every
      row is shown with its effective action: Ready rows will be built, while
      Blocked and exact-existing rows will be skipped unchanged. The list has its own
      vertical scrollbar, so all 50 supported rows remain available for review
      without expanding the dialog beyond the current screen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [object[]]$Records,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [psobject]$Settings,

        [AllowEmptyString()]
        [string]$LogPath
    )

    $outcomeCounts = Get-ValidationOutcomeCounts -Records $Records
    $submittedCount = $outcomeCounts.Total
    if ($submittedCount -lt 1 -or $submittedCount -gt $script:MaximumBatchSize) {
        throw "The confirmation dialog received $submittedCount submitted server(s); expected between 1 and $($script:MaximumBatchSize)."
    }

    $readyCount = $outcomeCounts.Ready
    $skippedExistingCount = $outcomeCounts.SkippedExisting
    $blockedCount = $outcomeCounts.Blocked
    if ($readyCount -lt 1) {
        throw 'The confirmation dialog requires at least one Ready server.'
    }

    $presentation = New-ProvisioningConfirmationPresentation `
        -Records $Records `
        -Settings $Settings `
        -ReadyCount $readyCount `
        -SkippedExistingCount $skippedExistingCount `
        -BlockedCount $blockedCount `
        -LogPath $LogPath

    [xml]$confirmationXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Confirm OLVM Server Addition provisioning"
        Width="1080" Height="560" MinWidth="820" MinHeight="500"
        WindowStartupLocation="CenterOwner" WindowStyle="SingleBorderWindow"
        ResizeMode="CanResize" ShowInTaskbar="False">
 <Grid Margin="16">
  <Grid.RowDefinitions>
   <RowDefinition Height="*"/>
   <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>

  <ScrollViewer Grid.Row="0" Name="ConfirmationContentScroll"
                VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                Margin="0,0,0,12">
   <StackPanel>
    <TextBlock Name="ConfirmationHeading" FontSize="18" FontWeight="SemiBold"
               TextWrapping="Wrap" Margin="0,0,0,10"/>

    <Border Background="#F3F7FC" BorderBrush="#C8D7EA" BorderThickness="1"
            CornerRadius="3" Padding="10" Margin="0,0,0,10">
     <Grid Name="ConfirmationSettingsGrid">
      <Grid.RowDefinitions>
       <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
       <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid.ColumnDefinitions>
       <ColumnDefinition Width="105"/><ColumnDefinition Width="*"/>
       <ColumnDefinition Width="24"/><ColumnDefinition Width="95"/><ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <TextBlock Grid.Row="0" Grid.Column="0" Text="PVS collection" FontWeight="SemiBold" Foreground="#334E68" Margin="0,2,8,4"/>
      <TextBlock Grid.Row="0" Grid.Column="1" Name="CollectionValue" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap" Margin="0,2,0,4"/>
      <TextBlock Grid.Row="0" Grid.Column="3" Text="OLVM Manager" FontWeight="SemiBold" Foreground="#334E68" Margin="0,2,8,4"/>
      <TextBlock Grid.Row="0" Grid.Column="4" Name="ManagerValue" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap" Margin="0,2,0,4"/>

      <TextBlock Grid.Row="1" Grid.Column="0" Text="PVS Store" FontWeight="SemiBold" Foreground="#334E68" Margin="0,2,8,4"/>
      <TextBlock Grid.Row="1" Grid.Column="1" Name="StoreValue" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap" Margin="0,2,0,4"/>
      <TextBlock Grid.Row="1" Grid.Column="3" Text="vDisk" FontWeight="SemiBold" Foreground="#334E68" Margin="0,2,8,4"/>
      <TextBlock Grid.Row="1" Grid.Column="4" Name="ImageValue" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap" Margin="0,2,0,4"/>

      <TextBlock Grid.Row="2" Grid.Column="0" Text="Boot type" FontWeight="SemiBold" Foreground="#334E68" Margin="0,2,8,4"/>
      <TextBlock Grid.Row="2" Grid.Column="1" Name="BootValue" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap" Margin="0,2,0,4"/>
      <TextBlock Grid.Row="2" Grid.Column="3" Text="Power on" FontWeight="SemiBold" Foreground="#334E68" Margin="0,2,8,4"/>
      <TextBlock Grid.Row="2" Grid.Column="4" Name="PowerValue" Margin="0,2,0,4"/>

      <TextBlock Grid.Row="3" Grid.Column="0" Text="AD domain" FontWeight="SemiBold" Foreground="#334E68" Margin="0,2,8,2"/>
      <TextBlock Grid.Row="3" Grid.Column="1" Name="AdDomainValue" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap" Margin="0,2,0,2"/>
      <TextBlock Grid.Row="3" Grid.Column="3" Text="OU" FontWeight="SemiBold" Foreground="#334E68" Margin="0,2,8,2"/>
      <TextBlock Grid.Row="3" Grid.Column="4" Name="OuValue" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap" Margin="0,2,0,2"/>
     </Grid>
    </Border>

    <TextBlock Name="ConfirmationListHeading" FontWeight="SemiBold"
               TextWrapping="Wrap" Margin="0,0,0,6"/>

    <DataGrid Name="ConfirmationServers" IsReadOnly="True" Height="59"
              AutoGenerateColumns="False" CanUserAddRows="False" CanUserDeleteRows="False"
              CanUserResizeRows="False" CanUserReorderColumns="False" HeadersVisibility="Column"
              SelectionMode="Single" GridLinesVisibility="Horizontal" RowHeight="27"
              ColumnHeaderHeight="30" VerticalScrollBarVisibility="Auto"
              HorizontalScrollBarVisibility="Auto" Margin="0,0,0,10">
     <DataGrid.Columns>
      <DataGridTextColumn Header="Sr. No." Binding="{Binding Line}" Width="60"/>
      <DataGridTextColumn Header="Server name" Binding="{Binding MachineName}" Width="*"/>
      <DataGridTextColumn Header="IP address" Binding="{Binding IPAddress}" Width="135"/>
      <DataGridTextColumn Header="Reboot" Binding="{Binding RebootDay}" Width="85"/>
      <DataGridTextColumn Header="Actions" Binding="{Binding Action}" Width="245"/>
      <DataGridTextColumn Header="Power" Binding="{Binding PowerAction}" Width="205"/>
     </DataGrid.Columns>
    </DataGrid>

    <Border Name="ConfirmationWarning" Visibility="Collapsed" Background="#FFF4CE"
            BorderBrush="#D9822B" BorderThickness="1" CornerRadius="3"
            Padding="9" Margin="0,0,0,8">
     <TextBlock Name="ConfirmationWarningText" TextWrapping="Wrap" Foreground="#8A4B08" FontWeight="SemiBold"/>
    </Border>

    <Border Name="ConfirmationSafeguards" Background="#F5F7FA" BorderBrush="#D7E0E8"
            BorderThickness="1" CornerRadius="3" Padding="9" Margin="0,0,0,8">
     <StackPanel>
      <TextBlock Name="SafeguardOne" TextWrapping="Wrap" Foreground="#334E68" Margin="0,0,0,3"/>
      <TextBlock Name="SafeguardTwo" TextWrapping="Wrap" Foreground="#334E68" Margin="0,0,0,3"/>
      <TextBlock Name="SafeguardThree" TextWrapping="Wrap" Foreground="#334E68"/>
     </StackPanel>
    </Border>

    <Expander Name="ConfirmationTechnical" Header="Show technical details"
              IsExpanded="False" FontWeight="SemiBold" Margin="0,0,0,2">
     <Border Background="#FAFBFC" BorderBrush="#D7E0E8" BorderThickness="1"
             CornerRadius="3" Padding="8" Margin="0,5,0,0">
      <TextBox Name="ConfirmationTechnicalText" Height="150" IsReadOnly="True"
               AcceptsReturn="True" TextWrapping="Wrap" FontFamily="Consolas"
               FontWeight="Normal" Background="Transparent" BorderThickness="0"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
     </Border>
    </Expander>
   </StackPanel>
  </ScrollViewer>

  <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right">
   <Button Name="AcceptConfirmation" MinWidth="170" Padding="16,7" Margin="0,0,8,0"
           Background="#0F6CBD" Foreground="White" BorderBrush="#0B4F8A"
           FontWeight="SemiBold" IsDefault="False"/>
   <Button Name="CancelConfirmation" Content="Cancel" MinWidth="95" Padding="12,7"
           IsDefault="False" IsCancel="True"/>
  </StackPanel>
 </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $confirmationXaml
    try {
        $dialog = [System.Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        $reader.Dispose()
    }
    $dialog.Owner = $script:Window

    $heading = $dialog.FindName('ConfirmationHeading')
    $listHeading = $dialog.FindName('ConfirmationListHeading')
    $serverGrid = $dialog.FindName('ConfirmationServers')
    $collectionValue = $dialog.FindName('CollectionValue')
    $managerValue = $dialog.FindName('ManagerValue')
    $storeValue = $dialog.FindName('StoreValue')
    $imageValue = $dialog.FindName('ImageValue')
    $bootValue = $dialog.FindName('BootValue')
    $powerValue = $dialog.FindName('PowerValue')
    $adDomainValue = $dialog.FindName('AdDomainValue')
    $ouValue = $dialog.FindName('OuValue')
    $warningBorder = $dialog.FindName('ConfirmationWarning')
    $warningText = $dialog.FindName('ConfirmationWarningText')
    $safeguardOne = $dialog.FindName('SafeguardOne')
    $safeguardTwo = $dialog.FindName('SafeguardTwo')
    $safeguardThree = $dialog.FindName('SafeguardThree')
    $technicalText = $dialog.FindName('ConfirmationTechnicalText')
    $acceptButton = $dialog.FindName('AcceptConfirmation')
    $cancelButton = $dialog.FindName('CancelConfirmation')

    $submittedNoun = if ($submittedCount -eq 1) { 'server' } else { 'servers' }
    $readyNoun = if ($readyCount -eq 1) { 'server' } else { 'servers' }
    $heading.Text = "Review all $submittedCount submitted $submittedNoun before provisioning"
    $listHeading.Text = $presentation.ListHeading
    $serverGrid.ItemsSource = $presentation.ServerRows
    $serverGrid.Height = [double]$presentation.TableHeight
    $dialog.Height = [double]$presentation.InitialDialogHeight

    $collectionValue.Text = $presentation.CollectionDisplay
    $collectionValue.ToolTip = $presentation.CollectionDisplay
    $managerValue.Text = $presentation.ManagerDisplay
    $managerValue.ToolTip = $presentation.ManagerDisplay
    $storeValue.Text = $presentation.StoreDisplay
    $storeValue.ToolTip = $presentation.StoreDisplay
    $imageValue.Text = $presentation.ImageDisplay
    $imageValue.ToolTip = $presentation.ImageFull
    $bootValue.Text = $presentation.BootDisplay
    $bootValue.ToolTip = $presentation.BootDisplay
    $powerValue.Text = $presentation.PowerDisplay
    $adDomainValue.Text = $presentation.AdDomainDisplay
    $adDomainValue.ToolTip = $presentation.AdDomainDisplay
    $ouValue.Text = $presentation.OuDisplay
    $ouValue.ToolTip = $presentation.OuFull

    $warningText.Text = $presentation.WarningText
    $warningBorder.Visibility = if ($presentation.HasWarning) { 'Visible' } else { 'Collapsed' }
    $safeguardOne.Text = $presentation.Safeguards[0]
    $safeguardTwo.Text = $presentation.Safeguards[1]
    $safeguardThree.Text = $presentation.Safeguards[2]
    $technicalText.Text = $presentation.TechnicalDetails
    $acceptButton.Content = if ($blockedCount -gt 0) {
        "Build $readyCount Ready; Skip $blockedCount Blocked"
    }
    else {
        "Provision $readyCount $readyNoun"
    }

    $acceptButton.Add_Click({
            $dialog.DialogResult = $true
        })
    $cancelButton.Add_Click({
            $dialog.DialogResult = $false
        })

    Set-WindowInitialBounds -TargetWindow $dialog
    $dialog.Add_PreviewKeyDown({
            param($sender,$eventArgs)
            if ($eventArgs.Key -eq [System.Windows.Input.Key]::Return) {
                $eventArgs.Handled = $true
            }
        })
    $dialog.Add_ContentRendered({
            $null = $cancelButton.Focus()
        })
    return ($dialog.ShowDialog() -eq $true)
}

function Show-AdPowerOverrideDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Contexts)

    [xml]$dialogXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AD verification failed" Width="920" Height="560"
        MinWidth="720" MinHeight="430" WindowStartupLocation="CenterOwner"
        ResizeMode="CanResize" ShowInTaskbar="False">
 <Grid Margin="16">
  <Grid.RowDefinitions>
   <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
   <RowDefinition Height="*"/><RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <TextBlock Grid.Row="0" FontSize="18" FontWeight="SemiBold"
             Text="AD verification failed; explicit power-on decision required" Margin="0,0,0,10"/>
  <TextBlock Grid.Row="1" TextWrapping="Wrap" Margin="0,0,0,10"
             Text="AD machine-account creation or verification was not successful for the servers below. OLVM identity/MAC, PVS target, vDisk, Reboot personality, DHCP reservations, and option 67 were verified. The build remains AttentionRequired. The VM can start without verified AD, but domain trust, Group Policy, authentication, and VDA registration may fail until the AD issue is corrected."/>
  <DataGrid Grid.Row="2" Name="OverrideRows" IsReadOnly="True" AutoGenerateColumns="False"
            CanUserAddRows="False" CanUserDeleteRows="False" VerticalScrollBarVisibility="Auto"
            HorizontalScrollBarVisibility="Auto" Margin="0,0,0,12">
   <DataGrid.Columns>
    <DataGridTextColumn Header="Machine" Binding="{Binding Machine}" Width="130"/>
    <DataGridTextColumn Header="IP address" Binding="{Binding IPAddress}" Width="120"/>
    <DataGridTextColumn Header="Verified vDisk" Binding="{Binding VDisk}" Width="210"/>
    <DataGridTextColumn Header="AD error" Binding="{Binding AdError}" Width="*"/>
   </DataGrid.Columns>
  </DataGrid>
  <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
   <Button Name="KeepOff" Content="Keep Powered Off" MinWidth="145" Margin="0,0,10,0"
           Padding="12,5" IsDefault="True" IsCancel="True"/>
   <Button Name="PowerAnyway" Content="Power On Anyway" MinWidth="145" Padding="12,5"/>
  </StackPanel>
 </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $dialogXaml
    try { $dialog = [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    $dialog.Owner = $script:Window
    $rows = @($Contexts | ForEach-Object {
            [pscustomobject]@{
                Machine   = $_.Record.MachineName
                IPAddress = $_.Record.IPAddress
                VDisk     = $_.Settings.ImageDisplay
                AdError   = $_.AdFailure
            }
        })
    $dialog.FindName('OverrideRows').ItemsSource = $rows
    $dialog.Tag = $false
    $dialog.FindName('PowerAnyway').Add_Click({
            $dialog.Tag = $true
            $dialog.DialogResult = $true
        })
    $dialog.FindName('KeepOff').Add_Click({
            $dialog.Tag = $false
            $dialog.DialogResult = $false
        })
    Set-WindowInitialBounds -TargetWindow $dialog
    $null = $dialog.ShowDialog()
    return ($dialog.Tag -eq $true)
}

function Resolve-AdPowerOverrideDecisions {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Contexts)

    $candidates = [object[]]@($Contexts | Where-Object {
            $_.Settings.PowerOnAfterBuild -and
            $_.Record.Result -eq 'AttentionRequired' -and
            $_.Record.PowerOverrideEligible -eq $true -and
            $_.Record.NonAdPrerequisitesVerified -eq $true
        })
    if ($candidates.Count -eq 0) { return }

    Assert-AuditTrailAvailable
    Assert-FarmBuildLockOwned
    foreach ($context in $candidates) {
        Write-RunLog -Level WARN -Stage 'AD power override' -MachineName $context.Record.MachineName -Message "Eligible for an explicit power-on decision because all non-AD prerequisites passed. Build remains AttentionRequired. AD error: $($context.AdFailure)"
    }
    Suspend-ExecutionClockForConfirmation
    try { $approved = Show-AdPowerOverrideDialog -Contexts $candidates }
    finally { Resume-ExecutionClockAfterConfirmation }

    $operator = Get-CurrentOperatorName
    $timestamp = [DateTime]::UtcNow
    if ($approved) {
        Assert-AuditTrailAvailable
        Assert-FarmBuildLockOwned
    }
    foreach ($context in $candidates) {
        $context.Record.PowerOverrideOperator = $operator
        $context.Record.PowerOverrideTimestamp = $timestamp
        if ($approved) {
            $context.PowerOverrideApproved = $true
            $context.Record.PowerOverrideDecision = 'Approved'
            $context.Record.PowerResult = 'Pending'
            $context.Record.PowerDetails = 'Awaiting power-on after explicit operator approval despite the AD warning.'
        }
        else {
            $context.PowerOverrideApproved = $false
            $context.Record.PowerOverrideDecision = 'Declined'
            $context.Record.PowerResult = 'KeptOffByOperator'
            $context.Record.PowerDetails = 'Kept powered off because the operator did not approve power-on after the AD verification failure.'
        }
        Write-RunLog -Level WARN -Stage 'AD power override' -MachineName $context.Record.MachineName -Message "RunId=$($script:RunId); Operator=$operator; Decision=$($context.Record.PowerOverrideDecision); TimestampUtc=$($timestamp.ToString('o')); AD error=$($context.AdFailure)"
    }
    Refresh-GridRecoverySafe
}
