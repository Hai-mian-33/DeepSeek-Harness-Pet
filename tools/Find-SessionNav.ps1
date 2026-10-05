# Find-SessionNav.ps1 - is there ANY way to send the Harness UI to one conversation?
#
# "Click the bubble -> jump to that conversation" needs a mechanism, and the obvious
# ones are ruled out: the SPA never reads the URL, and the shell's protocol handler
# accepts only `dsh://open` (macOS only). This searches the remaining candidates:
#
#   1. URL/location handling anywhere in the client plugin bundles;
#   2. a host API that activates a session (which a watching UI would follow);
#   3. an accessibility path into the sidebar.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bundles = "C:\Users\23154\.dsh\profiles\node_modules\@deepseek-ai"
$results = @()

Write-Host '=== 1. URL handling in client plugin bundles ==='
$clientFiles = Get-ChildItem $bundles -Directory | ForEach-Object {
    Join-Path $_.FullName 'lib\client.js'
} | Where-Object { Test-Path $_ }

Write-Host "scanning $($clientFiles.Count) client bundles"
$urlPatterns = @('location.search', 'location.hash', 'location.pathname', 'window.location', 'URLSearchParams', 'pushState', 'history.state')
foreach ($file in $clientFiles) {
    $text = [System.IO.File]::ReadAllText($file)
    $hits = @()
    foreach ($pattern in $urlPatterns) {
        $count = ([regex]::Matches($text, [regex]::Escape($pattern))).Count
        if ($count -gt 0) { $hits += "$pattern x$count" }
    }
    if ($hits.Count -gt 0) {
        $name = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $file))
        $results += [pscustomobject]@{ Bundle = $name; Hits = ($hits -join ', ') }
    }
}
if ($results.Count -eq 0) { Write-Host '  none: no client bundle touches the URL' }
else { $results | Format-Table -AutoSize }

Write-Host ''
Write-Host '=== 2. host API that activates / focuses a session ==='
$ctrl = Join-Path $bundles 'dsh-api-session-controller\lib\index.js'
if (Test-Path $ctrl) {
    $text = [System.IO.File]::ReadAllText($ctrl)
    # Look for method names that imply making a session current.
    foreach ($pattern in @('activate', 'focus', 'openSession', 'selectSession', 'setActive', 'currentSession', 'resume')) {
        $count = ([regex]::Matches($text, $pattern, 'IgnoreCase')).Count
        if ($count -gt 0) { Write-Host ("  {0,-16} x{1}" -f $pattern, $count) }
    }
    Write-Host ''
    Write-Host '  methods declared on the session controller surface:'
    $methods = [regex]::Matches($text, '(?m)^\s{0,4}([a-zA-Z][A-Za-z0-9_]{2,30})\s*\(') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    Write-Host ('    ' + (($methods | Select-Object -First 40) -join ', '))
} else {
    Write-Host "  session controller not found at $ctrl"
}

Write-Host ''
Write-Host '=== 3. does the client sidebar expose item activation via UIA? ==='
Write-Host '  (sidebar is inside the Electron/browser renderer; requires the window visible)'
