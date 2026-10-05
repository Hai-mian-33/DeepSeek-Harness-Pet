# Test-SelfActivateHandoff.ps1 - 关键实验：先让本进程的窗口取得前台，再把前台交给目标窗口。
#
# 背景：后台进程调用 SetForegroundWindow 会被系统拒绝（前台锁）。但 Windows 允许
# "已经拥有前台的进程"把前台交给别的窗口。由此得到一个标准做法：
#
#   1. 先把本进程自己的窗口设为前台（这总是允许的）；
#   2. 立刻对目标窗口调用 SetForegroundWindow —— 此时本进程已拥有前台，调用合法。
#
# 本脚本必须在有消息队列的线程里运行（WPF 的 Dispatcher 线程满足），因为
# AttachThreadInput 等 API 要求调用线程有消息队列，而普通控制台 PowerShell 主线程没有
# —— 这正是之前所有控制台测试都失败、不能代表 shell 真实环境的原因。
#
# 实验同时报告 AttachThreadInput 的返回值，以验证"消息队列"这一解释。

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

Add-Type -Namespace Handoff -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
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
    $h = [Handoff.Native]::OpenProcess($PQLI, $false, [uint32]$processId)
    if ($h -eq [IntPtr]::Zero) { return '' }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([Handoff.Native]::QueryFullProcessImageName($h, 0, $sb, [ref]$size)) { return $sb.ToString() }
        return ''
    } finally { [Handoff.Native]::CloseHandle($h) | Out-Null }
}

function Get-Windows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [Handoff.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([Handoff.Native]::IsWindowVisible($h)) {
            $len = [Handoff.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [Handoff.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $op = 0
                [Handoff.Native]::GetWindowThreadProcessId($h, [ref]$op) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h; Title = $sb.ToString(); Pid = [int]$op
                    Exe = (Get-ExePath ([int]$op))
                })
            }
        }
        return $true
    }
    [Handoff.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$windows = @(Get-Windows)
$target = @($windows | Where-Object { $_.Exe -match 'DeepSeek Harness\.exe' -and $_.Title -ne '' })[0]
$park = @($windows | Where-Object {
    $_.Exe -notmatch 'DeepSeek Harness\.exe' -and $_.Title -notmatch '蓝鲸小深' -and $_.Title -ne ''
})[0]
if ($null -eq $target) { Write-Host 'SKIP: 桌面版无可见窗口'; exit 3 }
if ($null -eq $park) { Write-Host 'SKIP: 找不到停靠窗口'; exit 3 }

$th = $target.Handle
Write-Host "目标: '$($target.Title)'"
Write-Host ''

# 在 WPF Dispatcher 线程里执行：这里才有消息队列，与 shell 的运行环境一致。
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'

# 本进程的一个小窗口，用来"自己先取得前台"
$self = New-Object System.Windows.Window
$self.WindowStyle = 'None'
$self.AllowsTransparency = $true
$self.Background = New-Object System.Windows.Media.SolidColorBrush(
    [System.Windows.Media.Color]::FromArgb(1, 0, 0, 0))
$self.ShowInTaskbar = $false
$self.Topmost = $true
$self.Width = 40
$self.Height = 40
$self.Left = -2000
$self.Top = -2000
$self.Show()

$selfHandle = (New-Object System.Windows.Interop.WindowInteropHelper($self)).Handle
Write-Host "本进程窗口 hwnd=$selfHandle"

# 用 Dispatcher 排队执行，确保运行在 WPF 线程上
$script:result = $null
$self.Dispatcher.Invoke([action]{
    # 制造劣势
    [Handoff.Native]::ShowWindow($park.Handle, 9) | Out-Null
    [Handoff.Native]::SetForegroundWindow($park.Handle) | Out-Null
    Start-Sleep -Milliseconds 600
    $fgBefore = [Handoff.Native]::GetForegroundWindow()

    Write-Host "停靠后前台 hwnd=$fgBefore  （目标非前台: $($fgBefore -ne $th)）"

    # 检验消息队列解释：在 WPF 线程上 AttachThreadInput 是否成功？
    $pid2 = 0
    $fgt = [Handoff.Native]::GetWindowThreadProcessId($fgBefore, [ref]$pid2)
    $selfThread = [Handoff.Native]::GetCurrentThreadId()
    $att = [Handoff.Native]::AttachThreadInput($selfThread, $fgt, $true)
    if ($att) { [Handoff.Native]::AttachThreadInput($selfThread, $fgt, $false) | Out-Null }
    Write-Host "AttachThreadInput (WPF 线程, 有消息队列) -> $att"
    Write-Host "  自身线程=$selfThread  前台线程=$fgt"

    # 实验一：自己先取得前台，再交给目标
    [Handoff.Native]::SetForegroundWindow($selfHandle) | Out-Null
    Start-Sleep -Milliseconds 200
    $weAreFg = ([Handoff.Native]::GetForegroundWindow() -eq $selfHandle)
    Write-Host ""
    Write-Host "实验一：先自己取得前台 —— 成功: $weAreFg"
    if ($weAreFg) {
        [Handoff.Native]::SetForegroundWindow($th) | Out-Null
        Start-Sleep -Milliseconds 400
        $ok = ([Handoff.Native]::GetForegroundWindow() -eq $th)
        Write-Host "  随后把前台交给目标 —— 成功: $ok"
        $script:result = $ok
    } else {
        Write-Host "  无法让自身窗口成为前台，实验一无法进行"
        $script:result = $false
    }
})

$self.Close()
$app.Shutdown()

Write-Host ''
if ($script:result -eq $true) {
    Write-Host 'PASS: "先自取前台，再移交" 可行 —— 这就是 Open-Harness 应该采用的做法。'
    exit 0
}
Write-Host 'FAIL: 该做法在此环境下无效。'
exit 1
