# Stop-Pet.ps1 - stop the Blue Whale Pet (shell and bridge), wherever they were started.
#
# Both parts are found by observable evidence rather than by a stored pid, because
# `start-pet.cmd` launches them detached and they can outlive the terminal that started
# them:
#
#   * the shell OWNS the pet's windows, so its pid comes from enumerating windows that
#     carry the pet's titles;
#   * the bridge publishes its own pid in `state/bridge-status.json`.
#
# Stopping is idempotent: running this when nothing is up reports that and exits 0.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') {
    # This file lives in <root>\tools, so the repository root is ONE level above the
    # script's own directory. ($PSCommandPath is used rather than $PSScriptRoot, which
    # can be empty while parameters are still being bound.)
    $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Write-Host '[pet] stopping...'

$stopped = 0
$seen = New-Object System.Collections.Generic.HashSet[int]

# --- the shell: whoever owns the pet's windows ---
$petWindows = @(Get-AllWindows | Where-Object {
    $_.Visible -and ($_.Title -eq '蓝鲸小深' -or $_.Title -like '蓝鲸小深*')
})
foreach ($window in $petWindows) {
    if ($seen.Add([int]$window.Owner)) {
        $process = Get-Process -Id $window.Owner -ErrorAction SilentlyContinue
        if ($null -ne $process) {
            Write-Host ("[pet]   shell  pid {0} ({1})" -f $window.Owner, $process.ProcessName)
            Stop-Process -Id $window.Owner -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    }
}
if ($petWindows.Count -eq 0) { Write-Host '[pet]   no shell window found' }

# --- the bridge: it records its own pid ---
$statusFile = Join-Path $Root 'state\bridge-status.json'
if (Test-Path -LiteralPath $statusFile) {
    try {
        $status = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $bridgePid = [int]$status.pid
        if ($bridgePid -gt 0 -and $seen.Add($bridgePid)) {
            $process = Get-Process -Id $bridgePid -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                Write-Host ("[pet]   bridge pid {0} ({1})" -f $bridgePid, $process.ProcessName)
                Stop-Process -Id $bridgePid -Force -ErrorAction SilentlyContinue
                $stopped++
            } else {
                Write-Host ("[pet]   bridge pid {0} already gone" -f $bridgePid)
            }
        }
    } catch {
        Write-Host "[pet]   could not read bridge status: $($_.Exception.Message)"
    }
} else {
    Write-Host '[pet]   no bridge status file'
}

Start-Sleep -Milliseconds 600

$remaining = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '蓝鲸小深*' })
if ($remaining.Count -eq 0) {
    Write-Host ("[pet] stopped ({0} process(es))." -f $stopped)
    exit 0
}
Write-Host ("[pet] WARNING: {0} pet window(s) still present." -f $remaining.Count)
exit 1
