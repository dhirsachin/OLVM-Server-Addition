#region Active Directory helpers

function Get-RdnParts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Rdn
    )

    $separator = $Rdn.IndexOf('=')
    if ($separator -lt 1 -or $separator -eq ($Rdn.Length - 1)) {
        throw "Invalid relative distinguished name: '$Rdn'."
    }

    return [pscustomobject]@{
        Attribute = $Rdn.Substring(0, $separator).Trim()
        Value     = Trim-LdapComponentWhitespace -Value $Rdn.Substring($separator + 1)
    }
}

function ConvertFrom-LdapRdnValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $builder = New-Object System.Text.StringBuilder
    $index = 0
    while ($index -lt $Value.Length) {
        if ($Value[$index] -ne '\') {
            [void]$builder.Append($Value[$index])
            $index++
            continue
        }

        if ($index -eq ($Value.Length - 1)) {
            throw "Invalid LDAP escape sequence in RDN value '$Value'."
        }

        $hasHexEscape = ($index + 2 -lt $Value.Length) -and
            ([string]$Value[$index + 1] -match '^[0-9A-Fa-f]$') -and
            ([string]$Value[$index + 2] -match '^[0-9A-Fa-f]$')
        if ($hasHexEscape) {
            $bytes = New-Object 'System.Collections.Generic.List[byte]'
            while (($index + 2 -lt $Value.Length) -and
                ($Value[$index] -eq '\') -and
                ([string]$Value[$index + 1] -match '^[0-9A-Fa-f]$') -and
                ([string]$Value[$index + 2] -match '^[0-9A-Fa-f]$')) {
                [void]$bytes.Add([Convert]::ToByte($Value.Substring($index + 1, 2), 16))
                $index += 3
            }
            [void]$builder.Append([Text.Encoding]::UTF8.GetString($bytes.ToArray()))
            continue
        }

        [void]$builder.Append($Value[$index + 1])
        $index += 2
    }

    return $builder.ToString()
}

function ConvertTo-PvsOuComponent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $specialCharacters = @('"', '#', '+', ',', ';', '<', '>', '/', '=', '\')
    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        if ($specialCharacters -contains [string]$character) {
            [void]$builder.Append('\')
        }
        [void]$builder.Append($character)
    }
    return $builder.ToString()
}

function ConvertFrom-OuDistinguishedName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName
    )

    $components = @(Split-LdapDistinguishedName -DistinguishedName $DistinguishedName)
    $rdns = @($components | ForEach-Object { Get-RdnParts -Rdn $_ })
    $firstDomainComponent = -1
    for ($index = 0; $index -lt $rdns.Count; $index++) {
        if ($rdns[$index].Attribute -ieq 'DC') {
            $firstDomainComponent = $index
            break
        }
    }

    if ($firstDomainComponent -lt 1) {
        throw "The OU must be a full distinguished name containing OU= and DC= components. Received '$DistinguishedName'."
    }

    $ouRdns = @($rdns[0..($firstDomainComponent - 1)])
    $domainRdns = @($rdns[$firstDomainComponent..($rdns.Count - 1)])
    foreach ($rdn in $ouRdns) {
        if ($rdn.Attribute -ine 'OU') {
            throw "Only an organizational unit is supported. Component '$($rdn.Attribute)=$($rdn.Value)' is not an OU."
        }
    }
    foreach ($rdn in $domainRdns) {
        if ($rdn.Attribute -ine 'DC') {
            throw "Invalid domain portion in OU distinguished name: '$DistinguishedName'."
        }
    }

    $ouNames = @($ouRdns | ForEach-Object { ConvertFrom-LdapRdnValue -Value $_.Value })
    [array]::Reverse($ouNames)
    $pvsComponents = @($ouNames | ForEach-Object { ConvertTo-PvsOuComponent -Value $_ })
    $pvsOuPath = $pvsComponents -join '/'
    if ($pvsOuPath.Length -gt 255) {
        throw 'The converted PVS organizational-unit path exceeds 255 characters.'
    }

    return [pscustomobject]@{
        DistinguishedName = ($components -join ',')
        DomainDn          = (@($components[$firstDomainComponent..($components.Count - 1)]) -join ',')
        DomainDnsName     = (@($domainRdns | ForEach-Object {
                ConvertFrom-LdapRdnValue -Value $_.Value
            }) -join '.')
        PvsOuPath         = $pvsOuPath
        FriendlyOuPath    = ($ouNames -join '/')
    }
}

