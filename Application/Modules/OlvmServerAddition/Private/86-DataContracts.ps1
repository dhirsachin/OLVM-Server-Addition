function Set-ValidationBuildState {
    <# Owns updates to the canonical Validation records and retained Build contexts. #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$ValidationRecords,

        [AllowNull()]
        [object[]]$BuildContexts
    )

    if ($PSBoundParameters.ContainsKey('ValidationRecords')) {
        $script:ValidationRecords = $ValidationRecords
        $script:Record = $script:ValidationRecords
    }
    if ($PSBoundParameters.ContainsKey('BuildContexts')) {
        $script:BuildContexts = $BuildContexts
        $script:ProvisionContext = $script:BuildContexts
    }
}

function Get-ValidationBuildState {
    <# Returns the canonical workflow snapshots while honoring legacy alias writes. #>
    [CmdletBinding()]
    param()

    $canonicalRecords = Get-Variable -Name ValidationRecords -Scope Script -ErrorAction SilentlyContinue
    $legacyRecords = Get-Variable -Name Record -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $legacyRecords -and
        ($null -eq $canonicalRecords -or
            -not [object]::ReferenceEquals($canonicalRecords.Value,$legacyRecords.Value))) {
        $script:ValidationRecords = $legacyRecords.Value
    }
    elseif ($null -eq $canonicalRecords) {
        $script:ValidationRecords = [object[]]@()
    }
    $script:Record = $script:ValidationRecords

    $canonicalContexts = Get-Variable -Name BuildContexts -Scope Script -ErrorAction SilentlyContinue
    $legacyContexts = Get-Variable -Name ProvisionContext -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $legacyContexts -and
        ($null -eq $canonicalContexts -or
            -not [object]::ReferenceEquals($canonicalContexts.Value,$legacyContexts.Value))) {
        $script:BuildContexts = $legacyContexts.Value
    }
    elseif ($null -eq $canonicalContexts) {
        $script:BuildContexts = $null
    }
    $script:ProvisionContext = $script:BuildContexts

    return [pscustomobject][ordered]@{
        ValidationRecords = $script:ValidationRecords
        BuildContexts     = $script:BuildContexts
    }
}

function Assert-ExactPropertyContract {
    <# Validates only the ordered property-name contract; values remain workflow-owned. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ExpectedNames,

        [Parameter(Mandatory = $true)]
        [string]$ContractName
    )

    $actualNames = if ($null -eq $InputObject) {
        [string[]]@()
    }
    else {
        [string[]]@($InputObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
    }

    $isExact = ($actualNames.Count -eq $ExpectedNames.Count)
    if ($isExact) {
        for ($index = 0; $index -lt $ExpectedNames.Count; $index++) {
            if ($actualNames[$index] -cne $ExpectedNames[$index]) {
                $isExact = $false
                break
            }
        }
    }
    if (-not $isExact) {
        $expectedText = if ($ExpectedNames.Count -eq 0) { '<none>' } else { [string]::Join(', ', $ExpectedNames) }
        $actualText = if ($actualNames.Count -eq 0) { '<none>' } else { [string]::Join(', ', $actualNames) }
        throw "$ContractName has an invalid property contract. Expected ordered names: $expectedText. Actual ordered names: $actualText."
    }
}

function Assert-ValidationRecordContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject
    )

    Assert-ExactPropertyContract `
        -InputObject $InputObject `
        -ContractName 'Validation record' `
        -ExpectedNames @(
            'Line','MachineName','IPAddress','MacAddress','Fqdn','DhcpName',
            'PvsCollection','PvsImage','ConfiguredPvsImage','CurrentStreamedPvsImage',
            'OlvmVmStatus','RebootDay','ValidationOutcome','ValidationAdAction',
            'BuildAction','BuildStarted','AdBuildEvaluated','NonAdPrerequisitesEvaluated',
            'PowerRequested','PowerResult','PowerDetails','AdStatus','AdDetails',
            'NonAdPrerequisitesVerified','PowerOverrideEligible','PowerOverrideDecision',
            'PowerOverrideOperator','PowerOverrideTimestamp','Stage','Result','ActionSummary','Details'
        )
}

function Assert-BuildActionPlanContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject
    )

    Assert-ExactPropertyContract `
        -InputObject $InputObject `
        -ContractName 'Build action plan' `
        -ExpectedNames @('PvsTarget','Image','Personality','DhcpTargets','AdAccount')
}

