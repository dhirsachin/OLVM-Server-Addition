function Test-PathWithinRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    if ($fullPath.Equals($fullRoot,[System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $fullPath.StartsWith(
        $fullRoot + $separator,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-','').ToLowerInvariant()
    }
    finally {
        if ($null -ne $sha256) { $sha256.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-TrustedModuleRoots {
    <# Derives module roots from Windows APIs, never from mutable PSModulePath. #>
    [CmdletBinding()]
    param([switch]$IncludeProgramFiles)

    $roots = New-Object 'System.Collections.Generic.List[string]'
    $windowsRoot = [Environment]::GetFolderPath('Windows')
    foreach ($candidate in @(
            (Join-Path $windowsRoot 'System32\WindowsPowerShell\v1.0\Modules'),
            (Join-Path $PSHOME 'Modules')
        )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            [System.IO.Directory]::Exists($candidate) -and
            $roots -inotcontains $candidate) {
            [void]$roots.Add([System.IO.Path]::GetFullPath($candidate))
        }
    }
    if ($IncludeProgramFiles) {
        $programFilesRoot = [Environment]::GetFolderPath('ProgramFiles')
        if (-not [string]::IsNullOrWhiteSpace($programFilesRoot)) {
            $candidate = Join-Path $programFilesRoot 'WindowsPowerShell\Modules'
            if ([System.IO.Directory]::Exists($candidate) -and $roots -inotcontains $candidate) {
                [void]$roots.Add([System.IO.Path]::GetFullPath($candidate))
            }
        }
    }
    if ($roots.Count -eq 0) {
        throw 'No trusted Windows PowerShell module root could be resolved from the operating system.'
    }
    return [string[]]$roots.ToArray()
}

function Test-PathWithinAnyRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Roots
    )

    foreach ($root in $Roots) {
        if (Test-PathWithinRoot -Path $Path -Root $root) { return $true }
    }
    return $false
}

function Import-TrustedModule {
    <#
      Selects the newest module only after filtering to OS/Program Files roots,
      rejects reparse points, imports by exact path, and logs its file hash.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$AllowedRoots
    )

    foreach ($loaded in @(Get-Module -Name $Name)) {
        if ([string]::IsNullOrWhiteSpace([string]$loaded.Path) -or
            -not (Test-PathWithinAnyRoot -Path ([string]$loaded.Path) -Roots $AllowedRoots)) {
            throw "Module '$Name' was already loaded from untrusted path '$($loaded.Path)'. Close this PowerShell process and start the tool in a clean administrative Windows PowerShell 5.1 session."
        }
        Assert-PathHasNoReparsePoint -Path ([string]$loaded.Path) -BoundaryDescription "Loaded module '$Name'"
    }

    $previousModulePath = $env:PSModulePath
    try {
        # Constrain both discovery and manifest RequiredModules resolution so
        # neither can fall back to a user-writable PSModulePath entry.
        $env:PSModulePath = $AllowedRoots -join [System.IO.Path]::PathSeparator
        $candidates = @(Get-Module -ListAvailable -Name $Name | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.Path) -and
                [System.IO.File]::Exists([string]$_.Path) -and
                (Test-PathWithinAnyRoot -Path ([string]$_.Path) -Roots $AllowedRoots)
            } | Sort-Object Version -Descending)
        if ($candidates.Count -eq 0) {
            throw "Required module '$Name' was not found under a trusted Windows or Program Files module root."
        }

        $highestVersion = $candidates[0].Version
        $highestVersionCandidates = @($candidates | Where-Object { $_.Version -eq $highestVersion })
        if ($highestVersionCandidates.Count -ne 1) {
            $ambiguousPaths = @($highestVersionCandidates | ForEach-Object { [string]$_.Path }) -join '; '
            throw "Required module '$Name' version '$highestVersion' is ambiguous across trusted roots ('$ambiguousPaths'). Remove the duplicate or start from the approved installation path."
        }

        $candidate = $highestVersionCandidates[0]
        $candidatePath = [System.IO.Path]::GetFullPath([string]$candidate.Path)
        $candidateModuleBase = if ([string]::IsNullOrWhiteSpace([string]$candidate.ModuleBase)) {
            [System.IO.Path]::GetDirectoryName($candidatePath)
        }
        else {
            [System.IO.Path]::GetFullPath([string]$candidate.ModuleBase)
        }
        Assert-PathHasNoReparsePoint -Path $candidatePath -BoundaryDescription "Module '$Name'"
        $hashBeforeImport = Get-FileSha256 -Path $candidatePath

        # A manifest import can report the loaded root .psm1/.dll in Path
        # instead of the .psd1 used for Import-Module. ModuleBase, name, and
        # version provide the stable manifest identity; the actual loaded file
        # must additionally remain inside that exact trusted base directory.
        $matchesCandidateIdentity = {
            param([System.Management.Automation.PSModuleInfo]$Module)

            if ($null -eq $Module -or
                $Module.Name -ine $Name -or
                $Module.Version -ne $highestVersion -or
                [string]::IsNullOrWhiteSpace([string]$Module.ModuleBase) -or
                [string]::IsNullOrWhiteSpace([string]$Module.Path)) {
                return $false
            }
            try {
                $loadedBase = [System.IO.Path]::GetFullPath([string]$Module.ModuleBase)
                $loadedPath = [System.IO.Path]::GetFullPath([string]$Module.Path)
                return ($loadedBase.Equals(
                        $candidateModuleBase,
                        [System.StringComparison]::OrdinalIgnoreCase
                    ) -and
                    [System.IO.File]::Exists($loadedPath) -and
                    (Test-PathWithinRoot -Path $loadedPath -Root $candidateModuleBase) -and
                    (Test-PathWithinAnyRoot -Path $loadedPath -Roots $AllowedRoots))
            }
            catch {
                return $false
            }
        }

        # Do not allow two trusted-but-different versions of the same module
        # to coexist. Command resolution must remain deterministic for the
        # entire GUI session.
        $loadedBeforeImport = @(Get-Module -Name $Name)
        $loadedExact = @($loadedBeforeImport | Where-Object {
                & $matchesCandidateIdentity $_
            })
        if ($loadedBeforeImport.Count -ne $loadedExact.Count) {
            $otherPaths = @($loadedBeforeImport | Where-Object {
                    -not (& $matchesCandidateIdentity $_)
                } | ForEach-Object {
                    "Name=$($_.Name), Version=$($_.Version), ModuleBase=$($_.ModuleBase), Path=$($_.Path)"
                }) -join '; '
            throw "Module '$Name' is already loaded from a different trusted path or version ('$otherPaths'). Close this PowerShell process and start the tool in a clean session."
        }
        if ($loadedExact.Count -gt 1) {
            throw "Module '$Name' is loaded more than once from trusted base '$candidateModuleBase'. Close this PowerShell process and start the tool in a clean session."
        }
        if ($loadedExact.Count -eq 0) {
            $null = Import-Module -Name $candidatePath -DisableNameChecking -PassThru -ErrorAction Stop
        }
    }
    finally {
        $env:PSModulePath = $previousModulePath
    }
    $loadedMatches = @(Get-Module -Name $Name | Where-Object {
            & $matchesCandidateIdentity $_
        })
    if ($loadedMatches.Count -ne 1) {
        $observedModules = @(Get-Module -Name $Name | ForEach-Object {
                "Name=$($_.Name), Version=$($_.Version), ModuleBase=$($_.ModuleBase), Path=$($_.Path)"
            }) -join '; '
        throw "Exact-path import of module '$Name' did not produce exactly one trusted module identity for manifest '$candidatePath'. Observed: $observedModules"
    }
    $loadedModule = $loadedMatches[0]
    Assert-PathHasNoReparsePoint -Path ([string]$loadedModule.Path) -BoundaryDescription "Loaded module '$Name'"
    $hashAfterImport = Get-FileSha256 -Path $candidatePath
    if ($hashAfterImport -cne $hashBeforeImport) {
        throw "Module '$Name' changed while it was being imported. Close the tool and investigate '$candidatePath'."
    }
    $loadedFileHash = Get-FileSha256 -Path ([string]$loadedModule.Path)
    Write-RunLog -Level SUCCESS -Stage 'Dependency trust' -Message "Loaded trusted module '$Name' version '$($loadedModule.Version)' from manifest '$candidatePath'; ModuleBase='$candidateModuleBase'; LoadedPath='$($loadedModule.Path)'; ManifestSHA256=$hashAfterImport; LoadedFileSHA256=$loadedFileHash."
    return $loadedModule
}

