# Get-PetWindowStyle.ps1 - report the pet window's Win32 styles.
#
# Relevant to dragging: a window created with no activation (WS_EX_NOACTIVATE, or
# WPF's ShowActivated = $false) shows the symptom where the first press arrives but
# subsequent moves and the release do not, and SetCapture cannot hold the mouse.
# This prints the styles so that hypothesis can be confirmed instead of assumed.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -Namespace PetStyle -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int index);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
'@

$pet = Get-PetWindow
if ($null -eq $pet) { Write-Host 'FAIL: pet window not found'; exit 1 }

$style = [PetStyle.Native]::GetWindowLong($pet.Handle, -16)     # GWL_STYLE
$ex = [PetStyle.Native]::GetWindowLong($pet.Handle, -20)        # GWL_EXSTYLE

Write-Host ("pet hwnd    : {0}" -f $pet.Handle)
Write-Host ("GWL_STYLE   : 0x{0:X8}" -f $style)
Write-Host ("GWL_EXSTYLE : 0x{0:X8}" -f $ex)

$checks = @(
    @{ Name = 'WS_EX_NOACTIVATE'; Mask = 0x08000000; Source = 'ex' },
    @{ Name = 'WS_EX_TOOLWINDOW'; Mask = 0x00000080; Source = 'ex' },
    @{ Name = 'WS_EX_TOPMOST';    Mask = 0x00000008; Source = 'ex' },
    @{ Name = 'WS_EX_TRANSPARENT'; Mask = 0x00000020; Source = 'ex' },
    @{ Name = 'WS_EX_LAYERED';    Mask = 0x00080000; Source = 'ex' },
    @{ Name = 'WS_DISABLED';      Mask = 0x08000000; Source = 'style' },
    @{ Name = 'WS_VISIBLE';       Mask = 0x10000000; Source = 'style' },
    @{ Name = 'WS_POPUP';         Mask = 0x80000000; Source = 'style' }
)
foreach ($check in $checks) {
    $value = if ($check.Source -eq 'ex') { $ex } else { $style }
    $on = (($value -band $check.Mask) -ne 0)
    Write-Host ("  {0,-18} : {1}" -f $check.Name, $on)
}

$fg = [PetStyle.Native]::GetForegroundWindow()
$owner = 0
[PetStyle.Native]::GetWindowThreadProcessId($fg, [ref]$owner) | Out-Null
Write-Host ("foreground window is the pet: {0}" -f ($fg -eq $pet.Handle))
