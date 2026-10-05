# Show-Pet.ps1 - bring the pet into view and raise it above other windows.
#
# The pet is an always-on-top frameless window, but "topmost" only orders it among
# topmost windows: if another tool window holds activation it can still be covered.
# This moves it to a clear spot, re-asserts topmost, and activates it.

param(
    [int]$X = -1,
    [int]$Y = -1,
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'src\shell\PetGeometry.ps1')
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace ShowPet -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
'@

$pet = Get-PetWindow
if ($null -eq $pet) {
    Write-Host 'FAIL: pet window not found. Start it first: scripts\start-pet.cmd'
    exit 1
}

$screen = [System.Windows.Forms.Screen]::PrimaryScreen
$work = Get-WorkRect -Screen $screen

# Default: upper-right of the work area, clear of the taskbar and far enough from
# the tray to be easy to click.
if ($X -lt 0) { $X = $work.X + $work.Width - $pet.Width - 60 }
if ($Y -lt 0) { $Y = $work.Y + 80 }

$desired = New-Rect -X $X -Y $Y -Width $pet.Width -Height $pet.Height
$target = Get-DisplayFor -Rect $desired -Screens @([System.Windows.Forms.Screen]::AllScreens)
$clamped = Get-ClampedRect -Rect $desired -Work (Get-WorkRect -Screen $target)

# HWND_TOPMOST (-1) with SWP_NOACTIVATE|SWP_SHOWWINDOW.
[ShowPet.Native]::SetWindowPos($pet.Handle, [IntPtr](-1), [int]$clamped.Rect.X, [int]$clamped.Rect.Y,
    [int]$pet.Width, [int]$pet.Height, 0x0010 -bor 0x0040) | Out-Null
[ShowPet.Native]::ShowWindow($pet.Handle, 5) | Out-Null   # SW_SHOW
[ShowPet.Native]::BringWindowToTop($pet.Handle) | Out-Null
[ShowPet.Native]::SetForegroundWindow($pet.Handle) | Out-Null
Start-Sleep -Milliseconds 400

$after = Get-PetWindow
Write-Host "pet is up: $($after.Width)x$($after.Height) at ($($after.Left),$($after.Top))  visible=$($after.Visible)"
Write-Host "work area : $($work.Width)x$($work.Height) at ($($work.X),$($work.Y))"
