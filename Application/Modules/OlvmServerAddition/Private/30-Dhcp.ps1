#region DHCP discovery, validation, and verification helpers

function Get-DhcpReservationByIpInScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]$ScopeId,

        [Parameter(Mandatory = $true)]
        [string]$IPAddress
    )

    $expectedAddress = (Get-IPv4Address -Value $IPAddress).IPAddressToString
    return @(Get-DhcpServerv4Reservation -ComputerName $Server -ScopeId $ScopeId -ErrorAction Stop |
        Where-Object { $_.IPAddress.IPAddressToString -eq $expectedAddress })
}

function Get-DhcpScopeOption67Values {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]$ScopeId
    )

    return @((Get-DhcpServerv4OptionValue -ComputerName $Server -ScopeId $ScopeId -ErrorAction Stop |
        Where-Object { $_.OptionId -eq 67 } |
        ForEach-Object { @($_.Value) }) |
        ForEach-Object { [string]$_ })
}

function Get-PreviewDhcpTargets {
    <#
      Preview-only scope discovery. Remote scope inventories are cached as
      primitive snapshots, while each row receives new target objects because
      Option67Level is row-specific mutable validation state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]$IPAddress,

        [Parameter(Mandatory = $true)]
        [string[]]$Servers,

        [Parameter(Mandatory = $true)]
        [string]$MachineName,

        [Parameter(Mandatory = $true)]
        [psobject]$Cache,

        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int]$InputServerNumber,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 2147483647)]
        [int]$InputServerCount
    )

    $targets = New-Object 'System.Collections.Generic.List[object]'
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $dhcpServerNumber = 0
    $dhcpServerCount = @($Servers).Count

    foreach ($server in $Servers) {
        $dhcpServerNumber++
        $matchTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $matchOutcome = 'Failed'
        Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "[Server $InputServerNumber/$InputServerCount; DHCP server $dhcpServerNumber/$dhcpServerCount] Finding the DHCP scope on '$server'..."; Stage = 'DHCP scope'; MachineName = $MachineName }
        Write-RunLog -Level INFO -Stage 'DHCP scope' -MachineName $MachineName -Message "Reading the Validation scope snapshot for '$server' and IP $($IPAddress.IPAddressToString)."
        try {
            $normalizedServer = ([string]$server).Trim().ToLowerInvariant()
            $scopeEntry = Get-PreviewCacheSnapshot `
                -Cache $Cache `
                -Key "DHCP.Scopes|$normalizedServer" `
                -Phase $Phase `
                -Operation 'DHCP.ScopeInventory' `
                -MachineName $MachineName `
                -Endpoint $server `
                -Loader {
                    @(Get-DhcpServerv4Scope -ComputerName $server -ErrorAction Stop |
                        ForEach-Object {
                            [pscustomobject]@{
                                ScopeId   = (Get-IPv4Address -Value ([string]$_.ScopeId)).IPAddressToString
                                StartRange = (Get-IPv4Address -Value ([string]$_.StartRange)).IPAddressToString
                                EndRange   = (Get-IPv4Address -Value ([string]$_.EndRange)).IPAddressToString
                                State      = [string]$_.State
                            }
                        })
                }

            $matchingScopes = @($scopeEntry.Value | Where-Object {
                    Test-IPv4InRange `
                        -Address $IPAddress `
                        -StartRange (Get-IPv4Address -Value ([string]$_.StartRange)) `
                        -EndRange (Get-IPv4Address -Value ([string]$_.EndRange))
                })
            if ($matchingScopes.Count -ne 1) {
                throw "Expected exactly one matching DHCP scope, but found $($matchingScopes.Count)."
            }
            if ([string]$matchingScopes[0].State -ine 'Active') {
                throw "Matching DHCP scope '$($matchingScopes[0].ScopeId)' is '$($matchingScopes[0].State)', not Active."
            }

            $target = [pscustomobject]@{
                Server        = [string]$server
                ScopeId       = Get-IPv4Address -Value ([string]$matchingScopes[0].ScopeId)
                Option67Level = $null
                Option67Action = $null
                Action        = $null
            }
            [void]$targets.Add($target)
            $matchOutcome = 'Succeeded'
            Write-RunLog -Level SUCCESS -Stage 'DHCP scope' -MachineName $MachineName -Message "Matched cached scope '$($target.ScopeId)' on '$server'."
        }
        catch {
            $failure = "${server}: $($_.Exception.Message)"
            [void]$failures.Add($failure)
            Write-RunLog -Level ERROR -Stage 'DHCP scope' -MachineName $MachineName -Message $failure
        }
        finally {
            Write-StageTiming `
                -Timer $matchTimer `
                -Phase $Phase `
                -Operation 'DHCP.ScopeMatch' `
                -Outcome $matchOutcome `
                -MachineName $MachineName `
                -Endpoint $server `
                -Source 'PreviewCache'
        }
    }

    if ($failures.Count -gt 0) {
        throw "DHCP scope validation did not pass on every selected PVS/DHCP server. $([string]::Join(' | ', $failures.ToArray()))"
    }

    return [object[]]$targets.ToArray()
}

function Assert-PreviewDhcpTargetAvailable {
    <#
      Applies the exact-state conflict and option-67 rules using only snapshots
      scoped to this Validation pass. Build consumes the resulting retained
      action plan; this helper is never called by a write path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target,

        [Parameter(Mandatory = $true)]
        [psobject]$Record,

        [Parameter(Mandatory = $true)]
        [string]$BootFile,

        [Parameter(Mandatory = $true)]
        [psobject]$Cache,

        [Parameter(Mandatory = $true)]
        [string]$Phase
    )

    $server = [string]$Target.Server
    $scopeId = (Get-IPv4Address -Value ([string]$Target.ScopeId)).IPAddressToString
    $normalizedServer = $server.Trim().ToLowerInvariant()
    $scopeKey = "$normalizedServer|$scopeId"
    Write-RunLog -Level INFO -Stage 'DHCP preflight' -MachineName $Record.MachineName -Message "Checking cached reservations, leases, and option 67 on '$server' scope '$scopeId'."

    $reservationEntry = Get-PreviewCacheSnapshot `
        -Cache $Cache `
        -Key "DHCP.Reservations|$scopeKey" `
        -Phase $Phase `
        -Operation 'DHCP.ReservationInventory' `
        -MachineName $Record.MachineName `
        -Endpoint $server `
        -Loader {
            @(Get-DhcpServerv4Reservation `
                -ComputerName $server `
                -ScopeId (Get-IPv4Address -Value $scopeId) `
                -ErrorAction Stop |
                ForEach-Object {
                    [pscustomobject]@{
                        IPAddress = (Get-IPv4Address -Value ([string]$_.IPAddress)).IPAddressToString
                        ClientId  = [string]$_.ClientId
                        Name      = [string]$_.Name
                        Type      = [string]$_.Type
                    }
                })
        }
    $reservations = @($reservationEntry.Value)
    $ipMatches = @($reservations | Where-Object { $_.IPAddress -eq $Record.IPAddress })
    $macMatches = @($reservations | Where-Object {
            Test-MacAddressEqual -First $_.ClientId -Second $Record.MacAddress
        })
    if ($ipMatches.Count -eq 0 -and $macMatches.Count -eq 0) {
        $Target.Action = 'Create'
    }
    elseif ($ipMatches.Count -eq 1 -and $macMatches.Count -eq 1 -and
        $ipMatches[0].IPAddress -eq $macMatches[0].IPAddress -and
        (Test-MacAddressEqual -First $ipMatches[0].ClientId -Second $Record.MacAddress)) {
        $existing = $ipMatches[0]
        if ([string]$existing.Name -cne [string]$Record.DhcpName -or
            [string]$existing.Type -ine 'Both') {
            throw "DHCP reservation $($Record.IPAddress) on $server exists with the expected MAC but different required metadata. Expected name '$($Record.DhcpName)', type 'Both'; found name '$($existing.Name)', type '$($existing.Type)'. The existing reservation, including any Description, will not be overwritten."
        }
        $Target.Action = 'ReuseExact'
    }
    else {
        throw "DHCP reservation state on $server is conflicting or ambiguous for IP '$($Record.IPAddress)' and MAC '$($Record.MacAddress)'. IP matches=$($ipMatches.Count); MAC matches=$($macMatches.Count). Existing values will not be reconciled."
    }

    $leaseEntry = Get-PreviewCacheSnapshot `
        -Cache $Cache `
        -Key "DHCP.Leases|$scopeKey" `
        -Phase $Phase `
        -Operation 'DHCP.LeaseInventory' `
        -MachineName $Record.MachineName `
        -Endpoint $server `
        -Loader {
            @(Get-DhcpServerv4Lease `
                -ComputerName $server `
                -ScopeId (Get-IPv4Address -Value $scopeId) `
                -ErrorAction Stop |
                ForEach-Object {
                    [pscustomobject]@{
                        IPAddress = (Get-IPv4Address -Value ([string]$_.IPAddress)).IPAddressToString
                    }
                })
        }
    if ($Target.Action -eq 'Create' -and
        @($leaseEntry.Value | Where-Object { $_.IPAddress -eq $Record.IPAddress }).Count -gt 0) {
        throw "IP $($Record.IPAddress) already has a DHCP lease on $server in scope $scopeId. Release or resolve that lease before provisioning."
    }

    $optionEntry = Get-PreviewCacheSnapshot `
        -Cache $Cache `
        -Key "DHCP.ScopeOption67|$scopeKey" `
        -Phase $Phase `
        -Operation 'DHCP.ScopeOption67' `
        -MachineName $Record.MachineName `
        -Endpoint $server `
        -Loader {
            @(Get-DhcpScopeOption67Values `
                -Server $server `
                -ScopeId (Get-IPv4Address -Value $scopeId))
        }
    $scopeOption67 = @($optionEntry.Value | ForEach-Object { [string]$_ })
    if ($scopeOption67.Count -gt 0) {
        if ($scopeOption67.Count -ne 1 -or [string]$scopeOption67[0] -cne $BootFile) {
            throw "Scope option 67 on $server [$scopeId] is '$($scopeOption67 -join ', ')', not '$BootFile'."
        }
        $Target.Option67Level = 'Scope'
        $Target.Option67Action = 'UseScope'
        if ($Target.Action -eq 'ReuseExact') {
            $reservationOptionEntry = Get-PreviewCacheSnapshot `
                -Cache $Cache `
                -Key "DHCP.ReservationOption67|$normalizedServer|$($Record.IPAddress)" `
                -Phase $Phase `
                -Operation 'DHCP.ReservationOption67' `
                -MachineName $Record.MachineName `
                -Endpoint $server `
                -Loader {
                    @(Get-DhcpServerv4OptionValue `
                        -ComputerName $server `
                        -ReservedIP $Record.IPAddress `
                        -ErrorAction Stop |
                        Where-Object { $_.OptionId -eq 67 } |
                        ForEach-Object { @($_.Value | ForEach-Object { [string]$_ }) })
                }
            [string[]]$reservationValues = @($reservationOptionEntry.Value | ForEach-Object { [string]$_ })
            if ($reservationValues.Count -gt 0) {
                if ($reservationValues.Count -ne 1 -or [string]$reservationValues[0] -cne $BootFile) {
                    throw "Reservation option 67 on $server overrides the correct scope value with '$($reservationValues -join ', ')', not '$BootFile'. It will not be overwritten."
                }
                $Target.Option67Level = 'Reservation'
                $Target.Option67Action = 'ReuseExact'
            }
        }
    }
    else {
        if ($Target.Action -eq 'ReuseExact') {
            $reservationOptionEntry = Get-PreviewCacheSnapshot `
                -Cache $Cache `
                -Key "DHCP.ReservationOption67|$normalizedServer|$($Record.IPAddress)" `
                -Phase $Phase `
                -Operation 'DHCP.ReservationOption67' `
                -MachineName $Record.MachineName `
                -Endpoint $server `
                -Loader {
                    @(Get-DhcpServerv4OptionValue `
                        -ComputerName $server `
                        -ReservedIP $Record.IPAddress `
                        -ErrorAction Stop |
                        Where-Object { $_.OptionId -eq 67 } |
                        ForEach-Object { @($_.Value | ForEach-Object { [string]$_ }) })
                }
            [string[]]$existingOptionValues = @($reservationOptionEntry.Value | ForEach-Object { [string]$_ })
            if ($existingOptionValues.Count -gt 1 -or
                ($existingOptionValues.Count -eq 1 -and [string]$existingOptionValues[0] -cne $BootFile)) {
                throw "Existing DHCP reservation option 67 on $server is '$($existingOptionValues -join ', ')', not '$BootFile'. It will not be overwritten."
            }
            $Target.Option67Action = if ($existingOptionValues.Count -eq 1) { 'ReuseExact' } else { 'Create' }
        }
        else {
            $Target.Option67Action = 'Create'
        }
        if ($Target.Option67Action -eq 'Create') {
            $definitionEntry = Get-PreviewCacheSnapshot `
                -Cache $Cache `
                -Key "DHCP.Option67Definition|$normalizedServer" `
                -Phase $Phase `
                -Operation 'DHCP.Option67Definition' `
                -MachineName $Record.MachineName `
                -Endpoint $server `
                -Loader {
                    @(Get-DhcpServerv4OptionDefinition `
                        -ComputerName $server `
                        -OptionId 67 `
                        -ErrorAction Stop |
                        ForEach-Object { [int]$_.OptionId })
                }
            if (@($definitionEntry.Value).Count -eq 0) {
                throw "DHCP option 67 is not defined on $server."
            }
        }
        $Target.Option67Level = 'Reservation'
    }

    Write-RunLog -Level SUCCESS -Stage 'DHCP preflight' -MachineName $Record.MachineName -Message "DHCP target '$server' Validation actions are reservation='$($Target.Action)' and option67='$($Target.Option67Action)' at $($Target.Option67Level.ToLowerInvariant()) level."
    return $Target
}

