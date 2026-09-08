function Get-XlsxArchiveEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Archive,

        [Parameter(Mandatory = $true)]
        [string]$EntryName,

        [switch]$Required
    )

    $matches = @($Archive.Entries | Where-Object {
            $_.FullName.Equals($EntryName, [System.StringComparison]::OrdinalIgnoreCase)
        })
    if ($matches.Count -gt 1) {
        throw "The Excel workbook contains more than one package entry named '$EntryName'. Save it as a new .xlsx file and retry."
    }
    if ($matches.Count -eq 0) {
        if ($Required) {
            throw "The Excel workbook is missing required component '$EntryName'. Save it as a new, unencrypted .xlsx file and retry."
        }
        return $null
    }
    return $matches[0]
}

function Assert-XlsxImportXmlBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Archive,

        [Parameter(Mandatory = $true)]
        [string[]]$EntryNames
    )

    $totalBytes = [long]0
    $seenEntries = @{}
    foreach ($entryName in $EntryNames) {
        $key = $entryName.ToLowerInvariant()
        if ($seenEntries.ContainsKey($key)) { continue }
        $seenEntries[$key] = $true
        $entry = Get-XlsxArchiveEntry -Archive $Archive -EntryName $entryName
        if ($null -ne $entry) {
            $totalBytes += [long]$entry.Length
        }
    }
    if ($totalBytes -gt $script:MaximumXlsxXmlCharacters) {
        throw "The Excel components required for this import expand to $totalBytes bytes. The aggregate supported XML limit is $($script:MaximumXlsxXmlCharacters) bytes."
    }
}

