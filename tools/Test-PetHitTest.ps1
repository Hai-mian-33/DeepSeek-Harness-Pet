# Test-PetHitTest.ps1 - is every pixel of the pet window a mouse target?
#
# This is the test that matters for dragging, and it does not need to move the
# cursor (which the DSH sandbox blocks). `WindowFromPoint` performs the same
# per-pixel, alpha-aware hit test the OS uses to route a real click, so asking it
# about points across the pet's rectangle answers "would a click here reach the
# pet, or fall through to the desktop behind it" without any input injection.
#
# A layered window (AllowsTransparency) with a fully transparent background is
# transparent to the mouse, which is what made the pet undraggable: only the
# whale's own opaque pixels were clickable.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -Namespace PetHit -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr h, uint flags);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@

$GA_ROOT = 2

$pet = Get-PetWindow
if ($null -eq $pet) { Write-Host 'FAIL: pet window not found'; exit 1 }

Write-Host "pet window : hwnd=$($pet.Handle) $($pet.Width)x$($pet.Height) at ($($pet.Left),$($pet.Top))"
Write-Host ''

# Sample a grid across the whole pet rectangle, including its corners, which the
# whale artwork never covers.
$cols = 5
$rows = 5
$hits = 0
$misses = 0
$missPoints = @()

for ($r = 0; $r -lt $rows; $r++) {
    for ($c = 0; $c -lt $cols; $c++) {
        # Inset by 2 px so rounding at the border cannot skew the result.
        $x = $pet.Left + 2 + [int](($pet.Width - 4) * $c / ($cols - 1))
        $y = $pet.Top + 2 + [int](($pet.Height - 4) * $r / ($rows - 1))
        $point = New-Object PetHit.Native+POINT
        $point.X = $x
        $point.Y = $y
        $hwnd = [PetHit.Native]::WindowFromPoint($point)
        $root = [PetHit.Native]::GetAncestor($hwnd, $GA_ROOT)
        $isPet = ($hwnd -eq $pet.Handle) -or ($root -eq $pet.Handle)
        if ($isPet) { $hits++ } else { $misses++; $missPoints += "($x,$y)" }
    }
}

$total = $cols * $rows
Write-Host "grid sample: $cols x $rows = $total points across the pet rectangle"
Write-Host "  points that hit the pet   : $hits"
Write-Host "  points that fall through  : $misses"
if ($missPoints.Count -gt 0) {
    Write-Host "  falling through at        : $($missPoints -join ' ')"
}
Write-Host ''

if ($misses -eq 0) {
    Write-Host 'PASS: every sampled pixel of the pet window is a mouse target.'
    Write-Host '      The whole rectangle can start a drag, including the transparent'
    Write-Host '      padding around the whale.'
    exit 0
}
Write-Host 'FAIL: part of the pet window is transparent to the mouse, so a drag'
Write-Host '      started there falls through to the application behind it.'
exit 1
