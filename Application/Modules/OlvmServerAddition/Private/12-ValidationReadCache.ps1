function New-PreviewReadCache {
    <#
      Preview is a point-in-time, read-only assessment. Its cache is created
      inside Invoke-Preview and is never stored in script or provisioning
      state. Each manual Validation starts with a fresh cache; Build consumes
      only the retained action plan and never repeats this cache-backed pass.
    #>
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        Entries  = @{}
        Hits     = 0
        Misses   = 0
        Failures = 0
    }
}

function Get-PreviewCacheSnapshot {
    <#
      Returns one cache envelope rather than the cached values directly. This
      preserves the important distinction between a successful empty result
      and a failed query. Failed reads are cached and rethrown for every row
      that depends on them; infrastructure errors are never treated as absence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Cache,

        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [string]$Operation,

        [string]$MachineName = '-',

        [string]$Endpoint = '-',

        [Parameter(Mandatory = $true)]
        [scriptblock]$Loader
    )

    if ($null -eq $Cache.Entries -or $Cache.Entries -isnot [hashtable]) {
        throw 'The Validation read cache is invalid.'
    }

    if ($Cache.Entries.ContainsKey($Key)) {
        $Cache.Hits++
        $cachedEntry = $Cache.Entries[$Key]
        if (-not $cachedEntry.Success) {
            throw [System.InvalidOperationException]::new([string]$cachedEntry.ErrorMessage)
        }
        return $cachedEntry
    }

    $Cache.Misses++
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = 'Failed'
    try {
        $values = @(& $Loader)
        $entry = [pscustomobject]@{
            Success      = $true
            Value        = [object[]]$values
            ErrorMessage = $null
        }
        $Cache.Entries[$Key] = $entry
        $outcome = 'Succeeded'
        return $entry
    }
    catch {
        $Cache.Failures++
        $errorMessage = [string]$_.Exception.Message
        $failedEntry = [pscustomobject]@{
            Success      = $false
            Value        = [object[]]@()
            ErrorMessage = $errorMessage
        }
        $Cache.Entries[$Key] = $failedEntry
        throw
    }
    finally {
        Write-StageTiming `
            -Timer $timer `
            -Phase $Phase `
            -Operation $Operation `
            -Outcome $outcome `
            -MachineName $MachineName `
            -Endpoint $Endpoint `
            -Source 'CacheMiss'
    }
}