function Assert-CommandProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [string[]]$AllowedModuleNames = @(),
        [string[]]$AllowedSnapInNames = @()
    )

    foreach ($name in $Names) {
        $command = Get-Command -Name $name -ErrorAction Stop | Select-Object -First 1
        if ($command.CommandType -notin @(
                [System.Management.Automation.CommandTypes]::Function,
                [System.Management.Automation.CommandTypes]::Cmdlet
            )) {
            throw "Command '$name' resolved to unsupported command type '$($command.CommandType)'. Restart in a clean session and correct the dependency installation."
        }
        $moduleName = [string]$command.ModuleName
        $snapInProperty = $command.PSObject.Properties['PSSnapIn']
        $snapInName = if ($null -ne $snapInProperty -and $null -ne $snapInProperty.Value) {
            [string]$snapInProperty.Value.Name
        }
        else { '' }
        if ($moduleName -notin $AllowedModuleNames -and $snapInName -notin $AllowedSnapInNames) {
            throw "Command '$name' resolved to unapproved source '$($command.Source)' (module '$moduleName', snap-in '$snapInName'). Restart in a clean session and correct the dependency installation."
        }
    }
}

function Assert-InfrastructureCommandProvenance {
    [CmdletBinding()]
    param()

    Assert-CommandProvenance -Names @(
        'Set-PvsConnection','Get-PvsCollection','Get-PvsServer','Get-PvsDevice',
        'New-PvsDevice','Get-PvsADAccount','Add-PvsDeviceToDomain',
        'Get-PvsStore','Get-PvsDiskInfo','Get-PvsDiskLocator','Get-PvsDiskVersion',
        'Get-PvsDiskInventory','Get-PvsDeviceDiskLocatorEnabled','Add-PvsDiskLocatorToDevice',
        'Get-PvsDevicePersonality','Set-PvsDevicePersonality'
    ) -AllowedSnapInNames @('Citrix.PVS.SnapIn')
    Assert-CommandProvenance -Names @(
        'Get-DhcpServerv4Scope','Get-DhcpServerv4Lease','Get-DhcpServerv4Reservation',
        'Add-DhcpServerv4Reservation',
        'Get-DhcpServerv4OptionDefinition','Get-DhcpServerv4OptionValue',
        'Set-DhcpServerv4OptionValue'
    ) -AllowedModuleNames @('DhcpServer')
    Assert-CommandProvenance -Names @('Resolve-DnsName') -AllowedModuleNames @('DnsClient')
}

function Assert-OlvmCommandProvenance {
    [CmdletBinding()]
    param()

    Assert-CommandProvenance -Names @(
        'Pull-PVSConfiguration','Export-WorkingPVSConfiguration',
        'New-OLVMCredentialObject','Connect-oVirtServer',
        'Find-CTxOLVMHost','Get-oVM','Get-oVmNic'
    ) -AllowedModuleNames @('PVSImageMan','CWxPVS','Posh-oVirt')
}
