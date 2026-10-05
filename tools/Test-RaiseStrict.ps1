# Test-RaiseStrict.ps1 - 严格验证 shell 的提升逻辑：先夺走前台，再验证能否夺回。
#
# 之前所有"通过"的测试都犯同一个错误：目标窗口本来就是前台，于是检查立即为真，
# 被测代码从未真正执行。本脚本从 shell 源码原样提取 Invoke-RaiseWindow，并且：
#
#   1. 先把前台停靠到别的窗口，断言确认目标确实非前台；
#   2. 再调用 Invoke-RaiseWindow；
#   3. 用 GetForegroundWindow 验证真实结果。
#
# 前提不成立时报告 SKIP，绝不谎报 PASS。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$shellPath = Join-Path $Root 'src\shell\WhalePet.ps1'
$text = [System.IO.File]::ReadAllText($shellPath)

# --- 与 shell 完全相同的 Add-Type 声明 ---
$m = [regex]::Match($text, "(?ms)Add-Type -Namespace PetNative -Name Win -MemberDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $m.Success) { Write-Host 'FAIL: 无法提取 Add-Type 块'; exit 1 }
if (-not ('PetNative.Win' -as [type])) {
    Add-Type -Namespace PetNative -Name Win -MemberDefinition $m.Groups[1].Value
}

function Get-FunctionSource([string]$name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($name))\s*\{.*?^\}"
    $mm = [regex]::Match($text, $pattern)
    if (-not $mm.Success) { throw "无法提取 $name" }
    return $mm.Value
}

# Write-Diag 在 shell 里写文件；测试中用静默版本，避免污染 build 目录
function Write-Diag { param([string]$Message) }
Invoke-Expression (Get-FunctionSource 'Test-IsForeground')
Invoke-Expression (Get-FunctionSource 'Invoke-RaiseWindow')

Add-Type -Namespace StrictRaise -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, uint pid);
[DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool QueryFullProcessImageName(System.IntPtr h, uint flags, System.Text.StringBuilder name, ref uint size);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
'@

$PQLI = 0x1000
function Get-ExePath([int]$processId) {
    $h = [StrictRaise.Native]::OpenProcess($PQLI, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([StrictRaise.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [StrictRaise.Native]::CloseHandle($h) | Out-Null }
}

function Get-Windows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [StrictRaise.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([StrictRaise.Native]::IsWindowVisible($h)) {
            $len = [StrictRaise.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [StrictRaise.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $op = 0
                [StrictRaise.Native]::GetWindowThreadProcessId($h, [ref]$op) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h; Title = $sb.ToString(); Pid = [int]$op
                    Exe = (Get-ExePath ([int]$op))
                    Iconic = [StrictRaise.Native]::IsIconic($h)
                })
            }
        }
        return $true
    }
    [StrictRaise.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$windows = @(Get-Windows)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 桌面版无可见窗口'; exit 3 }
$park = @($windows | Where-Object {
    $_.Exe -notmatch 'DeepSeek Harness\.exe' -and $_.Title -notmatch '蓝鲸小深' -and $_.Title -ne ''
})[0]
if ($null -eq $park) { Write-Host 'SKIP: 找不到停靠窗口'; exit 3 }

$th = $target.Handle
Write-Host "目标: hwnd=$th  '$($target.Title)'"
Write-Host "停靠: hwnd=$($park.Handle)  '$($park.Title)'"
Write-Host ''

# 制造劣势
[StrictRaise.Native]::ShowWindow($park.Handle, 9) | Out-Null
[StrictRaise.Native]::SetForegroundWindow($park.Handle) | Out-Null
Start-Sleep -Milliseconds 700

$fgBefore = [StrictRaise.Native]::GetForegroundWindow()
if ($fgBefore -eq $th) {
    Write-Host 'SKIP: 无法把前台从目标窗口移开，前提不成立（继续测试会得到假阳性）。'
    exit 3
}
Write-Host "✔ 前提成立：目标不在前台（当前前台 hwnd=$fgBefore）"
Write-Host ''

Write-Host '调用 shell 的 Invoke-RaiseWindow...'
$result = Invoke-RaiseWindow -Handle $th
Start-Sleep -Milliseconds 300
$fgAfter = [StrictRaise.Native]::GetForegroundWindow()
$ok = ($fgAfter -eq $th)

Write-Host "  返回: $result"
Write-Host "  调用后前台 hwnd: $fgAfter"
Write-Host "  目标成为前台: $ok"
Write-Host ''
if ($ok) {
    Write-Host 'PASS: 在"目标原本非前台"的前提下，shell 的提升逻辑确实能把它带到前台。'
    exit 0
}
Write-Host 'FAIL: 目标仍未成为前台。'
exit 1
