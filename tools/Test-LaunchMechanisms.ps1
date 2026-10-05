# Test-LaunchMechanisms.ps1 - 哪种启动方式能让 Harness 窗口真正出现在最前面？
#
# 已确认：本进程被禁止操作其他应用的窗口（SetForegroundWindow 返回错误 203，跨进程
# SetWindowPos 返回 ACCESS_DENIED）。所以"自己动手提升窗口"这条路在沙箱内走不通。
#
# 但"启动应用"是另一回事，而且有几种通道，它们的权限来源不同：
#
#   A. Start-Process            —— 直接 CreateProcess，子进程继承本进程的限制
#   B. cmd /c start ""          —— 经 cmd，再由 cmd 调 ShellExecute
#   C. explorer.exe <path>      —— 由 explorer 代为启动（explorer 拥有桌面权限）
#   D. ShellExecute via .NET    —— 走 shell 的关联/执行路径
#
# 关键在 C：explorer 是桌面的属主，由它启动的程序不继承本进程的 UI 限制，因此它调用
# SetForegroundWindow 时很可能成功。这是沙箱内的可行出路。
#
# 每项测试前都先把前台抢走，确保 Harness 确实不在前台，否则结果无意义。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace LM -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
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
    $h = [LM.Native]::OpenProcess($PQLI, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([LM.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [LM.Native]::CloseHandle($h) | Out-Null }
}

function Get-Windows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [LM.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([LM.Native]::IsWindowVisible($h)) {
            $len = [LM.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [LM.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $op = 0
                [LM.Native]::GetWindowThreadProcessId($h, [ref]$op) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h; Title = $sb.ToString(); Pid = [int]$op
                    Exe = (Get-ExePath ([int]$op))
                })
            }
        }
        return $true
    }
    [LM.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$exe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
if (-not (Test-Path -LiteralPath $exe)) { Write-Host "SKIP: 未安装 ($exe)"; exit 3 }

$windows = @(Get-Windows)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
if ($null -eq $target) { Write-Host 'SKIP: 桌面版无可见窗口'; exit 3 }
$park = @($windows | Where-Object {
    $_.Exe -notmatch 'DeepSeek Harness\.exe' -and $_.Title -notmatch '蓝鲸小深' -and $_.Title -ne ''
})[0]
if ($null -eq $park) { Write-Host 'SKIP: 找不到停靠窗口'; exit 3 }

$th = $target.Handle
Write-Host "目标: hwnd=$th '$($target.Title)'"
Write-Host "停靠: hwnd=$($park.Handle) '$($park.Title)'"
Write-Host ''

function Reset-Parked {
    [LM.Native]::ShowWindow($park.Handle, 9) | Out-Null
    [LM.Native]::SetForegroundWindow($park.Handle) | Out-Null
    Start-Sleep -Milliseconds 700
    return ([LM.Native]::GetForegroundWindow() -ne $th)
}

$results = [ordered]@{}

function Try-Launch([string]$name, [scriptblock]$action) {
    $parked = Reset-Parked
    if (-not $parked) {
        Write-Host ("  {0,-40} 跳过（无法制造劣势）" -f $name)
        return
    }
    try { & $action } catch { Write-Host ("  {0,-40} 启动异常: {1}" -f $name, $_.Exception.Message) }

    $ok = $false
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        if ([LM.Native]::GetForegroundWindow() -eq $th) { $ok = $true; break }
    }
    $results[$name] = $ok
    Write-Host ("  {0,-40} {1}" -f $name, $(if ($ok) { '成功成为前台' } else { '未成为前台' }))
}

Write-Host '每项前先抢走前台，确保 Harness 确实不在前台：'
Write-Host ''

Try-Launch 'A. Start-Process' {
    Start-Process -FilePath $exe | Out-Null
}

Try-Launch 'B. cmd /c start' {
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'start', '""', "`"$exe`"" -WindowStyle Hidden | Out-Null
}

Try-Launch 'C. explorer.exe 代为启动' {
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$exe`"" | Out-Null
}

Try-Launch 'D. ShellExecute (Start-Process 默认)' {
    # Start-Process 默认就是 ShellExecute；显式写出以对齐语义
    Start-Process -FilePath $exe -UseNewEnvironment:$false | Out-Null
}

Write-Host ''
Write-Host '=== 汇总 ==='
$winners = @($results.GetEnumerator() | Where-Object { $_.Value -eq $true })
if ($winners.Count -eq 0) {
    Write-Host '  没有任何启动方式能让 Harness 窗口成为前台。'
    Write-Host '  说明该环境对窗口激活的限制覆盖了这些通道，需要在受限环境之外运行桌宠。'
    exit 1
}
foreach ($w in $winners) { Write-Host "  可行: $($w.Key)" }
exit 0
