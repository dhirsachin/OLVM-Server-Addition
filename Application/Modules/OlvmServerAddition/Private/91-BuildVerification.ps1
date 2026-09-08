function Assert-CompletedNonAdInfrastructureState {
    <# Post-write verification for every prerequisite except AD. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Context,

        [Parameter(Mandatory = $true)]
        [guid]$ExpectedPvsGuid
    )

    $record = $Context.Record
    $settings = $Context.Settings
    Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Running the final OLVM, PVS, and DHCP verification for '$($record.MachineName)'..."; Stage = 'Final non-AD verification'; MachineName = $record.MachineName }
    $null = Assert-PvsTargetCreated `
        -Record $record `
        -Collection $settings.Collection `
        -ExpectedGuid ([string]$ExpectedPvsGuid)

    # Re-read OLVM after all writes so a VM/NIC replacement during the build
    # cannot be marked complete or become eligible for post-build power-on.
    $finalMac = Get-OlvmMac `
        -MachineName $Context.Row.LookupName `
        -SelectedManager ([string]$Context.OlvmIdentity.Manager)
    if ($finalMac -ine $record.MacAddress) {
        throw "Final OLVM verification found MAC '$finalMac', but Validation and the created PVS/DHCP objects use '$($record.MacAddress)'."
    }
    $finalOlvmIdentity = Get-OlvmRouteIdentity -MachineName $Context.Row.LookupName
    if ([string]$finalOlvmIdentity.Manager -ine [string]$Context.OlvmIdentity.Manager -or
        [string]$finalOlvmIdentity.VmId -ine [string]$Context.OlvmIdentity.VmId) {
        throw "Final OLVM identity verification changed. Expected Manager '$($Context.OlvmIdentity.Manager)' and VM ID '$($Context.OlvmIdentity.VmId)'; found Manager '$($finalOlvmIdentity.Manager)' and VM ID '$($finalOlvmIdentity.VmId)'."
    }
    if ($settings.PowerOnAfterBuild) {
        $null = Assert-OlvmVmIsDown `
            -Identity $finalOlvmIdentity `
            -MachineName $record.MachineName
    }
    $Context.OlvmIdentity = $finalOlvmIdentity
    if ($settings.AssignPvsImage) {
        $null = Assert-PvsImageSnapshotUnchanged `
            -Collection $settings.Collection `
            -Store $settings.Store `
            -ExpectedImage $settings.Image
        $null = Assert-PvsImageAssignedToDevice `
            -DeviceId $ExpectedPvsGuid `
            -Image $settings.Image
    }
    else {
        $null = Assert-PvsNoImageAssignedToDevice -DeviceId $ExpectedPvsGuid
    }
    $null = Assert-PvsRebootPersonality `
        -DeviceId $ExpectedPvsGuid `
        -ExpectedDay ([string]$Context.RebootDay) `
        -ExpectedOtherFingerprint ([string]$Context.PersonalityOtherFingerprint)

    $currentFarmServers = Get-DhcpServerNames
    $targetServers = @($Context.DhcpTargets | ForEach-Object { [string]$_.Server } | Sort-Object -Unique)
    $missingTargets = @($currentFarmServers | Where-Object { $targetServers -inotcontains $_ })
    $staleTargets = @($targetServers | Where-Object { $currentFarmServers -inotcontains $_ })
    if ($missingTargets.Count -gt 0 -or $staleTargets.Count -gt 0) {
        throw "The PVS farm server set changed during provisioning. Missing DHCP verification targets: '$($missingTargets -join ', ')'. No longer in farm: '$($staleTargets -join ', ')'."
    }

    foreach ($target in $Context.DhcpTargets) {
        Assert-DhcpReservationCreated `
            -Target $target `
            -Record $record `
            -BootFile $settings.BootFile
    }
    $verifiedImageText = if ($settings.AssignPvsImage) {
        "image '$($settings.Image.Name)' version '$($settings.Image.EffectiveVersionDisplay)'"
    }
    else {
        'zero vDisk mappings as requested'
    }
    Write-RunLog -Level SUCCESS -Stage 'Final non-AD verification' -MachineName $record.MachineName -Message "OLVM VM ID/MAC and down state where required, PVS target, $verifiedImageText, Reboot='$($Context.RebootDay)', and every DHCP reservation were verified after the planned writes."
    return $true
}

function Assert-FinalAdPvsBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Context,
        [Parameter(Mandatory = $true)][guid]$ExpectedPvsGuid,
        [Parameter(Mandatory = $true)][psobject]$ExpectedAdAccount
    )

    return Wait-ForVerifiedAdPvsBinding `
        -MachineName $Context.Record.MachineName `
        -OuMetadata $Context.Settings.OuMetadata `
        -ExpectedPvsGuid $ExpectedPvsGuid `
        -ExpectedAdDistinguishedName ([string]$ExpectedAdAccount.DistinguishedName) `
        -ExpectedAdSid ([string]$ExpectedAdAccount.Sid) `
        -VerificationAttempts $script:AdBindingVerificationAttempts `
        -VerificationDelaySeconds $script:AdBindingVerificationDelaySeconds `
        -Stage 'Final AD/PVS verify'
}
