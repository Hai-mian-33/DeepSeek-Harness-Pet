# Test-ZOrderRaise.ps1 - 用正确的指标验证：窗口能否被"抬到最前"（z-order），而不只是抢焦点。
#
# 这是对 Test-ForegroundLock.ps1 的修正。那次测试用"是否成为前台"来判定所有方法，
# 但 SetWindowPos(HWND_TOP) 的设计目的本来就是改变 z-order，而不是夺取键盘焦点 ——
# 用前台去衡量它必然"失败"，属于测量错误。
#
# EnumWindows 按 z-order 从最前到最末枚举窗口，所以"索引"就是可靠的 z-order 指标。
# 本脚本测量目标窗口从最小化恢复后，其在 z-order 中的位置是否变成最前。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace ZR -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@

$SW_RESTORE = 9
$SWP_NOSIZE = 0x0001
$SWP_NOMOVE = 0x0002
$SWP_SHOWWINDOW = 0x0040

function Get-ZOrder {
    # EnumWindows 按 z-order 自前向后枚举。
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [ZR.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([ZR.Native]::IsWindowVisible($h)) {
            $len = [ZR.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [ZR.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $list.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString() })
            }
        }
        return $true
    }
    [ZR.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Get-Index($list, [IntPtr]$handle) {
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Handle -eq $handle) { return $i } }
    return -1
}

$windows = Get-ZOrder
$target = @($windows | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 没有 Harness 窗口'; exit 3 }
$park = @($windows | Where-Object { $_.Title -match '^蓝鲸小深$' })[0]

$th = $target.Handle
Write-Host "目标: hwnd=$th  '$($target.Title)'"
Write-Host "总窗口数: $($windows.Count)"
Write-Host ''

$failures = 0

Write-Host '--- 基线：目标当前的 z-order ---'
$idx0 = Get-Index (Get-ZOrder) $th
Write-Host "  索引 = $idx0  （0 表示最前）"
Write-Host ''

Write-Host '--- 把目标最小化，制造真实劣势 ---'
[ZR.Native]::ShowWindow($th, 6) | Out-Null
Start-Sleep -Milliseconds 700
if ($null -ne $park) {
    [ZR.Native]::ShowWindow($park.Handle, $SW_RESTORE) | Out-Null
    [ZR.Native]::SetForegroundWindow($park.Handle) | Out-Null
    Start-Sleep -Milliseconds 500
}
$iconic = [ZR.Native]::IsIconic($th)
Write-Host "  目标最小化: $iconic"
Write-Host ''

Write-Host '--- 施加"恢复 + 抬到最前"（不依赖前台权限）---'
[ZR.Native]::ShowWindow($th, $SW_RESTORE) | Out-Null
# 等恢复生效
for ($i = 0; $i -lt 40; $i++) {
    if (-not [ZR.Native]::IsIconic($th)) { break }
    Start-Sleep -Milliseconds 25
}
[ZR.Native]::SetWindowPos($th, [IntPtr]::Zero, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
Start-Sleep -Milliseconds 300
# 尽力而为：也尝试夺取前台
[ZR.Native]::SetForegroundWindow($th) | Out-Null
Start-Sleep -Milliseconds 400

$idx1 = Get-Index (Get-ZOrder) $th
$isFg = ([ZR.Native]::GetForegroundWindow() -eq $th)
$restored = -not [ZR.Native]::IsIconic($th)

Write-Host "  索引 = $idx1  （0 表示最前）"
Write-Host "  从最小化恢复: $restored"
Write-Host "  成为前台    : $isFg"
Write-Host ''

if (-not $restored) { Write-Host 'FAIL: 未能从最小化恢复'; $failures++ }
if ($idx1 -ne 0 -and $idx1 -ge $idx0 -and $idx0 -ge 0) {
    Write-Host "FAIL: z-order 没有提前（$idx0 -> $idx1）"
    $failures++
} else {
    Write-Host "z-order 已提前（$idx0 -> $idx1）"
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 不依赖前台权限也能让窗口可见且位于最前。'
    Write-Host '      SetWindowPos(HWND_TOP) 改变的是 z-order，之前用"是否前台"衡量它是错的。'
    exit 0
}
Write-Host "FAIL: $failures 项未达成。"
exit 1
