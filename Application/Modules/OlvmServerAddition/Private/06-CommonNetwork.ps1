function Get-NormalizedMacAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $hex = ($Value -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($hex -notmatch '^[0-9A-F]{12}$') {
        throw "Invalid MAC address '$Value'."
    }

    return (($hex -split '(.{2})' | Where-Object { $_ }) -join '-')
}

function Test-MacAddressEqual {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$First,
        [AllowNull()][object]$Second
    )

    try {
        return ((Get-NormalizedMacAddress -Value ([string]$First)) -ieq
            (Get-NormalizedMacAddress -Value ([string]$Second)))
    }
    catch {
        return $false
    }
}

function Get-IPv4Address {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $text = $Value.Trim()
    $invalidMessage = "Invalid IPv4 address '$Value'. Enter four decimal numbers from 0 to 255, separated by periods, without leading zeros (example: 104.170.86.105)."

    # Accept only canonical dotted-decimal ASCII notation. IPAddress.TryParse
    # also accepts ambiguous forms such as 010.010.010.010, 127.1, a single
    # integer, and hexadecimal components, so lexical validation must run first.
    if ($text -notmatch '^(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}$') {
        throw $invalidMessage
    }

    $octets = @($text.Split('.') | ForEach-Object { [int]$_ })
    if ($octets.Count -ne 4 -or
        @($octets | Where-Object { $_ -lt 0 -or $_ -gt 255 }).Count -gt 0) {
        throw $invalidMessage
    }

    $address = $null
    $isValid = [System.Net.IPAddress]::TryParse($text, [ref]$address)
    if (-not $isValid -or
        $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $address.IPAddressToString -cne $text) {
        throw $invalidMessage
    }

    return $address
}

function Get-ServerNameValidationError {
    <# Returns a direct operator-facing correction for an invalid server name. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $displayName = Protect-LogField -Value $Name -MaximumLength 128
    if ($Name.Contains('.')) {
        return "Server name '$displayName' appears to be an FQDN. Enter only the server name before the first period, without the DNS domain (example: SERVER01)."
    }
    return "Server name '$displayName' is invalid. Enter a 1-15 character server name using only letters, digits, or hyphens; do not begin or end with a hyphen."
}

function ConvertTo-UInt32IPv4 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]$Address
    )

    $bytes = $Address.GetAddressBytes()
    [array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Test-IPv4InRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]$Address,

        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]$StartRange,

        [Parameter(Mandatory = $true)]
        [System.Net.IPAddress]$EndRange
    )

    $value = ConvertTo-UInt32IPv4 -Address $Address
    return ($value -ge (ConvertTo-UInt32IPv4 -Address $StartRange) -and
        $value -le (ConvertTo-UInt32IPv4 -Address $EndRange))
}

function Convert-DnsDomainToDn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DnsDomain
    )

    $normalized = $DnsDomain.Trim().Trim('.')
    $labels = @($normalized -split '\.')
    if ($labels.Count -lt 2) {
        throw "AD DNS domain '$DnsDomain' must contain at least two labels."
    }
    foreach ($label in $labels) {
        if ($label -notmatch '^[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$') {
            throw "AD DNS domain '$DnsDomain' contains an invalid label '$label'."
        }
    }
    return (($labels | ForEach-Object { "DC=$_" }) -join ',')
}

function Test-DnsNoPtrRecordError {
    <# Only an authoritative name-error/no-record result may use the selected
       AD DNS domain as a fallback. Timeouts and DNS-server failures remain
       blocking because they cannot prove that a conflicting PTR is absent. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $errorId = [string]$ErrorRecord.FullyQualifiedErrorId
    if ($errorId -match '(?i)DNS_ERROR_RCODE_NAME_ERROR|DNS_INFO_NO_RECORDS') {
        return $true
    }

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        foreach ($propertyName in @('NativeErrorCode','ErrorCode','HResult')) {
            $property = $exception.PSObject.Properties[$propertyName]
            if ($null -eq $property -or $null -eq $property.Value) { continue }
            try {
                $code = [int64]$property.Value
                if ($code -in @(9003,9501) -or ($code -band 0xFFFF) -in @(9003,9501)) {
                    return $true
                }
            }
            catch {}
        }
        $exception = $exception.InnerException
    }

    # This supplements the stable error IDs/codes for older DNS cmdlet builds.
    return ($ErrorRecord.Exception.Message -match '(?i)DNS name does not exist|no (?:DNS )?records?')
}

