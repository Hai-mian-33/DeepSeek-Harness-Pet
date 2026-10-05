# Test-DesktopRaiseStrict.ps1 - 严格验证：桌面窗口"最小化且非前台"时，启动 exe 能否唤起它。
#
# 之前的 Test-DesktopActivation.ps1 是无效测试：目标窗口本来就是前台，于是
# GetForegroundWindow() == handle 恒为真。本脚本先把前台停靠到别处、并把目标最小化，
# 确认它确实既非前台也已最小化，然后再启动 exe 观察结果。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace DRS -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@

function Get-Windows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [DRS.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([DRS.Native]::IsWindowVisible($h)) {
            $len = [DRS.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [DRS.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $list.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString() })
            }
        }
        return $true
    }
    [DRS.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$exe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
if (-not (Test-Path -LiteralPath $exe)) { Write-Host "SKIP: 未安装桌面版"; exit 3 }

$windows = Get-Windows
$target = @($windows | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 没有 Harness 窗口'; exit 3 }

# 停靠窗口：桌宠，或当前前台
$park = @($windows | Where-Object { $_.Title -match '^蓝鲸小深$' })[0]
if ($null -eq $park) { Write-Host 'SKIP: 没有可用于停靠前台的窗口'; exit 3 }

$th = $target.Handle
Write-Host "目标: hwnd=$th"
Write-Host "      '$($target.Title)'"
Write-Host "停靠: hwnd=$($park.Handle)"
Write-Host ''

# 设置一个真正的劣势：目标最小化，前台停到别处。
Write-Host '制造劣势：最小化目标窗口，并把前台停靠到桌宠窗口...'
[DRS.Native]::ShowWindow($th, 6) | Out-Null      # SW_MINIMIZE
Start-Sleep -Milliseconds 600
[DRS.Native]::ShowWindow($park.Handle, 9) | Out-Null
[DRS.Native]::SetForegroundWindow($park.Handle) | Out-Null
Start-Sleep -Milliseconds 600

$fgBefore = [DRS.Native]::GetForegroundWindow()
$iconicBefore = [DRS.Native]::IsIconic($th)
Write-Host "  目标最小化: $iconicBefore"
Write-Host "  目标是否前台: $($fgBefore -eq $th)"
Write-Host "  当前前台 hwnd: $fgBefore"
Write-Host ''

if (-not $iconicBefore -and $fgBefore -ne $th) {
    Write-Host '（注意：目标未成功最小化，但仍非前台，测试依然有效）'
}

if ($fgBefore -eq $th -and -not $iconicBefore) {
    Write-Host 'SKIP: 无法制造"既非前台也未最小化"的劣势，测试会失去意义。'
    exit 3
}

Write-Host '启动 DeepSeek Harness.exe...'
Start-Process -FilePath $exe | Out-Null

$becameFg = $false
$restored = $false
for ($i = 0; $i -lt 50; $i++) {
    Start-Sleep -Milliseconds 200
    if (-not [DRS.Native]::IsIconic($th)) { $restored = $true }
    if ([DRS.Native]::GetForegroundWindow() -eq $th) { $becameFg = $true; break }
}

Write-Host ''
Write-Host "结果（等待 $($i * 200)ms）："
Write-Host "  从最小化恢复: $restored"
Write-Host "  成为前台    : $becameFg"
Write-Host ''
if ($becameFg) {
    Write-Host 'PASS: 桌面版 exe 能把"最小化且非前台"的窗口唤起到前台。'
    exit 0
}
if ($restored) {
    Write-Host 'PARTIAL: 窗口已从最小化恢复，但未成为前台（前台锁限制）。'
    exit 2
}
Write-Host 'FAIL: 启动 exe 没有唤起窗口。'
exit 1