function Assert-BuildContextContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject
    )

    Assert-ExactPropertyContract `
        -InputObject $InputObject `
        -ContractName 'Build context' `
        -ExpectedNames @(
            'Settings','Row','Record','Fqdn','RebootDay','ValidationId','ValidatedAtUtc',
            'Plan','HasWrites','ActionSummary','ValidationAdAction','ConfiguredPvsImage',
            'CurrentStreamedPvsImage','OlvmVmStatus','ExistingAdAccount','OlvmIdentity',
            'PowerRequestAttempted','PowerRequestSent','PersonalityOtherFingerprint',
            'DhcpServers','DhcpTargets','AdFailure','PowerOverrideApproved'
        )
    Assert-ValidationRecordContract -InputObject $InputObject.Record
    Assert-BuildActionPlanContract -InputObject $InputObject.Plan
}

function Assert-ReadyBuildContextSelectionContract {
    <#
        Proves that Build will consume only the exact, ordered Ready records
        retained by the most recent Validation. This is intentionally based on
        object identity rather than matching names or values so a stale,
        reconstructed, Blocked, or SkippedExisting record cannot reach a write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$ValidationRecords,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$BuildContexts
    )

    $records = [object[]]@($ValidationRecords)
    $contexts = [object[]]@($BuildContexts)
    foreach ($record in $records) {
        Assert-ValidationRecordContract -InputObject $record
        if ([string]$record.Result -cnotin @('Ready','Blocked','SkippedExisting')) {
            throw "The retained Validation record for '$($record.MachineName)' has unsupported result '$($record.Result)'."
        }
    }
    foreach ($context in $contexts) {
        Assert-BuildContextContract -InputObject $context
    }

    $readyRecords = [object[]]@($records | Where-Object { [string]$_.Result -ceq 'Ready' })
    if ($readyRecords.Count -eq 0) {
        throw 'The retained Validation contains no Ready server for Build.'
    }
    if ($contexts.Count -ne $readyRecords.Count) {
        throw "The retained Build-context selection is invalid: Validation has $($readyRecords.Count) Ready record(s), but $($contexts.Count) Build context(s) were retained."
    }

    $commonValidationId = ''
    $commonSettings = $null
    $seenLineAndMachine = @{}
    for ($index = 0; $index -lt $contexts.Count; $index++) {
        $context = $contexts[$index]
        $record = $context.Record

        for ($priorIndex = 0; $priorIndex -lt $index; $priorIndex++) {
            if ([object]::ReferenceEquals($context,$contexts[$priorIndex])) {
                throw "The retained Build-context selection is invalid: context index $index duplicates context index $priorIndex."
            }
        }

        $readyReferenceCount = 0
        foreach ($readyRecord in $readyRecords) {
            if ([object]::ReferenceEquals($record,$readyRecord)) {
                $readyReferenceCount++
            }
        }
        if ($readyReferenceCount -ne 1) {
            throw "The retained Build context at index $index does not reference exactly one retained Ready Validation record."
        }
        if (-not [object]::ReferenceEquals($record,$readyRecords[$index])) {
            throw "The retained Build-context selection is out of order at index $index; Build context order must match Ready Validation-record order."
        }
        if ([string]$record.Result -cne 'Ready') {
            throw "The retained Build context at index $index points to a Validation record whose result is '$($record.Result)', not Ready."
        }

        $lineAndMachineKey = '{0}|{1}' -f
            ([string]$record.Line).Trim(),
            ([string]$record.MachineName).Trim().ToUpperInvariant()
        if ($seenLineAndMachine.ContainsKey($lineAndMachineKey)) {
            throw "The retained Build-context selection contains duplicate Line/Machine identity '$($record.Line)/$($record.MachineName)'."
        }
        $seenLineAndMachine[$lineAndMachineKey] = $true

        $contextValidationId = [string]$context.ValidationId
        if ([string]::IsNullOrWhiteSpace($contextValidationId)) {
            throw "The retained Build context at index $index has no ValidationId."
        }
        if ($index -eq 0) {
            $commonValidationId = $contextValidationId
            $commonSettings = $context.Settings
            if ($null -eq $commonSettings) {
                throw 'The retained Build contexts have no Validation Settings object.'
            }
        }
        else {
            if ($contextValidationId -cne $commonValidationId) {
                throw "The retained Build contexts do not share one ValidationId; index $index belongs to '$contextValidationId' instead of '$commonValidationId'."
            }
            if (-not [object]::ReferenceEquals($context.Settings,$commonSettings)) {
                throw "The retained Build context at index $index does not reference the common Validation Settings object."
            }
        }
    }
}

function Assert-ProvisioningStateContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject
    )

    Assert-ExactPropertyContract `
        -InputObject $InputObject `
        -ContractName 'Provisioning state' `
        -ExpectedNames @(
            'PvsStatus','PvsGuid','ImageStatus','PersonalityStatus',
            'PersonalityOtherFingerprint','DhcpOperations'
        )
}

