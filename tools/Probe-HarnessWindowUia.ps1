# Probe-HarnessWindowUia.ps1 - can the running Harness UI be driven to a session?
#
# "Click the bubble -> jump to that conversation" needs a mechanism. There is no
# deep link (the SPA never reads the URL), so the remaining candidate is UI
# Automation: if the sidebar's session items appear in the accessibility tree, the
# pet can select one.
#
# This finds the Harness window by title (it may be a browser window or the Electron
# shell), walks its UIA tree, and prints anything list- or session-shaped.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'tools\PetWindowNative.ps1')

$windows = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -ne '' })
# @() is required: a single match unwraps to a scalar and .Count then throws.
$harness = @($windows | Where-Object { $_.Title -match 'Harness' })
if ($harness.Count -eq 0) {
    Write-Host 'No window with "Harness" in its title is visible.'
    Write-Host 'Open the Harness UI and retry.'
    exit 2
}

Write-Host "candidate Harness windows: $($harness.Count)"
foreach ($w in $harness) {
    $proc = Get-Process -Id $w.Owner -ErrorAction SilentlyContinue
    $name = if ($null -ne $proc) { $proc.ProcessName } else { '?' }
    Write-Host ("  pid {0,-7} {1,-20} {2,5}x{3,-5} '{4}'" -f $w.Owner, $name, $w.Width, $w.Height, $w.Title)
}
Write-Host ''

$target = $harness | Sort-Object { $_.Width * $_.Height } -Descending | Select-Object -First 1
Write-Host "inspecting pid $($target.Owner) hwnd $($target.Handle)"
Write-Host ''

$root = [System.Windows.Automation.AutomationElement]::FromHandle($target.Handle)
if ($null -eq $root) { Write-Host 'UIA returned no root element for that window.'; exit 1 }
Write-Host "root: Name='$($root.Current.Name)' Class='$($root.Current.ClassName)'"

$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
$interesting = New-Object System.Collections.Generic.List[object]
$queue = New-Object System.Collections.Generic.Queue[object]
$queue.Enqueue(@{ El = $root; Depth = 0 })
$visited = 0

while ($queue.Count -gt 0 -and $visited -lt 1500) {
    $node = $queue.Dequeue()
    $el = $node.El
    $visited++
    try {
        $name = $el.Current.Name
        $cls = $el.Current.ClassName
        $ctype = $el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', ''
        if ($ctype -match 'ListItem|List|TreeItem|Tree|Button|Tab|Hyperlink|Edit|Document' -or $name -match 'DeepSeek|Harness|session|会话') {
            $interesting.Add([pscustomobject]@{ Depth = $node.Depth; Type = $ctype; Class = $cls; Name = $name })
        }
        if ($node.Depth -lt 12) {
            $child = $walker.GetFirstChild($el)
            while ($null -ne $child) {
                $queue.Enqueue(@{ El = $child; Depth = $node.Depth + 1 })
                $child = $walker.GetNextSibling($child)
            }
        }
    } catch { }
}

Write-Host "visited $visited elements; interesting: $($interesting.Count)"
Write-Host ''
$interesting | Select-Object -First 50 | ForEach-Object {
    $n = $_.Name
    if ($n.Length -gt 70) { $n = $n.Substring(0, 70) + '...' }
    Write-Host ("  {0}{1,-12} {2,-14} {3}" -f ('  ' * [Math]::Min($_.Depth, 10)), $_.Type, $_.Class, $n)
}
