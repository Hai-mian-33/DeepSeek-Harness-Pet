# Probe-ZOrderTruth.ps1 - EnumWindows 的枚举顺序真的是 z-order 吗？
#
# 刚才所有 z-order 手段都报告"z 6->6 无变化"，包括 SetWindowPos(HWND_TOP)。这有两种可能：
#   (a) 手段确实无效；或
#   (b) 我的测量指标是错的 —— EnumWindows 未必按真实 z-order 枚举。
#
# 在改动产品代码前必须先排除 (b)。本脚本做一个判决性实验：
#   1. 记录两个窗口在 EnumWindows 中的索引；
#   2. 明确把其中一个用 HWND_TOP 提到另一个之上（前提是它确实被移到了上面）；
#   3. 再看索引是否随之变化。
#
# 同时用 GetWindow(GW_HWNDPREV/GW_HWNDNEXT) 读取真实的 z-order 链，作为独立佐证 ——
# 这是直接来自窗口管理器的答案，不依赖枚举顺序的约定。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace ZTruth -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetWindow(System.IntPtr h, uint cmd);
[DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@

$GW_HWNDPREV = 3
$GW_HWNDNEXT = 2
$SWP_NOMOVE = 0x0002
$SWP_NOSIZE = 0x0001
$SWP_SHOWWINDOW = 0x0040

function Get-EnumOrder {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [ZTruth.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([ZTruth.Native]::IsWindowVisible($h)) {
            $len = [ZTruth.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [ZTruth.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $list.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString() })
            }
        }
        return $true
    }
    [ZTruth.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Get-Index($list, [IntPtr]$handle) {
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Handle -eq $handle) { return $i } }
    return -1
}

function Describe([IntPtr]$h) {
    if ($h -eq [IntPtr]::Zero) { return '(无)' }
    $len = [ZTruth.Native]::GetWindowTextLength($h)
    $sb = New-Object System.Text.StringBuilder ($len + 2)
    [ZTruth.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
    $t = $sb.ToString()
    if ($t.Length -gt 40) { $t = $t.Substring(0, 40) + '…' }
    return "hwnd=$h '$t'"
}

# 取两个有标题的可见窗口作为实验对象
$order = @(Get-EnumOrder)
if ($order.Count -lt 3) { Write-Host 'SKIP: 可见窗口太少'; exit 3 }

$first = $order[0]
$last = $order[$order.Count - 1]
Write-Host "枚举顺序（前 3 个）："
for ($i = 0; $i -lt [Math]::Min(3, $order.Count); $i++) {
    Write-Host ("  [{0}] hwnd={1} '{2}'" -f $i, $order[$i].Handle, $order[$i].Title)
}
Write-Host ''
Write-Host "实验：把最后一个窗口 '$($last.Title)' 用 HWND_TOP 提到最前"
Write-Host ""

Write-Host "--- 实验前 ---"
$idxBefore = Get-Index (Get-EnumOrder) $last.Handle
Write-Host "  该窗口枚举索引: $idxBefore"
Write-Host "  GW_HWNDPREV(它上面的窗口): $(Describe ([ZTruth.Native]::GetWindow($last.Handle, $GW_HWNDPREV)))"
Write-Host "  GW_HWNDNEXT(它下面的窗口): $(Describe ([ZTruth.Native]::GetWindow($last.Handle, $GW_HWNDNEXT)))"
Write-Host ""

[ZTruth.Native]::SetWindowPos($last.Handle, [IntPtr]::Zero, 0, 0, 0, 0, ($SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW)) | Out-Null
Start-Sleep -Milliseconds 500

Write-Host "--- 实验后 ---"
$idxAfter = Get-Index (Get-EnumOrder) $last.Handle
Write-Host "  该窗口枚举索引: $idxAfter"
Write-Host "  GW_HWNDPREV(它上面的窗口): $(Describe ([ZTruth.Native]::GetWindow($last.Handle, $GW_HWNDPREV)))"
Write-Host "  GW_HWNDNEXT(它下面的窗口): $(Describe ([ZTruth.Native]::GetWindow($last.Handle, $GW_HWNDNEXT)))"
Write-Host ''

$moved = ($idxAfter -lt $idxBefore)
if ($moved -or $idxAfter -eq 0) {
    Write-Host "结论：EnumWindows 的索引确实反映 z-order（$idxBefore -> $idxAfter）。"
    Write-Host "      因此之前测出'z 无变化'是真实的，不是测量误差。"
    exit 0
}
Write-Host "结论：SetWindowPos(HWND_TOP) 后索引没有前移（$idxBefore -> $idxAfter）。"
Write-Host "      说明 EnumWindows 的枚举顺序在这种环境下不反映真实 z-order，"
Write-Host "      之前的 z-order 结论不可信，需要改用 GW_HWNDPREV 链来判定。"
exit 2
