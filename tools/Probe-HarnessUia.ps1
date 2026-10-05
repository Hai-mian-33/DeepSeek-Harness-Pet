# Probe-HarnessUia.ps1 - can the Harness window's sessions be driven from outside?
#
# There is no documented way to open one specific conversation in the Desktop app:
#   * the SPA is loaded over file:// with IPC, so there is no URL to navigate;
#   * the SPA has no session route (its only `hashchange` reference is React's
#     synthetic event list);
#   * the shell's protocol handler accepts only `dsh://open`, and only on macOS;
#   * no `dsh` command opens a session.
#
# So a "jump to this conversation" click needs another mechanism. UI Automation is
# the candidate: if the session list is exposed as an accessibility tree, the pet can
# select the right item. This probe reports whether that tree is reachable and what
# it contains, before any of it is built on.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

function Get-WindowTitles {
    Add-Type -Namespace UiaProbe -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern int GetWindowTextLength(System.IntPtr h);
'@
    $list = New-Object System.Collections.Generic.List[object]
    $harnessPids = @(Get-Process | Where-Object { $_.ProcessName -like '*DeepSeek*' } | Select-Object -ExpandProperty Id)
    $cb = [UiaProbe.Native+EnumWindowsProc] {
        param([IntPtr]$h, [IntPtr]$p)
        $owner = 0
        [UiaProbe.Native]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
        if ($harnessPids -contains [int]$owner) {
            $len = [UiaProbe.Native]::GetWindowTextLength($h)
            $sb = New-Object System.Text.StringBuilder ($len + 2)
            [UiaProbe.Native]::GetWindowText($h, $sb, $sb.Capacity) | Out-Null
            $list.Add([pscustomobject]@{ Handle = $h; Pid = [int]$owner; Title = $sb.ToString(); Visible = [UiaProbe.Native]::IsWindowVisible($h) })
        }
        return $true
    }
    [UiaProbe.Native]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $list
}

$windows = Get-WindowTitles
Write-Host "Harness windows found: $($windows.Count)"
foreach ($w in $windows) { Write-Host ("  hwnd={0,-10} pid={1,-7} visible={2,-5} title='{3}'" -f $w.Handle, $w.Pid, $w.Visible, $w.Title) }

$main = $windows | Where-Object { $_.Visible -and $_.Title -ne '' } | Select-Object -First 1
if ($null -eq $main) { Write-Host 'No visible Harness window - open it and retry.'; exit 2 }

Write-Host ''
Write-Host "Inspecting UIA tree of '$($main.Title)' (hwnd=$($main.Handle))"
$root = [System.Windows.Automation.AutomationElement]::FromHandle($main.Handle)
if ($null -eq $root) { Write-Host 'UIA returned no root element.'; exit 1 }
Write-Host "root: Name='$($root.Current.Name)' Class='$($root.Current.ClassName)'"

# Walk a bounded slice of the tree looking for anything list- or session-shaped.
$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$found = New-Object System.Collections.Generic.List[object]
$queue = New-Object System.Collections.Generic.Queue[object]
$queue.Enqueue(@{ El = $root; Depth = 0 })
$visited = 0
while ($queue.Count -gt 0 -and $visited -lt 400) {
    $node = $queue.Dequeue()
    $el = $node.El
    $visited++
    try {
        $name = $el.Current.Name
        $cls = $el.Current.ClassName
        $ctype = $el.Current.ControlType.ProgrammaticName
        if ($name -ne '' -or $ctype -match 'List|Tree|Button|Tab') {
            $found.Add([pscustomobject]@{ Depth = $node.Depth; Type = $ctype; Class = $cls; Name = $name })
        }
        if ($node.Depth -lt 6) {
            $child = $walker.GetFirstChild($el)
            while ($null -ne $child) {
                $queue.Enqueue(@{ El = $child; Depth = $node.Depth + 1 })
                $child = $walker.GetNextSibling($child)
            }
        }
    } catch { }
}

Write-Host "visited $visited elements; interesting nodes: $($found.Count)"
Write-Host ''
$found | Select-Object -First 45 | ForEach-Object {
    Write-Host ("  {0}{1,-28} {2,-26} {3}" -f ('  ' * $_.Depth), $_.Type, $_.Class, $_.Name)
}
