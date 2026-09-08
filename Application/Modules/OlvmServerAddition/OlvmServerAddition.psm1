Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'The OLVM Server Addition module requires Windows PowerShell 5.1 Desktop.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'The OLVM Server Addition module requires 64-bit Windows PowerShell 5.1.'
}
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    throw 'The OLVM Server Addition module requires a single-threaded apartment. Start powershell.exe with -STA.'
}

# Typed WPF parameters in private functions must resolve while the module is
# loaded. The launcher must also load the legacy Citrix snap-in in its caller
# scope before this isolated module session state is created.
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop

$loadedPvsSnapIn = Get-PSSnapin -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue
if ($null -eq $loadedPvsSnapIn) {
    throw 'Citrix.PVS.SnapIn is not visible to the OLVM Server Addition module. Start the application through OLVMServerAddition.ps1 in a fresh Windows PowerShell 5.1 process.'
}
$rootPvsStoreCommands = @(Get-Command -Name Get-PvsStore -ListImported -All -ErrorAction SilentlyContinue)
if ($rootPvsStoreCommands.Count -ne 1 -or
    $rootPvsStoreCommands[0].CommandType -ne [System.Management.Automation.CommandTypes]::Cmdlet -or
    [string]$rootPvsStoreCommands[0].PSSnapIn.Name -cne 'Citrix.PVS.SnapIn') {
    throw 'Get-PvsStore did not resolve uniquely from Citrix.PVS.SnapIn in the OLVM Server Addition module scope. Close Windows PowerShell and start the application through its launcher again.'
}

$script:IsApplicationEntryActive = $false
$script:HasApplicationState = $false
$privateRoot = Join-Path $PSScriptRoot 'Private'
$publicRoot = Join-Path $PSScriptRoot 'Public'
$privateFiles = @(
    '00-State.ps1',
    '05-ObjectPrimitives.ps1',
    '06-CommonNetwork.ps1',
    '07-DistinguishedName.ps1',
    '08-SecurePath.ps1',
    '09-BuildWriteGuard.ps1',
    '10-Audit.ps1',
    '10-ErrorIdentity.ps1',
    '10-ApplicationFailure.ps1',
    '11-Timing.ps1',
    '12-ValidationReadCache.ps1',
    '13-LockMetadata.ps1',
    '14-ApplicationLock.ps1',
    '15-ApplicationHostPresentation.ps1',
    '16-StartupSplash.ps1',
    '17-PresentationPorts.ps1',
    '20-ImportCommon.ps1',
    '21-ImportCsv.ps1',
    '22-ImportXlsx.ps1',
    '23-ImportUi.ps1',
    '30-Dhcp.ps1',
    '40-OlvmSession.ps1',
    '41-OlvmInventory.ps1',
    '42-OlvmPower.ps1',
    '43-OlvmApplication.ps1',
    '50-AdDirectory.ps1',
    '51-PvsTarget.ps1',
    '52-AdPvsBinding.ps1',
    '53-DirectoryDiscovery.ps1',
    '60-PvsStoreImage.ps1',
    '61-PvsPersonality.ps1',
    '70-GuiCore.ps1',
    '75-DependencyTrust.ps1',
    '76-StartupServices.ps1',
    '79-SelectionServices.ps1',
    '80-OuSelection.ps1',
    '81-PvsStoreSelection.ps1',
    '82-PvsImageCache.ps1',
    '83-PvsImageWorker.ps1',
    '84-PvsImagePresentation.ps1',
    '85-FarmBuildLock.ps1',
    '86-DataContracts.ps1',
    '87-ValidationInput.ps1',
    '88-ValidationPlanning.ps1',
    '89-ValidationExecution.ps1',
    '90-BuildExecution.ps1',
    '91-BuildVerification.ps1',
    '92-CompletionPresentation.ps1',
    '93-GuiSelectionLifecycle.ps1',
    '95-MainWindowXaml.ps1',
    '96-MainWindowInitialization.ps1',
    '97-MainWindowEvents.ps1',
    '98-ApplicationLifecycle.ps1',
    '99-Application.ps1'
)
$publicFiles = @(
    'Start-OlvmServerAddition.ps1'
)
if (@($privateFiles | Sort-Object -Unique).Count -ne $privateFiles.Count) {
    throw 'The OLVM Server Addition private-file list contains a duplicate entry.'
}
foreach ($privateFile in $privateFiles) {
    $privatePath = Join-Path $privateRoot $privateFile
    if (-not [System.IO.File]::Exists($privatePath)) {
        throw "Required OLVM Server Addition module component '$privateFile' is missing."
    }
    . $privatePath
}
if (@($publicFiles | Sort-Object -Unique).Count -ne $publicFiles.Count) {
    throw 'The OLVM Server Addition public-file list contains a duplicate entry.'
}
foreach ($publicFile in $publicFiles) {
    $publicPath = Join-Path $publicRoot $publicFile
    if (-not [System.IO.File]::Exists($publicPath)) {
        throw "Required OLVM Server Addition module component '$publicFile' is missing."
    }
    . $publicPath
}

Export-ModuleMember -Function 'Start-OlvmServerAddition'
