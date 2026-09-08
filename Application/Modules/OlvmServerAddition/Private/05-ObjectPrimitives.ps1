function Get-FirstPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $InputObject) { return $null }
    foreach ($name in $Names) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) { continue }
        if ($property.Value -is [string] -and
            [string]::IsNullOrWhiteSpace([string]$property.Value)) { continue }
        return $property.Value
    }
    return $null
}

function ConvertTo-StrictBoolean {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim()
    switch -Regex ($text) {
        '^(?i:true|1|yes|enabled)$' { return $true }
        '^(?i:false|0|no|disabled)$' { return $false }
        default { throw "$Description returned unsupported boolean value '$text'." }
    }
}
