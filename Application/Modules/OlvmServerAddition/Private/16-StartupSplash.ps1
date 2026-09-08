function Set-StartupSplashStage {
    <# Updates only shared text; the splash Dispatcher owns every WPF control. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Text
    )

    $handle = $script:StartupSplash
    if ($null -eq $handle -or $handle.Disposed -or $null -eq $handle.State) {
        return
    }
    try { $handle.State['StatusText'] = $Text } catch {}
}

function Stop-StartupSplash {
    <#
      Idempotently requests splash shutdown without allowing cleanup to hide
      or delay the real application outcome. A worker that does not stop
      within the bounded waits is left for process teardown rather than being
      synchronously stopped or closed on the main WPF thread.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [psobject]$Handle = $script:StartupSplash
    )

    if ($null -eq $Handle) { return }
    try { if ($Handle.Disposed) { return } }
    catch { return }

    # No AsyncResult means BeginInvoke never started; those resources are safe
    # to dispose immediately. Otherwise retain the handle until completion is
    # positively observed.
    $pipelineCompleted = ($null -eq $Handle.AsyncResult)
    $cleanupWarnings = New-Object 'System.Collections.Generic.List[string]'
    try {
        if ($null -ne $Handle.State) {
            $Handle.State['CloseRequested'] = $true
        }
        if ($null -ne $Handle.AsyncResult) {
            try {
                $pipelineCompleted = [bool]$Handle.AsyncResult.IsCompleted
                if (-not $pipelineCompleted) {
                    $pipelineCompleted = $Handle.AsyncResult.AsyncWaitHandle.WaitOne(1500)
                }
            }
            catch {
                [void]$cleanupWarnings.Add("Splash completion could not be checked: $($_.Exception.Message)")
            }
        }

        if (-not $pipelineCompleted -and $null -ne $Handle.PowerShell) {
            # BeginStop is deliberately asynchronous. Never call Stop() here:
            # a wedged UI worker must not freeze the main WPF dispatcher.
            try {
                $stopResult = $null
                if ($null -ne $Handle.PSObject.Properties['StopAsyncResult']) {
                    $stopResult = $Handle.StopAsyncResult
                }
                if ($null -eq $stopResult) {
                    $stopResult = $Handle.PowerShell.BeginStop($null,$null)
                    if ($null -eq $Handle.PSObject.Properties['StopAsyncResult']) {
                        $Handle | Add-Member -NotePropertyName StopAsyncResult -NotePropertyValue $stopResult
                    }
                    else {
                        $Handle.StopAsyncResult = $stopResult
                    }
                }
                if ($null -ne $stopResult -and $stopResult.AsyncWaitHandle.WaitOne(1500)) {
                    try { $Handle.PowerShell.EndStop($stopResult) } catch {}
                    try { $stopResult.AsyncWaitHandle.Dispose() } catch {}
                    try { $Handle.StopAsyncResult = $null } catch {}
                }
            }
            catch {
                [void]$cleanupWarnings.Add("Splash cancellation could not be requested: $($_.Exception.Message)")
            }
            if ($null -ne $Handle.AsyncResult) {
                try { $pipelineCompleted = [bool]$Handle.AsyncResult.IsCompleted } catch {}
            }
        }

        if ($pipelineCompleted -and
            $null -ne $Handle.PowerShell -and
            $null -ne $Handle.AsyncResult) {
            try { $null = $Handle.PowerShell.EndInvoke($Handle.AsyncResult) } catch {}
        }
    }
    catch {
        [void]$cleanupWarnings.Add("Splash cleanup failed safely: $($_.Exception.Message)")
    }
    finally {
        if ($pipelineCompleted) {
            if ($null -ne $Handle.PSObject.Properties['StopAsyncResult'] -and
                $null -ne $Handle.StopAsyncResult) {
                try {
                    if ($Handle.StopAsyncResult.IsCompleted -and $null -ne $Handle.PowerShell) {
                        $Handle.PowerShell.EndStop($Handle.StopAsyncResult)
                    }
                }
                catch {}
                try { $Handle.StopAsyncResult.AsyncWaitHandle.Dispose() } catch {}
                try { $Handle.StopAsyncResult = $null } catch {}
            }
            if ($null -ne $Handle.PowerShell) {
                try { $Handle.PowerShell.Dispose() } catch {
                    [void]$cleanupWarnings.Add("Splash pipeline disposal failed: $($_.Exception.Message)")
                }
            }
            if ($null -ne $Handle.Runspace) {
                try { $Handle.Runspace.Dispose() } catch {
                    [void]$cleanupWarnings.Add("Splash runspace disposal failed: $($_.Exception.Message)")
                }
            }
            if ($null -ne $Handle.ReadyEvent) {
                try { $Handle.ReadyEvent.Dispose() } catch {
                    [void]$cleanupWarnings.Add("Splash readiness-handle disposal failed: $($_.Exception.Message)")
                }
            }
            try { $Handle.Disposed = $true } catch {}
            if ($script:StartupSplash -eq $Handle) {
                $script:StartupSplash = $null
            }
        }
        else {
            [void]$cleanupWarnings.Add('The splash worker did not stop within 3 seconds; cleanup was deferred to process teardown.')
            # Keep the only handle so application-final cleanup can retry after
            # the worker has acknowledged CloseRequested/BeginStop.
            if ($null -eq $script:StartupSplash) {
                $script:StartupSplash = $Handle
            }
        }
    }

    $workerError = ''
    try { $workerError = [string]$Handle.State['ErrorMessage'] } catch {}
    if (-not [string]::IsNullOrWhiteSpace($workerError)) {
        [void]$cleanupWarnings.Add("The optional splash worker reported: $workerError")
    }
    if ($cleanupWarnings.Count -gt 0) {
        try {
            Write-RecoveryLog -Level WARN -Stage 'Startup splash' -Message (($cleanupWarnings | Select-Object -Unique) -join ' ')
        }
        catch {}
    }
}

