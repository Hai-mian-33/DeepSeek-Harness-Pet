# Watch-AutostartEvidence.ps1 - record what the autostart feature actually does, so the result
# can be inspected after Harness has been closed and reopened.
#
# WHY THIS EXISTS
#   "Closing Harness hides the pet, and reopening it brings the pet back" cannot be verified by an
#   agent session, because that session RUNS INSIDE Harness: closing Harness terminates the very
#   process doing the checking. The only honest way to obtain evidence is to record it
#   asynchronously — this script samples the desktop while you close and reopen Harness, then
#   leaves a timeline behind that can be read afterwards.
#
# WHAT IT RECORDS
#   Every sample: the number of `DeepSeek Harness` processes, whether a window identifying
#   Harness is visible, how many pet windows exist, and what the watchdog last decided. Every
#   CHANGE is logged as an explicit transition with a timestamp, which is what makes the file
#   readable as a story rather than a wall of numbers.
#
# HOW TO USE
#   1. Install autostart (once):
#        powershell -NoProfile -ExecutionPolicy Bypass -File tools\Install-Autostart.ps1
#   2. Start the recorder, detached:
#        powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File tools\Watch-AutostartEvidence.ps1
#      (or run it in a terminal and leave that terminal open)
#   3. Close DeepSeek Harness completely and wait ~40 s.
#   4. Reopen DeepSeek Harness and wait ~30 s.
#   5. Read build\autostart-evidence.txt
#
#   The recorder stops by itself once it has seen a full close/reopen cycle, or after -TimeoutSec.

param(
    [string]$Root = '',
    [int]$IntervalSec = 2,
    # Give up after this long even if no cycle was observed.
    [int]$TimeoutSec = 900,
    # Stop as soon as one complete cycle (closed -> pet hidden -> reopened -> pet shown) is seen.
    [switch]$StopAfterCycle = $true,
    # Print samples to the console as well (useful when run in a terminal).
    [switch]$Verbose
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'tools\PetWindowNative.ps1')

$evidenceFile = Join-Path $Root 'build\autostart-evidence.txt'
$jsonFile = Join-Path $Root 'build\autostart-evidence.json'
$watchdogState = Join-Path $Root 'state\watchdog.json'
$quitMarker = Join-Path $Root 'state\pet-quit'

$script:Lines = New-Object System.Collections.Generic.List[string]
$script:Transitions = New-Object System.Collections.Generic.List[object]

function Add-Line {
    param([string]$Text)
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line = "$stamp  $Text"
    $script:Lines.Add($line)
    if ($Verbose) { Write-Host $line }
}

function Get-Snapshot {
    $harnessProcs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue).Count
    $harnessWindows = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '*Harness*' }).Count
    $petWindows = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '蓝鲸小深*' }).Count
    $action = ''
    if (Test-Path -LiteralPath $watchdogState) {
        try { $action = [string](Get-Content -LiteralPath $watchdogState -Raw -Encoding UTF8 | ConvertFrom-Json).lastAction }
        catch { $action = '?' }
    }
    return [pscustomobject]@{
        HarnessProcs = $harnessProcs
        HarnessWindows = $harnessWindows
        PetWindows = $petWindows
        Action = $action
        Quit = (Test-Path -LiteralPath $quitMarker)
    }
}

# Was Harness open at the start? The recorder's verdict depends on having seen both halves.
$first = Get-Snapshot
$harnessWasOpen = ($first.HarnessProcs -gt 0) -or ($first.HarnessWindows -gt 0)

Add-Line '=== 蓝鲸小深 · 自动启动证据记录 ==='
Add-Line "记录开始；Harness 当时 $(if ($harnessWasOpen) { '已打开' } else { '未打开' })"
Add-Line "采样间隔 ${IntervalSec}s，超时 ${TimeoutSec}s"
Add-Line ''
Add-Line '时间       Harness进程  Harness窗口  桌宠窗口  看门狗动作  quit标记'
Add-Line ('-' * 74)

$previous = $first
$sawClosed = $false       # Harness was observed gone
$petHidAfterClose = $false
$sawReopened = $false
$petReturnedAfterReopen = $false
$startedAt = Get-Date

