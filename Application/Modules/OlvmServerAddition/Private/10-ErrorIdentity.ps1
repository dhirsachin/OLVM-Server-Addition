function New-SerializableErrorIdentity {
    <#
      Converts an ErrorRecord and its exception chain into bounded scalar data.
      Live ErrorRecord, Exception, credential, secure-string, and scriptblock
      instances are never returned or copied into a cross-runspace envelope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [ValidateSet('Unknown','Retryable','DoNotRetry','RequiresIntervention')]
        [string]$Disposition = 'Unknown',

        [ValidateRange(1,16)]
        [int]$MaximumInnerDepth = 8,

        [AllowNull()]
        [System.Collections.IDictionary]$AdditionalData = $null
    )

    $maximumDataDepth = 6
    $maximumDataItems = 32
    $maximumTextCharacters = 2048

    $toSafeText = {
        param([AllowNull()][object]$Value)

        if ($null -eq $Value) { return '' }
        $text = (([string]$Value) -replace '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}|]+',' ').Trim()
        $text = [regex]::Replace(
            $text,
            '(?i)\b(https?://)([^/\s:@]+):([^/\s]+)@',
            '$1<redacted>:<redacted>@'
        )
        $text = [regex]::Replace(
            $text,
            '(?i)\b(Authorization\s*[:=]\s*(?:Bearer|Basic)\s+)[^\s,;]+',
            '$1<redacted>'
        )
        $text = [regex]::Replace(
            $text,
            '(?i)\b(Cookie\s*[:=]\s*)[^;]+',
            '$1<redacted>'
        )
        $text = [regex]::Replace(
            $text,
            '(?i)(-(?:Password|Credential|Token|Secret|Authorization|Cookie)\s+)(?:"[^"]*"|''[^'']*''|[^\s]+)',
            '$1<redacted>'
        )
        $text = [regex]::Replace(
            $text,
            '(?i)\b(Password|Passwd|Pwd|Credential|Token|Secret|Api[-_]?Key|Cookie)\s*[:=]\s*(?:"[^"]*"|''[^'']*''|[^\s,;]+)',
            '$1=<redacted>'
        )
        if ($text.Length -gt $maximumTextCharacters) {
            return $text.Substring(0,$maximumTextCharacters - 16) + ' ... [truncated]'
        }
        return $text
    }

    $convertDataValue = $null
    $convertDataValue = {
        param(
            [AllowNull()][object]$Value,
            [int]$Depth
        )

        if ($null -eq $Value) { return $null }
        if ($Value -is [System.Management.Automation.PSCredential] -or
            $Value -is [System.Security.SecureString]) {
            return '<redacted>'
        }
        if ($Value -is [System.Exception] -or
            $Value -is [System.Management.Automation.ErrorRecord] -or
            $Value -is [scriptblock]) {
            return '<runtime object omitted>'
        }
        if ($Value -is [string]) { return (& $toSafeText $Value) }
        if ($Value -is [bool] -or
            $Value -is [byte] -or $Value -is [sbyte] -or
            $Value -is [int16] -or $Value -is [uint16] -or
            $Value -is [int32] -or $Value -is [uint32] -or
            $Value -is [int64] -or $Value -is [uint64] -or
            $Value -is [single] -or $Value -is [double] -or
            $Value -is [decimal]) {
            return $Value
        }
        if ($Value -is [DateTime]) {
            return ([DateTime]$Value).ToString('o',[System.Globalization.CultureInfo]::InvariantCulture)
        }
        if ($Value -is [guid]) { return ([guid]$Value).ToString('D') }
        if ($Value.GetType().IsEnum) { return (& $toSafeText $Value) }
        if ($Depth -ge $maximumDataDepth) { return '<maximum depth reached>' }

        if ($Value -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            $count = 0
            foreach ($key in @($Value.Keys)) {
                if ($count -ge $maximumDataItems) {
                    $result['AdditionalItemsOmitted'] = $true
                    break
                }
                $safeKey = & $toSafeText $key
                if ([string]::IsNullOrWhiteSpace($safeKey)) { $safeKey = "Item$count" }
                if ($safeKey -match '(?i)(?:password|passwd|pwd|credential|token|secret|authorization|cookie|api[-_]?key)') {
                    $result[$safeKey] = '<redacted>'
                }
                else {
                    $result[$safeKey] = & $convertDataValue $Value[$key] ($Depth + 1)
                }
                $count++
            }
            return [pscustomobject]$result
        }

        if ($Value -is [System.Collections.IEnumerable]) {
            $items = New-Object 'System.Collections.Generic.List[object]'
            $count = 0
            foreach ($item in $Value) {
                if ($count -ge $maximumDataItems) {
                    [void]$items.Add('<additional items omitted>')
                    break
                }
                [void]$items.Add((& $convertDataValue $item ($Depth + 1)))
                $count++
            }
            return $items.ToArray()
        }

        return (& $toSafeText $Value)
    }

    $buildIdentity = $null
    $buildIdentity = {
        param(
            [AllowNull()][System.Exception]$Exception,
            [int]$Depth,
            [string]$FullyQualifiedErrorId,
            [string]$Category,
            [AllowNull()][System.Collections.IDictionary]$RootData
        )

        if ($null -eq $Exception) { return $null }
        $data = [ordered]@{}
        $dataItemCount = 0
        $dataSources = New-Object 'System.Collections.Generic.List[System.Collections.IDictionary]'
        [void]$dataSources.Add($Exception.Data)
        if ($Depth -eq 0 -and $null -ne $RootData) {
            [void]$dataSources.Add($RootData)
        }
        foreach ($dataSource in $dataSources) {
            foreach ($key in @($dataSource.Keys)) {
                if ($dataItemCount -ge $maximumDataItems) {
                    $data['AdditionalItemsOmitted'] = $true
                    break
                }
                $safeKey = & $toSafeText $key
                if ([string]::IsNullOrWhiteSpace($safeKey)) { continue }
                if ($safeKey -match '(?i)(?:password|passwd|pwd|credential|token|secret|authorization|cookie|api[-_]?key)') {
                    $data[$safeKey] = '<redacted>'
                }
                else {
                    $data[$safeKey] = & $convertDataValue $dataSource[$key] 0
                }
                $dataItemCount++
            }
            if ($dataItemCount -ge $maximumDataItems) { break }
        }
        $effectiveDisposition = $Disposition
        if ($data.Contains('Disposition') -and
            -not [string]::IsNullOrWhiteSpace([string]$data['Disposition'])) {
            $effectiveDisposition = [string]$data['Disposition']
        }
        $innerError = $null
        if ($null -ne $Exception.InnerException -and $Depth -lt $MaximumInnerDepth) {
            $innerError = & $buildIdentity $Exception.InnerException ($Depth + 1) '' '' $null
        }

        return [pscustomobject][ordered]@{
            Message               = & $toSafeText $Exception.Message
            ExceptionType         = [string]$Exception.GetType().FullName
            FullyQualifiedErrorId = & $toSafeText $FullyQualifiedErrorId
            Category              = & $toSafeText $Category
            Disposition           = $effectiveDisposition
            Data                  = [pscustomobject]$data
            InnerError            = $innerError
        }
    }

    try {
        return (& $buildIdentity `
            $ErrorRecord.Exception `
            0 `
            ([string]$ErrorRecord.FullyQualifiedErrorId) `
            ([string]$ErrorRecord.CategoryInfo.Category) `
            $AdditionalData)
    }
    catch {
        # Diagnostic enrichment must never replace the operational failure it
        # is trying to describe. Return a bounded, scalar fallback instead.
        return [pscustomobject][ordered]@{
            Message               = 'Error identity serialization failed.'
            ExceptionType         = [string]$ErrorRecord.Exception.GetType().FullName
            FullyQualifiedErrorId = ''
            Category              = ''
            Disposition           = $Disposition
            Data                  = [pscustomobject][ordered]@{}
            InnerError            = $null
        }
    }
}
