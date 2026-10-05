# Get-HarnessUrl.ps1 - what URL is the Harness UI loaded from?
#
# Decides how "open Harness" and "jump to a conversation" must be implemented:
#   * a loopback web URL  -> the pet can open it with the modelled token exchange;
#   * the Electron shell  -> the pet can only raise its window (no deep link).
#
# Reads the address bar via the browser's own window title where possible, and
# otherwise reports the loopback port the host is serving on.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Write-Host '=== listening loopback ports that look like the DSH host ==='
$listening = netstat -ano | Select-String -Pattern 'LISTENING' | Select-String -Pattern '127\.0\.0\.1:'
$ports = @()
foreach ($line in $listening) {
    $parts = ($line.ToString().Trim() -split '\s+')
    $local = $parts[1]
    $ownerPid = $parts[-1]
    $port = [int]($local -split ':')[-1]
    $ports += [pscustomobject]@{ Port = $port; Pid = $ownerPid }
}

# The DSH host answers /favicon.svg publicly with its own whale mark.
foreach ($entry in ($ports | Sort-Object Port -Unique)) {
    try {
        $probe = Invoke-WebRequest -Uri "http://127.0.0.1:$($entry.Port)/favicon.svg" -UseBasicParsing -TimeoutSec 2
        if ($probe.StatusCode -eq 200 -and $probe.Content -match 'viewBox') {
            Write-Host ("  port {0,-7} pid {1,-7} -> favicon OK (len {2})" -f $entry.Port, $entry.Pid, $probe.Content.Length)
        }
    } catch { }
}

Write-Host ''
Write-Host '=== Harness windows and their titles ==='
$windows = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -ne '' -and $_.Title -match 'Harness|DeepSeek' })
foreach ($w in $windows) {
    $proc = Get-Process -Id $w.Owner -ErrorAction SilentlyContinue
    $name = if ($null -ne $proc) { $proc.ProcessName } else { '?' }
    Write-Host ("  pid {0,-7} {1,-12} '{2}'" -f $w.Owner, $name, $w.Title)
}
Write-Host ''
Write-Host 'The desktop shell loads its renderer over file:// with IPC, so its title is'
Write-Host 'document-derived and carries no session identity. A browser window title'
Write-Host 'likewise shows the document title, not the URL.'
