function Assert-FarmBuildLockOwned {
    [CmdletBinding()]
    param()

    if ($null -eq $script:ActiveFarmBuildLock -or
        $null -eq $script:ActiveFarmBuildLock.Stream -or
        -not $script:ActiveFarmBuildLock.Stream.CanWrite) {
        throw 'The farm-wide Build lock is no longer owned. No additional infrastructure write is permitted.'
    }
    try {
        $script:ActiveFarmBuildLock.Stream.Flush($true)
    }
    catch {
        throw "The farm-wide Build lock handle failed its ownership I/O check. No additional infrastructure write is permitted. $($_.Exception.Message)"
    }
}
