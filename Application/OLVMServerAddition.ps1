#requires -Version 5.1
<#
.SYNOPSIS
Launches the bundled OLVM Server Addition PowerShell application.

.DESCRIPTION
Run this launcher in 64-bit Windows PowerShell 5.1 on a configured PVS master.
It imports the versioned local OlvmServerAddition module package and starts the same
OLVM, PVS, DHCP, AD, Validation, Build, logging, and optional power-on workflow.
#>
[CmdletBinding()]
param(
    [string]$PvsSoapServer = 'localhost',
    [string[]]$DhcpServer
)

# Capture process-local monotonic checkpoints before platform, snap-in, and
# module initialization. The audit logger consumes and clears these markers
# after the splash is first rendered.
$startupPowerShellNow = [DateTime]::Now
$startupEpochDate = [DateTime]'1970-01-01'
$startupPowerShellDay = [long][Math]::Floor(
    ($startupPowerShellNow.Date - $startupEpochDate).TotalDays
)
$startupPowerShellLocalMilliseconds = ($startupPowerShellDay * 86400000L) +
    [long][Math]::Floor($startupPowerShellNow.TimeOfDay.TotalMilliseconds)
$env:OLVM_SERVER_ADDITION_PS_LOCAL_MS = $startupPowerShellLocalMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)
$env:OLVM_SERVER_ADDITION_PS_STAMP = [Diagnostics.Stopwatch]::GetTimestamp().ToString([Globalization.CultureInfo]::InvariantCulture)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw 'Run this tool with Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe). The Citrix PVS snap-in and WPF workflow are validated for Windows PowerShell 5.1.'
}
if (-not [Environment]::Is64BitProcess) {
    throw 'Run this tool in 64-bit Windows PowerShell 5.1 so the trusted Citrix, DHCP, and OLVM dependencies resolve from their supported locations.'
}
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    throw 'Run this tool in a single-threaded apartment. Start Windows PowerShell with powershell.exe -STA and launch the script again.'
}

