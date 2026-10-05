# Probe-OpenHarness.ps1 - reproduce the click's "open Harness" path and report what fails.
#
# Clicking the pet runs Open-Harness, which tries, in order:
#   1. raise an existing window whose title identifies Harness;
#   2. launch the desktop executable;
#   3. open the discovered loopback URL.
#
# If step 1's SetForegroundWindow is refused (Windows only grants foreground rights
# to the process that owns the foreground window, or one that just received input),
# it returns FALSE and the code silently falls through. The pet is shown without
# activation, so it is never the foreground process — which makes this the prime
# suspect for "clicking does nothing".
#
# This reports the return value of every call so the failing step is identified
# rather than guessed.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -Namespace OpenProbe -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr SetFocus(System.IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@

function Get-Titled {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [OpenProbe.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([OpenProbe.Native]::IsWindowVisible($h)) {
            $len = [OpenProbe.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [OpenProbe.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $owner = 0
                [OpenProbe.Native]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
                $list.Add([pscustomobject]@{ H = $h; Title = $sb.ToString(); Pid = [int]$owner })
            }
        }
        return $true
    }
    [OpenProbe.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$foreground = [OpenProbe.Native]::GetForegroundWindow()
$fgPid = 0
[OpenProbe.Native]::GetWindowThreadProcessId($foreground, [ref]$fgPid) | Out-Null
Write-Host "current foreground hwnd=$foreground pid=$fgPid"
Write-Host "this script's pid = $PID, thread = $([OpenProbe.Native]::GetCurrentThreadId())"
Write-Host ''

$candidates = @(Get-Titled | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })
Write-Host "Harness-titled windows: $($candidates.Count)"
foreach ($c in $candidates) { Write-Host "  hwnd=$($c.H) pid=$($c.Pid) '$($c.Title)'" }
Write-Host ''

if ($candidates.Count -eq 0) { Write-Host 'nothing to raise'; exit 2 }
$target = $candidates[0]

Write-Host "=== step 1: raise hwnd $($target.H) ==="
if ([OpenProbe.Native]::IsIconic($target.H)) {
    Write-Host "  IsIconic = true; ShowWindow(SW_RESTORE) -> $([OpenProbe.Native]::ShowWindow($target.H, 9))"
} else {
    Write-Host '  IsIconic = false (not minimised)'
}
$btt = [OpenProbe.Native]::BringWindowToTop($target.H)
Write-Host "  BringWindowToTop -> $btt"
$sfw = [OpenProbe.Native]::SetForegroundWindow($target.H)
Write-Host "  SetForegroundWindow -> $sfw   <-- the suspect"
Start-Sleep -Milliseconds 400
$now = [OpenProbe.Native]::GetForegroundWindow()
Write-Host "  foreground is now hwnd=$now  (target reached: $($now -eq $target.H))"
Write-Host ''

Write-Host '=== the AttachThreadInput workaround ==='
# Windows refuses foreground changes from a background process. Temporarily
# attaching this thread's input queue to the foreground thread's makes the call
# legal, which is the standard fix.
$fgThread = [OpenProbe.Native]::GetWindowThreadProcessId($foreground, [ref]$fgPid)
$targetThread = [OpenProbe.Native]::GetWindowThreadProcessId($target.H, [ref]$fgPid)
$self = [OpenProbe.Native]::GetCurrentThreadId()
Write-Host "  foreground thread=$fgThread  target thread=$targetThread  self=$self"

$attached = $false
if ($fgThread -ne $self) {
    $attached = [OpenProbe.Native]::AttachThreadInput($self, $fgThread, $true)
    Write-Host "  AttachThreadInput(self, foreground) -> $attached"
}
$btt2 = [OpenProbe.Native]::BringWindowToTop($target.H)
$sfw2 = [OpenProbe.Native]::SetForegroundWindow($target.H)
Write-Host "  BringWindowToTop -> $btt2"
Write-Host "  SetForegroundWindow -> $sfw2   <-- with the workaround"
if ($attached) { [OpenProbe.Native]::AttachThreadInput($self, $fgThread, $false) | Out-Null }

Start-Sleep -Milliseconds 400
$after = [OpenProbe.Native]::GetForegroundWindow()
Write-Host "  foreground is now hwnd=$after  (target reached: $($after -eq $target.H))"
Write-Host ''
if ($after -eq $target.H) {
    Write-Host 'RESULT: the window can be raised, but only with AttachThreadInput.'
    exit 0
}
Write-Host 'RESULT: still not raised.'
exit 1
