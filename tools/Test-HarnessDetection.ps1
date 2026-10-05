# Test-HarnessDetection.ps1 - verify the watchdog's "is Harness running?" decision.
#
# WHY THIS DESERVES ITS OWN TEST
#   The autostart feature turns entirely on this one question. Answering it wrongly in one
#   direction hides the pet while Harness is plainly open; wrongly in the other direction leaves
#   the pet on screen forever after Harness closes. Both are silent: nothing on screen says the
#   watchdog misjudged.
#
#   The two signals are genuinely both needed on this machine. The processes named
#   `DeepSeek Harness` own no visible window, while the window that identifies Harness belongs to
#   a pid that `Get-Process -Name 'DeepSeek Harness'` does not return. `tools\
#   Probe-HarnessProcessName.ps1` prints that evidence on demand. A single-signal check would
#   therefore fail in practice, which is exactly what this test pins down.
#
# The real `Test-HarnessRunning` is extracted and run with both probes stubbed, so both signals
# and both failure modes can be exercised without touching the real desktop.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$text = [System.IO.File]::ReadAllText((Join-Path $Root 'tools\Watch-Pet.ps1'))

# The detection is three functions: the tray-mode check and the window check are helpers that
# Test-HarnessRunning calls. All three are extracted, so the code under test is the shipped code
# rather than a restatement of it — and a future refactor that renames or drops a helper fails
# here loudly instead of quietly weakening the assertions.
function Get-Fn([string]$Name) {
    $m = [regex]::Match($text, "(?ms)^function\s+$([regex]::Escape($Name))\s*\{.*?^\}")
    if (-not $m.Success) { throw "无法从 Watch-Pet.ps1 提取 $Name" }
    return $m.Value
}
foreach ($fn in @('Test-BackgroundTrayEnabled', 'Test-HarnessWindowVisible', 'Test-HarnessRunning')) {
    try { Invoke-Expression (Get-Fn $fn) } catch { Write-Host "FAIL: $_"; exit 1 }
}

# --- stubs ------------------------------------------------------------------
$script:ProcessNames = @()
$script:ProcessThrows = $false
$script:WindowTitles = @()
$script:WindowThrows = $false

$script:HarnessProcessName = 'DeepSeek Harness'
# Tray mode is read from a marker file in production; the tests pin it explicitly so the machine's
# real Harness configuration cannot change what is being asserted.
$script:BackgroundTrayEnabled = ''
$script:BackgroundTrayMarker = ''
$script:IgnoreHarnessWindow = $false

function Get-Process {
    param([string]$Name, [switch]$ErrorAction)
    if ($script:ProcessThrows) { throw 'access denied (simulated)' }
    $hits = @($script:ProcessNames | Where-Object { $_ -eq $Name })
    # Return the same shape the caller relies on: an array with a Count.
    return @($hits | ForEach-Object { [pscustomobject]@{ ProcessName = $_ } })
}

function Get-AllWindows {
    if ($script:WindowThrows) { throw 'enumeration denied (simulated)' }
    return @($script:WindowTitles | ForEach-Object {
        [pscustomobject]@{ Handle = [IntPtr]1; Owner = 1; Title = $_; Visible = $true }
    })
}

# (The three functions were extracted and defined above, before the stubs they call.)

$failures = 0
function Check([string]$Label, [bool]$Ok) {
    if ($Ok) { Write-Host "  OK   $Label" }
    else { Write-Host "  FAIL $Label"; $script:failures++ }
}
function Reset {
    $script:ProcessNames = @()
    $script:ProcessThrows = $false
    $script:WindowTitles = @()
    $script:WindowThrows = $false
    $script:BackgroundTrayEnabled = ''
    $script:BackgroundTrayMarker = ''
    $script:IgnoreHarnessWindow = $false
}

# A throwaway marker so tray mode can be driven both ways without touching real app data.
$trayMarkerOn = Join-Path ([System.IO.Path]::GetTempPath()) ("pet-tray-on-" + [guid]::NewGuid())
New-Item -ItemType File -Path $trayMarkerOn -Force | Out-Null
$trayMarkerOff = Join-Path ([System.IO.Path]::GetTempPath()) ("pet-tray-off-" + [guid]::NewGuid())

Write-Host '=== 信号一：按进程名（托盘模式固定为关，否则进程信号会被正确地忽略）==='
Reset
$script:BackgroundTrayMarker = $trayMarkerOff
$script:ProcessNames = @('DeepSeek Harness')
Check '进程名匹配 -> 认为在运行' (Test-HarnessRunning)

Reset
$script:BackgroundTrayMarker = $trayMarkerOff
Check '进程名不匹配且无窗口 -> 认为未运行' (-not (Test-HarnessRunning))