function Read-SafeXlsxXmlDocument {
    <# Reads XML directly from the package without extracting files. DTDs,
       external resolution, oversized entries, and duplicate paths are blocked. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Archive,

        [Parameter(Mandatory = $true)]
        [string]$EntryName,

        [switch]$Required
    )

    $entry = Get-XlsxArchiveEntry -Archive $Archive -EntryName $EntryName -Required:$Required
    if ($null -eq $entry) {
        return $null
    }
    if ($entry.Length -gt $script:MaximumXlsxXmlCharacters) {
        throw "Excel component '$EntryName' expands to $($entry.Length) bytes. The supported limit is $($script:MaximumXlsxXmlCharacters) bytes."
    }

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersInDocument = [long]$script:MaximumXlsxXmlCharacters
    $stream = $null
    $reader = $null
    try {
        $stream = $entry.Open()
        $reader = [System.Xml.XmlReader]::Create($stream,$settings)
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
        return $document
    }
    catch {
        throw "Excel component '$EntryName' contains invalid or unsupported XML. $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Resolve-XlsxWorksheetEntryName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlElement]$Relationship
    )

    $targetMode = $Relationship.GetAttribute('TargetMode')
    if ($targetMode -and -not $targetMode.Equals('Internal', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'External Excel worksheet relationships are not supported.'
    }
    $target = $Relationship.GetAttribute('Target')
    if ([string]::IsNullOrWhiteSpace($target) -or $target.Contains('\')) {
        throw 'The Excel workbook contains an invalid worksheet relationship target.'
    }

    try {
        $baseUri = [System.Uri]::new('https://package.invalid/xl/workbook.xml')
        $resolvedUri = [System.Uri]::new($baseUri,$target)
    }
    catch {
        throw "The Excel worksheet relationship target '$target' is invalid."
    }
    if (-not $resolvedUri.Scheme.Equals('https', [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $resolvedUri.Host.Equals('package.invalid', [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::IsNullOrEmpty($resolvedUri.Query) -or
        -not [string]::IsNullOrEmpty($resolvedUri.Fragment)) {
        throw "The Excel worksheet relationship target '$target' is external or unsupported."
    }

    $entryName = [System.Uri]::UnescapeDataString($resolvedUri.AbsolutePath.TrimStart('/'))
    $segments = @($entryName.Split('/'))
    if (-not $entryName.StartsWith('xl/', [System.StringComparison]::OrdinalIgnoreCase) -or
        $segments.Count -lt 2 -or
        @($segments | Where-Object { $_ -in @('','.','..') }).Count -gt 0) {
        throw "The Excel worksheet relationship target '$target' resolves outside the workbook package."
    }
    return $entryName
}

function Get-XlsxWorksheetCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Archive
    )

    $workbook = Read-SafeXlsxXmlDocument -Archive $Archive -EntryName 'xl/workbook.xml' -Required
    $relationships = Read-SafeXlsxXmlDocument -Archive $Archive -EntryName 'xl/_rels/workbook.xml.rels' -Required
    $relationshipMap = @{}
    $relationshipTypes = @{}
    foreach ($relationship in @($relationships.SelectNodes("//*[local-name()='Relationship']"))) {
        $id = $relationship.GetAttribute('Id')
        $type = $relationship.GetAttribute('Type')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($relationshipTypes.ContainsKey($id)) {
            throw "The Excel workbook contains duplicate relationship '$id'."
        }
        $relationshipTypes[$id] = $type
        if ($type -match '/worksheet$') {
            $relationshipMap[$id] = Resolve-XlsxWorksheetEntryName -Relationship $relationship
        }
    }

    $catalog = New-Object 'System.Collections.Generic.List[object]'
    foreach ($sheet in @($workbook.SelectNodes("//*[local-name()='sheets']/*[local-name()='sheet']"))) {
        $state = $sheet.GetAttribute('state')
        if ($state -and -not $state.Equals('visible', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $name = $sheet.GetAttribute('name')
        $idAttribute = @($sheet.Attributes | Where-Object { $_.LocalName -eq 'id' } | Select-Object -First 1)
        $relationshipId = if ($idAttribute.Count -eq 1) { [string]$idAttribute[0].Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($name) -or
            [string]::IsNullOrWhiteSpace($relationshipId) -or
            -not $relationshipTypes.ContainsKey($relationshipId)) {
            throw 'The Excel workbook contains an invalid visible worksheet definition.'
        }
        # Chart sheets and other visible non-worksheet sheet types cannot hold
        # the A/B server table and are intentionally omitted from the picker.
        if ($relationshipTypes[$relationshipId] -notmatch '/worksheet$') {
            continue
        }
        if (-not $relationshipMap.ContainsKey($relationshipId)) {
            throw 'The Excel workbook contains an invalid worksheet relationship.'
        }
        $entryName = [string]$relationshipMap[$relationshipId]
        $null = Get-XlsxArchiveEntry -Archive $Archive -EntryName $entryName -Required
        [void]$catalog.Add([pscustomobject]@{
                Name      = $name
                EntryName = $entryName
            })
    }
    if ($catalog.Count -eq 0) {
        throw 'The Excel workbook does not contain a visible worksheet that can hold server names and IPv4 addresses.'
    }
    return [object[]]$catalog.ToArray()
}

function Get-XlsxSharedStrings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Archive
    )

    $document = Read-SafeXlsxXmlDocument -Archive $Archive -EntryName 'xl/sharedStrings.xml'
    if ($null -eq $document) {
        return [string[]]@()
    }

    $values = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @($document.SelectNodes("/*[local-name()='sst']/*[local-name()='si']"))) {
        $textNodes = @($item.SelectNodes("./*[local-name()='t'] | ./*[local-name()='r']/*[local-name()='t']"))
        [void]$values.Add([string]::Join('', [string[]]@($textNodes | ForEach-Object { $_.InnerText })))
    }
    return [string[]]$values.ToArray()
}

function Get-XlsxCellText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlElement]$Cell,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$SharedStrings,

        [Parameter(Mandatory = $true)]
        [string]$WorksheetName
    )

    $cellReference = $Cell.GetAttribute('r')
    if ($null -ne $Cell.SelectSingleNode("./*[local-name()='f']")) {
        throw "Worksheet '$WorksheetName', cell '$cellReference' contains a formula. Replace formulas in columns A and B with values, save the workbook, and retry."
    }

    $cellType = $Cell.GetAttribute('t')
    if ($cellType -eq 'e') {
        throw "Worksheet '$WorksheetName', cell '$cellReference' contains an Excel error value. Replace it with a server name or IPv4 address and retry."
    }
    if ($cellType -eq 'inlineStr') {
        $textNodes = @($Cell.SelectNodes("./*[local-name()='is']/*[local-name()='t'] | ./*[local-name()='is']/*[local-name()='r']/*[local-name()='t']"))
        return [string]::Join('', [string[]]@($textNodes | ForEach-Object { $_.InnerText }))
    }

    $valueNode = $Cell.SelectSingleNode("./*[local-name()='v']")
    $rawValue = if ($null -eq $valueNode) { '' } else { [string]$valueNode.InnerText }
    if ($cellType -eq 's') {
        $sharedIndex = 0
        if (-not [int]::TryParse(
                $rawValue,
                [System.Globalization.NumberStyles]::Integer,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$sharedIndex) -or
            $sharedIndex -lt 0 -or $sharedIndex -ge $SharedStrings.Count) {
            throw "Worksheet '$WorksheetName', cell '$cellReference' contains an invalid shared-string reference."
        }
        return [string]$SharedStrings[$sharedIndex]
    }
    if ([string]::IsNullOrWhiteSpace($cellType) -or
        $cellType -in @('n','str','b','d')) {
        return $rawValue
    }
    throw "Worksheet '$WorksheetName', cell '$cellReference' uses unsupported Excel cell type '$cellType'."
}

