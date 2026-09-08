function Get-PvsDevicePersonalityEnvelope {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][guid]$DeviceId)

    $envelopes = @(Get-PvsDevicePersonality -DeviceId $DeviceId -ErrorAction Stop)
    if ($envelopes.Count -ne 1) {
        throw "PVS returned $($envelopes.Count) personality containers for device '$DeviceId'; expected one."
    }
    return $envelopes[0]
}

function Get-PvsPersonalityEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Envelope)

    $property = $Envelope.PSObject.Properties['DevicePersonality']
    if ($null -eq $property -or $null -eq $property.Value) { return [object[]]@() }
    return [object[]]@($property.Value)
}

function Get-PvsRebootDistribution {
    <#
      Existing valid Reboot values are authoritative for balancing. A missing
      Reboot entry is excluded from the counts, while duplicate or unsupported
      values remain ambiguous and block automatic planning. Personalities are
      fetched by immutable DeviceId in bounded batches and mapped by the
      returned read-only DeviceId. Output ordering is never trusted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][psobject]$Collection)

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $counts = @{}
    foreach ($day in $script:RebootDayOrder) { $counts[$day] = 0 }
    $devices = @(Get-PvsDevice -CollectionId ([guid]$Collection.Guid) -ErrorAction Stop)
    $deviceRecords = New-Object 'System.Collections.Generic.List[object]'
    $requestedById = @{}
    foreach ($device in $devices) {
        $deviceName = [string](Get-FirstPropertyValue -InputObject $device -Names @('Name','DeviceName'))
        [guid]$deviceId = [guid]::Empty
        $rawDeviceId = Get-FirstPropertyValue -InputObject $device -Names @('Guid','DeviceId')
        if (-not [guid]::TryParse([string]$rawDeviceId, [ref]$deviceId) -or
            $deviceId -eq [guid]::Empty) {
            throw "Existing PVS target '$deviceName' does not expose a usable immutable DeviceId."
        }
        $key = $deviceId.ToString('D').ToLowerInvariant()
        if ($requestedById.ContainsKey($key)) {
            throw "PVS returned duplicate DeviceId '$deviceId' while reading collection '$($Collection.Display)'."
        }
        $record = [pscustomobject]@{
            Id   = $deviceId
            Key  = $key
            Name = $deviceName
        }
        $requestedById[$key] = $record
        [void]$deviceRecords.Add($record)
    }

    [guid[]]$deviceIds = @($deviceRecords.ToArray() | ForEach-Object { [guid]$_.Id })
    $personalityById = @{}
    $chunkSize = $script:PvsPersonalityBulkChunkSize
    for ($offset = 0; $offset -lt $deviceIds.Count; $offset += $chunkSize) {
        $lastIndex = [math]::Min($deviceIds.Count - 1, $offset + $chunkSize - 1)
        [guid[]]$chunk = @($deviceIds[$offset..$lastIndex])
        $envelopes = @(Get-PvsDevicePersonality -DeviceId $chunk -ErrorAction Stop)
        foreach ($envelope in $envelopes) {
            [guid]$returnedId = [guid]::Empty
            $rawReturnedId = Get-FirstPropertyValue -InputObject $envelope -Names @('DeviceId')
            if (-not [guid]::TryParse([string]$rawReturnedId, [ref]$returnedId) -or
                $returnedId -eq [guid]::Empty) {
                throw 'PVS returned a personality container without its documented immutable DeviceId.'
            }
            $returnedKey = $returnedId.ToString('D').ToLowerInvariant()
            if (-not $requestedById.ContainsKey($returnedKey)) {
                throw "PVS returned an unrequested personality container for DeviceId '$returnedId'."
            }
            if ($personalityById.ContainsKey($returnedKey)) {
                throw "PVS returned duplicate personality containers for DeviceId '$returnedId'."
            }
            $personalityById[$returnedKey] = $envelope
        }
    }

    $missingKeys = @($requestedById.Keys | Where-Object {
            -not $personalityById.ContainsKey($_)
        })
    if ($missingKeys.Count -gt 0 -or $personalityById.Count -ne $requestedById.Count) {
        $missingNames = @($missingKeys | ForEach-Object { $requestedById[$_].Name })
        throw "PVS returned an incomplete bulk personality snapshot for collection '$($Collection.Display)'. Missing target(s): $($missingNames -join ', ')."
    }

    # Fail closed if collection membership changed while the personality
    # snapshot was being assembled. The caller can run Preview again against a
    # stable collection; no allocation is guessed from a torn snapshot.
    $freshDevices = @(Get-PvsDevice -CollectionId ([guid]$Collection.Guid) -ErrorAction Stop)
    $freshById = @{}
    foreach ($freshDevice in $freshDevices) {
        [guid]$freshId = [guid]::Empty
        $rawFreshId = Get-FirstPropertyValue -InputObject $freshDevice -Names @('Guid','DeviceId')
        if (-not [guid]::TryParse([string]$rawFreshId, [ref]$freshId) -or
            $freshId -eq [guid]::Empty) {
            throw "PVS returned a target without a usable DeviceId while confirming collection '$($Collection.Display)' membership."
        }
        $freshKey = $freshId.ToString('D').ToLowerInvariant()
        if ($freshById.ContainsKey($freshKey)) {
            throw "PVS returned duplicate DeviceId '$freshId' while confirming collection '$($Collection.Display)' membership."
        }
        $freshById[$freshKey] = $true
    }
    $requestedMembership = @($requestedById.Keys | Sort-Object) -join '|'
    $freshMembership = @($freshById.Keys | Sort-Object) -join '|'
    if ($requestedMembership -cne $freshMembership) {
        throw "PVS collection '$($Collection.Display)' membership changed while calculating the Reboot distribution. Run Validation again."
    }

    foreach ($deviceRecord in $deviceRecords.ToArray()) {
        $deviceName = [string]$deviceRecord.Name
        $envelope = $personalityById[[string]$deviceRecord.Key]
        $rebootEntries = @(Get-PvsPersonalityEntries -Envelope $envelope | Where-Object {
                [string]$_.Name -ieq 'Reboot'
            })
        if ($rebootEntries.Count -eq 0) {
            Write-RunLog -Level INFO -Stage 'PVS personality plan' -MachineName $deviceName -Message "Existing target has no Reboot personality. It is excluded from the balancing counts; a submitted exact partial target will receive a newly planned value."
            continue
        }
        if ($rebootEntries.Count -gt 1) {
            throw "Existing PVS target '$deviceName' has $($rebootEntries.Count) Reboot personality entries. Multiple values are ambiguous and block automatic planning."
        }
        $day = ([string]$rebootEntries[0].Value).Trim()
        $canonical = @($script:RebootDayOrder | Where-Object { $_ -ceq $day })
        if ($canonical.Count -ne 1) {
            throw "Existing PVS target '$deviceName' has unsupported Reboot personality '$day'. Allowed values are: $($script:RebootDayOrder -join ', ')."
        }
        $counts[$day]++
    }
    $timer.Stop()
    Write-RunLog -Level INFO -Stage 'PVS personality plan' -Message "Read and immutably mapped Reboot personalities for $($deviceRecords.Count) existing target(s) in collection '$($Collection.Display)' using $([math]::Ceiling($deviceIds.Count / [double]$chunkSize)) bounded bulk request(s). QueryMs=$($timer.ElapsedMilliseconds)."
    return $counts
}

