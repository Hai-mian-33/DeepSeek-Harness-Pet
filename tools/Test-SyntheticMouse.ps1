# Test-SyntheticMouse.ps1 - validate the test method itself.
#
# The pet's own counters are the only evidence that mouse input arrives, so before
# trusting them the injection method has to be proven. This moves the cursor with
# SetCursorPos and reads the position back, and also reports the cursor's window,
# to show whether a synthetic move is observable to another window at all.

param([int]$X = 400, [int]$Y = 300)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace SynthMouse -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@

$start = New-Object SynthMouse.Native+POINT
[SynthMouse.Native]::GetCursorPos([ref]$start) | Out-Null
Write-Host "cursor starts at ($($start.X),$($start.Y))"

[SynthMouse.Native]::SetCursorPos($X, $Y) | Out-Null
Start-Sleep -Milliseconds 250

$end = New-Object SynthMouse.Native+POINT
[SynthMouse.Native]::GetCursorPos([ref]$end) | Out-Null
Write-Host "cursor now    at ($($end.X),$($end.Y))  (requested $X,$Y)"

$moved = ($end.X -eq $X) -and ($end.Y -eq $Y)
Write-Host "SetCursorPos took effect: $moved"

# Which window does the OS think is under that point?
$probe = New-Object SynthMouse.Native+POINT
$probe.X = $X
$probe.Y = $Y
$hwnd = [SynthMouse.Native]::WindowFromPoint($probe)
$builder = New-Object System.Text.StringBuilder 256
[SynthMouse.Native]::GetClassName($hwnd, $builder, $builder.Capacity) | Out-Null
$owner = 0
[SynthMouse.Native]::GetWindowThreadProcessId($hwnd, [ref]$owner) | Out-Null
Write-Host "WindowFromPoint(($X,$Y)) -> hwnd=$hwnd class='$($builder.ToString())' pid=$owner"

[SynthMouse.Native]::SetCursorPos($start.X, $start.Y) | Out-Null
Write-Host ''
if ($moved) {
    Write-Host 'The injection method works: the cursor really moves.'
    exit 0
}
Write-Host 'The injection method did NOT move the cursor.'
exit 1
