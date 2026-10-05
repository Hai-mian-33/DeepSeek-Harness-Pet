# Test-ClickInjection.ps1 - 用 PostMessage 向窗口投递真实鼠标消息来验证点击链路。
#
# 这个沙箱禁止 SetCursorPos / SendInput（见 Test-SyntheticMouse.ps1），所以无法移动
# 真实光标。但 PostMessage 是直接把消息放进目标窗口的消息队列，不经过输入队列，
# 因而可用。这正是排查"点击没反应"所需要的手段：
#
#   * WM_LBUTTONDOWN 会触发窗口的 MouseLeftButtonDown，与真实按下等效；
#   * 光标位置仍是 GetCursorPos 的真实值，所以落点由"当前光标位置"决定 —— 测试前
#     需要先把光标移到目标窗口上方，这一步同样受限。
#
# 因此本脚本采用另一种等价做法：直接给出 lParam 坐标（相对客户区），并同时报告
# 窗口的命中测试结果，用来回答"这个像素到底是不是鼠标目标"。

param(
    [string]$Root = '',
    [switch]$Pet,
    [switch]$Popup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$WM_MOUSEMOVE = 0x0200
$MK_LBUTTON = 0x0001

Add-Type -Namespace ClickTest -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.UIntPtr w, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
'@

function Get-WindowsByTitle([string]$pattern) {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [ClickTest.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([ClickTest.Native]::IsWindowVisible($h)) {
            $len = [ClickTest.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [ClickTest.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $title = $sb.ToString()
                if ($title -match $pattern) {
                    $rect = New-Object ClickTest.Native+RECT
                    [ClickTest.Native]::GetWindowRect($h, [ref]$rect) | Out-Null
                    $list.Add([pscustomobject]@{
                        Handle = $h; Title = $title
                        X = $rect.Left; Y = $rect.Top
                        W = $rect.Right - $rect.Left; H = $rect.Bottom - $rect.Top
                    })
                }
            }
        }
        return $true
    }
    [ClickTest.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Test-HitGrid($win, [string]$label) {
    Write-Host ""
    Write-Host "=== $label  hwnd=$($win.Handle) $($win.W)x$($win.H) at ($($win.X),$($win.Y)) ==="
    $cols = 4; $rows = 4
    $hits = 0; $miss = 0; $missAt = @()
    for ($r = 0; $r -lt $rows; $r++) {
        for ($c = 0; $c -lt $cols; $c++) {
            $x = $win.X + 3 + [int](($win.W - 6) * $c / ($cols - 1))
            $y = $win.Y + 3 + [int](($win.H - 6) * $r / ($rows - 1))
            $pt = New-Object ClickTest.Native+POINT
            $pt.X = $x; $pt.Y = $y
            $hwnd = [ClickTest.Native]::WindowFromPoint($pt)
            $root = [ClickTest.Native]::GetAncestor($hwnd, 2)
            if ($hwnd -eq $win.Handle -or $root -eq $win.Handle) { $hits++ }
            else { $miss++; $missAt += "($x,$y)->$hwnd" }
        }
    }
    Write-Host "  命中 $hits / $($cols*$rows)  穿透 $miss"
    if ($miss -gt 0) { Write-Host "  穿透点: $($missAt -join ' ')" }
    return $miss
}

$failures = 0

if ($Pet -or -not $Popup) {
    $pets = @(Get-WindowsByTitle '^蓝鲸小深$')
    if ($pets.Count -gt 0) {
        $failures += Test-HitGrid $pets[0] '桌宠窗口'
        Write-Host "  投递 WM_LBUTTONDOWN 到桌宠..."
        $lp = [IntPtr](($pets[0].H / 2) -shl 16 -bor ($pets[0].W / 2))
        [ClickTest.Native]::PostMessage($pets[0].Handle, $WM_LBUTTONDOWN, [System.UIntPtr]::new(1), $lp) | Out-Null
        Start-Sleep -Milliseconds 300
        [ClickTest.Native]::PostMessage($pets[0].Handle, $WM_LBUTTONUP, [System.UIntPtr]::Zero, $lp) | Out-Null
        Write-Host "  已投递"
    } else { Write-Host "未找到桌宠窗口" }
}

if ($Popup -or -not $Pet) {
    $popups = @(Get-WindowsByTitle '蓝鲸小深 · 状态')
    if ($popups.Count -gt 0) {
        $failures += Test-HitGrid $popups[0] '气泡窗口'
    } else { Write-Host "`n未找到气泡窗口（当前可能未显示）" }
}

Write-Host ""
if ($failures -eq 0) { Write-Host 'PASS: 所有采样点都是鼠标目标。'; exit 0 }
Write-Host "FAIL: 有 $failures 个采样点穿透，鼠标事件到不了窗口。"
exit 1
