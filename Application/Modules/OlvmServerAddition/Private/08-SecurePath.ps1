function Assert-PathHasNoReparsePoint {
    <# Refuses junctions/symlinks at privileged file and module boundaries. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BoundaryDescription
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$BoundaryDescription contains reparse point '$($item.FullName)'. The tool refuses redirected privileged paths."
        }
        if ($item -is [System.IO.DirectoryInfo]) {
            $item = $item.Parent
        }
        elseif ($item -is [System.IO.FileInfo]) {
            $item = $item.Directory
        }
        else {
            throw "$BoundaryDescription contains unsupported filesystem object '$($item.FullName)'."
        }
    }
}
