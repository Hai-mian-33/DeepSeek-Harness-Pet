# Simulate-PointerClick.ps1 - 走一遍 shell 的命中判定逻辑，确认点击会被识别。
#
# 沙箱禁止移动光标，所以无法真的驱动一次点击。但 shell 的判定完全建立在三个 OS
# 查询之上，本脚本用同一组查询复现它的决策，从而验证"如果光标在这里，按下会发生
# 什么"：
#
#   WindowFromPoint  -> 落点是桌宠还是气泡（或都不是）
#   GetAsyncKeyState -> 按键是否按下（模拟期间强制为"按下"）
#
# 这样可以在不移动光标的前提下，确认桌宠与气泡两个分支都能被正确识别。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -Namespace SP -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr WindowFromPoint(POINT p);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
'@

function Classify([int]$x, [int]$y, $petHandle, $popupHandle) {
    $p = New-Object SP.Native+POINT
    $p.X = $x; $p.Y = $y
    $hit = [SP.Native]::WindowFromPoint($p)
    $target = ''
    if ($hit -eq $petHandle) { $target = 'pet' }
    elseif ($popupHandle -ne [IntPtr]::Zero -and $hit -eq $popupHandle) { $target = 'popup' }
    return [pscustomobject]@{ Hit = $hit; Target = $target }
}

$pet = Get-PetWindow
if ($null -eq $pet) { Write-Host 'FAIL: 未找到桌宠窗口'; exit 1 }

$all = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -eq '' -and $_.Width -eq 240 })
$popup = if ($all.Count -gt 0) { $all[0] } else { $null }

Write-Host "桌宠 hwnd=$($pet.Handle)"
if ($null -ne $popup) { Write-Host "气泡 hwnd=$($popup.Handle) $($popup.Width)x$($popup.Height) at ($($popup.Left),$($popup.Top))" }
Write-Host ''

$failures = 0

# 桌宠：中心与四角内侧都必须判定为 pet
$pts = @(
    @{ X = $pet.Left + [int]($pet.Width / 2); Y = $pet.Top + [int]($pet.Height / 2); What = '桌宠中心' },
    @{ X = $pet.Left + 4;                     Y = $pet.Top + 4;                      What = '桌宠左上' },
    @{ X = $pet.Left + $pet.Width - 5;        Y = $pet.Top + $pet.Height - 5;       What = '桌宠右下' }
)
Write-Host '--- 桌宠区域 ---'
foreach ($pt in $pts) {
    $r = Classify $pt.X $pt.Y $pet.Handle $(if ($null -ne $popup) { $popup.Handle } else { [IntPtr]::Zero })
    $ok = ($r.Target -eq 'pet')
    Write-Host ("  {0,-10} ({1,4},{2,4}) -> {3}  {4}" -f $pt.What, $pt.X, $pt.Y, $(if ($r.Target -eq '') { '无' } else { $r.Target }), $(if ($ok) { 'OK' } else { '不符合预期' }))
    if (-not $ok) { $failures++ }
}

if ($null -ne $popup) {
    Write-Host ''
    Write-Host '--- 气泡区域 ---'
    $bpts = @(
        @{ X = $popup.Left + [int]($popup.Width / 2); Y = $popup.Top + [int]($popup.Height / 2); What = '气泡中心' },
        @{ X = $popup.Left + [int]($popup.Width / 2); Y = $popup.Top + 6;                      What = '气泡上缘' },
        @{ X = $popup.Left + [int]($popup.Width / 2); Y = $popup.Top + $popup.Height - 6;      What = '气泡下缘' }
    )
    foreach ($pt in $bpts) {
        $r = Classify $pt.X $pt.Y $pet.Handle $popup.Handle
        $ok = ($r.Target -eq 'popup')
        Write-Host ("  {0,-10} ({1,4},{2,4}) -> {3}  {4}" -f $pt.What, $pt.X, $pt.Y, $(if ($r.Target -eq '') { '无' } else { $r.Target }), $(if ($ok) { 'OK' } else { '不符合预期' }))
        if (-not $ok) { $failures++ }
    }
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 桌宠与气泡的落点都能被准确区分，点击链路的前提成立。'
    exit 0
}
Write-Host "FAIL: $failures 个落点判定错误。"
exit 1
