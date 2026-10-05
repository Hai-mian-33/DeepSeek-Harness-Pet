# Test-Watchdog.ps1 - verify the watchdog's decision table for every state combination.
#
# The watchdog is the one component that has to be right without supervision: if it
# misjudges, the pet either never appears or refuses to go away, and nothing on screen says
# why. Its four interesting states cannot all be produced on demand (Harness cannot be
# closed and reopened freely, and the pet must not be killed mid-test), so the decisions are
# tested directly.
#
# Approach: extract the REAL decision function from the script, but replace its two probe
# functions (`Test-HarnessRunning`, `Test-PetRunning`) and its two effect functions
# (`Start-PetNow`, `Stop-PetNow`) with recording stubs. The logic under test is therefore
# the shipped logic, not a copy -- while the side effects stay observable and harmless.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$text = [System.IO.File]::ReadAllText((Join-Path $Root 'tools\Watch-Pet.ps1'))

function Get-FunctionSource([string]$name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($name))\s*\{.*?^\}"
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { throw "无法提取 $name" }
    return $m.Value
}

# --- observable stubs -------------------------------------------------------
$script:Harness = $true
$script:Pet = $false
$script:Started = 0
$script:Stopped = 0
$script:Log = New-Object System.Collections.Generic.List[string]

function Test-HarnessRunning { return $script:Harness }
function Test-PetRunning { return $script:Pet }
function Start-PetNow { $script:Started++; $script:Pet = $true; return $true }
function Stop-PetNow { $script:Stopped++; $script:Pet = $false; return $true }
function Write-WatchLog { param([string]$Message) $script:Log.Add($Message) }
function Write-WatchState { param([bool]$Harness, [bool]$Pet, [string]$Action) }

$script:DryRun = $false
$script:GraceMs = 20000

# The quit marker is read from disk by the real functions. They are stubbed here so the whole
# suite runs without touching state\, and so both answers can be exercised in one run.
$script:QuitRequested = $false
$script:ClearedCount = 0
$script:LaunchPending = $false
function Test-QuitRequested { return $script:QuitRequested }
function Clear-QuitRequest { $script:ClearedCount++ }
function Test-LaunchPending { return $script:LaunchPending }

# The real decision function.
Invoke-Expression (Get-FunctionSource 'Invoke-WatchStep')

$failures = 0
function Check([string]$label, [bool]$condition) {
    if ($condition) { Write-Host "  OK   $label" }
    else { Write-Host "  FAIL $label"; $script:failures++ }
}
function Reset-Throttle {
    $script:Started = 0; $script:Stopped = 0; $script:Log.Clear()
    $script:QuitRequested = $false; $script:ClearedCount = 0
    $script:LaunchPending = $false
}

Write-Host '=== 状态一：Harness 运行中，桌宠未运行 → 应启动 ==='
$script:Harness = $true; $script:Pet = $false; Reset-Throttle
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'started'（实际 '$action'）" ($action -eq 'started')
Check "启动被调用 1 次（实际 $script:Started）" ($script:Started -eq 1)
Check "停止未被调用（实际 $script:Stopped）" ($script:Stopped -eq 0)

Write-Host ''
Write-Host '=== 状态二：Harness 运行中，桌宠已运行 → 什么都不做 ==='
$script:Harness = $true; $script:Pet = $true; Reset-Throttle
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'none'（实际 '$action'）" ($action -eq 'none')
Check '没有产生任何动作' ($script:Started -eq 0 -and $script:Stopped -eq 0)

Write-Host ''
Write-Host '=== 状态三：Harness 已关闭，桌宠在运行 → 先宽限，不立即停止 ==='
$script:Harness = $false; $script:Pet = $true; Reset-Throttle
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'grace'（实际 '$action'）" ($action -eq 'grace')
Check "宽限期内不停止（实际停止 $script:Stopped 次）" ($script:Stopped -eq 0)
Check '记录了宽限开始时间' ($null -ne $absent)

Write-Host ''
Write-Host '=== 状态四：宽限期已过 → 应停止桌宠 ==='
$script:Harness = $false; $script:Pet = $true; Reset-Throttle
# 把"消失时刻"设到足够久以前，模拟宽限期已过
$absent = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 60000
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'stopped'（实际 '$action'）" ($action -eq 'stopped')
Check "停止被调用 1 次（实际 $script:Stopped）" ($script:Stopped -eq 1)

Write-Host ''
Write-Host '=== 状态五：Harness 已关闭且桌宠也已停止 → 什么都不做 ==='
$script:Harness = $false; $script:Pet = $false; Reset-Throttle
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'none'（实际 '$action'）" ($action -eq 'none')
Check '没有产生任何动作' ($script:Started -eq 0 -and $script:Stopped -eq 0)

