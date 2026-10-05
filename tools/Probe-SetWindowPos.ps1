# Probe-SetWindowPos.ps1 - does SetWindowPos hold a WPF window at a physical size?
#
# The pet asks for a 96x104 physical window but WPF kept producing 192x208, so
# this isolates the question: after a transparent frameless window is shown, does
# forcing the physical rectangle stick, or does WPF's layout pass put its own
# device-independent size back?

param(
    [int]$Width = 96,
    [int]$Height = 104
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type -Namespace PosProbe -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@

function Get-Rect([IntPtr]$handle) {
    $r = New-Object PosProbe.Native+RECT
    [PosProbe.Native]::GetWindowRect($handle, [ref]$r) | Out-Null
    return "$($r.Right - $r.Left)x$($r.Bottom - $r.Top) at ($($r.Left),$($r.Top))"
}

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
$window.Left = 200
$window.Top = 200
$window.Width = $Width
$window.Height = $Height
$window.Content = New-Object System.Windows.Controls.Grid

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$step = 0
$timer.Add_Tick({
    $step++
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    switch ($step) {
        1 {
            Write-Host "after show           : $(Get-Rect $handle)   DIP=$($window.Width)x$($window.Height)"
            $source = [System.Windows.PresentationSource]::FromVisual($window)
            if ($null -ne $source) {
                Write-Host "TransformToDevice M11: $($source.CompositionTarget.TransformToDevice.M11)"
            } else {
                Write-Host "TransformToDevice    : (no presentation source)"
            }
        }
        2 {
            [PosProbe.Native]::SetWindowPos($handle, [IntPtr]::Zero, 400, 400, $Width, $Height, 0x0014) | Out-Null
            Write-Host "right after SetWindowPos: $(Get-Rect $handle)"
        }
        3 {
            Write-Host "one layout pass later   : $(Get-Rect $handle)   DIP=$($window.Width)x$($window.Height)"
            $app.Shutdown()
        }
    }
})

$window.Show()
$timer.Start()
$app.Run() | Out-Null