function Get-XlsxColumnNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Letters
    )

    $column = 0
    foreach ($character in $Letters.ToUpperInvariant().ToCharArray()) {
        if ($character -lt 'A' -or $character -gt 'Z') {
            throw "Excel column reference '$Letters' is invalid."
        }
        $column = ($column * 26) + ([int]$character - [int][char]'A' + 1)
    }
    return $column
}

function Assert-XlsxRequiredColumnsAreNotMerged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Xml.XmlDocument]$Worksheet,

        [Parameter(Mandatory = $true)]
        [string]$WorksheetName
    )

    foreach ($mergeCell in @($Worksheet.SelectNodes("//*[local-name()='mergeCells']/*[local-name()='mergeCell']"))) {
        $reference = $mergeCell.GetAttribute('ref') -replace '\$',''
        $endpoints = @($reference.Split(':'))
        if ($endpoints.Count -notin @(1,2) -or
            $endpoints[0] -notmatch '^([A-Za-z]+)[1-9][0-9]*$' -or
            $endpoints[-1] -notmatch '^([A-Za-z]+)[1-9][0-9]*$') {
            throw "Worksheet '$WorksheetName' contains invalid merged-cell reference '$reference'."
        }
        $firstColumn = Get-XlsxColumnNumber -Letters ([regex]::Match($endpoints[0], '^[A-Za-z]+').Value)
        $lastColumn = Get-XlsxColumnNumber -Letters ([regex]::Match($endpoints[-1], '^[A-Za-z]+').Value)
        $minimumColumn = [math]::Min($firstColumn,$lastColumn)
        $maximumColumn = [math]::Max($firstColumn,$lastColumn)
        if ($minimumColumn -le 2 -and $maximumColumn -ge 1) {
            throw "Worksheet '$WorksheetName' has merged cells '$reference' in columns A or B. Unmerge those cells, save the workbook, and retry."
        }
    }
}

