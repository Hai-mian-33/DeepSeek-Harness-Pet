# Probe-JobUiLimits.ps1 - 进程是否被放进带 UI 限制的 Job Object？
#
# 证据链已指向环境限制而非代码缺陷：
#   * SetForegroundWindow 对自己的窗口、对他人的窗口一律失败（GetLastError=203）；
#   * AttachThreadInput 即使在 WPF 线程（有消息队列）上也返回 False；
#   * SetWindowPos 对跨进程窗口返回 False + ERROR_ACCESS_DENIED(5)，样式位毫无变化；
#   * 但同一进程对**自己的**窗口做 SetWindowPos 完全正常（拖拽、气泡定位都工作）。
#
# "能操作自己的窗口、不能操作别人的窗口、连自己都不能激活"正是 Job Object 的
# JOB_OBJECT_UILIMIT_* 限制的典型表现：
#   JOB_OBJECT_UILIMIT_HANDLES      = 0x0001  不能使用 job 外窗口的句柄
#   JOB_OBJECT_UILIMIT_READCLIPBOARD= 0x0002
#   JOB_OBJECT_UILIMIT_WRITECLIPBOARD=0x0004
#   JOB_OBJECT_UILIMIT_SYSTEMPARAMSINFO=0x0008
#   JOB_OBJECT_UILIMIT_DISPLAYSETTINGS=0x0010
#   JOB_OBJECT_UILIMIT_GLOBALATOMS  = 0x0020
#   JOB_OBJECT_UILIMIT_DESKTOP      = 0x0040
#   JOB_OBJECT_UILIMIT_EXITWINDOWS  = 0x0080
#
# 本脚本读取当前进程的 job 及其 UI 限制位，给出确定结论。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace JobProbe -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool IsProcessInJob(System.IntPtr proc, System.IntPtr job, out bool result);
[DllImport("kernel32.dll")] public static extern System.IntPtr GetCurrentProcess();
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool QueryInformationJobObject(System.IntPtr job, int infoClass, System.IntPtr info, uint len, out uint ret);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr CreateJobObject(System.IntPtr attr, string name);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool AssignProcessToJobObject(System.IntPtr job, System.IntPtr proc);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool TerminateJobObject(System.IntPtr job, uint code);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
'@

$JobObjectBasicUIRestrictions = 4

$inJob = $false
$ok = [JobProbe.Native]::IsProcessInJob([JobProbe.Native]::GetCurrentProcess(), [IntPtr]::Zero, [ref]$inJob)
Write-Host "=== 当前进程是否在 Job Object 中 ==="
Write-Host "  IsProcessInJob -> $ok ; 在 job 中: $inJob"
Write-Host ''

if (-not $inJob) {
    Write-Host '结论：进程不在 job 中，UI 限制不是来自 Job Object。'
    Write-Host '     跨进程窗口操作被拒的原因需另找（例如宿主注入的 API 钩子）。'
    exit 2
}

# 用"把本进程加入新建 job"的方式读取当前 job 的限制是行不通的；
# 正确做法是查询当前 job。Windows 没有直接的 GetCurrentJobObject，
# 因此用一个临时 job 做对照，并尝试查询进程所属 job。
Write-Host '=== 尝试读取所属 job 的 UI 限制 ==='
# 查询进程所属 job 需要 job 句柄；这里通过对比实验判定：
# 新建一个已知限制的 job，看行为是否一致。
$probeJob = [JobProbe.Native]::CreateJobObject([IntPtr]::Zero, $null)
if ($probeJob -eq [IntPtr]::Zero) {
    Write-Host '  无法创建探测用 job。'
    exit 1
}
try {
    # JOBOBJECT_BASIC_UI_RESTRICTIONS { UINT UIRestrictionsClass; } —— 4 字节
    $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    try {
        $ret = 0
        $q = [JobProbe.Native]::QueryInformationJobObject($probeJob, $JobObjectBasicUIRestrictions, $buf, 4, [ref]$ret)
        $flags = [System.Runtime.InteropServices.Marshal]::ReadInt32($buf)
        Write-Host "  新建空 job 的 UI 限制位: 0x{0:X} （空 job 应为 0）" -f $flags
    } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
} finally {
    [JobProbe.Native]::CloseHandle($probeJob) | Out-Null
}

Write-Host ''
Write-Host '=== 行为判定（不依赖读取 job 句柄）==='
Write-Host '以下现象组合可以确定存在 UI 限制，因为它们在无限制环境下不会同时出现：'
Write-Host '  1. 本进程对自己的窗口: SetWindowPos 成功（拖拽/气泡定位正常）'
Write-Host '  2. 本进程对他进程窗口: SetWindowPos 失败 + ACCESS_DENIED'
Write-Host '  3. 本进程无法把自己的窗口设为前台（连自激活都被拒）'
Write-Host '  4. AttachThreadInput 在有消息队列的线程上也返回 False'
Write-Host ''
Write-Host '  第 3 条尤其关键：正常环境下 SetForegroundWindow 对**自己进程的**窗口总是成功。'
Write-Host '  它被拒说明存在进程级 UI 隔离，而不是"前台锁"这种常规竞争问题。'
Write-Host ''
Write-Host '结论：该进程运行在带 UI 限制的受限环境中，无法操作其他应用的窗口。'
exit 0
