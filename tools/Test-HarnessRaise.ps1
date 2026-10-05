# Test-HarnessRaise.ps1 - would the pet's click find and raise the Harness UI?
#
# `Open-Harness` prefers an already-open window whose title identifies Harness, so
# that a click raises what the user is looking at instead of spawning a duplicate.
# This checks that such a window is discoverable, using the same title match.
#
# Note what this CANNOT verify: that the raised view is the right *conversation*.
# No deep link exists (see README), so the click raises the UI and nothing more.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'tools\PetWindowNative.ps1')

$windows = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -ne '' })
$candidates = @($windows | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })

Write-Host "visible titled windows : $($windows.Count)"
Write-Host "Harness candidates     : $($candidates.Count)"
Write-Host ''
foreach ($w in $candidates) {
    $proc = Get-Process -Id $w.Owner -ErrorAction SilentlyContinue
    $name = if ($null -ne $proc) { $proc.ProcessName } else { '?' }
    Write-Host ("  pid {0,-7} {1,-16} {2,5}x{3,-5} '{4}'" -f $w.Owner, $name, $w.Width, $w.Height, $w.Title)
}

Write-Host ''
Write-Host '=== the pet desktop app (fallback 2) ==='
$exe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
Write-Host "  $exe"
Write-Host "  exists: $(Test-Path -LiteralPath $exe)"

Write-Host ''
Write-Host "=== loopback Harness URL (fallback 3) ==="
$listening = netstat -ano | Select-String -Pattern 'LISTENING' | Select-String -Pattern '127\.0\.0\.1:'
$found = @()
foreach ($line in $listening) {
    $parts = ($line.ToString().Trim() -split '\s+')
    if ($parts.Count -lt 4) { continue }
    $port = 0
    if (-not [int]::TryParse(($parts[1] -split ':')[-1], [ref]$port)) { continue }
    if ($port -eq 19387) { continue }
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/favicon.svg" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200 -and $r.Content -match 'viewBox') { $found += "http://127.0.0.1:$port/" }
    } catch { }
}
if ($found.Count -eq 0) { Write-Host '  none discovered (a window raise or the desktop app would be used)' }
else { $found | ForEach-Object { Write-Host "  $_" } }

Write-Host ''
if ($candidates.Count -gt 0) {
    Write-Host 'PASS: a click can raise an existing Harness window.'
    exit 0
}
Write-Host 'NOTE: no Harness window is currently open, so a click would launch one.'
exit 2