function Get-NormalizedAdServerName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server
    )

    $serverName = $Server.Trim()
    $labels = @($serverName -split '\.')
    if ($serverName.Length -gt 253 -or
        $serverName -notmatch '^[A-Za-z0-9_.-]+$' -or
        $labels.Count -lt 1) {
        throw "The AD server value '$Server' must be a hostname, FQDN, or IPv4 address without a path or port."
    }
    foreach ($label in $labels) {
        if ([string]::IsNullOrWhiteSpace($label) -or
            $label.Length -gt 63 -or
            $label.StartsWith('-') -or
            $label.EndsWith('-')) {
            throw "The AD server value '$Server' contains an empty or malformed label."
        }
    }
    return $serverName
}

function New-SecureDirectoryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $entry = New-Object System.DirectoryServices.DirectoryEntry($Path)
    $entry.AuthenticationType = [System.DirectoryServices.AuthenticationTypes]::Secure -bor
        [System.DirectoryServices.AuthenticationTypes]::Signing -bor
        [System.DirectoryServices.AuthenticationTypes]::Sealing
    return $entry
}

function Get-LdapPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName,

        [string]$Server
    )

    if ([string]::IsNullOrWhiteSpace($Server)) {
        return "LDAP://$DistinguishedName"
    }
    return "LDAP://$(Get-NormalizedAdServerName -Server $Server)/$DistinguishedName"
}

function Resolve-AdOrganizationalUnit {
    <# Validates that the DN exists and returns both PVS and operator paths. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName,

        [string]$Server
    )

    $metadata = ConvertFrom-OuDistinguishedName -DistinguishedName $DistinguishedName
    $entry = New-SecureDirectoryEntry -Path (Get-LdapPath -DistinguishedName $metadata.DistinguishedName -Server $Server)
    try {
        $null = $entry.NativeObject
        if ([string]$entry.SchemaClassName -ine 'organizationalUnit') {
            throw "'$DistinguishedName' is not an organizational unit."
        }

        $resolvedDn = [string]$entry.Properties['distinguishedName'].Value
        if ([string]::IsNullOrWhiteSpace($resolvedDn)) {
            throw "Active Directory did not return a distinguished name for '$DistinguishedName'."
        }
        $resolvedMetadata = ConvertFrom-OuDistinguishedName -DistinguishedName $resolvedDn
        $canonicalName = [string]$entry.Properties['canonicalName'].Value
        $displayPath = if ([string]::IsNullOrWhiteSpace($canonicalName)) {
            "$($resolvedMetadata.DomainDnsName)/$($resolvedMetadata.FriendlyOuPath)"
        }
        else {
            $canonicalName
        }

        return [pscustomobject]@{
            DistinguishedName = $resolvedMetadata.DistinguishedName
            DomainDn          = $resolvedMetadata.DomainDn
            DomainDnsName     = $resolvedMetadata.DomainDnsName
            PvsOuPath         = $resolvedMetadata.PvsOuPath
            DisplayPath       = $displayPath
        }
    }
    finally {
        $entry.Dispose()
    }
}

function ConvertTo-LdapFilterValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $builder = New-Object System.Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        switch ([int][char]$character) {
            0  { [void]$builder.Append('\00') }
            40 { [void]$builder.Append('\28') }
            41 { [void]$builder.Append('\29') }
            42 { [void]$builder.Append('\2a') }
            92 { [void]$builder.Append('\5c') }
            default { [void]$builder.Append($character) }
        }
    }
    return $builder.ToString()
}