Write-Host ''
Write-Host '=== 信号二：按窗口（本机真实情况：名字对不上，窗口对得上）==='
Reset
$script:ProcessNames = @()          # 名字完全对不上
$script:WindowTitles = @('# DeepSeek Harness 桌面宠物“蓝鲸 — DeepSeek Harness')
Check '名字对不上但窗口在 -> 仍认为在运行（单靠名字会误判为已关闭）' (Test-HarnessRunning)

Reset
$script:WindowTitles = @('蓝鲸小深', '蓝鲸小深 · 状态')
Check '只有桌宠自己的窗口 -> 认为未运行（不得把桌宠当 Harness）' (-not (Test-HarnessRunning))

Write-Host ''
Write-Host '=== 两个信号都不成立 ==='
Reset
Check '无进程、无窗口 -> 认为未运行' (-not (Test-HarnessRunning))

Write-Host ''
Write-Host '=== 失败模式：读取被拒时不得误判为"已关闭" ==='
Reset
$script:BackgroundTrayMarker = $trayMarkerOff
$script:ProcessThrows = $true
Check 'Get-Process 抛异常 -> 保守认为在运行（保住已有桌宠）' (Test-HarnessRunning)

Reset
$script:BackgroundTrayMarker = $trayMarkerOff
$script:WindowTitles = @('蓝鲸小深')
$script:WindowThrows = $true
# Window enumeration failing means "cannot tell", not "closed". The safe answer is "running",
# because the alternative retracts the pet while the user may be looking straight at Harness.
# This case previously asserted the opposite, from before the tray-mode work: with tray mode ON
# the window is the ONLY signal, so answering "closed" here would hide the pet on nothing more
# than a denied enumeration.
Check '窗口枚举抛异常 -> 保守认为在运行（不误判为已关闭）' (Test-HarnessRunning)

Reset
$script:BackgroundTrayMarker = $trayMarkerOn
$script:WindowThrows = $true
Check '托盘模式开 + 枚举抛异常 -> 仍保守认为在运行' (Test-HarnessRunning)

Write-Host ''
Write-Host '=== 托盘模式（决定"关闭 Harness"到底意味着什么）==='
# DeepSeek Harness has a Windows tray mode: once the user acknowledges it, closing the window
# HIDES the app and the processes stay alive by design. With tray mode on, a process-based check
# reports "running" forever after the window is closed, so the pet would never hide — the exact
# requirement the watchdog exists to satisfy. These cases pin both settings.

Write-Host '  托盘模式 = 关（关闭窗口即退出进程）'
Reset
$script:BackgroundTrayMarker = $trayMarkerOff
$script:ProcessNames = @('DeepSeek Harness')
Check '  进程在、无窗口 -> 认为在运行（进程是可靠信号）' (Test-HarnessRunning)

Reset
$script:BackgroundTrayMarker = $trayMarkerOff
Check '  无进程、无窗口 -> 认为未运行' (-not (Test-HarnessRunning))

Write-Host '  托盘模式 = 开（进程故意常驻，窗口才是真相）'
Reset
$script:BackgroundTrayMarker = $trayMarkerOn
$script:ProcessNames = @('DeepSeek Harness')
Check '  进程常驻、窗口已隐藏 -> 认为已关闭（否则桌宠永不收起）' (-not (Test-HarnessRunning))

Reset
$script:BackgroundTrayMarker = $trayMarkerOn
$script:ProcessNames = @('DeepSeek Harness')
$script:WindowTitles = @('# DeepSeek Harness x — DeepSeek Harness')
Check '  进程常驻、窗口可见 -> 认为在运行' (Test-HarnessRunning)

Reset
$script:BackgroundTrayMarker = $trayMarkerOn
$script:WindowTitles = @('蓝鲸小深')
Check '  托盘模式开，只有桌宠自己的窗口 -> 认为已关闭' (-not (Test-HarnessRunning))

Write-Host '  强制覆盖参数（供测试固定行为，必须能被显式关闭）'
Reset
$script:BackgroundTrayEnabled = 'true'
$script:ProcessNames = @('DeepSeek Harness')
Check "  -BackgroundTrayEnabled 'true' -> 忽略进程，只看窗口" (-not (Test-HarnessRunning))

Reset
$script:BackgroundTrayEnabled = 'false'
$script:BackgroundTrayMarker = $trayMarkerOn
$script:ProcessNames = @('DeepSeek Harness')
Check "  -BackgroundTrayEnabled 'false' -> 恢复按进程判断" (Test-HarnessRunning)

Write-Host ''
Write-Host '=== Harness 启动中/托盘无窗口时仍应算运行（托盘模式关）==='
Reset
$script:BackgroundTrayMarker = $trayMarkerOff
$script:ProcessNames = @('DeepSeek Harness')
Check '有进程无窗口 -> 认为在运行' (Test-HarnessRunning)

Remove-Item -LiteralPath $trayMarkerOn -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: Harness 检测在两种信号下都正确，托盘模式两种设置都正确，且不会把桌宠自身当成 Harness。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
