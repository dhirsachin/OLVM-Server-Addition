function Register-PresentationPort {
    <# Registers one synchronous Presentation adapter for the current application run. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'Status','RecoveryStatus','StartupStage','ProgressRecoverySafe',
            'ResponsiveWait','GridRefresh','GridRefreshRecoverySafe',
            'SuspendExecutionClock','ResumeExecutionClock','ReadBuildRequest',
            'ProvisioningConfirmation','AdPowerOverrideDecisions','StaleFarmLockRecovery',
            'SetBuildEnabled','SetProgressIndeterminate','SetProgressMinimum',
            'SetProgressMaximum','SetProgressValue'
        )]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [scriptblock]$Adapter
    )

    if ($null -eq $script:PresentationPorts) {
        throw 'The Presentation port registry is unavailable. Initialize application state before registering adapters.'
    }
    if ($script:PresentationPorts.ContainsKey($Name)) {
        throw "Presentation port '$Name' is already registered for this application run."
    }
    [void]$script:PresentationPorts.Add($Name,$Adapter)
}

function Invoke-PresentationPort {
    <# Invokes one registered adapter inline and forwards its output and terminating errors unchanged. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'Status','RecoveryStatus','StartupStage','ProgressRecoverySafe',
            'ResponsiveWait','GridRefresh','GridRefreshRecoverySafe',
            'SuspendExecutionClock','ResumeExecutionClock','ReadBuildRequest',
            'ProvisioningConfirmation','AdPowerOverrideDecisions','StaleFarmLockRecovery',
            'SetBuildEnabled','SetProgressIndeterminate','SetProgressMinimum',
            'SetProgressMaximum','SetProgressValue'
        )]
        [string]$Name,

        [AllowEmptyCollection()]
        [System.Collections.IDictionary]$Arguments = @{}
    )

    if ($null -eq $script:PresentationPorts -or
        -not $script:PresentationPorts.ContainsKey($Name)) {
        throw "Presentation port '$Name' is not registered for this application run."
    }

    $adapter = [scriptblock]$script:PresentationPorts[$Name]
    & $adapter $Arguments
}
