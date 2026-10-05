# Probe-RaiseStrategies.ps1 - which way of raising a background window actually works?
#
# SetForegroundWindow is refused for a process that does not already own the
# foreground (Windows' foreground lock). The pet is shown without activation, so it
# is never the foreground process — meaning a click that relies on
# SetForegroundWindow alone silently does nothing, which is exactly the reported
# symptom.
#
# This tries each candidate against the real (minimised) Harness window and reports
# which one actually changes observable state, so the fix is chosen from evidence:
#
#   1. ShowWindow(SW_RESTORE)              - un-minimise, no foreground rights needed
#   2. SetWindowPos(HWND_TOP + SHOWWINDOW) - reorder to the top of the z-order
#   3. AttachThreadInput + SetForeground  - the classic foreground-lock workaround
#
# State is verified with IsIconic and GetForegroundWindow rather than trusting each
# call's return value, because ShowWindow's return value reports the PREVIOUS
# visibility, not success.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace Raise -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@

$HWND_TOP = [IntPtr]::Zero
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$SWP_SHOWWINDOW = 0x0040
$SW_RESTORE = 9
$SW_SHOW = 5

function Get-TitledWindows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [Raise.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([Raise.Native]::IsWindowVisible($h)) {
            $len = [Raise.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [Raise.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $owner = 0
                [Raise.Native]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
                $list.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString(); Pid = [int]$owner })
            }
        }
        return $true
    }
    [Raise.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Get-State([IntPtr]$h) {
    return [pscustomobject]@{
        Iconic = [Raise.Native]::IsIconic($h)
        Foreground = ([Raise.Native]::GetForegroundWindow() -eq $h)
    }
}

$candidates = @(Get-TitledWindows | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })
if ($candidates.Count -eq 0) { Write-Host 'No Harness-titled window found.'; exit 2 }

$target = $candidates[0]
$handle = $target.Handle
Write-Host "target: hwnd=$handle pid=$($target.Pid)"
Write-Host "        '$($target.Title)'"
Write-Host ''

$before = Get-State $handle
Write-Host "before      : iconic=$($before.Iconic) foreground=$($before.Foreground)"
Write-Host ''

Write-Host '--- strategy 1: ShowWindow(SW_RESTORE) ---'
[Raise.Native]::ShowWindow($handle, $SW_RESTORE) | Out-Null
Start-Sleep -Milliseconds 500
$s1 = Get-State $handle
Write-Host "after       : iconic=$($s1.Iconic) foreground=$($s1.Foreground)"
Write-Host "  restored (no longer iconic): $(($s1.Iconic -eq $false))"
Write-Host ''

Write-Host '--- strategy 2: SetWindowPos(HWND_TOP, SWP_SHOWWINDOW) ---'
[Raise.Native]::SetWindowPos($handle, $HWND_TOP, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
Start-Sleep -Milliseconds 400
$s2 = Get-State $handle
Write-Host "after       : iconic=$($s2.Iconic) foreground=$($s2.Foreground)"
Write-Host ''

Write-Host '--- strategy 3: AttachThreadInput + SetForegroundWindow ---'
$foreground = [Raise.Native]::GetForegroundWindow()
$fgPid = 0
$fgThread = [Raise.Native]::GetWindowThreadProcessId($foreground, [ref]$fgPid)
$self = [Raise.Native]::GetCurrentThreadId()
Write-Host "  foreground hwnd=$foreground thread=$fgThread ; self thread=$self"
$attached = $false
if ($fgThread -ne 0 -and $fgThread -ne $self) {
    $attached = [Raise.Native]::AttachThreadInput($self, $fgThread, $true)
    Write-Host "  AttachThreadInput -> $attached"
}
[Raise.Native]::ShowWindow($handle, $SW_RESTORE) | Out-Null
[Raise.Native]::BringWindowToTop($handle) | Out-Null
$setFg = [Raise.Native]::SetForegroundWindow($handle)
Write-Host "  SetForegroundWindow -> $setFg"
if ($attached) { [Raise.Native]::AttachThreadInput($self, $fgThread, $false) | Out-Null }
Start-Sleep -Milliseconds 500
$s3 = Get-State $handle
Write-Host "after       : iconic=$($s3.Iconic) foreground=$($s3.Foreground)"
Write-Host ''

Write-Host '=== summary ==='
Write-Host "  restored by SW_RESTORE          : $(($s1.Iconic -eq $false))"
Write-Host "  became foreground (strategy 3)  : $($s3.Foreground)"
Write-Host ''
if ($s1.Iconic -eq $false) {
    Write-Host 'The window CAN be un-minimised without foreground rights.'
    Write-Host 'Only keyboard focus needs the foreground lock, which this process cannot take.'
    exit 0
}
Write-Host 'Could not even un-minimise the window.'
exit 1
