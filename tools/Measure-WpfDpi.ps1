# Measure-WpfDpi.ps1 - report how WPF resolves DPI in a plain PowerShell host.
#
# The pet's edge fixing and popup placement work in physical pixels, so the
# window size WPF actually produces must match the size that was requested. This
# probe prints the requested size, the resulting Win32 rectangle and the scaling
# WPF applied, which is what distinguishes "DPI virtualisation is on" from "the
# geometry math is wrong".

param(
    [int]$Width = 96,
    [int]$Height = 104
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -Namespace WpfDpi -Name Native -MemberDefinition @'
[DllImport("shcore.dll", SetLastError=true)] public static extern int SetProcessDpiAwareness(int value);
[DllImport("user32.dll", SetLastError=true)] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr ctx);
[DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@

# Claim per-monitor DPI awareness before any window exists.
try { [WpfDpi.Native]::SetProcessDpiAwareness(2) | Out-Null } catch { }

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'

$window = New-Object System.Windows.Window
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.ShowInTaskbar = $false
$window.ResizeMode = 'NoResize'
$window.WindowStartupLocation = 'Manual'
$window.ShowActivated = $false
$window.Left = 300
$window.Top = 300
$window.Width = $Width
$window.Height = $Height

$window.Add_ContentRendered({
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    $rect = New-Object WpfDpi.Native+RECT
    [WpfDpi.Native]::GetWindowRect($handle, [ref]$rect) | Out-Null

    $source = [System.Windows.PresentationSource]::FromVisual($window)
    $matrix = $source.CompositionTarget.TransformToDevice
    $dpiX = $source.CompositionTarget.TransformToDevice.M11

    Write-Host "requested (DIP)      : $Width x $Height"
    Write-Host "WPF ActualWidth/Height: $($window.ActualWidth) x $($window.ActualHeight)"
    Write-Host "TransformToDevice M11 : $dpiX  (WPF scaling factor)"
    Write-Host "GetDpiForWindow       : $([WpfDpi.Native]::GetDpiForWindow($handle))"
    Write-Host "Win32 GetWindowRect   : $($rect.Right - $rect.Left) x $($rect.Bottom - $rect.Top) at ($($rect.Left),$($rect.Top))"
    Write-Host "device units in WPF   : $([math]::Round($window.ActualWidth * $dpiX)) x $([math]::Round($window.ActualHeight * $dpiX))"

    $app.Shutdown()
})

$window.Show()
$app.Run() | Out-Null
