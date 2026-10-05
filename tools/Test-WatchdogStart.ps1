# Test-WatchdogStart.ps1 - verify the watchdog can actually START the pet.
#
# Why this needs its own test: the decision table is covered by Test-Watchdog.ps1, but the
# spawn itself was never exercised. A watchdog that decides correctly and then fails to
# launch anything is the worst possible outcome -- the pet never appears, and nothing on
# screen explains why.
#
# Why a probe directory rather than the real project: the pet must not be killed to run a
# test, and the real watchdog (correctly) does nothing while a pet is already on screen, so
# the start branch cannot be reached live. This test therefore:
#
#   * builds a throwaway "project" whose bridge and shell are stubs that record that they ran;
#   * extracts the REAL `Start-PetNow` from tools\Watch-Pet.ps1 and calls it with that root;
#   * asserts both stubs actually executed, proving the paths and argument shapes are right.
#
# The logic under test is the shipped code; only the location and the two leaf programs differ.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }

$probe = Join-Path $Root 'build\watchdog-start-probe'
$bridgeMarker = Join-Path $probe 'bridge-ran.txt'
$shellMarker = Join-Path $probe 'shell-ran.txt'

Remove-Item -Recurse -Force $probe -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $probe 'src\shell') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $probe 'tools') | Out-Null

# --- build the stub "project" -----------------------------------------------

# The bridge stub is JS, so its path is written with forward slashes: a Windows path in a
# JS single-quoted string would have its backslashes treated as escapes and be corrupted.
$bridgePathJs = $bridgeMarker.Replace('\', '/')
$bridgeStub = "import { writeFileSync } from 'node:fs';`nwriteFileSync('$bridgePathJs', 'bridge-started');`n"
[System.IO.File]::WriteAllText((Join-Path $probe 'src\bridge.mjs'), $bridgeStub,
    [System.Text.UTF8Encoding]::new($false))

# The stub MUST live at src\shell\WhalePet.ps1, not src\WhalePet.ps1. Start-PetNow launches
# `<root>\src\shell\WhalePet.ps1`; placing the stub one directory too high pointed `-File` at a
# missing path, PowerShell exited instantly, and the test reported a failure in the watchdog
# that did not exist. The asymmetry is worth noting: the bridge lives at src\bridge.mjs while
# the shell lives at src\shell\WhalePet.ps1.
$shellStub = "[System.IO.File]::WriteAllText('$shellMarker', 'shell-started')`n"
[System.IO.File]::WriteAllText((Join-Path $probe 'src\shell\WhalePet.ps1'), $shellStub,
    [System.Text.UTF8Encoding]::new($false))

# Start-PetNow calls Stop-Pet.ps1 first; a no-op keeps that path exercised but harmless.
[System.IO.File]::WriteAllText((Join-Path $probe 'tools\Stop-Pet.ps1'), "exit 0`n",
    [System.Text.UTF8Encoding]::new($false))

# --- extract the real start function ----------------------------------------

$text = [System.IO.File]::ReadAllText((Join-Path $Root 'tools\Watch-Pet.ps1'))
$match = [regex]::Match($text, "(?ms)^function\s+Start-PetNow\s*\{.*?^\}")
if (-not $match.Success) { Write-Host 'FAIL: 无法从 Watch-Pet.ps1 提取 Start-PetNow'; exit 1 }
Invoke-Expression $match.Value

# Write-WatchLog is the only side dependency; its real version writes to the log file.
$script:LogLines = New-Object System.Collections.Generic.List[string]
function Write-WatchLog { param([string]$Message) $script:LogLines.Add($Message) }

# Start-PetNow now VERIFIES its launch by waiting for the pet's window (Test-PetRunning)
# instead of trusting that no exception was thrown. In this probe there is no real pet
# window, so the stub reports success as soon as the shell marker exists — which is the
# evidence the real check would find via the window.
function Test-PetRunning { return (Test-Path -LiteralPath $shellMarker) }

Write-Host '=== 调用真实的 Start-PetNow（指向探针目录）==='
$savedRoot = $Root
$Root = $probe                      # Start-PetNow resolves every path from this
$ok = Start-PetNow
$Root = $savedRoot

Write-Host ''
Write-Host '=== 探针程序是否真的被执行 ==='
# Both spawns are asynchronous: Start-PetNow starts the bridge, sleeps ~1.8s, starts the
# shell, and returns WITHOUT waiting for either. A fixed short sleep here therefore raced the
# shell's own start-up and reported a failure that did not exist — the first version of this
# test waited 800ms and produced exactly that false negative. Polling for both markers
# removes the race, and a generous ceiling keeps a real failure distinguishable from a slow
# machine.
$deadline = 30000
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt $deadline) {
    if ((Test-Path -LiteralPath $bridgeMarker) -and (Test-Path -LiteralPath $shellMarker)) { break }
    Start-Sleep -Milliseconds 200
}
Write-Host ("  等待耗时: {0} ms" -f $sw.ElapsedMilliseconds)

$failures = 0
foreach ($pair in @(
    @{ Name = 'bridge (node)';  Path = $bridgeMarker; Want = 'bridge-started' },
    @{ Name = 'shell (powershell)'; Path = $shellMarker; Want = 'shell-started' }
)) {
    if (Test-Path -LiteralPath $pair.Path) {
        $content = [System.IO.File]::ReadAllText($pair.Path).Trim()
        if ($content -eq $pair.Want) {
            Write-Host "  OK   $($pair.Name) 已启动"
        } else {
            Write-Host "  FAIL $($pair.Name) 内容异常: '$content'"
            $failures++
        }
    } else {
        Write-Host "  FAIL $($pair.Name) 从未启动（等待 ${deadline}ms 后仍无标记）"
        $failures++
    }
}

Write-Host ''
Write-Host '=== Start-PetNow 的返回值与日志 ==='
Write-Host ("  返回值: {0}" -f $ok)
foreach ($line in $script:LogLines) { Write-Host "  日志: $line" }
if ($ok -ne $true) { Write-Host '  FAIL 返回值应为 True'; $failures++ }

# Give the spawned stubs a moment, then clean up so no stray process or directory remains.
Start-Sleep -Milliseconds 800
Remove-Item -Recurse -Force $probe -ErrorAction SilentlyContinue

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 看门狗能真正启动桌宠（桥接与 shell 都被拉起）。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
