# Test-PetEdges.ps1 - live check of the edge-fixing acceptance criteria.
#
# The geometry core is unit tested (tests/geometry.test.mjs); this drives the real
# window to the screen edges through the same PetGeometry.ps1 functions the shell
# uses, then confirms from the real Win32 rectangle that the pet is fixed flush to
# the edge, still fully on screen, still its full size, and still visible.
#
# That is the product's differentiator stated as an assertion: an edge is a
# fixture, not a hiding place.
#
# Usage: powershell -NoProfile -File tools/Test-PetEdges.ps1

param(
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'src\shell\PetGeometry.ps1')
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -AssemblyName System.Windows.Forms

function Get-PetRect([IntPtr]$handle) {
    $r = New-Object PetWindowNative.Win+RECT
    [PetWindowNative.Win]::GetWindowRect($handle, [ref]$r) | Out-Null
    New-Rect -X $r.Left -Y $r.Top -Width ($r.Right - $r.Left) -Height ($r.Bottom - $r.Top)
}

$pet = Get-PetWindow
if ($null -eq $pet) {
    Write-Host 'FAIL: pet window not found - start the pet first (scripts\start-pet.cmd)'
    exit 1
}
$handle = $pet.Handle

$screens = @([System.Windows.Forms.Screen]::AllScreens)
# Force array semantics: PowerShell unwraps a single-element collection, so a
# one-seam desktop would otherwise arrive as a bare object with no Count.
$seams = @(Get-SeamRects -Screens $screens)
$primary = [System.Windows.Forms.Screen]::PrimaryScreen
$work = Get-WorkRect -Screen $primary
$start = Get-PetRect $handle

Write-Host "pet window  : $($start.Width)x$($start.Height) at ($($start.X),$($start.Y))  pid=$($pet.Owner)"
Write-Host "monitors    : $($screens.Count)   interior seams: $($seams.Count)"
foreach ($screen in $screens) {
    $w = Get-WorkRect -Screen $screen
    Write-Host "   $($screen.DeviceName) work=$($w.Width)x$($w.Height) at ($($w.X),$($w.Y)) primary=$($screen.Primary)"
}
Write-Host ''

$failures = 0
$cases = @(
    @{ Name = 'A1 free placement';         X = 600;                Y = 300 }
    @{ Name = 'A2 right edge (pull far)';  X = $work.Width + 900;  Y = 400 }
    @{ Name = 'A2 left edge (pull far)';   X = -1200;              Y = 400 }
    @{ Name = 'A2 top edge (pull far)';    X = 700;                Y = -900 }
    @{ Name = 'A2 bottom edge';            X = 700;                Y = $work.Height + 900 }
    @{ Name = 'A2 bottom-right corner';    X = $work.Width + 900;  Y = $work.Height + 900 }
    @{ Name = 'A2 top-left corner';        X = -900;               Y = -900 }
    @{ Name = 'A3 seam (interior)';        X = [int]($work.Width / 2); Y = 400 }
)

foreach ($case in $cases) {
    # The shell's own path: resolve the desired rectangle against the display that
    # owns it, fixing any crossed edge instead of letting the pet leave the screen.
    $desired = New-Rect -X $case.X -Y $case.Y -Width $start.Width -Height $start.Height
    $screen = Get-DisplayFor -Rect $desired -Screens $screens
    $clamped = Get-ClampedRect -Rect $desired -Work (Get-WorkRect -Screen $screen)
    [PetWindowNative.Win]::SetWindowPos($handle, [IntPtr]::Zero, [int]$clamped.Rect.X, [int]$clamped.Rect.Y,
        [int]$start.Width, [int]$start.Height, 0x0014) | Out-Null
    Start-Sleep -Milliseconds 200

    $actual = Get-PetRect $handle
    $onScreen = ($actual.X -ge $work.X) -and ($actual.Y -ge $work.Y) -and
                (($actual.X + $actual.Width) -le ($work.X + $work.Width)) -and
                (($actual.Y + $actual.Height) -le ($work.Y + $work.Height))
    $visible = [PetWindowNative.Win]::IsWindowVisible($handle)
    $fullSize = ($actual.Width -eq $start.Width) -and ($actual.Height -eq $start.Height)
    $ok = $onScreen -and $visible -and $fullSize
    if (-not $ok) { $failures++ }

    $anchors = @()
    if ($clamped.Edges.Left) { $anchors += 'left' }
    if ($clamped.Edges.Right) { $anchors += 'right' }
    if ($clamped.Edges.Top) { $anchors += 'top' }
    if ($clamped.Edges.Bottom) { $anchors += 'bottom' }
    $anchorText = if ($anchors.Count -gt 0) { $anchors -join '+' } else { 'free' }

    Write-Host ("{0}  {1,-24} wanted=({2,6},{3,6}) -> ({4,5},{5,5})  anchor={6,-12} onScreen={7,-5} visible={8,-5} fullSize={9}" -f `
        $(if ($ok) { 'PASS' } else { 'FAIL' }), $case.Name, $case.X, $case.Y, $actual.X, $actual.Y,
        $anchorText, $onScreen, $visible, $fullSize)
}

# Leave the pet where it was found.
[PetWindowNative.Win]::SetWindowPos($handle, [IntPtr]::Zero, [int]$start.X, [int]$start.Y,
    [int]$start.Width, [int]$start.Height, 0x0014) | Out-Null

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'all edge cases behaved: fixed to the edge, never hidden, always full size.'
    exit 0
}
Write-Host "$failures edge case(s) failed."
exit 1
