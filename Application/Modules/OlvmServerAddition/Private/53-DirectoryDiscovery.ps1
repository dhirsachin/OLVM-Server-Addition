function Get-LocalDnsDomain {
    <# The initial AD domain comes from reverse DNS for the current PVS server. #>
    [CmdletBinding()]
    param()

    try {
        $hostEntry = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)
        $fqdn = [string]$hostEntry.HostName
        if ($fqdn -match '^[^.]+\.(.+)$') {
            $domain = $Matches[1].TrimEnd('.')
            Write-RunLog -Level SUCCESS -Stage 'Reverse DNS' -Message "This PVS server resolved as '$fqdn'; initial AD DNS domain is '$domain'."
            return $domain
        }
        Write-RunLog -Level WARN -Stage 'Reverse DNS' -Message "Reverse DNS returned '$fqdn' without a DNS suffix. The operator must enter the AD DNS domain."
    }
    catch {
        Write-RunLog -Level WARN -Stage 'Reverse DNS' -Message "The AD DNS domain could not be derived from this PVS server: $($_.Exception.Message)"
    }
    return ''
}

function Get-OuChoicesForDomain {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DnsDomain)

    $dnsDomain = $DnsDomain.Trim().Trim('.').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($dnsDomain)) {
        throw 'Enter the AD DNS domain before opening the OU list.'
    }
    if ($script:OuChoicesCache.ContainsKey($dnsDomain)) {
        return [object[]]$script:OuChoicesCache[$dnsDomain]
    }

    $domainDn = Convert-DnsDomainToDn -DnsDomain $dnsDomain
    Invoke-PresentationPort -Name 'Status' -Arguments @{ Text = "Reading existing OUs from '$dnsDomain'..."; Stage = 'OU selection' }
    Assert-AdServerNamingContext `
        -Server $dnsDomain `
        -ExpectedDomainDn $domainDn `
        -ExpectedDomainDnsName $dnsDomain

    $root = $null
    $searcher = $null
    $searchResults = $null
    $ouItems = New-Object 'System.Collections.Generic.List[object]'
    try {
        $root = New-SecureDirectoryEntry -Path "LDAP://$dnsDomain/$domainDn"
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($root)
        $searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
        $searcher.PageSize = 1000
        $searcher.SizeLimit = $script:MaximumOuBrowseResults + 1
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds($script:DirectorySearchTimeoutSeconds)
        $searcher.ServerTimeLimit = [TimeSpan]::FromSeconds($script:DirectorySearchTimeoutSeconds)
        $searcher.CacheResults = $false
        $searcher.Filter = '(objectClass=organizationalUnit)'
        [void]$searcher.PropertiesToLoad.Add('distinguishedName')
        [void]$searcher.PropertiesToLoad.Add('canonicalName')
        $searchResults = $searcher.FindAll()
        foreach ($searchResult in $searchResults) {
            if ($ouItems.Count -ge $script:MaximumOuBrowseResults) {
                throw "The AD domain returned more than $($script:MaximumOuBrowseResults) OUs. Narrowing the OU source is required before this domain can be used safely."
            }
            $distinguishedName = [string]$searchResult.Properties['distinguishedname'][0]
            if ([string]::IsNullOrWhiteSpace($distinguishedName)) {
                throw "Active Directory returned an OU without a distinguished name from '$dnsDomain'."
            }
            $canonicalName = [string]$searchResult.Properties['canonicalname'][0]
            if ([string]::IsNullOrWhiteSpace($canonicalName)) {
                $metadata = ConvertFrom-OuDistinguishedName -DistinguishedName $distinguishedName
                $canonicalName = "$($metadata.DomainDnsName)/$($metadata.FriendlyOuPath)"
            }
            [void]$ouItems.Add([pscustomobject]@{
                    DistinguishedName = $distinguishedName
                    Display           = $canonicalName
                })
        }
    }
    finally {
        if ($null -ne $searchResults) { try { $searchResults.Dispose() } catch {} }
        if ($null -ne $searcher) { try { $searcher.Dispose() } catch {} }
        if ($null -ne $root) { try { $root.Dispose() } catch {} }
    }
    $choices = [object[]]@($ouItems.ToArray() | Sort-Object Display)
    if ($choices.Count -eq 0) {
        throw "No organizational units were returned from '$dnsDomain'."
    }
    $script:OuChoicesCache[$dnsDomain] = [object[]]$choices
    Write-RunLog -Level SUCCESS -Stage 'OU selection' -Message "Loaded and cached $($choices.Count) OU(s) from '$dnsDomain'."
    return [object[]]$choices
}
