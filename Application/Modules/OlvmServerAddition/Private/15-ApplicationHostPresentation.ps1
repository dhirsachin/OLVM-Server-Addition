function Initialize-OlvmServerAdditionApplicationHost {
    [CmdletBinding()]
    param()

$script:Window = $null
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    Enter-ApplicationInstanceLock
    Start-RunAuditSession
    if ($script:ApplicationLockWasAbandoned) {
        Write-RunLog -Level WARN -Stage 'Application lock' -Message 'Recovered an abandoned same-server application mutex after Windows confirmed that its previous owner had exited.'
    }
    Write-RunLog -Level SUCCESS -Stage 'Application lock' -Message 'Acquired the same-server single-instance mutex for the complete GUI session.'
    $startupSplashTimestamp = [long]0
    try {
        $script:StartupSplash = Start-StartupSplash
        if ($null -ne $script:StartupSplash -and
            $script:StartupSplash.State.ContainsKey('ContentRenderedTimestamp')) {
            $startupSplashTimestamp = [long]$script:StartupSplash.State['ContentRenderedTimestamp']
        }
    }
    catch {
        # Stop-StartupSplash clears a completed handle itself and deliberately
        # retains an incomplete one for a later bounded cleanup attempt.
        Write-RecoveryLog -Level WARN -Stage 'Startup splash' -Message "The optional startup splash could not be displayed: $($_.Exception.Message) Startup will continue in the main process."
    }
    Write-StartupLaunchTiming -SplashTimestamp $startupSplashTimestamp
    Set-StartupSplashStage -Text 'Checking required components...'

    # Window bounds are fitted in native pixels so absolute virtual-screen
    # coordinates never need to be translated through WPF. The host-reported
    # WPF scale is used only to convert the large-screen size caps.
    if ($null -eq ('OlvmServerAddition.NativeWindowPlacement' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace OlvmServerAddition
{
    public static class NativeWindowPlacement
    {
        public const uint MonitorDefaultToNearest = 2;
        private const uint SwpNoZOrder = 0x0004;
        private const uint SwpNoActivate = 0x0010;

        [StructLayout(LayoutKind.Sequential)]
        public struct Rect
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct Point
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        private struct MonitorInfo
        {
            public int Size;
            public Rect Monitor;
            public Rect Work;
            public uint Flags;
        }

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromPoint(Point point, uint flags);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool GetCursorPos(out Point point);

        [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetWindowPos(
            IntPtr window,
            IntPtr insertAfter,
            int x,
            int y,
            int width,
            int height,
            uint flags);

        public static Rect GetWorkArea(IntPtr monitor)
        {
            MonitorInfo info = new MonitorInfo();
            info.Size = Marshal.SizeOf(typeof(MonitorInfo));
            if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "The monitor work area could not be read.");
            }
            return info.Work;
        }

        public static IntPtr GetMonitorAtCursor()
        {
            Point point;
            if (!GetCursorPos(out point))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "The current pointer position could not be read.");
            }
            IntPtr monitor = MonitorFromPoint(point, MonitorDefaultToNearest);
            if (monitor == IntPtr.Zero)
            {
                throw new InvalidOperationException("The monitor containing the pointer could not be identified.");
            }
            return monitor;
        }

        public static void SetBounds(IntPtr window, int x, int y, int width, int height)
        {
            if (window == IntPtr.Zero || width <= 0 || height <= 0)
            {
                throw new ArgumentException("Valid window bounds are required.");
            }
            if (!SetWindowPos(window, IntPtr.Zero, x, y, width, height, SwpNoZOrder | SwpNoActivate))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "The window bounds could not be applied.");
            }
        }
    }
}
'@ -ErrorAction Stop
    }
    Write-RunLog -Level SUCCESS -Stage 'Startup' -Message 'WPF presentation assemblies and native per-monitor placement support loaded.'
}
catch {
    $startupErrorRecord = $_
    try { Write-ExceptionLog -Stage 'Startup' -ErrorRecord $startupErrorRecord } catch {}
    $startupFailureReport = New-ApplicationFailureReport `
        -Phase Startup `
        -ErrorRecord $startupErrorRecord
    Stop-StartupSplash
    try {
        [System.Windows.MessageBox]::Show(
            [string]$startupFailureReport.Message,
            [string]$startupFailureReport.Title,
            'OK',
            'Error'
        ) | Out-Null
    }
    catch {}
    Close-RunLog
    Exit-ApplicationInstanceLock
    throw
}

}