function Format-Sample([object]$s) {
    # FIVE placeholders for FIVE arguments, matching the five header columns. An earlier version
    # had six placeholders and five arguments, so every row threw "Error formatting a string" and
    # the record came out with a header and no data — exactly the kind of silently-empty evidence
    # this file exists to avoid. Values are cast explicitly for the same reason: `-f` also throws
    # when an argument's type does not suit its placeholder.
    return ('{0,11}  {1,11}  {2,10}  {3,10}  {4}' -f `
        [int]$s.HarnessProcs, [int]$s.HarnessWindows, [int]$s.PetWindows,
        [string]$s.Action, $(if ($s.Quit) { 'quit' } else { '-' }))
}

Add-Line (Format-Sample $first)

while (((Get-Date) - $startedAt).TotalSeconds -lt $TimeoutSec) {
    Start-Sleep -Seconds $IntervalSec
    $now = Get-Snapshot

    $changed = ($now.HarnessProcs -ne $previous.HarnessProcs) -or
               ($now.HarnessWindows -ne $previous.HarnessWindows) -or
               ($now.PetWindows -ne $previous.PetWindows) -or
               ($now.Action -ne $previous.Action) -or
               ($now.Quit -ne $previous.Quit)

    if ($changed) {
        Add-Line (Format-Sample $now)

        # Harness window state
        $harnessOpenNow = ($now.HarnessProcs -gt 0) -or ($now.HarnessWindows -gt 0)
        $harnessOpenBefore = ($previous.HarnessProcs -gt 0) -or ($previous.HarnessWindows -gt 0)

        if ($harnessOpenBefore -and -not $harnessOpenNow) {
            $sawClosed = $true
            $script:Transitions.Add([pscustomobject]@{ at = (Get-Date -Format 'HH:mm:ss'); what = 'harness-closed' })
            Add-Line '  >>> Harness 已关闭'
        }
        if (-not $harnessOpenBefore -and $harnessOpenNow) {
            $sawReopened = $true
            $script:Transitions.Add([pscustomobject]@{ at = (Get-Date -Format 'HH:mm:ss'); what = 'harness-reopened' })
            Add-Line '  >>> Harness 已重新打开'
        }

        # Pet visibility
        if ($previous.PetWindows -gt 0 -and $now.PetWindows -eq 0) {
            if ($sawClosed) { $petHidAfterClose = $true }
            $script:Transitions.Add([pscustomobject]@{ at = (Get-Date -Format 'HH:mm:ss'); what = 'pet-hidden' })
            Add-Line '  >>> 桌宠已收起'
        }
        if ($previous.PetWindows -eq 0 -and $now.PetWindows -gt 0) {
            if ($sawReopened) { $petReturnedAfterReopen = $true }
            $script:Transitions.Add([pscustomobject]@{ at = (Get-Date -Format 'HH:mm:ss'); what = 'pet-shown' })
            Add-Line '  >>> 桌宠已出现'
        }
    }

    $previous = $now

    if ($StopAfterCycle -and $sawClosed -and $petHidAfterClose -and $sawReopened -and $petReturnedAfterReopen) {
        Add-Line ''
        Add-Line '已观察到完整循环（关闭 -> 收起 -> 重开 -> 出现），记录结束。'
        break
    }
}

# --- verdict ----------------------------------------------------------------
Add-Line ''
Add-Line '=== 结论 ==='

$verdict = @()
if (-not $sawClosed) {
    $verdict += '未观察到 Harness 关闭 —— 请在记录期间完全退出 DeepSeek Harness。'
} elseif (-not $petHidAfterClose) {
    $verdict += 'Harness 关闭后桌宠【没有】自动收起，这是不符合预期的。'
    $verdict += '  可能原因：看门狗当时未在运行（检查 state\watchdog.json 心跳），'
    $verdict += '  或 Harness 有进程驻留后台（此时应以窗口为准，而不是进程）。'
} else {
    $verdict += 'Harness 关闭后桌宠已自动收起 —— 符合预期。'
}

if (-not $sawReopened) {
    $verdict += '未观察到 Harness 重新打开 —— 如已完成重开，请忽略此行。'
} elseif (-not $petReturnedAfterReopen) {
    $verdict += 'Harness 重开后桌宠【没有】自动出现，这是不符合预期的。'
} else {
    $verdict += 'Harness 重开后桌宠已自动出现 —— 符合预期。'
}

foreach ($v in $verdict) { Add-Line "  $v" }

$pass = $sawClosed -and $petHidAfterClose -and $sawReopened -and $petReturnedAfterReopen
Add-Line ''
Add-Line $(if ($pass) { '总判定: PASS' } else { '总判定: 未取得完整证据（见上）' })

[System.IO.File]::WriteAllLines($evidenceFile, $script:Lines, (New-Object System.Text.UTF8Encoding($false)))
$json = [pscustomobject]@{
    schema = 'dsh-pet-autostart-evidence/1'
    finishedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    sawHarnessClosed = $sawClosed
    petHidAfterClose = $petHidAfterClose
    sawHarnessReopened = $sawReopened
    petReturnedAfterReopen = $petReturnedAfterReopen
    pass = $pass
    transitions = $script:Transitions
}
[System.IO.File]::WriteAllText($jsonFile, ($json | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

Write-Host "证据已写入: $evidenceFile"
Write-Host "结构化结果: $jsonFile"
if ($Verbose) { Write-Host "总判定: $(if ($pass) { 'PASS' } else { '未取得完整证据' })" }
