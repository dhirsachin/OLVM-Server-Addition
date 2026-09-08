function Initialize-Dependencies {
    <# Nothing is written to PVS, DHCP, OLVM, or AD during startup. #>
    [CmdletBinding()]
    param()

    Invoke-PresentationPort -Name 'StartupStage' -Arguments @{ Text = 'Checking required components...' }
    Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = 'Checking the DHCP Server PowerShell module...'; Stage = 'Startup' }
    $windowsModuleRoots = Get-TrustedModuleRoots
    $null = Import-TrustedModule -Name 'DhcpServer' -AllowedRoots $windowsModuleRoots
    $null = Import-TrustedModule -Name 'DnsClient' -AllowedRoots $windowsModuleRoots

    Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = 'Checking the Citrix PVS PowerShell snap-in...'; Stage = 'Startup' }
    $registeredSnapIn = Get-PSSnapin -Registered -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue
    if ($null -eq $registeredSnapIn) {
        throw 'Citrix.PVS.SnapIn is not registered. Run this tool from a supported PVS Console host.'
    }
    if ($null -eq (Get-PSSnapin -Name Citrix.PVS.SnapIn -ErrorAction SilentlyContinue)) {
        Add-PSSnapin Citrix.PVS.SnapIn -ErrorAction Stop
    }
    Write-RunLog -Level SUCCESS -Stage 'Startup' -Message "Loaded Citrix PVS snap-in version '$($registeredSnapIn.Version)'."

    foreach ($commandName in @(
            'Set-PvsConnection','Get-PvsCollection','Get-PvsServer','Get-PvsDevice',
            'New-PvsDevice','Get-PvsADAccount','Add-PvsDeviceToDomain',
            'Get-PvsStore','Get-PvsDiskInfo','Get-PvsDiskLocator','Get-PvsDiskVersion',
            'Get-PvsDiskInventory','Get-PvsDeviceDiskLocatorEnabled','Add-PvsDiskLocatorToDevice',
            'Get-PvsDevicePersonality','Set-PvsDevicePersonality',
            'Get-DhcpServerv4Scope','Get-DhcpServerv4Lease','Get-DhcpServerv4Reservation',
            'Add-DhcpServerv4Reservation',
            'Get-DhcpServerv4OptionDefinition','Get-DhcpServerv4OptionValue',
            'Set-DhcpServerv4OptionValue','Resolve-DnsName')) {
        if ($null -eq (Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            throw "Required PowerShell command '$commandName' is unavailable."
        }
    }
    Assert-InfrastructureCommandProvenance
    Write-RunLog -Level SUCCESS -Stage 'Dependency trust' -Message 'PVS, DHCP, and DNS command provenance was verified after dependency loading.'

    $addReservationCommand = Get-Command -Name Add-DhcpServerv4Reservation -ErrorAction Stop |
        Select-Object -First 1
    if (-not $addReservationCommand.Parameters.ContainsKey('PassThru')) {
        throw 'Add-DhcpServerv4Reservation does not support PassThru, which is required for exact post-write identity verification.'
    }
    $setOptionCommand = Get-Command -Name Set-DhcpServerv4OptionValue -ErrorAction Stop |
        Select-Object -First 1
    if (-not $setOptionCommand.Parameters.ContainsKey('ReservedIP')) {
        throw 'Set-DhcpServerv4OptionValue does not support ReservedIP, which is required to avoid changing server- or scope-level option 67.'
    }
    $addToDomainCommand = Get-Command -Name Add-PvsDeviceToDomain -ErrorAction Stop |
        Select-Object -First 1
    if (-not $addToDomainCommand.Parameters.ContainsKey('DeviceId') -and
        -not $addToDomainCommand.Parameters.ContainsKey('Guid')) {
        throw 'Add-PvsDeviceToDomain does not support a DeviceId or Guid selector. This tool will not use a mutable target name for AD creation because an existing or replacement PVS target must never be modified.'
    }
    $getPvsDeviceCommand = Get-Command -Name Get-PvsDevice -ErrorAction Stop |
        Select-Object -First 1
    if (-not $getPvsDeviceCommand.Parameters.ContainsKey('DeviceId') -and
        -not $getPvsDeviceCommand.Parameters.ContainsKey('Guid')) {
        throw 'Get-PvsDevice does not support a DeviceId or Guid selector, which is required for immutable target verification.'
    }
    $assignDiskCommand = Get-Command -Name Add-PvsDiskLocatorToDevice -ErrorAction Stop |
        Select-Object -First 1
    if (-not $assignDiskCommand.Parameters.ContainsKey('DiskLocatorId') -or
        -not $assignDiskCommand.Parameters.ContainsKey('DeviceId')) {
        throw 'Add-PvsDiskLocatorToDevice does not support immutable DiskLocatorId and DeviceId selectors.'
    }
    $diskInfoCommand = Get-Command -Name Get-PvsDiskInfo -ErrorAction Stop |
        Select-Object -First 1
    if (-not $diskInfoCommand.Parameters.ContainsKey('SiteId') -or
        -not $diskInfoCommand.Parameters.ContainsKey('StoreId')) {
        throw 'Get-PvsDiskInfo does not support immutable SiteId and StoreId filters required for safe image selection.'
    }
    $getDiskLocatorCommand = Get-Command -Name Get-PvsDiskLocator -ErrorAction Stop |
        Select-Object -First 1
    if (-not $getDiskLocatorCommand.Parameters.ContainsKey('DeviceId')) {
        throw 'Get-PvsDiskLocator does not support immutable DeviceId filtering required for safe image verification.'
    }
    $getDeviceDiskEnabledCommand = Get-Command -Name Get-PvsDeviceDiskLocatorEnabled -ErrorAction Stop |
        Select-Object -First 1
    if (-not $getDeviceDiskEnabledCommand.Parameters.ContainsKey('DeviceId') -or
        -not $getDeviceDiskEnabledCommand.Parameters.ContainsKey('DiskLocatorId')) {
        throw 'Get-PvsDeviceDiskLocatorEnabled does not support immutable DeviceId and DiskLocatorId selectors required for safe image verification.'
    }
    $getPersonalityCommand = Get-Command -Name Get-PvsDevicePersonality -ErrorAction Stop |
        Select-Object -First 1
    if (-not $getPersonalityCommand.Parameters.ContainsKey('DeviceId')) {
        throw 'Get-PvsDevicePersonality does not support the immutable DeviceId selector.'
    }
    $setPersonalityCommand = Get-Command -Name Set-PvsDevicePersonality -ErrorAction Stop |
        Select-Object -First 1
    if (-not $setPersonalityCommand.Parameters.ContainsKey('DevicePersonality')) {
        throw 'Set-PvsDevicePersonality does not support the DevicePersonality parameter required for a device-specific update.'
    }

    Invoke-PresentationPort -Name 'StartupStage' -Arguments @{ Text = 'Connecting to PVS...' }
    Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Connecting to the PVS SOAP service on '$script:PvsSoapServer'..."; Stage = 'Startup' }
    Set-PvsConnection -Server $script:PvsSoapServer -ErrorAction Stop | Out-Null
    Write-RunLog -Level SUCCESS -Stage 'Startup' -Message "Connected to the PVS SOAP service on '$script:PvsSoapServer'."
}

