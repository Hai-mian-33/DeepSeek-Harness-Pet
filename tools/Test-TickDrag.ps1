# Test-TickDrag.ps1 - verify the tick-driven drag against the live window.
#
# The drag no longer relies on MouseMove or Mouse.Capture: the press starts it and
# every tick moves the window from the OS cursor position until the button is
# released. That design exists because MouseMove stops arriving once capture fails,
# and capture is unreliable on a window shown without activation.
#
# This drives exactly that loop: it holds the button down with a synthetic press,
# moves the cursor with SetCursorPos, and lets the shell's own tick carry the pet.
# `SetCursorPos` is refused in the DSH sandbox, so when that happens the test reports
# SKIP rather than a false pass, and the deterministic maths is still covered by
# Test-PetDragLogic.ps1.

param([string]$Root = '', [int]$Distance = 180)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -Namespace TickDrag -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@

$LEFTDOWN = 0x0002
$LEFTUP = 0x0004

function Get-Pet {
    $pet = Get-PetWindow
    if ($null -eq $pet) { return $null }
    return @{ Handle = $pet.Handle; X = $pet.Left; Y = $pet.Top; W = $pet.Width; H = $pet.Height }
}

function Test-LeftDown {
    return (([int]([TickDrag.Native]::GetAsyncKeyState(0x01)) -band 0x8000) -ne 0)
}

$before = Get-Pet
if ($null -eq $before) { Write-Host 'FAIL: pet window not found'; exit 1 }

$origin = New-Object TickDrag.Native+POINT
[TickDrag.Native]::GetCursorPos([ref]$origin) | Out-Null

# Verify the cursor can be moved at all before drawing conclusions.
$probeOk = [TickDrag.Native]::SetCursorPos(600, 500)
Start-Sleep -Milliseconds 200
$probeNow = New-Object TickDrag.Native+POINT
[TickDrag.Native]::GetCursorPos([ref]$probeNow) | Out-Null
$canMove = ([Math]::Abs($probeNow.X - 600) -le 2) -and ([Math]::Abs($probeNow.Y - 500) -le 2)
Write-Host "cursor movable by SetCursorPos: $canMove  (reported=$probeOk at $($probeNow.X),$($probeNow.Y))"

if (-not $canMove) {
    Write-Host ''
    Write-Host 'SKIP: this sandbox refuses cursor injection, so a real held-button drag'
    Write-Host '      cannot be exercised here. Run this script from a normal terminal.'
    Write-Host '      Deterministic coverage: tools\Test-PetDragLogic.ps1 (movement maths'
    Write-Host '      against the real window) + tools\Test-PetHitTest.ps1 (every pixel is'
    Write-Host '      a drag target).'
    exit 3
}

$grabX = $before.X + [int]($before.W / 2)
$grabY = $before.Y + [int]($before.H / 2)

[TickDrag.Native]::SetCursorPos($grabX, $grabY) | Out-Null
Start-Sleep -Milliseconds 300
[TickDrag.Native]::mouse_event($LEFTDOWN, 0, 0, 0, [System.UIntPtr]::Zero)
Start-Sleep -Milliseconds 200
Write-Host "button reports down after press: $(Test-LeftDown)"

# Move in steps; the shell's tick follows the cursor with no MouseMove needed.
for ($i = 1; $i -le 10; $i++) {
    [TickDrag.Native]::SetCursorPos($grabX + [int]($Distance * $i / 10), $grabY + [int]($Distance * 0.5 * $i / 10)) | Out-Null
    Start-Sleep -Milliseconds 60
}
Start-Sleep -Milliseconds 200
$during = Get-Pet
[TickDrag.Native]::mouse_event($LEFTUP, 0, 0, 0, [System.UIntPtr]::Zero)
Start-Sleep -Milliseconds 700
$after = Get-Pet

$dx = $after.X - $before.X
$dy = $after.Y - $before.Y
Write-Host ''
Write-Host "pet before: ($($before.X),$($before.Y))"
Write-Host "pet during: ($($during.X),$($during.Y))"
Write-Host "pet after : ($($after.X),$($after.Y))  moved by ($dx,$dy)"

# Restore.
[PetWindowNative.Win]::SetWindowPos($before.Handle, [IntPtr]::Zero, $before.X, $before.Y, $before.W, $before.H, 0x0014) | Out-Null
[TickDrag.Native]::SetCursorPos($origin.X, $origin.Y) | Out-Null

$followed = ($dx -gt [int]($Distance * 0.6)) -and ($dy -gt [int]($Distance * 0.2))
Write-Host ''
if ($followed) {
    Write-Host 'PASS: holding the button and moving the cursor drags the pet.'
    exit 0
}
Write-Host 'FAIL: the pet did not follow the cursor while the button was held.'
exit 1
