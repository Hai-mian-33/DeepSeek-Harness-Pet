# Test-OpenHarness.ps1 - does a click actually raise Harness, minimised or not?
#
# The earlier verification for this only checked that a Harness-titled window EXISTS,
# which is why a completely broken raise passed as "PASS". This checks the thing that
# matters: that the window is the FOREGROUND window afterwards.
#
# The shell's own `Invoke-RaiseWindow` is loaded from the real source so the test
# exercises the shipped logic rather than a copy of it.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }

# Pull just the two functions under test out of the shell. Sourcing the whole file
# would start the pet, so the definitions are extracted textually.
$shellPath = Join-Path $Root 'src\shell\WhalePet.ps1'
$text = [System.IO.File]::ReadAllText($shellPath)

function Get-FunctionSource([string]$name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($name))\s*\{.*?^\}"
    $match = [regex]::Match($text, $pattern)
    if (-not $match.Success) { throw "could not extract $name from the shell" }
    return $match.Value
}

Add-Type -Namespace TestRaise -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(System.IntPtr h, bool alt);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@

# `PetNative.Win` is what the extracted code calls into; provide it under that name.
if (-not ('PetNative.Win' -as [type])) {
    Add-Type -Namespace PetNative -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(System.IntPtr h, bool alt);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@
}

Invoke-Expression (Get-FunctionSource 'Test-IsForeground')
Invoke-Expression (Get-FunctionSource 'Invoke-RaiseWindow')

function Get-TitledWindows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [TestRaise.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([TestRaise.Native]::IsWindowVisible($h)) {
            $len = [TestRaise.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [TestRaise.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $list.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString() })
            }
        }
        return $true
    }
    [TestRaise.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$targets = @(Get-TitledWindows | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })
if ($targets.Count -eq 0) { Write-Host 'SKIP: no Harness window is open.'; exit 3 }
$handle = $targets[0].Handle
Write-Host "target: '$($targets[0].Title)'  hwnd=$handle"
Write-Host ''

$failures = 0

Write-Host '--- case 1: window is open (not minimised) ---'
[TestRaise.Native]::ShowWindow($handle, 9) | Out-Null
Start-Sleep -Milliseconds 500
$raised = Invoke-RaiseWindow -Handle $handle
$isFg = Test-IsForeground -Handle $handle
Write-Host "  Invoke-RaiseWindow -> $raised ; foreground now: $isFg"
if (-not $isFg) { $failures++ }

Write-Host ''
Write-Host '--- case 2: window is MINIMISED (the case that used to fail) ---'
# Park the foreground on something else so this starts from a real disadvantage.
[TestRaise.Native]::ShowWindow($handle, 6) | Out-Null   # SW_MINIMIZE
Start-Sleep -Milliseconds 700
Write-Host "  minimized: iconic=$([TestRaise.Native]::IsIconic($handle))"
$raised2 = Invoke-RaiseWindow -Handle $handle
$isFg2 = Test-IsForeground -Handle $handle
$isIconic2 = [TestRaise.Native]::IsIconic($handle)
Write-Host "  Invoke-RaiseWindow -> $raised2 ; iconic now: $isIconic2 ; foreground now: $isFg2"
if ($isIconic2) { $failures++ }
if (-not $isFg2) { $failures++ }

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: Harness is raised to the foreground, both open and minimised.'
    exit 0
}
Write-Host "FAIL: $failures assertion(s) failed."
exit 1