function Start-StartupSplash {
    <#
      Shows startup progress on a dedicated STA thread. Infrastructure modules,
      authentication, logging, and PVS connections remain in the main runspace.
    #>
    [CmdletBinding()]
    param(
        [string]$Version = [string]$script:ToolVersion
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        throw 'A display version is required for the startup splash.'
    }

    if ($null -ne $script:StartupSplash -and -not $script:StartupSplash.Disposed) {
        return $script:StartupSplash
    }

    $state = [hashtable]::Synchronized(@{
            StatusText    = 'Starting OLVM Server Addition...'
            CloseRequested = $false
            Ready         = $false
            Closed        = $false
            ErrorMessage  = ''
            ContentRenderedTimestamp = [long]0
        })
    $readyEvent = New-Object System.Threading.ManualResetEventSlim($false)
    $splashXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="520" Height="190" WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False"
        AllowsTransparency="True" Background="Transparent" Topmost="False"
        UseLayoutRounding="True" SnapsToDevicePixels="True">
    <Border Background="#F4F7FA" BorderBrush="#8BA5BA" BorderThickness="1" CornerRadius="5" Padding="28">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="Auto" />
                <RowDefinition Height="*" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="OLVM Server Addition" FontSize="25" FontWeight="SemiBold" Foreground="#102F4F" />
            <TextBlock x:Name="SplashVersion" Grid.Row="1" Margin="1,3,0,0" FontSize="12" Foreground="#60758A" />
            <TextBlock x:Name="SplashStatus" Grid.Row="2" Margin="1,27,0,12" FontSize="14" Foreground="#243B53" TextTrimming="CharacterEllipsis" />
            <ProgressBar Grid.Row="3" Height="5" IsIndeterminate="True" Foreground="#1976A8" Background="#DCE6ED" />
        </Grid>
    </Border>
</Window>
'@
    $workerSource = @'
param($WorkerState,$WorkerReadyEvent,[string]$WorkerVersion,[string]$WorkerXaml)
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase -ErrorAction Stop
    [xml]$xml = $WorkerXaml
    $reader = New-Object System.Xml.XmlNodeReader $xml
    try { $splashWindow = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    $status = $splashWindow.FindName('SplashStatus')
    $version = $splashWindow.FindName('SplashVersion')
    if ($null -eq $status -or $null -eq $version) {
        throw 'The startup splash controls could not be loaded.'
    }
    $version.Text = "Version $WorkerVersion"
    $status.Text = [string]$WorkerState['StatusText']
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
            $status.Text = [string]$WorkerState['StatusText']
            if ([bool]$WorkerState['CloseRequested']) {
                $timer.Stop()
                $splashWindow.Close()
            }
        })
    $splashWindow.Add_Closing({
            param($sender,$eventArgs)
            if (-not [bool]$WorkerState['CloseRequested']) {
                $eventArgs.Cancel = $true
            }
        })
    $splashWindow.Add_ContentRendered({
            $WorkerState['ContentRenderedTimestamp'] = [Diagnostics.Stopwatch]::GetTimestamp()
            $WorkerState['Ready'] = $true
            $WorkerReadyEvent.Set()
        })
    $timer.Start()
    $null = $splashWindow.ShowDialog()
}
catch {
    $WorkerState['ErrorMessage'] = [string]$_.Exception.Message
    $WorkerReadyEvent.Set()
}
finally {
    $WorkerState['Closed'] = $true
}
'@

    $runspace = $null
    $worker = $null
    $asyncResult = $null
    $handle = $null
    try {
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.Runspace = $runspace
        [void]$worker.AddScript($workerSource)
        [void]$worker.AddArgument($state)
        [void]$worker.AddArgument($readyEvent)
        [void]$worker.AddArgument($Version)
        [void]$worker.AddArgument($splashXaml)
        $asyncResult = $worker.BeginInvoke()
        $handle = [pscustomobject]@{
            State       = $state
            ReadyEvent  = $readyEvent
            Runspace    = $runspace
            PowerShell  = $worker
            AsyncResult = $asyncResult
            StopAsyncResult = $null
            Disposed    = $false
        }
        $script:StartupSplash = $handle
        $readySignalled = $readyEvent.Wait(5000)
        if (-not $readySignalled -or -not [bool]$state['Ready']) {
            $reason = [string]$state['ErrorMessage']
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = 'The splash window did not become ready within 5 seconds.'
            }
            throw $reason
        }
        return $handle
    }
    catch {
        if ($null -eq $handle) {
            $handle = [pscustomobject]@{
                State       = $state
                ReadyEvent  = $readyEvent
                Runspace    = $runspace
                PowerShell  = $worker
                AsyncResult = $asyncResult
                StopAsyncResult = $null
                Disposed    = $false
            }
        }
        Stop-StartupSplash -Handle $handle
        throw
    }
}
