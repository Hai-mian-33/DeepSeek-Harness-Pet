# Probe-RaiseMethods.ps1 - find a raise method that works from a background process.
#
# `SetForegroundWindow` is refused here: the pet is shown without activation, so it
# never owns the foreground, and Windows only grants foreground changes to the
# process that owns the foreground window or one that has just received input. The
# click therefore did nothing at all.
#
# Candidate workarounds, each verified by observable state (GetForegroundWindow)
# rather than by a return value:
#
#   1. SetForegroundWindow alone                       (known to fail)
#   2. SwitchToThisWindow                              (the taskbar's own call)
#   3. WScript.Shell AppActivate                        (COM; different code path)
#   4. AttachThreadInput + SetForegroundWindow + focus
#   5. A synthetic ALT tap, then SetForegroundWindow    (unlocks foreground rights)
#   6. ShowWindow(SW_MINIMIZE) then SW_RESTORE

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace RM -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(System.IntPtr h, bool altTab);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern System.IntPtr SetActiveWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr SetFocus(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@

$SW_RESTORE = 9
$SW_MINIMIZE = 6
$VK_MENU = 0x12
$KEYEVENTF_KEYUP = 0x0002

function Get-TitledWindows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [RM.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([RM.Native]::IsWindowVisible($h)) {
            $len = [RM.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [RM.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $owner = 0
                [RM.Native]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
                $list.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString(); Pid = [int]$owner })
            }
        }
        return $true
    }
    [RM.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Test-Foreground([IntPtr]$h) { return ([RM.Native]::GetForegroundWindow() -eq $h) }

$candidates = @(Get-TitledWindows | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })
if ($candidates.Count -eq 0) { Write-Host 'No Harness-titled window.'; exit 2 }
$target = $candidates[0]
$handle = $target.Handle

Write-Host "target hwnd=$handle pid=$($target.Pid)"
Write-Host "       '$($target.Title)'"
Write-Host "starts foreground: $(Test-Foreground $handle)"
Write-Host ''
Write-Host ('{0,-46} {1}' -f 'method', 'became foreground')
Write-Host ('-' * 62)

function Reset-Window {
    # Park focus elsewhere so each trial starts from the same disadvantage.
    $desktop = [RM.Native]::GetForegroundWindow()
    Start-Sleep -Milliseconds 150
}

$results = [ordered]@{}

# 1 - the known failure, for a baseline.
Reset-Window
[RM.Native]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 350
$results['1. SetForegroundWindow (baseline)'] = Test-Foreground $handle

# 2 - SwitchToThisWindow, what the taskbar uses.
Reset-Window
[RM.Native]::SwitchToThisWindow($handle, $true)
Start-Sleep -Milliseconds 400
$results['2. SwitchToThisWindow'] = Test-Foreground $handle

# 3 - WScript.Shell AppActivate.
Reset-Window
$ok3 = $false
try {
    $shell = New-Object -ComObject WScript.Shell
    $ok3 = $shell.AppActivate($target.Pid)
} catch { $ok3 = "err: $($_.Exception.Message)" }
Start-Sleep -Milliseconds 400
$results["3. WScript.Shell AppActivate (returned $ok3)"] = Test-Foreground $handle

# 4 - AttachThreadInput, then foreground, then focus the window itself.
Reset-Window
$fg = [RM.Native]::GetForegroundWindow()
$fgPid = 0
$fgThread = [RM.Native]::GetWindowThreadProcessId($fg, [ref]$fgPid)
$self = [RM.Native]::GetCurrentThreadId()
$attached = $false
if ($fgThread -ne 0 -and $fgThread -ne $self) { $attached = [RM.Native]::AttachThreadInput($self, $fgThread, $true) }
[RM.Native]::BringWindowToTop($handle) | Out-Null
[RM.Native]::SetForegroundWindow($handle) | Out-Null
[RM.Native]::SetActiveWindow($handle) | Out-Null
[RM.Native]::SetFocus($handle) | Out-Null
if ($attached) { [RM.Native]::AttachThreadInput($self, $fgThread, $false) | Out-Null }
Start-Sleep -Milliseconds 450
$results["4. AttachThreadInput chain (attached=$attached)"] = Test-Foreground $handle

# 5 - synthetic ALT tap to unlock foreground rights, then claim it.
Reset-Window
[RM.Native]::keybd_event($VK_MENU, 0, 0, [System.UIntPtr]::Zero)
Start-Sleep -Milliseconds 60
[RM.Native]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [System.UIntPtr]::Zero)
Start-Sleep -Milliseconds 120
[RM.Native]::ShowWindow($handle, $SW_RESTORE) | Out-Null
[RM.Native]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 450
$results['5. ALT tap + SetForegroundWindow'] = Test-Foreground $handle

# 6 - minimise then restore.
Reset-Window
[RM.Native]::ShowWindow($handle, $SW_MINIMIZE) | Out-Null
Start-Sleep -Milliseconds 300
[RM.Native]::ShowWindow($handle, $SW_RESTORE) | Out-Null
Start-Sleep -Milliseconds 450
$results['6. minimize then restore'] = Test-Foreground $handle

foreach ($entry in $results.GetEnumerator()) {
    Write-Host ('{0,-46} {1}' -f $entry.Key, $entry.Value)
}

Write-Host ''
$winners = @($results.GetEnumerator() | Where-Object { $_.Value -eq $true })
if ($winners.Count -gt 0) {
    Write-Host "WORKS: $($winners[0].Key)"
    exit 0
}
Write-Host 'None of these made the window foreground from a background process.'
exit 1
