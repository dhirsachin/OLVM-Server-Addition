@{
    RootModule        = 'OlvmServerAddition.psm1'
    ModuleVersion     = '3.0.0'
    GUID              = '0c64599b-2183-48a4-9c04-de5c015ecad3'
    Author            = 'OLVM Server Addition'
    Description       = 'Bundled implementation module for the OLVM Server Addition PowerShell GUI.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Start-OlvmServerAddition')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    FileList          = @(
        'OlvmServerAddition.psm1',
        'Private/00-State.ps1',
        'Private/05-ObjectPrimitives.ps1',
        'Private/06-CommonNetwork.ps1',
        'Private/07-DistinguishedName.ps1',
        'Private/08-SecurePath.ps1',
        'Private/09-BuildWriteGuard.ps1',
        'Private/10-Audit.ps1',
        'Private/10-ErrorIdentity.ps1',
        'Private/10-ApplicationFailure.ps1',
        'Private/11-Timing.ps1',
        'Private/12-ValidationReadCache.ps1',
        'Private/13-LockMetadata.ps1',
        'Private/14-ApplicationLock.ps1',
        'Private/15-ApplicationHostPresentation.ps1',
        'Private/16-StartupSplash.ps1',
        'Private/17-PresentationPorts.ps1',
        'Private/20-ImportCommon.ps1',
        'Private/21-ImportCsv.ps1',
        'Private/22-ImportXlsx.ps1',
        'Private/23-ImportUi.ps1',
        'Private/30-Dhcp.ps1',
        'Private/40-OlvmSession.ps1',
        'Private/41-OlvmInventory.ps1',
        'Private/42-OlvmPower.ps1',
        'Private/43-OlvmApplication.ps1',
        'Private/50-AdDirectory.ps1',
        'Private/51-PvsTarget.ps1',
        'Private/52-AdPvsBinding.ps1',
        'Private/53-DirectoryDiscovery.ps1',
        'Private/60-PvsStoreImage.ps1',
        'Private/61-PvsPersonality.ps1',
        'Private/70-GuiCore.ps1',
        'Private/75-DependencyTrust.ps1',
        'Private/76-StartupServices.ps1',
        'Private/79-SelectionServices.ps1',
        'Private/80-OuSelection.ps1',
        'Private/81-PvsStoreSelection.ps1',
        'Private/82-PvsImageCache.ps1',
        'Private/83-PvsImageWorker.ps1',
        'Private/84-PvsImagePresentation.ps1',
        'Private/85-FarmBuildLock.ps1',
        'Private/86-DataContracts.ps1',
        'Private/87-ValidationInput.ps1',
        'Private/88-ValidationPlanning.ps1',
        'Private/89-ValidationExecution.ps1',
        'Private/90-BuildExecution.ps1',
        'Private/91-BuildVerification.ps1',
        'Private/92-CompletionPresentation.ps1',
        'Private/93-GuiSelectionLifecycle.ps1',
        'Private/95-MainWindowXaml.ps1',
        'Private/96-MainWindowInitialization.ps1',
        'Private/97-MainWindowEvents.ps1',
        'Private/98-ApplicationLifecycle.ps1',
        'Private/99-Application.ps1',
        'Public/Start-OlvmServerAddition.ps1'
    )
}
