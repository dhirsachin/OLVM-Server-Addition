function Assert-OlvmPowerCommandAvailable {
    [CmdletBinding()]
    param()

    Initialize-OlvmAccess
    $command = Get-Command -Name Set-oVMPowerState -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        throw "Optional power-on was selected, but the required OLVM command 'Set-oVMPowerState' is unavailable."
    }
    Assert-CommandProvenance `
        -Names @('Set-oVMPowerState') `
        -AllowedModuleNames @('PVSImageMan','CWxPVS','Posh-oVirt')
    foreach ($parameterName in 'PowerState','oVirtServerName') {
        if (-not $command.Parameters.ContainsKey($parameterName)) {
            throw "Set-oVMPowerState does not expose required parameter '$parameterName'."
        }
    }
    if (-not $command.Parameters.ContainsKey('Id')) {
        throw "Set-oVMPowerState does not expose the immutable Id selector required for safe power-on. This tool will not start a VM by its mutable name."
    }
}

function Get-OlvmMac {
    <#
      A selected Manager is a Validation preference only when
      FallbackToAutoDetect is explicitly enabled. Exact-identity safety
      boundaries omit that switch and therefore remain pinned to their
      already-validated Manager.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineName,

        [AllowEmptyString()]
        [string]$SelectedManager = '',

        [switch]$FallbackToAutoDetect
    )

    Initialize-OlvmAccess
    $totalTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $trimmedName = $MachineName.Trim()
    $cacheKey = $trimmedName.ToUpperInvariant()
    $lookupNames = @(
        $trimmedName,
        $trimmedName.ToUpperInvariant(),
        $trimmedName.ToLowerInvariant()
    ) | Select-Object -Unique

    $manager = $null
    $resolvedName = $null
    $virtualMachines = [object[]]@()
    $routeSource = 'Discovery'
    $hadCachedRoute = $false
    $knownManagerAttempted = $false
    $discoveryMilliseconds = [long]0
    $vmQueryMilliseconds = [long]0
    $nicQueryMilliseconds = [long]0
    $connectionMilliseconds = [long]0
    $attemptedManagers = @{}
    $routeFailures = New-Object 'System.Collections.Generic.List[string]'
    $selectedManagerFallbackUsed = $false
    $selectedManagerBootstrapUsed = $false
    $selectedManagerFailure = ''
    $autoDetectActive = [string]::IsNullOrWhiteSpace($SelectedManager)

    if (-not [string]::IsNullOrWhiteSpace($SelectedManager)) {
        $explicitManager = $SelectedManager.Trim()
        $attemptedManagers[$explicitManager] = $true
        $selectedManagerReady = $true
        if (-not (Test-OlvmManagerSessionKnown -Manager $explicitManager)) {
            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Connecting to selected OLVM Manager '$explicitManager'..."; Stage = 'OLVM selected manager'; MachineName = $trimmedName }
            Write-RunLog -Level INFO -Stage 'OLVM selected manager' -MachineName $trimmedName -Message "Connecting only to selected OLVM Manager '$explicitManager' before querying VM '$trimmedName'."
            $connectionTimer = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                Connect-OlvmSelectedManagerSession -Manager $explicitManager
                $selectedManagerBootstrapUsed = $true
                Write-RunLog -Level SUCCESS -Stage 'OLVM selected manager' -MachineName $trimmedName -Message "Connected to selected OLVM Manager '$explicitManager'."
            }
            catch {
                $selectedManagerReady = $false
                $selectedManagerFailure = "Selected OLVM Manager '$explicitManager' could not establish an authenticated session: $($_.Exception.Message)"
            }
            finally {
                $connectionTimer.Stop()
                $connectionMilliseconds += $connectionTimer.ElapsedMilliseconds
            }
        }

        if ($selectedManagerReady) {
            foreach ($lookupName in $lookupNames) {
                Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Checking selected OLVM Manager '$explicitManager' for VM '$lookupName'..."; Stage = 'OLVM selected manager'; MachineName = $trimmedName }
                $query = Get-OlvmVmQueryResult -Manager $explicitManager -ResolvedName $lookupName
                $vmQueryMilliseconds += $query.ElapsedMilliseconds

                if (-not $query.Succeeded) {
                    $selectedManagerFailure = "Selected OLVM Manager '$explicitManager' could not be queried for exact VM name '$lookupName': $($query.ErrorMessage)"
                    break
                }
                if ($query.Machines.Count -gt 1) {
                    throw "Selected OLVM Manager '$explicitManager' returned $($query.Machines.Count) VMs for exact name '$lookupName'. The result is ambiguous."
                }
                if ($query.Machines.Count -eq 1) {
                    $manager = $explicitManager
                    $resolvedName = $lookupName
                    $virtualMachines = [object[]]$query.Machines
                    $routeSource = if ($selectedManagerBootstrapUsed) { 'SelectedManagerConnection' } else { 'SelectedManager' }
                    break
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($manager)) {
            if ([string]::IsNullOrWhiteSpace($selectedManagerFailure)) {
                $selectedManagerFailure = "Selected OLVM Manager '$explicitManager' did not return VM '$MachineName' using the entered, uppercase, or lowercase exact name."
            }
            if (-not $FallbackToAutoDetect) {
                throw "$selectedManagerFailure Auto-detection is disabled at this exact-Manager safety boundary."
            }
            $selectedManagerFallbackUsed = $true
            $autoDetectActive = $true
            [void]$routeFailures.Add($selectedManagerFailure)
            Write-RunLog -Level WARN -Stage 'OLVM selected manager' -MachineName $trimmedName -Message "$selectedManagerFailure Automatically switching to Auto-detect for this VM."
            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Selected OLVM Manager '$explicitManager' was unsuccessful for '$MachineName'. Running Auto-detect..."; Color = 'DarkOrange'; Stage = 'OLVM discovery'; MachineName = $trimmedName }
        }
    }

    # A cached route only avoids manager discovery. It is removed before use
    # and restored only after a fresh VM, NIC, and unique MAC lookup succeeds.
    if ($autoDetectActive -and
        $script:OlvmVmRouteCache.ContainsKey($cacheKey)) {
        $hadCachedRoute = $true
        $cachedRoute = $script:OlvmVmRouteCache[$cacheKey]
        [void]$script:OlvmVmRouteCache.Remove($cacheKey)
        $cachedManager = [string]$cachedRoute.Manager
        $cachedResolvedName = [string]$cachedRoute.ResolvedName
        if (-not [string]::IsNullOrWhiteSpace($cachedManager) -and
            -not [string]::IsNullOrWhiteSpace($cachedResolvedName) -and
            -not $attemptedManagers.ContainsKey($cachedManager)) {
            $attemptedManagers[$cachedManager] = $true
            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Reusing the verified OLVM route for VM '$cachedResolvedName' on Manager '$cachedManager'..."; Stage = 'OLVM route'; MachineName = $trimmedName }
            $query = Get-OlvmVmQueryResult -Manager $cachedManager -ResolvedName $cachedResolvedName
            $vmQueryMilliseconds += $query.ElapsedMilliseconds
            if ($query.Succeeded) {
                if ($query.Machines.Count -gt 1) {
                    throw "Cached OLVM Manager '$cachedManager' returned $($query.Machines.Count) VMs for exact name '$cachedResolvedName'. The result is ambiguous and provisioning is blocked."
                }
                if ($query.Machines.Count -eq 1) {
                    $manager = $cachedManager
                    $resolvedName = $cachedResolvedName
                    $virtualMachines = [object[]]$query.Machines
                    $routeSource = if ($selectedManagerFallbackUsed) { 'SelectedFallbackCachedRoute' } else { 'CachedRoute' }
                }
                else {
                    Write-RunLog -Level WARN -Stage 'OLVM route' -MachineName $trimmedName -Message "The cached route '$cachedManager' no longer returned VM '$cachedResolvedName'. Full configured-manager discovery will run."
                }
            }
            else {
                [void]$routeFailures.Add("Cached manager '$cachedManager': $($query.ErrorMessage)")
                Write-RunLog -Level WARN -Stage 'OLVM route' -MachineName $trimmedName -Message "The cached route '$cachedManager' could not be queried for VM '$cachedResolvedName': $($query.ErrorMessage) Full configured-manager discovery will run."
            }
        }
    }

    # For another VM in the same batch, try managers that already produced a
    # completely verified MAC. A miss or connection failure never proves that
    # the VM is absent; full configured-manager discovery remains the fallback.
    if ([string]::IsNullOrWhiteSpace($manager)) {
        foreach ($knownManager in @($script:OlvmKnownManagers)) {
            if ($attemptedManagers.ContainsKey($knownManager)) {
                continue
            }
            $knownManagerAttempted = $true
            $attemptedManagers[$knownManager] = $true
            foreach ($lookupName in $lookupNames) {
                Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Checking previously verified OLVM Manager '$knownManager' for VM '$lookupName'..."; Stage = 'OLVM route'; MachineName = $trimmedName }
                $query = Get-OlvmVmQueryResult -Manager $knownManager -ResolvedName $lookupName
                $vmQueryMilliseconds += $query.ElapsedMilliseconds
                if (-not $query.Succeeded) {
                    [void]$routeFailures.Add("Known manager '$knownManager': $($query.ErrorMessage)")
                    Write-RunLog -Level WARN -Stage 'OLVM route' -MachineName $trimmedName -Message "Previously verified Manager '$knownManager' could not be queried: $($query.ErrorMessage) Full configured-manager discovery remains available."
                    break
                }
                if ($query.Machines.Count -gt 1) {
                    throw "Previously verified OLVM Manager '$knownManager' returned $($query.Machines.Count) VMs for exact name '$lookupName'. The result is ambiguous and provisioning is blocked."
                }
                if ($query.Machines.Count -eq 1) {
                    $manager = [string]$knownManager
                    $resolvedName = $lookupName
                    $virtualMachines = [object[]]$query.Machines
                    $routeSource = if ($selectedManagerFallbackUsed) {
                        'SelectedFallbackKnown'
                    }
                    elseif ($hadCachedRoute) {
                        'CacheFallbackKnown'
                    }
                    else {
                        'KnownManager'
                    }
                    break
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($manager)) {
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($manager)) {
        foreach ($lookupName in $lookupNames) {
            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Searching all configured OLVM Managers for VM '$lookupName'..."; Stage = 'OLVM discovery'; MachineName = $trimmedName }
            $discoveryTimer = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $candidateManager = Find-CTxOLVMHost `
                    -VMName $lookupName `
                    -OLVMInstances $script:OlvmEngineInventory `
                    3>$null 6>$null
            }
            catch {
                if ($selectedManagerFallbackUsed) {
                    throw "$selectedManagerFailure Auto-detect failed while searching for exact VM name '$lookupName': $($_.Exception.Message)"
                }
                throw
            }
            finally {
                $discoveryTimer.Stop()
                $discoveryMilliseconds += $discoveryTimer.ElapsedMilliseconds
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$candidateManager)) {
                $manager = [string]$candidateManager
                $resolvedName = $lookupName
                break
            }
        }

        if ([string]::IsNullOrWhiteSpace($manager)) {
            if ($routeFailures.Count -gt 0) {
                throw "No verified OLVM route succeeded for VM '$MachineName'. OLVM route issue(s): $([string]::Join(' | ', $routeFailures.ToArray())). Auto-detect did not report the VM."
            }
            throw "No configured OLVM Manager reported VM '$MachineName'. Tried the entered, uppercase, and lowercase name forms. Confirm the VM exists and that this PVS master's OLVM Manager inventory includes its manager."
        }

        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Reading VM '$resolvedName' from discovered OLVM Manager '$manager'..."; Stage = 'OLVM lookup'; MachineName = $trimmedName }
        $query = Get-OlvmVmQueryResult -Manager $manager -ResolvedName $resolvedName
        $vmQueryMilliseconds += $query.ElapsedMilliseconds
        if (-not $query.Succeeded) {
            if ($selectedManagerFallbackUsed) {
                throw "$selectedManagerFailure Auto-detect reported OLVM Manager '$manager' for VM '$resolvedName', but the immediate live VM query failed: $($query.ErrorMessage)"
            }
            throw "VM '$resolvedName' was discovered on OLVM Manager '$manager', but the live VM query failed: $($query.ErrorMessage)"
        }
        if ($query.Machines.Count -eq 0) {
            if ($selectedManagerFallbackUsed) {
                throw "$selectedManagerFailure Auto-detect reported OLVM Manager '$manager' for VM '$resolvedName', but the immediate live query returned no VM."
            }
            throw "VM '$resolvedName' was discovered on OLVM Manager '$manager' but was not returned by the immediate live query."
        }
        if ($query.Machines.Count -gt 1) {
            if ($selectedManagerFallbackUsed) {
                throw "$selectedManagerFailure Auto-detect reported OLVM Manager '$manager', whose immediate exact-name query returned $($query.Machines.Count) VMs for '$resolvedName'."
            }
            throw "OLVM Manager '$manager' returned $($query.Machines.Count) VMs for exact name '$resolvedName'."
        }
        $virtualMachines = [object[]]$query.Machines
        if ($selectedManagerFallbackUsed) {
            $routeSource = 'SelectedFallbackDiscovery'
        }
        elseif ($hadCachedRoute) {
            $routeSource = 'CacheFallbackDiscovery'
        }
        elseif ($knownManagerAttempted) {
            $routeSource = 'KnownFallbackDiscovery'
        }
        else {
            $routeSource = 'Discovery'
        }
    }

    Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Reading the live NIC MAC for OLVM VM '$resolvedName'..."; Stage = 'OLVM NIC'; MachineName = $trimmedName }
    $nicTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $macAddresses = @($virtualMachines[0] |
            Get-oVmNic -Syncopate 3>$null 6>$null |
            ForEach-Object { Get-NormalizedMacAddress -Value ([string]$_.mac.address) } |
            Select-Object -Unique)
    }
    finally {
        $nicTimer.Stop()
        $nicQueryMilliseconds = $nicTimer.ElapsedMilliseconds
    }
    if ($macAddresses.Count -eq 0) {
        throw "OLVM VM '$resolvedName' has no NIC MAC address."
    }
    if ($macAddresses.Count -ne 1) {
        throw "OLVM returned $($macAddresses.Count) NIC MAC addresses for '$resolvedName'. This workflow requires exactly one NIC; identify the PVS NIC before proceeding."
    }

    # Cache only routing information after the entire live lookup succeeds.
    # The next call still performs Get-oVM and Get-oVmNic and compares the MAC.
    $verifiedVm = $virtualMachines[0]
    $verifiedVmId = Get-OlvmVmIdentifier -VirtualMachine $verifiedVm
    $verifiedVmStatus = Get-OlvmVmStatusFromObject -VirtualMachine $verifiedVm
    $script:OlvmVmRouteCache[$cacheKey] = [pscustomobject]@{
        Manager      = $manager
        ResolvedName = $resolvedName
        VmId         = $verifiedVmId
        Status       = $verifiedVmStatus
    }
    Add-OlvmKnownManager -Manager $manager
    Add-OlvmManagerSession -Manager $manager
    $totalTimer.Stop()
    Write-RunLog -Level SUCCESS -Stage 'OLVM NIC' -MachineName $trimmedName -Message "OLVM Manager '$manager' returned live MAC '$($macAddresses[0])' for VM '$resolvedName' (VM ID '$verifiedVmId', status '$verifiedVmStatus'). RouteSource=$routeSource; ConnectionMs=$connectionMilliseconds; DiscoveryMs=$discoveryMilliseconds; VmQueryMs=$vmQueryMilliseconds; NicQueryMs=$nicQueryMilliseconds; TotalMs=$($totalTimer.ElapsedMilliseconds)."
    return $macAddresses[0]
}

function Start-OlvmVmByIdentity {
    <# Starts one VM only after live Manager, ID, MAC, and down-state checks. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Identity,
        [Parameter(Mandatory = $true)][string]$MachineName,
        [Parameter(Mandatory = $true)][string]$ExpectedMacAddress
    )

    # Power may run well after an early row completed. Re-read the live NIC at
    # the final power boundary so a same-ID VM whose NIC was replaced cannot be
    # started against stale PVS and DHCP data.
    $freshMac = Get-OlvmMac `
        -MachineName $MachineName `
        -SelectedManager ([string]$Identity.Manager)
    if (-not (Test-MacAddressEqual -First $freshMac -Second $ExpectedMacAddress)) {
        throw "OLVM MAC changed before power-on. Expected '$ExpectedMacAddress'; the exact live VM now reports '$freshMac'. No Start was sent."
    }
    $freshIdentity = Get-OlvmRouteIdentity -MachineName $MachineName
    if ([string]$freshIdentity.Manager -ine [string]$Identity.Manager -or
        [string]$freshIdentity.VmId -ine [string]$Identity.VmId) {
        throw "OLVM identity changed before power-on. Expected Manager '$($Identity.Manager)' and VM ID '$($Identity.VmId)'; found Manager '$($freshIdentity.Manager)' and VM ID '$($freshIdentity.VmId)'. No Start was sent."
    }

    $snapshot = Assert-OlvmVmIsDown -Identity $freshIdentity -MachineName $MachineName
    $command = Get-Command -Name Set-oVMPowerState -ErrorAction Stop | Select-Object -First 1
    $arguments = @{
        PowerState     = 'Start'
        oVirtServerName = [string]$freshIdentity.Manager
        ErrorAction    = 'Stop'
    }
    if (-not $command.Parameters.ContainsKey('Id')) {
        throw 'Set-oVMPowerState does not expose the immutable Id selector. The VM was not started.'
    }
    $arguments['Id'] = [string]$snapshot.VmId
    $selector = "immutable ID '$($snapshot.VmId)'"
    if ($command.Parameters.ContainsKey('Confirm')) { $arguments['Confirm'] = $false }

    Write-RunLog -Level INFO -Stage 'OLVM power start' -MachineName $MachineName -Message "Sending Start to Manager '$($freshIdentity.Manager)' using $selector after live Manager, VM ID, MAC, and down-state verification."
    # This is the last gate before the external power mutation. A prior log
    # fault must block this and every later Start request.
    Assert-AuditTrailAvailable
    Assert-FarmBuildLockOwned
    try {
        $output = @(& $command @arguments)
        $formattedWebError = Get-OlvmFormattedWebErrorMessage -Output $output
        if (-not [string]::IsNullOrWhiteSpace($formattedWebError)) {
            throw "OLVM rejected the Start request for '$MachineName': $formattedWebError"
        }
    }
    catch {
        # The request crossed an external mutation boundary. Tag the error so
        # the caller reconciles the exact VM ID and never sends a blind retry.
        $wrapped = New-Object System.InvalidOperationException(
            "OLVM Start did not return a clean success response: $($_.Exception.Message)",
            $_.Exception
        )
        $wrapped.Data['OlvmStartRequestAttempted'] = $true
        throw $wrapped
    }
    $returnTypes = @($output | ForEach-Object { $_.GetType().FullName } | Select-Object -Unique)
    Write-RecoveryLog -Level INFO -Stage 'OLVM power start' -MachineName $MachineName -Message "Start command returned without a formatted OLVM web error. Return types: $($returnTypes -join '; '). Live exact-ID status polling is authoritative."
}

function Set-PowerRecordOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Context,
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][string]$Details,
        [ValidateSet('INFO','SUCCESS','WARN','ERROR')][string]$LogLevel = 'INFO'
    )

    if ($Context.PowerOverrideApproved -eq $true) {
        if ($Result -eq 'PoweredOn') { $Result = 'PoweredOnWithAdWarning' }
        elseif ($Result -eq 'AlreadyUp') { $Result = 'AlreadyUpWithAdWarning' }
        if ($Result -in @('PoweredOnWithAdWarning','AlreadyUpWithAdWarning')) {
            $Details = "$Details The operator explicitly approved power-on even though the build remains AttentionRequired for AD. AD error: $($Context.AdFailure)"
        }
    }
    $Context.Record.PowerResult = $Result
    $Context.Record.PowerDetails = $Details
    Write-RecoveryLog -Level $LogLevel -Stage 'OLVM power' -MachineName $Context.Record.MachineName -Message "$Result - $Details"
    Invoke-PresentationPort -Name 'GridRefreshRecoverySafe' -Arguments @{ MachineName = $Context.Record.MachineName; FocusRecord = $Context.Record }
}

function Test-ContextEligibleForPostBuildPower {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Context)

    if (-not $Context.Settings.PowerOnAfterBuild) { return $false }
    if ($Context.Record.Result -eq 'CreatedAndVerified') { return $true }
    return ($Context.Record.Result -eq 'AttentionRequired' -and
        $Context.Record.NonAdPrerequisitesVerified -eq $true -and
        $Context.Record.PowerOverrideEligible -eq $true -and
        $Context.PowerOverrideApproved -eq $true)
}

function Invoke-OlvmPostBuildPowerOn {
    <#
      Runs only after the complete build phase. Power results never rewrite the
      build Result and never trigger infrastructure rollback or a power-off.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Contexts
    )

    $unsafeContexts = @($Contexts | Where-Object {
            $_.Settings.PowerOnAfterBuild -and -not $_.Settings.AssignPvsImage
        })
    if ($unsafeContexts.Count -gt 0) {
        throw "Power-on was requested for $($unsafeContexts.Count) build context(s) without a selected PVS image. No Start request was sent."
    }

    $eligible = [object[]]@($Contexts | Where-Object {
            Test-ContextEligibleForPostBuildPower -Context $_
        })
    foreach ($context in $Contexts) {
        if ($context.Settings.PowerOnAfterBuild -and
            -not (Test-ContextEligibleForPostBuildPower -Context $context) -and
            $context.Record.PowerResult -notin @('NotAttempted','NotRequested','KeptOffByOperator')) {
            $context.Record.PowerResult = 'NotEligible'
            $context.Record.PowerDetails = "Not powered because the build result is '$($context.Record.Result)'."
        }
    }
    if ($eligible.Count -eq 0) {
        Write-RunLog -Level INFO -Stage 'OLVM power' -Message 'No VM remained eligible for post-build power-on after build results and any AD-warning operator decisions were applied.'
        return
    }

    Assert-AuditTrailAvailable
    Assert-OlvmPowerCommandAvailable
    $managerFailures = @{}
    Invoke-PresentationPort -Name 'SetProgressMinimum' -Arguments @{ Value = 0 }
    Invoke-PresentationPort -Name 'SetProgressMaximum' -Arguments @{ Value = $eligible.Count }
    Invoke-PresentationPort -Name 'SetProgressValue' -Arguments @{ Value = 0 }
    $completed = 0
    $waveCount = [int][math]::Ceiling($eligible.Count / [double]$script:PowerWaveSize)

    for ($waveIndex = 0; $waveIndex -lt $waveCount; $waveIndex++) {
        $startIndex = $waveIndex * $script:PowerWaveSize
        $endIndex = [math]::Min($eligible.Count - 1, $startIndex + $script:PowerWaveSize - 1)
        $wave = [object[]]@($eligible[$startIndex..$endIndex])
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Post-build power-on: starting wave $($waveIndex + 1) of $waveCount ($($wave.Count) VM(s)). Inputs remain locked."; Color = 'DarkOrange'; Stage = 'OLVM power' }
        $pending = New-Object 'System.Collections.Generic.List[object]'

        foreach ($context in $wave) {
            $managerKey = ([string]$context.OlvmIdentity.Manager).ToLowerInvariant()
            if ($managerFailures.ContainsKey($managerKey)) {
                Set-PowerRecordOutcome -Context $context -Result 'NotAttempted' -LogLevel WARN -Details "OLVM Manager '$($context.OlvmIdentity.Manager)' was unavailable earlier in this power phase: $($managerFailures[$managerKey])"
                $completed++
                Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
                continue
            }
            try {
                $snapshot = Get-OlvmVmPowerSnapshot -Identity $context.OlvmIdentity
                switch ($snapshot.Status) {
                    'up' {
                        Set-PowerRecordOutcome -Context $context -Result 'AlreadyUp' -LogLevel WARN -Details 'The exact OLVM VM was already up before this tool sent Start, so no power command was issued.'
                        $completed++
                        Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
                    }
                    'down' {
                        try {
                            Start-OlvmVmByIdentity `
                                -Identity $context.OlvmIdentity `
                                -MachineName $context.Record.MachineName `
                                -ExpectedMacAddress $context.Record.MacAddress
                            $context.PowerRequestAttempted = $true
                            $context.PowerRequestSent = $true
                            $context.Record.PowerResult = 'Pending'
                            $context.Record.PowerDetails = 'Start was sent; waiting for the exact OLVM VM to report up.'
                            [void]$pending.Add($context)
                        }
                        catch {
                            $startError = $_.Exception.Message
                            $requestAttempted = Test-OlvmStartRequestAttempted -ErrorRecord $_
                            $context.PowerRequestAttempted = $requestAttempted
                            $pendingAfterReconcile = $false
                            try {
                                $reconciled = Get-OlvmVmPowerSnapshot -Identity $context.OlvmIdentity
                                if (-not $requestAttempted) {
                                    Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "No Start request crossed the OLVM command boundary: $startError"
                                }
                                elseif ($reconciled.Status -eq 'up') {
                                    Set-PowerRecordOutcome -Context $context -Result 'PoweredOn' -LogLevel SUCCESS -Details "The Start response was uncertain, but the exact OLVM VM ID '$($reconciled.VmId)' now reports status 'up'. No retry was sent."
                                }
                                elseif ($reconciled.Status -in @('down','powering_up','wait_for_launch')) {
                                    Set-PowerRecordOutcome -Context $context -Result 'Pending' -LogLevel WARN -Details "The Start response was uncertain. The exact OLVM VM reports status '$($reconciled.Status)'; the tool will poll it and will not resend Start. Original error: $startError"
                                    [void]$pending.Add($context)
                                    $pendingAfterReconcile = $true
                                }
                                else {
                                    $statusText = if ([string]::IsNullOrWhiteSpace($reconciled.Status)) { 'unknown' } else { $reconciled.Status }
                                    Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "The Start response was uncertain and the exact OLVM VM reported unsupported status '$statusText'. No retry was sent. Original error: $startError"
                                }
                            }
                            catch {
                                $reconcileError = $_.Exception.Message
                                $failureScope = Get-OlvmPowerFailureScope -ErrorRecord $_
                                if ($failureScope -eq 'Manager') {
                                    $managerFailures[$managerKey] = $reconcileError
                                    $requestText = if ($requestAttempted) { 'Start may have been accepted; no retry was sent' } else { 'No Start request crossed the command boundary' }
                                    Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "$requestText, and Manager '$($context.OlvmIdentity.Manager)' could not be queried for reconciliation: $startError | $reconcileError"
                                }
                                else {
                                    $requestText = if ($requestAttempted) { 'Start may have been accepted; no retry was sent' } else { 'No Start request crossed the command boundary' }
                                    Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "$requestText, and exact-VM reconciliation failed for this row: $startError | $reconcileError"
                                }
                            }
                            if (-not $pendingAfterReconcile) {
                                $completed++
                                Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
                            }
                        }
                    }
                    'powering_up' { [void]$pending.Add($context) }
                    'wait_for_launch' { [void]$pending.Add($context) }
                    default {
                        $statusText = if ([string]::IsNullOrWhiteSpace($snapshot.Status)) { 'unknown' } else { $snapshot.Status }
                        Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "No Start was sent because the exact OLVM VM reported unsupported status '$statusText'."
                        $completed++
                        Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
                    }
                }
            }
            catch {
                $statusError = $_.Exception.Message
                $failureScope = Get-OlvmPowerFailureScope -ErrorRecord $_
                if ($failureScope -eq 'Manager') {
                    $managerFailures[$managerKey] = $statusError
                    Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "OLVM Manager '$($context.OlvmIdentity.Manager)' could not perform the final exact-VM status check: $statusError"
                }
                else {
                    Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "The final exact-VM status check failed for this row: $statusError"
                }
                $completed++
                Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
            }
        }

        $pollTimer = [System.Diagnostics.Stopwatch]::StartNew()
        while ($pending.Count -gt 0 -and $pollTimer.Elapsed.TotalSeconds -lt $script:PowerTimeoutSeconds) {
            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Post-build power-on: wave $($waveIndex + 1) of $waveCount has $($pending.Count) VM(s) awaiting OLVM status 'up'."; Color = 'DarkOrange'; Stage = 'OLVM power' }
            $resolvedThisPoll = New-Object 'System.Collections.Generic.List[object]'
            foreach ($context in [object[]]$pending.ToArray()) {
                $managerKey = ([string]$context.OlvmIdentity.Manager).ToLowerInvariant()
                if ($managerFailures.ContainsKey($managerKey)) {
                    if ($context.PowerRequestAttempted) {
                        Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "Start was attempted, but status verification stopped because Manager '$($context.OlvmIdentity.Manager)' is unavailable. No retry was sent: $($managerFailures[$managerKey])"
                    }
                    else {
                        Set-PowerRecordOutcome -Context $context -Result 'NotAttempted' -LogLevel WARN -Details "No Start was sent by this tool; status verification stopped because Manager '$($context.OlvmIdentity.Manager)' is unavailable: $($managerFailures[$managerKey])"
                    }
                    [void]$resolvedThisPoll.Add($context)
                    $completed++
                    Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
                    continue
                }
                try {
                    $snapshot = Get-OlvmVmPowerSnapshot -Identity $context.OlvmIdentity
                    if ($snapshot.Status -eq 'up') {
                        $resultName = if ($context.PowerRequestAttempted) { 'PoweredOn' } else { 'AlreadyUp' }
                        $detail = if ($context.PowerRequestSent) {
                            "The exact OLVM VM ID '$($snapshot.VmId)' reported status 'up' after this tool sent Start."
                        }
                        elseif ($context.PowerRequestAttempted) {
                            "The exact OLVM VM ID '$($snapshot.VmId)' reported status 'up' after an uncertain Start response. No retry was sent."
                        }
                        else {
                            "The exact OLVM VM ID '$($snapshot.VmId)' reached status 'up' without this tool sending another Start."
                        }
                        Set-PowerRecordOutcome -Context $context -Result $resultName -LogLevel SUCCESS -Details $detail
                        [void]$resolvedThisPoll.Add($context)
                        $completed++
                        Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
                    }
                    elseif ($snapshot.Status -notin @('down','powering_up','wait_for_launch')) {
                        Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "The exact OLVM VM changed to unsupported status '$($snapshot.Status)' while waiting for 'up'."
                        [void]$resolvedThisPoll.Add($context)
                        $completed++
                        Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
                    }
                }
                catch {
                    $statusError = $_.Exception.Message
                    $failureScope = Get-OlvmPowerFailureScope -ErrorRecord $_
                    if ($failureScope -eq 'Manager') {
                        $managerFailures[$managerKey] = $statusError
                        Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "Power status could not be verified because Manager '$($context.OlvmIdentity.Manager)' became unavailable: $statusError"
                    }
                    else {
                        Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "Power status verification failed for this exact VM only: $statusError"
                    }
                    [void]$resolvedThisPoll.Add($context)
                    $completed++
                    Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
                }
            }
            foreach ($resolved in $resolvedThisPoll) { [void]$pending.Remove($resolved) }
            if ($pending.Count -gt 0) { Invoke-PresentationPort -Name 'ResponsiveWait' -Arguments @{ Seconds = $script:PowerPollSeconds } }
        }

        foreach ($context in [object[]]$pending.ToArray()) {
            $requestText = if ($context.PowerRequestAttempted) { 'A Start request was attempted and was not retried.' } else { 'No Start request was sent by this tool.' }
            Set-PowerRecordOutcome -Context $context -Result 'Failed' -LogLevel ERROR -Details "Timed out after $($script:PowerTimeoutSeconds) seconds waiting for the exact OLVM VM to report status 'up'. $requestText The completed PVS/DHCP/AD build was retained and the VM was not powered off."
            $completed++
            Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $completed; MachineName = $context.Record.MachineName }
        }
        if ($waveIndex -lt ($waveCount - 1)) {
            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Post-build power-on: wave $($waveIndex + 1) finished. Waiting $($script:PowerWaveDelaySeconds) seconds before the next wave."; Color = 'DarkOrange'; Stage = 'OLVM power' }
            Invoke-PresentationPort -Name 'ResponsiveWait' -Arguments @{ Seconds = $script:PowerWaveDelaySeconds }
        }
    }
}
