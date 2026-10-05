# Probe-HarnessProcessName.ps1 - what process names does an UNRESTRICTED process see?
#
# This matters because the watchdog decides "is Harness running?" by process name, and it runs
# OUTSIDE any sandbox (Windows starts it at logon). Inside a restricted host only a subset of
# processes is visible, so a check performed there cannot answer the question.
#
# Run this from a normal terminal to see the truth. The result is also written to
# build\harness-processes.txt so it can be read afterwards.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$outFile = Join-Path $Root 'build\harness-processes.txt'

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("")

# 1) Processes matching the name the watchdog uses.
$byName = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
$lines.Add("Get-Process -Name 'DeepSeek Harness' -> $($byName.Count) 个")
foreach ($p in $byName) {
    $lines.Add("  pid=$($p.Id)  start=$($p.StartTime.ToString('HH:mm:ss'))  threads=$($p.Threads.Count)")
}
$lines.Add("")

# 2) Every process whose name looks related, in case the image name differs.
$related = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'Harness|DeepSeek|Codex' })
$lines.Add("名字含 Harness/DeepSeek 的进程 -> $($related.Count) 个")
foreach ($p in $related) {
    $lines.Add("  pid=$($p.Id)  name='$($p.ProcessName)'")
}
$lines.Add("")

# 3) Which process OWNS a window whose title mentions Harness? The name of that process is the
#    real answer, because a window is what the user perceives as "Harness is open".
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class HProc {
  public delegate bool E(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(E cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
'@

$owners = New-Object System.Collections.Generic.List[string]
$cb = [HProc+E] {
    param($h, $l)
    if ([HProc]::IsWindowVisible($h)) {
        $len = [HProc]::GetWindowTextLength($h)
        if ($len -gt 0) {
            $sb = New-Object System.Text.StringBuilder ($len + 2)
            [HProc]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
            $title = $sb.ToString()
            if ($title -match 'Harness') {
                $owner = 0
                [HProc]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
                $proc = Get-Process -Id $owner -ErrorAction SilentlyContinue
                $name = if ($null -ne $proc) { $proc.ProcessName } else { '<无法读取>' }
                $owners.Add("  hwnd=$h  pid=$owner  name='$name'")
                $owners.Add("      '$title'")
            }
        }
    }
    return $true
}
[HProc]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null

$lines.Add("Harness 窗口的所属进程:")
foreach ($o in $owners) { $lines.Add($o) }
$lines.Add("")

# 4) The verdict the watchdog cares about.
$verdict = if ($byName.Count -gt 0) {
    "结论: 用 -Name 'DeepSeek Harness' 可以检测到 Harness（$($byName.Count) 个进程）"
} else {
    "结论: !! 用 -Name 'DeepSeek Harness' 检测不到 Harness —— 看门狗需要改名或改用窗口检测"
}
$lines.Add($verdict)

[System.IO.File]::WriteAllLines($outFile, $lines)
foreach ($line in $lines) { Write-Host $line }
