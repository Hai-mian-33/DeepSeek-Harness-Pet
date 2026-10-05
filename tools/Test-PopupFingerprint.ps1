# Test-PopupFingerprint.ps1 - 验证气泡只在内容真正变化时才重建。
#
# 卡顿与闪现的根因：Update-Popup 会 Clear() 并重建整棵可视化树，而主循环每 40ms 调用它
# 一次，拖拽时还额外每帧调用 —— 数据其实每秒才变一次。修复方式是用"指纹"判断内容是否
# 真的变了，只重定位而不重建。
#
# 本脚本从 shell 源码原样提取 Get-PopupFingerprint，并验证两类行为：
#   * 不相关的变化（例如 now 时间戳本身）**不应**改变指纹，否则重建照旧发生；
#   * 任何会改变渲染结果的变化都**必须**改变指纹，否则界面会停留在旧内容上。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$text = [System.IO.File]::ReadAllText((Join-Path $Root 'src\shell\WhalePet.ps1'))

function Get-FunctionSource([string]$name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($name))\s*\{.*?^\}"
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { throw "无法提取 $name" }
    return $m.Value
}

$script:PanelExpanded = $false
$script:SilentMode = $false
Invoke-Expression (Get-FunctionSource 'Get-Field')
Invoke-Expression (Get-FunctionSource 'Get-PopupFingerprint')

function New-View {
    param([hashtable]$Overrides = @{})
    $bubble = [pscustomobject]@{
        sessionId = 'run'; name = 'deepseek-pet'; label = '工作中 · pwsh'; status = 'working'
        progressText = '已完成 2/10'; elapsedText = '03:12'; ageText = '刚刚'
        others = 1; lastToolName = 'pwsh'; longTask = $false
    }
    foreach ($k in $Overrides.Keys) { $bubble.$k = $Overrides[$k] }
    return [pscustomobject]@{
        bubble = $bubble
        bubbles = @($bubble)
        notifications = @()
        entries = @()
        hover = $null
    }
}

$failures = 0
function Assert([bool]$condition, [string]$message) {
    if ($condition) { Write-Host "  OK   $message" }
    else { Write-Host "  FAIL $message"; $script:failures++ }
}

$base = New-View
$fp = Get-PopupFingerprint -View $base

Write-Host '=== 内容未变：指纹必须相同（否则仍会每帧重建）==='
$same = Get-PopupFingerprint -View (New-View)
Assert ($fp -eq $same) '相同内容产生相同指纹'

Write-Host ''
Write-Host '=== 仅时间戳变化：不应触发重建 ==='
# 这是关键：主循环每帧都带新的 now，如果它进入指纹，节流就完全失效。
$ticked = New-View
$ticked | Add-Member -NotePropertyName now -NotePropertyValue 1791000000123 -Force
$ticked | Add-Member -NotePropertyName mood -NotePropertyValue 'working' -Force
Assert ((Get-PopupFingerprint -View $ticked) -eq $fp) '新增 now/mood 字段不改变指纹（它们不参与气泡渲染）'

Write-Host ''
Write-Host '=== 渲染相关的每一项变化：必须产生新指纹 ==='
$cases = @(
    @{ Name = 'elapsedText（运行时长跳动）'; O = @{ elapsedText = '03:13' } },
    @{ Name = 'ageText（完成后时间跳动）';  O = @{ ageText = '1 分钟前' } },
    @{ Name = 'label（状态文字）';          O = @{ label = '✅ 任务完成' } },
    @{ Name = 'status（徽标颜色）';          O = @{ status = 'done' } },
    @{ Name = 'progressText（进度）';        O = @{ progressText = '已完成 3/10' } },
    @{ Name = 'lastToolName（工具名）';      O = @{ lastToolName = 'grep' } },
    @{ Name = 'others（+N 徽标）';           O = @{ others = 2 } },
    @{ Name = 'longTask（长任务标记）';      O = @{ longTask = $true } },
    @{ Name = 'sessionId（换了一个会话）';   O = @{ sessionId = 'other' } }
)
foreach ($case in $cases) {
    $changed = Get-PopupFingerprint -View (New-View -Overrides $case.O)
    Assert ($changed -ne $fp) $case.Name
}

Write-Host ''
Write-Host '=== 展开/收起必须触发重建（宽度与内容都变）==='
$script:PanelExpanded = $true
$expanded = Get-PopupFingerprint -View $base
Assert ($expanded -ne $fp) '展开状态改变指纹'
$script:PanelExpanded = $false

Write-Host ''
# 反向验证：如果指纹忽略某个渲染字段，上面必然失败；这里确认它确实覆盖了全部字段。
Write-Host '=== 覆盖度：气泡的每个渲染字段都应在指纹中 ==='
$keys = @('sessionId','label','status','progressText','elapsedText','ageText','others','lastToolName','longTask')
$missed = @()
foreach ($k in $keys) {
    $probe = New-View -Overrides @{ $k = 'ZZZ-PROBE' }
    if ((Get-PopupFingerprint -View $probe) -eq $fp) { $missed += $k }
}
Assert ($missed.Count -eq 0) "所有渲染字段都参与指纹$(if ($missed.Count -gt 0) { '（遗漏: ' + ($missed -join ', ') + '）' })"

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 指纹只在渲染内容真正变化时改变，节流生效。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
