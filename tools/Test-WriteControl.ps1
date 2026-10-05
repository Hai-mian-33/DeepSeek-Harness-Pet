# Test-WriteControl.ps1 - 直接执行真实的 Write-Control，确认它到底写出了什么。
#
# 症状：pet-control.json 的时间戳停在 18:47，而 shell-config.json 在 20:59 仍在更新。
# 说明 shell 活着、但在写控制文件这一步失败或没被调用。由于 Write-Control 内部有
# try/catch 且只写 Write-Verbose（默认不显示），失败是完全静默的 —— 这正是它长期
# 未被发现的原因。
#
# 本脚本从 shell 源码原样提取 Write-Control 及其依赖，注入最小状态后真实调用一次，
# 然后检查文件内容与形状。

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

# 注入 Write-Control 依赖的脚本级状态（与 shell 启动时一致）
$script:Hovered = $false
$script:Dragging = $false
$script:ActiveSessionId = 'session-probe-1'
$script:Paused = $false
$script:EvDown = 1; $script:EvMove = 2; $script:EvUp = 3; $script:EvEnter = 4
$script:PopupPressed = $false
$script:Acknowledged = New-Object System.Collections.Generic.List[object]
$script:Acknowledged.Add([pscustomobject]@{ sessionId = 'session-probe-1'; at = 1791028133567 })
$script:Acknowledged.Add([pscustomobject]@{ sessionId = 'session-probe-2'; at = 1791028080591 })

# 同时定义 shell 里可能存在的 Paused 兜底
if (-not (Get-Variable -Name 'Paused' -Scope Script -ErrorAction SilentlyContinue)) {
    $script:Paused = $false
}

$outFile = Join-Path $Root 'build\probe-control.json'
$script:ControlFile = $outFile
Remove-Item $outFile -Force -ErrorAction SilentlyContinue

Write-Host '=== 提取并调用真实的 Write-Control ==='
$src = Get-FunctionSource 'Write-Control'
Write-Host ("  函数体行数: {0}" -f ($src -split "`n").Count)
Invoke-Expression $src

Write-Host ''
Write-Host '=== 关键：Paused 变量在 shell 里是否真的存在？ ==='
$pausedRefs = [regex]::Matches($text, '\$script:Paused')
Write-Host ("  \$script:Paused 出现次数: {0}" -f $pausedRefs.Count)
$pausedInit = [regex]::Match($text, '(?m)^\$script:Paused\s*=')
Write-Host ("  是否有顶层初始化: {0}" -f $(if ($pausedInit.Success) { '是' } else { '否 —— StrictMode 下读取会抛异常' }))

Write-Host ''
Write-Host '=== 调用 Write-Control（捕获异常）==='
try {
    Write-Control
    Write-Host '  调用成功，无异常'
} catch {
    Write-Host "  抛出异常: $($_.Exception.GetType().Name)"
    Write-Host "  消息: $($_.Exception.Message)"
    Write-Host "  位置: $($_.InvocationInfo.PositionMessage)"
}

Write-Host ''
Write-Host '=== 产物检查 ==='
if (Test-Path $outFile) {
    $raw = [System.IO.File]::ReadAllText($outFile)
    Write-Host "  文件已生成，$($raw.Length) 字符"

    # 形状断言：acknowledged 必须是对象数组，而不是裸字符串 ——
    # 桥接的 readAcknowledgements 只接受对象或裸字符串，形状错了点击就会被丢弃。
    $parsed = $raw | ConvertFrom-Json
    $acks = @($parsed.acknowledged)
    Write-Host ("  acknowledged 条目数: {0}" -f $acks.Count)
    if ($acks.Count -ne 2) {
        Write-Host "  FAIL: 期望 2 条确认记录，实际 $($acks.Count)"
        exit 1
    }
    $first = $acks[0]
    $isObject = $null -ne $first.sessionId
    Write-Host ("  首个条目的形状: {0}" -f $(if ($isObject) { '对象 {sessionId, at}  ← 正确' } else { "裸值 '$first'  ← 桥接会丢弃！" }))
    if (-not $isObject) {
        Write-Host '  FAIL: 确认记录格式错误，桥接的 readAcknowledgements 会丢弃它'
        exit 1
    }
    Write-Host ("  首个条目: sessionId='{0}' at={1}" -f $first.sessionId, $first.at)
    if ($first.at -ne 1791028133567) {
        Write-Host '  FAIL: 时间戳没有正确序列化（顺序或类型错误）'
        exit 1
    }
    # 其余字段也要在，否则桥接读到的是默认值。
    foreach ($field in @('hovered', 'dragging', 'activeSessionId', 'paused', 'tick')) {
        if ($null -eq $parsed.PSObject.Properties[$field]) {
            Write-Host "  FAIL: 缺少字段 $field"
            exit 1
        }
    }
    Write-Host '  其余字段齐全 (hovered/dragging/activeSessionId/paused/tick)'
} else {
    Write-Host '  FAIL: 文件未生成 —— Write-Control 静默失败了'
    exit 1
}

Write-Host ''
Write-Host 'PASS: Write-Control 能生成形状正确的控制文件。'
exit 0
