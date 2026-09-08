function Get-RequiredRadioChoice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Windows.Controls.RadioButton]$First,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$FirstValue,

        [Parameter(Mandatory)]
        [System.Windows.Controls.RadioButton]$Second,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SecondValue,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MissingMessage
    )

    $firstSelected = ($First.IsChecked -eq $true)
    $secondSelected = ($Second.IsChecked -eq $true)

    # Fail closed if neither choice is selected or the UI ever enters an
    # invalid state in which both mutually exclusive choices are selected.
    if ($firstSelected -eq $secondSelected) {
        throw $MissingMessage
    }

    if ($firstSelected) { return $FirstValue }
    return $SecondValue
}

function Read-GuiBuildRequest {
    [CmdletBinding()]
    param()

    # Enforce the build-size policy before this batch performs any AD OU, OLVM,
    # PVS, DNS, or DHCP lookup. Count every non-empty physical row so malformed
    # or duplicate entries cannot bypass the limit.
    $inputLines = @($script:ServerList.Text -split '\r\n|\n|\r')
    $serverEntryCount = @($inputLines | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }).Count
    if ($serverEntryCount -eq 0) {
        throw 'Enter at least one server as: ServerName, IPv4Address.'
    }
    if ($serverEntryCount -gt $script:MaximumBatchSize) {
        throw "This build contains $serverEntryCount server entries. The maximum is $($script:MaximumBatchSize) servers per build. Split the list into batches of $($script:MaximumBatchSize) or fewer and run Validation again. No per-batch infrastructure checks or changes were started."
    }

    $collection = $script:Collection.SelectedItem
    if ($null -eq $collection) { throw 'Select a PVS device collection.' }
    $assignImageChoice = Get-RequiredRadioChoice `
        -First $script:AssignImageYes -FirstValue 'Yes' `
        -Second $script:AssignImageNo -SecondValue 'No' `
        -MissingMessage 'Select exactly one Assign Image choice: Yes or No.'
    $assignPvsImage = ($assignImageChoice -eq 'Yes')
    $powerChoice = Get-RequiredRadioChoice `
        -First $script:PowerOnYes -FirstValue 'Yes' `
        -Second $script:PowerOnNo -SecondValue 'No' `
        -MissingMessage 'Select exactly one post-build power choice: Yes or No.'
    $powerOnAfterBuild = ($powerChoice -eq 'Yes')
    $store = $null
    $validatedImage = $null
    if ($assignPvsImage) {
        $store = $script:PvsStore.SelectedItem
        if ($null -eq $store) {
            throw 'Image assignment is selected. Select a PVS Store and one Production-ready vDisk.'
        }
        $script:SelectedPvsImage = $script:PvsImage.SelectedItem
        if ($null -eq $script:SelectedPvsImage) {
            throw 'Image assignment is selected. Choose one Production-ready vDisk from the list.'
        }
        if ([guid]$script:SelectedPvsImage.StoreId -ne [guid]$store.StoreId -or
            [guid]$script:SelectedPvsImage.SiteId -ne [guid]$collection.SiteId) {
            throw 'The selected PVS image does not belong to the currently selected collection Site and Store. Select the image again.'
        }
        $validatedImage = Assert-SelectionPvsImageSnapshot `
            -Collection $collection `
            -Store $store `
            -ExpectedImage $script:SelectedPvsImage
    }
    elseif ($null -ne $script:SelectedPvsImage -or
        $null -ne $script:PvsImage.SelectedItem) {
        throw 'The GUI contains a PVS image while optional image assignment is not selected. Clear and reselect the image option before Validation.'
    }
    if ($powerOnAfterBuild -and -not $assignPvsImage) {
        throw 'Power-on requires a selected and validated PVS image. Select optional image assignment and choose a vDisk, or select No for post-build power.'
    }
    $bootLabel = Get-RequiredRadioChoice `
        -First $script:BootBios -FirstValue 'BIOS (Legacy)' `
        -Second $script:BootUefi -SecondValue 'UEFI (x64)' `
        -MissingMessage 'Select exactly one boot type: BIOS (Legacy) or UEFI (x64).'
    $pvsNameCase = Get-RequiredRadioChoice `
        -First $script:PvsCaseUpper -FirstValue 'Upper' `
        -Second $script:PvsCaseLower -SecondValue 'Lower' `
        -MissingMessage 'Select exactly one PVS target-name case: Upper or Lower.'
    $dhcpNameCase = Get-RequiredRadioChoice `
        -First $script:DhcpCaseUpper -FirstValue 'Upper' `
        -Second $script:DhcpCaseLower -SecondValue 'Lower' `
        -MissingMessage 'Select exactly one DHCP reservation-name case: Upper or Lower.'
    $reservationName = Get-RequiredRadioChoice `
        -First $script:ReservationHost -FirstValue 'Host' `
        -Second $script:ReservationFqdn -SecondValue 'FQDN' `
        -MissingMessage 'Select exactly one DHCP reservation name: Host or FQDN.'

    $adDnsDomain = $script:AdDnsDomain.Text.Trim().Trim('.')
    if ([string]::IsNullOrWhiteSpace($adDnsDomain)) {
        throw 'Enter the AD DNS domain and select an existing OU.'
    }
    $expectedDomainDn = Convert-DnsDomainToDn -DnsDomain $adDnsDomain
    $ouDn = $script:OrganizationalUnit.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($ouDn)) {
        throw 'Select an existing AD OU from the OU list.'
    }
    if ($null -eq $script:OuSelector.SelectedItem -or
        -not (Test-DistinguishedNameEqual `
            -First ([string]$script:OuSelector.SelectedItem.DistinguishedName) `
            -Second $ouDn)) {
        throw 'The OU field contains typed text rather than an exact selected OU. Open the list and select one result.'
    }
    $ouMetadata = Resolve-SelectionAdOrganizationalUnit -DistinguishedName $ouDn -Server $adDnsDomain
    if (-not (Test-DistinguishedNameEqual -First $ouMetadata.DomainDn -Second $expectedDomainDn) -or
        -not $ouMetadata.DomainDnsName.Equals($adDnsDomain, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The selected OU belongs to '$($ouMetadata.DomainDnsName)', not the entered AD DNS domain '$adDnsDomain'."
    }

    # Keep the backend DN hidden while showing only the canonical path to users.
    $script:OrganizationalUnit.Text = $ouMetadata.DistinguishedName
    $script:OuSelector.Text = $ouMetadata.DisplayPath

    $managerChoice = $script:OlvmManager.SelectedItem
    if ($null -eq $managerChoice) {
        throw 'Select an OLVM Manager choice. Auto-detect is recommended.'
    }
    if (-not [bool]$managerChoice.IsAvailable) {
        throw "Selected OLVM Manager '$($managerChoice.Manager)' is unavailable: $($managerChoice.AvailabilityMessage)"
    }

    $settings = [pscustomobject]@{
        Collection          = $collection
        AssignPvsImage      = $assignPvsImage
        Store               = $store
        StoreDisplay        = if ($assignPvsImage) { [string]$store.Name } else { 'Not required' }
        Image               = $validatedImage
        ImageDisplay        = if ($assignPvsImage) { [string]$validatedImage.Name } else { 'Not requested' }
        ImageVersionDisplay = if ($assignPvsImage) { [string]$validatedImage.EffectiveVersionDisplay } else { 'Not applicable' }
        BootLabel           = $bootLabel
        BootFile            = if ($bootLabel -eq 'BIOS (Legacy)') { 'ardbp32.bin' } else { 'pvsnbpx64.efi' }
        AdDnsDomain         = $adDnsDomain
        OuMetadata          = $ouMetadata
        PvsNameCase         = $pvsNameCase
        DhcpNameCase        = $dhcpNameCase
        ReservationName     = $reservationName
        PowerOnAfterBuild   = $powerOnAfterBuild
        OlvmManager         = if ([string]$managerChoice.Mode -eq 'Explicit') { [string]$managerChoice.Manager } else { '' }
        OlvmManagerDisplay  = [string]$managerChoice.Display
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $lineNumber = 0
    foreach ($rawLine in $inputLines) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }

        if ($rawLine.Length -gt 256) {
            [void]$rows.Add([pscustomobject]@{
                    Line        = $lineNumber
                    LookupName  = ''
                    MachineName = ''
                    IPAddress   = ''
                    InputError  = 'This entry is too long. Use exactly: ServerName, IPv4Address'
                })
            continue
        }

        $parts = @($rawLine.Split(',') | ForEach-Object { $_.Trim() })
        if ($parts.Count -ne 2) {
            [void]$rows.Add([pscustomobject]@{
                    Line        = $lineNumber
                    LookupName  = ''
                    MachineName = ''
                    IPAddress   = ''
                    InputError  = 'Use exactly: ServerName, IPv4Address'
                })
            continue
        }

        try {
            $lookupName = $parts[0]
            $validatedName = $lookupName.ToUpperInvariant()
            if ($validatedName -notmatch '^[A-Z0-9](?:[A-Z0-9-]{0,13}[A-Z0-9])?$') {
                throw (Get-ServerNameValidationError -Name $lookupName)
            }
            $pvsName = if ($settings.PvsNameCase -eq 'Lower') {
                $validatedName.ToLowerInvariant()
            }
            else {
                $validatedName
            }
            $ipAddress = (Get-IPv4Address -Value $parts[1]).IPAddressToString
            [void]$rows.Add([pscustomobject]@{
                    Line        = $lineNumber
                    LookupName  = $lookupName
                    MachineName = $pvsName
                    IPAddress   = $ipAddress
                    InputError  = ''
                })
        }
        catch {
            [void]$rows.Add([pscustomobject]@{
                    Line        = $lineNumber
                    LookupName  = $parts[0]
                    MachineName = $parts[0]
                    IPAddress   = $parts[1]
                    InputError  = $_.Exception.Message
                })
        }
    }

    return [pscustomobject]@{
        Settings = $settings
        Rows     = [object[]]$rows.ToArray()
    }
}


function Get-GuiInput {
    <# Compatibility wrapper. New internal callers use Read-GuiBuildRequest. #>
    [CmdletBinding()]
    param()

    return (Read-GuiBuildRequest @PSBoundParameters)
}