function Get-PvsRebootStateForDevice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][guid]$DeviceId)

    $envelope = Get-PvsDevicePersonalityEnvelope -DeviceId $DeviceId
    $entries = @(Get-PvsPersonalityEntries -Envelope $envelope)
    $rebootEntries = @($entries | Where-Object { [string]$_.Name -ieq 'Reboot' })
    if ($rebootEntries.Count -eq 0) {
        return [pscustomobject]@{
            Action           = 'Create'
            Day              = ''
            OtherFingerprint = Get-PvsPersonalityFingerprint -Entries $entries
        }
    }
    if ($rebootEntries.Count -gt 1) {
        throw "PVS target '$DeviceId' has $($rebootEntries.Count) Reboot personality entries. Multiple values are ambiguous and will not be changed."
    }
    $day = ([string]$rebootEntries[0].Value).Trim()
    if (@($script:RebootDayOrder | Where-Object { $_ -ceq $day }).Count -ne 1) {
        throw "PVS target '$DeviceId' has unsupported Reboot personality '$day'. Allowed values are: $($script:RebootDayOrder -join ', ')."
    }
    return [pscustomobject]@{
        Action           = 'ReuseExact'
        Day              = $day
        OtherFingerprint = Get-PvsPersonalityFingerprint -Entries $entries
    }
}

function Get-NextPvsRebootDay {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Distribution)

    $minimum = ($script:RebootDayOrder | ForEach-Object { [int]$Distribution[$_] } | Measure-Object -Minimum).Minimum
    foreach ($day in $script:RebootDayOrder) {
        if ([int]$Distribution[$day] -eq [int]$minimum) {
            $Distribution[$day] = [int]$Distribution[$day] + 1
            return $day
        }
    }
    throw 'A reboot day could not be allocated.'
}