function Find-AdComputersBatch {
    <#
      Complete direct-AD inventory for Validation and post-write verification.
      The result explicitly records Found or ConfirmedAbsent for every
      requested name. No partial snapshot is returned if LDAP binding,
      enumeration, or result conversion fails.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$MachineNames,

        [Parameter(Mandatory = $true)]
        [string]$DomainDn,

        [Parameter(Mandatory = $true)]
        [string]$Server
    )

    $uniqueNames = @($MachineNames |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToUpperInvariant() } |
        Sort-Object -Unique)
    if ($uniqueNames.Count -gt 50) {
        throw "Direct AD batch lookup accepts at most 50 computer names; received $($uniqueNames.Count)."
    }
    foreach ($name in $uniqueNames) {
        if ($name -notmatch '^[A-Z0-9](?:[A-Z0-9-]{0,13}[A-Z0-9])?$') {
            throw "Direct AD batch lookup received invalid server name '$name'."
        }
    }

    $serverName = Get-NormalizedAdServerName -Server $Server
    $entries = @{}
    foreach ($name in $uniqueNames) {
        $entries[$name] = [pscustomobject]@{
            MachineName = $name
            State       = 'ConfirmedAbsent'
            Account     = $null
        }
    }

    if ($uniqueNames.Count -eq 0) {
        return [pscustomobject]@{
            Completed      = $true
            DomainDn       = $DomainDn
            Server         = $serverName
            RequestedNames = [string[]]@()
            Entries        = $entries
        }
    }

    # SearchResponse exposes the LDAP result code. DirectorySearcher.FindAll
    # can return only the entries found before a server time limit, which is
    # insufficient when absence must be authoritative. This protocol-level
    # query accepts a snapshot only when LDAP reports complete Success.
    Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop
    $connection = $null
    try {
        $nameClauses = @($uniqueNames | ForEach-Object {
                $escapedSam = ConvertTo-LdapFilterValue -Value ($_ + '$')
                "(sAMAccountName=$escapedSam)"
            })
        $filter = "(&(objectCategory=computer)(|$($nameClauses -join '')))"
        try {
            $identifier = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier(
                $serverName,
                389,
                $false,
                $false
            )
            $connection = New-Object System.DirectoryServices.Protocols.LdapConnection($identifier)
            $connection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
            $connection.Timeout = [TimeSpan]::FromSeconds(30)
            $connection.SessionOptions.ProtocolVersion = 3
            $connection.SessionOptions.ReferralChasing = [System.DirectoryServices.Protocols.ReferralChasingOptions]::None
            $connection.SessionOptions.Signing = $true
            $connection.SessionOptions.Sealing = $true
            $connection.Bind()
        }
        catch {
            $caughtException = $_.Exception
            $rootException = $caughtException
            while ($null -ne $rootException.InnerException) {
                $rootException = $rootException.InnerException
            }
            $ldapMessage = (($rootException.Message -replace '\s+',' ').Trim())
            $lookupException = [System.InvalidOperationException]::new(
                "Active Directory could not establish a signed and sealed LDAP connection to '$serverName' for the computer-account lookup. Technical detail: $ldapMessage",
                $caughtException
            )
            $lookupException.Data['AdLookupFailureKind'] = 'Unavailable'
            throw $lookupException
        }

        $attributes = [string[]]@('sAMAccountName','distinguishedName','objectSid')
        $request = New-Object System.DirectoryServices.Protocols.SearchRequest(
            $DomainDn,
            $filter,
            [System.DirectoryServices.Protocols.SearchScope]::Subtree,
            $attributes
        )
        # At most one domain account can have each sAMAccountName. A response
        # over this limit is therefore inconsistent and must not be accepted.
        $request.SizeLimit = $uniqueNames.Count + 1

        try {
            $response = [System.DirectoryServices.Protocols.SearchResponse]$connection.SendRequest($request)
        }
        catch {
            $caughtException = $_.Exception
            $operationException = $caughtException
            while ($null -ne $operationException -and
                $operationException -isnot [System.DirectoryServices.Protocols.DirectoryOperationException]) {
                $operationException = $operationException.InnerException
            }
            $rootException = $caughtException
            while ($null -ne $rootException.InnerException) {
                $rootException = $rootException.InnerException
            }
            $ldapMessage = (($rootException.Message -replace '\s+',' ').Trim())
            $isAmbiguousSizeLimit = ($null -ne $operationException -and
                $null -ne $operationException.Response -and
                $operationException.Response.ResultCode -eq [System.DirectoryServices.Protocols.ResultCode]::SizeLimitExceeded)
            $isReferral = ([int]$rootException.HResult -eq -2147016661 -or
                $ldapMessage -match '(?i)\breferral\b')
            $friendlyMessage = if ($isAmbiguousSizeLimit) {
                "Active Directory returned more account records than allowed for the requested computer-name lookup through '$serverName'. The result is ambiguous and was not accepted."
            }
            elseif ($isReferral) {
                "The selected AD domain returned an LDAP referral instead of a complete batch account result through '$serverName'. The tool did not treat any requested account as absent. Verify that '$serverName' serves '$DomainDn', then retry. Technical detail: $ldapMessage"
            }
            else {
                "Active Directory could not complete the batch computer-account lookup through '$serverName' in '$DomainDn'. No requested account was treated as absent. Technical detail: $ldapMessage"
            }
            $lookupException = [System.InvalidOperationException]::new($friendlyMessage, $caughtException)
            $lookupException.Data['AdLookupFailureKind'] = if ($isAmbiguousSizeLimit) { 'Conflict' } else { 'Unavailable' }
            throw $lookupException
        }

        if ($null -eq $response -or
            $response.ResultCode -ne [System.DirectoryServices.Protocols.ResultCode]::Success) {
            $resultCode = if ($null -eq $response) { 'NoResponse' } else { [string]$response.ResultCode }
            $resultDetail = if ($null -eq $response) { 'LDAP returned no response object.' } else { [string]$response.ErrorMessage }
            $lookupException = [System.InvalidOperationException]::new(
                "Active Directory returned incomplete batch-search status '$resultCode' through '$serverName'. No requested account was treated as absent. Technical detail: $resultDetail"
            )
            $lookupException.Data['AdLookupFailureKind'] = if ($null -ne $response -and
                $response.ResultCode -eq [System.DirectoryServices.Protocols.ResultCode]::SizeLimitExceeded) {
                'Conflict'
            }
            else {
                'Unavailable'
            }
            throw $lookupException
        }

        foreach ($result in $response.Entries) {
            $samAttribute = $result.Attributes['sAMAccountName']
            $dnAttribute = $result.Attributes['distinguishedName']
            $sidAttribute = $result.Attributes['objectSid']
            $samAccountName = if ($null -eq $samAttribute -or $samAttribute.Count -ne 1) { '' } else { [string]$samAttribute[0] }
            $foundDn = if ($null -eq $dnAttribute -or $dnAttribute.Count -ne 1) { '' } else { [string]$dnAttribute[0] }
            $sidBytes = if ($null -eq $sidAttribute -or $sidAttribute.Count -ne 1) { $null } else { [byte[]]$sidAttribute[0] }
            if ([string]::IsNullOrWhiteSpace($samAccountName) -or
                -not $samAccountName.EndsWith('$') -or
                [string]::IsNullOrWhiteSpace($foundDn) -or
                $null -eq $sidBytes -or
                $sidBytes.Count -eq 0) {
                $lookupException = [System.IO.InvalidDataException]::new(
                    'AD returned an incomplete computer account during the direct AD batch lookup.'
                )
                $lookupException.Data['AdLookupFailureKind'] = 'Conflict'
                throw $lookupException
            }

            $foundName = $samAccountName.Substring(0, $samAccountName.Length - 1).ToUpperInvariant()
            if (-not $entries.ContainsKey($foundName)) {
                $lookupException = [System.IO.InvalidDataException]::new(
                    "AD returned unexpected computer account '$samAccountName' during the direct AD batch lookup."
                )
                $lookupException.Data['AdLookupFailureKind'] = 'Conflict'
                throw $lookupException
            }
            if ([string]$entries[$foundName].State -eq 'Found') {
                $lookupException = [System.IO.InvalidDataException]::new(
                    "AD returned more than one computer account for '$foundName'; the batch result is ambiguous."
                )
                $lookupException.Data['AdLookupFailureKind'] = 'Conflict'
                throw $lookupException
            }

            $entries[$foundName] = [pscustomobject]@{
                MachineName = $foundName
                State       = 'Found'
                Account     = [pscustomobject]@{
                    Name              = $foundName
                    DistinguishedName = $foundDn
                    Sid               = [System.Security.Principal.SecurityIdentifier]::new([byte[]]$sidBytes, 0).Value
                }
            }
        }

        return [pscustomobject]@{
            Completed      = $true
            DomainDn       = $DomainDn
            Server         = $serverName
            RequestedNames = [string[]]$uniqueNames
            Entries        = $entries
        }
    }
    finally {
        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}