function Get-FqdnForInput {
    <#
      Reverse DNS is authoritative when present. If no usable PTR exists, the
      selected AD DNS domain supplies the one controlled FQDN fallback. A PTR
      that points to another machine is never hidden by that fallback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MachineName,

        [Parameter(Mandatory = $true)]
        [string]$IPAddress,

        [Parameter(Mandatory = $true)]
        [string]$AdDnsDomain
    )

    Write-RunLog -Level INFO -Stage 'DNS' -MachineName $MachineName -Message "Looking up the PTR record for $IPAddress."
    $dnsConfirmedNoPtr = $false
    try {
        $ptrNames = @(Resolve-DnsName -Name $IPAddress -Type PTR -DnsOnly -ErrorAction Stop |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.NameHost) } |
            ForEach-Object { ([string]$_.NameHost).TrimEnd('.') } |
            Sort-Object -Unique)

        if ($ptrNames.Count -gt 1) {
            throw "PTR lookup returned multiple FQDNs for ${IPAddress}: '$($ptrNames -join ', ')'. Resolve the ambiguity before provisioning."
        }
        if ($ptrNames.Count -eq 1) {
            $fqdn = $ptrNames[0]
            if ($fqdn -notmatch '^(?=.{1,253}$)(?:[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?\.)+[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$') {
                throw "PTR FQDN '$fqdn' is not a usable fully qualified DNS name."
            }
            if ($fqdn.Split('.')[0] -ine $MachineName) {
                throw "PTR FQDN '$fqdn' does not match machine name '$MachineName'."
            }

            Write-RunLog -Level SUCCESS -Stage 'DNS' -MachineName $MachineName -Message "PTR lookup returned '$fqdn'."
            return $fqdn
        }
        $dnsConfirmedNoPtr = $true
    }
    catch {
        if ($_.Exception.Message -match '^PTR ') {
            Write-ExceptionLog -Stage 'DNS' -MachineName $MachineName -ErrorRecord $_
            throw
        }
        if (-not (Test-DnsNoPtrRecordError -ErrorRecord $_)) {
            Write-ExceptionLog -Stage 'DNS' -MachineName $MachineName -ErrorRecord $_
            $technicalDetail = (($_.Exception.Message -replace '\s+',' ').Trim())
            throw "Reverse-DNS lookup for $IPAddress could not be completed. The AD DNS domain fallback is used only when DNS confirms that no PTR record exists. Resolve the DNS lookup failure, then run Validation again. Technical detail: $technicalDetail"
        }
        $dnsConfirmedNoPtr = $true
        Write-RunLog -Level WARN -Stage 'DNS' -MachineName $MachineName -Message "DNS confirmed that no PTR record exists for $IPAddress. $($_.Exception.Message)"
    }

    if (-not $dnsConfirmedNoPtr) {
        throw "Reverse-DNS lookup for $IPAddress ended without an authoritative PTR result. The server was blocked."
    }
    $normalizedDomain = $AdDnsDomain.Trim().Trim('.')
    $null = Convert-DnsDomainToDn -DnsDomain $normalizedDomain
    $fallbackFqdn = "$MachineName.$normalizedDomain"
    Write-RunLog -Level WARN -Stage 'DNS' -MachineName $MachineName -Message "No usable PTR record exists for $IPAddress. Using the selected AD DNS domain to build '$fallbackFqdn'."
    return $fallbackFqdn
}