function Assert-DhcpReservationIdentityCreated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target,

        [Parameter(Mandatory = $true)]
        [psobject]$Record
    )

    $matches = @(Get-DhcpReservationByIpInScope `
        -Server $Target.Server `
        -ScopeId $Target.ScopeId `
        -IPAddress $Record.IPAddress)
    if ($matches.Count -ne 1) {
        throw "DHCP reservation verification on $($Target.Server) expected one IP match and found $($matches.Count)."
    }

    $reservation = $matches[0]
    $actualMac = Get-NormalizedMacAddress -Value ([string]$reservation.ClientId)
    if ($actualMac -ine $Record.MacAddress) {
        throw "DHCP reservation verification on $($Target.Server) returned MAC '$actualMac', not '$($Record.MacAddress)'."
    }
    if ([string]$reservation.Name -cne [string]$Record.DhcpName) {
        throw "DHCP reservation verification on $($Target.Server) returned name '$($reservation.Name)', not '$($Record.DhcpName)'."
    }
    $typeProperty = $reservation.PSObject.Properties['Type']
    if ($null -ne $typeProperty -and [string]$typeProperty.Value -ine 'Both') {
        throw "DHCP reservation verification on $($Target.Server) returned type '$($typeProperty.Value)', not 'Both'."
    }

    return $reservation
}

function Assert-DhcpReservationCreated {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target,

        [Parameter(Mandatory = $true)]
        [psobject]$Record,

        [Parameter(Mandatory = $true)]
        [string]$BootFile
    )

    $null = Assert-DhcpReservationIdentityCreated -Target $Target -Record $Record

    # Option 67 is mutable external state. Re-read the scope on every final
    # verification before trusting the level chosen during an earlier check.
    $scopeValues = @(Get-DhcpScopeOption67Values `
        -Server $Target.Server `
        -ScopeId $Target.ScopeId)
    if ($scopeValues.Count -gt 0 -and
        ($scopeValues.Count -ne 1 -or [string]$scopeValues[0] -cne $BootFile)) {
        throw "DHCP scope option 67 changed on $($Target.Server) [$($Target.ScopeId)]. Expected either no scope value or exactly '$BootFile'; found '$($scopeValues -join ', ')'."
    }

    if ($Target.Option67Level -eq 'Scope') {
        if ($scopeValues.Count -ne 1 -or [string]$scopeValues[0] -cne $BootFile) {
            throw "DHCP scope option 67 verification failed on $($Target.Server) [$($Target.ScopeId)]."
        }
        $reservationOptions = @(Get-DhcpServerv4OptionValue `
            -ComputerName $Target.Server `
            -ReservedIP $Record.IPAddress `
            -ErrorAction Stop |
            Where-Object { $_.OptionId -eq 67 })
        if ($reservationOptions.Count -gt 0) {
            throw "DHCP reservation-level option 67 unexpectedly exists on $($Target.Server) and would override the validated scope value."
        }
    }
    elseif ($Target.Option67Level -eq 'Reservation') {
        $option = @(Get-DhcpServerv4OptionValue `
            -ComputerName $Target.Server `
            -ReservedIP $Record.IPAddress `
            -OptionId 67 `
            -ErrorAction Stop)
        # Keep the value collection strongly typed. Windows PowerShell unwraps
        # a one-item array emitted by an if expression; without this type the
        # later [0] lookup would read the first character of the boot filename.
        [string[]]$optionValues = if ($option.Count -eq 1) {
            @($option[0].Value | ForEach-Object { [string]$_ })
        }
        else { @() }
        if ($option.Count -ne 1 -or
            $optionValues.Count -ne 1 -or
            [string]$optionValues[0] -cne $BootFile) {
            throw "DHCP reservation option 67 verification failed on $($Target.Server)."
        }
    }
    else {
        throw "DHCP option 67 verification has an invalid level '$($Target.Option67Level)' on $($Target.Server)."
    }

    Write-RunLog -Level SUCCESS -Stage 'DHCP verify' -MachineName $Record.MachineName -Message "Verified IP, MAC, name, type, and option 67 on '$($Target.Server)' scope '$($Target.ScopeId)'. DHCP Description is intentionally outside the validation contract."
}


function Get-DhcpServerNames {
    [CmdletBinding()]
    param()

    $farmServers = @(Get-PvsServer -Fields Name -ErrorAction Stop |
        ForEach-Object { [string]$_.Name } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)
    if ($farmServers.Count -eq 0) {
        throw 'No PVS servers were found for DHCP discovery.'
    }

    if ($null -ne $script:DhcpServer -and $script:DhcpServer.Count -gt 0) {
        $requestedServers = @($script:DhcpServer |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique)
        $missingServers = @($farmServers | Where-Object { $requestedServers -inotcontains $_ })
        $unexpectedServers = @($requestedServers | Where-Object { $farmServers -inotcontains $_ })
        if ($missingServers.Count -gt 0 -or $unexpectedServers.Count -gt 0) {
            throw "DhcpServer override must exactly match every PVS master in the connected farm. Missing: '$($missingServers -join ', ')'. Not in farm: '$($unexpectedServers -join ', ')'."
        }
    }

    Write-RunLog -Level SUCCESS -Stage 'PVS farm' -Message "DHCP will be validated on every PVS master in the connected farm ($($farmServers.Count)): $($farmServers -join ', ')."
    return [string[]]$farmServers
}
#endregion DHCP discovery, validation, and verification helpers