function Get-ParentDistinguishedName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName
    )

    $components = @(Split-LdapDistinguishedName -DistinguishedName $DistinguishedName)
    if ($components.Count -lt 2) {
        throw "Cannot determine the parent of '$DistinguishedName'."
    }
    return (@($components[1..($components.Count - 1)]) -join ',')
}

function Assert-AdServerNamingContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Server,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedDomainDn,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedDomainDnsName
    )

    $serverName = Get-NormalizedAdServerName -Server $Server
    $entry = New-SecureDirectoryEntry -Path "LDAP://$serverName/RootDSE"
    try {
        $null = $entry.NativeObject
        $defaultNamingContext = [string]$entry.Properties['defaultNamingContext'].Value
        if ([string]::IsNullOrWhiteSpace($defaultNamingContext)) {
            throw "Active Directory did not return a default naming context from '$serverName'."
        }
        if (-not (Test-DistinguishedNameEqual -First $defaultNamingContext -Second $ExpectedDomainDn)) {
            throw "Domain controller '$serverName' does not serve '$ExpectedDomainDnsName'. It reported '$defaultNamingContext'."
        }
    }
    finally {
        $entry.Dispose()
    }
}

function Get-WritableAdDomainControllerNames {
    <#
      Discovers normal writable DC computer accounts from the selected domain
      without relying on the operator's logon domain or the AD PowerShell
      module. AD DS assigns primaryGroupID 516 to writable DC computer objects;
      RODCs use 521 and are deliberately excluded.

      The signed and sealed paged LDAP request is accepted only after every
      page returns Success. A partial controller inventory must never be used
      for the final AD/PVS binding decision.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$OuMetadata
    )

    Add-Type -AssemblyName System.DirectoryServices.Protocols -ErrorAction Stop
    $serverName = Get-NormalizedAdServerName -Server $OuMetadata.DomainDnsName
    $connection = $null
    try {
        $identifier = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier(
            $serverName,
            389,
            $false,
            $false
        )
        $connection = New-Object System.DirectoryServices.Protocols.LdapConnection($identifier)
        $connection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
        $connection.Timeout = [TimeSpan]::FromSeconds(30)
        $connection.SessionOptions.ProtocolVersion = 3
        $connection.SessionOptions.ReferralChasing = [System.DirectoryServices.Protocols.ReferralChasingOptions]::None
        $connection.SessionOptions.Signing = $true
        $connection.SessionOptions.Sealing = $true
        $connection.Bind()

        $attributes = [string[]]@('dNSHostName','primaryGroupID')
        $request = New-Object System.DirectoryServices.Protocols.SearchRequest(
            $OuMetadata.DomainDn,
            '(&(objectCategory=computer)(primaryGroupID=516)(dNSHostName=*))',
            [System.DirectoryServices.Protocols.SearchScope]::Subtree,
            $attributes
        )
        $pageRequest = New-Object System.DirectoryServices.Protocols.PageResultRequestControl(250)
        [void]$request.Controls.Add($pageRequest)
        $controllers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $pageCount = 0

        do {
            $pageCount++
            if ($pageCount -gt 1000) {
                throw 'Writable domain-controller discovery exceeded 1000 LDAP pages and was stopped.'
            }
            try {
                $response = [System.DirectoryServices.Protocols.SearchResponse]$connection.SendRequest($request)
            }
            catch {
                $caughtException = $_.Exception
                $rootException = $caughtException
                while ($null -ne $rootException.InnerException) {
                    $rootException = $rootException.InnerException
                }
                $ldapMessage = (($rootException.Message -replace '\s+',' ').Trim())
                throw [System.InvalidOperationException]::new(
                    "Active Directory could not discover writable domain controllers for '$($OuMetadata.DomainDnsName)' through '$serverName'. Technical detail: $ldapMessage",
                    $caughtException
                )
            }
            if ($null -eq $response -or
                $response.ResultCode -ne [System.DirectoryServices.Protocols.ResultCode]::Success) {
                $resultCode = if ($null -eq $response) { 'NoResponse' } else { [string]$response.ResultCode }
                $resultDetail = if ($null -eq $response) { 'LDAP returned no response object.' } else { [string]$response.ErrorMessage }
                throw "Writable domain-controller discovery returned incomplete LDAP status '$resultCode' through '$serverName'. Technical detail: $resultDetail"
            }

            foreach ($entry in $response.Entries) {
                $hostAttribute = $entry.Attributes['dNSHostName']
                $primaryGroupAttribute = $entry.Attributes['primaryGroupID']
                $hostName = if ($null -eq $hostAttribute -or $hostAttribute.Count -ne 1) { '' } else { [string]$hostAttribute[0] }
                $primaryGroupId = if ($null -eq $primaryGroupAttribute -or $primaryGroupAttribute.Count -ne 1) { 0 } else { [int]$primaryGroupAttribute[0] }
                if ([string]::IsNullOrWhiteSpace($hostName) -or $primaryGroupId -ne 516) {
                    throw 'Active Directory returned an incomplete or non-writable domain-controller record during discovery.'
                }
                $normalizedHostName = Get-NormalizedAdServerName -Server $hostName
                if (-not $controllers.Add($normalizedHostName)) {
                    throw "Active Directory returned duplicate writable domain-controller hostname '$normalizedHostName'."
                }
            }

            $pageResponses = @($response.Controls | Where-Object {
                    $_ -is [System.DirectoryServices.Protocols.PageResultResponseControl]
                })
            if ($pageResponses.Count -ne 1) {
                throw 'Writable domain-controller discovery did not return exactly one LDAP paging response control.'
            }
            $pageRequest.Cookie = [byte[]]$pageResponses[0].Cookie
        } while ($null -ne $pageRequest.Cookie -and $pageRequest.Cookie.Count -gt 0)

        if ($controllers.Count -eq 0) {
            throw "Active Directory returned no writable domain controllers for '$($OuMetadata.DomainDnsName)'."
        }
        return [string[]]@($controllers | Sort-Object)
    }
    finally {
        if ($null -ne $connection) {
            $connection.Dispose()
        }
    }
}

