function Get-ServerImportTextEncoding {
    <# Detects Unicode BOMs and otherwise prefers strict UTF-8, with the local
       Windows code page retained only for legacy Excel CSV output. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    if ($Bytes.Length -ge 3 -and
        $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return New-Object System.Text.UTF8Encoding($true,$true)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false,$true)
    try {
        $null = $strictUtf8.GetString($Bytes)
        return $strictUtf8
    }
    catch [System.Text.DecoderFallbackException] {
        return [System.Text.Encoding]::Default
    }
}

function Read-ServerImportCsv {
    <# Uses the framework CSV parser so quoted records are handled correctly.
       The returned objects are still validated atomically before GUI update. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    $stream = $null
    $parser = $null
    $records = New-Object 'System.Collections.Generic.List[object]'
    $recordNumber = 0
    $dataRecordCount = 0
    try {
        # Hold one read-only stream for size check, encoding detection, and CSV
        # parsing so another process cannot replace the file between those steps.
        $stream = [System.IO.File]::Open(
            $file.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        if ($stream.Length -gt $script:MaximumCsvImportBytes) {
            throw "CSV file '$($file.Name)' is $($stream.Length) bytes. The maximum supported CSV size is $($script:MaximumCsvImportBytes) bytes."
        }
        $bytes = New-Object byte[] ([int]$stream.Length)
        $bytesRead = 0
        while ($bytesRead -lt $bytes.Length) {
            $read = $stream.Read($bytes,$bytesRead,$bytes.Length - $bytesRead)
            if ($read -eq 0) { break }
            $bytesRead += $read
        }
        if ($bytesRead -ne $bytes.Length) {
            throw "CSV file '$($file.Name)' changed or ended while it was being read. No entries were imported."
        }
        $stream.Position = 0
        $encoding = Get-ServerImportTextEncoding -Bytes $bytes
        $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($stream,$encoding,$true,$true)
        $parser.TextFieldType = 'Delimited'
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false

        while (-not $parser.EndOfData) {
            $recordNumber++
            try {
                $fields = @($parser.ReadFields())
            }
            catch {
                throw "CSV record $recordNumber could not be read. Check its commas and quotation marks. $($_.Exception.Message)"
            }

            if ($fields.Count -eq 0 -or
                @($fields | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -eq 0) {
                continue
            }
            if ($fields.Count -ne 2) {
                throw "CSV record $recordNumber contains $($fields.Count) fields. Every non-empty record must contain exactly two fields: ServerName,IPAddress."
            }

            $isHeader = ($records.Count -eq 0 -and
                (Test-ServerImportHeader -FirstValue ([string]$fields[0]) -SecondValue ([string]$fields[1])))
            if (-not $isHeader) {
                $dataRecordCount++
                if ($dataRecordCount -gt $script:MaximumBatchSize) {
                    throw "CSV file '$($file.Name)' contains more than $($script:MaximumBatchSize) server records. Split it into smaller files. No entries were imported."
                }
            }

            [void]$records.Add([pscustomobject]@{
                    Location   = "CSV record $recordNumber"
                    ServerName = [string]$fields[0]
                    IPAddress  = [string]$fields[1]
                })
        }
    }
    finally {
        if ($null -ne $parser) {
            $parser.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    return [object[]]$records.ToArray()
}