Write-Host ''
Write-Host '=== 关键场景：Harness 重启不应让桌宠闪退 ==='
# Harness 短暂消失又回来，是常见操作（更新、应用自我重启）。宽限必须吸收它。
$script:Harness = $true; $script:Pet = $true; Reset-Throttle
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check '运行中不做动作' ($action -eq 'none')

$script:Harness = $false                      # Harness 关闭
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check '进入宽限' ($action -eq 'grace')

$script:Harness = $true                       # 很快又回来了
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check '恢复运行后不做动作' ($action -eq 'none')
Check "整个过程中桌宠从未被停止（实际停止 $script:Stopped 次）" ($script:Stopped -eq 0)
Check '宽限状态被重置' ($null -eq $absent)

Write-Host ''
Write-Host '=== Dry-run 不得产生任何副作用 ==='
$script:Harness = $true; $script:Pet = $false; Reset-Throttle
$script:DryRun = $true
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'would-start'（实际 '$action'）" ($action -eq 'would-start')
Check "没有真的启动（实际 $script:Started 次）" ($script:Started -eq 0)

$script:Harness = $false; $script:Pet = $true
$absent = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 60000
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'would-stop'（实际 '$action'）" ($action -eq 'would-stop')
Check "没有真的停止（实际 $script:Stopped 次）" ($script:Stopped -eq 0)
$script:DryRun = $false

Write-Host ''
Write-Host '=== 退出桌宠：用户主动关闭后不得被自动拉起 ==='
# 这是安装看门狗后必然出现的问题：右键「退出桌宠」把窗口关掉，而"Harness 在跑 + 没有桌宠"
# 正是看门狗要修复的状态，于是它会在几秒后把桌宠重新拉起来 —— 用户会认为退出功能坏了。
$script:Harness = $true; $script:Pet = $false; Reset-Throttle
$script:QuitRequested = $true
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'quit'（实际 '$action'）" ($action -eq 'quit')
Check "没有重新启动桌宠（实际启动 $script:Started 次）" ($script:Started -eq 0)

Write-Host ''
Write-Host '=== 陈旧标记必须自愈（否则桌宠永久锁死）==='
# 真实事故：Stop-Pet.ps1 杀 shell 时，shell 的关闭路径会写 pet-quit；而 Start-PetNow 又会先调用
# Stop-Pet.ps1，于是"先停止再启动"这一步毒化了启动本身 —— 标记残留，看门狗从此永远报 quit，
# 桌宠再也不出现。唯一线索只是心跳里的 lastAction=quit，极难解读。
# 因此标记必须有生命周期，且启动前必须被清掉。
$quitText = [System.IO.File]::ReadAllText((Join-Path $Root 'tools\Watch-Pet.ps1'))
$quitFn = [regex]::Match($quitText, "(?ms)^function Test-QuitRequested\s*\{.*?^\}")
Check '能从 Watch-Pet.ps1 提取 Test-QuitRequested' $quitFn.Success

if ($quitFn.Success) {
    $probeDir = Join-Path $Root 'build\quit-probe'
    Remove-Item -Recurse -Force $probeDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $probeDir 'state') | Out-Null

    $script:QuitMaxAgeMs = 1000
    $savedRoot = $Root
    $Root = $probeDir
    Invoke-Expression $quitFn.Value
    $marker = Join-Path $probeDir 'state\pet-quit'

    [System.IO.File]::WriteAllText($marker, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()).ToString())
    Check '新鲜标记 -> 抑制生效' (Test-QuitRequested)

    [System.IO.File]::WriteAllText($marker, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 60000).ToString())
    Check '过期标记 -> 自动失效（不再永久锁死）' (-not (Test-QuitRequested))
    Check '过期标记文件已被删除' (-not (Test-Path -LiteralPath $marker))

    [System.IO.File]::WriteAllText($marker, 'not-a-number')
    Check '无有效时间戳 -> 自动失效' (-not (Test-QuitRequested))
    Check '不可读标记文件已被删除' (-not (Test-Path -LiteralPath $marker))

    $Root = $savedRoot
    Remove-Item -Recurse -Force $probeDir -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=== 启动前清标记，且必须在停止之后（顺序即正确性）==='
$startText = [System.IO.File]::ReadAllText((Join-Path $Root 'tools\Watch-Pet.ps1'))
$startFn = [regex]::Match($startText, "(?ms)^function Start-PetNow\s*\{.*?^\}")
Check '能从 Watch-Pet.ps1 提取 Start-PetNow' $startFn.Success
if ($startFn.Success) {
    $body = $startFn.Value
    $stopAt = $body.IndexOf('Stop-Pet.ps1')
    $clearAt = $body.IndexOf("state\pet-quit")
    Check '仍在启动前停止残留实例' ($stopAt -gt 0)
    Check '会清除 pet-quit 标记' ($clearAt -gt 0)
    Check '清除发生在停止之后（否则会被重新写出）' ($clearAt -gt $stopAt)
}