function Get-PvsPersonalityFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries
    )

    # A newly-created target legitimately has no personality entries. Its
    # empty fingerprint records that there is no non-Reboot state to preserve.
    return (@($Entries | Where-Object { [string]$_.Name -ine 'Reboot' } |
            ForEach-Object { '{0}={1}' -f ([string]$_.Name),([string]$_.Value) } |
            Sort-Object) -join '|')
}

function Assert-PvsRebootPersonality {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][guid]$DeviceId,
        [Parameter(Mandatory = $true)][string]$ExpectedDay,
        [AllowEmptyString()][string]$ExpectedOtherFingerprint = ''
    )

    $envelope = Get-PvsDevicePersonalityEnvelope -DeviceId $DeviceId
    $entries = @(Get-PvsPersonalityEntries -Envelope $envelope)
    $rebootEntries = @($entries | Where-Object { [string]$_.Name -ieq 'Reboot' })
    if ($rebootEntries.Count -ne 1 -or [string]$rebootEntries[0].Value -cne $ExpectedDay) {
        throw "PVS did not persist exactly one Reboot personality with value '$ExpectedDay' on target '$DeviceId'."
    }
    if ((Get-PvsPersonalityFingerprint -Entries $entries) -cne $ExpectedOtherFingerprint) {
        throw "A non-Reboot personality changed while assigning Reboot='$ExpectedDay' to target '$DeviceId'."
    }
    return $envelope
}

function Set-PvsRebootPersonalityForNewTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Context,
        [Parameter(Mandatory = $true)][psobject]$State
    )

    $record = $Context.Record
    $expectedDay = [string]$Context.RebootDay
    $envelope = Get-PvsDevicePersonalityEnvelope -DeviceId ([guid]$State.PvsGuid)
    $entries = @(Get-PvsPersonalityEntries -Envelope $envelope)
    $rebootEntries = @($entries | Where-Object { [string]$_.Name -ieq 'Reboot' })
    if ($rebootEntries.Count -gt 0) {
        throw "The retained PVS target now has a Reboot personality although Validation planned it as missing. It was not modified."
    }
    $otherFingerprint = Get-PvsPersonalityFingerprint -Entries $entries
    $insertMethod = $envelope.PSObject.Methods['Insert']
    if ($null -eq $insertMethod) {
        throw 'The PVS personality object does not support safe insertion of a new value.'
    }

    $setCommand = Get-Command -Name Set-PvsDevicePersonality -ErrorAction Stop | Select-Object -First 1
    $arguments = @{ ErrorAction = 'Stop' }
    if ($setCommand.Parameters.ContainsKey('DevicePersonality')) {
        $arguments['DevicePersonality'] = $envelope
    }
    else {
        throw 'Set-PvsDevicePersonality does not expose the DevicePersonality parameter required for an immutable device-specific update.'
    }
    if ($setCommand.Parameters.ContainsKey('Confirm')) { $arguments['Confirm'] = $false }
    if ($setCommand.Parameters.ContainsKey('PassThru')) { $arguments['PassThru'] = $true }
    Write-RunLog -Level INFO -Stage 'PVS personality' -MachineName $record.MachineName -Message "Assigning missing Reboot='$expectedDay' to target GUID '$($State.PvsGuid)'; current non-Reboot personality values will be preserved."
    # Last fail-closed audit gate immediately before the personality mutation.
    Assert-AuditTrailAvailable
    Assert-FarmBuildLockOwned
    $State.PersonalityStatus = 'Ambiguous'
    $envelope.Insert(0, 'Reboot', $expectedDay)
    & $setCommand @arguments | Out-Null
    $null = Assert-PvsRebootPersonality `
        -DeviceId ([guid]$State.PvsGuid) `
        -ExpectedDay $expectedDay `
        -ExpectedOtherFingerprint $otherFingerprint
    $State.PersonalityStatus = 'ConfirmedSet'
    $State.PersonalityOtherFingerprint = $otherFingerprint
    $Context.PersonalityOtherFingerprint = $otherFingerprint
    Write-RunLog -Level SUCCESS -Stage 'PVS personality' -MachineName $record.MachineName -Message "Assigned and verified Reboot='$expectedDay' on PVS target GUID '$($State.PvsGuid)'; all other personality values were preserved."
}
