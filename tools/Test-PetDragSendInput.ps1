# Test-PetDragSendInput.ps1 - end-to-end drag using SendInput.
#
# `SetCursorPos` is refused in the DSH sandbox (see Test-SyntheticMouse.ps1), so the
# earlier drag test could not actually move the cursor. `SendInput` injects at a
# lower level and is worth trying: if it works, this is a true end-to-end drag —
# real button press, real movement, real release — and the only test that proves the
# whole chain from the OS input queue to SetWindowPos.
#
# Reports clearly whether injection is available; an unavailable injection path is
# reported as SKIP, never as a pass.

param([string]$Root = '', [int]$Distance = 200)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -Namespace PetSend -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)]
public struct INPUT { public uint type; public MOUSEINPUT mi; }
[DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@

$INPUT_MOUSE = 0
$MOVE = 0x0001
$LEFTDOWN = 0x0002
$LEFTUP = 0x0004
$ABSOLUTE = 0x8000

# Absolute coordinates for SendInput are normalised to 0..65535 over the virtual screen.
Add-Type -AssemblyName System.Windows.Forms
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen

function Send-MouseInput {
    # `$MouseFlags` is explicitly [uint32]: a param named `$Flags` bound to an
    # integer argument is treated as a [switch] and the bitwise OR then fails.
    param([uint32]$EventFlags, [int]$PosX = 0, [int]$PosY = 0, [switch]$UseAbsolute)
    $input = New-Object PetSend.Native+INPUT
    $input.type = $INPUT_MOUSE
    if ($UseAbsolute) {
        $input.mi.dx = [int](($PosX - $vs.X) * 65535 / ($vs.Width - 1))
        $input.mi.dy = [int](($PosY - $vs.Y) * 65535 / ($vs.Height - 1))
        # `-bor` written directly after a variable parses as a parameter token, so
        # the operands are parenthesised to force the operator form.
        $input.mi.dwFlags = [uint32](([uint32]$EventFlags) -bor ([uint32]$ABSOLUTE))
    } else {
        $input.mi.dx = $PosX
        $input.mi.dy = $PosY
        $input.mi.dwFlags = [uint32]$EventFlags
    }
    $sent = [PetSend.Native]::SendInput(1, @($input), [System.Runtime.InteropServices.Marshal]::SizeOf($input))
    return $sent
}

function Get-PetRect {
    $pet = Get-PetWindow
    if ($null -eq $pet) { return $null }
    return @{ X = $pet.Left; Y = $pet.Top; W = $pet.Width; H = $pet.Height; Handle = $pet.Handle }
}

$before = Get-PetRect
if ($null -eq $before) { Write-Host 'FAIL: pet window not found'; exit 1 }

# Prove injection works at all before drawing conclusions from it.
$probeX = 500
$probeY = 400
$current = New-Object PetSend.Native+POINT
[PetSend.Native]::GetCursorPos([ref]$current) | Out-Null
$originX = $current.X
$originY = $current.Y

$sent = Send-MouseInput -EventFlags $MOVE -X $probeX -Y $probeY -UseAbsolute
Start-Sleep -Milliseconds 200
[PetSend.Native]::GetCursorPos([ref]$current) | Out-Null
$moved = ([Math]::Abs($current.X - $probeX) -le 2) -and ([Math]::Abs($current.Y - $probeY) -le 2)
Write-Host "SendInput probe: sent=$sent cursor=($($current.X),$($current.Y)) expected=($probeX,$probeY) moved=$moved"

if (-not $moved) {
    Write-Host ''
    Write-Host 'SKIP: SendInput cannot move the cursor in this sandbox either.'
    Write-Host '      End-to-end drag cannot be synthesised here; use tools\Test-PetHitTest.ps1'
    Write-Host '      (every pixel is a drag target) plus tools\Test-PetDragLogic.ps1 (the'
    Write-Host '      movement maths moves the real window).'
    exit 3
}

# Real drag: press at the pet's centre, move in steps, release.
$grabX = $before.X + [int]($before.W / 2)
$grabY = $before.Y + [int]($before.H / 2)

Send-MouseInput -EventFlags $MOVE -X $grabX -Y $grabY -UseAbsolute | Out-Null
Start-Sleep -Milliseconds 250
Send-MouseInput -EventFlags $LEFTDOWN | Out-Null
Start-Sleep -Milliseconds 150

$steps = 10
for ($i = 1; $i -le $steps; $i++) {
    Send-MouseInput -EventFlags $MOVE -X ($grabX + [int]($Distance * $i / $steps)) -Y ($grabY + [int]($Distance * 0.5 * $i / $steps)) -UseAbsolute | Out-Null
    Start-Sleep -Milliseconds 45
}
Start-Sleep -Milliseconds 150
$during = Get-PetRect
Send-MouseInput -EventFlags $LEFTUP | Out-Null
Start-Sleep -Milliseconds 700
$after = Get-PetRect

$deltaX = $after.X - $before.X
$deltaY = $after.Y - $before.Y
$followed = ($deltaX -gt ($Distance * 0.5)) -and ($deltaY -gt ($Distance * 0.2))

Write-Host ''
Write-Host "pet before : ($($before.X),$($before.Y))"
Write-Host "pet during : ($($during.X),$($during.Y))"
Write-Host "pet after  : ($($after.X),$($after.Y))"
Write-Host "moved by   : ($deltaX,$deltaY)"
Write-Host ''

# Put things back.
[PetWindowNative.Win]::SetWindowPos($before.Handle, [IntPtr]::Zero, $before.X, $before.Y, $before.W, $before.H, 0x0014) | Out-Null
Send-MouseInput -EventFlags $MOVE -X $originX -Y $originY -UseAbsolute | Out-Null

if ($followed) {
    Write-Host 'PASS: a real injected drag moved the pet. Dragging works end to end.'
    exit 0
}
Write-Host 'FAIL: the pet did not follow a real injected drag.'
exit 1
