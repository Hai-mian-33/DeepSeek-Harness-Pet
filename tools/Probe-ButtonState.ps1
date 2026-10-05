# Probe-ButtonState.ps1 - is the button-state source trustworthy?
#
# The drag watchdog polls [System.Windows.Forms.Control]::MouseButtons. In a pure
# WPF process WinForms never installs its message filter, so that property can
# report "no buttons" even while a button is physically held — which would make the
# watchdog cancel every drag on the very next tick.
#
# This compares it against GetAsyncKeyState(VK_LBUTTON), which reads the physical
# key state directly and needs no message loop.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace BtnProbe -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
[DllImport("user32.dll")] public static extern short GetKeyState(int vKey);
'@

$VK_LBUTTON = 0x01
$VK_RBUTTON = 0x02

function Get-AsyncDown([int]$vk) {
    $state = [int]([BtnProbe.Native]::GetAsyncKeyState($vk))
    return (($state -band 0x8000) -ne 0)
}

Write-Host 'Reading button state 5 times over ~1s.'
Write-Host 'Press and hold the LEFT mouse button during this window if you can.'
Write-Host ''
Write-Host ('{0,-6} {1,-26} {2,-24} {3}' -f 't', 'Control.MouseButtons', 'GetAsyncKeyState(L)', 'GetKeyState(L)')

for ($i = 1; $i -le 5; $i++) {
    $wf = [System.Windows.Forms.Control]::MouseButtons
    $asyncDown = Get-AsyncDown $VK_LBUTTON
    $keyState = [int]([BtnProbe.Native]::GetKeyState($VK_LBUTTON))
    $keyDown = (($keyState -band 0x8000) -ne 0)
    Write-Host ('{0,-6} {1,-26} {2,-24} {3}' -f $i, $wf.ToString(), $asyncDown, $keyDown)
    Start-Sleep -Milliseconds 200
}

Write-Host ''
Write-Host 'If Control.MouseButtons always shows "None" while GetAsyncKeyState reports'
Write-Host 'True, the watchdog was cancelling every drag and the poll must use'
Write-Host 'GetAsyncKeyState instead.'