function Initialize-OlvmAccess {
    [CmdletBinding()]
    param()

    if ($script:OlvmAccessInitialized) {
        $inventoryVariable = Get-Variable -Name OlvmEngineInventory -Scope Script -ErrorAction SilentlyContinue
        if ($null -eq $inventoryVariable -or
            ($inventoryVariable.Value | Measure-Object).Count -eq 0) {
            throw 'The OLVM initialization flag is set but its Manager inventory is unavailable. Close the tool and start a clean session.'
        }
        return
    }

    Remove-Variable -Name OlvmEngineInventory -Scope Script -ErrorAction SilentlyContinue
    try {
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = 'Loading the OLVM integration modules...'; Stage = 'OLVM startup' }
        $trustedOlvmRoots = Get-TrustedModuleRoots -IncludeProgramFiles
        foreach ($moduleName in 'PVSImageMan','CWxPVS','Posh-oVirt') {
            $null = Import-TrustedModule -Name $moduleName -AllowedRoots $trustedOlvmRoots
        }
        Assert-OlvmCommandProvenance
        # Later imports must not be able to shadow the already-validated PVS,
        # DHCP, or DNS commands used at production write boundaries.
        Assert-InfrastructureCommandProvenance

        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = 'Reading the configured OLVM Manager inventory from PVS configuration...'; Stage = 'OLVM startup' }
        $null = Pull-PVSConfiguration 3>$null 6>$null
        $configValues = Export-WorkingPVSConfiguration
        if ($null -eq $configValues -or
            $null -eq $configValues.ImageManagement -or
            $null -eq $configValues.ImageManagement.OLVMEngines) {
            throw 'PVS/OLVM configuration or its OLVM Manager inventory was not available.'
        }

        # Credential retrieval is deferred until the first authenticated
        # Manager connection. Startup publishes only validated configuration.
        $engineInventory = $configValues.ImageManagement.OLVMEngines
        $managerNames = @(
            foreach ($property in @($engineInventory.PSObject.Properties)) {
                foreach ($rawValue in @($property.Value)) {
                    foreach ($candidate in @(([string]$rawValue) -split '[,;\r\n]+')) {
                        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                            $candidate.Trim().ToLowerInvariant()
                        }
                    }
                }
            }
        ) | Sort-Object -Unique
        $managerCount = @($managerNames).Count
        if ($managerCount -eq 0) {
            throw 'The PVS/OLVM configuration contains no OLVM Manager records.'
        }
        $script:OlvmEngineInventory = $engineInventory
        $script:OlvmAccessInitialized = $true
        Write-RunLog -Level SUCCESS -Stage 'OLVM startup' -Message "OLVM access initialized with $managerCount distinct configured Manager name(s). Credentials were intentionally not logged or retained by this function."
    }
    catch {
        $initializationError = $_
        $script:OlvmAccessInitialized = $false
        Remove-Variable -Name OlvmEngineInventory -Scope Script -ErrorAction SilentlyContinue
        Write-ExceptionLog -Stage 'OLVM startup' -ErrorRecord $initializationError
        throw $initializationError
    }
    finally {
        # Do not retain the configuration wrapper after publishing its
        # validated Manager inventory.
        $configValues = $null
    }
}

