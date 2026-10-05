# Test-ForegroundLock.ps1 - 严格测试：目标窗口"确实不是前台"时，哪种方法能提升它。
#
# 之前的测试是无效的：目标窗口当时已经是前台，于是 GetForegroundWindow() == handle
# 恒为真，六种方法全部"通过"。真实 shell 进程内的日志则显示所有方法都被拒绝。
#
# 本脚本修正了这个错误：先把前台切到另一个窗口（桌宠窗口），确认目标确实不是前台，
# 再逐一尝试，并用 GetForegroundWindow 验证。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace FL -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(System.IntPtr h, bool alt);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern System.IntPtr SetActiveWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@

$SW_RESTORE = 9
$SW_SHOW = 5
$SW_MINIMIZE = 6
$VK_MENU = 0x12
$KEYUP = 0x0002

function Get-Windows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [FL.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([FL.Native]::IsWindowVisible($h)) {
            $len = [FL.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [FL.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $list.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString() })
            }
        }
        return $true
    }
    [FL.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Show-Fg([string]$label) {
    $fg = [FL.Native]::GetForegroundWindow()
    Write-Host "    [$label] 前台=$fg"
    return $fg
}

$windows = Get-Windows
$target = @($windows | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })[0]
$pet = @($windows | Where-Object { $_.Title -match '^蓝鲸小深$' })[0]

if ($null -eq $target) { Write-Host 'SKIP: 没有 Harness 窗口'; exit 3 }
$th = $target.Handle
Write-Host "目标: hwnd=$th"
Write-Host "       '$($target.Title)'"
Write-Host ''

# 「停靠窗口」：把前台切到别处，让目标确实不是前台。
$park = if ($null -ne $pet) { $pet.Handle } else { [FL.Native]::GetForegroundWindow() }
Write-Host "停靠窗口 hwnd=$park"

function Reset-Foreground {
    [FL.Native]::ShowWindow($park, $SW_RESTORE) | Out-Null
    [FL.Native]::SetForegroundWindow($park) | Out-Null
    Start-Sleep -Milliseconds 350
    return ([FL.Native]::GetForegroundWindow() -eq $park)
}

$results = [ordered]@{}

function Try-Method([string]$name, [scriptblock]$action) {
    $parked = Reset-Foreground
    $fgBefore = [FL.Native]::GetForegroundWindow()
    $wasNotFg = ($fgBefore -ne $th)
    & $action
    Start-Sleep -Milliseconds 400
    $ok = ([FL.Native]::GetForegroundWindow() -eq $th)
    $mark = if ($ok) { '成功' } else { '失败' }
    Write-Host ("  {0,-46} {1}   (停靠成功={2} 目标原本非前台={3})" -f $name, $mark, $parked, $wasNotFg)
    $results[$name] = ($ok -and $wasNotFg)
}

Write-Host '把前台停靠到桌宠窗口，然后逐一测试：'
Write-Host ''

Try-Method '1. SetForegroundWindow' {
    [FL.Native]::SetForegroundWindow($th) | Out-Null
}

Try-Method '2. SwitchToThisWindow' {
    [FL.Native]::SwitchToThisWindow($th, $true)
}

Try-Method '3. ShowWindow(SW_RESTORE)（非最小化时）' {
    [FL.Native]::ShowWindow($th, $SW_RESTORE) | Out-Null
}

Try-Method '4. 最小化→还原' {
    [FL.Native]::ShowWindow($th, $SW_MINIMIZE) | Out-Null
    Start-Sleep -Milliseconds 350
    [FL.Native]::ShowWindow($th, $SW_RESTORE) | Out-Null
}

Try-Method '5. AttachThreadInput + SetForegroundWindow' {
    $fg = [FL.Native]::GetForegroundWindow()
    $pid2 = 0
    $fgt = [FL.Native]::GetWindowThreadProcessId($fg, [ref]$pid2)
    $self = [FL.Native]::GetCurrentThreadId()
    $att = $false
    if ($fgt -ne 0 -and $fgt -ne $self) { $att = [FL.Native]::AttachThreadInput($self, $fgt, $true) }
    [FL.Native]::BringWindowToTop($th) | Out-Null
    [FL.Native]::SetForegroundWindow($th) | Out-Null
    [FL.Native]::SetActiveWindow($th) | Out-Null
    if ($att) { [FL.Native]::AttachThreadInput($self, $fgt, $false) | Out-Null }
}

Try-Method '6. 合成 ALT 敲击 + SetForegroundWindow' {
    [FL.Native]::keybd_event($VK_MENU, 0, 0, [System.UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [FL.Native]::keybd_event($VK_MENU, 0, $KEYUP, [System.UIntPtr]::Zero)
    Start-Sleep -Milliseconds 150
    [FL.Native]::SetForegroundWindow($th) | Out-Null
}

Try-Method '7. SetWindowPos(HWND_TOP)+SWP_SHOWWINDOW' {
    [FL.Native]::SetWindowPos($th, [IntPtr]::Zero, 0, 0, 0, 0, (0x0002 -bor 0x0001 -bor 0x0040)) | Out-Null
}

Write-Host ''
Write-Host '=== 结论（仅在"目标原本非前台"时才算有效）==='
$winners = @($results.GetEnumerator() | Where-Object { $_.Value -eq $true })
if ($winners.Count -eq 0) {
    Write-Host '  没有任何方法能在后台进程中把窗口提升为前台。'
    Write-Host '  这与 shell 进程内的日志一致：raise: every method refused'
    exit 1
}
foreach ($w in $winners) { Write-Host "  可行: $($w.Key)" }
exit 0
