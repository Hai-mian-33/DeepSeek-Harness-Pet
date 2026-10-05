# Capture-Region.ps1 - screenshot a screen rectangle, for visual verification.
#
# The desktop pet is a transparent always-on-top window, so "did it render?" has
# to be answered from pixels. Capture is done with CopyFromScreen into a Bitmap
# so the result can be inspected as an image.
#
# Usage:
#   powershell -NoProfile -File tools/Capture-Region.ps1 -X 1400 -Y 640 -Width 420 -Height 340 -Out build/shot.png

param(
    [Parameter(Mandatory = $true)][int]$X,
    [Parameter(Mandatory = $true)][int]$Y,
    [Parameter(Mandatory = $true)][int]$Width,
    [Parameter(Mandatory = $true)][int]$Height,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$Root = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not yet populated while parameter defaults are evaluated, so
# the project root is resolved here instead.
if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# The virtual screen gives the coordinate origin for a multi-monitor desktop.
$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
Write-Host "virtual screen: $($bounds.X),$($bounds.Y) $($bounds.Width)x$($bounds.Height)"

$clampedX = [Math]::Max($bounds.X, [Math]::Min($X, $bounds.X + $bounds.Width - 1))
$clampedY = [Math]::Max($bounds.Y, [Math]::Min($Y, $bounds.Y + $bounds.Height - 1))
$clampedW = [Math]::Min($Width, $bounds.X + $bounds.Width - $clampedX)
$clampedH = [Math]::Min($Height, $bounds.Y + $bounds.Height - $clampedY)

$bitmap = New-Object System.Drawing.Bitmap($clampedW, $clampedH)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($clampedX, $clampedY, 0, 0, (New-Object System.Drawing.Size($clampedW, $clampedH)))
$graphics.Dispose()

$target = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $Root $Out }
$directory = Split-Path -Parent $target
if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$bitmap.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()

Write-Host "captured ($clampedX,$clampedY) ${clampedW}x${clampedH} -> $target"
