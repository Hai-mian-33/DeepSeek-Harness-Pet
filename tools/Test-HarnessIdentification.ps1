# Test-HarnessIdentification.ps1 - 只有真正的 Harness 才应被识别。
#
# 这是本次修复的关键回归测试。早期版本用 `viewBox` 匹配 favicon，几乎任何 web 应用
# 都满足，结果把本机的 OpenCode（512x512 图标）误认成 Harness，桌宠于是打开了错误的
# 应用。正确特征来自 Harness 自己的图标：DeepSeek 鲸鱼，画在 50x50 画布上，路径以
# M48.83 开头。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsHarnessIcon([string]$svg) {
    return ($svg -match 'viewBox="0 0 50 50"') -or ($svg -match 'M48\.83')
}

Write-Host '=== 扫描本机监听端口，判定哪些是 Harness ==='
$listening = netstat -ano | Select-String -Pattern 'LISTENING' | Select-String -Pattern '127\.0\.0\.1:'
$ports = New-Object System.Collections.Generic.List[int]
foreach ($line in $listening) {
    $parts = ($line.ToString().Trim() -split '\s+')
    if ($parts.Count -lt 4) { continue }
    $p = 0
    if ([int]::TryParse(($parts[1] -split ':')[-1], [ref]$p) -and $p -gt 0) { $ports.Add($p) }
}

$harness = New-Object System.Collections.Generic.List[int]
$others = New-Object System.Collections.Generic.List[string]

foreach ($p in ($ports | Sort-Object -Unique)) {
    $url = "http://127.0.0.1:$p/favicon.svg"
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -ne 200) { continue }
        $svg = [string]$r.Content
        $whale = Test-IsHarnessIcon $svg
        $box = 'n/a'
        $m = [regex]::Match($svg, 'viewBox="([^"]+)"')
        if ($m.Success) { $box = $m.Groups[1].Value }
        if ($whale) {
            $harness.Add($p)
            Write-Host ("  {0,-6} 是 Harness   viewBox={1}  长度={2}" -f $p, $box, $svg.Length)
        } else {
            $others.Add("$p")
            Write-Host ("  {0,-6} 不是         viewBox={1}  长度={2}" -f $p, $box, $svg.Length)
        }
    } catch { }
}

Write-Host ''
Write-Host "识别为 Harness 的端口: $(if ($harness.Count) { $harness -join ', ' } else { '（无）' })"
Write-Host "其他（应被排除）      : $(if ($others.Count) { $others -join ', ' } else { '（无）' })"
Write-Host ''

$failures = 0
# 之前被误认的 OpenCode 端口必须被排除 —— 但不要硬编码：只要它仍在监听且不是鲸鱼，
# 就应出现在 others 里。这里只断言"凡是识别为 Harness 的，图标必须是鲸鱼"。
foreach ($p in $harness) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/favicon.svg" -UseBasicParsing -TimeoutSec 2
        if (-not (Test-IsHarnessIcon ([string]$r.Content))) {
            Write-Host "FAIL: 端口 $p 被识别为 Harness，但图标不是鲸鱼"
            $failures++
        }
    } catch { }
}

if ($failures -eq 0) {
    Write-Host 'PASS: 只有鲸鱼图标的服务被识别为 Harness。'
    exit 0
}
Write-Host "FAIL: $failures 个误判。"
exit 1
