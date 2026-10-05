# Test-DesktopActivation.ps1 - 启动 DeepSeek Harness.exe 能否唤起已有桌面窗口？
#
# 桌面版（Electron）持有 single-instance 锁，并在收到第二次启动时聚焦它自己的主窗口。
# 这是官方支持的唤起方式，而且不依赖 SetForegroundWindow —— 后者在本机被前台锁拒绝
# （见 Test-ForegroundLock.ps1 的七项全败）。
#
# 本脚本测量实际效果：记录调用前的窗口状态，启动 exe，等待，然后检查那个 Harness 窗口
# 是否成为前台、是否从最小化恢复、以及是否出现了新窗口（若 single-instance 生效，
# 不应有第二个主窗口）。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

Add-Type -Namespace Act -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@

function Get-HarnessWindows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [Act.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([Act.Native]::IsWindowVisible($h)) {
            $len = [Act.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [Act.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $t = $sb.ToString()
                if ($t -match 'Harness' -and $t -notmatch '蓝鲸小深') {
                    $ownerPid = 0
                    [Act.Native]::GetWindowThreadProcessId($h, [ref]$ownerPid) | Out-Null
                    $list.Add([pscustomobject]@{
                        Handle = $h
                        Title = $t
                        Pid = [int]$ownerPid
                        Iconic = [Act.Native]::IsIconic($h)
                        Foreground = ([Act.Native]::GetForegroundWindow() -eq $h)
                    })
                }
            }
        }
        return $true
    }
    [Act.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$exe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
if (-not (Test-Path -LiteralPath $exe)) { Write-Host "SKIP: 未找到 $exe"; exit 3 }

Write-Host "桌面版可执行文件: $exe"
$before = @(Get-HarnessWindows)
Write-Host "调用前的 Harness 窗口: $($before.Count)"
foreach ($w in $before) {
    Write-Host ("  hwnd={0} pid={1} iconic={2} foreground={3}" -f $w.Handle, $w.Pid, $w.Iconic, $w.Foreground)
}
if ($before.Count -eq 0) { Write-Host 'SKIP: 没有已打开的桌面窗口可供唤起'; exit 3 }
Write-Host ''

Write-Host '启动 DeepSeek Harness.exe（依赖 single-instance 锁聚焦已有窗口）...'
$started = Get-Date
Start-Process -FilePath $exe | Out-Null

# 轮询等待，最多 8 秒：Electron 需要时间把 second-instance 事件传到主窗口。
$becameForeground = $false
$restored = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 200
    $now = @(Get-HarnessWindows)
    $target = $now | Where-Object { $_.Handle -eq $before[0].Handle }
    if ($null -ne $target) {
        if (-not $target.Iconic) { $restored = $true }
        if ($target.Foreground) { $becameForeground = $true; break }
    }
}
$elapsed = [int]((Get-Date) - $started).TotalMilliseconds

$after = @(Get-HarnessWindows)
Write-Host ''
Write-Host "耗时: ${elapsed}ms"
Write-Host "调用后的 Harness 窗口: $($after.Count)"
foreach ($w in $after) {
    Write-Host ("  hwnd={0} pid={1} iconic={2} foreground={3}" -f $w.Handle, $w.Pid, $w.Iconic, $w.Foreground)
}
Write-Host ''
Write-Host "已成为前台: $becameForeground"
Write-Host "已从最小化恢复: $restored"
Write-Host "窗口数量未增加（single-instance 生效）: $($after.Count -eq $before.Count)"
Write-Host ''

if ($becameForeground) {
    Write-Host 'PASS: 启动桌面版可执行文件能唤起已打开的 Harness 桌面窗口。'
    exit 0
}
Write-Host 'FAIL: 启动可执行文件没有把桌面窗口带到前台。'
exit 1
