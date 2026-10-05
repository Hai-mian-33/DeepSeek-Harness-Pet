# Test-PetDrag.ps1 - drive a real mouse drag at the pet and report what happened.
#
# Verifies A1 (拖拽移动) against the live desktop, not in simulation: it moves the
# real cursor, presses the real left button, drags in steps, releases, and compares
# the pet's window rectangle before and after. If the pet does not follow the
# cursor, the drag path is broken somewhere between the WPF mouse events and
# SetWindowPos.
#
# Usage: powershell -NoProfile -File tools/Test-PetDrag.ps1

param(
    [string]$Root = '',
    [int]$Distance = 240,
    [int]$Steps = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -Namespace PetDrag -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@

$MOUSEEVENTF_LEFTDOWN = 0x0002
$MOUSEEVENTF_LEFTUP = 0x0004

function Get-PetRect {
    $pet = Get-PetWindow
    if ($null -eq $pet) { return $null }
    return @{ X = $pet.Left; Y = $pet.Top; W = $pet.Width; H = $pet.Height; Handle = $pet.Handle }
}

function Get-Cursor {
    $p = New-Object PetDrag.Native+POINT
    [PetDrag.Native]::GetCursorPos([ref]$p) | Out-Null
    return @{ X = $p.X; Y = $p.Y }
}

$before = Get-PetRect
if ($null -eq $before) {
    Write-Host 'FAIL: pet window not found - start the pet first'
    exit 1
}
$origin = Get-Cursor

Write-Host "pet before : $($before.W)x$($before.H) at ($($before.X),$($before.Y))"
Write-Host "cursor was : ($($origin.X),$($origin.Y))"

# Grab the pet's centre, then drag right and down.
$grabX = $before.X + [int]($before.W / 2)
$grabY = $before.Y + [int]($before.H / 2)
Write-Host "grab point : ($grabX,$grabY)"

[PetDrag.Native]::SetCursorPos($grabX, $grabY) | Out-Null
Start-Sleep -Milliseconds 250   # let WPF see the move and produce MouseEnter

[PetDrag.Native]::mouse_event($MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [System.UIntPtr]::Zero)
Start-Sleep -Milliseconds 150

for ($step = 1; $step -le $Steps; $step++) {
    $x = $grabX + [int]($Distance * $step / $Steps)
    $y = $grabY + [int]($Distance * 0.6 * $step / $Steps)
    [PetDrag.Native]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 40
}

Start-Sleep -Milliseconds 150
$during = Get-PetRect
[PetDrag.Native]::mouse_event($MOUSEEVENTF_LEFTUP, 0, 0, 0, [System.UIntPtr]::Zero)
Start-Sleep -Milliseconds 600

$after = Get-PetRect
$cursorEnd = Get-Cursor

Write-Host ""
Write-Host "pet during : $($during.W)x$($during.H) at ($($during.X),$($during.Y))"
Write-Host "pet after  : $($after.W)x$($after.H) at ($($after.X),$($after.Y))"
Write-Host "cursor end : ($($cursorEnd.X),$($cursorEnd.Y))"
Write-Host ""

$movedDuring = ($during.X -ne $before.X) -or ($during.Y -ne $before.Y)
$movedAfter = ($after.X -ne $before.X) -or ($after.Y -ne $before.Y)
$followed = [Math]::Abs($during.X - ($cursorEnd.X - [int]($before.W / 2))) -lt 60

Write-Host "followed cursor while held : $movedDuring"
Write-Host "stayed moved after release : $movedAfter"
Write-Host "landed near the cursor     : $followed"

# Put the pet back where it started, and the cursor too.
[PetWindowNative.Win]::SetWindowPos($before.Handle, [IntPtr]::Zero, $before.X, $before.Y, $before.W, $before.H, 0x0014) | Out-Null
[PetDrag.Native]::SetCursorPos($origin.X, $origin.Y) | Out-Null

if ($movedDuring -and $movedAfter -and $followed) {
    Write-Host ""
    Write-Host 'PASS: the pet follows the cursor and stays where it was dropped.'
    exit 0
}
Write-Host ""
Write-Host 'FAIL: the pet did not follow the cursor.'
exit 1
