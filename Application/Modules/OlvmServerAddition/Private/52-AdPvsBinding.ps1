#region Active Directory and PVS binding helpers

function Get-VerifiedAdPvsBinding {
    <#
      Verifies one fresh three-way AD/PVS binding snapshot across every
      discovered writable DC. Optional expected DN/SID values make the final
      gate detect a move or delete/recreate event.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$MachineName,
        [Parameter(Mandatory = $true)][psobject]$OuMetadata,
        [Parameter(Mandatory = $true)][guid]$ExpectedPvsGuid,
        [AllowEmptyString()][string]$ExpectedAdDistinguishedName = '',
        [AllowEmptyString()][string]$ExpectedAdSid = '',
        [string]$Stage = 'AD verify'
    )

    $verifiedPvsAccount = Get-PvsAdComputerAccount `
        -Name $MachineName `
        -Domain $OuMetadata.DomainDnsName
    $verifiedPvsDevice = Get-PvsTargetDevice -Name $MachineName
    if ($null -eq $verifiedPvsAccount -or $null -eq $verifiedPvsDevice) {
        throw 'PVS account or target-device metadata is not available.'
    }
    if ([guid]$verifiedPvsDevice.Guid -ne $ExpectedPvsGuid) {
        throw "PVS target '$MachineName' was replaced. Expected GUID '$ExpectedPvsGuid'; found '$($verifiedPvsDevice.Guid)'."
    }

    $pvsAccountSid = [string](Get-ObjectPropertyValue -InputObject $verifiedPvsAccount -Name 'Sid')
    $pvsAccountDc = [string](Get-ObjectPropertyValue -InputObject $verifiedPvsAccount -Name 'DomainController')
    $pvsDeviceSid = [string](Get-ObjectPropertyValue -InputObject $verifiedPvsDevice -Name 'DomainObjectSID')
    $pvsDeviceDomain = [string](Get-ObjectPropertyValue -InputObject $verifiedPvsDevice -Name 'DomainName')
    $pvsDeviceDc = [string](Get-ObjectPropertyValue -InputObject $verifiedPvsDevice -Name 'DomainControllerName')
    $pvsDeviceTime = Get-ObjectPropertyValue -InputObject $verifiedPvsDevice -Name 'DomainTimeCreated'

    if ([string]::IsNullOrWhiteSpace($pvsAccountSid) -or
        [string]::IsNullOrWhiteSpace($pvsDeviceSid) -or
        -not $pvsAccountSid.Equals($pvsDeviceSid,[System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The PVS AD-account SID and PVS target DomainObjectSID are missing or do not match.'
    }
    if (-not $pvsDeviceDomain.Equals($OuMetadata.DomainDnsName,[System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace($pvsDeviceDc) -or
        -not (Test-PvsDomainTimestamp -Value $pvsDeviceTime)) {
        throw 'PVS did not retain the expected domain, domain controller, and creation timestamp metadata.'
    }

    $writableServers = @(Get-WritableAdDomainControllerNames -OuMetadata $OuMetadata)
    $matchingAccounts = New-Object 'System.Collections.Generic.List[object]'
    $laggingServers = New-Object 'System.Collections.Generic.List[string]'
    $unavailableServers = New-Object 'System.Collections.Generic.List[string]'
    $conflicts = New-Object 'System.Collections.Generic.List[string]'
    $machineKey = $MachineName.Trim().ToUpperInvariant()

    foreach ($verificationServer in $writableServers) {
        try {
            $snapshot = Find-AdComputersBatch `
                -MachineNames ([string[]]@($MachineName)) `
                -DomainDn $OuMetadata.DomainDn `
                -Server $verificationServer
        }
        catch {
            $lookupMessage = (($_.Exception.Message -replace '\s+',' ').Trim())
            $failureKind = [string]$_.Exception.Data['AdLookupFailureKind']
            if ($failureKind -ieq 'Unavailable') {
                [void]$unavailableServers.Add("${verificationServer}: $lookupMessage")
            }
            else {
                [void]$conflicts.Add("${verificationServer}: $lookupMessage")
            }
            continue
        }

        $entry = $snapshot.Entries[$machineKey]
        if ($null -eq $entry) {
            [void]$conflicts.Add("${verificationServer}: the complete LDAP response omitted the requested account state.")
            continue
        }
        if ([string]$entry.State -eq 'ConfirmedAbsent') {
            [void]$laggingServers.Add($verificationServer)
            continue
        }
        if ([string]$entry.State -ne 'Found' -or $null -eq $entry.Account) {
            [void]$conflicts.Add("${verificationServer}: AD returned unsupported account state '$($entry.State)'.")
            continue
        }

        $adAccount = $entry.Account
        try {
            $adSid = [string]$adAccount.Sid
            $adDn = [string]$adAccount.DistinguishedName
            $parentDn = Get-ParentDistinguishedName -DistinguishedName $adDn
            $accountConflicts = New-Object 'System.Collections.Generic.List[string]'
            if (-not (Test-DistinguishedNameEqual -First $parentDn -Second $OuMetadata.DistinguishedName)) {
                [void]$accountConflicts.Add("OU '$parentDn' does not match '$($OuMetadata.DistinguishedName)'")
            }
            if ([string]::IsNullOrWhiteSpace($adSid) -or
                -not $pvsAccountSid.Equals($adSid,[System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$accountConflicts.Add("AD SID '$adSid' does not match PVS SID '$pvsAccountSid'")
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedAdDistinguishedName) -and
                -not (Test-DistinguishedNameEqual -First $adDn -Second $ExpectedAdDistinguishedName)) {
                [void]$accountConflicts.Add("DN '$adDn' changed from '$ExpectedAdDistinguishedName'")
            }
            if (-not [string]::IsNullOrWhiteSpace($ExpectedAdSid) -and
                -not $adSid.Equals($ExpectedAdSid,[System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$accountConflicts.Add("SID '$adSid' changed from '$ExpectedAdSid'")
            }
            if ($accountConflicts.Count -gt 0) {
                [void]$conflicts.Add("${verificationServer}: $($accountConflicts -join '; ').")
                continue
            }
            [void]$matchingAccounts.Add([pscustomobject]@{
                    Server  = $verificationServer
                    Account = $adAccount
                })
        }
        catch {
            [void]$conflicts.Add("${verificationServer}: $((($_.Exception.Message -replace '\s+',' ').Trim())).")
        }
    }

    if ($conflicts.Count -gt 0) {
        $conflictException = [System.InvalidOperationException]::new(
            "Conflicting AD computer-account state was returned for '$MachineName': $($conflicts -join ' | ')"
        )
        $conflictException.Data['AdBindingFailureKind'] = 'Conflict'
        throw $conflictException
    }
    if ($matchingAccounts.Count -eq 0) {
        $laggingText = if ($laggingServers.Count -eq 0) { 'none' } else { $laggingServers -join ', ' }
        $unavailableText = if ($unavailableServers.Count -eq 0) { 'none' } else { $unavailableServers -join ' | ' }
        $notVisibleException = [System.InvalidOperationException]::new(
            "No writable domain controller confirmed the exact AD/PVS binding for '$MachineName'. Account not visible: $laggingText. Query unavailable: $unavailableText."
        )
        $notVisibleException.Data['AdBindingFailureKind'] = 'NotVisible'
        throw $notVisibleException
    }

    if ($laggingServers.Count -gt 0) {
        Write-RecoveryLog -Level WARN -Stage $Stage -MachineName $MachineName -Message "The exact AD account is not yet visible on writable DC(s): $($laggingServers -join ', '). A matching writable DC is sufficient, so this replication lag does not block completion."
    }
    if ($unavailableServers.Count -gt 0) {
        Write-RecoveryLog -Level WARN -Stage $Stage -MachineName $MachineName -Message "Writable DC query warning(s): $($unavailableServers -join ' | '). A matching writable DC is sufficient, so these query failures do not block completion."
    }

    $matchedServers = [string[]]@($matchingAccounts | ForEach-Object { [string]$_.Server })
    $adAccount = $matchingAccounts[0].Account

    return [pscustomobject]@{
        AdAccount                    = $adAccount
        VerificationServer           = $matchedServers[0]
        MatchingDomainControllers    = $matchedServers
        LaggingDomainControllers     = [string[]]$laggingServers.ToArray()
        UnavailableDomainControllers = [string[]]$unavailableServers.ToArray()
        PvsAccountSid                = $pvsAccountSid
        PvsDeviceSid                 = $pvsDeviceSid
        PvsAccountDomainController   = $pvsAccountDc
        PvsDeviceDomainController    = $pvsDeviceDc
    }
}

function Wait-ForVerifiedAdPvsBinding {
    <#
      Runs one complete writable-DC fan-out. A single short second pass is
      allowed only when the first pass cannot confirm the account anywhere.
      The AD creation command is never reissued.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$MachineName,
        [Parameter(Mandatory = $true)][psobject]$OuMetadata,
        [Parameter(Mandatory = $true)][guid]$ExpectedPvsGuid,
        [ValidateRange(1,2)][int]$VerificationAttempts = $script:AdBindingVerificationAttempts,
        [ValidateRange(0,30)][int]$VerificationDelaySeconds = $script:AdBindingVerificationDelaySeconds,
        [AllowEmptyString()][string]$ExpectedAdDistinguishedName = '',
        [AllowEmptyString()][string]$ExpectedAdSid = '',
        [string]$Stage = 'AD verify'
    )

    $lastMessage = 'No verification pass completed.'
    $lastErrorRecord = $null
    $lastFailureKind = ''
    $completedPasses = 0
    $maximumScheduledWaitSeconds = [math]::Max(0, ($VerificationAttempts - 1) * $VerificationDelaySeconds)
    Write-RecoveryLog -Level INFO -Stage $Stage -MachineName $MachineName -Message "Starting bounded AD/PVS binding reconciliation across every discovered writable DC: make up to $VerificationAttempts full fan-out pass(es), beginning immediately, with $VerificationDelaySeconds second(s) before the optional second pass (maximum scheduled wait $maximumScheduledWaitSeconds second(s), plus query time). The AD creation command will not be repeated."
    for ($attempt = 1; $attempt -le $VerificationAttempts; $attempt++) {
        $completedPasses = $attempt
        Invoke-PresentationPort -Name 'RecoveryStatus' -Arguments @{ Text = "Verifying the AD and PVS machine-account binding for '$MachineName' across writable DCs (pass $attempt of $VerificationAttempts)..."; Stage = $Stage; MachineName = $MachineName }
        try {
            $binding = Get-VerifiedAdPvsBinding `
                -MachineName $MachineName `
                -OuMetadata $OuMetadata `
                -ExpectedPvsGuid $ExpectedPvsGuid `
                -ExpectedAdDistinguishedName $ExpectedAdDistinguishedName `
                -ExpectedAdSid $ExpectedAdSid `
                -Stage $Stage
            Write-RecoveryLog -Level SUCCESS -Stage $Stage -MachineName $MachineName -Message "Verified AD DN '$($binding.AdAccount.DistinguishedName)' and matching SID '$($binding.AdAccount.Sid)' through AD, Get-PvsADAccount, and Get-PvsDevice. Matching writable DC(s): $($binding.MatchingDomainControllers -join ', '). PVS-reported DCs: account='$($binding.PvsAccountDomainController)', target='$($binding.PvsDeviceDomainController)'."
            return $binding.AdAccount
        }
        catch {
            $lastErrorRecord = $_
            $lastMessage = $_.Exception.Message
            $failureKind = [string]$_.Exception.Data['AdBindingFailureKind']
            $lastFailureKind = $failureKind
            Write-RecoveryLog -Level WARN -Stage $Stage -MachineName $MachineName -Message "Writable-DC fan-out pass $attempt failed: $lastMessage"
            if ($failureKind -ine 'NotVisible') {
                break
            }
            if ($attempt -lt $VerificationAttempts -and $VerificationDelaySeconds -gt 0) {
                Start-Sleep -Seconds $VerificationDelaySeconds
            }
        }
    }
    $finalMessage = "Complete AD/PVS binding verification failed after $completedPasses writable-DC fan-out pass(es): $lastMessage"
    $innerException = if ($null -eq $lastErrorRecord) { $null } else { $lastErrorRecord.Exception }
    $verificationException = [System.InvalidOperationException]::new($finalMessage,$innerException)
    $verificationException.Data['AdBindingFailureKind'] = $lastFailureKind
    $verificationException.Data['Attempt'] = $completedPasses
    $verificationException.Data['MaxAttempts'] = $VerificationAttempts
    $verificationException.Data['Disposition'] = if ($lastFailureKind -ieq 'NotVisible') {
        'Retryable'
    }
    else {
        'DoNotRetry'
    }
    throw $verificationException
}

function Invoke-PvsMachineAccountCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.CommandInfo]$Command,

        [Parameter(Mandatory = $true)]
        [guid]$ExpectedPvsGuid,

        [Parameter(Mandatory = $true)]
        [string]$Domain,

        [Parameter(Mandatory = $true)]
        [string]$PvsOuPath
    )

    $arguments = @{ ErrorAction = 'Stop' }
    # Bind only by the immutable PVS target GUID. Name-based invocation is
    # deliberately refused because another target could otherwise replace the
    # name between the final check and the domain operation.
    if ($Command.Parameters.ContainsKey('DeviceId')) {
        $arguments['DeviceId'] = $ExpectedPvsGuid
    }
    elseif ($Command.Parameters.ContainsKey('Guid')) {
        $arguments['Guid'] = $ExpectedPvsGuid
    }
    else {
        throw 'Add-PvsDeviceToDomain does not expose a DeviceId or Guid selector. The tool refuses name-based AD creation because it cannot guarantee that an existing or replacement PVS target will remain unchanged.'
    }

    if (-not $Command.Parameters.ContainsKey('Domain') -or
        -not $Command.Parameters.ContainsKey('OrganizationUnit')) {
        throw 'Add-PvsDeviceToDomain does not expose the required Domain and OrganizationUnit parameters.'
    }
    $arguments['Domain'] = $Domain
    $arguments['OrganizationUnit'] = $PvsOuPath
    if ($Command.Parameters.ContainsKey('Confirm')) {
        $arguments['Confirm'] = $false
    }

    return @(& $Command @arguments)
}

function Invoke-PvsManagedAdMachineAccount {
    <#
      Success requires three matching SIDs: direct AD, Get-PvsADAccount, and
      Get-PvsDevice.DomainObjectSID. Verification checks every writable DC and
      accepts one exact OU/SID match when other DCs are merely lagging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineName,

        [Parameter(Mandatory = $true)]
        [psobject]$OuMetadata,

        [Parameter(Mandatory = $true)]
        [guid]$ExpectedPvsGuid,

        [ValidateRange(1, 2)]
        [int]$VerificationAttempts = $script:AdBindingVerificationAttempts,

        [ValidateRange(0, 30)]
        [int]$VerificationDelaySeconds = $script:AdBindingVerificationDelaySeconds
    )

    $command = Get-Command -Name Add-PvsDeviceToDomain -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $command) {
        throw 'Add-PvsDeviceToDomain is unavailable on this PVS console host.'
    }

    Assert-AuditTrailAvailable
    Assert-FarmBuildLockOwned
    Write-RunLog -Level INFO -Stage 'AD create' -MachineName $MachineName -Message "Calling Add-PvsDeviceToDomain for domain '$($OuMetadata.DomainDnsName)' and PVS OU path '$($OuMetadata.PvsOuPath)' according to the retained Validation action plan."
    $commandError = $null
    $commandInvoked = $false
    $commandOutput = @()
    try {
        $commandInvoked = $true
        $commandOutput = @(Invoke-PvsMachineAccountCommand `
            -Command $command `
            -ExpectedPvsGuid $ExpectedPvsGuid `
            -Domain $OuMetadata.DomainDnsName `
            -PvsOuPath $OuMetadata.PvsOuPath)
    }
    catch {
        $commandError = $_.Exception.Message
        Write-RecoveryLog -Level ERROR -Stage 'AD create' -MachineName $MachineName -Message $commandError
    }
    if ($commandInvoked) {
        if ([string]::IsNullOrWhiteSpace($commandError)) {
            $returnTypes = @($commandOutput | ForEach-Object { $_.GetType().FullName } | Select-Object -Unique)
            Write-RecoveryLog -Level INFO -Stage 'AD create' -MachineName $MachineName -Message "PVS command returned without a terminating error. Return types: $($returnTypes -join '; ')."
        }
        else {
            Write-RecoveryLog -Level WARN -Stage 'AD reconcile' -MachineName $MachineName -Message 'The PVS command reported an error; verification will still run because the account might have been created server-side.'
        }
    }

    try {
        $verifiedAccountResult = Wait-ForVerifiedAdPvsBinding `
            -MachineName $MachineName `
            -OuMetadata $OuMetadata `
            -ExpectedPvsGuid $ExpectedPvsGuid `
            -VerificationAttempts $VerificationAttempts `
            -VerificationDelaySeconds $VerificationDelaySeconds `
            -Stage 'AD verify'
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($commandError)) {
            throw "PVS reported '$commandError'. Reconciliation also failed: $($_.Exception.Message)"
        }
        throw "PVS returned without a terminating error, but $($_.Exception.Message)"
    }
    if (-not [string]::IsNullOrWhiteSpace($commandError)) {
        Write-RecoveryLog -Level WARN -Stage 'AD reconcile' -MachineName $MachineName -Message "The command error was reconciled as successful after full verification: $commandError"
    }
    if (-not $script:AuditTrailHealthy) {
        throw 'The AD account and PVS binding were verified, but the run log became unavailable after creation. The row requires manual review and no later row will be attempted.'
    }
    return $verifiedAccountResult
}

#endregion Active Directory and PVS binding helpers
