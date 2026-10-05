# Probe-IntegrityLevel.ps1 - 跨进程窗口操作失败，是不是完整性级别（UIPI）造成的？
#
# 现象：SetWindowPos / SetForegroundWindow / AttachThreadInput 对 Harness 窗口全部失败，
# 甚至返回 False 且不做任何事。这符合 Windows 的 UIPI 规则：**低完整性级别的进程
# 不能操作更高完整性级别的窗口**（消息会被静默丢弃）。
#
# 如果桌宠进程的完整性级别低于 Harness，那么无论怎样改代码都无法唤起 Harness —— 这是
# 环境限制，不是代码缺陷。本脚本对比各进程的完整性级别来判定这一点。
#
# 读取方法：打开进程令牌，取 TokenIntegrityLevel 并映射到名称。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace IL -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, uint pid);
[DllImport("kernel32.dll", SetLastError=true)]
public static extern bool OpenProcessToken(System.IntPtr proc, uint access, out System.IntPtr token);
[DllImport("advapi32.dll", SetLastError=true)]
public static extern bool GetTokenInformation(System.IntPtr token, int cls, System.IntPtr info, uint len, out uint ret);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(System.IntPtr h);
[DllImport("kernel32.dll")] public static extern uint GetCurrentProcessId();
'@

$PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
$TOKEN_QUERY = 0x0008
$TokenIntegrityLevel = 25

function Get-IntegrityLevel([int]$processId) {
    $proc = [IL.Native]::OpenProcess($PROCESS_QUERY_LIMITED_INFORMATION, $false, [uint32]$processId)
    if ($proc -eq [IntPtr]::Zero) { return "打不开进程 (err=$([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message))" }
    $token = [IntPtr]::Zero
    try {
        if (-not [IL.Native]::OpenProcessToken($proc, $TOKEN_QUERY, [ref]$token)) {
            return "打不开令牌 (err=$([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message))"
        }
        $len = 0
        [IL.Native]::GetTokenInformation($token, $TokenIntegrityLevel, [IntPtr]::Zero, 0, [ref]$len) | Out-Null
        if ($len -eq 0) { return '无法确定' }
        $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([int]$len)
        try {
            if (-not [IL.Native]::GetTokenInformation($token, $TokenIntegrityLevel, $buf, [uint32]$len, [ref]$len)) {
                return '无法确定'
            }
            # TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES Label; } -> 取 Label.Sid，再取最后一个子授权值
            $sidPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf)
            $count = [System.Runtime.InteropServices.Marshal]::ReadByte($sidPtr, 1)
            $value = [System.Runtime.InteropServices.Marshal]::ReadInt32($sidPtr, 8 + (4 * ($count - 1)))
            # 完整性级别 RID 的常见取值
            switch ($value) {
                0x0000 { return 'Untrusted (0)' }
                0x1000 { return 'Low (4096)' }
                0x2000 { return 'Medium (8192)' }
                0x2100 { return 'Medium Plus (8448)' }
                0x3000 { return 'High (12288)' }
                0x4000 { return 'System (16384)' }
                default { return "0x{0:X} ({1})" -f $value, $value }
            }
        } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
    } finally {
        if ($token -ne [IntPtr]::Zero) { [IL.Native]::CloseHandle($token) | Out-Null }
        [IL.Native]::CloseHandle($proc) | Out-Null
    }
}

Write-Host '=== 各进程的完整性级别 ==='
Write-Host ("  本脚本 (pid {0}): {1}" -f [IL.Native]::GetCurrentProcessId(), (Get-IntegrityLevel ([IL.Native]::GetCurrentProcessId())))

$targets = @(
    @{ Name = 'DeepSeek Harness (桌面版)'; Filter = { $_.ProcessName -like '*DeepSeek*' } },
    @{ Name = '桌宠 shell (powershell)';   Filter = { $_.ProcessName -eq 'powershell' } },
    @{ Name = 'explorer';                  Filter = { $_.ProcessName -eq 'explorer' } }
)

foreach ($t in $targets) {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object $t.Filter | Select-Object -First 3)
    if ($procs.Count -eq 0) { Write-Host ("  {0,-30} (未运行)" -f $t.Name); continue }
    foreach ($p in $procs) {
        Write-Host ("  {0,-30} pid {1,-7} {2}" -f $t.Name, $p.Id, (Get-IntegrityLevel $p.Id))
    }
}

Write-Host ''
Write-Host '=== 判定 ==='
$mine = Get-IntegrityLevel ([IL.Native]::GetCurrentProcessId())
Write-Host "  若 Harness 的级别高于桌宠，则 UIPI 会拦截所有跨进程窗口操作，"
Write-Host "  表现为调用返回 False 且窗口毫无变化 —— 与观测到的现象一致。"
