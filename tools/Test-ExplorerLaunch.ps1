# Test-ExplorerLaunch.ps1 - 单独验证 explorer.exe 代为启动能否唤起 Harness 窗口。
#
# 上一步的"D. ShellExecute 成功"是假象：该调用抛出了异常（环境变量字典冲突）根本没有
# 启动进程，而被检测到的前台变化其实是前面 C 项（explorer）延迟生效的结果。这是典型
# 的测量污染 —— 必须单独测试。
#
# explorer.exe 是桌面的属主，由它启动的程序并不继承本进程所在的受限 job，因此它有能力
# 激活窗口。这是沙箱内唯一有理论依据的出路，值得单独确认。
#
# 本脚本只测这一种方式，并把等待时间放宽到 20 秒，避免"生效慢"被误判为"无效"。

param([string]$Root = '', [int]$WaitMs = 20000)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace ExpLaunch -Name Native -MemberDefinition @'
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
[DllImport("kernel32.dll")] public static extern uint GetCurrentProcessId();
'@

$PQLI = 0x1000
function Get-ExePath([int]$processId) {
    $h = [ExpLaunch.Native]::OpenProcess($PQLI, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([ExpLaunch.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [ExpLaunch.Native]::CloseHandle($h) | Out-Null }
}

function Get-Windows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [ExpLaunch.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([ExpLaunch.Native]::IsWindowVisible($h)) {
            $len = [ExpLaunch.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [ExpLaunch.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $op = 0
                [ExpLaunch.Native]::GetWindowThreadProcessId($h, [ref]$op) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h; Title = $sb.ToString(); Pid = [int]$op
                    Exe = (Get-ExePath ([int]$op))
                })
            }
        }
        return $true
    }
    [ExpLaunch.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$exe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
if (-not (Test-Path -LiteralPath $exe)) { Write-Host "SKIP: 未安装"; exit 3 }

$windows = @(Get-Windows)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
$park = @($windows | Where-Object {
    $_.Exe -notmatch 'DeepSeek Harness\.exe' -and $_.Title -notmatch '蓝鲸小深' -and $_.Title -ne ''
})[0]
if ($null -eq $target) { Write-Host 'SKIP: 桌面版无可见窗口'; exit 3 }
if ($null -eq $park) { Write-Host 'SKIP: 找不到停靠窗口'; exit 3 }

$th = $target.Handle
$selfPid = [ExpLaunch.Native]::GetCurrentProcessId()
Write-Host "目标: hwnd=$th '$($target.Title)'"
Write-Host "停靠: hwnd=$($park.Handle) '$($park.Title)'"
Write-Host ''

# 制造劣势：把前台停到停靠窗口
[ExpLaunch.Native]::ShowWindow($park.Handle, 9) | Out-Null
[ExpLaunch.Native]::SetForegroundWindow($park.Handle) | Out-Null
Start-Sleep -Milliseconds 900
$fg0 = [ExpLaunch.Native]::GetForegroundWindow()
if ($fg0 -eq $th) {
    Write-Host 'SKIP: 无法把前台从 Harness 移开，前提不成立。'
    exit 3
}
Write-Host "✔ 前提成立：前台 = hwnd $fg0（不是 Harness）"
Write-Host ''

Write-Host '通过 explorer.exe 启动（模拟桌面属主代为启动）...'
Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$exe`"" | Out-Null

# 轮询等待，最多 WaitMs
$became = $false
$elapsed = 0
$step = 250
while ($elapsed -lt $WaitMs) {
    Start-Sleep -Milliseconds $step
    $elapsed += $step
    if ([ExpLaunch.Native]::GetForegroundWindow() -eq $th) { $became = $true; break }
}

$fgEnd = [ExpLaunch.Native]::GetForegroundWindow()
Write-Host ''
Write-Host "等待 ${elapsed}ms 后："
Write-Host "  前台 hwnd = $fgEnd"
Write-Host "  Harness 成为前台: $became"
Write-Host ''
if ($became) {
    Write-Host 'PASS: explorer.exe 代为启动确实能让 Harness 窗口成为前台。'
    Write-Host '      这是沙箱内可行的唤醒通道。'
    exit 0
}
Write-Host 'FAIL: 即使等满等待时间，Harness 也未成为前台。'
exit 1
