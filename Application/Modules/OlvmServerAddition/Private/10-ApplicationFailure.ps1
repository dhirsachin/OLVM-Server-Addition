function New-ApplicationFailureReport {
    <#
      Creates the scalar failure contract shared by the GUI fatal boundary and
      its launcher. The ErrorRecord is converted here and is never retained in
      the returned object.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Startup','Runtime')]
        [string]$Phase,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $disposition = 'RequiresIntervention'
    $errorIdentity = New-SerializableErrorIdentity `
        -ErrorRecord $ErrorRecord `
        -Disposition $disposition
    $title = if ($Phase -ceq 'Startup') {
        'OLVM Server Addition - startup stopped'
    }
    else {
        'OLVM Server Addition - application stopped'
    }
    $message = [string]$errorIdentity.Message
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = 'An unexpected OLVM Server Addition application error occurred.'
    }

    return [pscustomobject][ordered]@{
        Phase         = $Phase
        Title         = $title
        Message       = $message
        ExitCode      = 1
        Disposition   = $disposition
        ErrorIdentity = $errorIdentity
    }
}
