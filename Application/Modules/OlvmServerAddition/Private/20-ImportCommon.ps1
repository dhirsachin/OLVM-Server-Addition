function Get-NormalizedServerImportHeader {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ''
    }
    return (($Value.Trim() -replace '[\s_-]+','').ToUpperInvariant())
}

function Test-ServerImportHeader {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$FirstValue,
        [AllowNull()][string]$SecondValue
    )

    $nameHeader = Get-NormalizedServerImportHeader -Value $FirstValue
    $ipHeader = Get-NormalizedServerImportHeader -Value $SecondValue
    return ($nameHeader -in @('SERVERNAME','MACHINENAME','NAME') -and
        $ipHeader -in @('IPADDRESS','IPV4ADDRESS'))
}

function ConvertTo-ServerImportBatch {
    <# Validates the complete temporary import before ServerList.Text changes.
       Validation remains authoritative after a successful import. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records,

        [Parameter(Mandatory = $true)]
        [string]$SourceDisplay
    )

    $workingRecords = @($Records)
    $headerSkipped = $false
    if ($workingRecords.Count -gt 0 -and
        (Test-ServerImportHeader -FirstValue $workingRecords[0].ServerName -SecondValue $workingRecords[0].IPAddress)) {
        $headerSkipped = $true
        if ($workingRecords.Count -gt 1) {
            $workingRecords = @($workingRecords[1..($workingRecords.Count - 1)])
        }
        else {
            $workingRecords = @()
        }
    }

    if ($workingRecords.Count -eq 0) {
        throw "'$SourceDisplay' does not contain any server records. Add ServerName and IPAddress values, then import the file again."
    }
    if ($workingRecords.Count -gt $script:MaximumBatchSize) {
        throw "'$SourceDisplay' contains $($workingRecords.Count) server records. The maximum is $($script:MaximumBatchSize) servers per build. Split the file into batches of $($script:MaximumBatchSize) or fewer. No entries were imported."
    }

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    $seenNames = @{}
    $seenIps = @{}
    foreach ($record in $workingRecords) {
        $location = [string]$record.Location
        $name = ([string]$record.ServerName).Trim()
        $ipText = ([string]$record.IPAddress).Trim()
        $rowIsValid = $true

        if ([string]::IsNullOrWhiteSpace($name)) {
            [void]$errors.Add("${location}: the server name is blank.")
            $rowIsValid = $false
        }
        elseif ($name.Length -gt 128) {
            [void]$errors.Add("${location}: the server name is too long. Enter only the 1-15 character server name, without a DNS domain.")
            $rowIsValid = $false
        }
        elseif ($name.ToUpperInvariant() -notmatch '^[A-Z0-9](?:[A-Z0-9-]{0,13}[A-Z0-9])?$') {
            [void]$errors.Add("${location}: $(Get-ServerNameValidationError -Name $name)")
            $rowIsValid = $false
        }

        $canonicalIp = $null
        if ([string]::IsNullOrWhiteSpace($ipText)) {
            [void]$errors.Add("${location}: the IPv4 address is blank.")
            $rowIsValid = $false
        }
        elseif ($ipText.Length -gt 64) {
            [void]$errors.Add("${location}: the IPv4 address is too long. Enter four decimal numbers separated by periods.")
            $rowIsValid = $false
        }
        else {
            try {
                $canonicalIp = (Get-IPv4Address -Value $ipText).IPAddressToString
            }
            catch {
                [void]$errors.Add("${location}: $($_.Exception.Message)")
                $rowIsValid = $false
            }
        }

        if ($rowIsValid) {
            $nameKey = $name.ToUpperInvariant()
            if ($seenNames.ContainsKey($nameKey)) {
                [void]$errors.Add("${location}: server name '$name' is duplicated; it was already supplied at $($seenNames[$nameKey]).")
                $rowIsValid = $false
            }
            else {
                $seenNames[$nameKey] = $location
            }

            if ($seenIps.ContainsKey($canonicalIp)) {
                [void]$errors.Add("${location}: IPv4 address '$canonicalIp' is duplicated; it was already supplied at $($seenIps[$canonicalIp]).")
                $rowIsValid = $false
            }
            else {
                $seenIps[$canonicalIp] = $location
            }
        }

        if ($rowIsValid) {
            [void]$outputLines.Add("$name, $canonicalIp")
        }
    }

    if ($errors.Count -gt 0) {
        $visibleErrors = @($errors | Select-Object -First 8 | ForEach-Object { "- $_" })
        $moreText = if ($errors.Count -gt $visibleErrors.Count) {
            "`n- ... and $($errors.Count - $visibleErrors.Count) more error(s)."
        }
        else {
            ''
        }
        $exception = New-Object System.InvalidOperationException(
            "Import validation failed for '$SourceDisplay':`n$($visibleErrors -join "`n")$moreText`n`nNo entries were imported and the current server list was not changed."
        )
        # The dialog stays readable, while the event handler records every
        # invalid row in the persistent audit log.
        $exception.Data['ImportValidationErrors'] = [string[]]$errors.ToArray()
        throw $exception
    }

    return [pscustomobject]@{
        Count         = $outputLines.Count
        Text          = [string]::Join([Environment]::NewLine, [string[]]$outputLines.ToArray())
        HeaderSkipped = $headerSkipped
    }
}
