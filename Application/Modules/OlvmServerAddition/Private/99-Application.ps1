function Start-OlvmServerAdditionGui {
    [CmdletBinding()]
    param()

    $script:Window = $null
    try {
        $script:Window = New-OlvmServerAdditionMainWindow -XamlText $script:MainWindowXamlText
        Initialize-OlvmServerAdditionControlBindings -Window $script:Window
        Initialize-OlvmServerAdditionMainWindowState -Window $script:Window
        Register-OlvmServerAdditionPresentationPorts
        Initialize-OlvmServerAdditionStartupData
        Register-OlvmServerAdditionMainWindowEvents
        Set-StartupSplashStage -Text 'Opening OLVM Server Addition...'
        [void]$script:Window.ShowDialog()
    }
    catch {
        $runtimeErrorRecord = $_
        try { Write-ExceptionLog -Stage 'Application' -ErrorRecord $runtimeErrorRecord } catch {}
        $failureReport = New-ApplicationFailureReport `
            -Phase Runtime `
            -ErrorRecord $runtimeErrorRecord
        Show-OlvmServerAdditionApplicationFailure -FailureReport $failureReport
        throw
    }
    finally {
        Invoke-OlvmServerAdditionApplicationShutdown
    }
}
