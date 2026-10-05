# Test-RaiseMethodsStrict.ps1 - 严格测量各种"夺取前台"手段，前提是目标确实不在前台。
#
# 之前所有提升测试都有同一个致命缺陷：目标窗口当时已经是前台，于是
# `GetForegroundWindow() == handle` 恒为真，任何方法都"通过"，被测代码从未真正起作用。
# 这导致我先后得出过两个相反的错误结论。
#
# 本脚本先强制制造劣势（把前台停靠到别的窗口），断言确认目标非前台，然后逐一测试，
# 并同时测量三个客观指标：
#
#   前台   : GetForegroundWindow() == 目标
#   z 序   : EnumWindows 的枚举索引（0 最前），反映层叠顺序
#   最小化 : IsIconic
#
# 候选手段（都用于"后台进程唤起另一个程序的窗口"这个真实场景）：
#   1. SetForegroundWindow
#   2. ShowWindow(SW_MINIMIZE) -> ShowWindow(SW_RESTORE)   最小化再还原会被系统置前
#   3. 合成 ALT 敲击 -> SetForegroundWindow                让系统认为用户刚按过键
#   4. AttachThreadInput + BringWindowToTop + SetForegroundWindow
#   5. SetWindowPos(HWND_TOPMOST) -> SetWindowPos(HWND_NOTOPMOST)
#   6. 合成 ALT + AttachThreadInput + SetForegroundWindow  组合
#
# 注意：本脚本进程从未收到过输入事件，而 Windows 会把前台权限授予"最近收到输入的
# 进程"。真实点击桌宠时 shell 会收到输入，条件优于本脚本 —— 所以这里的失败不代表
# shell 内也失败，但成功则一定可行。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace Strict -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr SetActiveWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr SetFocus(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
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
$VK_MENU = 0x12
$KEYUP = 0x0002
$HWND_TOPMOST = [IntPtr](-1)
$HWND_NOTOPMOST = [IntPtr](-2)
$SWP_NOMOVE = 0x0002
$SWP_NOSIZE = 0x0001
$SWP_SHOWWINDOW = 0x0040
$PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

function Get-ExePath([int]$processId) {
    $h = [Strict.Native]::OpenProcess($PROCESS_QUERY_LIMITED_INFORMATION, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([Strict.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [Strict.Native]::CloseHandle($h) | Out-Null }
}

function Get-WindowsZ {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [Strict.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([Strict.Native]::IsWindowVisible($h)) {
            $len = [Strict.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [Strict.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $ownerPid = 0
                [Strict.Native]::GetWindowThreadProcessId($h, [ref]$ownerPid) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h; Title = $sb.ToString()
                    Pid = [int]$ownerPid; Exe = (Get-ExePath ([int]$ownerPid))
                    Iconic = [Strict.Native]::IsIconic($h)
                })
            }
        }
        return $true
    }
    [Strict.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Measure([IntPtr]$handle) {
    # `@()` and the array index keep this to a single returned object: PowerShell
    # unrolls collections, so a stray item would make the caller's property access
    # bind to the wrong value ("The property 'Foreground' cannot be found").
    $list = @(Get-WindowsZ)
    $z = -1
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Handle -eq $handle) { $z = $i; break } }
    $object = New-Object psobject -Property @{
        Foreground = ([Strict.Native]::GetForegroundWindow() -eq $handle)
        Z = $z
        Iconic = [Strict.Native]::IsIconic($handle)
    }
    return $object
}

$windows = @(Get-WindowsZ)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 桌面版无可见窗口'; exit 3 }
$park = @($windows | Where-Object { $_.Exe -notmatch 'DeepSeek Harness\.exe' -and $_.Title -notmatch '蓝鲸小深' -and $_.Title -ne '' })[0]
if ($null -eq $park) { Write-Host 'SKIP: 找不到停靠窗口'; exit 3 }

$th = $target.Handle
$ph = $park.Handle
Write-Host "目标: hwnd=$th  '$($target.Title)'"
Write-Host "停靠: hwnd=$ph  '$($park.Title)'"
Write-Host ''

function Initialize-Measure {
    <#
    .SYNOPSIS
        Record the target's current foreground / z-order / minimised state.
    .DESCRIPTION
        Results go into script-scope variables rather than being returned. PowerShell
        unrolls collections from a function's output, so returning an object from a
        helper that also calls EnumWindows produced an array and the caller's property
        access failed with "The property 'Foreground' cannot be found on this object".
    #>
    param([IntPtr]$Handle, [string]$Prefix)
    $list = @(Get-WindowsZ)
    $z = -1
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Handle -eq $Handle) { $z = $i; break } }
    Set-Variable -Name "${Prefix}Fg" -Value ([Strict.Native]::GetForegroundWindow() -eq $Handle) -Scope Script
    Set-Variable -Name "${Prefix}Z" -Value $z -Scope Script
    Set-Variable -Name "${Prefix}Iconic" -Value ([Strict.Native]::IsIconic($Handle)) -Scope Script
}

