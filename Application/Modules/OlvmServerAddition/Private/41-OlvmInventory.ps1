function Get-OlvmVmQueryResult {
    <#
      Queries one already-selected manager. Errors are returned as data so the
      caller can safely evict a stale route and perform full discovery once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Manager,

        [Parameter(Mandatory = $true)]
        [string]$ResolvedName
    )

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $machines = [object[]]@()
    $errorMessage = ''
    $errorIdentity = $null
    try {
        $queryOutput = [object[]]@(Get-oVM `
            -Name $ResolvedName `
            -oVirtServerName $Manager `
            -Syncopate `
            3>$null 6>$null)
        $formattedWebError = Get-OlvmFormattedWebErrorMessage -Output $queryOutput
        if (-not [string]::IsNullOrWhiteSpace($formattedWebError)) {
            $errorMessage = $formattedWebError
            $formattedException = [System.InvalidOperationException]::new($formattedWebError)
            $formattedErrorRecord = [System.Management.Automation.ErrorRecord]::new(
                $formattedException,
                'OlvmFormattedWebError',
                [System.Management.Automation.ErrorCategory]::InvalidResult,
                $Manager
            )
            $errorIdentity = New-SerializableErrorIdentity `
                -ErrorRecord $formattedErrorRecord `
                -Disposition 'Retryable' `
                -AdditionalData ([ordered]@{ Manager=$Manager; ResolvedName=$ResolvedName })
        }
        else {
            $machines = $queryOutput
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $errorIdentity = New-SerializableErrorIdentity `
            -ErrorRecord $_ `
            -Disposition 'Retryable' `
            -AdditionalData ([ordered]@{ Manager=$Manager; ResolvedName=$ResolvedName })
    }
    finally {
        $timer.Stop()
    }

    return [pscustomobject]@{
        Succeeded           = [string]::IsNullOrWhiteSpace($errorMessage)
        Machines            = [object[]]$machines
        ErrorMessage        = $errorMessage
        ElapsedMilliseconds = [long]$timer.ElapsedMilliseconds
        ErrorIdentity       = $errorIdentity
    }
}

function Get-OlvmVmIdentifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$VirtualMachine
    )

    foreach ($propertyName in 'Id','id','Guid','guid') {
        $property = $VirtualMachine.PSObject.Properties[$propertyName]
        if ($null -ne $property -and
            -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return ([string]$property.Value).Trim()
        }
    }
    throw 'OLVM returned the VM without an immutable VM identifier.'
}

function Get-NormalizedOlvmVmStatus {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Status
    )

    if ($null -eq $Status) { return '' }
    $valueProperty = $Status.PSObject.Properties['value']
    if ($null -ne $valueProperty) {
        $Status = $valueProperty.Value
    }
    return (([string]$Status).Trim().ToLowerInvariant() -replace '[\s-]+','_')
}

function Get-OlvmVmStatusFromObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$VirtualMachine
    )

    foreach ($propertyName in 'Status','status','PowerState','power_state') {
        $property = $VirtualMachine.PSObject.Properties[$propertyName]
        if ($null -ne $property) {
            return (Get-NormalizedOlvmVmStatus -Status $property.Value)
        }
    }
    return ''
}

function Get-OlvmRouteIdentity {
    <# Returns only immutable, freshly verified routing data cached by Get-OlvmMac. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineName
    )

    $cacheKey = $MachineName.Trim().ToUpperInvariant()
    if (-not $script:OlvmVmRouteCache.ContainsKey($cacheKey)) {
        throw "No verified OLVM identity is available for '$MachineName'. Run the live MAC lookup again."
    }
    $route = $script:OlvmVmRouteCache[$cacheKey]
    if ([string]::IsNullOrWhiteSpace([string]$route.Manager) -or
        [string]::IsNullOrWhiteSpace([string]$route.ResolvedName) -or
        [string]::IsNullOrWhiteSpace([string]$route.VmId)) {
        throw "The verified OLVM route for '$MachineName' is incomplete."
    }
    return [pscustomobject]@{
        Manager      = [string]$route.Manager
        ResolvedName = [string]$route.ResolvedName
        VmId         = [string]$route.VmId
        Status       = [string]$route.Status
    }
}
