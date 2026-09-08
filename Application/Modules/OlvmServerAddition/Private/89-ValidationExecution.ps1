function Invoke-Preview {
    [CmdletBinding()]
    param()

    $previewKind = 'Validation'
    $previewPhase = 'Preview'
    $batchTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $batchOutcome = 'Failed'
    $script:ValidationAttemptCount = [long]$script:ValidationAttemptCount + 1
    $validationAttempt = [long]$script:ValidationAttemptCount
    $validationId = [guid]::NewGuid().ToString('N')
    $validatedAtUtc = [DateTime]::UtcNow
    try {
    Write-RunLog -Level INFO -Stage $previewKind -Message "BEGIN Validation attempt $validationAttempt; ValidationId=$validationId."
    Reset-OlvmRouteCache
    # Never leave results from an older input set on screen while a new
    # validation pass is starting or if that pass fails before row creation.
    Invoke-PresentationPort -Name 'SetBuildEnabled' -Arguments @{ Enabled = $false }
    Set-ValidationBuildState -ValidationRecords ([object[]]@()) -BuildContexts $null
    Invoke-PresentationPort -Name 'GridRefresh'
    Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "$previewKind started: validating the server list, choices, and selected OU..."; Stage = $previewKind }
    $startedAt = Get-Date
    $batch = Invoke-TimedOperation `
        -Phase $previewPhase `
        -Operation 'InputAndOU' `
        -Source 'Live' `
        -Action { Invoke-PresentationPort -Name 'ReadBuildRequest' }
    $null = Invoke-TimedOperation `
        -Phase $previewPhase `
        -Operation 'PVS.CollectionCheck' `
        -Source 'Live' `
        -Action { Assert-PvsCollectionAvailable -Collection $batch.Settings.Collection }
    if ($batch.Settings.AssignPvsImage) {
        $null = Invoke-TimedOperation `
            -Phase $previewPhase `
            -Operation 'PVS.ImageCheck' `
            -Source 'Live' `
            -Action {
                Assert-PvsImageSnapshotUnchanged `
                    -Collection $batch.Settings.Collection `
                    -Store $batch.Settings.Store `
                    -ExpectedImage $batch.Settings.Image
            }
    }
    else {
        Write-RunLog -Level INFO -Stage $previewKind -Message 'Optional PVS image assignment was not requested; Store and vDisk readiness checks were skipped.'
    }
    $rebootDistribution = Invoke-TimedOperation `
        -Phase $previewPhase `
        -Operation 'PVS.RebootDistribution' `
        -Source 'LiveCollectionRead' `
        -Action { Get-PvsRebootDistribution -Collection $batch.Settings.Collection }
    if ($batch.Settings.PowerOnAfterBuild) {
        $null = Invoke-TimedOperation `
            -Phase $previewPhase `
            -Operation 'OLVM.PowerCapability' `
            -Source 'LiveModuleCapability' `
            -Action { Assert-OlvmPowerCommandAvailable }
    }
    $servers = $null
    $previewCache = New-PreviewReadCache
    $directAdSnapshot = $null
    $directAdSnapshotLoaded = $false
    $adBatchNames = @($batch.Rows |
        Where-Object {
            [string]::IsNullOrWhiteSpace([string]$_.InputError) -and
            -not [string]::IsNullOrWhiteSpace([string]$_.MachineName)
        } |
        ForEach-Object { [string]$_.MachineName } |
        Sort-Object -Unique)

    Write-RunLog -Level INFO -Stage $previewKind -Message ("Settings: Collection='{0}'; Assign image={1}; Store='{2}'; Image='{3}' version='{4}'; Boot='{5}' ({6}); PVS case='{7}'; DHCP case='{8}'; DHCP name='{9}'; AD domain='{10}'; OU='{11}'; Power after build={12}; OLVM Manager='{13}'; Server count={14}." -f
        $batch.Settings.Collection.Display,
        $batch.Settings.AssignPvsImage,
        $batch.Settings.StoreDisplay,
        $batch.Settings.ImageDisplay,
        $batch.Settings.ImageVersionDisplay,
        $batch.Settings.BootLabel,
        $batch.Settings.BootFile,
        $batch.Settings.PvsNameCase,
        $batch.Settings.DhcpNameCase,
        $batch.Settings.ReservationName,
        $batch.Settings.AdDnsDomain,
        $batch.Settings.OuMetadata.DisplayPath,
        $batch.Settings.PowerOnAfterBuild,
        $batch.Settings.OlvmManagerDisplay,
        $batch.Rows.Count)

    $contexts = New-Object 'System.Collections.Generic.List[object]'
    $records = New-Object 'System.Collections.Generic.List[object]'
    $resolvedMacOwners = @{}
    $currentRow = 0

    foreach ($row in $batch.Rows) {
        $currentRow++
        Invoke-PresentationPort -Name 'SetProgressIndeterminate' -Arguments @{ Value = $false }
        Invoke-PresentationPort -Name 'SetProgressMaximum' -Arguments @{ Value = $batch.Rows.Count }
        Invoke-PresentationPort -Name 'SetProgressValue' -Arguments @{ Value = $currentRow - 1 }
        $record = New-ValidationRecord `
            -Row $row `
            -Settings $batch.Settings `
            -Stage $previewKind
        $rowStartedAt = Get-Date
        $rowTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $rowOutcome = 'Blocked'
        Write-RunLog -Level INFO -Stage $previewKind -MachineName $row.LookupName -Message "Row $($row.Line) started with IP '$($row.IPAddress)'."

        try {
            $null = Invoke-TimedOperation `
                -Phase $previewPhase `
                -Operation 'Input.RowValidation' `
                -MachineName $row.LookupName `
                -Source 'Live' `
                -Action {
                    if (-not [string]::IsNullOrWhiteSpace($row.InputError)) {
                        throw $row.InputError
                    }
                    if (@($batch.Rows | Where-Object {
                                $_.Line -ne $row.Line -and $_.MachineName -ieq $row.MachineName
                            }).Count -gt 0) {
                        throw "Server name '$($row.MachineName)' appears more than once in the submitted list."
                    }
                    if (@($batch.Rows | Where-Object {
                                $_.Line -ne $row.Line -and $_.IPAddress -eq $row.IPAddress
                            }).Count -gt 0) {
                        throw "IP address '$($row.IPAddress)' appears more than once in the submitted list."
                    }
                }

            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "[Server $currentRow/$($batch.Rows.Count)] Finding '$($row.LookupName)' in OLVM and reading its NIC MAC..."; Stage = 'OLVM lookup'; MachineName = $row.LookupName }
            $record.MacAddress = Invoke-TimedOperation `
                -Phase $previewPhase `
                -Operation 'OLVM.MacLookup' `
                -MachineName $row.MachineName `
                -Source 'LiveSessionReuse' `
                -Action {
                    Get-OlvmMac `
                        -MachineName $row.LookupName `
                        -SelectedManager ([string]$batch.Settings.OlvmManager) `
                        -FallbackToAutoDetect:(-not [string]::IsNullOrWhiteSpace([string]$batch.Settings.OlvmManager))
                }
            $olvmIdentity = Get-OlvmRouteIdentity -MachineName $row.LookupName
            $record.OlvmVmStatus = if ([string]::IsNullOrWhiteSpace([string]$olvmIdentity.Status)) {
                'unknown'
            }
            else {
                [string]$olvmIdentity.Status
            }
            $record.CurrentStreamedPvsImage = if ($record.OlvmVmStatus -eq 'down') {
                'N/A at Validation - the OLVM VM was powered off.'
            }
            else {
                'Not evaluated - Validation checks the configured PVS mapping, not the vDisk currently streamed by a running VM.'
            }
            if ($batch.Settings.PowerOnAfterBuild) {
                $null = Invoke-TimedOperation `
                    -Phase $previewPhase `
                    -Operation 'OLVM.PowerEligibility' `
                    -MachineName $row.MachineName `
                    -Endpoint $olvmIdentity.Manager `
                    -Source 'LiveExactIdentity' `
                    -Action { Assert-OlvmVmIsDown -Identity $olvmIdentity -MachineName $row.MachineName }
            }
            if ($resolvedMacOwners.ContainsKey($record.MacAddress)) {
                throw "OLVM MAC '$($record.MacAddress)' is also returned for '$($resolvedMacOwners[$record.MacAddress])' in this batch."
            }
            $resolvedMacOwners[$record.MacAddress] = $row.MachineName

            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "[Server $currentRow/$($batch.Rows.Count)] Classifying exact or missing PVS state..."; Stage = 'PVS continuation plan'; MachineName = $row.MachineName }
            $pvsPlan = Invoke-TimedOperation `
                -Phase $previewPhase `
                -Operation 'PVS.ComponentPlan' `
                -MachineName $row.MachineName `
                -Source 'Live' `
                -Action {
                    Get-PvsTargetActionPlan `
                        -Record $record `
                        -Collection $batch.Settings.Collection
                }
            $imagePlan = Get-PvsImageActionPlan `
                -PvsPlan $pvsPlan `
                -Settings $batch.Settings
            $record.ConfiguredPvsImage = if ($batch.Settings.AssignPvsImage) {
                $configurationState = if ($imagePlan.Action -eq 'ReuseExact') {
                    'exact assignment validated'
                }
                else {
                    'planned for Build; not yet assigned by this run'
                }
                "$($batch.Settings.ImageDisplay), version $($batch.Settings.ImageVersionDisplay) ($configurationState)"
            }
            elseif ($pvsPlan.Action -eq 'ReuseExact') {
                'None (zero configured mappings validated)'
            }
            else {
                'None requested (zero mappings will be verified during Build)'
            }

            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "[Server $currentRow/$($batch.Rows.Count)] Resolving DNS and calculating the DHCP reservation name..."; Stage = 'DNS'; MachineName = $row.MachineName }
            $fqdn = Invoke-TimedOperation `
                -Phase $previewPhase `
                -Operation 'DNS.Resolve' `
                -MachineName $row.MachineName `
                -Source 'Live' `
                -Action {
                    Get-FqdnForInput `
                        -MachineName $row.MachineName `
                        -IPAddress $row.IPAddress `
                        -AdDnsDomain $batch.Settings.AdDnsDomain
                }
            $record.Fqdn = $fqdn
            $hostName = if ($batch.Settings.DhcpNameCase -eq 'Upper') {
                $fqdn.Split('.')[0].ToUpperInvariant()
            }
            else {
                $fqdn.Split('.')[0].ToLowerInvariant()
            }
            $record.DhcpName = if ($batch.Settings.ReservationName -eq 'FQDN') {
                if ($batch.Settings.DhcpNameCase -eq 'Upper') {
                    $fqdn.ToUpperInvariant()
                }
                else {
                    $fqdn.ToLowerInvariant()
                }
            }
            else {
                $hostName
            }

            if ($null -eq $servers) {
                $serverEntry = Get-PreviewCacheSnapshot `
                    -Cache $previewCache `
                    -Key 'PVS.FarmServers' `
                    -Phase $previewPhase `
                    -Operation 'PVS.FarmDiscovery' `
                    -MachineName $row.MachineName `
                    -Endpoint 'PVSFarm' `
                    -Loader { @(Get-DhcpServerNames) }
                $servers = [string[]]@($serverEntry.Value)
            }
            $targets = @(Get-PreviewDhcpTargets `
                -IPAddress (Get-IPv4Address -Value $row.IPAddress) `
                -Servers $servers `
                -MachineName $row.MachineName `
                -Cache $previewCache `
                -Phase $previewPhase `
                -InputServerNumber $currentRow `
                -InputServerCount $batch.Rows.Count)
            if ($targets.Count -eq 0) {
                throw 'No eligible DHCP server and scope were found.'
            }
            $dhcpServerNumber = 0
            foreach ($target in $targets) {
                $dhcpServerNumber++
                Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "[Server $currentRow/$($batch.Rows.Count); DHCP server $dhcpServerNumber/$($targets.Count)] Checking reservations and option 67 on '$($target.Server)', scope '$($target.ScopeId)'..."; Stage = 'DHCP preflight'; MachineName = $row.MachineName }
                $null = Invoke-TimedOperation `
                    -Phase $previewPhase `
                    -Operation 'DHCP.Preflight' `
                    -MachineName $row.MachineName `
                    -Endpoint $target.Server `
                    -Source 'PreviewCache' `
                    -Action {
                        Assert-PreviewDhcpTargetAvailable `
                            -Target $target `
                            -Record $record `
                            -BootFile $batch.Settings.BootFile `
                            -Cache $previewCache `
                            -Phase $previewPhase
                    }
            }

            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "[Server $currentRow/$($batch.Rows.Count)] Classifying exact or missing AD state..."; Stage = 'AD continuation plan'; MachineName = $row.MachineName }
            if (-not $directAdSnapshotLoaded) {
                $adEntry = Get-PreviewCacheSnapshot `
                    -Cache $previewCache `
                    -Key ("AD.Computers|{0}|{1}" -f $batch.Settings.OuMetadata.DomainDn.ToLowerInvariant(), $batch.Settings.AdDnsDomain.ToLowerInvariant()) `
                    -Phase $previewPhase `
                    -Operation 'AD.BatchDirectoryQuery' `
                    -MachineName $row.MachineName `
                    -Endpoint $batch.Settings.AdDnsDomain `
                    -Loader {
                        Find-AdComputersBatchAcrossWritableDcs `
                            -MachineNames $adBatchNames `
                            -OuMetadata $batch.Settings.OuMetadata
                    }
                if (@($adEntry.Value).Count -ne 1) {
                    throw 'The direct AD batch Validation query did not return exactly one complete snapshot.'
                }
                $directAdSnapshot = $adEntry.Value[0]
                $directAdSnapshotLoaded = $true
            }
            $adPlan = Invoke-TimedOperation `
                -Phase $previewPhase `
                -Operation 'AD.ComponentPlan' `
                -MachineName $row.MachineName `
                -Endpoint $batch.Settings.AdDnsDomain `
                -Source 'PreviewCache' `
                -Action {
                    Get-AdActionPlan `
                        -MachineName $row.MachineName `
                        -OuMetadata $batch.Settings.OuMetadata `
                        -DirectAccountSnapshot $directAdSnapshot `
                        -PvsPlan $pvsPlan
                }

            if ($pvsPlan.Action -eq 'ReuseExact') {
                $rebootState = Get-PvsRebootStateForDevice -DeviceId ([guid]$pvsPlan.Guid)
                if ($rebootState.Action -eq 'ReuseExact') {
                    $record.RebootDay = [string]$rebootState.Day
                    $personalityPlan = [pscustomobject]@{
                        Action           = 'ReuseExact'
                        OtherFingerprint = [string]$rebootState.OtherFingerprint
                    }
                }
                else {
                    $record.RebootDay = Get-NextPvsRebootDay -Distribution $rebootDistribution
                    $personalityPlan = [pscustomobject]@{
                        Action           = 'Create'
                        OtherFingerprint = [string]$rebootState.OtherFingerprint
                    }
                }
            }
            else {
                $record.RebootDay = Get-NextPvsRebootDay -Distribution $rebootDistribution
                $personalityPlan = [pscustomobject]@{
                    Action           = 'Create'
                    OtherFingerprint = ''
                }
            }

            $hasWrites = ($pvsPlan.Action -eq 'Create' -or
                $imagePlan.Action -eq 'Create' -or
                $personalityPlan.Action -eq 'Create' -or
                @($targets | Where-Object {
                        $_.Action -eq 'Create' -or $_.Option67Action -eq 'Create'
                    }).Count -gt 0 -or
                $adPlan.Action -eq 'Create')
            $actionSummary = "PVS=$($pvsPlan.Action); vDisk=$($imagePlan.Action); Reboot=$($personalityPlan.Action); DHCP=$(($targets | ForEach-Object { "$($_.Server):Reservation=$($_.Action)/Option67=$($_.Option67Action)" }) -join ', '); AD=$($adPlan.Action)"
            $record.ActionSummary = $actionSummary
            $record.ValidationAdAction = [string]$adPlan.Action
            $record.PowerResult = if ($batch.Settings.PowerOnAfterBuild) { 'Pending' } else { 'NotRequested' }
            $record.Result = if (-not $hasWrites -and -not $batch.Settings.PowerOnAfterBuild) { 'SkippedExisting' } else { 'Ready' }
            $record.Stage = if ($record.Result -eq 'SkippedExisting') { 'Validation exact' } else { 'Validation' }
            $record.ValidationOutcome = if ($record.Result -eq 'SkippedExisting') { 'Exact' } else { 'Passed' }
            $record.BuildAction = if ($record.Result -eq 'SkippedExisting') {
                'None - Validation found the requested stored provisioning configuration exact; no write is required.'
            }
            else {
                'Pending operator confirmation - execute the retained Validation action plan.'
            }
            $rowOutcome = if ($record.Result -eq 'SkippedExisting') { 'SkippedExisting' } else { 'Succeeded' }
            $imagePreviewText = if ($batch.Settings.AssignPvsImage) {
                "$($batch.Settings.ImageDisplay), version $($batch.Settings.ImageVersionDisplay)"
            }
            else {
                'not requested; zero vDisk mappings were verified or planned'
            }
            $record.Details = "$(if ($record.Result -eq 'SkippedExisting') { 'Validation found the requested stored provisioning configuration exact; Build action is none and no write is required.' } else { 'Validation passed; the retained action plan is ready for Build confirmation.' }) OLVM MAC: $($record.MacAddress). Configured / next-boot vDisk: $imagePreviewText. Reboot personality: $($record.RebootDay). FQDN: $fqdn. AD OU: $($batch.Settings.OuMetadata.DisplayPath). Power after build: $(if ($batch.Settings.PowerOnAfterBuild) { 'requested after post-write verification' } else { 'not requested' })."
            $buildActionPlan = New-BuildActionPlan `
                -PvsTargetPlan $pvsPlan `
                -ImagePlan $imagePlan `
                -PersonalityPlan $personalityPlan `
                -DhcpTargets ([object[]]$targets) `
                -AdAccountPlan $adPlan
            $context = New-BuildContext `
                -Settings $batch.Settings `
                -Row $row `
                -Record $record `
                -ValidationId $validationId `
                -ValidatedAtUtc $validatedAtUtc `
                -Plan $buildActionPlan `
                -HasWrites ([bool]$hasWrites) `
                -OlvmIdentity $olvmIdentity `
                -DhcpServers ([string[]]$servers)
            if ($record.Result -eq 'Ready') {
                [void]$contexts.Add($context)
            }
            $duration = [math]::Round(((Get-Date) - $rowStartedAt).TotalSeconds, 2)
            Write-RunLog -Level SUCCESS -Stage $previewKind -MachineName $row.MachineName -Message "Row $($row.Line) result is '$($record.Result)' after $duration second(s). $($record.Details) Raw Validation action plan: $actionSummary"
        }
        catch {
            $record.ValidationOutcome = 'Blocked'
            $record.BuildAction = 'None - Validation is blocked; no Build action is available.'
            $record.Details = $_.Exception.Message
            Write-ExceptionLog -Stage $previewKind -MachineName $row.MachineName -ErrorRecord $_
        }
        finally {
            Write-StageTiming `
                -Timer $rowTimer `
                -Phase $previewPhase `
                -Operation 'Row.Total' `
                -Outcome $rowOutcome `
                -MachineName $row.MachineName `
                -Source 'Mixed'
        }

        [void]$records.Add($record)
        Set-ValidationBuildState -ValidationRecords ([object[]]$records.ToArray())
        Invoke-PresentationPort -Name 'GridRefresh' -Arguments @{ FocusRecord = $record }
        Invoke-PresentationPort -Name 'SetProgressValue' -Arguments @{ Value = $currentRow }
    }

    $validatedRecords = [object[]]$records.ToArray()
    $retainedBuildContexts = [object[]]$contexts.ToArray()
    Set-ValidationBuildState -ValidationRecords $validatedRecords -BuildContexts $retainedBuildContexts
    Invoke-PresentationPort -Name 'GridRefresh'
    $outcomeCounts = Get-ValidationOutcomeCounts -Records $validatedRecords
    $readyCount = $outcomeCounts.Ready
    $skippedCount = $outcomeCounts.SkippedExisting
    $blockedCount = $outcomeCounts.Blocked
    $canProvision = Test-ValidationBatchCanBuild -Records $validatedRecords
    # The button handler restores Create only after Validation tracking ends.
    Invoke-PresentationPort -Name 'SetBuildEnabled' -Arguments @{ Enabled = ($canProvision -and -not $script:IsOperationRunning) }
    $durationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 2)

    if ($canProvision) {
        if ($blockedCount -eq 0) {
            $statusText = "Validation completed: $readyCount ready, $skippedCount server(s) with exact stored provisioning configuration skipped, 0 blocked. Review the component action plans, then select Build."
            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = $statusText; Color = 'Green'; Stage = $previewKind }
            Write-RunLog -Level SUCCESS -Stage $previewKind -Message "$previewKind completed in $durationSeconds second(s): $readyCount ready, $skippedCount skipped existing, 0 blocked."
        }
        else {
            $statusText = "Validation completed: $readyCount ready, $skippedCount with exact stored provisioning configuration, $blockedCount blocked and excluded. Build is available and will process only Ready servers."
            Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = $statusText; Color = 'DarkOrange'; Stage = $previewKind }
            Write-RunLog -Level WARN -Stage $previewKind -Message "$previewKind completed in $durationSeconds second(s): $readyCount ready for Build, $skippedCount skipped existing, $blockedCount blocked and excluded from Build."
        }
    }
    elseif ($readyCount -eq 0 -and $skippedCount -gt 0 -and $blockedCount -eq 0) {
        $statusText = "Validation completed: all $skippedCount server(s) have the requested stored provisioning configuration exact. Build action is none; no changes are required."
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = $statusText; Color = 'Green'; Stage = $previewKind }
        Write-RunLog -Level SUCCESS -Stage $previewKind -Message "$previewKind completed in $durationSeconds second(s): 0 ready, $skippedCount skipped existing, 0 blocked."
    }
    else {
        $statusText = "Validation completed: 0 ready, $skippedCount with exact stored provisioning configuration, $blockedCount blocked. No server is eligible for Build."
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = $statusText; Color = 'Red'; Stage = $previewKind }
        Write-RunLog -Level WARN -Stage $previewKind -Message "$previewKind completed in $durationSeconds second(s): $readyCount ready, $skippedCount skipped existing, $blockedCount blocked."
    }

    Write-RunLog -Level INFO -Stage "$previewKind cache" -Message "Read-only cache summary: Entries=$($previewCache.Entries.Count); Hits=$($previewCache.Hits); Misses=$($previewCache.Misses); FailedLoads=$($previewCache.Failures). The cache will now be discarded."
    $batchOutcome = if ($blockedCount -gt 0 -and $readyCount -gt 0) {
        'Partial'
    }
    elseif ($blockedCount -gt 0) {
        'Blocked'
    }
    else {
        'Complete'
    }

    return $canProvision
    }
    finally {
        Write-StageTiming `
            -Timer $batchTimer `
            -Phase $previewPhase `
            -Operation 'Batch.Total' `
            -Outcome $batchOutcome `
            -Source 'Mixed'
        $validationEndLevel = if ($batchOutcome -eq 'Complete') {
            'SUCCESS'
        }
        elseif ($batchOutcome -in @('Partial','Blocked')) {
            'WARN'
        }
        else {
            'ERROR'
        }
        Write-RecoveryLog -Level $validationEndLevel -Stage $previewKind -Message "END Validation attempt $validationAttempt; ValidationId=$validationId; Outcome=$batchOutcome; DurationMs=$($batchTimer.ElapsedMilliseconds)."
    }
}
