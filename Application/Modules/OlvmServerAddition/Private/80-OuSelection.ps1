function Read-OuChoicesForCurrentDomain {
    [CmdletBinding()]
    param()

    $dnsDomain = $script:AdDnsDomain.Text.Trim().Trim('.')
    $choices = @(Get-SelectionOuChoices -DnsDomain $dnsDomain)
    if ($null -ne $script:OuChoiceView) {
        if (-not [object]::ReferenceEquals(
                $script:OuSelector.ItemsSource,
                $script:OuChoiceView
            )) {
            $script:OuSelector.ItemsSource = $script:OuChoiceView
        }
        return [object[]]$choices
    }

    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($choices)
    $view.Filter = [System.Predicate[object]]{
        param($item)
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace($script:OuSearchText)) {
            return $true
        }
        return ([string]$item.Display).IndexOf(
            $script:OuSearchText,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0
    }
    $script:OuChoiceView = $view
    $script:OuSelector.ItemsSource = $view
    return [object[]]$choices
}

function Initialize-OuChoicesForCurrentDomain {
    <#
      Preloads the detected domain's OU inventory for a responsive dropdown.
      AD lookup failures remain recoverable and are retried when the list opens;
      audit-log failures still propagate through the normal fail-closed boundary.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Startup','New build')]
        [string]$Source = 'Startup'
    )

    $dnsDomain = $script:AdDnsDomain.Text.Trim().Trim('.')
    if ([string]::IsNullOrWhiteSpace($dnsDomain)) {
        Write-RunLog -Level INFO -Stage 'OU preload' -Message "OU preload was skipped during $Source because no AD DNS domain was detected."
        return [pscustomobject]@{
            Succeeded    = $false
            Skipped      = $true
            Count        = 0
            Domain       = ''
        }
    }

    $script:IsRefreshingOuChoices = $true
    try {
        $script:OuSearchText = ''
        $choices = @(Read-OuChoicesForCurrentDomain)
        $script:OuSelector.SelectedIndex = -1
        $script:OuSelector.Text = ''
        $script:OrganizationalUnit.Text = ''
        if ($null -ne $script:OuChoiceView) {
            $script:OuChoiceView.Refresh()
        }
        Write-RunLog -Level SUCCESS -Stage 'OU preload' -Message "Preloaded $($choices.Count) OU choice(s) for '$dnsDomain' during $Source. No OU was selected automatically."
        return [pscustomobject]@{
            Succeeded    = $true
            Skipped      = $false
            Count        = $choices.Count
            Domain       = $dnsDomain
        }
    }
    catch {
        $message = $_.Exception.Message
        if (-not $script:AuditTrailHealthy) {
            throw
        }
        $script:OuChoiceView = $null
        $script:OuSearchText = ''
        $script:OuSelector.SelectedIndex = -1
        $script:OuSelector.ItemsSource = @()
        $script:OuSelector.Text = ''
        $script:OrganizationalUnit.Text = ''
        Write-RunLog -Level WARN -Stage 'OU preload' -Message "Optional OU preload for '$dnsDomain' failed during ${Source}: $message Opening the OU list will retry."
        return [pscustomobject]@{
            Succeeded    = $false
            Skipped      = $false
            Count        = 0
            Domain       = $dnsDomain
        }
    }
    finally {
        $script:IsRefreshingOuChoices = $false
    }
}
