# Test-PanelToggle.ps1 - 验证【展开/收起】按钮真的能被点击到。
#
# 根因：弹窗不投递 WPF 鼠标事件（与拖拽同样的原因），点击是靠 OS 级轮询 + 命中测试
# 解析的。而命中测试原来只返回带 Tag 的**会话卡片**，按钮没有 Tag，于是返回空字符串，
# 点击被当作"没有会话"丢弃 —— 所以【收起】看起来毫无反应。
#
# 本脚本验证修复：
#   1. 从 shell 源码原样提取 Get-PopupHitAtCursor 与 Invoke-PopupHit；
#   2. 用真实的 Build-BubbleContent 构建展开状态的面板；
#   3. 对按钮的实际屏幕位置做命中测试，断言得到 action:toggle-panel；
#   4. 再看 Toggle-Panel 是否真的把状态翻转。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$text = [System.IO.File]::ReadAllText((Join-Path $Root 'src\shell\WhalePet.ps1'))

function Get-FunctionSource([string]$name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($name))\s*\{.*?^\}"
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { throw "无法提取 $name" }
    return $m.Value
}

$script:BrandBlue = '#4D6BFE'
$script:PanelExpanded = $true

foreach ($fn in @('Get-Field', 'New-TextBlock', 'New-Card', 'New-Dot', 'Get-StatusColor',
                  'Build-BubbleContent', 'Get-PopupHitAtCursor', 'Get-VisualScale')) {
    Invoke-Expression (Get-FunctionSource $fn)
}

# Toggle-Panel 依赖一些状态与副作用，用最小替身：只记录被调用的次数
$script:ToggleCalls = 0
function Toggle-Panel { $script:ToggleCalls++; $script:PanelExpanded = -not $script:PanelExpanded }
function Open-Harness { }
function Invoke-PopupClick { param([string]$SessionId) $script:ClickedSession = $SessionId }
function Write-Diag { param([string]$Message) Write-Host "    [diag] $Message" }
Invoke-Expression (Get-FunctionSource 'Invoke-PopupHit')

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'

# 一个承载内容的窗口：命中测试需要真实的屏幕坐标
$window = New-Object System.Windows.Window
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = New-Object System.Windows.Media.SolidColorBrush(
    [System.Windows.Media.Color]::FromArgb(1, 0, 0, 0))
$window.ShowInTaskbar = $false
$window.Width = 240
$window.Height = 400
$window.Left = 200
$window.Top = 200
$window.SizeToContent = 'Height'

$host_ = New-Object System.Windows.Controls.StackPanel
$host_.Margin = New-Object System.Windows.Thickness(8)
$host_.Background = [System.Windows.Media.Brushes]::Transparent
$window.Content = $host_

# 三个并行任务的视图，确保展开后有内容也有按钮
$bubbles = @(
    [pscustomobject]@{ sessionId='run'; name='TASK-RUN'; label='工作中 · pwsh'; status='working'
        progress=$null; progressText='2/10'; elapsedText='03:12'; ageText='刚刚'; completionAt=0
        others=2; othersRunning=1; othersFinished=1; badge='+2'; longTask=$false; lastToolName='pwsh'; summary=$false },
    [pscustomobject]@{ sessionId='done'; name='TASK-DONE'; label='✅ 任务完成'; status='done'
        progress=$null; progressText=$null; elapsedText=$null; ageText='2 分钟前'; completionAt=1700000000000
        others=2; othersRunning=1; othersFinished=1; badge='+2'; longTask=$false; lastToolName=$null; summary=$false }
)
$view = [pscustomobject]@{ bubble=$bubbles[0]; bubbles=$bubbles; hover=$null; notifications=@(); entries=@() }

$content = Build-BubbleContent -View $view -Width 240
$host_.Children.Add($content) | Out-Null
$script:PopupHost = $host_
$script:PopupWindow = $window
$window.Show()
$window.UpdateLayout()
Start-Sleep -Milliseconds 500

