# Probe-SandboxLimits.ps1 - 确认当前 shell 是否运行在受限环境中。
#
# 观测到的异常：
#   * SetWindowPos / SetForegroundWindow / AttachThreadInput 对跨进程窗口全部返回 False
#     且毫无效果（连 WS_EX_TOPMOST 位都不变）；
#   * Get-Process -Name explorer 查不到 explorer.exe，尽管它的窗口存在；
#   * 所有进程的完整性级别都是 Low。
#
# 这些迹象指向"进程运行在受限/沙箱环境"。本脚本收集可判定的证据。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host '=== 1. 当前进程的令牌与桌面 ==='
Write-Host ("  用户: {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
Write-Host ("  是否管理员: {0}" -f (New-Object System.Security.Principal.WindowsPrincipal(
    [System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator))

# 桌面/窗口站名称能直接反映是否处于受限桌面上
Add-Type -Namespace SB -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError=true)]
public static extern System.IntPtr GetProcessWindowStation();
[DllImport("user32.dll", SetLastError=true)]
public static extern System.IntPtr GetThreadDesktop(uint threadId);
[DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool GetUserObjectInformation(System.IntPtr h, int index, System.Text.StringBuilder info, uint len, out uint needed);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
'@

function Get-ObjectName([IntPtr]$handle) {
    $sb = New-Object System.Text.StringBuilder 256
    $needed = 0
    if ([SB.Native]::GetUserObjectInformation($handle, 2, $sb, [uint32]$sb.Capacity, [ref]$needed)) {
        return $sb.ToString()
    }
    return '(读取失败)'
}

$winsta = [SB.Native]::GetProcessWindowStation()
$desk = [SB.Native]::GetThreadDesktop([SB.Native]::GetCurrentThreadId())
Write-Host ("  窗口站: {0}" -f (Get-ObjectName $winsta))
Write-Host ("  桌面  : {0}" -f (Get-ObjectName $desk))
Write-Host ''

Write-Host '=== 2. 能否枚举/查询常见系统进程 ==='
foreach ($name in @('explorer', 'winlogon', 'dwm', 'DeepSeek Harness')) {
    $p = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    Write-Host ("  {0,-20} Get-Process 找到 {1} 个" -f $name, $p.Count)
}
Write-Host ''

Write-Host '=== 3. 关键判定：跨进程窗口操作是否被整体禁止 ==='
# 取任意一个不属于本进程的可见窗口，尝试一次无害的 SetWindowPos(SWP_NOSIZE|NOMOVE)
Add-Type -Namespace SB2 -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(System.IntPtr h, int i);
[DllImport("kernel32.dll")] public static extern uint GetLastError();
[DllImport("kernel32.dll")] public static extern uint GetCurrentProcessId();
'@

$selfPid = [SB2.Native]::GetCurrentProcessId()
$candidate = [IntPtr]::Zero
$cb = [SB2.Native+EnumWindowsProc] {
    param([IntPtr]$h, [IntPtr]$p)
    if ([SB2.Native]::IsWindowVisible($h)) {
        $owner = 0
        [SB2.Native]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
        if ($owner -ne $selfPid) {
            $script:candidate = $h
            return $false
        }
    }
    return $true
}
[SB2.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null

if ($candidate -eq [IntPtr]::Zero) {
    Write-Host '  找不到其他进程的窗口，无法测试。'
} else {
    $owner = 0
    [SB2.Native]::GetWindowThreadProcessId($candidate, [ref]$owner) | Out-Null
    $before = [SB2.Native]::GetWindowLong($candidate, -20)
    $r = [SB2.Native]::SetWindowPos($candidate, [IntPtr]::Zero, 0, 0, 0, 0, 0x0003)
    $err = [SB2.Native]::GetLastError()
    $after = [SB2.Native]::GetWindowLong($candidate, -20)
    Write-Host ("  目标窗口 hwnd={0} (pid {1})" -f $candidate, $owner)
    Write-Host ("  SetWindowPos 返回={0}  GetLastError={1}" -f $r, $err)
    Write-Host ("  EXSTYLE 前后: 0x{0:X8} -> 0x{1:X8}" -f $before, $after)
    if (-not $r -and $err -eq 0) {
        Write-Host ''
        Write-Host '  返回 False 但 GetLastError=0：调用被静默拦截，没有真正执行。'
        Write-Host '  这是受限环境的典型表现（正常环境下跨进程移动自己的窗口是允许的）。'
    }
}
