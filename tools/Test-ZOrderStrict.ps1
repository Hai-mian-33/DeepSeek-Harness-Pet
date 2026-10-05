# Test-ZOrderStrict.ps1 - 严格测试"不依赖前台权限"的置前手段。
#
# 前台锁决定了后台进程无法夺取键盘焦点（6 种方法实测全败，见 Test-RaiseStrict.ps1）。
# 但用户要的是"让 Harness 出现在最前面"，这属于 z-order，不需要键盘焦点。本脚本专门
# 测量那些只改 z-order 的手段，并且：
#
#   * 每项测试前先把前台停靠到别的窗口，并断言目标确实非前台（否则就是假阳性）；
#   * 用 EnumWindows 的枚举顺序作为 z-order 指标（0 最前），它是客观的；
#   * 同时记录前台状态，区分"前移"与"夺焦点"两件不同的事。
#
# 候选手法：
#   A. SetWindowPos(HWND_TOP, SWP_SHOWWINDOW)
#   B. SetWindowPos(HWND_TOPMOST) -> SetWindowPos(HWND_NOTOPMOST)
#   C. ShowWindow(SW_MINIMIZE) -> ShowWindow(SW_RESTORE)
#   D. BringWindowToTop
#   E. 上面几种的组合

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace ZS -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, uint pid);
[DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool QueryFullProcessImageName(System.IntPtr h, uint flags, System.Text.StringBuilder name, ref uint size);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
'@

$SW_RESTORE = 9
$SW_MINIMIZE = 6
$SW_SHOW = 5
$HWND_TOP = [IntPtr]::Zero
$HWND_TOPMOST = [IntPtr](-1)
$HWND_NOTOPMOST = [IntPtr](-2)
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$SWP_SHOWWINDOW = 0x0040
$PQLI = 0x1000

function Get-ExePath([int]$processId) {
    $h = [ZS.Native]::OpenProcess($PQLI, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([ZS.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [ZS.Native]::CloseHandle($h) | Out-Null }
}

function Get-ZOrder {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [ZS.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([ZS.Native]::IsWindowVisible($h)) {
            $len = [ZS.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [ZS.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $op = 0
                [ZS.Native]::GetWindowThreadProcessId($h, [ref]$op) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h; Title = $sb.ToString(); Pid = [int]$op
                    Exe = (Get-ExePath ([int]$op))
                })
            }
        }
        return $true
    }
    [ZS.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Get-State([IntPtr]$handle) {
    $list = @(Get-ZOrder)
    $z = -1
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Handle -eq $handle) { $z = $i; break } }
    $state = New-Object psobject -Property @{
        Z = $z
        Foreground = ([ZS.Native]::GetForegroundWindow() -eq $handle)
        Iconic = [ZS.Native]::IsIconic($handle)
    }
    return $state
}

$windows = @(Get-ZOrder)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 桌面版无可见窗口'; exit 3 }
$park = @($windows | Where-Object {
    $_.Exe -notmatch 'DeepSeek Harness\.exe' -and $_.Title -notmatch '蓝鲸小深' -and $_.Title -ne ''
})[0]
if ($null -eq $park) { Write-Host 'SKIP: 找不到停靠窗口'; exit 3 }

$th = $target.Handle
$ph = $park.Handle
Write-Host "目标: hwnd=$th '$($target.Title)'"
Write-Host "总窗口数: $($windows.Count)"
Write-Host ''

function Reset-Parked {
    [ZS.Native]::ShowWindow($ph, $SW_RESTORE) | Out-Null
    [ZS.Native]::SetForegroundWindow($ph) | Out-Null
    Start-Sleep -Milliseconds 450
}

$results = [ordered]@{}

function Try-Method([string]$name, [scriptblock]$action) {
    Reset-Parked
    $before = Get-State $th
    if ($before.Foreground) {
        Write-Host ("  {0,-46} 跳过（前提不成立：目标已是前台）" -f $name)
        return
    }
    & $action
    Start-Sleep -Milliseconds 400
    $after = Get-State $th

    $moved = ($before.Z -ge 0) -and ($after.Z -ge 0) -and ($after.Z -lt $before.Z)
    if ($after.Foreground) { $verdict = 'FRONT:前台' }
    elseif ($after.Z -eq 0) { $verdict = 'FRONT:最顶层' }
    elseif ($moved) { $verdict = 'FRONT:前移' }
    elseif ($before.Iconic -and -not $after.Iconic) { $verdict = 'RESTORED:已还原' }
    else { $verdict = 'NONE:无变化' }

    $results[$name] = $verdict
    Write-Host ("  {0,-46} {1,-16} z {2}->{3}" -f $name, $verdict, $before.Z, $after.Z)
}

Write-Host '每项前都把前台停到别处，并确认目标非前台：'
Write-Host ''

Try-Method 'A. SetWindowPos(HWND_TOP, SHOWWINDOW)' {
    [ZS.Native]::SetWindowPos($th, $HWND_TOP, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
}

Try-Method 'B. TOPMOST -> NOTOPMOST' {
    [ZS.Native]::SetWindowPos($th, $HWND_TOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
    Start-Sleep -Milliseconds 200
    [ZS.Native]::SetWindowPos($th, $HWND_NOTOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
}

Try-Method 'C. MINIMIZE -> RESTORE' {
    [ZS.Native]::ShowWindow($th, $SW_MINIMIZE) | Out-Null
    Start-Sleep -Milliseconds 350
    [ZS.Native]::ShowWindow($th, $SW_RESTORE) | Out-Null
}

Try-Method 'D. BringWindowToTop' {
    [ZS.Native]::BringWindowToTop($th) | Out-Null
}

Try-Method 'E. TOPMOST->NOTOPMOST + MIN->RESTORE' {
    [ZS.Native]::SetWindowPos($th, $HWND_TOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
    Start-Sleep -Milliseconds 150
    [ZS.Native]::SetWindowPos($th, $HWND_NOTOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
    Start-Sleep -Milliseconds 150
    [ZS.Native]::ShowWindow($th, $SW_MINIMIZE) | Out-Null
    Start-Sleep -Milliseconds 300
    [ZS.Native]::ShowWindow($th, $SW_RESTORE) | Out-Null
    Start-Sleep -Milliseconds 200
    [ZS.Native]::BringWindowToTop($th) | Out-Null
}

Write-Host ''
Write-Host '=== 汇总（前提成立的项）==='
$front = @()
foreach ($e in $results.GetEnumerator()) {
    if ($e.Value -like 'FRONT*') { $front += "$($e.Key) -> $($e.Value)" }
}
if ($front.Count -eq 0) {
    Write-Host '  没有任何手段能让窗口前移。'
    exit 1
}
foreach ($f in $front) { Write-Host "  $f" }
Write-Host ''
Write-Host '这些手段不需要前台（键盘焦点）权限，因此在真实点击后必然可用。'
exit 0
