# Capture-DocsShots.ps1 - regenerate the documentation screenshots from synthetic data.
#
# The READMEs need screenshots of the bubble and the expanded panel, but a live
# capture shows whatever conversations the developer really has open — project
# names, affiliations, everything. So instead of capturing the desktop, this
# script renders the SAME WPF visual tree the shell draws at runtime, fed by a
# view that the REAL reducer produced from synthetic, neutral sessions
# (demo-app, api-gateway, …). Nothing personal can leak in, and the images stay
# pixel-faithful to the product because no drawing code is duplicated.
#
# Outputs (docs/images/, pure-white background, 2x scale):
#   shot-bubble.png      zh-CN, collapsed popup
#   shot-panel.png       zh-CN, expanded panel
#   shot-bubble-en.png   en, collapsed popup
#   shot-panel-en.png    en, expanded panel
#   desktop-mock.png     zh-CN whale + bubble on white (hero shot)
#   desktop-mock-en.png  en whale + bubble on white (hero shot)
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Capture-DocsShots.ps1

param([string]$Root = '')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$shellPath = Join-Path $Root 'src\shell\WhalePet.ps1'
$outDir = Join-Path $Root 'docs\images'
$sheetPath = Join-Path $Root 'assets\whale-sheet.png'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# --- the shell's real rendering functions, extracted verbatim -----------------

$text = [System.IO.File]::ReadAllText($shellPath)

function Get-FunctionSource([string]$name) {
    $pattern = "(?ms)^function\s+$([regex]::Escape($name))\s*\{.*?^\}"
    $m = [regex]::Match($text, $pattern)
    if (-not $m.Success) { throw "cannot extract $name" }
    return $m.Value
}

$script:BrandBlue = '#4D6BFE'
$script:PanelExpanded = $false

foreach ($fn in @('Get-Field', 'New-TextBlock', 'New-Card', 'New-Dot', 'Get-StatusColor', 'Build-BubbleContent')) {
    Invoke-Expression (Get-FunctionSource $fn)
}
# The bilingual copy table the renderer reaches through `T`.
. (Join-Path $Root 'src\shell\PetStrings.ps1')

# --- synthetic views from the REAL reducer ------------------------------------

# Written to a temp .mjs and run by Node: the view must come from reducePet so the
# screenshots show what the product actually renders, not a hand-typed imitation.
$generator = @'
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const reducerUrl = pathToFileURL(join(process.argv[2], 'src', 'core', 'pet-reducer.mjs')).href;
const { reducePet } = await import(reducerUrl);

const NOW = 1_800_000_000_000;
const base = {
  title: null, seq: 10, time: NOW, openTurn: false, openStep: false,
  pendingApprovals: 0, pendingQuestions: 0, pendingCalls: 0,
  toolCalls: 12, toolErrors: 0, lastToolFailed: false, errorCode: null,
  todoDone: null, todoTotal: null, tracked: true,
};
const sessions = [
  // working, 46:42 elapsed, todo 2/10 -> the long-task showcase
  { ...base, id: 's1', name: 'demo-app', openTurn: true, pendingCalls: 1,
    lastToolName: 'pwsh', todoDone: 2, todoTotal: 10,
    startedAt: NOW - 2_802_000, lastActivity: NOW },
  // finished 2 minutes ago, unread -> the completion reminder on top
  { ...base, id: 's2', name: 'api-gateway', lastToolName: 'npm',
    lastTurnCompleted: true, startedAt: NOW - 1_500_000, lastActivity: NOW - 120_000 },
  // finished 40 minutes ago, unread
  { ...base, id: 's3', name: 'ml-course', lastToolName: 'python',
    lastTurnCompleted: true, startedAt: NOW - 3_600_000, lastActivity: NOW - 2_400_000 },
  // failed 5 minutes ago, unread -> the red row
  { ...base, id: 's4', name: 'data-pipeline', lastToolName: 'bash',
    lastToolFailed: true, toolErrors: 1, errorCode: 'ENOENT',
    lastTurnCompleted: false, startedAt: NOW - 600_000, lastActivity: NOW - 300_000 },
  // thinking right now
  { ...base, id: 's5', name: 'docs-site', openTurn: true, openStep: true,
    lastToolName: null, startedAt: NOW - 95_000, lastActivity: NOW },
  // finished 3 hours ago, unread
  { ...base, id: 's6', name: 'web-crawler', lastToolName: 'node',
    lastTurnCompleted: true, startedAt: NOW - 5 * 3_600_000,
    lastActivity: NOW - 3 * 3_600_000 },
];
const completions = {
  s2: { at: NOW - 120_000, kind: 'done', acknowledged: false },
  s3: { at: NOW - 2_400_000, kind: 'done', acknowledged: false },
  s4: { at: NOW - 300_000, kind: 'error', acknowledged: false },
  s6: { at: NOW - 3 * 3_600_000, kind: 'done', acknowledged: false },
};

