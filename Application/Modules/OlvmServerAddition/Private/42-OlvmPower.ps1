function Throw-OlvmPowerFailure {
    <# Tags power-read failures so only genuine Manager outages suppress peers. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Manager','Vm')]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $exception = New-Object System.InvalidOperationException -ArgumentList ([string]$Message)
    $exception.Data['OlvmFailureScope'] = $Scope
    throw $exception
}

function Get-OlvmPowerFailureScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $scope = [string]$exception.Data['OlvmFailureScope']
        if ($scope -in @('Manager','Vm')) { return $scope }
        $exception = $exception.InnerException
    }
    return 'Unknown'
}

function Test-OlvmStartRequestAttempted {
    <# Detects an exception raised after crossing the external Start boundary. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception.Data['OlvmStartRequestAttempted'] -eq $true) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Get-OlvmVmPowerSnapshot {
    <# Re-queries one exact OLVM VM and refuses a name-to-ID identity change. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Identity
    )

    $query = Get-OlvmVmQueryResult `
        -Manager ([string]$Identity.Manager) `
        -ResolvedName ([string]$Identity.ResolvedName)
    if (-not $query.Succeeded) {
        Throw-OlvmPowerFailure -Scope Manager -Message "OLVM Manager '$($Identity.Manager)' could not be queried for VM '$($Identity.ResolvedName)': $($query.ErrorMessage)"
    }
    if ($query.Machines.Count -ne 1) {
        Throw-OlvmPowerFailure -Scope Vm -Message "OLVM Manager '$($Identity.Manager)' returned $($query.Machines.Count) VM objects for exact name '$($Identity.ResolvedName)'; expected one."
    }
    $virtualMachine = $query.Machines[0]
    try {
        $vmId = Get-OlvmVmIdentifier -VirtualMachine $virtualMachine
    }
    catch {
        Throw-OlvmPowerFailure -Scope Vm -Message "OLVM returned exact-name VM '$($Identity.ResolvedName)' without a usable immutable identifier: $($_.Exception.Message)"
    }
    if ($vmId -ine [string]$Identity.VmId) {
        Throw-OlvmPowerFailure -Scope Vm -Message "OLVM VM identity changed for '$($Identity.ResolvedName)'. Validated VM ID '$($Identity.VmId)' is now '$vmId'."
    }
    return [pscustomobject]@{
        Manager      = [string]$Identity.Manager
        ResolvedName = [string]$Identity.ResolvedName
        VmId         = $vmId
        Status       = Get-OlvmVmStatusFromObject -VirtualMachine $virtualMachine
    }
}

function Assert-OlvmVmIsDown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$MachineName
    )

    $snapshot = Get-OlvmVmPowerSnapshot -Identity $Identity
    if ($snapshot.Status -ne 'down') {
        $reportedStatus = if ([string]::IsNullOrWhiteSpace($snapshot.Status)) { 'unknown' } else { $snapshot.Status }
        throw "OLVM VM '$MachineName' must be powered off before this build can use the optional post-build power-on action. Current OLVM status: '$reportedStatus'. The tool will never power off or restart an existing VM."
    }
    return $snapshot
}
