# Probe-TopmostTruth.ps1 - SetWindowPos(HWND_TOPMOST) 到底生效了吗？
#
# 之前的 z-order 测试用 EnumWindows 的枚举索引判定，结论是"全部无变化"。但枚举顺序
# 是否真的反映 z-order 并未验证过，所以那个结论可能只是测量方法的问题。
#
# 本脚本改用**权威指标**：直接读窗口的扩展样式位 WS_EX_TOPMOST。
#   * 置为 TOPMOST 后，该位应为 1；窗口会浮在所有非置顶窗口之上 —— 这不需要前台权限；
#   * 再置为 NOTOPMOST 后，该位回到 0，但窗口会**保持在被抬高后的 z-order 位置**。
#
# 这正是"让窗口出现在最前面"的可靠手段，与键盘焦点无关。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace TopTruth -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int index);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
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

$GWL_EXSTYLE = -20
$WS_EX_TOPMOST = 0x00000008
$HWND_TOPMOST = [IntPtr](-1)
$HWND_NOTOPMOST = [IntPtr](-2)
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$SWP_SHOWWINDOW = 0x0040
$PQLI = 0x1000

function Get-ExePath([int]$processId) {
    $h = [TopTruth.Native]::OpenProcess($PQLI, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([TopTruth.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [TopTruth.Native]::CloseHandle($h) | Out-Null }
}

function Test-Topmost([IntPtr]$h) {
    $ex = [TopTruth.Native]::GetWindowLong($h, $GWL_EXSTYLE)
    return (($ex -band $WS_EX_TOPMOST) -ne 0)
}

function Get-Windows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [TopTruth.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([TopTruth.Native]::IsWindowVisible($h)) {
            $len = [TopTruth.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [TopTruth.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $op = 0
                [TopTruth.Native]::GetWindowThreadProcessId($h, [ref]$op) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h; Title = $sb.ToString(); Pid = [int]$op
                    Exe = (Get-ExePath ([int]$op))
                })
            }
        }
        return $true
    }
    [TopTruth.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$windows = @(Get-Windows)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 桌面版无可见窗口'; exit 3 }

$th = $target.Handle
Write-Host "目标: hwnd=$th '$($target.Title)'"
Write-Host "前置状态: 最小化=$([TopTruth.Native]::IsIconic($th))  TOPMOST=$(Test-Topmost $th)"
Write-Host ''

Write-Host '=== 测试 TOPMOST 置位（WS_EX_TOPMOST 位是权威指标）==='
Write-Host "  置位前 TOPMOST = $(Test-Topmost $th)"
$r1 = [TopTruth.Native]::SetWindowPos($th, $HWND_TOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW))
Start-Sleep -Milliseconds 350
$topAfter = Test-Topmost $th
Write-Host "  SetWindowPos(TOPMOST) 返回=$r1  ->  TOPMOST = $topAfter"
Write-Host ''

Write-Host '=== 再取消 TOPMOST（窗口保留在抬高后的 z-order）==='
$r2 = [TopTruth.Native]::SetWindowPos($th, $HWND_NOTOPMOST, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW))
Start-Sleep -Milliseconds 350
$topFinal = Test-Topmost $th
Write-Host "  SetWindowPos(NOTOPMOST) 返回=$r2  ->  TOPMOST = $topFinal"
Write-Host ''

$fg = [TopTruth.Native]::GetForegroundWindow()
Write-Host "前台窗口 hwnd=$fg  （目标是否前台: $($fg -eq $th)）"
Write-Host ''

if ($topAfter) {
    Write-Host 'PASS: TOPMOST 置位生效 —— 这不需要前台权限，可让窗口浮到最前。'
    Write-Host '      Open-Harness 应加入这一手段作为兜底。'
    exit 0
}
Write-Host 'FAIL: 连 TOPMOST 置位都不生效。'
exit 1
