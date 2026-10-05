# Validate-Shell.ps1 - keep the WPF shell runnable under Windows PowerShell 5.1.
#
# Two failure modes are easy to reintroduce and both are fatal at startup:
#
#  1. Encoding. The shell's UI copy is Chinese, and PowerShell 5.1 decodes a
#     BOM-less file as ANSI, which turns every literal into mojibake and makes
#     the parser report "unexpected token" on strings that look fine. Any editor
#     that writes UTF-8 without a BOM silently breaks the script, so the BOM is
#     checked (and repaired) here.
#  2. Syntax, including the reserved automatic variables that a UI script
#     naturally reaches for ($host, $error, $args, $input, $matches, $psitem).
#
# Usage:
#   powershell -NoProfile -File tools/Validate-Shell.ps1            # check
#   powershell -NoProfile -File tools/Validate-Shell.ps1 -Fix       # repair BOMs

param(
    [switch]$Fix,
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# Automatic variables that cannot be assigned; a collision here fails only at
# the moment the function runs, which is worse than failing at parse time.
$reserved = @('host', 'error', 'args', 'input', 'matches', 'psitem', 'this', 'true', 'false', 'null', 'pwd', 'home', 'pid')

$targets = Get-ChildItem -Path (Join-Path $Root 'src\shell') -Filter '*.ps1' -File
$failed = 0

foreach ($file in $targets) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF

    if (-not $hasBom) {
        if ($Fix) {
            $text = [System.IO.File]::ReadAllText($file.FullName, $utf8NoBom)
            [System.IO.File]::WriteAllText($file.FullName, $text, $utf8Bom)
            Write-Host "FIXED BOM  $($file.Name)"
        } else {
            Write-Host "FAIL  $($file.Name): missing UTF-8 BOM (PowerShell 5.1 will mis-decode the Chinese literals)"
            $failed++
            continue
        }
    }

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        Write-Host "FAIL  $($file.Name): $($errors.Count) parse error(s)"
        $errors | Select-Object -First 8 | ForEach-Object {
            Write-Host "        line $($_.Extent.StartLineNumber): $($_.Message)"
        }
        $failed++
        continue
    }

    # Assignment to a reserved automatic variable.
    $assignments = $tokens | Where-Object {
        $_.Kind -eq 'Variable' -and $reserved -contains $_.Name.TrimStart('$').ToLowerInvariant()
    }
    $bad = @()
    foreach ($token in $assignments) {
        # Only flag variables that are actually written to.
        $line = $token.Extent.StartLineNumber
        $text = (Get-Content -LiteralPath $file.FullName)[$line - 1]
        if ($text -match ('^\s*\$' + [regex]::Escape($token.Name.TrimStart('$')) + '\s*(=|[-+*/]=)')) {
            $bad += "line ${line}: assigns to reserved automatic variable $($token.Name)"
        }
    }
    if ($bad.Count -gt 0) {
        Write-Host "FAIL  $($file.Name): reserved variable assignment"
        $bad | Select-Object -First 6 | ForEach-Object { Write-Host "        $_" }
        $failed++
        continue
    }

    Write-Host "OK    $($file.Name)  (BOM, $($tokens.Count) tokens, no reserved assignments)"
}

if ($failed -gt 0) {
    Write-Host "`n$failed shell file(s) need attention."
    exit 1
}
Write-Host "`nall shell files valid."