// The collapsed-popup shot uses a smaller roster so the "+N" badge sentence fits
// the 240px popup the way it does in practice; the expanded-panel shot uses the
// full roster to show parallel boxes, badges and the list together.
const bubbleSessions = [sessions[0], sessions[1], sessions[4]];
const bubbleCompletions = { s2: completions.s2 };

for (const [lang, suffix] of [['zh-CN', 'zh'], ['en', 'en']]) {
  const panel = reducePet({ sessions, now: NOW, completions, lang });
  writeFileSync(join(process.argv[3], `view-panel-${suffix}.json`), JSON.stringify(panel), 'utf8');
  const bubble = reducePet({ sessions: bubbleSessions, now: NOW, completions: bubbleCompletions, lang });
  writeFileSync(join(process.argv[3], `view-bubble-${suffix}.json`), JSON.stringify(bubble), 'utf8');
}
console.log('views written');
'@
$genPath = Join-Path $env:TEMP 'pet-docs-view.mjs'
[System.IO.File]::WriteAllText($genPath, $generator, (New-Object System.Text.UTF8Encoding($false)))
node $genPath $Root $outDir
if ($LASTEXITCODE -ne 0) { throw "view generator failed" }

# --- offscreen rendering -------------------------------------------------------

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'

# White stage + soft shadow: the cards keep their own look, the shadow separates
# them from the pure-white background the documentation asks for.
function New-Stage([double]$Width) {
    $stage = New-Object System.Windows.Controls.Border
    $stage.Background = [System.Windows.Media.Brushes]::White
    $stage.Padding = New-Object System.Windows.Thickness(28)
    $holder = New-Object System.Windows.Controls.Border
    $holder.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect
    $holder.Effect.Color = ([System.Windows.Media.ColorConverter]::ConvertFromString('#0F172A'))
    $holder.Effect.BlurRadius = 16
    $holder.Effect.ShadowDepth = 5
    $holder.Effect.Opacity = 0.22
    $stage.Child = $holder
    return @($stage, $holder)
}

function Save-Visual($visual, [double]$width, [double]$height, [string]$file) {
    $scale = 2.0
    $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
        [int]($width * $scale), [int]($height * $scale), (96 * $scale), (96 * $scale),
        [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($visual)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb)) | Out-Null
    $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Create)
    try { $encoder.Save($stream) } finally { $stream.Close() }
    Write-Host ("  wrote {0} ({1}x{2}px @2x)" -f (Split-Path -Leaf $file), [int]$width, [int]$height)
}

function Render-ViewToFile($view, [string]$lang, [bool]$expanded, [string]$file) {
    Set-PetLanguage -Value $lang
    $script:PanelExpanded = $expanded
    $popupWidth = if ($expanded) { 280.0 } else { 240.0 }

    $content = Build-BubbleContent -View $view -Width $popupWidth
    $stage, $holder = New-Stage -Width $popupWidth
    $holder.Child = $content

    $stage.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $stage.Arrange([System.Windows.Rect]::new(0, 0, $stage.DesiredSize.Width, $stage.DesiredSize.Height))
    $stage.UpdateLayout()
    Save-Visual -Visual $stage -Width $stage.DesiredSize.Width -Height $stage.DesiredSize.Height -File $file
}

