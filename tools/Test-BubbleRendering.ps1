# Test-BubbleRendering.ps1 - 渲染验证：折叠时只显示一个框，展开时每个任务一个框。
#
# 需求是"默认只显示一个对话框，其他对话展开后可见"。这个行为完全由 shell 的渲染决定，
# 所以必须验证渲染结果本身，而不是只看 reducer 的输出。
#
# 本脚本从 shell 源码原样提取渲染函数（Build-BubbleContent 及其依赖），构造一个含多个
# 并行任务的视图，分别在"折叠"和"展开"两种状态下渲染，然后遍历生成的可视化树统计
# 各任务名出现的次数 —— 出现一次就代表该任务有一个独立的对话框。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$shellPath = Join-Path $Root 'src\shell\WhalePet.ps1'
$text = [System.IO.File]::ReadAllText($shellPath)

function Get-FunctionSource([string]$name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($name))\s*\{.*?^\}"
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { throw "无法提取 $name" }
    return $m.Value
}

# 渲染所需的脚本级变量（shell 在启动时设置它们）
$script:BrandBlue = '#4D6BFE'
$script:PanelExpanded = $false

# 渲染函数依赖的辅助函数，逐一从 shell 原样提取
foreach ($fn in @('Get-Field', 'New-TextBlock', 'New-Card', 'New-Dot', 'Get-StatusColor', 'Build-BubbleContent')) {
    Invoke-Expression (Get-FunctionSource $fn)
}

function New-BubbleView {
    # 三个并行任务：一个运行中、一个刚完成、一个出错。
    $bubbles = @(
        [pscustomobject]@{
            sessionId = 'run'; name = 'TASK-RUN'; label = '工作中 · pwsh'; status = 'working'
            progress = $null; progressText = '已完成 2/10'; elapsedText = '03:12'; ageText = '刚刚'
            completionAt = 0; others = 2; badge = '+2'; longTask = $false
            lastToolName = 'pwsh'; summary = $false
        },
        [pscustomobject]@{
            sessionId = 'done'; name = 'TASK-DONE'; label = '✅ 任务完成'; status = 'done'
            progress = $null; progressText = $null; elapsedText = $null; ageText = '2 分钟前'
            completionAt = 1700000000000; others = 2; badge = '+2'; longTask = $false
            lastToolName = $null; summary = $false
        },
        [pscustomobject]@{
            sessionId = 'err'; name = 'TASK-ERR'; label = '出错了 · EPERM'; status = 'error'
            progress = $null; progressText = $null; elapsedText = $null; ageText = '5 分钟前'
            completionAt = 1700000001000; others = 2; badge = '+2'; longTask = $false
            lastToolName = $null; summary = $false
        }
    )
    return [pscustomobject]@{
        bubble = $bubbles[0]
        bubbles = $bubbles
        hover = $null
        notifications = @()
        entries = @()
    }
}

function Count-TextInTree($element, [string]$needle) {
    $count = 0
    if ($null -eq $element) { return 0 }
    if ($element -is [System.Windows.Controls.TextBlock]) {
        if ([string]$element.Text -like "*$needle*") { $count++ }
    }
    $children = 0
    try { $children = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($element) } catch { $children = 0 }
    for ($i = 0; $i -lt $children; $i++) {
        $count += Count-TextInTree ([System.Windows.Media.VisualTreeHelper]::GetChild($element, $i)) $needle
    }
    return $count
}

# 渲染需要一个窗口承载，否则某些元素不会构建完整
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'

$failures = 0
$names = @('TASK-RUN', 'TASK-DONE', 'TASK-ERR')

foreach ($expanded in @($false, $true)) {
    $script:PanelExpanded = $expanded
    $view = New-BubbleView
    $content = Build-BubbleContent -View $view -Width 240
    $label = if ($expanded) { '展开' } else { '折叠' }

    Write-Host "=== $label 状态 ==="
    $total = 0
    foreach ($name in $names) {
        $n = Count-TextInTree $content $name
        $total += $n
        Write-Host ("  {0,-12} 出现 {1} 次" -f $name, $n)
    }
    Write-Host ("  对话框总数: {0}" -f $total)
    Write-Host ''

    if ($expanded) {
        # 展开：每个任务都要有自己的框
        foreach ($name in $names) {
            if ((Count-TextInTree $content $name) -ne 1) {
                Write-Host "  FAIL: 展开后 $name 应有且仅有一个对话框"
                $failures++
            }
        }
    } else {
        # 折叠：只显示排名第一的那个
        if ((Count-TextInTree $content 'TASK-RUN') -ne 1) {
            Write-Host '  FAIL: 折叠时应显示排名第一的对话框'
            $failures++
        }
        if ((Count-TextInTree $content 'TASK-DONE') -ne 0 -or (Count-TextInTree $content 'TASK-ERR') -ne 0) {
            Write-Host '  FAIL: 折叠时不应显示其他任务的对话框'
            $failures++
        }
    }
    Write-Host ''
}

$app.Shutdown()

if ($failures -eq 0) {
    Write-Host 'PASS: 折叠时只显示一个对话框，展开时每个并行任务各有一个。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