# 找到那个带 action 标签的按钮，取其真实屏幕矩形
$toggle = $null
$stack = New-Object System.Collections.Generic.Stack[object]
$stack.Push($host_)
while ($stack.Count -gt 0) {
    $el = $stack.Pop()
    if ([string](Get-Field $el 'Tag' '') -eq 'action:toggle-panel') { $toggle = $el; break }
    $cnt = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
    for ($i = 0; $i -lt $cnt; $i++) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)) }
}

if ($null -eq $toggle) { Write-Host 'FAIL: 面板里找不到带 action:toggle-panel 标签的控件'; $window.Close(); $app.Shutdown(); exit 1 }
Write-Host "找到切换控件: '$($toggle.Content)'  尺寸 $([int]$toggle.ActualWidth)x$([int]$toggle.ActualHeight)"
Write-Host ''

# 在按钮中心做命中测试。中点先算好再传入：在构造函数参数里直接写 `$x / 2` 会被
# PowerShell 解析成"对数组做除法"而报 op_Division 错误。
$scale = Get-VisualScale -Window $window
$midX = [double]$toggle.ActualWidth / 2
$midY = [double]$toggle.ActualHeight / 2
$centreInHost = $toggle.TranslatePoint((New-Object System.Windows.Point($midX, $midY)), $host_)
$winOrigin = $window.PointToScreen((New-Object System.Windows.Point(0, 0)))
$cursor = [pscustomobject]@{
    X = [int]($winOrigin.X + $centreInHost.X * $scale)
    Y = [int]($winOrigin.Y + $centreInHost.Y * $scale)
}
Write-Host "按钮中心的屏幕坐标: ($($cursor.X),$($cursor.Y))"

$hit = Get-PopupHitAtCursor -Cursor $cursor
Write-Host "命中测试结果: '$hit'"

$failures = 0
if ($hit -ne 'action:toggle-panel') {
    Write-Host "  FAIL: 期望 'action:toggle-panel'，实际 '$hit'"
    $failures++
} else {
    Write-Host '  OK: 切换控件可被命中测试识别'
}
Write-Host ''

# 派发该标签，确认 Toggle-Panel 真的执行
Write-Host '派发该标签：'
$before = $script:PanelExpanded
Invoke-PopupHit -Tag $hit
Write-Host "  PanelExpanded: $before -> $($script:PanelExpanded)"
if ($script:ToggleCalls -ne 1) {
    Write-Host "  FAIL: Toggle-Panel 应被调用 1 次，实际 $($script:ToggleCalls) 次"
    $failures++
} else {
    Write-Host '  OK: Toggle-Panel 被调用一次，面板状态已翻转'
}
Write-Host ''

# 顺带确认点击会话卡片仍然可用（不能因为改动而回归）
$cardHit = $null
foreach ($b in $bubbles) {
    $stack.Push($host_)
    while ($stack.Count -gt 0) {
        $el = $stack.Pop()
        if ([string](Get-Field $el 'Tag' '') -eq $b.sessionId) {
            $cardMidX = [double]$el.ActualWidth / 2; $cardMidY = [double]$el.ActualHeight / 2; $c = $el.TranslatePoint((New-Object System.Windows.Point($cardMidX, $cardMidY)), $host_)
            $cardCursor = [pscustomobject]@{ X = [int]($winOrigin.X + $c.X * $scale); Y = [int]($winOrigin.Y + $c.Y * $scale) }
            $cardHit = Get-PopupHitAtCursor -Cursor $cardCursor
            Write-Host "会话 '$($b.sessionId)' 卡片中心命中: '$cardHit'"
            if ($cardHit -eq $b.sessionId) { Write-Host '  OK: 卡片点击仍能解析到会话' }
            else { Write-Host "  FAIL: 期望 '$($b.sessionId)'，实际 '$cardHit'"; $failures++ }
            break
        }
        $cnt = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el)
        for ($i = 0; $i -lt $cnt; $i++) { $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)) }
    }
}

$window.Close()
$app.Shutdown()

Write-Host ''
if ($failures -eq 0) {
    Write-Host 'PASS: 【展开/收起】可被点击并生效，且会话卡片点击未回归。'
    exit 0
}
Write-Host "FAIL: $failures 项不符合预期。"
exit 1
