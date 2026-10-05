# Verify-RaiseFromOutside.ps1 - 严格验证"沙箱外实例能唤起 Harness"这一结论。
#
# 之前从沙箱内测试时，目标窗口往往本来就是前台，检查立即为真，提升代码从未执行 ——
# 属于假阳性。本脚本用"先把窗口最小化"来制造一个不可能为真的前提：
#
#   * 最小化的窗口 **不可能是前台窗口**，因此不存在假阳性的余地；
#   * 然后通过桌宠的命令通道触发 open-harness（等价于点击桌宠）；
#   * 读 shell 自己的诊断日志，并用 IsIconic / GetForegroundWindow 独立复核。
#
# 该脚本必须在桌宠由普通终端启动（即运行在沙箱之外）时才有意义。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }

Add-Type -Namespace VerifyRaise -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
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
    $h = [VerifyRaise.Native]::OpenProcess($PQLI, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([VerifyRaise.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [VerifyRaise.Native]::CloseHandle($h) | Out-Null }
}

function Get-Windows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [VerifyRaise.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([VerifyRaise.Native]::IsWindowVisible($h)) {
            $len = [VerifyRaise.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [VerifyRaise.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $op = 0
                [VerifyRaise.Native]::GetWindowThreadProcessId($h, [ref]$op) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h; Title = $sb.ToString(); Pid = [int]$op
                    Exe = (Get-ExePath ([int]$op))
                })
            }
        }
        return $true
    }
    [VerifyRaise.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$windows = @(Get-Windows)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 未找到 Harness 桌面窗口'; exit 3 }

$th = $target.Handle
$logPath = Join-Path $Root 'build\shell-diag.log'
$commandPath = Join-Path $Root 'state\shell-command.json'

$logBefore = 0
if (Test-Path $logPath) { $logBefore = (Get-Item $logPath).Length }

Write-Host "目标: hwnd=$th"
Write-Host "      '$($target.Title)'"
Write-Host ''

# 制造不可能为真的前提：最小化目标窗口。
Write-Host '步骤 1：最小化 Harness 窗口（最小化窗口不可能是前台，排除假阳性）'
[VerifyRaise.Native]::ShowWindow($th, 6) | Out-Null
Start-Sleep -Milliseconds 700
$iconic = [VerifyRaise.Native]::IsIconic($th)
$isFg = ([VerifyRaise.Native]::GetForegroundWindow() -eq $th)
Write-Host "  最小化: $iconic ; 是前台: $isFg"
if (-not $iconic -and -not $isFg) {
    Write-Host '  （窗口既未最小化也非前台，前提仍有效）'
} elseif ($isFg) {
    Write-Host '  FAIL: 窗口仍是前台，前提不成立'; exit 3
}
Write-Host ''

Write-Host '步骤 2：通过桌宠的命令通道触发 open-harness（等价于点击桌宠）'
[System.IO.File]::WriteAllText($commandPath, '{"command":"open-harness"}', [System.Text.UTF8Encoding]::new($false))
Start-Sleep -Seconds 7

Write-Host ''
Write-Host '步骤 3：复核结果'
$iconicAfter = [VerifyRaise.Native]::IsIconic($th)
$fgAfter = ([VerifyRaise.Native]::GetForegroundWindow() -eq $th)
Write-Host "  仍最小化: $iconicAfter"
Write-Host "  成为前台: $fgAfter"

Write-Host ''
Write-Host '=== shell 自身的记录 ==='
if (Test-Path $logPath) {
    $text = [System.IO.File]::ReadAllText($logPath)
    $new = $text.Substring([Math]::Min($logBefore, $text.Length))
    foreach ($line in ($new -split "`r?`n")) {
        if ($line.Trim() -ne '') { Write-Host "  $line" }
    }
}

Write-Host ''
if ($fgAfter) {
    Write-Host 'PASS: 窗口从"最小化且非前台"被成功唤起为前台。'
    Write-Host '      这证明：从普通终端运行的桌宠能够唤起 Harness 桌面版。'
    exit 0
}
Write-Host 'FAIL: 窗口未被唤起为前台。'
exit 1
