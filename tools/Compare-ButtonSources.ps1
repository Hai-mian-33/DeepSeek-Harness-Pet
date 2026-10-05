# Compare-ButtonSources.ps1 - which button-state source can the drag trust?
#
# The drag watchdog originally used [System.Windows.Forms.Control]::MouseButtons. In
# a pure WPF process WinForms never installs its message filter, so that property
# stays at `None` even while a button is physically held — a watchdog built on it
# cancels every drag on the next tick. This prints both sources side by side so the
# choice is evidence rather than assumption.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace ButtonSources -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
'@

$winforms = [System.Windows.Forms.Control]::MouseButtons
$async = (([int]([ButtonSources.Native]::GetAsyncKeyState(0x01)) -band 0x8000) -ne 0)

Write-Host "WinForms Control.MouseButtons : $winforms"
Write-Host "GetAsyncKeyState(VK_LBUTTON)  : $async"
Write-Host ''
Write-Host 'The drag polls GetAsyncKeyState: it reads the physical key state at call time'
Write-Host 'and needs no message loop, so it is correct in this process regardless of which'
Write-Host 'window has focus and regardless of whether Mouse.Capture succeeded.'
