function Invoke-NonAdBuildPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Context,

        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [Parameter(Mandatory = $true)]
        [int]$ServerNumber,

        [Parameter(Mandatory = $true)]
        [int]$ServerCount
    )

    $record = $Context.Record
    $settings = $Context.Settings

    Assert-AuditTrailAvailable
    Assert-FarmBuildLockOwned
    if ($Context.Plan.PvsTarget.Action -eq 'ReuseExact') {
        $State.PvsGuid = [guid]$Context.Plan.PvsTarget.Guid
        $State.PvsStatus = 'ReusedExact'
        Write-RunLog -Level SUCCESS -Stage 'PVS continuation' -MachineName $record.MachineName -Message "Skipped PVS target creation according to Validation plan '$($Context.ValidationId)'; reusing exact target GUID '$($State.PvsGuid)'."
    }
    elseif ($Context.Plan.PvsTarget.Action -eq 'Create') {
        Write-RunLog -Level INFO -Stage 'PVS create' -MachineName $record.MachineName -Message "Creating the missing PVS target in '$($settings.Collection.Display)' with MAC '$($record.MacAddress)' according to Validation plan '$($Context.ValidationId)'."
        $State.PvsStatus = 'Ambiguous'
        Assert-AuditTrailAvailable
        Assert-FarmBuildLockOwned
        $pvsCommandOutput = @(New-PvsDevice `
            -Name $record.MachineName `
            -DeviceMac $record.MacAddress `
            -SiteName $settings.Collection.SiteName `
            -CollectionName $settings.Collection.Name `
            -ErrorAction Stop)
        $verifiedPvsDevice = Assert-PvsTargetCreated -Record $record -Collection $settings.Collection
        $verifiedPvsGuid = [string]$verifiedPvsDevice.Guid
        if ([string]::IsNullOrWhiteSpace($verifiedPvsGuid)) {
            throw 'The created PVS target was returned without an immutable GUID.'
        }
        if ($pvsCommandOutput.Count -ne 1 -or [guid]$pvsCommandOutput[0].Guid -ne [guid]$verifiedPvsGuid) {
            throw "New-PvsDevice did not return exactly one object with verified GUID '$verifiedPvsGuid'. The partial state is retained for the next Validation."
        }
        $State.PvsGuid = [guid]$verifiedPvsGuid
        $State.PvsStatus = 'ConfirmedCreated'
        $pvsReturnTypes = @($pvsCommandOutput | ForEach-Object { $_.GetType().FullName } | Select-Object -Unique)
        Write-RunLog -Level SUCCESS -Stage 'PVS create' -MachineName $record.MachineName -Message "Created and verified PVS target GUID '$verifiedPvsGuid'. Return types: $($pvsReturnTypes -join '; ')."
    }
    else {
        throw "Validation plan contains unsupported PVS action '$($Context.Plan.PvsTarget.Action)'."
    }

    Assert-AuditTrailAvailable
    if ($Context.Plan.Image.Action -eq 'Create') {
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Assigning and verifying PVS image '$($settings.Image.Name)' for '$($record.MachineName)'..."; Stage = 'PVS image'; MachineName = $record.MachineName }
        Set-PvsImageForNewTarget -Context $Context -State $State
    }
    elseif ($Context.Plan.Image.Action -eq 'ReuseExact') {
        $State.ImageStatus = 'ReusedExact'
        Write-RunLog -Level SUCCESS -Stage 'PVS image' -MachineName $record.MachineName -Message "Skipped vDisk assignment according to Validation plan '$($Context.ValidationId)'; the exact selected DiskLocator '$($settings.Image.DiskLocatorId)' is retained."
    }
    elseif ($Context.Plan.Image.Action -eq 'VerifyNone') {
        $State.ImageStatus = 'ConfirmedUnassigned'
        Write-RunLog -Level SUCCESS -Stage 'PVS image' -MachineName $record.MachineName -Message "No PVS image was requested; Validation plan '$($Context.ValidationId)' recorded zero mappings and no image write is required."
    }
    else {
        throw "Validation plan contains unsupported image action '$($Context.Plan.Image.Action)'."
    }
    $record.ConfiguredPvsImage = if ($settings.AssignPvsImage) {
        "$($settings.ImageDisplay), version $($settings.ImageVersionDisplay) (configured / next boot; assignment verified during Build)"
    }
    else {
        'None (zero configured mappings verified during Build)'
    }

    if ($Context.Plan.Personality.Action -eq 'Create') {
        Assert-AuditTrailAvailable
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Assigning and verifying Reboot='$($Context.RebootDay)' for '$($record.MachineName)'..."; Stage = 'PVS personality'; MachineName = $record.MachineName }
        Set-PvsRebootPersonalityForNewTarget -Context $Context -State $State
    }
    elseif ($Context.Plan.Personality.Action -eq 'ReuseExact') {
        $State.PersonalityStatus = 'ReusedExact'
        $State.PersonalityOtherFingerprint = [string]$Context.Plan.Personality.OtherFingerprint
        $Context.PersonalityOtherFingerprint = [string]$Context.Plan.Personality.OtherFingerprint
        Write-RunLog -Level SUCCESS -Stage 'PVS personality' -MachineName $record.MachineName -Message "Skipped Reboot personality write according to Validation plan '$($Context.ValidationId)'; retaining exact Reboot='$($Context.RebootDay)'."
    }
    else {
        throw "Validation plan contains unsupported personality action '$($Context.Plan.Personality.Action)'."
    }

    $dhcpServerNumber = 0
    foreach ($target in $Context.DhcpTargets) {
        $dhcpServerNumber++
        Assert-AuditTrailAvailable
        Assert-FarmBuildLockOwned
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "[Server $ServerNumber/$ServerCount; DHCP server $dhcpServerNumber/$(@($Context.DhcpTargets).Count)] Applying the retained DHCP plan on '$($target.Server)', scope '$($target.ScopeId)'..."; Stage = 'DHCP build'; MachineName = $record.MachineName }
        $operation = [pscustomobject]@{
            Target         = $target
            Status         = 'NotAttempted'
            Option67Status = 'NotAttempted'
        }
        [void]$State.DhcpOperations.Add($operation)

        if ($target.Action -eq 'ReuseExact') {
            $operation.Status = 'ReusedExact'
            Write-RunLog -Level SUCCESS -Stage 'DHCP continuation' -MachineName $record.MachineName -Message "Skipped reservation creation on '$($target.Server)' according to Validation plan '$($Context.ValidationId)'; retaining the exact reservation."
        }
        elseif ($target.Action -eq 'Create') {
            Write-RunLog -Level INFO -Stage 'DHCP create' -MachineName $record.MachineName -Message "Creating reservation '$($record.DhcpName)' on '$($target.Server)' scope '$($target.ScopeId)' for IP '$($record.IPAddress)' and MAC '$($record.MacAddress)'."
            $operation.Status = 'Ambiguous'
            Assert-AuditTrailAvailable
            Assert-FarmBuildLockOwned
            $dhcpCommandOutput = @(Add-DhcpServerv4Reservation `
                -ComputerName $target.Server `
                -ScopeId $target.ScopeId `
                -IPAddress $record.IPAddress `
                -ClientId $record.MacAddress `
                -Name $record.DhcpName `
                -Type Both `
                -PassThru `
                -ErrorAction Stop)

            if ($dhcpCommandOutput.Count -ne 1 -or
                $dhcpCommandOutput[0].IPAddress.IPAddressToString -ne $record.IPAddress -or
                -not (Test-MacAddressEqual -First $dhcpCommandOutput[0].ClientId -Second $record.MacAddress)) {
                throw "Add-DhcpServerv4Reservation did not return exactly the expected IP and MAC on '$($target.Server)'. The partial state is retained for the next Validation."
            }

            $null = Assert-DhcpReservationIdentityCreated -Target $target -Record $record
            $operation.Status = 'ConfirmedCreated'
            $dhcpReturnTypes = @($dhcpCommandOutput | ForEach-Object { $_.GetType().FullName } | Select-Object -Unique)
            Write-RunLog -Level SUCCESS -Stage 'DHCP create' -MachineName $record.MachineName -Message "DHCP reservation ownership confirmed on '$($target.Server)' scope '$($target.ScopeId)'. Return types: $($dhcpReturnTypes -join '; ')."
        }
        else {
            throw "Validation plan contains unsupported DHCP action '$($target.Action)' for '$($target.Server)'."
        }

        if ($target.Option67Action -eq 'UseScope') {
            $operation.Option67Status = 'NotRequired'
            Write-RunLog -Level INFO -Stage 'DHCP option 67' -MachineName $record.MachineName -Message "Validation plan uses the existing matching scope option 67 on '$($target.Server)'; no option write was requested."
        }
        elseif ($target.Option67Action -eq 'ReuseExact') {
            $operation.Option67Status = 'ReusedExact'
            Write-RunLog -Level SUCCESS -Stage 'DHCP option 67' -MachineName $record.MachineName -Message "Skipped option 67 write on '$($target.Server)' according to Validation plan '$($Context.ValidationId)'; retaining the exact reservation-level value."
        }
        elseif ($target.Option67Action -eq 'Create' -and $target.Option67Level -eq 'Reservation') {
            Assert-AuditTrailAvailable
            Assert-FarmBuildLockOwned
            Write-RunLog -Level INFO -Stage 'DHCP option 67' -MachineName $record.MachineName -Message "Setting reservation-level option 67 to '$($settings.BootFile)' on '$($target.Server)'."
            $operation.Option67Status = 'Ambiguous'
            Set-DhcpServerv4OptionValue `
                -ComputerName $target.Server `
                -ReservedIP $record.IPAddress `
                -OptionId 67 `
                -Value $settings.BootFile `
                -ErrorAction Stop |
                Out-Null
        }
        else {
            throw "Validation plan contains invalid option 67 action/level '$($target.Option67Action)/$($target.Option67Level)' for '$($target.Server)'."
        }
        # Exact reused DHCP state was already captured by Validation. Only a
        # reservation or option write needs immediate post-write verification;
        # the completed row receives one end-to-end read after all writes.
        if ($target.Action -eq 'Create' -or $target.Option67Action -eq 'Create') {
            Assert-DhcpReservationCreated `
                -Target $target `
                -Record $record `
                -BootFile $settings.BootFile
            if ($target.Option67Action -eq 'Create') {
                $operation.Option67Status = 'ConfirmedSet'
            }
        }
    }
}

function Set-RemainingRowsNotAttempted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Contexts,

        [Parameter(Mandatory = $true)]
        [int]$StartIndex,

        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    for ($index = $StartIndex; $index -lt $Contexts.Count; $index++) {
        $record = $Contexts[$index].Record
        $record.Stage = 'Provisioning'
        $record.Result = 'NotAttempted'
        $record.BuildAction = 'Not attempted - an earlier row stopped sequential processing.'
        $record.Details = $Reason
        Write-RecoveryLog -Level WARN -Stage 'Provisioning' -MachineName $record.MachineName -Message $Reason
    }
}

function Invoke-Provision {
    [CmdletBinding()]
    param()

    Assert-AuditTrailAvailable
    $validationBuildState = Get-ValidationBuildState
    $validationRecords = $validationBuildState.ValidationRecords
    $buildContexts = $validationBuildState.BuildContexts
    if ($null -eq $buildContexts -or
        @($buildContexts).Count -eq 0) {
        throw 'Run Validation first; at least one submitted server must be Ready for Build.'
    }
    foreach ($record in @($validationRecords)) {
        Assert-ValidationRecordContract -InputObject $record
    }
    foreach ($context in @($buildContexts)) {
        Assert-BuildContextContract -InputObject $context
    }
    $null = Assert-ReadyBuildContextSelectionContract `
        -ValidationRecords ([object[]]@($validationRecords)) `
        -BuildContexts ([object[]]@($buildContexts))

    $farmLock = $null
    try {
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = 'Build selected: acquiring the farm-wide Build lock before confirmation...'; Stage = 'Farm lock' }
        $farmLock = Enter-FarmBuildLock
    }
    catch {
        Invoke-PresentationPort -Name 'SetBuildEnabled' -Arguments @{ Enabled = $false }
        Set-ValidationBuildState -BuildContexts $null
        throw "$($_.Exception.Message) The retained Validation was invalidated because another Build may change shared farm state; run Validation again."
    }

    try {
    $allRecords = [object[]]@($validationRecords)
    $contexts = [object[]]@($buildContexts)
    $settings = $contexts[0].Settings
    $validationOutcomeCounts = Get-ValidationOutcomeCounts -Records $allRecords
    $skippedExistingCount = $validationOutcomeCounts.SkippedExisting
    $blockedExcludedCount = $validationOutcomeCounts.Blocked
    $blockedExcludedIdentifiers = [string]::Join(', ',[string[]]@($allRecords |
            Where-Object { [string]$_.Result -ceq 'Blocked' } |
            ForEach-Object { "Line $($_.Line)/$($_.MachineName)" }))
    if ([string]::IsNullOrWhiteSpace($blockedExcludedIdentifiers)) {
        $blockedExcludedIdentifiers = '<none>'
    }
    Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Waiting for final confirmation: $($contexts.Count) Ready server(s) will be provisioned, $blockedExcludedCount Blocked server(s) will be excluded, and $skippedExistingCount exact server(s) will be skipped unchanged. No provisioning writes have started."; Color = 'DarkOrange'; Stage = 'Confirmation' }
    Invoke-PresentationPort -Name 'SuspendExecutionClock'
    $confirmationAccepted = Invoke-PresentationPort -Name 'ProvisioningConfirmation' -Arguments @{ Records = $allRecords; Settings = $settings; LogPath = $script:LogPath }
    if (-not $confirmationAccepted) {
        Write-RunLog -Level WARN -Stage 'Confirmation' -Message 'Operator declined final provisioning confirmation. No objects were created.'
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = 'Provisioning was cancelled at the confirmation. No objects were created.'; Color = 'DarkOrange'; Stage = 'Confirmation' }
        return 'Cancelled'
    }
    Invoke-PresentationPort -Name 'ResumeExecutionClock'
    Assert-AuditTrailAvailable
    $confirmationAuditLevel = if ($blockedExcludedCount -gt 0) { 'WARN' } else { 'SUCCESS' }
    Write-RunLog -Level $confirmationAuditLevel -Stage 'Confirmation' -Message "Operator confirmed Build selection: Ready=$($contexts.Count); BlockedExcluded=$blockedExcludedCount; BlockedExcludedRows=$blockedExcludedIdentifiers; SkippedExisting=$skippedExistingCount; Total=$($allRecords.Count); BuildContexts=$($contexts.Count). Only retained Ready contexts are eligible for writes and optional power-on."
    Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = 'Final confirmation accepted. Starting production provisioning for Ready servers now...'; Color = 'DarkGreen'; Stage = 'Confirmation' }

    # Build consumes the retained Validation action plan. Progress therefore
    # reflects only planned writes, post-write verification, and optional power.
    Invoke-PresentationPort -Name 'SetProgressIndeterminate' -Arguments @{ Value = $false }
    Invoke-PresentationPort -Name 'SetProgressMinimum' -Arguments @{ Value = 0 }
    Invoke-PresentationPort -Name 'SetProgressMaximum' -Arguments @{ Value = $contexts.Count }
    Invoke-PresentationPort -Name 'SetProgressValue' -Arguments @{ Value = 0 }
    $stopReason = $null
    for ($index = 0; $index -lt $contexts.Count; $index++) {
        $context = $contexts[$index]
        $record = $context.Record
        if (-not [string]::IsNullOrWhiteSpace($stopReason)) {
            Set-RemainingRowsNotAttempted -Contexts $contexts -StartIndex $index -Reason $stopReason
            Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = $contexts.Count }
            break
        }

        if ([string]$record.Result -cne 'Ready') {
            throw "The retained Build context for '$($record.MachineName)' is no longer Ready. No write was attempted for this row."
        }

        $state = New-ProvisioningState
        $record.BuildStarted = $true
        $record.BuildAction = 'Running - executing the retained Validation action plan.'
        $record.Stage = 'PVS, image state, personality and DHCP'
        $record.Result = 'Running'
        $record.Details = "Executing retained Validation plan '$($context.ValidationId)': $($context.ActionSummary)."
        Invoke-PresentationPort -Name 'GridRefresh' -Arguments @{ FocusRecord = $record }
        try {
            $null = Invoke-TimedOperation `
                -Phase 'PVSAndDHCP' `
                -Operation 'CreateAndVerify' `
                -MachineName $record.MachineName `
                -Source 'LiveSequentialWrites' `
                -Action {
                    Invoke-NonAdBuildPlan `
                        -Context $context `
                        -State $state `
                        -ServerNumber ($index + 1) `
                        -ServerCount $contexts.Count
                }
            $imageCreationResult = if ($settings.AssignPvsImage) {
                "image '$($settings.Image.Name)' version '$($settings.Image.EffectiveVersionDisplay)'"
            }
            else {
                'zero vDisk mappings as requested'
            }
            Write-RunLog -Level SUCCESS -Stage 'PVS and DHCP' -MachineName $record.MachineName -Message "PVS target, $imageCreationResult, Reboot='$($context.RebootDay)', and all DHCP reservations were created and verified."
        }
        catch {
            $creationError = $_.Exception.Message
            Write-RecoveryLog -Level ERROR -Stage 'PVS and DHCP' -MachineName $record.MachineName -Message $creationError
            if ($state.ImageStatus -eq 'Ambiguous' -and $settings.AssignPvsImage) {
                $record.ConfiguredPvsImage = "$($settings.ImageDisplay), version $($settings.ImageVersionDisplay) (assignment was attempted; current configured state requires attention)"
            }
            $dhcpState = @($state.DhcpOperations | ForEach-Object {
                    "$($_.Target.Server)=$($_.Status)/Option67:$($_.Option67Status)"
                }) -join ', '
            if ([string]::IsNullOrWhiteSpace($dhcpState)) { $dhcpState = 'none attempted' }
            $record.Stage = 'Partial build retained'
            $record.Result = 'AttentionRequired'
            $record.BuildAction = 'Stopped - partial infrastructure state was retained; no automatic rollback was attempted.'
            $record.AdBuildEvaluated = $true
            $record.AdStatus = 'NotAttempted'
            $record.AdDetails = 'AD was not attempted because the planned PVS/image/personality/DHCP sequence did not complete.'
            $record.NonAdPrerequisitesVerified = $false
            $record.PowerOverrideEligible = $false
            if ($settings.PowerOnAfterBuild) {
                $record.PowerResult = 'NotEligible'
                $record.PowerDetails = 'Not powered because the non-AD build sequence did not complete and verify.'
            }
            $record.Details = "The planned build stopped: $creationError No automatic rollback was attempted. Every component that completed was intentionally retained for the next Validation. Recorded state: PVS=$($state.PvsStatus); vDisk=$($state.ImageStatus); Reboot=$($state.PersonalityStatus); DHCP=$dhcpState. Run Validation again; V2 will reuse only exact retained components and create only missing components."
            Write-RecoveryLog -Level ERROR -Stage 'Partial build retained' -MachineName $record.MachineName -Message $record.Details
            $stopReason = "Not attempted because '$($record.MachineName)' retained a partial build after a component failure. Review Results and run Validation again before continuing."
            Invoke-PresentationPort -Name 'GridRefreshRecoverySafe' -Arguments @{ MachineName = $record.MachineName; FocusRecord = $record }
            Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = ($index + 1); MachineName = $record.MachineName }
            continue
        }

        $record.Stage = 'AD machine account'
        $record.Result = 'Running'
        $record.AdBuildEvaluated = $true
        $record.AdStatus = 'Running'
        $record.Details = "Executing retained AD action '$($context.Plan.AdAccount.Action)' and verifying any new PVS-managed SID binding."
        Invoke-PresentationPort -Name 'GridRefreshRecoverySafe' -Arguments @{ MachineName = $record.MachineName; FocusRecord = $record }
        $adSucceeded = $false
        $adFailure = ''
        $adAccount = $null
        try {
            if ($context.Plan.AdAccount.Action -eq 'ReuseExact') {
                $adAccount = $context.ExistingAdAccount
                if ($null -eq $adAccount -or
                    [string]::IsNullOrWhiteSpace([string]$adAccount.DistinguishedName) -or
                    [string]::IsNullOrWhiteSpace([string]$adAccount.Sid)) {
                    throw 'The retained Validation plan marked AD as ReuseExact but did not retain a complete exact AD account snapshot.'
                }
                $adAccount = Invoke-TimedOperation `
                    -Phase 'FinalVerification' `
                    -Operation 'ExistingAdPvsBinding' `
                    -MachineName $record.MachineName `
                    -Endpoint $settings.AdDnsDomain `
                    -Source 'PostWriteVerification' `
                    -Action {
                        Assert-FinalAdPvsBinding `
                            -Context $context `
                            -ExpectedPvsGuid ([guid]$state.PvsGuid) `
                            -ExpectedAdAccount $adAccount
                    }
                Write-RunLog -Level SUCCESS -Stage 'AD continuation' -MachineName $record.MachineName -Message "Skipped AD creation according to Validation plan '$($context.ValidationId)' and reverified exact account '$($adAccount.DistinguishedName)' with SID '$($adAccount.Sid)' after the planned non-AD work."
            }
            elseif ($context.Plan.AdAccount.Action -eq 'Create') {
                Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Creating and verifying the PVS-managed AD account for '$($record.MachineName)'..."; Stage = 'AD create'; MachineName = $record.MachineName }
                $adAccount = Invoke-TimedOperation `
                    -Phase 'AD' `
                    -Operation 'CreateAndVerifyBinding' `
                    -MachineName $record.MachineName `
                    -Endpoint $settings.AdDnsDomain `
                    -Source 'LiveSequentialWrite' `
                    -Action {
                        Invoke-PvsManagedAdMachineAccount `
                            -MachineName $record.MachineName `
                            -OuMetadata $settings.OuMetadata `
                            -ExpectedPvsGuid ([guid]$state.PvsGuid)
                    }
            }
            else {
                throw "Validation plan contains unsupported AD action '$($context.Plan.AdAccount.Action)'."
            }

            $record.AdStatus = 'Verified'
            $record.AdDetails = "AD/PVS binding verified for '$($adAccount.DistinguishedName)' with SID '$($adAccount.Sid)'."
            $adSucceeded = $true
        }
        catch {
            $adFailure = $_.Exception.Message
            $context.AdFailure = $adFailure
            $record.AdStatus = 'Failed'
            $record.AdDetails = $adFailure
            Write-RecoveryLog -Level ERROR -Stage 'AD machine account' -MachineName $record.MachineName -Message "AD creation or AD/PVS binding verification failed after the retained Validation plan was executed: $adFailure"
        }

        # This is the single broad per-row reread in Build. It occurs only
        # after all planned PVS, image, personality, DHCP, and AD writes have
        # been attempted; it is not a pre-write Validation pass.
        $record.Stage = 'Final non-AD verification'
        $record.Result = 'Running'
        $record.Details = 'Running the final post-write OLVM, PVS, vDisk, Reboot personality, and DHCP verification.'
        Invoke-PresentationPort -Name 'GridRefreshRecoverySafe' -Arguments @{ MachineName = $record.MachineName; FocusRecord = $record }
        try {
            $null = Invoke-TimedOperation `
                -Phase 'FinalVerification' `
                -Operation 'NonAdInfrastructure' `
                -MachineName $record.MachineName `
                -Source 'PostWriteVerification' `
                -Action {
                    Assert-CompletedNonAdInfrastructureState `
                        -Context $context `
                        -ExpectedPvsGuid ([guid]$state.PvsGuid)
                }
            $record.NonAdPrerequisitesEvaluated = $true
            $record.NonAdPrerequisitesVerified = $true
        }
        catch {
            $nonAdFailure = $_.Exception.Message
            $record.Stage = 'Final non-AD verification'
            $record.Result = 'AttentionRequired'
            $record.BuildAction = 'Completed retained actions, but final non-AD verification requires attention.'
            $record.NonAdPrerequisitesEvaluated = $true
            $record.NonAdPrerequisitesVerified = $false
            $record.PowerOverrideEligible = $false
            $record.PowerOverrideDecision = 'NotOffered'
            if ($settings.PowerOnAfterBuild) {
                $record.PowerResult = 'NotEligible'
                $record.PowerDetails = 'Not powered because final post-write non-AD verification failed.'
            }
            $adOutcomeText = if ($adSucceeded) {
                'The AD action completed and its binding was verified.'
            }
            else {
                "AD also requires attention: $adFailure"
            }
            $record.Details = "The retained Validation plan was executed, but final post-write non-AD verification failed: $nonAdFailure $adOutcomeText Completed components were retained; no automatic rollback was attempted. Run Validation again before retrying."
            Write-RecoveryLog -Level ERROR -Stage 'Final non-AD verification' -MachineName $record.MachineName -Message $record.Details
            $stopReason = "Not attempted because '$($record.MachineName)' failed final post-write non-AD verification. Review Results and run Validation again before continuing."
            Invoke-PresentationPort -Name 'GridRefreshRecoverySafe' -Arguments @{ MachineName = $record.MachineName; FocusRecord = $record }
            Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = ($index + 1); MachineName = $record.MachineName }
            continue
        }

        if ($adSucceeded) {
            $record.Stage = 'Complete'
            $record.Result = 'CreatedAndVerified'
            $record.BuildAction = 'Completed and verified.'
            $record.PowerOverrideEligible = $false
            $record.PowerOverrideDecision = 'NotOffered'
            $completedImageText = if ($settings.AssignPvsImage) {
                "image '$($settings.Image.Name)' version '$($settings.Image.EffectiveVersionDisplay)'"
            }
            else {
                'no PVS image assignment (zero vDisk mappings verified)'
            }
            $record.Details = "OLVM MAC, PVS target, $completedImageText, Reboot='$($context.RebootDay)', DHCP reservations, and PVS-managed AD account are complete and verified according to Validation plan '$($context.ValidationId)'. AD account: $($adAccount.DistinguishedName). Power-on result is reported separately."
            Write-RunLog -Level SUCCESS -Stage 'Complete' -MachineName $record.MachineName -Message $record.Details
        }
        else {
            $record.Stage = 'AD machine account'
            $record.Result = 'AttentionRequired'
            $record.BuildAction = 'Completed with AD verification requiring attention.'
            $record.PowerOverrideEligible = ($settings.PowerOnAfterBuild -and $script:AuditTrailHealthy)
            if ($record.PowerOverrideEligible) {
                $record.PowerOverrideDecision = 'AwaitingDecision'
                $record.PowerResult = 'Pending'
                $record.PowerDetails = 'All non-AD prerequisites passed final post-write verification. Awaiting an explicit operator decision about power-on despite the AD warning.'
            }
            elseif ($settings.PowerOnAfterBuild) {
                $record.PowerOverrideDecision = 'Unavailable'
                $record.PowerResult = 'NotEligible'
                $record.PowerDetails = 'Not powered because AD verification failed and an audited override decision is unavailable.'
            }
            $retainedImageText = if ($settings.AssignPvsImage) {
                "image '$($settings.Image.Name)'"
            }
            else {
                'no image assignment (zero mappings verified)'
            }
            $record.Details = "All non-AD prerequisites passed final post-write verification, but AD creation or AD/PVS binding verification failed: $adFailure PVS '$($settings.Collection.Display)', $retainedImageText, Reboot='$($context.RebootDay)', and DHCP IP '$($record.IPAddress)' / MAC '$($record.MacAddress)' were retained. The build remains AttentionRequired."
            Write-RecoveryLog -Level ERROR -Stage 'AD machine account' -MachineName $record.MachineName -Message $record.Details
        }
        Invoke-PresentationPort -Name 'GridRefreshRecoverySafe' -Arguments @{ MachineName = $record.MachineName; FocusRecord = $record }
        Invoke-PresentationPort -Name 'ProgressRecoverySafe' -Arguments @{ Value = ($index + 1); MachineName = $record.MachineName }
    }

    # Preserve skipped rows as well as the Ready rows represented by contexts.
    Set-ValidationBuildState -ValidationRecords $allRecords
    Invoke-PresentationPort -Name 'GridRefreshRecoverySafe'
    if ($settings.PowerOnAfterBuild) {
        Invoke-PresentationPort -Name 'AdPowerOverrideDecisions' -Arguments @{ Contexts = $contexts }
        Invoke-PresentationPort -Name 'GridRefreshRecoverySafe'
        try {
            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = 'Build phase finished. Starting optional post-build OLVM power-on for verified rows and explicitly approved AD-warning rows...'; Color = 'DarkOrange'; Stage = 'OLVM power' }
            Invoke-OlvmPostBuildPowerOn -Contexts $contexts
        }
        catch {
            # Power is deliberately a post-build convenience and never changes
            # retained infrastructure state. Convert an unexpected phase-level
            # error into per-VM outcomes so the normal completion summary is
            # still shown and completed builds remain CreatedAndVerified.
            $powerPhaseError = $_.Exception.Message
            Write-RecoveryLog -Level ERROR -Stage 'OLVM power' -Message "The optional power-on phase stopped unexpectedly: $powerPhaseError"
            foreach ($context in $contexts) {
                if (-not $context.Settings.PowerOnAfterBuild -or
                    -not (Test-ContextEligibleForPostBuildPower -Context $context) -or
                    $context.Record.PowerResult -ne 'Pending') {
                    continue
                }
                if ($context.PowerRequestAttempted) {
                    $context.Record.PowerResult = 'Failed'
                    $context.Record.PowerDetails = "A Start request was attempted and may have been accepted, but final OLVM status could not be verified because the power phase stopped. No retry was sent: $powerPhaseError"
                }
                else {
                    $context.Record.PowerResult = 'NotAttempted'
                    $context.Record.PowerDetails = "No Start request was confirmed because the optional power phase stopped before this VM could be processed: $powerPhaseError"
                }
                Write-RecoveryLog -Level ERROR -Stage 'OLVM power' -MachineName $context.Record.MachineName -Message "$($context.Record.PowerResult) - $($context.Record.PowerDetails)"
            }
        }
        Invoke-PresentationPort -Name 'GridRefreshRecoverySafe'
    }
    $outcomeCounts = Get-BuildOutcomeCounts -Records $allRecords
    $completedCount = $outcomeCounts.CreatedAndVerified
    $skippedCount = $outcomeCounts.SkippedExisting
    $blockedExcludedCount = $outcomeCounts.BlockedExcluded
    $attentionCount = $outcomeCounts.AttentionRequired
    $partialCount = $outcomeCounts.PartialRetained
    $notAttemptedCount = $outcomeCounts.NotAttempted
    $poweredCount = $outcomeCounts.PoweredOn
    $poweredWithAdWarningCount = $outcomeCounts.PoweredOnWithAdWarning
    $alreadyUpCount = $outcomeCounts.AlreadyUp
    $alreadyUpWithAdWarningCount = $outcomeCounts.AlreadyUpWithAdWarning
    $powerFailedCount = $outcomeCounts.PowerFailed
    $powerKeptOffCount = $outcomeCounts.PowerKeptOff
    $powerNotAttemptedCount = $outcomeCounts.PowerNotAttempted
    $powerNotEligibleCount = $outcomeCounts.PowerNotEligible
    $powerSummary = if ($settings.PowerOnAfterBuild) {
        " Power-on: $poweredCount powered on and verified ($poweredWithAdWarningCount with an approved AD warning), $alreadyUpCount already up ($alreadyUpWithAdWarningCount with an approved AD warning), $powerKeptOffCount kept off by operator, $powerFailedCount failed, $powerNotAttemptedCount not attempted, $powerNotEligibleCount not eligible."
    }
    else {
        ' Power-on was not requested.'
    }
    $summary = "Build finished: $completedCount complete and verified, $skippedCount matched the exact stored provisioning configuration and required no write, $blockedExcludedCount blocked by Validation and excluded unchanged, $attentionCount require attention ($partialCount with partial state retained), $notAttemptedCount not attempted. No automatic rollback was performed.$powerSummary Log: $script:LogPath"
    $level = if ($blockedExcludedCount -eq 0 -and $attentionCount -eq 0 -and $notAttemptedCount -eq 0 -and $powerFailedCount -eq 0 -and $powerNotAttemptedCount -eq 0) { 'SUCCESS' } else { 'WARN' }
    if (-not $script:AuditTrailHealthy) {
        $level = 'WARN'
        $summary = "$summary The audit log became unavailable; manual review is required."
    }
    Write-RecoveryLog -Level $level -Stage 'Run summary' -Message $summary
    Invoke-PresentationPort -Name 'SetBuildEnabled' -Arguments @{ Enabled = $false }
    return 'Finished'
    }
    finally {
        Exit-FarmBuildLock -Lock $farmLock
    }
}


function Invoke-PvsDhcpCreation {
    <# Compatibility wrapper. New internal callers use Invoke-NonAdBuildPlan. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Context,

        [Parameter(Mandatory = $true)]
        [psobject]$State,

        [Parameter(Mandatory = $true)]
        [int]$ServerNumber,

        [Parameter(Mandatory = $true)]
        [int]$ServerCount
    )

    Invoke-NonAdBuildPlan @PSBoundParameters
}
