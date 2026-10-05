# Test-WatchdogLoop.ps1 - run the REAL watchdog loop end to end against a stand-in process.
#
# Why this exists
# ---------------
# Every other watchdog test replaces either the probes or the effects. That leaves the one
# thing the objective actually asks for unverified: that the shipped loop, running normally,
# starts the pet when its target appears and stops it when the target goes away.
#
# Closing the user's DeepSeek Harness to test that would interrupt their work, so the loop is
# pointed at a harmless process instead via -HarnessProcessName. The loop, the grace period,
# the quit marker and the start/stop calls are all the shipped code; only the project root is a
# throwaway copy whose bridge and shell are stubs that record that they ran.
#
# The stubs make Test-PetRunning report true by creating files with the pet's own titles, so
# the real window-based liveness check is exercised rather than bypassed.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }

$probe = Join-Path $Root 'build\watchdog-loop-probe'
$bridgeMarker = Join-Path $probe 'bridge-ran.txt'
$shellMarker = Join-Path $probe 'shell-ran.txt'
$shellPidFile = Join-Path $probe 'shell-pid.txt'
$logFile = Join-Path $probe 'build\watchdog.log'

Remove-Item -Recurse -Force $probe -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $probe 'src\shell') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $probe 'tools') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $probe 'build') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $probe 'state') | Out-Null