Write-Host ''
Write-Host '=== 没有退出标记时仍应正常启动（确认上面的行为来自标记本身）==='
$script:Harness = $true; $script:Pet = $false; Reset-Throttle
$script:QuitRequested = $false
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'started'（实际 '$action'）" ($action -eq 'started')

Write-Host ''
Write-Host '=== Harness 关闭后应清除退出标记，使下次启动能重新出现 ==='
$script:Harness = $false; $script:Pet = $false; Reset-Throttle
$script:QuitRequested = $true
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "清除了退出标记（实际清除 $script:ClearedCount 次）" ($script:ClearedCount -ge 1)

Write-Host ''
Write-Host '=== 桌宠已在运行时，退出标记不应产生任何影响 ==='
# 标记只在"需要决定要不要启动"时才有意义；桌宠已经在屏幕上时看门狗本来就不动作。
$script:Harness = $true; $script:Pet = $true; Reset-Throttle
$script:QuitRequested = $true
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "返回 'none'（实际 '$action'）" ($action -eq 'none')

Write-Host ''
Write-Host '=== 启动进行中不得再启动第二个（这是出现两只桌宠的根因）==='
# 真实事故：冷启动超过了旧的 8 秒验证窗口 => 判定失败 => 4 秒后循环重试 => 启动第二个 shell
# => 第一个的窗口随后才出现 => 桌面上两只鲸鱼。
# 日志原样呈现了这个序列：
#   started the processes but no pet window appeared within 8000ms
#   started the processes but no pet window appeared within 8000ms
#   started the pet (Harness is running, window up after 821ms)
# 现在有两道防线：验证窗口放宽到 30 秒，以及"启动闩锁"——启动进行中时循环只等待、不重试。
$script:Harness = $true; $script:Pet = $false; Reset-Throttle
$script:LaunchPending = $true
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "启动进行中 -> 返回 'launching'（实际 '$action'）" ($action -eq 'launching')
Check "没有启动第二个桌宠（实际启动 $script:Started 次）" ($script:Started -eq 0)

Write-Host ''
Write-Host '=== 闩锁过期后必须允许重试（否则一次失败就永久不再尝试）==='
$script:Harness = $true; $script:Pet = $false; Reset-Throttle
$script:LaunchPending = $false
$absent = $null
$action = Invoke-WatchStep -AbsentSince ([ref]$absent)
Check "闩锁已释放 -> 正常启动（实际 '$action'）" ($action -eq 'started')

Write-Host ''
Write-Host '=== 启动闩锁自身的过期与自愈 ==='
$latchText = [System.IO.File]::ReadAllText((Join-Path $Root 'tools\Watch-Pet.ps1'))
$latchFn = [regex]::Match($latchText, "(?ms)^function Test-LaunchPending\s*\{.*?^\}")
Check '能从 Watch-Pet.ps1 提取 Test-LaunchPending' $latchFn.Success
if ($latchFn.Success) {
    $latchDir = Join-Path $Root 'build\latch-probe'
    Remove-Item -Recurse -Force $latchDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $latchDir 'state') | Out-Null

    $script:LaunchLatchMs = 1000
    $script:Log = New-Object System.Collections.Generic.List[string]
    function Write-WatchLog { param([string]$Message) }
    $savedRoot = $Root
    $Root = $latchDir
    Invoke-Expression $latchFn.Value
    $latch = Join-Path $latchDir 'state\pet-launching'

    Check '无闩锁文件 -> 不阻塞启动' (-not (Test-LaunchPending))

    [System.IO.File]::WriteAllText($latch, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()).ToString())
    Check '新鲜闩锁 -> 阻塞第二次启动' (Test-LaunchPending)

    [System.IO.File]::WriteAllText($latch, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - 60000).ToString())
    Check '过期闩锁 -> 允许重试' (-not (Test-LaunchPending))
    Check '过期闩锁文件已被删除' (-not (Test-Path -LiteralPath $latch))

    [System.IO.File]::WriteAllText($latch, 'garbage')
    Check '不可读闩锁 -> 允许重试（不永久阻塞）' (-not (Test-LaunchPending))

    $Root = $savedRoot
    Remove-Item -Recurse -Force $latchDir -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=== 验证窗口必须足够覆盖冷启动（旧值 8 秒会误判失败并重复启动）==='
$verifyFn = [regex]::Match($latchText, "(?ms)^function Start-PetNow\s*\{.*?^\}")
if ($verifyFn.Success) {
    $dm = [regex]::Match($verifyFn.Value, '\$deadline\s*=\s*(\d+)')
    Check 'Start-PetNow 中能找到验证窗口' $dm.Success
    if ($dm.Success) {
        $secs = [int]$dm.Groups[1].Value
        Check "验证窗口 >= 20 秒（实际 ${secs}s）—— 低于此值会因冷启动而重复启动" ($secs -ge 20000)
    }
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 看门狗决策正确，不会重复启动桌宠，退出与陈旧标记均能正确自愈。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
