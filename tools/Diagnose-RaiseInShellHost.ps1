# Diagnose-RaiseInShellHost.ps1 - 在与 shell 相同的宿主中执行真正的 Invoke-RaiseWindow。
#
# 之前的 Test-OpenHarness.ps1 用 Add-Type 自己声明了一份 PetNative.Win，所以它
# 验证的是"这份逻辑在理想条件下能否工作"，而不是"shell 进程里能否工作"。两者
# 的差别正是问题的所在：shell 用的是它自己那份 Add-Type，且运行在 WPF 的
# DispatcherTimer 回调里（UI 线程），而本脚本运行在普通 PS 宿主中。
#
# 本脚本从 shell 源码中原样提取 Add-Type 声明和 Invoke-RaiseWindow 函数体，因此
# 它执行的就是 shell 的那份代码。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$shellPath = Join-Path $Root 'src\shell\WhalePet.ps1'
$text = [System.IO.File]::ReadAllText($shellPath)

Write-Host '=== 1. 原样执行 shell 的 Add-Type 声明 ==='
$addTypeMatch = [regex]::Match($text, "(?ms)if \(-not \('PetNative' -as \[type\]\)\) \{\s*Add-Type -Namespace PetNative -Name Win -MemberDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $addTypeMatch.Success) { Write-Host 'FAIL: 无法提取 Add-Type 块'; exit 1 }
$memberDef = $addTypeMatch.Groups[1].Value
Write-Host "  提取到 $($memberDef.Length) 字符的成员定义"

if (-not ('PetNative.Win' -as [type])) {
    Add-Type -Namespace PetNative -Name Win -MemberDefinition $memberDef
}
Write-Host "  PetNative.Win 类型已就绪: $([PetNative.Win] -ne $null)"

Write-Host ''
Write-Host '=== 2. 原样执行 shell 的 Invoke-RaiseWindow / Test-IsForeground ==='
function Get-FunctionSource([string]$name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($name))\s*\{.*?^\}"
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { throw "无法提取 $name" }
    return $m.Value
}
Invoke-Expression (Get-FunctionSource 'Test-IsForeground')
Invoke-Expression (Get-FunctionSource 'Invoke-RaiseWindow')
Write-Host '  两个函数已加载'

Write-Host ''
Write-Host '=== 3. 找到 Harness 窗口 ==='
$found = New-Object System.Collections.Generic.List[object]
$cb = [PetNative.Win+EnumWindowsProc] {
    param([IntPtr]$h, [IntPtr]$p)
    if ([PetNative.Win]::IsWindowVisible($h)) {
        $len = [PetNative.Win]::GetWindowTextLength($h)
        if ($len -gt 0) {
            $sb = New-Object System.Text.StringBuilder ($len + 2)
            [PetNative.Win]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
            $found.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString() })
        }
    }
    return $true
}
[PetNative.Win]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
$targets = @($found | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })
Write-Host "  找到 $($targets.Count) 个候选窗口"
if ($targets.Count -eq 0) { Write-Host 'SKIP: 没有 Harness 窗口'; exit 3 }

$handle = $targets[0].Handle
Write-Host "  目标 hwnd=$handle"
Write-Host "  '$($targets[0].Title)'"

Write-Host ''
Write-Host '=== 4. 调用 shell 的 Invoke-RaiseWindow（无 try/catch，暴露真实异常）==='
$fgBefore = [PetNative.Win]::GetForegroundWindow()
Write-Host "  调用前前台 hwnd=$fgBefore"

try {
    $result = Invoke-RaiseWindow -Handle $handle
    Write-Host "  Invoke-RaiseWindow 返回: $result"
} catch {
    Write-Host "  抛出异常: $($_.Exception.GetType().FullName)"
    Write-Host "  消息: $($_.Exception.Message)"
    Write-Host "  位置: $($_.InvocationInfo.PositionMessage)"
    exit 1
}

Start-Sleep -Milliseconds 400
$fgAfter = [PetNative.Win]::GetForegroundWindow()
$isFg = ($fgAfter -eq $handle)
Write-Host "  调用后前台 hwnd=$fgAfter"
Write-Host "  目标窗口成为前台: $isFg"
Write-Host ''
if ($isFg) {
    Write-Host 'PASS: 在 shell 的宿主环境下也能成功提升窗口。'
    exit 0
}
Write-Host 'FAIL: 提升失败，需要在 shell 进程内进一步诊断。'
exit 1