$viewPanelZh = Get-Content (Join-Path $outDir 'view-panel-zh.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$viewPanelEn = Get-Content (Join-Path $outDir 'view-panel-en.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$viewBubbleZh = Get-Content (Join-Path $outDir 'view-bubble-zh.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$viewBubbleEn = Get-Content (Join-Path $outDir 'view-bubble-en.json') -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host 'rendering popup shots:'
Render-ViewToFile -View $viewBubbleZh -Lang 'zh-CN' -Expanded $false -File (Join-Path $outDir 'shot-bubble.png')
Render-ViewToFile -View $viewPanelZh -Lang 'zh-CN' -Expanded $true  -File (Join-Path $outDir 'shot-panel.png')
Render-ViewToFile -View $viewBubbleEn -Lang 'en'    -Expanded $false -File (Join-Path $outDir 'shot-bubble-en.png')
Render-ViewToFile -View $viewPanelEn -Lang 'en'    -Expanded $true  -File (Join-Path $outDir 'shot-panel-en.png')

# --- hero shot: whale + bubble on pure white -----------------------------------

function New-DesktopMock($view, [string]$lang, [string]$file) {
    Set-PetLanguage -Value $lang
    $script:PanelExpanded = $false

    $canvas = New-Object System.Windows.Controls.Canvas
    $canvas.Background = [System.Windows.Media.Brushes]::White
    $canvas.Width = 760; $canvas.Height = 420

    # The pet itself: the idle frame cropped from the committed sprite sheet.
    $sheet = New-Object System.Windows.Media.Imaging.BitmapImage
    $sheet.BeginInit()
    $sheet.UriSource = New-Object System.Uri($sheetPath)
    $sheet.CacheOption = 'OnLoad'
    $sheet.EndInit()
    $sheet.Freeze()
    $frame = New-Object System.Windows.Media.Imaging.CroppedBitmap($sheet, ([System.Windows.Int32Rect]::new(0, 0, 192, 208)))
    $whale = New-Object System.Windows.Controls.Image
    $whale.Source = $frame
    $whale.Width = 150; $whale.Height = 162.5
    [void]($canvas.Children.Add($whale))
    [System.Windows.Controls.Canvas]::SetLeft($whale, 545)
    [System.Windows.Controls.Canvas]::SetTop($whale, 200)

    # A soft ground shadow floats the whale off the white page.
    $ground = New-Object System.Windows.Shapes.Ellipse
    $ground.Fill = New-Object System.Windows.Media.SolidColorBrush(([System.Windows.Media.ColorConverter]::ConvertFromString('#0F172A')))
    $ground.Opacity = 0.10
    $ground.Width = 150; $ground.Height = 16
    $ground.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect
    $ground.Effect.BlurRadius = 12
    $ground.Effect.ShadowDepth = 0
    [void]($canvas.Children.Add($ground))
    [System.Windows.Controls.Canvas]::SetLeft($ground, 545)
    [System.Windows.Controls.Canvas]::SetTop($ground, 372)

    # The popup content, exactly as the shell builds it, floating left of the pet.
    $content = Build-BubbleContent -View $view -Width 240
    $holder = New-Object System.Windows.Controls.Border
    $holder.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect
    $holder.Effect.Color = ([System.Windows.Media.ColorConverter]::ConvertFromString('#0F172A'))
    $holder.Effect.BlurRadius = 16
    $holder.Effect.ShadowDepth = 5
    $holder.Effect.Opacity = 0.22
    $holder.Child = $content
    $holder.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    [void]($canvas.Children.Add($holder))
    [System.Windows.Controls.Canvas]::SetLeft($holder, 170)
    [System.Windows.Controls.Canvas]::SetTop($holder, 60)

    $canvas.Measure([System.Windows.Size]::new($canvas.Width, $canvas.Height))
    $canvas.Arrange([System.Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
    $canvas.UpdateLayout()
    Save-Visual -Visual $canvas -Width $canvas.Width -Height $canvas.Height -File $file
}

Write-Host 'rendering hero shots:'
New-DesktopMock -View $viewBubbleZh -Lang 'zh-CN' -File (Join-Path $outDir 'desktop-mock.png')
New-DesktopMock -View $viewBubbleEn -Lang 'en'    -File (Join-Path $outDir 'desktop-mock-en.png')

# The generator's intermediate views are not documentation assets.
Remove-Item (Join-Path $outDir 'view-panel-zh.json'), (Join-Path $outDir 'view-panel-en.json'), (Join-Path $outDir 'view-bubble-zh.json'), (Join-Path $outDir 'view-bubble-en.json') -Force
Remove-Item $genPath -Force

Write-Host 'PASS: documentation screenshots regenerated on a pure-white background.'
