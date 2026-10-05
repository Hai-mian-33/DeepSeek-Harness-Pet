# Probe-RestoreRace.ps1 - is the raise refused because the restore has not landed yet?
#
# Evidence so far:
#   * Probe-OpenHarness: target was ICONIC -> every raise call returned False.
#   * Probe-RaiseStrategies: target was NOT iconic -> SetForegroundWindow succeeded.
#
# That points at a race in the shell's sequence, which is:
#
#     if (IsIconic) { ShowWindow(SW_RESTORE) }     # asynchronous: returns at once
#     SetForegroundWindow(hwnd)                    # refused while still iconic
#
# ShowWindow's own return value reports the PREVIOUS visibility, so it cannot be
# used to tell whether the restore finished. This probe minimises the target, then
# compares the shell's immediate sequence against one that waits for the restore to
# be observable, reporting the real outcome of each via GetForegroundWindow.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace Race -Name Native -MemberDefinition @'
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
'@

$SW_RESTORE = 9
$SW_MINIMIZE = 6

function Get-TitledWindows {
    $list = New-Object System.Collections.Generic.List[object]
    $cb = [Race.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        if ([Race.Native]::IsWindowVisible($h)) {
            $len = [Race.Native]::GetWindowTextLength($h)
            if ($len -gt 0) {
                $sb = New-Object System.Text.StringBuilder ($len + 2)
                [Race.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
                $owner = 0
                [Race.Native]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
                $list.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString(); Pid = [int]$owner })
            }
        }
        return $true
    }
    [Race.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$candidates = @(Get-TitledWindows | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })
if ($candidates.Count -eq 0) { Write-Host 'No Harness-titled window.'; exit 2 }
$handle = $candidates[0].Handle
Write-Host "target hwnd=$handle '$($candidates[0].Title)'"
Write-Host ''

Write-Host '=== A: the shell''s current sequence (restore, then claim immediately) ==='
[Race.Native]::ShowWindow($handle, $SW_MINIMIZE) | Out-Null
Start-Sleep -Milliseconds 600
Write-Host "  minimized: iconic=$([Race.Native]::IsIconic($handle))"
[Race.Native]::ShowWindow($handle, $SW_RESTORE) | Out-Null
[Race.Native]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 500
$fgA = ([Race.Native]::GetForegroundWindow() -eq $handle)
Write-Host "  -> became foreground: $fgA   (iconic now: $([Race.Native]::IsIconic($handle)))"
Write-Host ''

Write-Host '=== B: wait for the restore to be observable, then claim ==='
[Race.Native]::ShowWindow($handle, $SW_MINIMIZE) | Out-Null
Start-Sleep -Milliseconds 600
Write-Host "  minimized: iconic=$([Race.Native]::IsIconic($handle))"
[Race.Native]::ShowWindow($handle, $SW_RESTORE) | Out-Null
$waited = 0
for ($i = 0; $i -lt 40; $i++) {
    if (-not [Race.Native]::IsIconic($handle)) { break }
    Start-Sleep -Milliseconds 25
    $waited += 25
}
Write-Host "  restore observed after ${waited}ms; iconic=$([Race.Native]::IsIconic($handle))"
[Race.Native]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 400
$fgB = ([Race.Native]::GetForegroundWindow() -eq $handle)
Write-Host "  -> became foreground: $fgB"
Write-Host ''

Write-Host '=== C: restore-and-confirm, then claim with a retry ==='
[Race.Native]::ShowWindow($handle, $SW_MINIMIZE) | Out-Null
Start-Sleep -Milliseconds 600
[Race.Native]::ShowWindow($handle, $SW_RESTORE) | Out-Null
for ($i = 0; $i -lt 40; $i++) {
    if (-not [Race.Native]::IsIconic($handle)) { break }
    Start-Sleep -Milliseconds 25
}
$fgC = $false
for ($attempt = 0; $attempt -lt 5; $attempt++) {
    [Race.Native]::SetForegroundWindow($handle) | Out-Null
    Start-Sleep -Milliseconds 120
    if ([Race.Native]::GetForegroundWindow() -eq $handle) { $fgC = $true; break }
}
Write-Host "  -> became foreground: $fgC"
Write-Host ''

Write-Host '=== summary ==='
Write-Host "  A (immediate claim, what the shell does): $fgA"
Write-Host "  B (wait for restore)                    : $fgB"
Write-Host "  C (wait + retry)                        : $fgC"
Write-Host ''
if (-not $fgA -and ($fgB -or $fgC)) {
    Write-Host 'CONFIRMED: the raise fails only because the restore has not landed yet.'
    exit 0
}
if ($fgA -and $fgB -and $fgC) {
    Write-Host 'All three worked here; the race did not reproduce on this run.'
    exit 2
}
Write-Host 'Inconclusive.'
exit 1
