# Probe-HitTestAlpha.ps1 - does a transparent WPF background let clicks through?
#
# The pet is a layered window (AllowsTransparency = $true). Windows hit-tests a
# layered window per pixel by the alpha it renders, so a background of
# Brushes.Transparent (alpha 0) is expected to be transparent to the MOUSE while
# still being invisible to the eye — which would make the pet undraggable
# everywhere the sprite is transparent.
#
# This builds two identical windows that differ only in background alpha, each with
# one opaque dot in the middle, and asks WindowFromPoint about their centre (opaque)
# and their corner (transparent). It is the isolated proof of the mechanism, and it
# needs no cursor movement, so the sandbox cannot invalidate it.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type -Namespace AlphaProbe -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr a, int x, int y, int cx, int cy, uint f);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'

function New-ProbeWindow {
    param([string]$Name, $Background, [int]$Left, [int]$Top)

    $window = New-Object System.Windows.Window
    $window.WindowStyle = 'None'
    $window.AllowsTransparency = $true
    $window.Background = $Background
    $window.ShowInTaskbar = $false
    $window.ResizeMode = 'NoResize'
    $window.Topmost = $true
    $window.ShowActivated = $false
    $window.WindowStartupLocation = 'Manual'
    $window.Title = $Name
    $window.Width = 100
    $window.Height = 100
    $window.Left = $Left
    $window.Top = $Top

    $grid = New-Object System.Windows.Controls.Grid
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 30
    $dot.Height = 30
    $dot.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Red)
    $dot.HorizontalAlignment = 'Center'
    $dot.VerticalAlignment = 'Center'
    $grid.Children.Add($dot) | Out-Null
    $window.Content = $grid

    return $window
}

$transparentBg = [System.Windows.Media.Brushes]::Transparent
$alphaOneBg = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(1, 0, 0, 0))

$winA = New-ProbeWindow -Name 'probe-transparent' -Background $transparentBg -Left 300 -Top 300
$winB = New-ProbeWindow -Name 'probe-alpha1' -Background $alphaOneBg -Left 500 -Top 300

$winA.Show()
$winB.Show()
Start-Sleep -Milliseconds 900

function Test-Point([int]$x, [int]$y) {
    $p = New-Object AlphaProbe.Native+POINT
    $p.X = $x
    $p.Y = $y
    $hwnd = [AlphaProbe.Native]::WindowFromPoint($p)
    return [AlphaProbe.Native]::GetAncestor($hwnd, 2)
}

$hwndA = (New-Object System.Windows.Interop.WindowInteropHelper($winA)).Handle
$hwndB = (New-Object System.Windows.Interop.WindowInteropHelper($winB)).Handle

Write-Host "window A (background = Transparent)      hwnd=$hwndA  at (300,300) 100x100"
Write-Host "window B (background = alpha 1 black)    hwnd=$hwndB  at (500,300) 100x100"
Write-Host ''

# Centre = the red dot (opaque in both). Corner = background only.
$results = @()
foreach ($probe in @(
    @{ Label = 'A centre (opaque dot)'; X = 350; Y = 350; Expect = $hwndA },
    @{ Label = 'A corner (transparent bg)'; X = 305; Y = 305; Expect = $hwndA },
    @{ Label = 'B centre (opaque dot)'; X = 550; Y = 350; Expect = $hwndB },
    @{ Label = 'B corner (alpha-1 bg)'; X = 505; Y = 305; Expect = $hwndB }
)) {
    $hit = Test-Point -x $probe.X -y $probe.Y
    $ok = ($hit -eq $probe.Expect)
    $results += [pscustomobject]@{ Label = $probe.Label; Hit = $hit; Ok = $ok }
    Write-Host ("{0,-28} -> hwnd {1,-12} reaches window: {2}" -f $probe.Label, $hit, $ok)
}

$winA.Close()
$winB.Close()
$app.Shutdown()

Write-Host ''
$aCorner = ($results | Where-Object { $_.Label -like 'A corner*' }).Ok
$bCorner = ($results | Where-Object { $_.Label -like 'B corner*' }).Ok

if (-not $aCorner -and $bCorner) {
    Write-Host 'CONFIRMED: a Transparent background is transparent to the mouse, and an'
    Write-Host '           alpha-1 background is not. The pet needed the alpha-1 fix.'
    exit 0
}
if ($aCorner -and $bCorner) {
    Write-Host 'NOTE: both backgrounds were clickable here, so per-pixel alpha is not the'
    Write-Host '      mechanism on this system and the drag fault lies elsewhere.'
    exit 2
}
Write-Host "INCONCLUSIVE: A corner reachable=$aCorner, B corner reachable=$bCorner"
exit 1
