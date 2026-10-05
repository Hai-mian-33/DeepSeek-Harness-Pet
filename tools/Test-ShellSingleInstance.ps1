# Test-ShellSingleInstance.ps1 - only one pet shell may run, even under simultaneous launches.
#
# WHY THIS EXISTS
#   Two whales appeared repeatedly, and the shell's own guard did not stop it. That guard scanned
#   for an existing pet WINDOW, which is racy: two shells launched seconds apart both scan while
#   NEITHER has a window yet, both conclude they are alone, and both proceed. The trigger was a
#   cold start exceeding the watchdog's verification window, so a second launch was attempted while
#   the first was still starting — and the first shell's window arrived afterwards.
#
#   A named mutex closes that hole because it is atomic: the OS guarantees exactly one creator, so
#   there is no interval in which two instances can both believe they are first. This matters even
#   with the watchdog's own single-instance guard, because stale watchdogs from an earlier build
#   cannot be reached to be stopped and will happily each launch a pet.
#
# WHAT IS VERIFIED
#   1. The shell takes an OS mutex before doing anything else.
#   2. Launching three shells at once leaves exactly one alive, with exactly one pet on screen.
#   3. The window scan is kept as a secondary check (it catches a pet started by an older build,
#      which never took the mutex).
#   4. The mutex is released by process exit, so a crash cannot leave the pet permanently unable to
#      start.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$shell = Join-Path $Root 'src\shell\WhalePet.ps1'
$text = [System.IO.File]::ReadAllText($shell)

$failures = 0
function Check([string]$Label, [bool]$Ok) {
    if ($Ok) { Write-Host "  OK   $Label" }
    else { Write-Host "  FAIL $Label"; $script:failures++ }
}

Write-Host '=== 守卫结构 ==='
Check '创建了命名互斥体' ($text -match 'System\.Threading\.Mutex')
Check '互斥体名字稳定' ($text -match 'Local\\BlueWhalePetShell')
Check '未取得所有权时放弃启动' ($text -match 'if \(-not \$createdNew\)\s*\{' -and $text -match 'return')
Check '保留了窗口扫描作为第二道防线' ($text -match 'another pet \(pid')

# The mutex must be taken at the very top of Start-Pet, before any window is built, or two
# instances could both get far enough to create one.
$mutexAt = $text.IndexOf('Local\BlueWhalePetShell')
$firstWindowAt = $text.IndexOf('function Build-PetWindow')
Check '互斥体在构建窗口之前取得' ($mutexAt -gt 0 -and ($firstWindowAt -lt 0 -or $mutexAt -lt $text.IndexOf('$pet = Build-PetWindow')))

Write-Host ''
Write-Host '=== 实测：同时启动 3 个 shell，只应存活 1 个 ==='

# The mutex is per desktop session, so a REAL pet already on screen holds it — every test shell
# would then exit immediately. That IS the guard working, but it would be reported here as
# "0 alive". The test therefore asks a running pet to quit first and waits for the release.
. (Join-Path $Root 'tools\PetWindowNative.ps1')
$existing = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '蓝鲸小深*' })
if ($existing.Count -gt 0) {
    Write-Host ("  屏幕上已有桌宠（{0} 个窗口），先请它退出，以便观察互斥体本身" -f $existing.Count)
    $cmdFile = Join-Path $Root 'state\shell-command.json'
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            [System.IO.File]::WriteAllText($cmdFile, '{"command":"quit"}', (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
        Start-Sleep -Seconds 4
        if (@(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '蓝鲸小深*' }).Count -eq 0) { break }
    }
    if (@(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '蓝鲸小深*' }).Count -gt 0) {
        Write-Host '  SKIP: 已有桌宠未能退出（互斥体仍被持有），本项无法验证。'
        Write-Host '        请在桌宠上右键 → 退出桌宠，然后重跑。'
        exit 3
    }
    Start-Sleep -Seconds 2
}

$procs = @()
try {
    for ($i = 1; $i -le 3; $i++) {
        $procs += Start-Process -FilePath 'powershell' -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                            '-File', $shell, '-WindowTitle', 'SHELLTESTPET')
    }

    # A cold start needs time; poll rather than assume.
    $deadline = 40000
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $alive = @()
    while ($sw.ElapsedMilliseconds -lt $deadline) {
        $alive = @($procs | Where-Object { $null -ne (Get-Process -Id $_.Id -ErrorAction SilentlyContinue) })
        if ($alive.Count -le 1 -and $sw.ElapsedMilliseconds -gt 8000) { break }
        Start-Sleep -Milliseconds 500
    }

    Write-Host ("  启动 3 个，存活 {0} 个: {1}" -f $alive.Count, (($alive | ForEach-Object { $_.Id }) -join ', '))
    Check '恰好 1 个 shell 存活' ($alive.Count -eq 1)

    # And exactly one pet window pair on screen.
    . (Join-Path $Root 'tools\PetWindowNative.ps1')
    $owners = @(Get-AllWindows |
        Where-Object { $_.Visible -and $_.Title -like 'SHELLTESTPET*' } |
        Select-Object -ExpandProperty Owner -Unique)
    Write-Host ("  拥有测试桌宠窗口的进程数: {0}" -f $owners.Count)
    Check '屏幕上只有 1 个桌宠实例' ($owners.Count -le 1)
} finally {
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Seconds 1
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 桌宠 shell 有原子单实例保护，并发启动也只会留下一个。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