function Write-Stub {
    param([string]$Path, [string]$Content, [switch]$Bom)
    # PowerShell 5.1 decodes a UTF-8 file WITHOUT a BOM using the ANSI code page, so the
    # Chinese window title in the shell stub would arrive as mojibake and the pet window would
    # never match. Every .ps1 stub is therefore written with a BOM; the JS stub is not, because
    # Node reads UTF-8 regardless.
    $encoding = if ($Bom) { [System.Text.UTF8Encoding]::new($true) } else { [System.Text.UTF8Encoding]::new($false) }
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

# The bridge stub records that it ran. Forward slashes: a Windows path inside a JS string
# literal would have its backslashes eaten as escapes.
$markerJs = $bridgeMarker.Replace('\', '/')
Write-Stub (Join-Path $probe 'src\bridge.mjs') `
    "import { writeFileSync } from 'node:fs';`nwriteFileSync('$markerJs', 'bridge-started');`n"

# The shell stub stands in for the real shell in two ways: it records that it ran, AND it
# creates a window whose title matches the pet's, so the real Test-PetRunning finds it. Without
# the second part the loop would start the "pet", fail to see it, and report failure forever --
# which is a property of the stub, not of the watchdog.
$shellStub = @"
param([string]`$WindowTitle = '蓝鲸小深-TESTPROBE')
try {
[System.IO.File]::WriteAllText('$shellPidFile', "`$PID")
[System.IO.File]::WriteAllText('$shellMarker', 'shell-started')
# Stand in for the pet's real window: Test-PetRunning looks for a visible window whose title
# starts with the pet's own name. A WinForms form is the simplest way to own such a window.
Add-Type -AssemblyName System.Windows.Forms
`$form = New-Object System.Windows.Forms.Form
`$form.Text = `$WindowTitle
`$form.ShowInTaskbar = `$false
`$form.Width = 120
`$form.Height = 130
`$form.Show()
[System.IO.File]::WriteAllText('$probe\shell-window-up.txt', 'up')
while (`$true) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
} catch {
[System.IO.File]::WriteAllText('$probe\stub-error.txt', `$_.Exception.ToString())
}
"@
Write-Stub (Join-Path $probe 'src\shell\WhalePet.ps1') $shellStub -Bom

# Start-PetNow calls Stop-Pet.ps1 before launching. In the probe it must REALLY remove the pet,
# or the loop would never leave the "pet is running" state and the stop half of the cycle could
# not be observed. The stub shell is identified by its command line, so unrelated powershell
# processes are untouched.
$stopStub = @"
`$probe = '$probe'
`$pidFile = Join-Path `$probe 'shell-pid.txt'
if (Test-Path -LiteralPath `$pidFile) {
    `$stubPid = [int](Get-Content -LiteralPath `$pidFile -Raw).Trim()
    try { Stop-Process -Id `$stubPid -Force -ErrorAction Stop } catch { }
}
Start-Sleep -Milliseconds 500
# The window goes with the process, so the markers must be cleared too; otherwise they linger and
# the "window is gone" check could never pass.
Remove-Item -LiteralPath (Join-Path `$probe 'shell-window-up.txt') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath `$pidFile -Force -ErrorAction SilentlyContinue
exit 0
"@
Write-Stub (Join-Path $probe 'tools\Stop-Pet.ps1') $stopStub -Bom

# Copy the real watchdog and its dependency, so the probe runs shipped code.
Copy-Item (Join-Path $Root 'tools\Watch-Pet.ps1') (Join-Path $probe 'tools\Watch-Pet.ps1') -Force
Copy-Item (Join-Path $Root 'tools\PetWindowNative.ps1') (Join-Path $probe 'tools\PetWindowNative.ps1') -Force

$loopScript = Join-Path $probe 'tools\Watch-Pet.ps1'
foreach ($f in @($loopScript, (Join-Path $probe 'tools\PetWindowNative.ps1'))) {
    $t = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($f, $t, [System.Text.UTF8Encoding]::new($true))
}

$failures = 0
function Check([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "  OK   $label" }
    else { Write-Host "  FAIL $label"; $script:failures++ }
}

function Wait-For([scriptblock]$Test, [int]$TimeoutMs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (& $Test) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return (& $Test)
}

# --- precondition ------------------------------------------------------------

# Window enumeration comes from the same helper the watchdog uses, so "is a pet on screen?" is
# answered by the same code under test rather than by a second implementation.
. (Join-Path $Root 'tools\PetWindowNative.ps1')

# Pet liveness is judged by a window title, which is global to the desktop. If a REAL pet is
# already on screen, the probe's watchdog correctly concludes "a pet is already running" and
# never reaches its start branch -- so the start half of this test fails for a reason that has
# nothing to do with the watchdog. That is exactly what happened on the first run: the stop half
# passed and the start half did not.
#
# The probe therefore uses its OWN title prefix, passed to the watchdog via -PetWindowTitle, which
# isolates it from a real pet completely. This test can then run at any time, including while the
# user's pet is on screen; the check below only has to catch a leftover probe from an interrupted
# earlier run.
Write-Host '=== 前置条件：没有上次遗留的探针桌宠 ==='
$existing = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '蓝鲸小深-TESTPROBE*' })
if ($existing.Count -gt 0) {
    Write-Host "  检测到 $($existing.Count) 个遗留的探针窗口，先清理："
    foreach ($w in $existing) {
        Write-Host "    hwnd=$($w.Handle) pid=$($w.Owner) '$($w.Title)'"
        try { Stop-Process -Id $w.Owner -Force -ErrorAction Stop } catch { }
    }
    Start-Sleep -Seconds 1
}
Write-Host '  干净，可以测试启动路径'
Write-Host ''

# --- start the watchdog loop, watching a harmless process --------------------

Write-Host '=== 准备：启动一个无害进程冒充 Harness ==='
# The stand-in is a COPY of ping.exe under a unique name, not notepad. Windows 11's notepad is a
# packaged single-instance app: killing it and relaunching the same name is unreliable (the second
# launch may just re-activate a lingering instance), which made the final section of this test fail
# for a reason unrelated to the watchdog. A copied binary has a unique, predictable process name
# and simply stays alive.
$targetExe = Join-Path $probe 'PetProbeTarget.exe'
Copy-Item -LiteralPath (Join-Path $env:windir 'System32\ping.exe') -Destination $targetExe -Force
$targetName = 'PetProbeTarget'
$stand = Start-Process -FilePath $targetExe -ArgumentList '-n', '3600', '127.0.0.1' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
$standAlive = @(Get-Process -Name $targetName -ErrorAction SilentlyContinue).Count -gt 0
Check "替身进程已启动 (name=$targetName, pid=$($stand.Id))" $standAlive

Write-Host ''
Write-Host '=== 启动真实看门狗循环（短周期，便于观察）==='
$watch = Start-Process -FilePath 'powershell' -PassThru -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', $loopScript, '-Root', $probe,
    '-IntervalMs', '1000', '-GraceMs', '3000',
    '-HarnessProcessName', $targetName, '-PetWindowTitle', '蓝鲸小深-TESTPROBE', '-IgnoreHarnessWindow', '-BackgroundTrayEnabled', 'false'
)
Check "看门狗已启动 (pid $($watch.Id))" ($null -ne (Get-Process -Id $watch.Id -ErrorAction SilentlyContinue))

Write-Host ''
Write-Host '=== 目标运行中：桌宠应被自动拉起 ==='
$windowMarker = Join-Path $probe 'shell-window-up.txt'
$petAppeared = Wait-For {
    (Test-Path -LiteralPath $shellMarker) -and (Test-Path -LiteralPath $windowMarker)
} 30000
Check '桥接被拉起' (Test-Path -LiteralPath $bridgeMarker)
Check 'shell 被拉起' (Test-Path -LiteralPath $shellMarker)
# The window marker is polled, not asserted immediately: the stub writes it after WinForms has
# initialised the form, so checking at the instant shell-ran.txt appears races that start-up and
# reports a failure that does not exist.
Check '桌宠窗口出现' (Test-Path -LiteralPath $windowMarker)
Check "看门狗报告已启动 (appeared=$petAppeared)" $petAppeared

Write-Host ''
Write-Host '=== 关闭目标：宽限期后桌宠应被收起 ==='
Get-Process -Name $targetName -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch { }
}
$gone = @(Get-Process -Name $targetName -ErrorAction SilentlyContinue).Count -eq 0
Write-Host "  替身进程已关闭 (全部实例已退出: $gone)"

$stateFile = Join-Path $probe 'state\watchdog.json'
function Get-LastAction {
    if (-not (Test-Path -LiteralPath $stateFile)) { return '' }
    try { return [string](Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).lastAction }
    catch { return '' }
}

# The stop must NOT be immediate: a Harness restart would otherwise make the pet blink out and
# back. Observing 'grace' before 'stopped' is what proves the grace period is doing its job.
$sawGrace = Wait-For { (Get-LastAction) -eq 'grace' } 20000
Check '进入宽限期（未立即停止）' $sawGrace

$stopped = Wait-For { (Get-LastAction) -eq 'stopped' } 20000
Check '宽限期后执行停止' $stopped

# And the pet must genuinely be gone, not merely reported as stopped: the real Test-PetRunning
# is what the next iteration consults, so a stale report would be corrected immediately.
$vanished = Wait-For {
    $w = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '蓝鲸小深-TESTPROBE*' })
    $w.Count -eq 0
} 15000
Check '桌宠窗口确实消失了（按真实窗口判断）' $vanished

Write-Host ''
Write-Host '=== 再次启动目标：桌宠应能重新出现 ==='
# A quit marker left over from a previous cycle must not suppress the restart; the watchdog
# clears it when the target stops.
$stand2 = Start-Process -FilePath $targetExe -ArgumentList '-n', '3600', '127.0.0.1' -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
$stand2Alive = @(Get-Process -Name $targetName -ErrorAction SilentlyContinue).Count -gt 0
Write-Host "  替身进程重新启动 (存活: $stand2Alive)"
$restarted = Wait-For {
    (Get-LastAction) -eq 'started' -and (Test-Path -LiteralPath $windowMarker)
} 30000
Check '目标重新出现后再次启动桌宠' $restarted
Check '没有残留的退出标记阻止启动' (-not (Test-Path -LiteralPath (Join-Path $probe 'state\pet-quit')))

Write-Host ''
Write-Host '=== 看门狗日志 ==='
if (Test-Path -LiteralPath $logFile) {
    Get-Content -LiteralPath $logFile | Select-Object -Last 12 | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host '  （无日志）'
}

# --- cleanup -----------------------------------------------------------------
Write-Host ''
Write-Host '=== 清理 ==='
foreach ($p in @($watch, $stand2)) {
    if ($null -ne $p) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
}
# The stub pet shell is a separate powershell; it is identified by its command line so that
# unrelated powershell processes are not touched.
try {
    $stubs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$probe*WhalePet.ps1*" })
    foreach ($s in $stubs) { try { Stop-Process -Id $s.ProcessId -Force } catch { } }
    Write-Host "  已停止 $($stubs.Count) 个桩 shell 进程"
} catch { }

Start-Sleep -Seconds 1
$stubErr = Join-Path $probe 'stub-error.txt'
if ((Test-Path -LiteralPath $stubErr) -and $failures -gt 0) {
    Write-Host '=== 桩脚本内部异常 ==='
    Get-Content -LiteralPath $stubErr | Select-Object -First 12 | ForEach-Object { Write-Host "  $_" }
}
if ($failures -eq 0) { Remove-Item -Recurse -Force $probe -ErrorAction SilentlyContinue }

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 真实看门狗循环能随目标进程启停桌宠。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