function Get-OlvmManagerChoices {
    <# Flattens the configured regional OLVM inventory without changing it. #>
    [CmdletBinding()]
    param()

    Initialize-OlvmAccess
    $choices = New-Object 'System.Collections.Generic.List[object]'
    [void]$choices.Add([pscustomobject]@{
            Mode                = 'Auto'
            Region              = ''
            Manager             = ''
            Display             = 'Auto-detect (Recommended)'
            IsAvailable         = $true
            AvailabilityMessage = ''
        })
    $seen = @{}
    foreach ($property in @($script:OlvmEngineInventory.PSObject.Properties)) {
        $region = ([string]$property.Name).Trim().ToUpperInvariant()
        $rawValues = @($property.Value)
        foreach ($rawValue in $rawValues) {
            foreach ($candidate in @(([string]$rawValue) -split '[,;\r\n]+')) {
                $managerName = $candidate.Trim()
                if ([string]::IsNullOrWhiteSpace($managerName)) { continue }
                $key = $managerName.ToLowerInvariant()
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true

                $available = $true
                $availabilityMessage = ''
                if ([Uri]::CheckHostName($managerName) -ne [UriHostNameType]::Dns) {
                    $available = $false
                    $availabilityMessage = 'The configured value is not a valid DNS hostname.'
                }
                else {
                    try {
                        $arguments = @{
                            Name        = $managerName
                            Type        = 'A'
                            DnsOnly     = $true
                            ErrorAction = 'Stop'
                        }
                        $resolveCommand = Get-Command -Name Resolve-DnsName -ErrorAction Stop | Select-Object -First 1
                        if ($resolveCommand.Parameters.ContainsKey('QuickTimeout')) {
                            $arguments['QuickTimeout'] = $true
                        }
                        $records = @(& $resolveCommand @arguments | Where-Object {
                                $_.Type -eq 'A' -and -not [string]::IsNullOrWhiteSpace([string]$_.IPAddress
                            )
                            })
                        if ($records.Count -eq 0) {
                            throw 'No A record was returned.'
                        }
                    }
                    catch {
                        $available = $false
                        $availabilityMessage = $_.Exception.Message
                    }
                }

                if (-not $available) {
                    Write-RunLog -Level WARN -Stage 'OLVM startup' -Message "Configured OLVM Manager '$managerName' in region '$region' is unavailable and will be disabled in the selector. The central PVSImageMan configuration was not changed. $availabilityMessage"
                }
                [void]$choices.Add([pscustomobject]@{
                        Mode                = 'Explicit'
                        Region              = $region
                        Manager             = $managerName
                        Display             = "$region - $managerName"
                        IsAvailable         = $available
                        AvailabilityMessage = $availabilityMessage
                    })
            }
        }
    }
    if ($choices.Count -le 1) {
        throw 'The PVS/OLVM configuration contains no usable OLVM Manager names.'
    }
    Write-RunLog -Level SUCCESS -Stage 'OLVM startup' -Message "Loaded $($choices.Count - 1) distinct configured OLVM Manager choice(s), plus Auto-detect."
    return [object[]]$choices.ToArray()
}