function Find-AdComputersBatchAcrossWritableDcs {
    <#
      Reads all submitted names once per writable DC. One consistent Found
      account is sufficient even when another DC is lagging or unavailable.
      Absence is accepted only when every discovered writable DC completed an
      authoritative batch query and reported the name absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$MachineNames,
        [Parameter(Mandatory = $true)][psobject]$OuMetadata
    )

    $uniqueNames = @($MachineNames |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToUpperInvariant() } |
        Sort-Object -Unique)
    $controllers = @(Get-WritableAdDomainControllerNames -OuMetadata $OuMetadata)
    $snapshots = New-Object 'System.Collections.Generic.List[object]'
    $failures = New-Object 'System.Collections.Generic.List[string]'

    foreach ($controller in $controllers) {
        try {
            $snapshot = Find-AdComputersBatch `
                -MachineNames $uniqueNames `
                -DomainDn $OuMetadata.DomainDn `
                -Server $controller
            [void]$snapshots.Add([pscustomobject]@{
                    DomainController = [string]$controller
                    Snapshot         = $snapshot
                })
            Write-RunLog -Level SUCCESS -Stage 'AD Validation fan-out' -Message "Completed the $($uniqueNames.Count)-name AD snapshot through writable DC '$controller'."
        }
        catch {
            $failure = "${controller}: $($_.Exception.Message)"
            [void]$failures.Add($failure)
            Write-RunLog -Level WARN -Stage 'AD Validation fan-out' -Message $failure
        }
    }
    if ($snapshots.Count -eq 0) {
        throw "No writable DC completed the AD batch Validation query. $([string]::Join(' | ', $failures.ToArray()))"
    }

    $entries = @{}
    foreach ($name in $uniqueNames) {
        $found = New-Object 'System.Collections.Generic.List[object]'
        foreach ($snapshotEnvelope in $snapshots) {
            $entry = $snapshotEnvelope.Snapshot.Entries[$name]
            if ($null -eq $entry) {
                throw "Writable DC '$($snapshotEnvelope.DomainController)' returned no explicit AD state for '$name'."
            }
            if ([string]$entry.State -eq 'Found') {
                [void]$found.Add([pscustomobject]@{
                        DomainController = [string]$snapshotEnvelope.DomainController
                        Account          = $entry.Account
                    })
            }
            elseif ([string]$entry.State -ne 'ConfirmedAbsent') {
                throw "Writable DC '$($snapshotEnvelope.DomainController)' returned unsupported AD state '$($entry.State)' for '$name'."
            }
        }

        if ($found.Count -gt 0) {
            $reference = $found[0].Account
            $conflicts = @($found | Where-Object {
                    -not (Test-DistinguishedNameEqual `
                        -First ([string]$_.Account.DistinguishedName) `
                        -Second ([string]$reference.DistinguishedName)) -or
                    [string]$_.Account.Sid -ine [string]$reference.Sid
                })
            if ($conflicts.Count -gt 0) {
                $states = @($found | ForEach-Object {
                        "$($_.DomainController):DN='$($_.Account.DistinguishedName)'/SID='$($_.Account.Sid)'"
                    }) -join ' | '
                throw "Writable DCs returned conflicting AD accounts for '$name'. $states"
            }
            $entries[$name] = [pscustomobject]@{
                MachineName = $name
                State       = 'Found'
                Account     = $reference
            }
            if ($failures.Count -gt 0 -or $found.Count -lt $controllers.Count) {
                Write-RunLog -Level WARN -Stage 'AD Validation fan-out' -MachineName $name -Message "Accepted the exact AD account from $($found.Count) writable DC(s). Other DCs were absent, lagging, or unavailable. Matching DCs: $(@($found.DomainController) -join ', ')."
            }
        }
        else {
            if ($failures.Count -gt 0 -or $snapshots.Count -ne $controllers.Count) {
                throw "AD absence for '$name' could not be proven across every writable DC. Completed=$($snapshots.Count); discovered=$($controllers.Count); failures=$([string]::Join(' | ', $failures.ToArray()))."
            }
            $entries[$name] = [pscustomobject]@{
                MachineName = $name
                State       = 'ConfirmedAbsent'
                Account     = $null
            }
        }
    }

    return [pscustomobject]@{
        Completed         = $true
        DomainDn          = [string]$OuMetadata.DomainDn
        Server            = 'WritableDcFanOut'
        RequestedNames    = [string[]]$uniqueNames
        DomainControllers = [string[]]$controllers
        Entries           = $entries
        Failures          = [string[]]$failures.ToArray()
    }
}

function Get-OuMetadata {
    <# Compatibility wrapper. New internal callers use ConvertFrom-OuDistinguishedName. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName
    )

    return (ConvertFrom-OuDistinguishedName @PSBoundParameters)
}

function Get-OrganizationalUnitMetadata {
    <# Compatibility wrapper. New internal callers use Resolve-AdOrganizationalUnit. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName,

        [string]$Server
    )

    return (Resolve-AdOrganizationalUnit @PSBoundParameters)
}

#endregion Active Directory helpers
