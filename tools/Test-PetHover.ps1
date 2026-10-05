# Test-PetHover.ps1 - does the pet receive plain mouse movement (no button)?
#
# This isolates the drag failure. `Test-PetDrag.ps1` shows the press arriving and
# then silence, which could mean either (a) the window stops receiving mouse input
# once a button goes down, or (b) movement is delivered but the drag never starts.
# Hovering with no button pressed distinguishes them: if `move` climbs while the
# cursor sweeps the pet, delivery works and the fault is in the drag itself.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -Namespace PetHover -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@

function Read-Counters {
    $path = Join-Path $Root 'state\pet-control.json'
    if (-not (Test-Path $path)) { return $null }
    try { return Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

$pet = Get-PetWindow
if ($null -eq $pet) { Write-Host 'FAIL: pet window not found'; exit 1 }

$origin = New-Object PetHover.Native+POINT
[PetHover.Native]::GetCursorPos([ref]$origin) | Out-Null

$before = Read-Counters
Write-Host "pet at ($($pet.Left),$($pet.Top)) size $($pet.Width)x$($pet.Height)"
Write-Host "counters before: down=$($before.events.down) move=$($before.events.move) up=$($before.events.up) enter=$($before.events.enter)"
Write-Host ''

# Sweep across the pet with no buttons pressed.
$x0 = $pet.Left - 40
$y0 = $pet.Top + [int]($pet.Height / 2)
$steps = 16
Write-Host "sweeping cursor across the pet in $steps steps (no buttons)..."
for ($i = 0; $i -le $steps; $i++) {
    $x = $x0 + [int](($pet.Width + 80) * $i / $steps)
    [PetHover.Native]::SetCursorPos($x, $y0) | Out-Null
    Start-Sleep -Milliseconds 45
}
Start-Sleep -Milliseconds 300

$after = Read-Counters
[PetHover.Native]::SetCursorPos($origin.X, $origin.Y) | Out-Null

Write-Host ''
Write-Host "counters after : down=$($after.events.down) move=$($after.events.move) up=$($after.events.up) enter=$($after.events.enter)"

$deltaMove = $after.events.move - $before.events.move
$deltaEnter = $after.events.enter - $before.events.enter
Write-Host "delta move=$deltaMove  enter=$deltaEnter"
Write-Host ''

if ($deltaMove -gt 0) {
    Write-Host 'RESULT: movement IS delivered to the pet window.'
    Write-Host '        The drag fault is in the drag handling, not in input delivery.'
    exit 0
}
Write-Host 'RESULT: no movement reached the pet window while hovering.'
Write-Host '        The pixel is not hit-testable by the mouse (transparent pixels do'
Write-Host '        not hit-test unless the element opts in).'
exit 2
