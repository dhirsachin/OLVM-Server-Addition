function Register-OlvmServerAdditionPresentationPorts {
    <# Binds the synchronous Presentation implementation after GUI controls exist. #>
    [CmdletBinding()]
    param()

    Register-PresentationPort -Name 'Status' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Set-Status @Arguments
    }
    Register-PresentationPort -Name 'RecoveryStatus' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Set-RecoveryStatus @Arguments
    }
    Register-PresentationPort -Name 'StartupStage' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Set-StartupSplashStage @Arguments
    }
    Register-PresentationPort -Name 'ProgressRecoverySafe' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Set-ProgressRecoverySafe @Arguments
    }
    Register-PresentationPort -Name 'ResponsiveWait' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Wait-GuiResponsive @Arguments
    }
    Register-PresentationPort -Name 'GridRefresh' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Refresh-Grid @Arguments
    }
    Register-PresentationPort -Name 'GridRefreshRecoverySafe' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Refresh-GridRecoverySafe @Arguments
    }
    Register-PresentationPort -Name 'SuspendExecutionClock' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Suspend-ExecutionClockForConfirmation @Arguments
    }
    Register-PresentationPort -Name 'ResumeExecutionClock' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Resume-ExecutionClockAfterConfirmation @Arguments
    }
    Register-PresentationPort -Name 'ReadBuildRequest' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Read-GuiBuildRequest @Arguments
    }
    Register-PresentationPort -Name 'ProvisioningConfirmation' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Show-ProvisioningConfirmationDialog @Arguments
    }
    Register-PresentationPort -Name 'AdPowerOverrideDecisions' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        Resolve-AdPowerOverrideDecisions @Arguments
    }
    Register-PresentationPort -Name 'StaleFarmLockRecovery' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        [System.Windows.MessageBox]::Show(
            $script:Window,
            "The farm lock file is not held by another process, but a stale file remains.`n`n$($Arguments.OwnerText)`n`nRecover this stale lock and continue to the normal Build confirmation?`n`nYes = recover and continue`nNo = cancel Build",
            'Recover stale farm Build lock?',
            'YesNo',
            'Warning',
            'No'
        )
    }
    Register-PresentationPort -Name 'SetBuildEnabled' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        $script:Create.IsEnabled = $Arguments.Enabled
    }
    Register-PresentationPort -Name 'SetProgressIndeterminate' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        $script:Progress.IsIndeterminate = $Arguments.Value
    }
    Register-PresentationPort -Name 'SetProgressMinimum' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        $script:Progress.Minimum = $Arguments.Value
    }
    Register-PresentationPort -Name 'SetProgressMaximum' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        $script:Progress.Maximum = $Arguments.Value
    }
    Register-PresentationPort -Name 'SetProgressValue' -Adapter {
        param([System.Collections.IDictionary]$Arguments)
        $script:Progress.Value = $Arguments.Value
    }
}

function New-OlvmServerAdditionMainWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$XamlText
    )

    [xml]$xaml = $XamlText
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    try {
        return [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        $reader.Dispose()
    }
}

function Initialize-OlvmServerAdditionControlBindings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Window
    )

    $controlNames = @(
        'ServerList','ImportServers','Collection','AssignImageYes','AssignImageNo','PvsStore','PvsImage','OlvmManager',
        'BootBios','BootUefi','PvsCaseUpper','PvsCaseLower',
        'DhcpCaseUpper','DhcpCaseLower','ReservationHost','ReservationFqdn',
        'AdDnsDomain','PowerOnYes','PowerOnNo',
        'OuSelector','OrganizationalUnit','Preview','Create',
        'Progress','ResultGrid','ViewDetails','OpenLog','Reset','Status','ExecutionNote',
        'BusyOverlay',
        'ProvisioningSettingsGroup','ProvisioningSettingsLayout',
        'NamingSettingsGroup','NamingSettingsLayout',
        'DestinationGroup','DestinationLayout','ServerInputPanel','AdDestinationPanel',
        'ResultsGroup','MainLayout','HeaderPanel','ActionBar','ServerListBorder'
    )
    foreach ($name in $controlNames) {
        $control = $Window.FindName($name)
        if ($null -eq $control) {
            throw "The GUI control '$name' could not be loaded."
        }
        Set-Variable -Name $name -Value $control -Scope Script
    }
}

function Initialize-OlvmServerAdditionMainWindowState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Window
    )

    $Window.Title = "$($script:ToolName) v$($script:ToolVersion)"
    $script:OpenLog.ToolTip = "Open the current run log in Notepad: $script:LogPath"
    Set-ValidationBuildState -ValidationRecords ([object[]]@()) -BuildContexts $null
    $script:InputControls = @(
        $script:ServerList,$script:ImportServers,$script:Collection,$script:AssignImageYes,$script:AssignImageNo,$script:PvsStore,
        $script:PvsImage,$script:OlvmManager,$script:PowerOnYes,$script:PowerOnNo,
        $script:BootBios,$script:BootUefi,$script:PvsCaseUpper,$script:PvsCaseLower,
        $script:DhcpCaseUpper,$script:DhcpCaseLower,$script:ReservationHost,$script:ReservationFqdn,
        $script:AdDnsDomain,$script:OuSelector
    )
    $script:InputSections = @(
        $script:ProvisioningSettingsGroup,$script:NamingSettingsGroup,$script:DestinationGroup
    )
}

