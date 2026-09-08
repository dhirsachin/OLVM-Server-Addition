function Start-OlvmServerAddition {
    <#
    .SYNOPSIS
    Starts the OLVM Server Addition graphical application.

    .DESCRIPTION
    Starts one isolated OLVM Server Addition session from the bundled module. The
    command initializes application state, retains the selected PVS and DHCP
    connection inputs, records the launcher path for audit context, prepares
    the supported application host, and opens the graphical workflow.

    Only one session can be active in a PowerShell process. Initialization and
    runtime failures are allowed to propagate to the caller after the
    application's normal cleanup path runs.

    .PARAMETER PvsSoapServer
    Specifies the PVS SOAP server used to establish the farm connection. The
    default is localhost.

    .PARAMETER DhcpServer
    Specifies an optional list that must exactly match every PVS master in the
    connected farm. When omitted, the workflow uses the PVS farm server list
    for DHCP discovery and validation.

    .PARAMETER LaunchScriptPath
    Specifies the full path of the supported launcher script. The command
    normalizes and retains this mandatory value for run-audit context. The
    bundled launcher supplies its own path automatically.

    .INPUTS
    None. This command does not accept pipeline input.

    .OUTPUTS
    None. The command presents status and results in the graphical application
    and writes the configured run log.

    .EXAMPLE
    Start-OlvmServerAddition -LaunchScriptPath 'C:\Tools\OLVMServerAddition\Application\OLVMServerAddition.ps1'

    Starts the application using the local PVS SOAP service and farm-discovered
    DHCP servers.

    .EXAMPLE
    Start-OlvmServerAddition -PvsSoapServer 'pvs01.example.com' -DhcpServer @('pvs01.example.com','pvs02.example.com') -LaunchScriptPath 'C:\Tools\OLVMServerAddition\Application\OLVMServerAddition.ps1'

    Starts the application using an explicit PVS SOAP server and an exact DHCP
    server-list assertion for the connected PVS farm.

    .NOTES
    Run from the bundled launcher on a supported 64-bit Windows PowerShell 5.1
    PVS Console host. The launcher establishes the required STA process and
    Citrix PVS snap-in context before invoking this exported command.
    #>
    [CmdletBinding()]
    param(
        [string]$PvsSoapServer = 'localhost',
        [string[]]$DhcpServer,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LaunchScriptPath
    )

    # The supported launcher may create the splash before importing this
    # module. Consume its one-shot internal handoff without changing the
    # exported command's parameter contract.
    $pendingStartupSplash = $null
    try {
        $pendingVariable = Get-Variable -Name PendingStartupSplash -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $pendingVariable) {
            $pendingStartupSplash = $pendingVariable.Value
        }
    }
    finally {
        Remove-Variable -Name PendingStartupSplash -Scope Script -ErrorAction SilentlyContinue
    }
    $pendingStartupSplashIsUsable = $false
    if ($null -ne $pendingStartupSplash) {
        try {
            $requiredProperties = @('State','ReadyEvent','Runspace','PowerShell','AsyncResult','Disposed')
            $availableProperties = @($pendingStartupSplash.PSObject.Properties.Name)
            $pendingStartupSplashIsUsable =
                @($requiredProperties | Where-Object { $_ -notin $availableProperties }).Count -eq 0 -and
                -not [bool]$pendingStartupSplash.Disposed -and
                $pendingStartupSplash.State -is [System.Collections.IDictionary] -and
                [bool]$pendingStartupSplash.State['Ready'] -and
                -not [bool]$pendingStartupSplash.State['Closed'] -and
                [string]::IsNullOrWhiteSpace([string]$pendingStartupSplash.State['ErrorMessage'])
        }
        catch {
            $pendingStartupSplashIsUsable = $false
        }
    }

    if ($script:IsApplicationEntryActive) {
        throw 'OLVM Server Addition is already active in this PowerShell process.'
    }
    if ($script:HasApplicationState) {
        $residualResources = New-Object 'System.Collections.Generic.List[string]'
        if ($null -ne $script:StartupSplash) { [void]$residualResources.Add('startup splash') }
        if ($script:IsPvsImageCacheWarmupActive -or
            $null -ne $script:PvsImageLoadPowerShell -or
            $null -ne $script:PvsImageLoadRunspace -or
            $null -ne $script:PvsImageLoadAsyncResult) {
            [void]$residualResources.Add('background vDisk reader')
        }
        if ($null -ne $script:LogWriter) { [void]$residualResources.Add('run log') }
        if ($null -ne $script:ActiveFarmBuildLock) { [void]$residualResources.Add('farm Build lock') }
        if ($script:ApplicationMutexOwned -or $null -ne $script:ApplicationMutex) {
            [void]$residualResources.Add('same-server application lock')
        }
        if ($residualResources.Count -gt 0) {
            throw "A previous OLVM Server Addition session in this PowerShell process did not release: $($residualResources -join ', '). Close this PowerShell process before starting the application again."
        }
    }

    $script:IsApplicationEntryActive = $true
    try {
        Initialize-OlvmServerAdditionState
        if ($pendingStartupSplashIsUsable) {
            $script:StartupSplash = $pendingStartupSplash
        }
        $script:HasApplicationState = $true
        $script:PvsSoapServer = $PvsSoapServer
        $script:DhcpServer = if ($null -eq $DhcpServer) { $null } else { [string[]]@($DhcpServer) }
        $script:LaunchScriptPath = [System.IO.Path]::GetFullPath($LaunchScriptPath)
        Initialize-OlvmServerAdditionApplicationHost
        Start-OlvmServerAdditionGui
    }
    finally {
        $script:IsApplicationEntryActive = $false
    }
}
