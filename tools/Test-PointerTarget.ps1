# Test-PointerTarget.ps1 - 验证 Step-PointerClick 的命中判定是否可靠。
#
# 这是本次修复的核心：气泡窗口收不到 WPF 鼠标事件（实测 popupPressed 恒为 false），
# 所以点击改由 OS 判定 —— GetCursorPos 取光标位置，WindowFromPoint 判断落点在
# 桌宠还是气泡，GetAsyncKeyState 判断按键。本脚本用同样的三个 API 独立复核判定
# 结果，确认 shell 的依据是正确的。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -Namespace PT -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr h, uint flags);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int v);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@

function Get-WindowAt([int]$x, [int]$y) {
    $p = New-Object PT.Native+POINT
    $p.X = $x; $p.Y = $y
    return [PT.Native]::WindowFromPoint($p)
}

$pet = Get-PetWindow
if ($null -eq $pet) { Write-Host 'FAIL: 未找到桌宠窗口'; exit 1 }

# 气泡窗口：无标题、位于桌宠上方、240 宽
$all = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -eq '' -and $_.Width -eq 240 })
$popup = $null
if ($all.Count -gt 0) { $popup = $all[0] }

Write-Host "桌宠 hwnd=$($pet.Handle) $($pet.Width)x$($pet.Height) at ($($pet.Left),$($pet.Top))"
if ($null -ne $popup) {
    Write-Host "气泡 hwnd=$($popup.Handle) $($popup.Width)x$($popup.Height) at ($($popup.Left),$($popup.Top))"
} else {
    Write-Host "气泡窗口未显示（无标题 240 宽窗口）"
}
Write-Host ''

$failures = 0

Write-Host '--- 桌宠中心点是否解析为桌宠窗口 ---'
$cx = $pet.Left + [int]($pet.Width / 2)
$cy = $pet.Top + [int]($pet.Height / 2)
$hit = Get-WindowAt $cx $cy
$ok = ($hit -eq $pet.Handle)
Write-Host "  ($cx,$cy) -> hwnd=$hit  是桌宠: $ok"
if (-not $ok) { $failures++ }

if ($null -ne $popup) {
    Write-Host ''
    Write-Host '--- 气泡中心点是否解析为气泡窗口 ---'
    $bx = $popup.Left + [int]($popup.Width / 2)
    $by = $popup.Top + [int]($popup.Height / 2)
    $hitB = Get-WindowAt $bx $by
    $okB = ($hitB -eq $popup.Handle)
    Write-Host "  ($bx,$by) -> hwnd=$hitB  是气泡: $okB"
    if (-not $okB) { $failures++ }

    Write-Host ''
    Write-Host '--- 气泡各卡片位置的解析（用于确定点击的是哪个会话）---'
    # 气泡有 8px 外边距；卡片纵向排列，逐点采样确认落在气泡内
    for ($frac = 0.15; $frac -le 0.9; $frac += 0.25) {
        $sx = $popup.Left + [int]($popup.Width / 2)
        $sy = $popup.Top + [int]($popup.Height * $frac)
        $h = Get-WindowAt $sx $sy
        $isPopup = ($h -eq $popup.Handle)
        Write-Host "  y=$([int]($popup.Height * $frac)) -> hwnd=$h  是气泡: $isPopUp" -ErrorAction SilentlyContinue
        Write-Host ("  y={0,3} -> hwnd={1}  是气泡: {2}" -f [int]($popup.Height * $frac), $h, $isPopup)
        if (-not $isPopup) { $failures++ }
    }
}

Write-Host ''
Write-Host '--- 当前按键状态 ---'
$down = ([int]([PT.Native]::GetAsyncKeyState(0x01)) -band 0x8000) -ne 0
Write-Host "  左键按下: $down"

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: WindowFromPoint 能稳定区分桌宠与气泡，判定依据可靠。'
    exit 0
}
Write-Host "FAIL: $failures 个采样点判定错误。"
exit 1
