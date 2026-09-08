function Reset-OlvmRouteCache {
    <# Route hints are batch-scoped; live VM, NIC, and MAC objects are never cached. #>
    [CmdletBinding()]
    param()

    $routeCount = $script:OlvmVmRouteCache.Count
    $managerCount = $script:OlvmKnownManagers.Count
    $script:OlvmVmRouteCache.Clear()
    $script:OlvmKnownManagers.Clear()
    Write-RunLog -Level INFO -Stage 'OLVM route' -Message "Cleared $routeCount batch-scoped VM route hint(s) and $managerCount known-manager hint(s). The next Validation lookup will establish fresh exact routes."
}

function Add-OlvmKnownManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Manager
    )

    foreach ($knownManager in $script:OlvmKnownManagers) {
        if ($knownManager -ieq $Manager) {
            return
        }
    }
    [void]$script:OlvmKnownManagers.Add($Manager)
}

function Test-OlvmManagerSessionKnown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Manager
    )

    foreach ($sessionManager in $script:OlvmSessionManagers) {
        if ($sessionManager -ieq $Manager) {
            return $true
        }
    }
    return $false
}

function Add-OlvmManagerSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Manager
    )

    if (-not (Test-OlvmManagerSessionKnown -Manager $Manager)) {
        [void]$script:OlvmSessionManagers.Add($Manager)
    }
}

function Get-OlvmFormattedWebErrorMessage {
    <# Detects the success-stream error object emitted by Oracle PoSh-oVirt. #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Output
    )

    $formattedErrors = @($Output | Where-Object {
            $null -ne $_ -and
            $null -ne $_.PSObject.Properties['WebError'] -and
            $null -ne $_.PSObject.Properties['LastCommandExecuted']
        })
    if ($formattedErrors.Count -eq 0) { return '' }

    $messages = @($formattedErrors | ForEach-Object {
            $message = [string]$_.Message
            if ([string]::IsNullOrWhiteSpace($message)) {
                'OLVM returned an unspecified formatted web error.'
            }
            else {
                $message.Trim()
            }
        } | Select-Object -Unique)
    return ($messages -join ' | ')
}

function Connect-OlvmSelectedManagerSession {
    <#
      Establishes only the operator-selected Manager's PoSh-oVirt session.
      The configured credential is held only for this call and is never logged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Manager
    )

    $managerName = ([string]$Manager).Trim()
    if ([string]::IsNullOrWhiteSpace($managerName) -or
        [Uri]::CheckHostName($managerName) -ne [UriHostNameType]::Dns) {
        throw "Selected OLVM Manager '$Manager' is not a valid DNS hostname."
    }
    [string[]]$configuredMatches = @(
        @(
            foreach ($property in @($script:OlvmEngineInventory.PSObject.Properties)) {
                foreach ($rawValue in @($property.Value)) {
                    foreach ($candidate in @(([string]$rawValue) -split '[,;\r\n]+')) {
                        $candidateName = $candidate.Trim()
                        if (-not [string]::IsNullOrWhiteSpace($candidateName) -and
                            $candidateName -ieq $managerName) {
                            $candidateName
                        }
                    }
                }
            }
        ) | Select-Object -Unique
    )
    if ($configuredMatches.Count -ne 1) {
        throw "Selected OLVM Manager '$managerName' does not resolve to exactly one entry in the effective PVS/OLVM Manager inventory."
    }
    $managerName = [string]$configuredMatches[0]
    if (Test-OlvmManagerSessionKnown -Manager $managerName) {
        return
    }

    $credential = $null
    try {
        $connectCommand = Get-Command -Name Connect-oVirtServer -ErrorAction Stop |
            Select-Object -First 1
        foreach ($requiredParameter in 'oVirtServerName','oVirtCredential') {
            if (-not $connectCommand.Parameters.ContainsKey($requiredParameter)) {
                throw "Connect-oVirtServer does not expose required parameter '$requiredParameter'."
            }
        }

        $credential = New-OLVMCredentialObject 3>$null 6>$null
        if ($null -eq $credential) {
            throw 'The configured OLVM credential could not be retrieved.'
        }

        $connectArguments = @{
            oVirtServerName = [string]$managerName
            oVirtCredential = $credential
            ErrorAction     = 'Stop'
        }
        if ($connectCommand.Parameters.ContainsKey('oVirtSSHCredential')) {
            $connectArguments['oVirtSSHCredential'] = $credential
        }

        $connectOutput = [object[]]@(& $connectCommand @connectArguments 3>$null 6>$null)
        $formattedWebError = Get-OlvmFormattedWebErrorMessage -Output $connectOutput
        if (-not [string]::IsNullOrWhiteSpace($formattedWebError)) {
            throw $formattedWebError
        }

        $connected = @($connectOutput | Where-Object {
                if ($null -eq $_) { return $false }
                $isConnectedProperty = $_.PSObject.Properties['IsConnected']
                if ($null -eq $isConnectedProperty) { return $false }
                $isConnected = ($isConnectedProperty.Value -eq $true -or
                    [string]$isConnectedProperty.Value -ieq 'true')
                if (-not $isConnected) { return $false }

                $nameProperty = $_.PSObject.Properties['Name']
                if ($null -eq $nameProperty -or
                    [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
                    return $true
                }
                $returnedName = ([string]$nameProperty.Value).Trim()
                return ($returnedName -ieq $managerName -or
                    $returnedName -ieq $managerName.Split('.')[0])
            })
        if ($connected.Count -eq 0) {
            throw "Connect-oVirtServer did not confirm an authenticated session to '$managerName'."
        }

        Add-OlvmManagerSession -Manager $managerName
    }
    finally {
        $credential = $null
    }
}
