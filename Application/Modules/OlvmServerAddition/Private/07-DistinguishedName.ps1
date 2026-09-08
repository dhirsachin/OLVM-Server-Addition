function Trim-LdapComponentWhitespace {
    <# Removes formatting whitespace but preserves an RFC4514 escaped final space. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $result = $Value.TrimStart()
    while ($result.Length -gt 0 -and [char]::IsWhiteSpace($result[$result.Length - 1])) {
        $backslashCount = 0
        for ($index = $result.Length - 2; $index -ge 0 -and $result[$index] -eq '\'; $index--) {
            $backslashCount++
        }
        if (($backslashCount % 2) -eq 1) {
            break
        }
        $result = $result.Substring(0, $result.Length - 1)
    }
    return $result
}

function Split-LdapDistinguishedName {
    <# Splits only unescaped commas, so names such as OU=Team\, East remain intact. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistinguishedName
    )

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $current = New-Object System.Text.StringBuilder
    $escaped = $false

    foreach ($character in $DistinguishedName.ToCharArray()) {
        if ($character -eq ',' -and -not $escaped) {
            $part = Trim-LdapComponentWhitespace -Value $current.ToString()
            if ($part.Length -eq 0) {
                throw "Invalid distinguished name: '$DistinguishedName'."
            }
            [void]$parts.Add($part)
            [void]$current.Clear()
            continue
        }

        [void]$current.Append($character)
        if ($character -eq '\' -and -not $escaped) {
            $escaped = $true
        }
        else {
            $escaped = $false
        }
    }

    if ($escaped) {
        throw "Invalid distinguished name with an incomplete escape sequence: '$DistinguishedName'."
    }

    $lastPart = Trim-LdapComponentWhitespace -Value $current.ToString()
    if ($lastPart.Length -eq 0) {
        throw "Invalid distinguished name: '$DistinguishedName'."
    }
    [void]$parts.Add($lastPart)

    # ToArray avoids a Windows PowerShell 5.1 binder issue with generic lists.
    return [string[]]$parts.ToArray()
}

function Test-DistinguishedNameEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$First,

        [Parameter(Mandatory = $true)]
        [string]$Second
    )

    $normalizedFirst = (@(Split-LdapDistinguishedName -DistinguishedName $First) |
        ForEach-Object { $_.Trim() }) -join ','
    $normalizedSecond = (@(Split-LdapDistinguishedName -DistinguishedName $Second) |
        ForEach-Object { $_.Trim() }) -join ','
    return $normalizedFirst.Equals($normalizedSecond, [System.StringComparison]::OrdinalIgnoreCase)
}