function Read-ServerImportXlsx {
    <# Reads columns A and B from a selected visible worksheet using only .NET
       Open XML/ZIP support. Excel, COM, ACE, and third-party modules are not used. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$WorksheetName
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.Length -gt $script:MaximumXlsxImportBytes) {
        throw "Excel file '$($file.Name)' is $($file.Length) bytes. The maximum supported .xlsx size is $($script:MaximumXlsxImportBytes) bytes."
    }

    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem -ErrorAction Stop
    $archive = $null
    try {
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($file.FullName)
        }
        catch {
            throw "Excel file '$($file.Name)' could not be opened as a standard, unencrypted .xlsx workbook. Save it as a new .xlsx file or CSV and retry. $($_.Exception.Message)"
        }
        if ($archive.Entries.Count -gt $script:MaximumXlsxEntryCount) {
            throw "Excel file '$($file.Name)' contains $($archive.Entries.Count) package entries. The supported limit is $($script:MaximumXlsxEntryCount)."
        }
        Assert-XlsxImportXmlBudget -Archive $archive -EntryNames @(
            'xl/workbook.xml',
            'xl/_rels/workbook.xml.rels'
        )

        $catalog = @(Get-XlsxWorksheetCatalog -Archive $archive)
        if ([string]::IsNullOrWhiteSpace($WorksheetName) -and $catalog.Count -gt 1) {
            return [pscustomobject]@{
                RequiresWorksheetSelection = $true
                WorksheetNames             = [string[]]@($catalog.Name)
                WorksheetName              = $null
                Records                    = @()
            }
        }

        $selectedSheet = if ([string]::IsNullOrWhiteSpace($WorksheetName)) {
            $catalog[0]
        }
        else {
            @($catalog | Where-Object { $_.Name.Equals($WorksheetName, [System.StringComparison]::Ordinal) } | Select-Object -First 1)
        }
        if ($null -eq $selectedSheet -or @($selectedSheet).Count -eq 0) {
            throw "Worksheet '$WorksheetName' was not found among the visible worksheets in '$($file.Name)'."
        }
        if ($selectedSheet -is [array]) { $selectedSheet = $selectedSheet[0] }

        Assert-XlsxImportXmlBudget -Archive $archive -EntryNames @(
            'xl/workbook.xml',
            'xl/_rels/workbook.xml.rels',
            'xl/sharedStrings.xml',
            [string]$selectedSheet.EntryName
        )
        $sharedStrings = [string[]]@(Get-XlsxSharedStrings -Archive $archive)
        $worksheet = Read-SafeXlsxXmlDocument -Archive $archive -EntryName $selectedSheet.EntryName -Required
        Assert-XlsxRequiredColumnsAreNotMerged -Worksheet $worksheet -WorksheetName $selectedSheet.Name

        $records = New-Object 'System.Collections.Generic.List[object]'
        $fallbackRowNumber = 0
        $dataRecordCount = 0
        foreach ($row in @($worksheet.SelectNodes("//*[local-name()='sheetData']/*[local-name()='row']"))) {
            $fallbackRowNumber++
            $rowNumber = $null
            $rowReference = $row.GetAttribute('r')
            if ($rowReference) {
                $parsedRowNumber = 0
                if (-not [int]::TryParse($rowReference,[ref]$parsedRowNumber) -or $parsedRowNumber -lt 1) {
                    throw "Worksheet '$($selectedSheet.Name)' contains invalid row reference '$rowReference'."
                }
                $rowNumber = $parsedRowNumber
            }

            $values = @('','')
            $present = @($false,$false)
            foreach ($cell in @($row.SelectNodes("./*[local-name()='c']"))) {
                $cellReference = $cell.GetAttribute('r') -replace '\$',''
                if ($cellReference -notmatch '^([A-Za-z]+)([1-9][0-9]*)$') {
                    throw "Worksheet '$($selectedSheet.Name)' contains a cell without a valid reference."
                }
                $cellRowNumber = [int]$matches[2]
                if ($null -eq $rowNumber) {
                    # The row index is optional in Open XML; when omitted, the
                    # first cell reference becomes authoritative for this row.
                    $rowNumber = $cellRowNumber
                }
                elseif ($cellRowNumber -ne $rowNumber) {
                    throw "Worksheet '$($selectedSheet.Name)' contains cell '$cellReference' inside row '$rowNumber'. Cell and row references must agree."
                }
                $column = Get-XlsxColumnNumber -Letters $matches[1]
                if ($column -gt 2) { continue }
                if ($present[$column - 1]) {
                    throw "Worksheet '$($selectedSheet.Name)' contains duplicate cell '$cellReference'."
                }
                $present[$column - 1] = $true
                $values[$column - 1] = Get-XlsxCellText -Cell $cell -SharedStrings $sharedStrings -WorksheetName $selectedSheet.Name
            }

            if ($null -eq $rowNumber) {
                $rowNumber = $fallbackRowNumber
            }

            if ([string]::IsNullOrWhiteSpace([string]$values[0]) -and
                [string]::IsNullOrWhiteSpace([string]$values[1])) {
                continue
            }
            $isHeader = ($records.Count -eq 0 -and
                (Test-ServerImportHeader -FirstValue ([string]$values[0]) -SecondValue ([string]$values[1])))
            if (-not $isHeader) {
                $dataRecordCount++
                if ($dataRecordCount -gt $script:MaximumBatchSize) {
                    throw "Excel file '$($file.Name)', worksheet '$($selectedSheet.Name)' contains more than $($script:MaximumBatchSize) server records. Split it into smaller files. No entries were imported."
                }
            }
            [void]$records.Add([pscustomobject]@{
                    Location   = "Worksheet '$($selectedSheet.Name)', row $rowNumber"
                    ServerName = [string]$values[0]
                    IPAddress  = [string]$values[1]
                })
        }

        return [pscustomobject]@{
            RequiresWorksheetSelection = $false
            WorksheetNames             = [string[]]@($catalog.Name)
            WorksheetName              = [string]$selectedSheet.Name
            Records                    = [object[]]$records.ToArray()
        }
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}
