function Show-ServerImportWorksheetPicker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$WorksheetNames,

        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Owner
    )

    [xml]$pickerXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Select Excel worksheet" Width="480" SizeToContent="Height"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" ShowInTaskbar="False"
        FontFamily="Segoe UI" FontSize="13">
 <Grid Margin="14">
  <Grid.RowDefinitions>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="Auto"/>
   <RowDefinition Height="Auto"/>
  </Grid.RowDefinitions>
  <TextBlock Text="This workbook contains multiple visible worksheets. Select the worksheet whose column A contains server names and column B contains IPv4 addresses."
             TextWrapping="Wrap" Margin="0,0,0,10"/>
  <ComboBox Grid.Row="1" Name="WorksheetList" MinWidth="420" Margin="0,0,0,14"
            AutomationProperties.Name="Worksheet to import"
            AutomationProperties.HelpText="Select the worksheet to import."/>
  <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
   <Button Name="UseWorksheet" Content="Import selected worksheet" IsEnabled="False" IsDefault="True" Padding="12,5" Margin="0,0,8,0"/>
   <Button Name="CancelWorksheet" Content="Cancel" IsCancel="True" Padding="12,5"/>
  </StackPanel>
 </Grid>
</Window>
'@
    $reader = New-Object System.Xml.XmlNodeReader $pickerXaml
    try {
        $dialog = [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        $reader.Dispose()
    }
    $dialog.Owner = $Owner
    $worksheetList = $dialog.FindName('WorksheetList')
    $useWorksheet = $dialog.FindName('UseWorksheet')
    $cancelWorksheet = $dialog.FindName('CancelWorksheet')
    $worksheetList.ItemsSource = [string[]]$WorksheetNames
    $worksheetList.SelectedIndex = -1
    $worksheetList.Add_SelectionChanged({
            $useWorksheet.IsEnabled = ($null -ne $worksheetList.SelectedItem)
        })
    $useWorksheet.Add_Click({
            $dialog.Tag = [string]$worksheetList.SelectedItem
            $dialog.DialogResult = $true
        })
    $cancelWorksheet.Add_Click({ $dialog.DialogResult = $false })
    $selected = $dialog.ShowDialog()
    if ($selected -eq $true) {
        return [string]$dialog.Tag
    }
    return $null
}

function Get-ServerImportFileBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Owner
    )

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer) {
        throw "'$Path' is a folder. Select a CSV or .xlsx file."
    }
    $extension = $file.Extension.ToLowerInvariant()
    $worksheetName = $null
    $records = switch ($extension) {
        '.csv' {
            @(Read-ServerImportCsv -Path $file.FullName)
            break
        }
        '.xlsx' {
            $excelResult = Read-ServerImportXlsx -Path $file.FullName
            if ($excelResult.RequiresWorksheetSelection) {
                $worksheetName = Show-ServerImportWorksheetPicker -WorksheetNames $excelResult.WorksheetNames -Owner $Owner
                if ([string]::IsNullOrWhiteSpace($worksheetName)) {
                    return [pscustomobject]@{ Cancelled = $true }
                }
                $excelResult = Read-ServerImportXlsx -Path $file.FullName -WorksheetName $worksheetName
            }
            else {
                $worksheetName = $excelResult.WorksheetName
            }
            @($excelResult.Records)
            break
        }
        '.xls' {
            throw 'Legacy .xls files are not supported. Open the file in Excel and save it as .xlsx or CSV, then import it again.'
        }
        default {
            throw "File type '$extension' is not supported. Select a .csv or .xlsx file."
        }
    }

    $sourceDisplay = if ($extension -eq '.xlsx') {
        "$($file.Name), worksheet '$worksheetName'"
    }
    else {
        $file.Name
    }
    $batch = ConvertTo-ServerImportBatch -Records @($records) -SourceDisplay $sourceDisplay
    return [pscustomobject]@{
        Cancelled      = $false
        Count          = $batch.Count
        Text           = $batch.Text
        HeaderSkipped  = $batch.HeaderSkipped
        FileName       = $file.Name
        FullPath       = $file.FullName
        FileType       = $extension
        WorksheetName  = $worksheetName
        SourceDisplay  = $sourceDisplay
    }
}