function New-ValidationRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row,

        [Parameter(Mandatory = $true)]
        [psobject]$Settings,

        [AllowEmptyString()]
        [string]$Stage = 'Validation'
    )

    $record = [pscustomobject][ordered]@{
        Line                         = $Row.Line
        MachineName                  = $Row.MachineName
        IPAddress                    = $Row.IPAddress
        MacAddress                   = ''
        Fqdn                         = ''
        DhcpName                     = ''
        PvsCollection                = $Settings.Collection.Display
        PvsImage                     = $Settings.ImageDisplay
        ConfiguredPvsImage           = if ($Settings.AssignPvsImage) {
            "$($Settings.ImageDisplay), version $($Settings.ImageVersionDisplay) (selected; assignment not yet evaluated)"
        }
        else {
            'None requested (assignment not yet evaluated)'
        }
        CurrentStreamedPvsImage      = ''
        OlvmVmStatus                 = ''
        RebootDay                    = ''
        ValidationOutcome            = 'InProgress'
        ValidationAdAction           = ''
        BuildAction                  = ''
        BuildStarted                 = $false
        AdBuildEvaluated             = $false
        NonAdPrerequisitesEvaluated  = $false
        PowerRequested               = [bool]$Settings.PowerOnAfterBuild
        PowerResult                  = if ($Settings.PowerOnAfterBuild) { 'NotEligible' } else { 'NotRequested' }
        PowerDetails                 = ''
        AdStatus                     = 'NotAttempted'
        AdDetails                    = ''
        NonAdPrerequisitesVerified   = $false
        PowerOverrideEligible        = $false
        PowerOverrideDecision        = 'NotOffered'
        PowerOverrideOperator        = ''
        PowerOverrideTimestamp       = $null
        Stage                        = $Stage
        Result                       = 'Blocked'
        ActionSummary                = ''
        Details                      = ''
    }
    Assert-ValidationRecordContract -InputObject $record
    return $record
}

function New-BuildActionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][psobject]$PvsTargetPlan,
        [Parameter(Mandatory = $true)][AllowNull()][psobject]$ImagePlan,
        [Parameter(Mandatory = $true)][AllowNull()][psobject]$PersonalityPlan,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$DhcpTargets,
        [Parameter(Mandatory = $true)][AllowNull()][psobject]$AdAccountPlan
    )

    $plan = [pscustomobject][ordered]@{
        PvsTarget   = $PvsTargetPlan
        Image       = $ImagePlan
        Personality = $PersonalityPlan
        DhcpTargets = [object[]]$DhcpTargets
        AdAccount   = $AdAccountPlan
    }
    Assert-BuildActionPlanContract -InputObject $plan
    return $plan
}

function New-BuildContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Settings,
        [Parameter(Mandatory = $true)][psobject]$Row,
        [Parameter(Mandatory = $true)][psobject]$Record,
        [Parameter(Mandatory = $true)][string]$ValidationId,
        [Parameter(Mandatory = $true)][datetime]$ValidatedAtUtc,
        [Parameter(Mandatory = $true)][psobject]$Plan,
        [Parameter(Mandatory = $true)][bool]$HasWrites,
        [Parameter(Mandatory = $true)][psobject]$OlvmIdentity,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$DhcpServers
    )

    $context = [pscustomobject][ordered]@{
        Settings                    = $Settings
        Row                         = $Row
        Record                      = $Record
        Fqdn                        = [string]$Record.Fqdn
        RebootDay                   = [string]$Record.RebootDay
        ValidationId                = $ValidationId
        ValidatedAtUtc              = $ValidatedAtUtc
        Plan                        = $Plan
        HasWrites                   = [bool]$HasWrites
        ActionSummary               = [string]$Record.ActionSummary
        ValidationAdAction          = [string]$Plan.AdAccount.Action
        ConfiguredPvsImage           = [string]$Record.ConfiguredPvsImage
        CurrentStreamedPvsImage     = [string]$Record.CurrentStreamedPvsImage
        OlvmVmStatus                = [string]$Record.OlvmVmStatus
        ExistingAdAccount           = $Plan.AdAccount.AdAccount
        OlvmIdentity                = $OlvmIdentity
        PowerRequestAttempted       = $false
        PowerRequestSent            = $false
        PersonalityOtherFingerprint = ''
        DhcpServers                 = [string[]]$DhcpServers
        DhcpTargets                 = $Plan.DhcpTargets
        AdFailure                   = ''
        PowerOverrideApproved       = $false
    }
    Assert-BuildContextContract -InputObject $context
    return $context
}

