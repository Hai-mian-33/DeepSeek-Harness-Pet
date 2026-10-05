# Test-RealClickScenario.ps1 - 复现真实场景：Harness 不在前台时，shell 能否把它唤起？
#
# 之前日志里的 "direct raise returned True" 是假阳性：当时 Harness 本来就是前台，
# Test-HarnessForeground 立即为真，提升代码从未真正执行。
#
# 本脚本严格复现真实场景：
#   1. 把前台抢到别的窗口（确认 Harness 确实不在前台）；
#   2. 通过 shell 的命令通道触发 open-harness（即点击桌宠所做的事）；
#   3. 读 shell 诊断日志，看它记录的确切结果与错误码。
#
# 这样得到的是 shell 自己进程内的真实行为，而不是外部进程的推测。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }

Add-Type -Namespace RealClick -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
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

$PQLI = 0x1000
function Get-ExePath([int]$processId) {
    $h = [RealClick.Native]::OpenProcess($PQLI, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([RealClick.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [RealClick.Native]::CloseHandle($h) | Out-Null }
}

function Get-Windows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [RealClick.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([RealClick.Native]::IsWindowVisible($h)) {
            $len = [RealClick.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [RealClick.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $op = 0
                [RealClick.Native]::GetWindowThreadProcessId($h, [ref]$op) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h; Title = $sb.ToString(); Pid = [int]$op
                    Exe = (Get-ExePath ([int]$op))
                })
            }
        }
        return $true
    }
    [RealClick.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$logPath = Join-Path $Root 'build\shell-diag.log'
$commandPath = Join-Path $Root 'state\shell-command.json'

# 记录调用前的日志长度，之后只读新增部分
$logBefore = 0
if (Test-Path $logPath) { $logBefore = (Get-Item $logPath).Length }

$windows = @(Get-Windows)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 桌面版无可见窗口'; exit 3 }
$park = @($windows | Where-Object {
    $_.Exe -notmatch 'DeepSeek Harness\.exe' -and $_.Title -notmatch '蓝鲸小深' -and $_.Title -ne ''
})[0]
if ($null -eq $park) { Write-Host 'SKIP: 找不到停靠窗口'; exit 3 }

$th = $target.Handle
Write-Host "Harness 桌面窗口: hwnd=$th"
Write-Host "停靠窗口        : hwnd=$($park.Handle) '$($park.Title)'"
Write-Host ''

# 步骤 1：把前台抢走，确认 Harness 不在前台
[RealClick.Native]::ShowWindow($park.Handle, 9) | Out-Null
[RealClick.Native]::SetForegroundWindow($park.Handle) | Out-Null
Start-Sleep -Milliseconds 800
$fg = [RealClick.Native]::GetForegroundWindow()
if ($fg -eq $th) {
    Write-Host 'SKIP: 无法把前台从 Harness 移开，前提不成立（会得到假阳性）。'
    exit 3
}
Write-Host "✔ 前提成立：Harness 不在前台（前台 hwnd=$fg）"
Write-Host ''

# 步骤 2：通过命令通道触发 open-harness（等价于点击桌宠）
Write-Host '触发 open-harness（与点击桌宠相同的代码路径）...'
[System.IO.File]::WriteAllText($commandPath, '{"command":"open-harness"}', [System.Text.UTF8Encoding]::new($false))
Start-Sleep -Seconds 7

# 步骤 3：读新增日志
Write-Host ''
Write-Host '=== shell 自身的记录 ==='
if (Test-Path $logPath) {
    $text = [System.IO.File]::ReadAllText($logPath)
    $new = $text.Substring([Math]::Min($logBefore, $text.Length))
    foreach ($line in ($new -split "`r?`n")) {
        if ($line.Trim() -ne '') { Write-Host "  $line" }
    }
} else {
    Write-Host '  (诊断日志不存在)'
}

$fgAfter = [RealClick.Native]::GetForegroundWindow()
$ok = ($fgAfter -eq $th)
Write-Host ''
Write-Host "调用后前台 hwnd=$fgAfter"
Write-Host "Harness 成为前台: $ok"
Write-Host ''
if ($ok) {
    Write-Host 'PASS: 在真实场景（Harness 原本非前台）下，shell 成功把它带到了前台。'
    exit 0
}
Write-Host 'FAIL: Harness 仍未成为前台 —— 原因见上面 shell 自身的记录。'
exit 1
