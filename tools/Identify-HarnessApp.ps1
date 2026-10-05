# Identify-HarnessApp.ps1 - DeepSeek Harness 的界面到底是桌面版还是浏览器？
#
# 这决定了"点击桌宠应该打开什么"：
#   * 桌面版（Electron）-> 启动 DeepSeek Harness.exe，靠 single-instance 锁把已有窗口
#     提到前台；
#   * 浏览器            -> 只能打开 URL。
#
# 两者都使用 Chrome_WidgetWin_1 窗口类，所以类名无法区分。可靠的判据有两个：
#   1. 窗口标题的结尾：Electron 会附加自己的应用名（"— DeepSeek Harness"），浏览器
#      则附加浏览器名（如 "— Google Chrome"、"联想浏览器"）；
#   2. 窗口所属进程：与 DeepSeek Harness.exe 的进程比对。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace AppId -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
'@

function Get-AllWindowsDetailed {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [AppId.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([AppId.Native]::IsWindowVisible($h)) {
            $len = [AppId.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [AppId.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $cls = New-Object System.Text.StringBuilder 256
                [AppId.Native]::GetClassName($h, $cls, $cls.Capacity) | Out-Null
                $ownerPid = 0
                [AppId.Native]::GetWindowThreadProcessId($h, [ref]$ownerPid) | Out-Null
                $list.Add([pscustomobject]@{
                    Handle = $h
                    Title = $sb.ToString()
                    Class = $cls.ToString()
                    Pid = [int]$ownerPid
                    Iconic = [AppId.Native]::IsIconic($h)
                })
            }
        }
        return $true
    }
    [AppId.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

Write-Host '=== DeepSeek Harness 相关进程 ==='
$harnessProcs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
foreach ($p in $harnessProcs) {
    Write-Host ("  pid {0,-8} {1}  启动={2}" -f $p.Id, $p.ProcessName, $p.StartTime.ToString('HH:mm:ss'))
}
if ($harnessProcs.Count -eq 0) { Write-Host '  （没有 DeepSeek Harness.exe 进程）' }
Write-Host ''

$harnessPids = @($harnessProcs | Select-Object -ExpandProperty Id)

Write-Host '=== 标题含 Harness 的窗口 ==='
$targets = @(Get-AllWindowsDetailed | Where-Object { $_.Title -match 'Harness' })
foreach ($w in $targets) {
    $procName = '?'
    try {
        $p = Get-Process -Id $w.Pid -ErrorAction Stop
        $procName = $p.ProcessName
    } catch {
        $procName = "(无法读取: $($_.Exception.GetType().Name))"
    }
    $isDesktopPid = $harnessPids -contains $w.Pid

    Write-Host ("  hwnd={0,-10} pid={1,-8} class={2}" -f $w.Handle, $w.Pid, $w.Class)
    Write-Host ("    进程名   : {0}" -f $procName)
    Write-Host ("    属于桌面版进程: {0}" -f $isDesktopPid)
    Write-Host ("    最小化   : {0}" -f $w.Iconic)
    Write-Host ("    标题     : {0}" -f $w.Title)

    # 标题结尾判据
    $desktopSuffix = $w.Title -match '—\s*DeepSeek Harness\s*$'
    $browserSuffix = $w.Title -match '(Google Chrome|Microsoft.*Edge|浏览器|Firefox|Brave)\s*$'
    Write-Host ("    标题后缀像桌面版: {0}   像浏览器: {1}" -f $desktopSuffix, $browserSuffix)
    Write-Host ''
}

Write-Host '=== 结论 ==='
$desktop = @($targets | Where-Object { $harnessPids -contains $_.Pid -or $_.Title -match '—\s*DeepSeek Harness\s*$' })
if ($desktop.Count -gt 0) {
    Write-Host '界面是【桌面版】：应通过启动 DeepSeek Harness.exe 来唤起它。'
    exit 0
}
Write-Host '界面看起来【不是桌面版】：该窗口不属于 DeepSeek Harness.exe 进程。'
exit 2