function New-ProvisioningState {
    [CmdletBinding()]
    param()

    $state = [pscustomobject][ordered]@{
        PvsStatus                   = 'NotAttempted'
        PvsGuid                     = $null
        ImageStatus                 = 'NotAttempted'
        PersonalityStatus           = 'NotAttempted'
        PersonalityOtherFingerprint = ''
        DhcpOperations              = New-Object 'System.Collections.Generic.List[object]'
    }
    Assert-ProvisioningStateContract -InputObject $state
    return $state
}

function Get-ValidationOutcomeCounts {
    <# Returns the shared, read-only Validation outcome summary. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    $readyCount = @($Records | Where-Object { $_.Result -eq 'Ready' }).Count
    $skippedExistingCount = @($Records | Where-Object { $_.Result -eq 'SkippedExisting' }).Count
    return [pscustomobject][ordered]@{
        Total           = @($Records).Count
        Ready           = $readyCount
        SkippedExisting = $skippedExistingCount
        Blocked         = @($Records).Count - $readyCount - $skippedExistingCount
    }
}

function Test-ValidationBatchCanBuild {
    <# Build eligibility depends only on whether Validation retained a Ready row. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    $outcomeCounts = Get-ValidationOutcomeCounts -Records $Records
    return [bool]($outcomeCounts.Ready -gt 0)
}

function Get-BuildOutcomeCounts {
    <# Returns the shared, read-only Build and optional power outcome summary. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Records
    )

    return [pscustomobject][ordered]@{
        Total                         = @($Records).Count
        CreatedAndVerified            = @($Records | Where-Object { $_.Result -eq 'CreatedAndVerified' }).Count
        SkippedExisting               = @($Records | Where-Object { $_.Result -eq 'SkippedExisting' }).Count
        BlockedExcluded               = @($Records | Where-Object { $_.Result -eq 'Blocked' }).Count
        AttentionRequired             = @($Records | Where-Object { $_.Result -eq 'AttentionRequired' }).Count
        PartialRetained               = @($Records | Where-Object { $_.Stage -eq 'Partial build retained' }).Count
        AdWarningAfterNonAdVerification = @($Records | Where-Object {
                $_.Result -eq 'AttentionRequired' -and $_.AdStatus -eq 'Failed' -and
                $_.NonAdPrerequisitesVerified -eq $true
            }).Count
        NotAttempted                  = @($Records | Where-Object { $_.Result -eq 'NotAttempted' }).Count
        PoweredOn                     = @($Records | Where-Object { $_.PowerResult -in @('PoweredOn','PoweredOnWithAdWarning') }).Count
        PoweredOnWithAdWarning        = @($Records | Where-Object { $_.PowerResult -eq 'PoweredOnWithAdWarning' }).Count
        AlreadyUp                     = @($Records | Where-Object { $_.PowerResult -in @('AlreadyUp','AlreadyUpWithAdWarning') }).Count
        AlreadyUpWithAdWarning        = @($Records | Where-Object { $_.PowerResult -eq 'AlreadyUpWithAdWarning' }).Count
        PowerFailed                   = @($Records | Where-Object { $_.PowerResult -eq 'Failed' }).Count
        PowerKeptOff                  = @($Records | Where-Object { $_.PowerResult -eq 'KeptOffByOperator' }).Count
        PowerNotAttempted             = @($Records | Where-Object { $_.PowerResult -eq 'NotAttempted' }).Count
        PowerNotEligible              = @($Records | Where-Object { $_.PowerResult -eq 'NotEligible' }).Count
    }
}