function Reset-Foreground {
    # 把前台停到停靠窗口，制造"目标非前台"的真实前提。
    [Strict.Native]::ShowWindow($ph, $SW_RESTORE) | Out-Null
    [Strict.Native]::SetForegroundWindow($ph) | Out-Null
    Start-Sleep -Milliseconds 500
}

$results = [ordered]@{}

function Try-Method([string]$name, [scriptblock]$action) {
    Reset-Foreground
    Initialize-Measure -Handle $th -Prefix 'Before'
    if ($script:BeforeFg) {
        Write-Host ("  {0,-44} 跳过（无法把前台移开）" -f $name)
        return
    }
    & $action
    Start-Sleep -Milliseconds 450
    Initialize-Measure -Handle $th -Prefix 'After'

    $zImproved = ($script:BeforeZ -ge 0) -and ($script:AfterZ -ge 0) -and ($script:AfterZ -lt $script:BeforeZ)
    if ($script:AfterFg) { $verdict = '前台' }
    elseif ($zImproved) { $verdict = 'z序前移' }
    elseif ($script:BeforeIconic -and -not $script:AfterIconic) { $verdict = '已还原' }
    else { $verdict = '无变化' }

    $results[$name] = $verdict
    Write-Host ("  {0,-44} {1,-8} z {2}->{3}" -f $name, $verdict, $script:BeforeZ, $script:AfterZ)
}

Write-Host '每项测试前都把前台停到别处，并确认目标非前台：'
Write-Host ''

Try-Method '1. SetForegroundWindow' {
    [Strict.Native]::SetForegroundWindow($th) | Out-Null
}

Try-Method '2. 最小化 -> 还原' {
    [Strict.Native]::ShowWindow($th, $SW_MINIMIZE) | Out-Null
    Start-Sleep -Milliseconds 400
    [Strict.Native]::ShowWindow($th, $SW_RESTORE) | Out-Null
}

Try-Method '3. 合成 ALT -> SetForegroundWindow' {
    [Strict.Native]::keybd_event($VK_MENU, 0, 0, [System.UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [Strict.Native]::keybd_event($VK_MENU, 0, $KEYUP, [System.UIntPtr]::Zero)
    Start-Sleep -Milliseconds 150
    [Strict.Native]::SetForegroundWindow($th) | Out-Null
}

Try-Method '4. AttachThreadInput + BringWindowToTop + SFW' {
    $fg = [Strict.Native]::GetForegroundWindow()
    $pid2 = 0
    $fgt = [Strict.Native]::GetWindowThreadProcessId($fg, [ref]$pid2)
    $self = [Strict.Native]::GetCurrentThreadId()
    $att = $false
    if ($fgt -ne 0 -and $fgt -ne $self) { $att = [Strict.Native]::AttachThreadInput($self, $fgt, $true) }
    [Strict.Native]::BringWindowToTop($th) | Out-Null
    [Strict.Native]::SetForegroundWindow($th) | Out-Null
    [Strict.Native]::SetActiveWindow($th) | Out-Null
    if ($att) { [Strict.Native]::AttachThreadInput($self, $fgt, $false) | Out-Null }
}

Try-Method '5. SetWindowPos TOPMOST -> NOTOPMOST' {
    [Strict.Native]::SetWindowPos($th, $HWND_TOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
    Start-Sleep -Milliseconds 200
    [Strict.Native]::SetWindowPos($th, $HWND_NOTOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
}

Try-Method '6. 合成 ALT + AttachThreadInput + SFW' {
    [Strict.Native]::keybd_event($VK_MENU, 0, 0, [System.UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Strict.Native]::keybd_event($VK_MENU, 0, $KEYUP, [System.UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    $fg = [Strict.Native]::GetForegroundWindow()
    $pid2 = 0
    $fgt = [Strict.Native]::GetWindowThreadProcessId($fg, [ref]$pid2)
    $self = [Strict.Native]::GetCurrentThreadId()
    $att = $false
    if ($fgt -ne 0 -and $fgt -ne $self) { $att = [Strict.Native]::AttachThreadInput($self, $fgt, $true) }
    [Strict.Native]::BringWindowToTop($th) | Out-Null
    [Strict.Native]::SetForegroundWindow($th) | Out-Null
    if ($att) { [Strict.Native]::AttachThreadInput($self, $fgt, $false) | Out-Null }
}

Write-Host ''
Write-Host '=== 汇总（仅统计前提成立的测试）==='
$winners = @()
foreach ($e in $results.GetEnumerator()) {
    if ($e.Value -eq '前台' -or $e.Value -eq 'z序前移' -or $e.Value -eq '已还原') { $winners += "$($e.Key) [$($e.Value)]" }
}
if ($winners.Count -eq 0) {
    Write-Host '  没有任何手段能在后台进程中把该窗口置前。'
    exit 1
}
foreach ($w in $winners) { Write-Host "  可用: $w" }
exit 0
