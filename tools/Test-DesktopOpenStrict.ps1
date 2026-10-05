# Test-DesktopOpenStrict.ps1 - 严格验证：桌面窗口"原本不是前台"时，启动 exe 能否把它带到前台。
#
# 这是对之前所有"验证通过"的修正。那些测试都犯了同一个错误：目标窗口当时已经是前台，
# 于是 `GetForegroundWindow() == handle` 恒为真，判定立即通过，被测代码其实从未起过
# 作用。shell 里的重试循环同样有这个缺陷 —— 它开头就 `if (Test-HarnessForeground) break`，
# 窗口已在前台时循环体一次都不执行，却仍然记录"已成前台"。
#
# 本脚本先把前台抢到桌宠窗口，确认 Harness 窗口确实不在前台，再执行与 Open-Harness
# 相同的启动动作，并对结果做诚实的分类：
#
#   FOREGROUND  - 成为前台（理想结果）
#   RESTORED    - 至少从最小化恢复或 z-order 提升
#   NOTHING     - 完全没有可观察变化

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace StrictOpen -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
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
'@

$PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
$SW_RESTORE = 9

function Get-ExePath([int]$processId) {
    $h = [StrictOpen.Native]::OpenProcess($PROCESS_QUERY_LIMITED_INFORMATION, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([StrictOpen.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [StrictOpen.Native]::CloseHandle($h) | Out-Null }
}

function Get-WindowsZ {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [StrictOpen.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([StrictOpen.Native]::IsWindowVisible($h)) {
            $len = [StrictOpen.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [StrictOpen.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $ownerPid = 0
                [StrictOpen.Native]::GetWindowThreadProcessId($h, [ref]$ownerPid) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h
                    Title = $sb.ToString()
                    Pid = [int]$ownerPid
                    Exe = (Get-ExePath ([int]$ownerPid))
                    Iconic = [StrictOpen.Native]::IsIconic($h)
                })
            }
        }
        return $true
    }
    [StrictOpen.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

function Get-ZIndex($list, [IntPtr]$handle) {
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Handle -eq $handle) { return $i } }
    return -1
}

$exe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
if (-not (Test-Path -LiteralPath $exe)) { Write-Host "SKIP: 未安装桌面版 ($exe)"; exit 3 }

# 目标：真正属于 DeepSeek Harness.exe 的可见窗口（用进程路径判定，不用标题）
$windows = @(Get-WindowsZ)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 桌面版没有可见窗口'; exit 3 }

# 停靠窗口：任意一个不是 Harness、也不是桌宠守护窗口的普通窗口
$park = @($windows | Where-Object {
    $_.Exe -notmatch 'DeepSeek Harness\.exe' -and $_.Title -notmatch '蓝鲸小深' -and $_.Title -ne ''
})[0]
if ($null -eq $park) { Write-Host 'SKIP: 找不到可用于停靠前台的窗口'; exit 3 }

Write-Host "目标桌面窗口: hwnd=$($target.Handle)  '$($target.Title)'"
Write-Host "              exe=$($target.Exe)"
Write-Host "停靠窗口    : hwnd=$($park.Handle)  '$($park.Title)'"
Write-Host ''

# ---- 制造真实劣势：把前台抢走 ----
Write-Host '步骤 1：把前台停靠到另一个窗口'
[StrictOpen.Native]::ShowWindow($park.Handle, $SW_RESTORE) | Out-Null
[StrictOpen.Native]::SetForegroundWindow($park.Handle) | Out-Null
Start-Sleep -Milliseconds 700

$fgNow = [StrictOpen.Native]::GetForegroundWindow()
$isFgBefore = ($fgNow -eq $target.Handle)
$zBefore = Get-ZIndex (Get-WindowsZ) $target.Handle
$iconicBefore = [StrictOpen.Native]::IsIconic($target.Handle)
Write-Host "  目标是否前台: $isFgBefore"
Write-Host "  目标 z-order 索引: $zBefore （越小越靠前）"
Write-Host "  目标是否最小化: $iconicBefore"
Write-Host ''

if ($isFgBefore) {
    Write-Host 'SKIP: 无法把前台从目标窗口移开，测试前提不成立（会得出假阳性）。'
    exit 3
}
Write-Host '  ✔ 前提成立：目标确实不在前台。'
Write-Host ''

# ---- 执行与 Open-Harness 相同的动作 ----
Write-Host '步骤 2：启动 DeepSeek Harness.exe（Open-Harness 的做法）'
Start-Process -FilePath $exe | Out-Null

$becameFg = $false
$restored = $false
$elapsed = 0
for ($i = 0; $i -lt 50; $i++) {
    Start-Sleep -Milliseconds 200
    $elapsed += 200
    if (-not [StrictOpen.Native]::IsIconic($target.Handle)) { $restored = $true }
    if ([StrictOpen.Native]::GetForegroundWindow() -eq $target.Handle) { $becameFg = $true; break }
}

$zAfter = Get-ZIndex (Get-WindowsZ) $target.Handle
Write-Host ''
Write-Host "步骤 3：结果（等待 ${elapsed}ms）"
Write-Host "  成为前台      : $becameFg"
Write-Host "  z-order 索引  : $zBefore -> $zAfter"
Write-Host "  从最小化恢复  : $restored"
Write-Host ''

if ($becameFg) {
    Write-Host '结果：FOREGROUND —— 启动 exe 确实把桌面窗口带到了前台。'
    exit 0
}
if ($restored -or ($zAfter -ge 0 -and $zBefore -ge 0 -and $zAfter -lt $zBefore)) {
    Write-Host '结果：RESTORED —— 窗口有可观察变化（恢复/前移），但未取得前台焦点。'
    exit 2
}
Write-Host '结果：NOTHING —— 启动 exe 没有产生任何可观察变化。'
exit 1
