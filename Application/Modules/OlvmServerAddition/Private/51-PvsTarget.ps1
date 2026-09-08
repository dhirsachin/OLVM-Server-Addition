#region PVS target helpers

function Get-PvsExceptionReturnCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    $depth = 0
    while ($null -ne $exception -and $depth -lt 8) {
        $property = $exception.PSObject.Properties['returnCode']
        if ($null -ne $property -and $null -ne $property.Value) {
            return [int]$property.Value
        }
        $exception = $exception.InnerException
        $depth++
    }
    return $null
}

function Get-PvsDeviceIfPresent {
    [CmdletBinding()]
    param(
        [Parameter(ParameterSetName = 'Name', Mandatory = $true)]
        [string]$Name,

        [Parameter(ParameterSetName = 'Mac', Mandatory = $true)]
        [string]$DeviceMac,

        [Parameter(ParameterSetName = 'Guid', Mandatory = $true)]
        [guid]$Guid,

        # Most callers need only the stable identity fields below. Callers
        # that inspect additional device state can opt into the original
        # unfiltered Get-PvsDevice response without duplicating lookup logic.
        [switch]$AllFields
    )

    try {
        if ($PSCmdlet.ParameterSetName -eq 'Name') {
            if ($AllFields) {
                return @(Get-PvsDevice `
                    -Name $Name `
                    -ErrorAction Stop)
            }
            return @(Get-PvsDevice `
                -Name $Name `
                -Fields Guid,Name,DeviceMac,SiteName,CollectionName `
                -ErrorAction Stop)
        }
        if ($PSCmdlet.ParameterSetName -eq 'Mac') {
            if ($AllFields) {
                return @(Get-PvsDevice `
                    -DeviceMac $DeviceMac `
                    -ErrorAction Stop)
            }
            return @(Get-PvsDevice `
                -DeviceMac $DeviceMac `
                -Fields Guid,Name,DeviceMac,SiteName,CollectionName `
                -ErrorAction Stop)
        }

        # Exact continuation and post-write verification use the immutable GUID
        # retained by Validation or returned by New-PvsDevice.
        $command = Get-Command -Name Get-PvsDevice -ErrorAction Stop |
            Select-Object -First 1
        $arguments = @{
            ErrorAction = 'Stop'
        }
        if (-not $AllFields) {
            $arguments['Fields'] = [string[]]@('Guid','Name','DeviceMac','SiteName','CollectionName')
        }
        if ($command.Parameters.ContainsKey('DeviceId')) {
            $arguments['DeviceId'] = $Guid
        }
        elseif ($command.Parameters.ContainsKey('Guid')) {
            $arguments['Guid'] = $Guid
        }
        else {
            throw 'Get-PvsDevice does not expose a DeviceId or Guid selector; immutable target verification is unavailable.'
        }
        return @(& $command @arguments)
    }
    catch {
        $returnCode = Get-PvsExceptionReturnCode -ErrorRecord $_
        if ($returnCode -eq 43 -or
            $_.Exception.Message -match '(?i)^The specified Device does not exist\.?$') {
            return @()
        }
        throw
    }
}

function Get-PvsTargetDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $devices = @(Get-PvsDeviceIfPresent -Name $Name -AllFields)

    if ($devices.Count -eq 0) { return $null }
    if ($devices.Count -gt 1) {
        throw "PVS returned $($devices.Count) target devices for '$Name'; the result is ambiguous."
    }
    return $devices[0]
}

function Get-PvsAdComputerAccount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Domain
    )

    try {
        $accounts = @(Get-PvsADAccount -Name $Name -Domain $Domain -ErrorAction Stop)
    }
    catch {
        $returnCode = Get-PvsExceptionReturnCode -ErrorRecord $_
        if ($returnCode -in @(43,79) -or
            $_.Exception.Message -match '(?i)^(The specified Device does not exist\.?|Specified computer account not found\..*)$') {
            return $null
        }
        throw
    }

    if ($accounts.Count -eq 0) { return $null }
    if ($accounts.Count -gt 1) {
        throw "PVS returned $($accounts.Count) AD accounts for '$Domain\$Name'; the result is ambiguous."
    }
    return $accounts[0]
}

function Get-ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-PvsDomainTimestamp {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [datetime]) { return ([datetime]$Value -gt [datetime]::MinValue) }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -ieq 'Empty') { return $false }
    $parsed = [datetime]::MinValue
    return ([datetime]::TryParse($text, [ref]$parsed) -and $parsed -gt [datetime]::MinValue)
}

function Assert-PvsTargetCreated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Record,

        [Parameter(Mandatory = $true)]
        [psobject]$Collection,

        [string]$ExpectedGuid
    )

    $devices = @(Get-PvsDeviceIfPresent -Name $Record.MachineName)
    if ($devices.Count -ne 1) {
        throw "PVS target verification expected one record for '$($Record.MachineName)' and found $($devices.Count)."
    }

    $device = $devices[0]
    $actualGuid = [string]$device.Guid
    if (-not [string]::IsNullOrWhiteSpace($ExpectedGuid) -and
        ([guid]$actualGuid -ne [guid]$ExpectedGuid)) {
        throw "PVS target verification returned GUID '$actualGuid', not the target GUID '$ExpectedGuid' created by this run. The replacement target was left unchanged."
    }
    $actualMac = Get-NormalizedMacAddress -Value ([string]$device.DeviceMac)
    if ($actualMac -ine $Record.MacAddress -or
        [string]$device.SiteName -ine [string]$Collection.SiteName -or
        [string]$device.CollectionName -ine [string]$Collection.Name) {
        throw "PVS target verification returned MAC/site/collection '$actualMac / $($device.SiteName) / $($device.CollectionName)', not '$($Record.MacAddress) / $($Collection.SiteName) / $($Collection.Name)'."
    }

    # Verification can run after a write. A broken log must not prevent the
    # caller from receiving the GUID and recording exact retained state.
    Write-RecoveryLog -Level SUCCESS -Stage 'PVS verify' -MachineName $Record.MachineName -Message "Verified PVS target in '$($Collection.SiteName) / $($Collection.Name)' with MAC '$actualMac'."
    return $device
}

function Assert-PvsTargetEligibleForAd {
    <# Refuses to bind AD to a replacement or previously domain-bound target. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineName,

        [Parameter(Mandatory = $true)]
        [guid]$ExpectedPvsGuid
    )

    $device = Get-PvsTargetDevice -Name $MachineName
    if ($null -eq $device) {
        throw "PVS target '$MachineName' was not found after PVS/DHCP creation."
    }
    if ([guid]$device.Guid -ne $ExpectedPvsGuid) {
        throw "PVS target '$MachineName' now has GUID '$($device.Guid)', not the GUID '$ExpectedPvsGuid' created by this run. The replacement target was left unchanged."
    }

    $deviceActive = Get-ObjectPropertyValue -InputObject $device -Name 'Active'
    $deviceDomain = [string](Get-ObjectPropertyValue -InputObject $device -Name 'DomainName')
    $deviceSid = [string](Get-ObjectPropertyValue -InputObject $device -Name 'DomainObjectSID')
    if ($deviceActive -eq $true) {
        throw "PVS target '$MachineName' is active. Shut it down before creating its AD machine account."
    }
    if (-not [string]::IsNullOrWhiteSpace($deviceDomain) -or
        -not [string]::IsNullOrWhiteSpace($deviceSid)) {
        throw "PVS target '$MachineName' already contains domain metadata (DomainName='$deviceDomain', DomainObjectSID='$deviceSid'). It was left unchanged."
    }
    return $device
}

#endregion PVS target helpers
