# Test-AutostartLive.ps1 - verify the autostart feature against the REAL DeepSeek Harness.
#
# WHY YOU RUN THIS, NOT THE AGENT
#   Two of the four checks require closing and reopening DeepSeek Harness. An agent session runs
#   INSIDE Harness, so closing it terminates the session that would be doing the checking. The
#   behaviour itself is already verified end to end by tools\Test-WatchdogLoop.ps1, which drives
#   the real watchdog loop against a stand-in process; what this script adds is confirmation
#   against the genuine application.
#
# HOW TO USE
#   1. Install autostart first (once):
#        powershell -NoProfile -ExecutionPolicy Bypass -File tools\Install-Autostart.ps1
#   2. Run this script and follow the three prompts. It checks what it can at each step.
#
#   Nothing here changes your files: it only reads state and waits.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'tools\PetWindowNative.ps1')

$stateFile = Join-Path $Root 'state\watchdog.json'
$failures = 0

function Write-Head([string]$Text) {
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}
function Check([string]$Label, [bool]$Ok, [string]$Note = '') {
    if ($Ok) { Write-Host "  [OK]   $Label" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $Label" -ForegroundColor Red; $script:failures++ }
    if ($Note -ne '') { Write-Host "         $Note" -ForegroundColor DarkGray }
}

function Get-PetWindowCount {
    return @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '蓝鲸小深*' }).Count
}
function Get-HarnessProcessCount {
    return @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue).Count
}
function Get-WatchdogState {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try { return Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}
function Wait-Until([scriptblock]$Test, [int]$TimeoutMs, [string]$What) {
    Write-Host "  waiting for $What (up to $([int]($TimeoutMs / 1000))s)..." -ForegroundColor DarkGray
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (& $Test) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return (& $Test)
}

Write-Host '蓝鲸小深 · 自动启动实机验证' -ForegroundColor Cyan
Write-Host '（本脚本只读取状态，不修改任何文件）'

# --- step 1: is autostart actually installed and running? --------------------
Write-Head '第 1 步：自动启动是否已安装并运行'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$installedVbs = Join-Path $startupDir 'BlueWhalePet.vbs'
$installed = Test-Path -LiteralPath $installedVbs
Check 'Startup 启动项已安装' $installed $(if ($installed) { $installedVbs } else { "未安装。请先运行: powershell -NoProfile -ExecutionPolicy Bypass -File `"$Root\tools\Install-Autostart.ps1`"" })

$wdState = Get-WatchdogState
$wdAlive = $false
if ($null -ne $wdState) {
    $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$wdState.at
    $proc = Get-Process -Id ([int]$wdState.pid) -ErrorAction SilentlyContinue
    $wdAlive = ($age -lt 30000) -and ($null -ne $proc)
}
Check '看门狗正在运行' $wdAlive $(if ($null -ne $wdState) { "心跳 pid=$($wdState.pid)" } else { '没有心跳文件' })

if (-not $installed) {
    Write-Host ''
    Write-Host '自动启动尚未安装，后续步骤无意义。请先安装后再运行本脚本。' -ForegroundColor Yellow
    exit 2
}

# --- step 2: Harness open -> pet appears ------------------------------------
Write-Head '第 2 步：Harness 打开时桌宠应自动出现'
$harness = Get-HarnessProcessCount
Check 'DeepSeek Harness 正在运行' ($harness -gt 0) "进程数: $harness"

if ($harness -gt 0) {
    $appeared = Wait-Until { (Get-PetWindowCount) -gt 0 } 30000 '桌宠窗口出现'
    Check '桌宠已自动出现在屏幕上' $appeared "当前桌宠窗口数: $(Get-PetWindowCount)"
    $s = Get-WatchdogState
    if ($null -ne $s) { Check '看门狗记录了启动动作' ($s.lastAction -eq 'started' -or $s.lastAction -eq 'none') "lastAction=$($s.lastAction)" }
}

# --- step 3: the interactive part (needs you) -------------------------------
Write-Head '第 3 步：关闭 Harness 后桌宠应自动收起'
Write-Host '  请现在【完全退出 DeepSeek Harness】（关闭窗口；若它在托盘中，也请一并退出）。'
Write-Host '  注意：如果你正通过 Harness 与 AI 对话，这会结束该对话——本步骤需要你手动完成。'
Write-Host ''
$null = Read-Host '  退出 Harness 后，按回车继续'

$gone = Wait-Until { (Get-HarnessProcessCount) -eq 0 } 60000 'Harness 进程完全退出'
if (-not $gone) {
    Write-Host "  提示：仍有 $(Get-HarnessProcessCount) 个 Harness 进程存活。" -ForegroundColor Yellow
    Write-Host '        如果关掉窗口后进程仍在，说明 Harness 会驻留后台，'
    Write-Host '        那么"关闭窗口即收起桌宠"需要改为以窗口为准——请把这一现象告诉 AI。' -ForegroundColor Yellow
}
Check 'Harness 进程已全部退出' $gone "剩余: $(Get-HarnessProcessCount)"

if ($gone) {
    # The watchdog waits out its grace period (20s by default) before stopping the pet, so that a
    # Harness restart does not make the pet blink out and back.
    $hid = Wait-Until { (Get-PetWindowCount) -eq 0 } 60000 '桌宠自动收起'
    Check '桌宠已自动收起（宽限期后）' $hid "当前桌宠窗口数: $(Get-PetWindowCount)"
    $s = Get-WatchdogState
    if ($null -ne $s) { Check '看门狗记录了停止动作' ($s.lastAction -eq 'stopped') "lastAction=$($s.lastAction)" }
}

# --- step 4: reopen Harness -> pet returns ----------------------------------
Write-Head '第 4 步：重新打开 Harness 后桌宠应再次出现'
Write-Host '  请现在重新打开 DeepSeek Harness（用桌面快捷方式）。'
Write-Host ''
$null = Read-Host '  打开后，按回车继续'

$back = Wait-Until { (Get-HarnessProcessCount) -gt 0 } 60000 'Harness 重新启动'
Check 'Harness 已重新运行' $back "进程数: $(Get-HarnessProcessCount)"

if ($back) {
    $again = Wait-Until { (Get-PetWindowCount) -gt 0 } 60000 '桌宠重新出现'
    Check '桌宠已自动重新出现' $again "当前桌宠窗口数: $(Get-PetWindowCount)"
    $s = Get-WatchdogState
    if ($null -ne $s) { Check '看门狗记录了重新启动' ($s.lastAction -eq 'started') "lastAction=$($s.lastAction)" }
}

# --- step 5: the exit command must be respected -----------------------------
Write-Head '第 5 步：右键「退出桌宠」后不应被自动拉起'
Write-Host '  请右键点击桌宠 → 退出桌宠。'
Write-Host ''
$null = Read-Host '  退出后，按回车继续'

Start-Sleep -Seconds 12   # longer than the watchdog poll interval
$stillGone = (Get-PetWindowCount) -eq 0
Check '退出后 12 秒内没有被自动拉起' $stillGone "当前桌宠窗口数: $(Get-PetWindowCount)"
Check '存在 pet-quit 抑制标记' (Test-Path -LiteralPath (Join-Path $Root 'state\pet-quit'))
Write-Host '  （若想恢复桌宠：重新打开 Harness，或运行 scripts\start-pet.cmd）' -ForegroundColor DarkGray

# --- summary ----------------------------------------------------------------
Write-Head '结果'
if ($failures -eq 0) {
    Write-Host '全部通过：自动启动按预期工作。' -ForegroundColor Green
    Write-Host '日志: ' -NoNewline; Write-Host (Join-Path $Root 'build\watchdog.log') -ForegroundColor DarkGray
    exit 0
}
Write-Host "$failures 项未通过，请把上面的 [FAIL] 行连同日志交给 AI。" -ForegroundColor Red
Write-Host '日志: ' -NoNewline; Write-Host (Join-Path $Root 'build\watchdog.log') -ForegroundColor DarkGray
exit 1
