# Diagnose-HarnessDesktop.ps1 - 到底哪个窗口才是 DeepSeek Harness 桌面版？
#
# 之前的判定用窗口标题里是否有 "Harness" 与 "— DeepSeek Harness" 后缀，这不可靠：
# DSH 的 Web 前端会把 document.title 设为 "<对话标题> — DeepSeek Harness"，因此一个
# 浏览器标签页同样满足该特征，于是把"浏览器窗口被激活"误判成"桌面版被唤起"。
#
# 唯一可靠的判据是窗口所属进程的可执行文件路径。本脚本用
# QueryFullProcessImageName 取得它（不依赖 Get-Process，因为部分 pid 无法用
# Get-Process 查询），从而区分：
#
#   * 桌面版   -> 路径为 ...\DeepSeek Harness.exe
#   * 浏览器   -> 路径为 chrome.exe / msedge.exe 等
#
# 同时列出 DeepSeek Harness.exe 进程持有的全部窗口（含不可见），以判断桌面版是否
# 只是没有可见窗口（例如被最小化到托盘）。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace DxD -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
[DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, uint pid);
[DllImport("kernel32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool QueryFullProcessImageName(System.IntPtr h, uint flags, System.Text.StringBuilder name, ref uint size);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
'@

$PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

function Get-ProcessPath([int]$processId) {
    $handle = [DxD.Native]::OpenProcess($PROCESS_QUERY_LIMITED_INFORMATION, $false, [uint32]$processId)
    if ($handle -eq [IntPtr]::Zero) { return "(打不开进程: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message))" }
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $size = [uint32]$sb.Capacity
        if ([DxD.Native]::QueryFullProcessImageName($handle, 0, $sb, [ref]$size)) {
            return $sb.ToString()
        }
        return "(查询路径失败)"
    } finally {
        [DxD.Native]::CloseHandle($handle) | Out-Null
    }
}

function Get-AllWindows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [DxD.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        $len = [DxD.Native]::GetWindowTextLength($h)
        $title = ''
        if ($len -gt 0) {
            $sb = New-Object System.Text.StringBuilder ($len + 2)
            [DxD.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
            $title = $sb.ToString()
        }
        $cls = New-Object System.Text.StringBuilder 256
        [DxD.Native]::GetClassName($h, $cls, $cls.Capacity) | Out-Null
        $ownerPid = 0
        [DxD.Native]::GetWindowThreadProcessId($h, [ref]$ownerPid) | Out-Null
        $list.Add([pscustomobject]@{
            Handle = $h
            Pid = [int]$ownerPid
            Class = $cls.ToString()
            Title = $title
            Visible = [DxD.Native]::IsWindowVisible($h)
            Iconic = [DxD.Native]::IsIconic($h)
        })
        return $true
    }
    [DxD.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

Write-Host '=== 1. DeepSeek Harness.exe 进程 ==='
$harnessProcs = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
foreach ($p in $harnessProcs) {
    Write-Host ("  pid {0,-8} 启动={1}" -f $p.Id, $p.StartTime.ToString('HH:mm:ss'))
    Write-Host ("    路径: {0}" -f (Get-ProcessPath $p.Id))
}
if ($harnessProcs.Count -eq 0) { Write-Host '  （没有 DeepSeek Harness.exe 进程）' }
Write-Host ''

$harnessPids = @($harnessProcs | Select-Object -ExpandProperty Id)

Write-Host '=== 2. 所有带标题的可见窗口，按"进程可执行文件路径"归类 ==='
$windows = @(Get-AllWindows)
$foreground = [DxD.Native]::GetForegroundWindow()
foreach ($w in ($windows | Where-Object { $_.Visible -and $_.Title -ne '' } | Sort-Object Pid)) {
    $path = Get-ProcessPath $w.Pid
    $leaf = Split-Path -Leaf $path -ErrorAction SilentlyContinue
    if (-not $leaf) { $leaf = $path }
    $isDesktop = $path -match 'DeepSeek Harness\.exe'
    $mark = if ($isDesktop) { '★ 桌面版' } else { '  其他' }
    $fg = if ($w.Handle -eq $foreground) { ' [前台]' } else { '' }
    Write-Host ("  {0} pid={1,-8} exe={2}{3}" -f $mark, $w.Pid, $leaf, $fg)
    Write-Host ("       标题: {0}" -f $w.Title)
}
Write-Host ''

Write-Host '=== 3. DeepSeek Harness.exe 进程持有的所有窗口（含不可见）==='
foreach ($w in ($windows | Where-Object { $harnessPids -contains $_.Pid })) {
    Write-Host ("  hwnd={0,-10} class={1,-28} visible={2,-6} iconic={3,-6} title='{4}'" -f `
        $w.Handle, $w.Class, $w.Visible, $w.Iconic, $w.Title)
}
if (-not ($windows | Where-Object { $harnessPids -contains $_.Pid })) {
    Write-Host '  （桌面版进程没有任何窗口 —— 可能被关闭到托盘，或窗口属于另一个进程）'
}
Write-Host ''

Write-Host '=== 4. 当前前台窗口的真实身份 ==='
$fgWin = $windows | Where-Object { $_.Handle -eq $foreground } | Select-Object -First 1
if ($null -ne $fgWin) {
    Write-Host ("  hwnd={0} pid={1}" -f $fgWin.Handle, $fgWin.Pid)
    Write-Host ("  exe : {0}" -f (Get-ProcessPath $fgWin.Pid))
    Write-Host ("  标题: {0}" -f $fgWin.Title)
} else {
    Write-Host "  前台 hwnd=$foreground 不在已枚举窗口中"
}
Write-Host ''

Write-Host '=== 结论 ==='
$desktopWindows = @($windows | Where-Object { $_.Visible -and $_.Title -ne '' -and (Get-ProcessPath $_.Pid) -match 'DeepSeek Harness\.exe' })
if ($desktopWindows.Count -gt 0) {
    Write-Host '存在可见的桌面版窗口，应直接提升它。'
    exit 0
}
Write-Host '桌面版没有可见窗口：点击应启动 DeepSeek Harness.exe 让它创建/显示窗口。'
exit 2