$moduleManifest = Join-Path $PSScriptRoot 'Modules\OlvmServerAddition\OlvmServerAddition.psd1'
$expectedModulePath = [System.IO.Path]::GetFullPath(
    (Join-Path (Split-Path -Parent $moduleManifest) 'OlvmServerAddition.psm1')
)
$startupSplashComponent = Join-Path $PSScriptRoot 'Modules\OlvmServerAddition\Private\16-StartupSplash.ps1'
$startupSplashVersion = '2026.09.04.8'
$startupSplashHandle = $null
$startupSplashCleanupHandle = $null
$moduleInfo = $null
try {
    if (-not [System.IO.File]::Exists($moduleManifest)) {
        throw "The bundled module manifest is missing from '$moduleManifest'. Copy the complete OLVM Server Addition package and try again."
    }
    if (-not [System.IO.File]::Exists($startupSplashComponent)) {
        throw "The bundled startup splash component is missing from '$startupSplashComponent'. Copy the complete OLVM Server Addition package and try again."
    }

    # Display the lightweight splash before loading the PVS snap-in or the main
    # application module. The same worker handle is adopted by the module after
    # its path, version, and exported entry point have been validated.
    $script:ToolVersion = $startupSplashVersion
    $script:StartupSplash = $null
    . $startupSplashComponent
    try {
        $startupSplashHandle = Start-StartupSplash -Version $startupSplashVersion
        $startupSplashCleanupHandle = $startupSplashHandle
        Set-StartupSplashStage -Text 'Loading application components...'
    }
    catch {
        # The splash remains optional. Preserve any incomplete worker handle so
        # the launcher can make a final bounded cleanup attempt.
        $startupSplashCleanupHandle = $script:StartupSplash
    }

    $registeredPvsSnapIn = Get-PSSnapin -Registered -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue
    if ($null -eq $registeredPvsSnapIn) {
        throw 'Citrix.PVS.SnapIn is not registered. Run this tool from a supported PVS Console host.'
    }
    if ($null -eq (Get-PSSnapin -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Citrix.PVS.SnapIn -ErrorAction Stop
    }
    $callerPvsStoreCommands = @(Get-Command -Name Get-PvsStore -ListImported -All -ErrorAction SilentlyContinue)
    if ($callerPvsStoreCommands.Count -ne 1 -or
        $callerPvsStoreCommands[0].CommandType -ne [System.Management.Automation.CommandTypes]::Cmdlet -or
        [string]$callerPvsStoreCommands[0].PSSnapIn.Name -cne 'Citrix.PVS.SnapIn') {
        throw 'Get-PvsStore did not resolve uniquely from Citrix.PVS.SnapIn in the launcher scope. Close Windows PowerShell and try again.'
    }
    $env:OLVM_SERVER_ADDITION_PVS_READY_STAMP = [Diagnostics.Stopwatch]::GetTimestamp().ToString([Globalization.CultureInfo]::InvariantCulture)
    $env:OLVM_SERVER_ADDITION_MODULE_START_STAMP = [Diagnostics.Stopwatch]::GetTimestamp().ToString([Globalization.CultureInfo]::InvariantCulture)
    $loadedByName = @(Get-Module -Name 'OlvmServerAddition' -All)
    $loadedFromOtherPath = @($loadedByName | Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.Path) -or
            [System.IO.Path]::GetFullPath([string]$_.Path) -ine $expectedModulePath
        })
    if ($loadedFromOtherPath.Count -gt 0) {
        $otherPaths = [string](($loadedFromOtherPath | ForEach-Object { [string]$_.Path } | Select-Object -Unique) -join ', ')
        throw "A different OlvmServerAddition module is already loaded from '$otherPaths'. Close this Windows PowerShell process, then launch this package again."
    }
    $loadedFromExpectedPath = @($loadedByName | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.Path) -and
            [System.IO.Path]::GetFullPath([string]$_.Path) -ieq $expectedModulePath
        })
    if ($loadedFromExpectedPath.Count -gt 1) {
        throw "More than one OlvmServerAddition module instance is loaded from '$expectedModulePath'. Close this Windows PowerShell process, then launch this package again."
    }
    if ($loadedFromExpectedPath.Count -eq 1) {
        $moduleInfo = $loadedFromExpectedPath[0]
        $env:OLVM_SERVER_ADDITION_MODULE_LOAD_MODE = 'Reused'
    }
    else {
        $loadedModules = @(Import-Module -Name $moduleManifest -PassThru -ErrorAction Stop)
        if ($loadedModules.Count -ne 1) {
            throw "Expected one bundled OlvmServerAddition module, but Import-Module returned $($loadedModules.Count)."
        }
        $moduleInfo = $loadedModules[0]
        $env:OLVM_SERVER_ADDITION_MODULE_LOAD_MODE = 'Imported'
    }
    if ([System.IO.Path]::GetFullPath([string]$moduleInfo.Path) -ine $expectedModulePath) {
        throw "The loaded OlvmServerAddition module path '$($moduleInfo.Path)' does not match bundled path '$expectedModulePath'."
    }
    if ($moduleInfo.Version -ne [version]'3.0.0') {
        throw "The bundled OlvmServerAddition module version '$($moduleInfo.Version)' does not match required version '3.0.0'."
    }
    $entryCommand = $moduleInfo.ExportedCommands['Start-OlvmServerAddition']
    if ($null -eq $entryCommand -or $entryCommand.Module.Path -cne $moduleInfo.Path) {
        throw 'The bundled module did not export the expected Start-OlvmServerAddition entry command from the imported path.'
    }
    $env:OLVM_SERVER_ADDITION_MODULE_READY_STAMP = [Diagnostics.Stopwatch]::GetTimestamp().ToString([Globalization.CultureInfo]::InvariantCulture)
    if ($null -ne $startupSplashHandle) {
        try {
            $moduleInfo.SessionState.PSVariable.Set('PendingStartupSplash',$startupSplashHandle)
        }
        catch {
            # The splash is presentation only. If its private module-session
            # handoff fails, close it and let the validated entry command use
            # the module's established splash fallback.
            try {
                Stop-StartupSplash -Handle $startupSplashCleanupHandle
                $startupSplashCleanupHandle = $null
            }
            catch {}
            $startupSplashHandle = $null
        }
    }
}
catch {
    $packageError = $_.Exception.Message
    try {
        if ($null -ne $startupSplashCleanupHandle) {
            Stop-StartupSplash -Handle $startupSplashCleanupHandle
        }
    }
    catch {}
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show(
            "The OLVM Server Addition package could not be loaded.`n`n$packageError",
            'OLVM Server Addition - startup stopped',
            'OK',
            'Error'
        ) | Out-Null
    }
    catch {}
    throw
}

try {
    & $entryCommand -PvsSoapServer $PvsSoapServer -DhcpServer $DhcpServer -LaunchScriptPath $PSCommandPath
}
finally {
    # The module normally closes the adopted splash when the main window is
    # rendered. This idempotent fallback also covers failures before adoption.
    try {
        if ($null -ne $startupSplashCleanupHandle) {
            Stop-StartupSplash -Handle $startupSplashCleanupHandle
        }
    }
    catch {}
}
