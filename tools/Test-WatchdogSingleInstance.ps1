# Test-WatchdogSingleInstance.ps1 - only one watchdog may run at a time.
#
# WHY THIS EXISTS
#   Duplicate pets had a single cause: several watchdogs running at once, each independently
#   deciding "Harness is up and no pet is on screen" and starting its own pet. Successive
#   installs and tests each left one behind, and nothing stopped them accumulating — the log
#   eventually named 24 distinct watchdog pids.
#
#   The signature in the log was unmistakable, and is what this test pins down: events arriving in
#   PAIRS hundredths of a second apart, because two watchdogs acted on the same observation.
#     started the processes but no pet window appeared within 8000ms
#     started the processes but no pet window appeared within 8000ms
#     started the pet ... (window up after 403ms)
#     started the pet ... (window up after 874ms)     <- two pets, one per watchdog
#
# WHAT IS VERIFIED
#   1. The guard exists and uses an OS mutex, which is atomic — unlike a pid file or a window
#      scan, there is no window in which two instances can both believe they are first.
#   2. Launching three watchdogs really leaves exactly one alive.
#   3. `-Once` runs are exempt: they are short-lived by design and must not be blocked by a
#      resident watchdog (the shortcuts and several tests rely on this).

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$script = Join-Path $Root 'tools\Watch-Pet.ps1'
$text = [System.IO.File]::ReadAllText($script)

$failures = 0
function Check([string]$Label, [bool]$Ok) {
    if ($Ok) { Write-Host "  OK   $Label" }
    else { Write-Host "  FAIL $Label"; $script:failures++ }
}

Write-Host '=== 守卫存在且使用原子互斥体 ==='
Check '代码里创建了命名互斥体' ($text -match 'System\.Threading\.Mutex')
Check '互斥体名字稳定（两次运行必须用同一个名字）' ($text -match "Local\\BlueWhalePetWatchdog")
Check '未取得所有权时退出' ($text -match 'if \(-not \$createdNew\)')

# The mutex must be created BEFORE the loop starts, or two instances could both enter it.
$mutexAt = $text.IndexOf('System.Threading.Mutex')
$loopAt = $text.IndexOf('while ($true)')
Check '互斥体在进入主循环之前创建' ($mutexAt -gt 0 -and $mutexAt -lt $loopAt)

Write-Host ''
Write-Host '=== -Once 必须豁免（短命运行不能被常驻看门狗挡掉）==='
$onceGuardAt = $text.IndexOf('if (-not $Once) {')
Check '互斥体被 if (-not $Once) 包裹' ($onceGuardAt -gt 0 -and $onceGuardAt -lt $mutexAt)

Write-Host ''
Write-Host '=== 实测：连开 3 个，只应存活 1 个 ==='
$procs = @()
try {
    for ($i = 1; $i -le 3; $i++) {
        $procs += Start-Process -FilePath 'powershell' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                            '-File', $script, '-Root', $Root, '-IntervalMs', '3000')
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds 6

    $alive = @($procs | Where-Object { $null -ne (Get-Process -Id $_.Id -ErrorAction SilentlyContinue) })
    Write-Host ("  启动 3 个，存活 {0} 个: {1}" -f $alive.Count, (($alive | ForEach-Object { $_.Id }) -join ', '))
    Check '恰好 1 个看门狗存活' ($alive.Count -eq 1)
} finally {
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    # Release the mutex by ensuring no watchdog remains, so a later run is not blocked.
    Start-Sleep -Milliseconds 800
}

Write-Host ''
Write-Host '=== 安装脚本必须替换旧的看门狗（否则新代码永远不生效）==='
$installText = [System.IO.File]::ReadAllText((Join-Path $Root 'tools\Install-Autostart.ps1'))
Check '安装时会停止已有的看门狗' ($installText -match 'Watch-Pet\.ps1' -and $installText -match 'Stop-Process')

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 看门狗有原子单实例保护，重复安装不再累积，因此不会出现重复桌宠。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