function Initialize-OlvmServerAdditionStartupData {
    [CmdletBinding()]
    param()

    Set-StartupSplashStage -Text 'Checking required components...'
    Initialize-Dependencies
    Set-StartupSplashStage -Text 'Loading PVS collections...'
    Set-Status -Text 'Reading PVS device collections...' -Stage 'Startup'
    $collections = @(Get-PvsCollection -Fields Guid,Name,SiteId,SiteName -ErrorAction Stop |
        Sort-Object SiteName,Name |
        ForEach-Object {
            [pscustomobject]@{
                Guid     = $_.Guid
                Name     = $_.Name
                SiteId   = $_.SiteId
                SiteName = $_.SiteName
                Display  = "$($_.SiteName) / $($_.Name)"
            }
        })
    if ($collections.Count -eq 0) {
        throw 'No PVS device collections were returned.'
    }
    $script:Collection.IsSynchronizedWithCurrentItem = $false
    $script:Collection.ItemsSource = $collections

    Set-StartupSplashStage -Text 'Loading PVS Stores...'
    Set-Status -Text 'Reading PVS Store inventory for every configured Site...' -Stage 'PVS Store startup'
    $storeInventory = Initialize-PvsStoreChoicesCache -Collections $collections
    Assert-AuditTrailAvailable

    # Every provisioning choice requires an explicit operator selection.
    Set-StartupSplashStage -Text 'Loading OLVM Managers...'
    $managerChoices = @(Get-OlvmManagerChoices)
    $script:OlvmManager.ItemsSource = $managerChoices
    foreach ($comboBox in @($script:Collection,$script:PvsStore,$script:PvsImage,$script:OuSelector)) {
        $comboBox.SelectedIndex = -1
    }
    $script:OlvmManager.SelectedIndex = 0
    foreach ($radioButton in @(
            $script:BootBios,$script:BootUefi,$script:PvsCaseUpper,$script:PvsCaseLower,
            $script:DhcpCaseUpper,$script:DhcpCaseLower,$script:ReservationHost,$script:ReservationFqdn)) {
        $radioButton.IsChecked = $false
    }
    $script:PvsStore.ItemsSource = @()
    $script:PvsImage.ItemsSource = @()
    $script:OuSelector.ItemsSource = @()
    $script:SelectedPvsImage = $null
    $script:AssignImageYes.IsChecked = $false
    $script:AssignImageNo.IsChecked = $true
    Reset-PowerOnChoice
    Sync-OptionalImagePowerUiState
    Set-StartupSplashStage -Text 'Detecting DNS domain...'
    $script:AdDnsDomain.Text = Get-SelectionDefaultDnsDomain
    Set-StartupSplashStage -Text 'Loading Active Directory OUs...'
    $ouStartup = Initialize-OuChoicesForCurrentDomain -Source 'Startup'
    Set-StartupSplashStage -Text 'Preparing background vDisk loading...'
    $warmupRequests = @(Initialize-PvsImageWarmupRequests -Collections $collections)
    $storeStartupNote = if ($storeInventory.FailedSites -gt 0) {
        " Preloaded $($storeInventory.StoreCount) Store choice(s) across $($storeInventory.LoadedSites) PVS Site(s); $($storeInventory.FailedSites) Site query failed. Assign Image remains optional and selecting Yes for an affected Site will retry."
    }
    else {
        " Preloaded $($storeInventory.StoreCount) Store choice(s) across $($storeInventory.LoadedSites) PVS Site(s)."
    }
    $ouStartupNote = if ($ouStartup.Succeeded) {
        " Preloaded $($ouStartup.Count) OU choice(s) for '$($ouStartup.Domain)'."
    }
    elseif ($ouStartup.Skipped) {
        ' OU preload was skipped because an AD DNS domain was not detected.'
    }
    else {
        " OU preload for '$($ouStartup.Domain)' failed; opening the OU list will retry."
    }
    $startupHasWarning = $storeInventory.FailedSites -gt 0 -or -not $ouStartup.Succeeded
    $startupLevel = if ($startupHasWarning) { 'WARN' } else { 'SUCCESS' }
    $startupColor = if ($startupHasWarning) { 'DarkOrange' } else { 'Green' }
    Write-RunLog -Level $startupLevel -Stage 'Startup' -Message "Loaded $($collections.Count) PVS collection(s): $(($collections.Display) -join ', ').$storeStartupNote$ouStartupNote Prepared $($warmupRequests.Count) unique Site and Store pair(s) for non-blocking vDisk cache warming."
    Set-Status -Text "Ready. Loaded $($collections.Count) PVS collection(s).$storeStartupNote$ouStartupNote Enter servers, select the required settings and an AD OU. Image assignment and power-on are optional." -Color $startupColor -Stage 'Startup'
}
