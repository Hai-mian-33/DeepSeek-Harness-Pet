# List-VisibleWindows.ps1 - what UI is actually on screen?
#
# Both the pet and the "open Harness" action need to know which Harness surface the
# user has in front of them: the Electron desktop window, or the web GUI in a
# browser. They are driven differently, so this lists the visible top-level windows
# with their owning process.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'tools\PetWindowNative.ps1')

$windows = Get-AllWindows | Where-Object { $_.Visible -and $_.Title -ne '' } | Sort-Object Owner
Write-Host "visible titled windows: $($windows.Count)"
Write-Host ''

foreach ($w in $windows) {
    $proc = Get-Process -Id $w.Owner -ErrorAction SilentlyContinue
    $name = if ($null -ne $proc) { $proc.ProcessName } else { '?' }
    $title = $w.Title
    if ($title.Length -gt 78) { $title = $title.Substring(0, 78) + '...' }
    Write-Host ("  pid {0,-7} {1,-22} {2,5}x{3,-5} ({4},{5})  {6}" -f `
        $w.Owner, $name, $w.Width, $w.Height, $w.Left, $w.Top, $title)
}

Write-Host ''
Write-Host '=== likely Harness surfaces ==='
foreach ($w in $windows) {
    $proc = Get-Process -Id $w.Owner -ErrorAction SilentlyContinue
    if ($null -eq $proc) { continue }
    $isHarnessApp = $proc.ProcessName -like '*DeepSeek*'
    $isBrowser = $proc.ProcessName -match 'chrome|msedge|firefox|brave|opera|vivaldi'
    if ($isHarnessApp) { Write-Host "  DESKTOP APP : pid $($w.Owner) '$($w.Title)'" }
    elseif ($isBrowser -and ($w.Title -match 'Harness|DeepSeek|localhost|127\.0\.0\.1')) {
        Write-Host "  BROWSER     : pid $($w.Owner) '$($w.Title)'"
    }
}
