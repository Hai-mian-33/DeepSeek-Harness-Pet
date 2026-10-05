# Test-SingleInstance.ps1 - verify a second pet refuses to start while one is on screen.
#
# WHY THIS MATTERS
#   Nothing used to stop two shells from running at once, and that happened in practice:
#   `start-pet.cmd` cannot always kill a shell that was launched OUTSIDE the caller's restricted
#   host (`Stop-Pet.ps1` reports "WARNING: N pet window(s) still present"), so a "restart" left
#   the old pet up and added a new one. The visible symptom is two whales on screen; the subtle
#   one is far worse — two shells racing over ONE command file, so a command is consumed by
#   whichever polls first. That is what made `quit` report `unknown 'quit'` even though the
#   source plainly contains it: an OLDER shell won the race. Diagnosing that from the outside is
#   guesswork, which is why the guard and this test exist.
#
# HOW IT TESTS
#   The real guard is extracted from `Start-Pet` and run against a stubbed window list, so all
#   four cases are exercised deterministically without touching the real desktop.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$text = [System.IO.File]::ReadAllText((Join-Path $Root 'src\shell\WhalePet.ps1'))

# The guard is the block at the top of Start-Pet, up to the "Probe once" comment that follows it.
$match = [regex]::Match($text, "(?ms)^function Start-Pet \{.*?^    # Probe once")
if (-not $match.Success) {
    Write-Host 'FAIL: 无法从 Start-Pet 提取单实例守卫（锚点「# Probe once」是否还在？）'
    exit 1
}
$guardBody = ($match.Value -split "`r?`n" | Select-Object -Skip 1 | Select-Object -SkipLast 1) -join "`n"

# --- stubs ------------------------------------------------------------------
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:Windows = @()

function Write-Diag { param([string]$Message) $script:LogLines.Add($Message) }
function Get-AllVisibleWindows { return $script:Windows }

# The real guard now takes a named mutex FIRST and only then scans for windows. This test covers
# the window-scan layer, so the mutex is stubbed to "always acquired" — otherwise, whenever a real
# pet is on screen (holding the mutex), every case here would take the mutex-refusal path and the
# window assertions would never run, reporting failures that do not exist. The mutex itself is
# verified by tools\Test-ShellSingleInstance.ps1.
$guardBody = $guardBody -replace '(?s)\$script:PetMutex = \$null.*?\n    \}\n', ''
Invoke-Expression "function Invoke-Guard { param([string]`$WindowTitle) $guardBody }"

function Test-Refused {
    param([object[]]$Windows, [string]$Title = '蓝鲸小深')
    $script:Windows = $Windows
    $script:LogLines.Clear()
    Invoke-Guard -WindowTitle $Title | Out-Null
    return @($script:LogLines | Where-Object { $_ -match 'refusing to start' }).Count -gt 0
}

function New-Window([int]$Owner, [string]$Title) {
    return [pscustomobject]@{ Handle = [IntPtr]1; Owner = $Owner; Title = $Title; Visible = $true }
}

$failures = 0
function Check([string]$Label, [bool]$Ok) {
    if ($Ok) { Write-Host "  OK   $Label" }
    else { Write-Host "  FAIL $Label"; $script:failures++ }
}

Write-Host '=== 单实例守卫 ==='

Check '无同名窗口 -> 放行（正常启动不受影响）' `
    (-not (Test-Refused -Windows @(New-Window 1 '记事本')))

Check '已有别的进程的桌宠窗口 -> 拒绝' `
    (Test-Refused -Windows @(New-Window 4242 '蓝鲸小深'))

Check '自己的同名窗口 -> 放行（不得把自己当重复）' `
    (-not (Test-Refused -Windows @(New-Window ([int]$PID) '蓝鲸小深')))

Check '只有状态窗口（· 状态 后缀）-> 仍拒绝' `
    (Test-Refused -Windows @(New-Window 77 '蓝鲸小深 · 状态'))

Check '两个桌宠窗口同时存在 -> 拒绝' `
    (Test-Refused -Windows @(New-Window 11 '蓝鲸小深', (New-Window 22 '蓝鲸小深 · 状态')))

Check '别人的 Harness 窗口不触发拒绝' `
    (-not (Test-Refused -Windows @(New-Window 33 '# DeepSeek Harness 桌面宠物“蓝鲸 — DeepSeek Harness')))

Write-Host ''
Write-Host '=== 自定义标题（测试隔离用）也应遵守同一规则 ==='
Check '自定义标题下，同名窗口 -> 拒绝' `
    (Test-Refused -Windows @(New-Window 55 'GUARDTESTPET') -Title 'GUARDTESTPET')
Check '自定义标题下，真实桌宠窗口 -> 不拒绝（前缀不同）' `
    (-not (Test-Refused -Windows @(New-Window 66 '蓝鲸小深') -Title 'GUARDTESTPET'))

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 单实例守卫在全部用例下判断正确。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
