# WhalePet.ps1 — 蓝鲸小深 desktop pet shell (WPF).
#
# Responsibilities, all on the presentation side of the bridge seam:
#   * one 96x104 transparent, frameless, always-on-top, click-through-free window
#     that renders the sprite sheet and owns every mouse interaction;
#   * one transient popup window that hosts the status bubble, the completion
#     notification and the expanded conversation list;
#   * drag with edge FIXING (never hiding), inertia, multi-monitor seams, and
#     normalized position persistence;
#   * opening DeepSeek Harness through its own launcher.
#
# It never reads the Harness store: the bridge publishes state/pet-state.json and
# this shell only renders it. That is what keeps the privacy boundary in one
# auditable place.

param(
    # Resolved below, not here: $PSScriptRoot is not yet populated while parameter
    # defaults are evaluated, so a default of `Split-Path $PSScriptRoot` silently
    # produces the wrong project root and the shell then cannot find its assets.
    [string]$Root = '',
    [string]$StateFile,
    [string]$ControlFile,
    [double]$Scale = 1.0,
    [int]$ClickThresholdPx = 10,
    # The pet's window title. Production always uses the default.
    #
    # It is a parameter so the watchdog's end-to-end test can run its own throwaway pet
    # without colliding with a real one: the watchdog decides "is a pet already on screen?" by
    # window title, and titles are global to the desktop, so a test could otherwise never reach
    # the start branch. Accepting the parameter here also keeps the shell launchable by the
    # watchdog with a consistent argument list.
    [string]$WindowTitle = '蓝鲸小深',
    # UI language: 'zh-CN' or 'en'. Empty means "detect from the OS UI culture, then
    # the saved config". Switchable at runtime from the right-click menu; the choice
    # is persisted in shell-config.json and forwarded to the bridge through the
    # control file so the snapshot labels follow.
    [string]$Language = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ($Root -eq '') {
    # $PSCommandPath may be relative to the caller's location, so it is resolved
    # before walking up: src/shell/WhalePet.ps1 -> the project root.
    $scriptDir = Split-Path -Parent $PSCommandPath
    if (-not [System.IO.Path]::IsPathRooted($scriptDir)) {
        $scriptDir = Join-Path (Get-Location).Path $scriptDir
    }
    $Root = Split-Path -Parent (Split-Path -Parent $scriptDir)
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing

if (-not ('PetNative' -as [type])) {
    Add-Type -Namespace PetNative -Name Win -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
[DllImport("user32.dll")]
public static extern uint GetDpiForWindow(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern int GetWindowTextLength(IntPtr hWnd);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int count);
[DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
// Which window is under a screen point, and where the cursor is. These let a click be
// resolved without WPF mouse events: the bubble window does not reliably deliver
// them, so the press is read from the OS instead (see Step-PointerClick).
[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
// Raising a background window needs more than SetForegroundWindow: Windows only
// grants a foreground change to the process that owns the foreground, or one that
// has just received input. The pet is deliberately never the foreground process
// (ShowActivated = $false), so the initial call is refused and these alternates are
// needed. `SwitchToThisWindow` is the call the taskbar itself uses, and
// AttachThreadInput temporarily joins this thread's input queue to the foreground
// thread's, which makes the request legal.
[DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
// A synthetic ALT tap clears the foreground lock briefly, which is the standard way
// for a background process to claim the foreground. Used by Invoke-RaiseWindow step 5.
[DllImport("user32.dll")] public static extern void keybd_event(byte vKey, byte scan, uint flags, System.UIntPtr extra);
// Reading the Win32 error explains WHY a window operation was refused: error 5
// (ACCESS_DENIED) means the host blocks cross-process window control, which no amount
// of retrying can overcome. SetLastError(0) is called first so a stale value cannot be
// mistaken for a fresh failure.
[DllImport("kernel32.dll")] public static extern void SetLastError(uint code);
[DllImport("kernel32.dll")] public static extern uint GetLastError();
[DllImport("shcore.dll")]
public static extern int SetProcessDpiAwareness(int value);
// Physical button state. This is the only reliable source in a pure WPF process:
// WinForms' Control.MouseButtons depends on its message filter, which is never
// installed here, so it reports None even while a button is held.
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
'@
}

$script:VK_LBUTTON = 0x01

<#
.SYNOPSIS
    Is the left mouse button physically down right now?
.DESCRIPTION
    `[System.Windows.Forms.Control]::MouseButtons` is not usable in this process.
    It is refreshed by WinForms' message filter, which a pure WPF application never
    installs, so it reports `None` continuously — including while the user is
    holding the button. A watchdog built on it cancels every drag on the next tick,
    which is exactly the "cannot drag at all" symptom.

    `GetAsyncKeyState` reads the physical key state at call time and needs no message
    loop, so it is correct here.
#>
function Test-LeftButtonDown {
    $state = [int]([PetNative.Win]::GetAsyncKeyState($script:VK_LBUTTON))
    return (($state -band 0x8000) -ne 0)
}

# Per-monitor DPI awareness must be claimed before any window exists, otherwise
# WinForms screen coordinates and WPF device-independent units disagree on
# scaled displays and edge fixing lands in the wrong place.
try { [PetNative.Win]::SetProcessDpiAwareness(2) | Out-Null } catch { }

# The geometry helpers sit beside this script, so the module directory comes from
# $PSCommandPath rather than $PSScriptRoot, which is unset during parameter binding.
. (Join-Path (Split-Path -Parent $PSCommandPath) 'PetGeometry.ps1')
# Bilingual UI copy. Dot-sourced for the same reason as PetGeometry: the renderer
# below reaches every label through `T '<key>'` in the language held by
# $script:PetLanguage (see src/shell/PetStrings.ps1 and src/core/i18n.mjs).
. (Join-Path (Split-Path -Parent $PSCommandPath) 'PetStrings.ps1')

# Language precedence: explicit -Language parameter, then the OS UI culture, then
# the saved config (applied later in Restore-Position, before any window exists).
if ($Language -ne '') { Set-PetLanguage -Value $Language }
else { Set-PetLanguage -Value (Get-PetDefaultLanguage) }

# --- constants ---------------------------------------------------------------

$script:BrandBlue = '#4D6BFE'
$script:Root = (Resolve-Path -LiteralPath $Root).Path
if (-not $StateFile) { $StateFile = Join-Path $script:Root 'state\pet-state.json' }
if (-not $ControlFile) { $ControlFile = Join-Path $script:Root 'state\pet-control.json' }
$script:ConfigFile = Join-Path $script:Root 'state\shell-config.json'
$script:SpritePath = Join-Path $script:Root 'assets\whale-sheet.png'
$script:HarnessUrls = @()   # discovered at startup by Find-HarnessUrls

$script:DshExeCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
    (Join-Path ${env:ProgramFiles} 'DeepSeek Harness\DeepSeek Harness.exe')
)

<#
The loopback URLs of running Harness hosts, discovered rather than assumed.

A Harness host serves its own favicon publicly even when its UI needs a session
cookie, so `/favicon.svg` is the identification probe — but the test must be
SPECIFIC. An earlier version accepted any port whose favicon contained `viewBox`,
which is true of nearly every web app: on this machine that matched a local OpenCode
instance (a 512x512 icon) just as readily as Harness, so the pet opened the wrong
application altogether.

The Harness icon is the DeepSeek whale on a `50x50` canvas — the same artwork the
sprite sheet is built from — and its path data opens with `M48.83`. Either signal
identifies it; a 512x512 icon is rejected.

A 401 on `/` is expected and is NOT a reason to skip a port: the Harness UI needs a
session cookie, which the browser already holds. Rejecting the port for that reason
would discard the one host that is actually wanted.
#>
function Find-HarnessUrls {
    $listening = & netstat -ano 2>$null | Select-String -Pattern 'LISTENING' | Select-String -Pattern '127\.0\.0\.1:'
    $ports = New-Object System.Collections.Generic.List[int]
    foreach ($line in $listening) {
        $parts = ($line.ToString().Trim() -split '\s+')
        if ($parts.Count -lt 4) { continue }
        $local = $parts[1]
        $port = 0
        if ([int]::TryParse(($local -split ':')[-1], [ref]$port) -and $port -gt 0) { $ports.Add($port) }
    }

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($port in ($ports | Sort-Object -Unique)) {
        try {
            $probe = Invoke-WebRequest -Uri "http://127.0.0.1:$port/favicon.svg" -UseBasicParsing -TimeoutSec 2
            if ($probe.StatusCode -ne 200) { continue }
            $svg = [string]$probe.Content
            if ($svg -match 'viewBox="0 0 50 50"' -or $svg -match 'M48\.83') {
                $found.Add("http://127.0.0.1:$port/")
                Write-Diag "ports: $port is Harness (whale icon)"
            } else {
                Write-Diag "ports: $port skipped (not the whale icon)"
            }
        } catch { }
    }
    return $found
}

# Sheet cell geometry: each frame is 192x208 source pixels, laid out 8 columns by
# 9 rows. This is the *artwork* size, not the on-screen size.
$script:CellW = 192
$script:CellH = 208

# On-screen size of the pet at 100% scale, carrying the sheet's 192:208 aspect
# ratio. The window is this size; the frame is scaled down to fit it.
#
# 120x130 rather than the brief's 96 px: at 96 the whale artwork itself covers only
# ~68 px, which reads as a smudge next to a modern icon. The pet stays well inside
# the 50-200% zoom range either way (60x65 at 50%, 240x260 at 200%).
$script:BaseW = 120
$script:BaseH = 130

$script:TimerMs = 25
$script:SnapshotMs = 400
$script:CompletionTtlMs = 30000

# --- state -------------------------------------------------------------------

$script:Snapshot = $null
$script:View = $null
$script:SnapshotAt = 0
$script:FrameIndex = 0
$script:FrameAccum = 0
$script:Mood = 'idle'
$script:PinnedMood = $null
$script:PinnedUntil = 0

$script:EvDown = 0
$script:EvMove = 0
$script:EvUp = 0
$script:EvEnter = 0
# Popup (bubble / list) press tracking. The popup's own MouseLeftButtonUp cannot be
# relied on for the same reason the pet's cannot: this window is shown without
# activation, so capture is unreliable and the release can be delivered elsewhere.
# The release is therefore detected by polling the physical button state, exactly as
# the drag does, and these record where the press landed.
$script:PopupPressed = $false
$script:PopupPressX = 0
$script:PopupPressY = 0
$script:PopupPressSessionId = ''
# Unified pointer state for Step-PointerClick: the single place a click on either
# window is resolved. `PointerTarget` is 'pet', 'popup' or '' while the button is held.
$script:PointerWasDown = $false
$script:PointerTarget = ''
$script:PointerSessionId = ''
$script:PointerDownAt = $null
# When a click was last acted on, and on which session. WPF's own mouse events are
# still wired on the pet image, so a single physical click can be noticed twice: once
# by those events and once by the OS polling in Step-PointerClick. Whichever fires
# first wins and the other is suppressed by this timestamp, so Harness is never opened
# twice and a session is never acknowledged twice.
$script:LastClickAt = 0
$script:LastClickSession = ''
$script:Dragging = $false
$script:DragMoved = $false
$script:DragStart = $null
$script:DragOffsetPx = $null
$script:DragLast = $null
$script:Velocity = @{ X = 0.0; Y = 0.0 }
$script:Inertia = $false
$script:TiltDeg = 0.0
$script:Bounce = 0.0

$script:PanelExpanded = $false
$script:PopupMode = 'hidden'   # hidden | bubble | panel
$script:PopupShownAt = 0
$script:PopupPinned = $false
# Fingerprint of the content currently built into the popup, so the visual tree is only
# rebuilt when something it renders actually changed. See Get-PopupFingerprint.
$script:PopupFingerprint = ''
# Set when a content rebuild was skipped because the pet was moving, so it is applied the
# moment the pet stops instead of waiting for the next fingerprint change.
$script:PopupContentDeferred = $false
$script:LastInteraction = 0
$script:Hovered = $false
$script:ActiveSessionId = $null
# Dismissed completions, each as @{ sessionId; at }. The timestamp is what makes the
# acknowledgement apply to ONE completion rather than to the conversation forever:
# the bridge compares it against the completion it holds, so a later reply in the same
# conversation notifies again. Storing bare ids here silenced every future completion
# of a conversation the user had ever clicked.
$script:Acknowledged = New-Object System.Collections.Generic.List[object]
$script:SilentMode = $false
$script:AlwaysOnTop = $true
$script:Exiting = $false

# --- helpers -----------------------------------------------------------------

<#
.SYNOPSIS
    Append one line to the shell's diagnostic log.
.DESCRIPTION
    The click path crosses a process boundary (the shell raises another
    application's window), so when it fails there is nothing on screen to explain
    why: the raise is simply refused and the desktop does not change. A file log is
    the only way to see which step ran and what each call returned.
#>
function Write-Diag {
    param([string]$Message)
    try {
        $path = Join-Path $script:Root 'build\shell-diag.log'
        $line = "{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Message
        [System.IO.File]::AppendAllText($path, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch { }
}

function Get-PetSize {
    param([double]$ForScale = $script:Scale)
    # The window is the pet's on-screen box, not the sprite cell: the frame is
    # scaled to fit, so 100% means the brief's 96x104 and 200% means 192x208.
    $w = [int][Math]::Round($script:BaseW * $ForScale)
    $h = [int][Math]::Round($script:BaseH * $ForScale)
    [pscustomobject]@{ Width = $w; Height = $h; ScaleX = 2.0 * $ForScale; ScaleY = 2.0 * $ForScale }
}

function Get-DpiScale {
    param($Window)
    try {
        $handle = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        if ($handle -ne [IntPtr]::Zero) {
            $dpi = [PetNative.Win]::GetDpiForWindow($handle)
            if ($dpi -gt 0) { return $dpi / 96.0 }
        }
    } catch { }
    return 1.0
}

function Get-WindowRectPx {
    param($Window)
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
    $rect = New-Object PetNative.Win+RECT
    if ([PetNative.Win]::GetWindowRect($handle, [ref]$rect)) {
        return (New-Rect -X $rect.Left -Y $rect.Top -Width ($rect.Right - $rect.Left) -Height ($rect.Bottom - $rect.Top))
    }
    return (New-Rect -X $Window.Left -Y $Window.Top -Width $Window.Width -Height $Window.Height)
}

function Move-WindowPx {
    param($Window, $Rect, [switch]$NoActivate)
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
    $flags = 0x0010 -bor 0x0004   # SWP_NOACTIVATE | SWP_NOZORDER
    [PetNative.Win]::SetWindowPos($handle, [IntPtr]::Zero,
        [int][Math]::Round($Rect.X), [int][Math]::Round($Rect.Y),
        [int][Math]::Round($Rect.Width), [int][Math]::Round($Rect.Height), $flags) | Out-Null
}

<#
.SYNOPSIS
    WPF's device-independent-to-physical factor for a window.
.DESCRIPTION
    The pet reasons in physical pixels — work areas, cursor positions and
    SetWindowPos are all physical — while WPF sizes windows in device-independent
    units. Read the factor from the window's own presentation source, so a scaled
    display does not silently double or halve the pet.
#>
function Get-VisualScale {
    param($Window)
    try {
        $source = [System.Windows.PresentationSource]::FromVisual($Window)
        if ($null -ne $source) {
            $scale = $source.CompositionTarget.TransformToDevice.M11
            if ($scale -gt 0.1) { return $scale }
        }
    } catch { }
    return 1.0
}

<# Size a window in DIP so its physical rectangle matches the requested size. #>
function Set-WindowSizePx {
    param($Window, $Size)
    $scale = Get-VisualScale -Window $Window
    $Window.Width = $Size.Width / $scale
    $Window.Height = $Size.Height / $scale
}

<#
.SYNOPSIS
    Every visible top-level window, with its title and owning process.
.DESCRIPTION
    Used to find an already-open Harness window so a click raises it instead of
    launching a second copy. `Get-Process` cannot answer this: a browser tab and an
    Electron renderer are both just windows owned by a multi-window process.
#>
function Get-AllVisibleWindows {
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [PetNative.Win+EnumWindowsProc] {
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        if (-not [PetNative.Win]::IsWindowVisible($hWnd)) { return $true }
        $length = [PetNative.Win]::GetWindowTextLength($hWnd)
        if ($length -le 0) { return $true }
        $builder = New-Object System.Text.StringBuilder ($length + 2)
        [PetNative.Win]::GetWindowText($hWnd, $builder, $builder.Capacity) | Out-Null
        $owner = 0
        [PetNative.Win]::GetWindowThreadProcessId($hWnd, [ref]$owner) | Out-Null
        $windows.Add([pscustomobject]@{
            Handle = $hWnd
            Title  = $builder.ToString()
            Owner  = [int]$owner
        })
        return $true
    }
    [PetNative.Win]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    return $windows
}

<#
.SYNOPSIS
    Force a window to an exact physical rectangle, correcting placement drift.
.DESCRIPTION
    WPF sizes windows in device-independent units, so the physical rectangle it
    produces can differ from the requested one (a virtualising process or a
    scaled display both do this). The pet's geometry — edge fixing, multi-monitor
    clamping and popup placement — is all in physical pixels, so the rectangle is
    asserted here: SetWindowPos is re-applied with the observed delta folded in,
    which also resizes the window when the DIP conversion was off.
#>
function Move-WindowExact {
    param($Window, $Rect)
    Move-WindowPx -Window $Window -Rect $Rect
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $actual = Get-WindowRectPx -Window $Window
        $dx = $Rect.X - $actual.X
        $dy = $Rect.Y - $actual.Y
        $dw = $Rect.Width - $actual.Width
        $dh = $Rect.Height - $actual.Height
        if ([Math]::Abs($dx) -le 1 -and [Math]::Abs($dy) -le 1 -and
            [Math]::Abs($dw) -le 1 -and [Math]::Abs($dh) -le 1) {
            return $actual
        }
        Move-WindowPx -Window $Window -Rect (New-Rect -X ($Rect.X + $dx) -Y ($Rect.Y + $dy) `
            -Width ($Rect.Width + $dw) -Height ($Rect.Height + $dh))
    }
    return (Get-WindowRectPx -Window $Window)
}

function Get-Screens { @([System.Windows.Forms.Screen]::AllScreens) }

function Save-Config {
    try {
        $screens = Get-Screens
        $rect = Get-WindowRectPx -Window $script:PetWindow
        $screen = Get-DisplayFor -Rect $rect -Screens $screens
        $work = Get-WorkRect -Screen $screen
        $norm = Get-NormalizedPosition -Rect $rect -Work $work
        $payload = [ordered]@{
            schema     = 'dsh-pet-shell-config/1'
            scale      = $script:Scale
            silentMode = $script:SilentMode
            alwaysOnTop = $script:AlwaysOnTop
            language   = (Get-PetLanguage)
            displayKey = $screen.DeviceName
            nx         = $norm.NX
            ny         = $norm.NY
            x          = $rect.X
            y          = $rect.Y
            savedAt    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }
        $json = $payload | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Verbose "save-config failed: $_"
    }
}

function Restore-Position {
    $rect = $null
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $config = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $config.scale) { $script:Scale = [double]$config.scale }
            if ($null -ne $config.silentMode) { $script:SilentMode = [bool]$config.silentMode }
            if ($null -ne $config.alwaysOnTop) { $script:AlwaysOnTop = [bool]$config.alwaysOnTop }
            # The saved choice beats the OS-culture default that ran just after the
            # dot-source; Set-PetLanguage ignores a value it cannot normalise.
            if ($null -ne $config.language) { Set-PetLanguage -Value ([string]$config.language) }

            $screens = Get-Screens
            $target = $screens | Where-Object { $_.DeviceName -eq $config.displayKey } | Select-Object -First 1
            if ($null -eq $target) { $target = [System.Windows.Forms.Screen]::PrimaryScreen }
            $work = Get-WorkRect -Screen $target
            $size = Get-PetSize
            if ($null -ne $config.nx -and $null -ne $config.ny) {
                $rect = Get-DenormalizedRect -NX ([double]$config.nx) -NY ([double]$config.ny) -Work $work `
                    -Size (New-Rect -X 0 -Y 0 -Width $size.Width -Height $size.Height)
            } else {
                $rect = New-Rect -X ([double]$config.x) -Y ([double]$config.y) -Width $size.Width -Height $size.Height
            }
        } catch {
            $rect = $null
        }
    }

    if ($null -eq $rect) {
        # First run: bottom-right of the primary work area, clear of the taskbar.
        $work = Get-WorkRect -Screen ([System.Windows.Forms.Screen]::PrimaryScreen)
        $size = Get-PetSize
        $rect = New-Rect -X ($work.X + $work.Width - $size.Width - 40) -Y ($work.Y + $work.Height - $size.Height - 40) `
            -Width $size.Width -Height $size.Height
    }

    # A stored position is still clamped: a resolution or taskbar change since
    # the last run must never leave the pet off-screen.
    $screen = Get-DisplayFor -Rect $rect -Screens (Get-Screens)
    return (Get-ClampedRect -Rect $rect -Work (Get-WorkRect -Screen $screen)).Rect
}

<#
.SYNOPSIS
    Record that the user dismissed a specific completion.
.DESCRIPTION
    The completion's own timestamp (`at`, from the bubble that was clicked) is stored
    with the session id. That is what limits the dismissal to the reply the user
    actually saw: the bridge only honours an acknowledgement whose timestamp is at
    least as new as the completion it holds, so when the same conversation produces a
    new reply the older acknowledgement no longer applies and the bubble appears
    again.

    Re-acknowledging the same completion is a no-op, so the shell can keep reporting
    it on every control write (which is what stops the reminder flashing back before
    the bridge's next poll).
#>
function Add-Acknowledged {
    param([string]$SessionId, $At)
    if ($SessionId -eq '') { return }

    $stamp = 0
    if ($null -ne $At) { $stamp = [long]$At }

    foreach ($entry in $script:Acknowledged) {
        if ([string]$entry.sessionId -eq $SessionId) {
            # Keep the newest timestamp for this session: acknowledging a newer
            # completion must not be undone by an older report still in flight.
            if ($stamp -gt [long]$entry.at) { $entry.at = $stamp }
            return
        }
    }
    $script:Acknowledged.Add([pscustomobject]@{ sessionId = $SessionId; at = $stamp })
}

<# Was this exact completion already dismissed? #>
function Test-Acknowledged {
    param([string]$SessionId, $At)
    $stamp = 0
    if ($null -ne $At) { $stamp = [long]$At }
    foreach ($entry in $script:Acknowledged) {
        if ([string]$entry.sessionId -ne $SessionId) { continue }
        # at >= the completion means the user saw this one or a later one.
        if ($stamp -le [long]$entry.at) { return $true }
    }
    return $false
}

function Write-Control {
    try {
        # `@($script:Acknowledged)` must NOT be used here.
        #
        # Under `Set-StrictMode -Version Latest`, applying the array-subexpression operator
        # to a generic List[object] throws "Argument types do not match". That single
        # expression made EVERY write of this file fail, and because the failure is caught
        # below and only logged via Write-Verbose, it was completely silent: the pet looked
        # alive, but `pet-control.json` stopped being updated, so the bridge never learned
        # about any click and dismissed conversations kept coming back.
        #
        # Assigning the list directly is valid here: ConvertTo-Json serialises an
        # IEnumerable as a JSON array, which is exactly the shape the bridge expects.
        # `.ToArray()` is the explicit alternative if a real array is ever needed.
        $acknowledged = $script:Acknowledged
        $payload = [ordered]@{
            hovered         = $script:Hovered
            dragging        = $script:Dragging
            activeSessionId = $script:ActiveSessionId
            acknowledged    = $acknowledged
            paused          = $false
            tick            = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            # The shell's UI language. The bridge reads this every poll and emits the
            # next snapshot's labels in the same language, which is how a right-click
            # switch re-renders the bridge-side text within a second.
            language        = (Get-PetLanguage)
            events          = [ordered]@{
                down    = $script:EvDown
                move    = $script:EvMove
                up      = $script:EvUp
                enter   = $script:EvEnter
                dragging = $script:Dragging
                popupPressed = $script:PopupPressed
            }
        }
        $json = $payload | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($ControlFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # This used to be Write-Verbose, which is invisible by default — so a total failure
        # to publish control state looked exactly like success. It is written to the
        # diagnostic log instead, because the bridge silently ignoring every click is a
        # severe, hard-to-diagnose failure that must leave a trace.
        Write-Diag "Write-Control FAILED: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Run a one-shot diagnostic command left in a file by an operator or a test.
.DESCRIPTION
    The click path calls into another process to raise a window, so when it fails
    there is nothing observable: no exception reaches the console (the shell runs a
    WPF message loop), and the desktop simply does not change. Debugging that from
    outside is guesswork, so the shell watches for a small command file and executes
    a whitelisted action inside its own process, logging the outcome.

    This exists for diagnosis only. It performs no action that the UI cannot already
    trigger, and the file is read only if it is present, so its absence is the normal
    state.
#>
function Invoke-ShellCommand {
    $path = Join-Path $script:Root 'state\shell-command.json'
    if (-not (Test-Path -LiteralPath $path)) { return }
    $command = ''
    try {
        $parsed = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $command = [string](Get-Field $parsed 'command' '')
    } catch {
        Write-Diag "command: unreadable: $_"
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        return
    }
    # Consume first, so a command cannot fire twice if it throws.
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if ($command -eq '') { return }

    Write-Diag "command: '$command'"
    switch ($command) {
        'open-harness' {
            try {
                $result = Open-Harness
                Write-Diag "command: Open-Harness returned $result"
            } catch {
                Write-Diag "command: Open-Harness threw: $($_.Exception.Message)"
            }
        }
        'enumerate-windows' {
            try {
                $all = @(Get-AllVisibleWindows)
                Write-Diag "command: enumerated $($all.Count) window(s)"
                foreach ($w in $all) {
                    if ($w.Title -match 'Harness') {
                        Write-Diag "  Harness-titled hwnd=$($w.Handle) iconic=$([PetNative.Win]::IsIconic($w.Handle)) '$($w.Title)'"
                    }
                }
            } catch {
                Write-Diag "command: enumeration threw: $($_.Exception.Message)"
            }
        }
        'popup-state' {
            Write-Diag ("command: popupMode={0} visible={1} bounds=({2},{3}) {4}x{5}" -f `
                $script:PopupMode, $script:PopupWindow.IsVisible, `
                (Get-WindowRectPx -Window $script:PopupWindow).X, (Get-WindowRectPx -Window $script:PopupWindow).Y, `
                (Get-WindowRectPx -Window $script:PopupWindow).Width, (Get-WindowRectPx -Window $script:PopupWindow).Height)
        }
        # Exercise the bubble's click action without a mouse. The sandbox refuses
        # cursor injection, so this is the only way to confirm that acknowledging a
        # session actually clears its bubble — the chain that the user's click relies
        # on. It performs exactly what Invoke-PopupClick would, then reports whether
        # the bubble is gone and whether the bridge echoed the acknowledgement.
        'simulate-bubble-click' {
            $sessionId = ''
            if ($null -ne $script:View -and $null -ne $script:View.bubble) {
                $sessionId = [string](Get-Field $script:View.bubble 'sessionId' '')
            }
            if ($sessionId -eq '') {
                # Fall back to the first listed conversation.
                if ($null -ne $script:View -and @($script:View.entries).Count -gt 0) {
                    $sessionId = [string](Get-Field $script:View.entries[0] 'id' '')
                }
            }
            Write-Diag "command: simulate-bubble-click sessionId='$sessionId'"
            if ($sessionId -eq '') { break }
            $before = $script:PopupMode
            Invoke-PopupClick -SessionId $sessionId
            Start-Sleep -Milliseconds 400
            # Hoisted: a bare `-join` inside `-f` arguments does not parse.
            $ackText = (@($script:Acknowledged | ForEach-Object {
                '{0}@{1}' -f ([string]$_.sessionId).Substring(0, [Math]::Min(8, ([string]$_.sessionId).Length)), $_.at
            }) -join ',')
            Write-Diag ("command: popupMode {0} -> {1}; bubble now {2}; acknowledged=[{3}]" -f `
                $before, $script:PopupMode,
                $(if ($null -eq $script:View.bubble) { 'null' } else { $script:View.bubble.label }),
                $ackText)
        }
        # Shut the pet down through its own code path, which is the same one the right-click
        # menu uses: it saves the position and writes the quit marker that tells a running
        # watchdog to leave the pet closed.
        #
        # This exists because the shell may be running OUTSIDE the sandbox (that is the normal
        # case once autostart is installed), where Stop-Process cannot reach it. The command
        # channel is the one route that works from either side.
        'quit' {
            Write-Diag 'command: quit requested; stopping the pet'
            Stop-Pet
        }
        default { Write-Diag "command: unknown '$command'" }
    }
}

function Open-Harness {
    <#
    .SYNOPSIS
        Bring the DeepSeek Harness DESKTOP application to the front.
    .DESCRIPTION
        The target is the desktop app, not a browser tab. Its window is an Electron
        window titled `... — DeepSeek Harness`; a browser tab would instead end in the
        browser's own name, which is how the two are told apart.

        The desktop executable is therefore the primary mechanism, and that is not a
        fallback: Electron holds a single-instance lock and, on a second launch,
        focuses its own primary window. That is the officially supported way to raise
        it and it needs no foreground rights, unlike `SetForegroundWindow`, which
        Windows refuses for a background process. Measured here: all seven candidate
        foreground methods (SetForegroundWindow, SwitchToThisWindow, AttachThreadInput,
        a synthetic ALT tap, ShowWindow, minimise-then-restore, and
        SetWindowPos-with-SHOWWINDOW) are refused once the target genuinely is not
        foreground — see tools\Test-ForegroundLock.ps1.

        Order:
          1. the desktop executable — raises the app, or starts it if it is not running;
          2. raising the window directly, which succeeds only when the pet happens to be
             the foreground process;
          3. the loopback web UI, ONLY when no desktop installation exists. A browser
             tab is not what was asked for, so it is deliberately the last resort.

        There is no way to focus one specific conversation: Harness registers no
        per-session deep link (its protocol handler accepts only `dsh://open`, and only
        on macOS), the SPA never reads the URL, and its API exposes no "activate
        session" call. See README for the evidence.
    #>
    Write-Diag 'Open-Harness: entered'

    # 1. The desktop application.
    #
    # The window is raised FIRST, before launching the executable, and this ordering
    # matters. Launching it is not what brings the window forward: Electron's
    # single-instance handler focuses its window only if the OS lets it, and a
    # measured run showed the launch alone produced no change at all in z-order or
    # foreground state. What actually works is calling SetForegroundWindow while this
    # process still holds foreground rights — and a click grants exactly that, because
    # Windows extends foreground rights to whatever received the last input event. So
    # the click itself is what makes the raise succeed, and the raise must be the
    # first thing attempted.
    $raised = Show-HarnessWindow
    Write-Diag "Open-Harness: direct raise returned $raised"

    foreach ($candidate in $script:DshExeCandidates) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            Write-Diag "Open-Harness: not installed at $candidate"
            continue
        }
        try {
            Start-Process -FilePath $candidate | Out-Null
            Write-Diag "Open-Harness: launched the desktop app ($candidate)"
        } catch {
            Write-Diag "Open-Harness: launching the desktop app failed: $_"
        }
        break
    }

    # Confirm, and retry briefly if the raise has not landed yet: the foreground
    # change is applied asynchronously, so a check taken in the same instant can miss
    # a raise that is on its way.
    if (-not (Test-HarnessForeground)) {
        for ($attempt = 0; $attempt -lt 8; $attempt++) {
            Start-Sleep -Milliseconds 150
            Show-HarnessWindow | Out-Null
            if (Test-HarnessForeground) { break }
        }
    }

    if (Test-HarnessForeground) {
        Write-Diag 'Open-Harness: the desktop window is foreground'
        return $true
    }
    Write-Diag 'Open-Harness: the desktop window is open but could not be made foreground'

    # 2. Only if there is no desktop installation at all does a browser tab come into
    #    play. A tab is not the desktop app, which is what was asked for.
    if (-not (Test-Path -LiteralPath $script:DshExeCandidates[0]) -and $script:HarnessUrls.Count -gt 0) {
        foreach ($url in $script:HarnessUrls) {
            try {
                Start-Process -FilePath $url | Out-Null
                Write-Diag "Open-Harness: no desktop app; opened $url in the browser"
                return $true
            } catch {
                Write-Diag "Open-Harness: opening $url failed: $_"
            }
        }
    }

    # The executable was launched (or the window raised), so the user's request was
    # acted on even if focus did not transfer; report success so the caller does not
    # treat a focus shortfall as a total failure.
    return (Test-Path -LiteralPath $script:DshExeCandidates[0])
}

<#
.SYNOPSIS
    Is a DeepSeek Harness window the foreground window right now?
.DESCRIPTION
    Distinguishes the desktop app from a browser tab by title suffix: Electron appends
    its own name (`— DeepSeek Harness`), whereas a browser appends the browser's.
#>
function Test-HarnessForeground {
    $foreground = [PetNative.Win]::GetForegroundWindow()
    foreach ($window in Get-AllVisibleWindows) {
        if ($window.Handle -ne $foreground) { continue }
        if ($window.Title -match 'Harness' -and $window.Title -notmatch '蓝鲸小深') {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Raise an already-open Harness window, if one can be found.
.DESCRIPTION
    Matched on window title. Neither the Electron renderer (loaded over file://)
    nor a browser tab exposes its URL through a window title, so this cannot target
    a conversation — it exists so the click does not spawn a duplicate window when
    the UI is already on screen.

    Raising a background window is not a single call. `SetForegroundWindow` is
    refused unless the caller owns the foreground or has just received input, and
    the pet is shown without activation precisely so that clicking it does not steal
    the user's focus — so it is never the foreground process, and the naive call
    fails. The sequence that works:

      1. restore it if minimised, and WAIT for the un-minimise to be observable —
         SetForegroundWindow cannot succeed while the window is still iconic, and
         ShowWindow returns before the restore has landed;
      2. try SetForegroundWindow;
      3. if that was refused, retry with this thread's input queue attached to the
         foreground thread's, which makes the request legal;
      4. fall back to SwitchToThisWindow, the call the taskbar itself uses.

    The return value reports whether the window is genuinely foreground now, checked
    rather than assumed: an earlier version returned `$true` unconditionally, so the
    caller believed the raise had worked, skipped every fallback, and the click
    appeared to do nothing.
#>
function Show-HarnessWindow {
    $candidates = @(Get-AllVisibleWindows | Where-Object {
        $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深'
    })
    # The desktop window first. Electron titles end in `— DeepSeek Harness`, while a
    # browser tab ends in the browser's own name; ordering by that suffix means the
    # desktop app is raised in preference to a tab of the same UI.
    $candidates = @($candidates | Sort-Object @{ Expression = {
        if ($_.Title -match '—\s*DeepSeek Harness\s*$') { 0 } else { 1 }
    } })
    Write-Diag "Show-HarnessWindow: $($candidates.Count) candidate(s)"
    foreach ($window in $candidates) {
        Write-Diag ("  candidate hwnd={0} iconic={1} title='{2}'" -f $window.Handle,
            [PetNative.Win]::IsIconic($window.Handle), $window.Title)
        if (Invoke-RaiseWindow -Handle $window.Handle) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    Make a window foreground, trying each method that can work without input rights.
.DESCRIPTION
    Returns $true only when the window is observed to be foreground, so the caller
    can fall through to another strategy instead of believing a refused call worked.
#>
function Invoke-RaiseWindow {
    param([IntPtr]$Handle)

    # 1. Try the direct call FIRST, before anything that sleeps.
    #
    #    The right to set the foreground is granted to whichever process received the
    #    last input event, and it does not last long. Clicking the pet is that input, so
    #    this call can succeed — but only if it happens promptly. An earlier version
    #    restored a minimised window first, waiting up to a second in 25 ms steps, and
    #    spent the grant before ever asking. Order matters more than elegance here.
    #    SetLastError(0) clears any stale value so the code below cannot mistake an old
    #    error for a fresh one.
    [PetNative.Win]::SetLastError(0)
    [PetNative.Win]::SetForegroundWindow($Handle) | Out-Null
    if (Test-IsForeground -Handle $Handle) { return $true }

    # Record WHY it was refused, because the error code separates two situations and
    # both share one consequence:
    #
    #   5   ERROR_ACCESS_DENIED    — the host refuses cross-process window control.
    #   203 ERROR_ENVVAR_NOT_FOUND — what Windows' foreground-lock refusal surfaces as
    #                                in this environment; observed here from inside the
    #                                shell. AttachThreadInput fails as well, so every
    #                                method below is refused too.
    #
    # In both cases this process cannot raise another application's window: a click can
    # launch Harness but cannot bring an existing window forward. Verified from inside the
    # shell with tools\Test-RealClickScenario.ps1, which steals the foreground first so
    # the check cannot pass merely because the window was already in front.
    $raiseError = [PetNative.Win]::GetLastError()
    if ($raiseError -eq 5 -or $raiseError -eq 203) {
        Write-Diag "  raise: refused (GetLastError=$raiseError). The host blocks cross-process"
        Write-Diag '  raise: window control, so no method below can raise the Harness window from'
        Write-Diag '  raise: this process. The executable is still launched, which focuses the'
        Write-Diag '  raise: window on an unrestricted desktop; for reliable raising, start the'
        Write-Diag '  raise: pet from a normal terminal (scripts\start-pet.cmd).'
    } elseif ($raiseError -ne 0) {
        Write-Diag "  raise: SetForegroundWindow refused, GetLastError=$raiseError"
    }

    # 2. Restore if minimised, and wait for it: a minimised window cannot be made
    #    foreground, and ShowWindow does not wait. ShowWindow's own return value
    #    reports the PREVIOUS visibility, so IsIconic is the honest check.
    $wasIconic = [PetNative.Win]::IsIconic($Handle)
    if ($wasIconic) {
        [PetNative.Win]::ShowWindow($Handle, 9) | Out-Null   # SW_RESTORE
        for ($wait = 0; $wait -lt 40; $wait++) {
            if (-not [PetNative.Win]::IsIconic($Handle)) { break }
            Start-Sleep -Milliseconds 25
        }
        # The restore itself may have brought it forward; check before spending more
        # time on the heavier methods below.
        [PetNative.Win]::SetForegroundWindow($Handle) | Out-Null
        if (Test-IsForeground -Handle $Handle) { return $true }
    }

    # 3. Retry with the input queues joined, which lifts the foreground lock.
    $foreground = [PetNative.Win]::GetForegroundWindow()
    $ownerPid = 0
    $foregroundThread = [PetNative.Win]::GetWindowThreadProcessId($foreground, [ref]$ownerPid)
    $self = [PetNative.Win]::GetCurrentThreadId()
    $attached = $false
    try {
        if ($foregroundThread -ne 0 -and $foregroundThread -ne $self) {
            $attached = [PetNative.Win]::AttachThreadInput($self, $foregroundThread, $true)
        }
        Write-Diag "  raise: attach=$attached fgThread=$foregroundThread self=$self"
        [PetNative.Win]::ShowWindow($Handle, 5) | Out-Null          # SW_SHOW
        [PetNative.Win]::SetForegroundWindow($Handle) | Out-Null
        if (Test-IsForeground -Handle $Handle) {
            Write-Diag '  raise: SetForegroundWindow worked after attaching'
            return $true
        }

        # 4. SwitchToThisWindow is what the taskbar uses; it has different rules.
        [PetNative.Win]::SwitchToThisWindow($Handle, $true)
        Start-Sleep -Milliseconds 120
        if (Test-IsForeground -Handle $Handle) {
            Write-Diag '  raise: SwitchToThisWindow worked'
            return $true
        }

        # 5. A synthetic ALT tap. Windows treats a key press as user activity and
        #    clears the foreground lock for a moment afterwards, which is the standard
        #    fix for a process that cannot claim the foreground. It is invisible and
        #    harmless (ALT alone does nothing), and it is only reached when everything
        #    above was refused.
        [PetNative.Win]::keybd_event(0x12, 0, 0, [System.UIntPtr]::Zero)              # VK_MENU down
        Start-Sleep -Milliseconds 60
        [PetNative.Win]::keybd_event(0x12, 0, 0x0002, [System.UIntPtr]::Zero)         # VK_MENU up
        Start-Sleep -Milliseconds 120
        [PetNative.Win]::SetForegroundWindow($Handle) | Out-Null
        if (Test-IsForeground -Handle $Handle) {
            Write-Diag '  raise: worked after a synthetic ALT tap'
            return $true
        }

        # 6. Minimise then restore. The restore of a minimised window is performed by
        #    the shell itself, so it lands in front without this process needing any
        #    foreground rights at all.
        [PetNative.Win]::ShowWindow($Handle, 6) | Out-Null                             # SW_MINIMIZE
        Start-Sleep -Milliseconds 250
        [PetNative.Win]::ShowWindow($Handle, 9) | Out-Null                             # SW_RESTORE
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            Start-Sleep -Milliseconds 80
            if (Test-IsForeground -Handle $Handle) {
                Write-Diag '  raise: worked after minimise/restore'
                return $true
            }
        }

        # A short retry loop: the foreground change is applied asynchronously, so a
        # single immediate check can miss a raise that did succeed.
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            [PetNative.Win]::SetForegroundWindow($Handle) | Out-Null
            Start-Sleep -Milliseconds 80
            if (Test-IsForeground -Handle $Handle) {
                Write-Diag "  raise: succeeded on retry $attempt"
                return $true
            }
        }
        if ($wasIconic) { Write-Diag '  raise: refused, but the window was restored' }
        else { Write-Diag '  raise: every method refused' }
    } catch {
        Write-Diag "  raise: threw: $_"
        return $false
    } finally {
        if ($attached) {
            try { [PetNative.Win]::AttachThreadInput($self, $foregroundThread, $false) | Out-Null } catch { }
        }
    }
    return (Test-IsForeground -Handle $Handle)
}

<# Is this window the foreground window right now? #>
function Test-IsForeground {
    param([IntPtr]$Handle)
    return ([PetNative.Win]::GetForegroundWindow() -eq $Handle)
}

# --- rendering ---------------------------------------------------------------

<#
.SYNOPSIS
    Read a field from a deserialized snapshot object, with a fallback.
.DESCRIPTION
    The snapshot is JSON produced by a separate process, so the shell can be handed
    a document from a *newer or older* bridge than the code it is running — which is
    exactly what happens when the bridge is left running across a reducer change.
    Under StrictMode a missing property is a fatal error rather than a blank line,
    and the throw happens inside the animation loop, taking the whole pet down.
    Reading through this helper keeps a field-shape mismatch to a missing label
    instead of a dead whale.
#>
function Get-Field {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    $value = $property.Value
    if ($null -eq $value) { return $Default }
    return $value
}

function New-CroppedFrames {
    param($Source, [int]$Columns, [int]$Rows, [int]$CellW, [int]$CellH)
    $frames = @{}
    for ($row = 0; $row -lt $Rows; $row++) {
        $list = New-Object System.Collections.Generic.List[object]
        for ($col = 0; $col -lt $Columns; $col++) {
            $list.Add((New-Object System.Windows.Media.Imaging.CroppedBitmap($Source,
                (New-Object System.Windows.Int32Rect(($col * $CellW), ($row * $CellH), $CellW, $CellH)))))
        }
        $frames[$row] = $list
    }
    $frames
}

function New-TextBlock {
    param([string]$Text, [double]$Size = 12, [string]$Color = '#0F1115', [string]$Weight = 'Normal')
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $Text
    $block.FontSize = $Size
    $block.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
    $block.Foreground = New-Object System.Windows.Media.SolidColorBrush(([System.Windows.Media.ColorConverter]::ConvertFromString($Color)))
    # FontWeight exposes its presets as static properties; the type converter
    # offers neither ConvertFromString nor ConvertFromInvariantString here.
    $block.FontWeight = switch ($Weight) {
        'Bold' { [System.Windows.FontWeights]::Bold }
        'SemiBold' { [System.Windows.FontWeights]::SemiBold }
        'Medium' { [System.Windows.FontWeights]::Medium }
        'Light' { [System.Windows.FontWeights]::Light }
        default { [System.Windows.FontWeights]::Normal }
    }
    $block.TextTrimming = 'CharacterEllipsis'
    $block
}

function New-Card {
    param([double]$Radius = 10, [string]$Background = '#FFFFFF', [double]$Alpha = 0.99)
    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = New-Object System.Windows.CornerRadius($Radius)
    # Near-opaque by default: the shell draws onto a transparent window, so a
    # translucent card lets the desktop through and washes out the label text it
    # exists to make readable.
    $brush = New-Object System.Windows.Media.SolidColorBrush(([System.Windows.Media.ColorConverter]::ConvertFromString($Background)))
    $brush.Opacity = $Alpha
    $border.Background = $brush
    $border.Padding = New-Object System.Windows.Thickness(10, 7, 10, 7)
    # A hairline border keeps the card's edge legible against a light desktop.
    $border.BorderBrush = New-Object System.Windows.Media.SolidColorBrush(([System.Windows.Media.ColorConverter]::ConvertFromString('#E3E7F3')))
    $border.BorderThickness = New-Object System.Windows.Thickness(1)
    $border
}

function New-Dot {
    param([string]$Color, [double]$Size = 8)
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = $Size
    $dot.Height = $Size
    $dot.Fill = New-Object System.Windows.Media.SolidColorBrush(([System.Windows.Media.ColorConverter]::ConvertFromString($Color)))
    $dot.VerticalAlignment = 'Center'
    $dot
}

<#
.SYNOPSIS
    Badge colour for a session status.
.DESCRIPTION
    Mirrors dotColor() in src/core/pet-reducer.mjs: green done, blue running,
    yellow waiting, red error. The reducer supplies a colour for list entries; the
    bubble only carries a status, so the mapping is repeated here rather than
    threading a colour through the snapshot.
#>
function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'done' { '#22C55E' }
        'working' { $script:BrandBlue }
        'thinking' { $script:BrandBlue }
        'approval' { '#F59E0B' }
        'question' { '#F59E0B' }
        'error' { '#EF4444' }
        default { '#9CA3AF' }
    }
}

# --- popup content -----------------------------------------------------------

function Build-BubbleContent {
    <#
    .SYNOPSIS
        Render the two-layer status stack plus the notification column.
    .DESCRIPTION
        Top layer is the current session's status card; the card behind it is the
        `+N` backer, offset down-right and drawn first so the stack reads as two
        stacked plates. Completion / error / approval notices are separate rows
        pinned above the pet, each clickable, exactly as the brief requires.
    #>
    param($View, [double]$Width)
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Width = $Width - 16

    if ($null -ne $View.notifications -and @($View.notifications).Count -gt 0) {
        foreach ($notice in @($View.notifications)) {
            $row = New-Card -Radius 8 -Background $(if ((Get-Field $notice "kind" "done") -eq 'error') { '#FEF2F2' } else { '#ECFDF5' })
            $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
            $row.Tag = (Get-Field $notice "sessionId" "")
            $row.Cursor = 'Hand'
            $inner = New-Object System.Windows.Controls.StackPanel
            $inner.Orientation = 'Horizontal'
            $glyph = if ((Get-Field $notice "kind" "done") -eq 'error') { '⛔' } else { '✅' }
            $head = New-TextBlock -Text "$glyph $((Get-Field $notice "name" (T 'sessionFallback')))" -Size 12.5 -Weight 'SemiBold' `
                -Color $(if ((Get-Field $notice "kind" "done") -eq 'error') { '#B91C1C' } else { '#047857' })
            $inner.Children.Add($head) | Out-Null
            $inner.Children.Add((New-TextBlock -Text ("  " + (Get-Field $notice "ageText" "")) -Size 11 -Color '#6B7280')) | Out-Null
            $row.Child = $inner
            $stack.Children.Add($row) | Out-Null
        }
    }

    # One dialog box per surfaced conversation.
    #
    # Collapsed (the default) shows only the highest-ranked one, so the pet stays
    # glanceable. Expanding shows every parallel task's own box, each with its own live
    # status — a running task counts its elapsed time up, a finished task keeps its box
    # and counts its age up ("刚刚" -> "5 分钟前") until the user clicks it.
    #
    # Each box is built by the same function, so a box looks identical whether it is the
    # only one or the fourth, and clicking any of them opens that conversation.
    $boxes = @()
    if ($script:PanelExpanded) { $boxes = @($View.bubbles) }
    elseif ($null -ne $View.bubble) { $boxes = @($View.bubble) }

    $boxIndex = 0
    foreach ($bubble in $boxes) {
        $boxIndex++
        $others = [int](Get-Field $bubble "others" 0)

        if ($others -gt 0 -and $boxIndex -eq 1) {
            # The badge says what it counts. A bare "+5" was ambiguous — it read as five
            # running tasks even when only one was working — so the label names the count
            # and breaks it down by state. The whole strip is a button: clicking it
            # expands the list, which is what the number is inviting the user to do.
            $othersRunning = [int](Get-Field $bubble "othersRunning" 0)
            $othersFinished = [int](Get-Field $bubble "othersFinished" 0)
            # The breakdown is composed in the shell's language: `T` gives the format
            # strings, `-f` fills the counts, and the joiner keeps the sentence natural
            # in both languages ("1 个进行中，4 个已完成" / "1 running, 4 done").
            $parts = @()
            if ($othersRunning -gt 0) { $parts += ((T 'othersRunning') -f $othersRunning) }
            if ($othersFinished -gt 0) { $parts += ((T 'othersFinished') -f $othersFinished) }
            $detail = if ($parts.Count -gt 0) { ((T 'othersDetail') -f ($parts -join (T 'othersJoin'))) } else { "" }

            $backer = New-Card -Radius 10 -Background '#E8ECFF' -Alpha 0.99
            $backer.Margin = New-Object System.Windows.Thickness(6, 0, 0, 0)
            $backer.Cursor = 'Hand'
            $backer.Tag = 'action:toggle-panel'
            $backerRow = New-Object System.Windows.Controls.StackPanel
            $backerRow.Orientation = 'Horizontal'
            $backerRow.HorizontalAlignment = 'Right'
            $backerRow.Children.Add((New-TextBlock -Text ((T 'othersBadge') -f $others, $detail) -Size 11 -Weight 'SemiBold' -Color $script:BrandBlue)) | Out-Null
            $backer.Child = $backerRow
            $backer.Padding = New-Object System.Windows.Thickness(10, 4, 10, 4)
            $stack.Children.Add($backer) | Out-Null
        }

        $card = New-Card -Radius 10 -Background '#FFFFFF'
        # Only the first box overlaps the `+N` backer; later ones sit in a plain column.
        $card.Margin = if ($boxIndex -eq 1) {
            New-Object System.Windows.Thickness(0, -4, 0, 0)
        } else {
            New-Object System.Windows.Thickness(0, 4, 0, 0)
        }
        $card.Cursor = 'Hand'
        $card.Tag = (Get-Field $bubble "sessionId" "")
        $body = New-Object System.Windows.Controls.StackPanel

        $topRow = New-Object System.Windows.Controls.StackPanel
        $topRow.Orientation = 'Horizontal'
        # The bubble carries a status, not a colour: the badge colour is the same
        # mapping the reducer uses for list entries (green done, blue running,
        # yellow waiting, red error).
        $topRow.Children.Add((New-Dot -Color (Get-StatusColor -Status (Get-Field $bubble "status" "idle")))) | Out-Null
        $topRow.Children.Add((New-TextBlock -Text ("  " + (Get-Field $bubble "name" "")) -Size 11.5 -Color '#6B7280')) | Out-Null
        $body.Children.Add($topRow) | Out-Null

        $labelColor = switch ((Get-Field $bubble "status" "idle")) {
            'done' { '#047857' }
            'error' { '#B91C1C' }
            'approval' { '#B45309' }
            'question' { '#B45309' }
            default { '#0F1115' }
        }
        $body.Children.Add((New-TextBlock -Text (Get-Field $bubble "label" "") -Size 13.5 -Weight 'SemiBold' -Color $labelColor)) | Out-Null

        # The meta line updates on every snapshot (the shell rebuilds it each time), so a
        # running task shows its elapsed time ticking and a finished one shows how long
        # ago it finished. That is what keeps a retained box informative rather than a
        # frozen "任务完成" that looks abandoned.
        $metaParts = @()
        if ($null -ne (Get-Field $bubble "progressText")) { $metaParts += (Get-Field $bubble "progressText") }
        if ($null -ne (Get-Field $bubble "elapsedText")) { $metaParts += (Get-Field $bubble "elapsedText") }
        if ($null -ne (Get-Field $bubble "ageText")) { $metaParts += (Get-Field $bubble "ageText") }
        if ((Get-Field $bubble "longTask" $false)) { $metaParts += (T 'longTask') }
        $toolName = [string](Get-Field $bubble "lastToolName" "")
        if ($toolName -ne '') { $metaParts += $toolName }
        if ($metaParts.Count -gt 0) {
            $body.Children.Add((New-TextBlock -Text ($metaParts -join '  ·  ') -Size 11 -Color '#6B7280')) | Out-Null
        }

        # The hover detail belongs to the box it describes, not to whichever box happens
        # to be first: with several boxes on screen, attaching it to `bubble` alone would
        # print one conversation's tool count under another's name.
        if ($null -ne $View.hover -and $boxIndex -eq 1) {
            # Reads are hoisted: nested double quotes are not legal inside a
            # PowerShell interpolated string.
            $hoverLabel = Get-Field $View.hover 'label' ''
            $hoverElapsed = Get-Field $View.hover 'elapsedText' ''
            $hoverTools = Get-Field $View.hover 'runningTools' 0
            $hoverLine = (T 'hoverLine') -f $hoverLabel, $hoverElapsed, $hoverTools
            $body.Children.Add((New-TextBlock -Text $hoverLine -Size 10.5 -Color $script:BrandBlue)) | Out-Null
        }

        $card.Child = $body
        $stack.Children.Add($card) | Out-Null
    }

    $expand = New-Object System.Windows.Controls.Button
    $expand.Content = if ($script:PanelExpanded) { (T 'expandCollapse') } else { (T 'expandAll') }
    $expand.FontSize = 11
    $expand.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
    $expand.Foreground = New-Object System.Windows.Media.SolidColorBrush(([System.Windows.Media.ColorConverter]::ConvertFromString($script:BrandBlue)))
    # Transparent, not null: a null Background is not hit-testable in WPF, so the button's
    # own padding would not register and the click would land on whatever is behind it.
    $expand.Background = [System.Windows.Media.Brushes]::Transparent
    $expand.BorderThickness = New-Object System.Windows.Thickness(0)
    $expand.Padding = New-Object System.Windows.Thickness(2, 3, 2, 1)
    $expand.HorizontalAlignment = 'Left'
    $expand.Cursor = 'Hand'
    # The tag is what the OS-level hit test returns, so this control is reachable even
    # though the popup does not deliver WPF click events. The Add_Click below is kept for
    # hosts that DO deliver them; Invoke-PopupHit is idempotent with it because toggling
    # twice in one press cannot happen — only one of the two paths fires per click.
    $expand.Tag = 'action:toggle-panel'
    $expand.Add_Click({ Toggle-Panel })
    $stack.Children.Add($expand) | Out-Null

    if ($script:PanelExpanded) {
        $list = New-Object System.Windows.Controls.StackPanel
        $list.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
        $entries = @($View.entries)
        if ($entries.Count -eq 0) {
            $list.Children.Add((New-TextBlock -Text (T 'noConversations') -Size 11.5 -Color '#6B7280')) | Out-Null
        }
        $index = 0
        foreach ($entry in $entries) {
            if ($index -ge 8) { break }
            $index++
            $row = New-Card -Radius 8 -Background $(if ((Get-Field $entry "isActive" $false)) { '#EEF2FF' } else { '#F9FAFB' })
            $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 3)
            $row.Cursor = 'Hand'
            $row.Tag = (Get-Field $entry "id" "")
            $row.Padding = New-Object System.Windows.Thickness(8, 5, 8, 5)

            $grid = New-Object System.Windows.Controls.StackPanel
            $line1 = New-Object System.Windows.Controls.StackPanel
            $line1.Orientation = 'Horizontal'
            $line1.Children.Add((New-Dot -Color (Get-Field $entry "dot" "#9CA3AF") -Size 7)) | Out-Null
            $nameColor = if ((Get-Field $entry "unacknowledged" $false)) { '#047857' } else { '#0F1115' }
            $line1.Children.Add((New-TextBlock -Text ("  " + (Get-Field $entry "name" "")) -Size 12 -Weight 'SemiBold' -Color $nameColor)) | Out-Null
            if ((Get-Field $entry "unacknowledged" $false)) {
                $line1.Children.Add((New-TextBlock -Text (T 'unreadMark') -Size 10 -Color '#22C55E')) | Out-Null
            }
            $grid.Children.Add($line1) | Out-Null

            # The meta line carries the status label, progress, running time and
            # freshness. An idle session has nothing but freshness to report, so
            # its "待机" label is dropped rather than repeated next to the age.
            $meta = @()
            if ((Get-Field $entry "status" "idle") -ne 'idle') { $meta += (Get-Field $entry "label" "") }
            if ($null -ne (Get-Field $entry "progressText")) { $meta += ((T 'progressPrefix') -f (Get-Field $entry "progressText")) }
            if ($null -ne (Get-Field $entry "elapsedText")) { $meta += (Get-Field $entry "elapsedText") }
            $meta += (Get-Field $entry "ageText" "")
            $grid.Children.Add((New-TextBlock -Text ($meta -join '  ·  ') -Size 10.5 -Color '#6B7280')) | Out-Null

            $row.Child = $grid
            $list.Children.Add($row) | Out-Null
        }
        $stack.Children.Add($list) | Out-Null
    }

    $stack
}

# --- popup window ------------------------------------------------------------

<#
.SYNOPSIS
    A cheap fingerprint of everything the popup's content depends on.
.DESCRIPTION
    Rebuilding the popup means clearing its children and constructing the whole visual
    tree again, which is expensive enough that doing it 40 times a second makes the pet
    stutter. That is exactly what happened: the animation tick rebuilt the popup on every
    frame while the DATA changed only once a second, so the panel visibly flickered as it
    was destroyed and recreated.

    The fix is to rebuild only when this string changes. It covers every field the
    renderer reads, so a change that would alter a single character of the panel produces a
    different fingerprint; anything not listed here is also not rendered, so it cannot
    matter.

    Deliberately NOT a hash of the whole view: `now` and the derived `ageText`/`elapsedText`
    tick continuously, and including them would defeat the purpose. They are represented by
    their rendered text, which changes at most once a second.
#>
function Get-PopupFingerprint {
    param($View)
    if ($null -eq $View) { return '' }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("expanded=$($script:PanelExpanded)")
    $parts.Add("silent=$($script:SilentMode)")
    # The language is part of what the content depends on: every shell-side label is
    # drawn through `T`, so a switch must rebuild even when the snapshot data is
    # unchanged (the bridge's labels change on the next poll, but not instantly).
    $parts.Add("lang=$(Get-PetLanguage)")

    foreach ($bubble in @($View.bubbles)) {
        $parts.Add(('b|{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f `
            (Get-Field $bubble 'sessionId' ''), (Get-Field $bubble 'label' ''),
            (Get-Field $bubble 'status' ''), (Get-Field $bubble 'progressText' ''),
            (Get-Field $bubble 'elapsedText' ''), (Get-Field $bubble 'ageText' ''),
            (Get-Field $bubble 'others' 0), (Get-Field $bubble 'lastToolName' ''),
            (Get-Field $bubble 'longTask' $false)))
    }
    foreach ($notice in @($View.notifications)) {
        $parts.Add(('n|{0}|{1}|{2}|{3}' -f `
            (Get-Field $notice 'sessionId' ''), (Get-Field $notice 'kind' ''),
            (Get-Field $notice 'ageText' ''), (Get-Field $notice 'name' '')))
    }
    if ($script:PanelExpanded) {
        foreach ($entry in @($View.entries)) {
            $parts.Add(('e|{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f `
                (Get-Field $entry 'id' ''), (Get-Field $entry 'name' ''),
                (Get-Field $entry 'status' ''), (Get-Field $entry 'progressText' ''),
                (Get-Field $entry 'ageText' ''), (Get-Field $entry 'elapsedText' ''),
                (Get-Field $entry 'unacknowledged' $false)))
        }
    }
    if ($null -ne $View.hover) {
        $parts.Add(('h|{0}|{1}|{2}' -f `
            (Get-Field $View.hover 'label' ''), (Get-Field $View.hover 'elapsedText' ''),
            (Get-Field $View.hover 'runningTools' 0)))
    }
    return ($parts -join "`n")
}

<#
.SYNOPSIS
    Rebuild the popup's content if it changed, and re-anchor it to the pet.
.DESCRIPTION
    Two independent jobs, deliberately separated:

      * **content** is rebuilt only when `Get-PopupFingerprint` changes, so the visual tree
        is not destroyed and recreated on every frame;
      * **position** is re-measured every time, because it is cheap and the pet moves — the
        panel must follow it immediately.

    The earlier version did both on every call, and the main animation tick calls this 40
    times a second; rebuilding the tree that often is what made the pet stutter and the
    panel flash while dragging.
#>
function Update-Popup {
    param($View, [switch]$Force)
    # Width is fixed by design; height is measured from the content. Both are
    # converted to WPF's DIP units so the popup ends up the intended physical
    # size on a scaled display.
    $bubbleWidthPx = 240.0
    if ($script:PanelExpanded) { $bubbleWidthPx = 280.0 }

    $visual = Get-VisualScale -Window $script:PopupWindow
    $fingerprint = Get-PopupFingerprint -View $View
    $contentStale = $Force -or $fingerprint -ne $script:PopupFingerprint

    # Never rebuild the visual tree while the pet is moving.
    #
    # Clearing and reconstructing the children is expensive, and the panel travels with the
    # pet, so a rebuild during a drag is visible as the panel flashing and the motion
    # stuttering. The fingerprint changes about once a second even when nothing the user
    # cares about happened, because `elapsedText`/`ageText` tick — so without this the
    # stutter happened on almost every drag.
    #
    # The text is simply one tick behind for the duration of the drag (a fraction of a
    # second, since inertia settles quickly) and is corrected on the next update once the
    # pet is still again. A brief stale timestamp is invisible; a flashing panel is not.
    if ($contentStale -and ($script:Dragging -or $script:Inertia) -and -not $Force) {
        $contentStale = $false
        # Remember that the content is behind, so the rebuild happens as soon as the pet
        # stops rather than waiting for the next fingerprint change (which might not come
        # for a second, leaving stale text on screen).
        $script:PopupContentDeferred = $true
    }

    if ($contentStale) {
        $content = Build-BubbleContent -View $View -Width ($bubbleWidthPx / $visual)
        $script:PopupHost.Children.Clear()
        $script:PopupHost.Children.Add($content) | Out-Null
        $script:PopupFingerprint = $fingerprint
        $script:PopupContentDeferred = $false

        $script:PopupWindow.Width = $bubbleWidthPx / $visual
        $script:PopupWindow.SizeToContent = 'Height'
        $script:PopupWindow.UpdateLayout()
    }
    $petRect = Get-WindowRectPx -Window $script:PetWindow
    $screen = Get-DisplayFor -Rect $petRect -Screens (Get-Screens)
    $work = Get-WorkRect -Screen $screen
    $heightPx = [Math]::Max(48, $script:PopupWindow.ActualHeight * $visual)
    $size = New-Rect -X 0 -Y 0 -Width $bubbleWidthPx -Height $heightPx
    $placement = Get-PopupPlacement -AnchorRect $petRect -Size $size -Work $work -Gap 8

    # Show first: a hidden window has no presentation source, so anything that
    # depends on the rendered size would otherwise be measured at zero.
    if (-not $script:PopupWindow.IsVisible) {
        $script:PopupWindow.Show()
        $script:PopupWindow.UpdateLayout()
        $heightPx = [Math]::Max(48, $script:PopupWindow.ActualHeight * (Get-VisualScale -Window $script:PopupWindow))
        $size = New-Rect -X 0 -Y 0 -Width $bubbleWidthPx -Height $heightPx
        $placement = Get-PopupPlacement -AnchorRect $petRect -Size $size -Work $work -Gap 8
    }
    Move-WindowExact -Window $script:PopupWindow -Rect $placement.Rect
    if ($script:PopupMode -ne 'popup') {
        # Start the 30 s completion-reminder clock when the bubble first appears,
        # not on every refresh, so a live task cannot keep resetting it.
        $script:PopupShownAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
    $script:PopupMode = 'popup'
}

<#
.SYNOPSIS
    Move the popup to follow the pet, without touching its content.
.DESCRIPTION
    Called on every frame while the pet is being dragged or is gliding, where the content
    is unchanged and only the anchor moved. It measures the current size and re-applies the
    placement, which is a single SetWindowPos — cheap enough for every frame, unlike
    rebuilding the visual tree.

    This exists because the drag path used to call the full `Update-Popup`: that cleared
    and reconstructed the children up to 40 times a second, which is what made dragging
    stutter and the panel flash.
#>
function Move-PopupToPet {
    if ($script:PopupMode -eq 'hidden' -or $null -eq $script:PopupWindow) { return }
    if (-not $script:PopupWindow.IsVisible) { return }

    $petRect = Get-WindowRectPx -Window $script:PetWindow
    $screen = Get-DisplayFor -Rect $petRect -Screens (Get-Screens)
    $work = Get-WorkRect -Screen $screen
    $visual = Get-VisualScale -Window $script:PopupWindow
    $bubbleWidthPx = 240.0
    if ($script:PanelExpanded) { $bubbleWidthPx = 280.0 }
    $heightPx = [Math]::Max(48, $script:PopupWindow.ActualHeight * $visual)
    $size = New-Rect -X 0 -Y 0 -Width $bubbleWidthPx -Height $heightPx
    $placement = Get-PopupPlacement -AnchorRect $petRect -Size $size -Work $work -Gap 8
    Move-WindowExact -Window $script:PopupWindow -Rect $placement.Rect
}

function Hide-Popup {
    if ($script:PopupWindow.IsVisible) { $script:PopupWindow.Hide() }
    $script:PopupMode = 'hidden'
    $script:PopupPinned = $false
    # Forget the content fingerprint so the next appearance rebuilds from scratch: the
    # window was hidden, so whatever was in it is no longer valid.
    $script:PopupFingerprint = ''
}

function Toggle-Panel {
    $script:PanelExpanded = -not $script:PanelExpanded
    $script:LastInteraction = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    # Forced: expanding or collapsing changes both the width and the whole content, and the
    # width is part of the built layout rather than of the fingerprint.
    if ($null -ne $script:View) { Update-Popup -View $script:View -Force }
}

function Show-BubbleIfNeeded {
    param($View)
    if ($script:Exiting) { return }

    # Suppress only the specific completion the user dismissed. The bridge learns about
    # an acknowledgement on its next poll (up to a second later), so without this the
    # bubble flashes back for a moment and the click reads as having failed.
    #
    # The comparison is by TIMESTAMP, not by session alone. A session-keyed check would
    # hide the conversation forever: once the user had dismissed one reply, every later
    # reply in that same conversation would be suppressed too, so the bubble could never
    # come back. Comparing the completion's own `at` against the dismissed timestamp
    # means a newer reply is shown again while the exact completion the user clicked
    # stays hidden.
    if ($script:Acknowledged.Count -gt 0 -and $null -ne $View) {
        # Applied to the whole list, not just the front bubble: with several boxes on
        # screen, dismissing one conversation must not clear the others.
        #
        # Note the field is `completionAt` (the reducer's name for "which finished turn
        # is this"). An earlier version read `at`, which does not exist on a bubble, so
        # the comparison silently used 0 and the suppression never matched.
        $keptBubbles = @()
        foreach ($item in @($View.bubbles)) {
            $itemRunning = (Get-Field $item 'status' '') -eq 'working'
            $itemId = [string](Get-Field $item 'sessionId' '')
            $itemAt = [long](Get-Field $item 'completionAt' 0)
            if (-not $itemRunning -and (Test-Acknowledged -SessionId $itemId -At $itemAt)) { continue }
            $keptBubbles += $item
        }
        $View.bubbles = $keptBubbles
        $View.bubble = if ($keptBubbles.Count -gt 0) { $keptBubbles[0] } else { $null }

        if ($null -ne $View.notifications -and @($View.notifications).Count -gt 0) {
            $View.notifications = @($View.notifications | Where-Object {
                -not (Test-Acknowledged -SessionId ([string](Get-Field $_ 'sessionId' '')) -At (Get-Field $_ 'at' 0))
            })
        }
        if ($null -ne $View.entries -and @($View.entries).Count -gt 0) {
            $View.entries = @($View.entries | Where-Object {
                $entryStatus = [string](Get-Field $_ 'status' '')
                if ($entryStatus -eq 'working') { return $true }
                # `completionAt` is the reducer's field name; reading `at` here would
                # always compare against 0 and never suppress anything.
                -not (Test-Acknowledged -SessionId ([string](Get-Field $_ 'id' '')) -At (Get-Field $_ 'completionAt' 0))
            })
        }
    }

    $hasBubble = (@($View.bubbles).Count -gt 0) -or (@($View.notifications).Count -gt 0)
    if ($script:SilentMode -and -not $script:PanelExpanded -and @($View.notifications).Count -eq 0) {
        if ($script:PopupMode -ne 'hidden') { Hide-Popup }
        return
    }
    if (-not $hasBubble -and -not $script:PanelExpanded) {
        if ($script:PopupMode -ne 'hidden') { Hide-Popup }
        return
    }

    # There is deliberately no expiry here. The bubble is visible exactly while the
    # reducer says there is something to show, and a finished conversation stays
    # listed until the user clicks it. An earlier version hid the bubble 30 s after
    # it appeared, which silently contradicted that retention: the reducer kept the
    # completion and the view stopped drawing it. Dismissal is now a single rule —
    # the click acknowledges the session, and the next snapshot has nothing to show.
    Update-Popup -View $View
}

# --- animation ---------------------------------------------------------------

function Get-MoodRow {
    param([string]$Mood)
    if ($null -ne $script:Snapshot -and $null -ne $script:Snapshot.sprite) {
        $states = $script:Snapshot.sprite.states
        if ($null -ne $states.$Mood) { return [int]$states.$Mood.row }
    }
    switch ($Mood) {
        'thinking' { 1 }
        'working' { 2 }
        'waiting' { 3 }
        'celebrate' { 4 }
        'error' { 5 }
        'drag' { 6 }
        'longtask' { 7 }
        default { 0 }
    }
}

function Update-Frame {
    $row = Get-MoodRow -Mood $script:Mood
    $frames = $script:Frames[$row]
    if ($null -eq $frames -or $frames.Count -eq 0) { return }
    $script:FrameIndex = ($script:FrameIndex + 1) % $frames.Count
    $script:PetImage.Source = $frames[$script:FrameIndex]
}

# --- snapshot polling --------------------------------------------------------

function Read-Snapshot {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (($now - $script:SnapshotAt) -lt $script:SnapshotMs) { return }
    $script:SnapshotAt = $now
    try {
        $raw = [System.IO.File]::ReadAllText($StateFile, [System.Text.Encoding]::UTF8)
        $snapshot = $raw | ConvertFrom-Json
    } catch {
        $script:PetImage.Opacity = 0.55
        return
    }
    $script:PetImage.Opacity = 1.0
    $script:Snapshot = $snapshot
    $script:View = $snapshot.view

    # A fresh completion is the one moment the pet takes over the mood, so the
    # celebration animation is actually seen instead of being outranked by the
    # next session that starts working.
    $previousMood = $script:Mood
    $mood = [string]$script:View.mood
    if ($mood -ne $previousMood) {
        $script:FrameIndex = 0
        $script:FrameAccum = 0
        if ($mood -eq 'celebrate' -or $mood -eq 'error') {
            $script:PinnedMood = $mood
            $script:PinnedUntil = $now + 1600
        }
    }
    $script:Mood = $mood
    if ($null -ne $script:PinnedMood) {
        if ($now -lt $script:PinnedUntil) { $script:Mood = $script:PinnedMood }
        else { $script:PinnedMood = $null }
    }
    if ($script:Dragging) { $script:Mood = 'drag' }
}

# --- drag --------------------------------------------------------------------
#
# The drag is driven from the animation tick, not from mouse events. Only the
# initial press is taken from WPF; movement and release are read from the OS each
# frame. That is deliberate:
#
#   * MouseMove stops arriving as soon as `Mouse.Capture` fails to hold, and this
#     window is shown without activation (ShowActivated = $false) so clicking the
#     pet does not steal focus from the user's editor — which is exactly the case
#     where capture is unreliable. A drag built on MouseMove moves a few pixels and
#     then sticks.
#   * MouseUp is delivered to whatever is under the cursor once capture is lost, so
#     the drag never ends.
#
# `[System.Windows.Forms.Cursor]::Position` and `GetAsyncKeyState` are direct Win32
# reads with no message-loop dependency, so polling them from the tick is reliable
# regardless of capture and regardless of which window has focus.

function Start-Drag {
    param($Source, $EventArgs)
    $script:LastInteraction = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $script:Inertia = $false
    $script:Velocity = @{ X = 0.0; Y = 0.0 }

    # The grab offset is where inside the window the press landed, in physical
    # pixels. It is derived from the window rectangle and the cursor position rather
    # than from the event, so it agrees exactly with what Step-Drag reads later.
    $rect = Get-WindowRectPx -Window $script:PetWindow
    $cursor = [System.Windows.Forms.Cursor]::Position
    $script:DragOffsetPx = @{ X = $cursor.X - $rect.X; Y = $cursor.Y - $rect.Y }
    $script:DragStart = @{ X = $cursor.X; Y = $cursor.Y }
    $script:DragLast = @{ Time = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); X = $rect.X; Y = $rect.Y }
    $script:DragMoved = $false
    $script:Dragging = $true
    $script:Mood = 'drag'
    # Best-effort only: the tick does not depend on capture succeeding.
    try { [System.Windows.Input.Mouse]::Capture($script:PetWindow) } catch { }
    if ($null -ne $EventArgs) { $EventArgs.Handled = $true }
}

<#
.SYNOPSIS
    Advance a drag one frame, and finish it when the button is released.
.DESCRIPTION
    Called every tick while `Dragging`, and also from the MouseMove handler when
    those events do arrive (which makes the motion smoother). Both callers compute
    the same rectangle from the same inputs, so the two paths are idempotent.
#>
function Step-Drag {
    if (-not $script:Dragging) { return }

    if (-not (Test-LeftButtonDown)) {
        # Released. The click decision belongs to Step-PointerClick, which is the
        # single authority on presses: it knows which window the press started on and
        # fires the click itself. Firing it here as well would open Harness twice for
        # one press.
        End-Drag -Source $null -EventArgs $null
        return
    }

    $cursor = [System.Windows.Forms.Cursor]::Position
    $rect = Get-WindowRectPx -Window $script:PetWindow
    $desired = New-Rect -X ($cursor.X - $script:DragOffsetPx.X) -Y ($cursor.Y - $script:DragOffsetPx.Y) `
        -Width $rect.Width -Height $rect.Height

    $screens = Get-Screens
    $screen = Get-DisplayFor -Rect $desired -Screens $screens
    # Edge fixing: the window is pinned flush to whichever physical edge it
    # crossed, so pulling further outward only slides it along that edge. The
    # clamp uses the monitor's WORK area, so the taskbar counts as an edge too.
    $clamped = Get-ClampedRect -Rect $desired -Work (Get-WorkRect -Screen $screen)
    if ($clamped.Rect.X -ne $rect.X -or $clamped.Rect.Y -ne $rect.Y) {
        Move-WindowPx -Window $script:PetWindow -Rect $clamped.Rect
    }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $dt = [Math]::Max(1, $now - $script:DragLast.Time)
    if ($dt -ge 12) {
        $script:Velocity = @{
            X = ($clamped.Rect.X - $script:DragLast.X) / $dt * 1000.0
            Y = ($clamped.Rect.Y - $script:DragLast.Y) / $dt * 1000.0
        }
        $script:DragLast = @{ Time = $now; X = $clamped.Rect.X; Y = $clamped.Rect.Y }
    }

    # The body swings with the cursor's horizontal direction while dragged.
    $script:TiltDeg = [Math]::Min(14, [Math]::Max(-14, $script:Velocity.X / 110.0))

    # Distance travelled from the press point, measured in screen pixels. The 10 px
    # threshold is what keeps "drag" and "open Harness" distinct.
    $moved = [Math]::Sqrt([Math]::Pow($cursor.X - $script:DragStart.X, 2) +
                          [Math]::Pow($cursor.Y - $script:DragStart.Y, 2))
    if ($moved -gt $ClickThresholdPx) { $script:DragMoved = $true }

    # Reposition only. The content has not changed while the pointer moves, and rebuilding
    # the visual tree here (up to 40 times a second) is what made dragging stutter and the
    # panel flash. See Move-PopupToPet.
    Move-PopupToPet
}

function End-Drag {
    param($Source, $EventArgs)
    if (-not $script:Dragging) { return }
    $script:Dragging = $false
    try { [System.Windows.Input.Mouse]::Capture($null) } catch { }

    $speed = [Math]::Sqrt($script:Velocity.X * $script:Velocity.X + $script:Velocity.Y * $script:Velocity.Y)
    if ($speed -ge 60) {
        $script:Inertia = $true
        $script:DragLast = @{ Time = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); X = 0; Y = 0 }
    } else {
        # A gentle placement: no glide, just one soft settle.
        $script:Velocity = @{ X = 0.0; Y = 0.0 }
        $script:Bounce = 1.0
        $script:TiltDeg = 0.0
        Save-Config
    }
    # Read the mood through the safe accessor: End-Drag can fire before the first
    # snapshot arrives, and a missing field there would throw inside the handler.
    $script:Mood = Get-Field $script:View 'mood' 'idle'
    if ($null -ne $EventArgs) { $EventArgs.Handled = $true }
}

function Step-Inertia {
    if (-not $script:Inertia) { return }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $dt = [Math]::Min(48, [Math]::Max(1, $now - $script:DragLast.Time))
    $script:DragLast = @{ Time = $now; X = 0; Y = 0 }

    $rect = Get-WindowRectPx -Window $script:PetWindow
    $step = Get-InertiaStep -Rect $rect -VelocityX $script:Velocity.X -VelocityY $script:Velocity.Y `
        -DtMs $dt -Screens (Get-Screens)
    Move-WindowPx -Window $script:PetWindow -Rect $step.Rect
    $script:Velocity = @{ X = $step.VelocityX; Y = $step.VelocityY }
    $script:TiltDeg = $step.TiltDeg
    if ($step.Bounce) { $script:Bounce = 1.0 }

    if ($step.Settled) {
        $script:Inertia = $false
        $script:TiltDeg = 0.0
        # Position is only persisted once the glide has finished, so a restart
        # restores where the pet actually came to rest.
        Save-Config
    }
    # Reposition only, for the same reason as the drag path.
    Move-PopupToPet
}

# --- interaction -------------------------------------------------------------

<#
.SYNOPSIS
    Remove one conversation's box from the local view.
.DESCRIPTION
    Applied immediately after a click so the box disappears on the next frame instead of
    waiting up to a second for the bridge to echo the acknowledgement — that gap is what
    made a click look like it had failed.

    Only the clicked conversation is removed, and only when it is NOT running: a running
    task keeps its box, because live work should stay visible until it actually finishes.
    Every other conversation is untouched, so parallel tasks keep their own boxes.
#>
function Remove-BubbleLocally {
    param([string]$SessionId)
    if ($null -eq $script:View -or $SessionId -eq '') { return }

    $kept = @()
    foreach ($item in @($script:View.bubbles)) {
        $itemId = [string](Get-Field $item 'sessionId' '')
        $itemStatus = [string](Get-Field $item 'status' '')
        if ($itemId -eq $SessionId -and $itemStatus -ne 'working') { continue }
        $kept += $item
    }
    $script:View.bubbles = $kept
    $script:View.bubble = if ($kept.Count -gt 0) { $kept[0] } else { $null }

    if ($null -ne $script:View.entries) {
        $script:View.entries = @($script:View.entries | Where-Object {
            $entryId = [string](Get-Field $_ 'id' '')
            $entryStatus = [string](Get-Field $_ 'status' '')
            if ($entryStatus -eq 'working') { return $true }
            $entryId -ne $SessionId
        })
    }
}

<#
.SYNOPSIS
    Should this click be acted on, or is it the second report of one press?
.DESCRIPTION
    A physical click can be noticed by two independent observers: WPF's mouse events on
    the pet image, and the OS polling in Step-PointerClick. Both are wired on purpose —
    the events are a fast path when they arrive, the polling is the reliable path when
    they do not (which is normal for the bubble, and was observed for the pet) — so the
    first to arrive records the click here and the other is dropped.

    Without this, one click opens Harness twice and acknowledges the session twice,
    which is visible as a duplicated browser tab or a flicker.
#>
function Test-ClickIsNew {
    param([string]$SessionId = '')
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (($now - $script:LastClickAt) -lt 500 -and $SessionId -eq $script:LastClickSession) {
        Write-Diag "click: duplicate for '$SessionId' suppressed"
        return $false
    }
    $script:LastClickAt = $now
    $script:LastClickSession = $SessionId
    return $true
}

function Invoke-PetClick {
    <#
    .SYNOPSIS
        Clicking the pet itself: open Harness, and clear the conversation it shows.
    .DESCRIPTION
        The press/release decision and the drag-versus-click threshold both live in
        Step-PointerClick, which calls this only for a genuine click on the pet
        window, so there is nothing to re-check here.

        Clicking the pet also acknowledges whatever conversation is on the bubble, so
        a single click cannot open Harness and leave the reminder sitting there —
        which is what "click the pet to jump, and the bubble clears" means in practice.
    #>
    # The press/release decision and the drag-versus-click threshold live in
    # Step-PointerClick, which calls this for a genuine click on the pet window. The
    # dedup guard is here as well because WPF's own mouse events also call this.
    if (-not (Test-ClickIsNew)) { return }

    $sessionId = ''
    $completionAt = 0
    if ($null -ne $script:View) {
        $sessionId = [string](Get-Field $script:View 'primaryId' '')
        if ($null -ne $script:View.bubble) {
            $completionAt = [long](Get-Field $script:View.bubble 'completionAt' 0)
        }
    }
    $script:LastClickSession = $sessionId
    Write-Diag "Invoke-PetClick: sessionId='$sessionId' completionAt=$completionAt"

    if ($sessionId -ne '') {
        $script:ActiveSessionId = $sessionId
        # Record the completion's own timestamp, so only the reply the user saw is
        # dismissed; a later reply in the same conversation notifies again.
        Add-Acknowledged -SessionId $sessionId -At $completionAt
        # Drop that conversation's box locally, and only that one: parallel tasks keep
        # their own boxes on screen.
        Remove-BubbleLocally -SessionId $sessionId
        Hide-Popup
    }

    $script:LastInteraction = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Write-Control
    Open-Harness | Out-Null
}

function Show-ContextMenu {
    $menu = New-Object System.Windows.Controls.ContextMenu
    $menu.FontFamily = New-Object System.Windows.Media.FontFamily('Microsoft YaHei UI, Segoe UI')
    $menu.FontSize = 12

    $open = New-Object System.Windows.Controls.MenuItem
    $open.Header = (T 'menuOpenHarness')
    $open.Add_Click({ Open-Harness | Out-Null })
    $menu.Items.Add($open) | Out-Null

    $toggle = New-Object System.Windows.Controls.MenuItem
    $toggle.Header = if ($script:PanelExpanded) { (T 'menuCollapseList') } else { (T 'menuExpandList') }
    $toggle.Add_Click({ Toggle-Panel })
    $menu.Items.Add($toggle) | Out-Null

    $menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null

    $scaleMenu = New-Object System.Windows.Controls.MenuItem
    $scaleMenu.Header = (T 'menuScale')
    foreach ($preset in @(0.5, 0.75, 1.0, 1.25, 1.5, 2.0)) {
        $item = New-Object System.Windows.Controls.MenuItem
        $item.Header = "$([int]($preset * 100))%"
        $item.IsCheckable = $true
        $item.IsChecked = ([Math]::Abs($script:Scale - $preset) -lt 0.01)
        $item.Tag = $preset
        $item.Add_Click({ param($s, $e) Set-Scale -Value ([double]$s.Tag) })
        $scaleMenu.Items.Add($item) | Out-Null
    }
    $menu.Items.Add($scaleMenu) | Out-Null

    # The language switch. The items name their own language ("中文" / "English") so
    # the menu stays readable in both, and picking one re-renders immediately: the
    # config records the choice, the control file forwards it to the bridge, and the
    # popup is forced to rebuild because its fingerprint covers data, not UI language.
    $langMenu = New-Object System.Windows.Controls.MenuItem
    $langMenu.Header = (T 'menuLanguage')
    foreach ($option in @(@('zh-CN', '中文'), @('en', 'English'))) {
        $langItem = New-Object System.Windows.Controls.MenuItem
        $langItem.Header = $option[1]
        $langItem.IsCheckable = $true
        $langItem.IsChecked = ((Get-PetLanguage) -eq $option[0])
        $langItem.Tag = $option[0]
        $langItem.Add_Click({
            param($s, $e)
            Set-PetLanguage -Value ([string]$s.Tag)
            Save-Config
            Write-Control
            $script:PopupFingerprint = ''
            if ($null -ne $script:View -and $script:PopupMode -ne 'hidden') {
                Update-Popup -View $script:View -Force
            }
        })
        $langMenu.Items.Add($langItem) | Out-Null
    }
    $menu.Items.Add($langMenu) | Out-Null

    $silent = New-Object System.Windows.Controls.MenuItem
    $silent.Header = (T 'menuSilent')
    $silent.IsCheckable = $true
    $silent.IsChecked = $script:SilentMode
    $silent.Add_Click({
        $script:SilentMode = -not $script:SilentMode
        if ($script:SilentMode) { Hide-Popup }
        Save-Config
    })
    $menu.Items.Add($silent) | Out-Null

    $top = New-Object System.Windows.Controls.MenuItem
    $top.Header = (T 'menuAlwaysOnTop')
    $top.IsCheckable = $true
    $top.IsChecked = $script:AlwaysOnTop
    $top.Add_Click({
        $script:AlwaysOnTop = -not $script:AlwaysOnTop
        $script:PetWindow.Topmost = $script:AlwaysOnTop
        $script:PopupWindow.Topmost = $script:AlwaysOnTop
        Save-Config
    })
    $menu.Items.Add($top) | Out-Null

    $menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
    $exit = New-Object System.Windows.Controls.MenuItem
    $exit.Header = (T 'menuExit')
    $exit.Add_Click({ Stop-Pet })
    $menu.Items.Add($exit) | Out-Null

    $menu.IsOpen = $true
    $menu
}

function Set-Scale {
    param([double]$Value)
    $script:Scale = [Math]::Min(2.0, [Math]::Max(0.5, $Value))
    $size = Get-PetSize
    $rect = Get-WindowRectPx -Window $script:PetWindow
    $desired = New-Rect -X $rect.X -Y $rect.Y -Width $size.Width -Height $size.Height
    $screen = Get-DisplayFor -Rect $desired -Screens (Get-Screens)
    $clamped = Get-ClampedRect -Rect $desired -Work (Get-WorkRect -Screen $screen)

    # The sprite covers the whole window in device units, so the UI elements are
    # sized in DIP against WPF's own factor while the window keeps the requested
    # physical size.
    $visual = Get-VisualScale -Window $script:PetWindow
    $dipW = $size.Width / $visual
    $dipH = $size.Height / $visual
    $script:PetImage.Width = $dipW
    $script:PetImage.Height = $dipH
    $script:PetHost.Width = $dipW
    $script:PetHost.Height = $dipH
    $script:TiltTransform.CenterX = $dipW / 2
    $script:TiltTransform.CenterY = $dipH / 2

    Set-WindowSizePx -Window $script:PetWindow -Size $size
    Move-WindowExact -Window $script:PetWindow -Rect $clamped.Rect
    Save-Config
    if ($null -ne $script:View) { Update-Popup -View $script:View }
}

function Stop-Pet {
    $script:Exiting = $true
    Save-Config

    # Tell a running watchdog to leave the pet closed.
    #
    # Without this, 退出桌宠 would look broken when the watchdog is installed: the pet would
    # vanish and then reappear a few seconds later, because "Harness is running and no pet is
    # on screen" is exactly the condition the watchdog fixes. The watchdog removes this marker
    # once the pet asks to start again (or when Harness is closed), so the suppression is not
    # permanent.
    try {
        $marker = Join-Path $script:Root 'state\pet-quit'
        [System.IO.File]::WriteAllText($marker, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()).ToString(),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }

    try { $script:ControlTimer.Stop() } catch { }
    try { $script:TickTimer.Stop() } catch { }
    try { $script:PopupWindow.Close() } catch { }
    try { $script:PetWindow.Close() } catch { }
    [System.Windows.Application]::Current.Shutdown()
}

# --- window construction -----------------------------------------------------

function Build-PetWindow {
    param($InitialRect, $Size)

    $window = New-Object System.Windows.Window
    $window.WindowStyle = 'None'
    $window.AllowsTransparency = $true
    # A layered (AllowsTransparency) window is hit-tested PER PIXEL BY ALPHA: a
    # pixel with alpha 0 is transparent to the mouse, so the click goes to whatever
    # is behind the pet. A sprite is transparent everywhere except the whale, so a
    # fully transparent background made almost the whole window unclickable —
    # hovering it produced no mouse events at all and dragging could never start.
    #
    # Alpha 1 is the fix: invisible to the eye, non-zero to the hit test, so every
    # pixel of the pet window is a valid drag/click target.
    $window.Background = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.Color]::FromArgb(1, 0, 0, 0))
    $window.ShowInTaskbar = $false
    $window.ResizeMode = 'NoResize'
    $window.Topmost = $script:AlwaysOnTop
    $window.WindowStartupLocation = 'Manual'
    $window.ShowActivated = $false
    $window.Title = $WindowTitle
    Set-WindowSizePx -Window $window -Size $Size
    $window.Left = $InitialRect.X
    $window.Top = $InitialRect.Y

    $surface = New-Object System.Windows.Controls.Grid
    # Element sizes are DIP (WPF scales them to device units itself); the window
    # size is physical, which is why the two use different conversions.
    $visual = Get-VisualScale -Window $window
    $dipW = $Size.Width / $visual
    $dipH = $Size.Height / $visual

    $surface.Width = $dipW
    $surface.Height = $dipH
    $surface.Background = [System.Windows.Media.Brushes]::Transparent

    $image = New-Object System.Windows.Controls.Image
    $image.Width = $dipW
    $image.Height = $dipH
    $image.Stretch = 'Fill'
    # BitmapScalingMode is an attached property, so it is set through the static
    # RenderOptions API rather than through a property on the Image itself.
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($image, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    $image.SnapsToDevicePixels = $true

    $transform = New-Object System.Windows.Media.RotateTransform(0.0)
    $transform.CenterX = $dipW / 2
    $transform.CenterY = $dipH / 2
    $image.RenderTransform = $transform

    # The pet itself is the interaction target: a click opens Harness, a drag
    # moves it, a right click opens the menu, and Ctrl+wheel scales it.
    #
    # The press is the only input the drag needs from WPF: movement and release are
    # polled from the OS by `Step-Drag` on every tick. MouseMove is still wired so
    # that motion is smooth when those events do arrive, and MouseLeftButtonUp is
    # wired as the fast path for a clean release. Both endpoints are idempotent with
    # the tick, so whichever notices first wins and the other becomes a no-op.
    $image.Add_MouseLeftButtonDown({
        param($s, $e)
        $script:EvDown++
        Start-Drag -Source $s -EventArgs $e
    })
    $image.Add_MouseMove({
        param($s, $e)
        $script:EvMove++
        Step-Drag
        $e.Handled = $true
    })
    $image.Add_MouseLeftButtonUp({
        param($s, $e)
        $script:EvUp++
        # Only ends the drag. The click itself is fired by Step-PointerClick, which
        # owns the press/release decision for both windows.
        if ($script:Dragging) { End-Drag -Source $s -EventArgs $e }
    })
    $image.Add_MouseRightButtonUp({ param($s, $e) Show-ContextMenu | Out-Null; $e.Handled = $true })
    $image.Add_MouseEnter({
        $script:EvEnter++
        $script:Hovered = $true
        $script:LastInteraction = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Write-Control
        if ($null -ne $script:View) { Show-BubbleIfNeeded -View $script:View }
    })
    $image.Add_MouseLeave({
        $script:Hovered = $false
        Write-Control
    })
    $image.Add_MouseWheel({
        param($s, $e)
        if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) {
            Set-Scale -Value ($script:Scale + $(if ($e.Delta -gt 0) { 0.1 } else { -0.1 }))
            $e.Handled = $true
        }
    })

    $surface.Children.Add($image) | Out-Null
    $window.Content = $surface

    $script:PetWindow = $window
    $script:PetImage = $image
    $script:PetHost = $surface
    $script:TiltTransform = $transform
    $window
}

function Build-PopupWindow {
    $window = New-Object System.Windows.Window
    $window.WindowStyle = 'None'
    $window.AllowsTransparency = $true
    # Same per-pixel-alpha hit-test rule as the pet window: a transparent background
    # would let clicks near the card edges fall through to the application behind.
    # Alpha 1 keeps the popup invisible but solid to the mouse.
    $window.Background = New-Object System.Windows.Media.SolidColorBrush(
        [System.Windows.Media.Color]::FromArgb(1, 0, 0, 0))
    $window.ShowInTaskbar = $false
    $window.ResizeMode = 'NoResize'
    $window.Topmost = $script:AlwaysOnTop
    $window.WindowStartupLocation = 'Manual'
    $window.ShowActivated = $false
    $window.Title = ($WindowTitle + (T 'titleSuffix'))
    $window.Width = 240
    $window.SizeToContent = 'Height'

    $surface = New-Object System.Windows.Controls.StackPanel
    $surface.Margin = New-Object System.Windows.Thickness(8)
    # A null Background is NOT hit-testable in WPF: the panel's own area (its 8 px
    # margin and the gaps between cards) would silently swallow no clicks at all,
    # so a press in those areas never reached the handler below. Brushes.Transparent
    # is hit-testable while still invisible, which is what makes the whole popup
    # clickable rather than only the pixels its children happen to cover.
    $surface.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Content = $surface

    # Clicking a card opens that conversation; the pointer staying on the popup
    # keeps the 30 s completion reminder from expiring underneath the user.
    $surface.Add_MouseEnter({
        $script:Hovered = $true
        $script:LastInteraction = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Write-Control
    })
    $surface.Add_MouseLeave({ $script:Hovered = $false; Write-Control })

    # The bubble's click is resolved by Step-PointerClick from the OS (cursor position
    # plus the physical button state), NOT from these WPF events: this window is shown
    # without activation, and in practice it delivered no press at all, so a handler
    # here would simply never run. The StackPanel's Transparent background above is
    # still required, so that the pixels between cards are part of the window that
    # `WindowFromPoint` reports as the bubble.
    $script:PopupWindow = $window
    $script:PopupHost = $surface
    $window
}

<#
.SYNOPSIS
    Walk up from the clicked element to the card that carries a session id.
.DESCRIPTION
    The bubble and the list rows are built from nested panels, so the element under
    the pointer is rarely the one holding the tag. This finds the nearest ancestor
    that has one, which is how a click on the label text still resolves to its
    conversation.
#>
function Get-CardSessionId {
    param($Source)
    $element = $Source
    while ($null -ne $element -and $null -eq $element.Tag) {
        try { $element = [System.Windows.Media.VisualTreeHelper]::GetParent($element) } catch { return '' }
    }
    if ($null -eq $element -or $null -eq $element.Tag) { return '' }
    return [string]$element.Tag
}

<#
.SYNOPSIS
    Act on a bubble / list click: open Harness and dismiss that conversation.
.DESCRIPTION
    Order matters. The session is acknowledged and the popup hidden FIRST, so the
    dismissal is immediate and cannot be undone by whatever raising Harness does to
    focus. The acknowledgement is what makes the bubble leave permanently: the
    bridge marks the completion as read, so the next snapshot simply has nothing to
    show for it.

    Note that `Acknowledged` is a list the shell owns and the bridge reads, while
    `ActiveSessionId` is used for a different purpose (reporting which conversation
    the pet considers current), so both are updated.
#>
function Invoke-PopupClick {
    param([string]$SessionId)

    $script:PopupPressed = $false
    Write-Diag "Invoke-PopupClick: sessionId='$SessionId'"
    if ($SessionId -eq '') {
        Write-Diag 'Invoke-PopupClick: no session on the clicked card; ignoring'
        return
    }
    # One physical press can be reported by both the WPF fast path and the polling
    # path, so the second report is dropped here.
    if (-not (Test-ClickIsNew -SessionId $SessionId)) { return }

    # The completion this card is about, so the dismissal applies to it alone. Found by
    # searching the bubble list — not just the front bubble — because with parallel tasks
    # on screen the clicked box may be any of them.
    $completionAt = 0
    if ($null -ne $script:View) {
        foreach ($item in @($script:View.bubbles)) {
            if ([string](Get-Field $item 'sessionId' '') -eq $SessionId) {
                $completionAt = [long](Get-Field $item 'completionAt' 0)
                break
            }
        }
        if ($completionAt -eq 0 -and $null -ne $script:View.entries) {
            foreach ($entry in @($script:View.entries)) {
                if ([string](Get-Field $entry 'id' '') -eq $SessionId) {
                    $completionAt = [long](Get-Field $entry 'completionAt' 0)
                    break
                }
            }
        }
    }
    Write-Diag "Invoke-PopupClick: completionAt=$completionAt"

    $script:ActiveSessionId = $SessionId
    Add-Acknowledged -SessionId $SessionId -At $completionAt
    $script:LastInteraction = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Write-Control
    Hide-Popup

    # Drop it from the local view too, so the bubble disappears on the next frame even
    # before the bridge has processed the control file. Without this the popup can flash
    # back for one poll interval, which reads as the click having failed. Only the clicked
    # conversation goes, and a running one stays, so live work and parallel tasks are
    # unaffected.
    Remove-BubbleLocally -SessionId $SessionId

    Open-Harness | Out-Null
}

<#
.SYNOPSIS
    Resolve a click on the pet or the bubble from the OS, without WPF mouse events.
.DESCRIPTION
    This is the single click handler, and it deliberately does not use WPF's
    MouseLeftButtonDown/Up. Those events are unreliable for these windows: they are
    shown without activation (ShowActivated = $false) so that clicking the pet does
    not steal focus from the editor, and in that state the pet's own counters showed
    `up = 0` for an entire session — releases are delivered elsewhere — while the
    bubble window reported no presses at all.

    The OS, however, always knows where the cursor is and whether the button is down,
    so the press is detected by polling:

      * `GetAsyncKeyState(VK_LBUTTON)` — the physical button state, read at call time
        with no message loop involved (see Test-LeftButtonDown);
      * `GetCursorPos` — the cursor position;
      * `WindowFromPoint` — which window the OS would deliver a click to, which is how
        a press is attributed to the pet or the bubble rather than guessed.

    The action fires on RELEASE, so a press can still be cancelled by moving away.
    Which window the press started on decides what it means:

      * the pet window -> open Harness (and clear the conversation it was showing);
      * the bubble window -> open Harness and dismiss that conversation.

    A press that drifts more than a few pixels is treated as a drag, not a click.
#>
function Step-PointerClick {
    $down = Test-LeftButtonDown

    # Trace every transition, and the cursor while a button is held. Without this a
    # failed click is invisible: nothing happens on screen and no event is recorded,
    # so there is no way to tell "the press was never seen" from "the press was seen
    # and the target was mis-identified".
    if ($down -ne $script:PointerWasDown) {
        $trace = Get-CursorPoint
        if ($down) {
            Write-Diag "pointer: button DOWN at ($($trace.X),$($trace.Y)) nextTarget=$script:PointerTarget"
        } else {
            Write-Diag "pointer: button UP  target=$($script:PointerTarget)"
        }
    }

    if (-not $down) {
        if (-not $script:PointerWasDown) { return }
        # Released: evaluate the click.
        $script:PointerWasDown = $false
        $target = $script:PointerTarget
        $script:PointerTarget = ''
        $drift = 0.0
        if ($null -ne $script:PointerDownAt) {
            $cursor = Get-CursorPoint
            $drift = [Math]::Sqrt([Math]::Pow($cursor.X - $script:PointerDownAt.X, 2) +
                                  [Math]::Pow($cursor.Y - $script:PointerDownAt.Y, 2))
        }
        if ($drift -gt 12) {
            Write-Diag "pointer: press on '$target' ignored (moved $([int]$drift)px)"
            return
        }
        switch ($target) {
            'pet'    { Write-Diag 'pointer: pet clicked'; Invoke-PetClick }
            # Dispatched on the tag: a session id opens that conversation, while
            # `action:...` drives an in-popup control such as the expand/collapse toggle.
            'popup'  {
                Write-Diag "pointer: popup clicked (hit='$($script:PointerSessionId)')"
                Invoke-PopupHit -Tag $script:PointerSessionId
            }
            default  { }
        }
        return
    }

    if ($script:PointerWasDown) { return }
    # A fresh press: record where it landed and on which window.
    $script:PointerWasDown = $true
    $cursor = Get-CursorPoint
    $script:PointerDownAt = $cursor
    $script:PointerTarget = ''
    $script:PointerSessionId = ''

    $point = New-Object PetNative.Win+POINT
    $point.X = $cursor.X
    $point.Y = $cursor.Y
    $hit = [PetNative.Win]::WindowFromPoint($point)

    $petHandle = (New-Object System.Windows.Interop.WindowInteropHelper($script:PetWindow)).Handle
    $popupHandle = [IntPtr]::Zero
    if ($null -ne $script:PopupWindow) {
        $popupHandle = (New-Object System.Windows.Interop.WindowInteropHelper($script:PopupWindow)).Handle
    }

    if ($hit -eq $petHandle) {
        $script:PointerTarget = 'pet'
    } elseif ($popupHandle -ne [IntPtr]::Zero -and $hit -eq $popupHandle) {
        $script:PointerTarget = 'popup'
        # Resolve what is under the cursor, since no WPF event carries it. The result is
        # an action name or a session id — see Invoke-PopupHit.
        $script:PointerSessionId = Get-PopupHitAtCursor -Cursor $cursor
    } else {
        $script:PointerTarget = ''
    }
    if ($script:PointerTarget -ne '') {
        Write-Diag "pointer: press on $($script:PointerTarget) at ($($cursor.X),$($cursor.Y)) hit='$($script:PointerSessionId)'"
    }
}

<# The cursor position as a plain object, avoiding a WinForms dependency. #>
function Get-CursorPoint {
    $point = New-Object PetNative.Win+POINT
    if ([PetNative.Win]::GetCursorPos([ref]$point)) { return $point }
    # Fall back to the WPF mouse position if the API is unavailable.
    return [System.Windows.Forms.Cursor]::Position
}

<#
.SYNOPSIS
    What is under the cursor inside the popup?
.DESCRIPTION
    Hit-tests the popup's own visual tree, because the popup window does not reliably
    deliver WPF mouse events — the same reason the pet's click is polled from the OS.

    Returns the `Tag` of the innermost matching element, which identifies what was
    clicked. Tags are either a session id (a conversation's box or list row) or an
    internal action name in the `action:` namespace — the expand/collapse control is one
    of those.

    The distinction matters: an earlier version returned only session ids, so a click on
    the expand button (which has no session) produced an empty result and was discarded,
    which is why 收起 appeared to do nothing.

    The card's rectangle is converted from WPF device-independent units to screen pixels.
    Deepest matches win, so a click on text inside a box still resolves to that box, and
    traversal is depth-first so a nested element takes precedence over its ancestor.
#>
function Get-PopupHitAtCursor {
    param($Cursor)
    if ($null -eq $script:PopupHost) { return '' }

    try {
        $origin = $script:PopupWindow.PointToScreen((New-Object System.Windows.Point(0, 0)))
        $scale = Get-VisualScale -Window $script:PopupWindow
        $offsetX = $Cursor.X - $origin.X
        $offsetY = $Cursor.Y - $origin.Y

        # Depth-first, and the first hit wins. Children are pushed in reverse so that the
        # topmost sibling is examined first, matching what the user sees.
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push($script:PopupHost)
        while ($stack.Count -gt 0) {
            $element = $stack.Pop()
            $tag = [string](Get-Field $element 'Tag' '')
            if ($tag -ne '') {
                if ($element.ActualWidth -gt 0 -and $element.ActualHeight -gt 0) {
                    $topLeft = $element.TranslatePoint((New-Object System.Windows.Point(0, 0)), $script:PopupHost)
                    $x0 = $topLeft.X * $scale
                    $y0 = $topLeft.Y * $scale
                    $x1 = $x0 + ($element.ActualWidth * $scale)
                    $y1 = $y0 + ($element.ActualHeight * $scale)
                    if ($offsetX -ge $x0 -and $offsetX -le $x1 -and $offsetY -ge $y0 -and $offsetY -le $y1) {
                        return $tag
                    }
                }
            }
            $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($element)
            for ($i = $count - 1; $i -ge 0; $i--) {
                $stack.Push([System.Windows.Media.VisualTreeHelper]::GetChild($element, $i))
            }
        }
    } catch {
        Write-Diag "Get-PopupHitAtCursor failed: $_"
    }
    return ''
}

<#
.SYNOPSIS
    Act on a click inside the popup, dispatching on what the tag names.
.DESCRIPTION
    A tag is either an internal action (`action:...`) or a session id. Actions are
    handled here so that controls such as the expand/collapse toggle work despite the
    popup not delivering WPF click events.
#>
function Invoke-PopupHit {
    param([string]$Tag)
    if ($Tag -eq '') { return }

    if ($Tag -like 'action:*') {
        $action = $Tag.Substring(7)
        Write-Diag "Invoke-PopupHit: action '$action'"
        switch ($action) {
            'toggle-panel' { Toggle-Panel }
            'open-harness' { Open-Harness | Out-Null }
            default { Write-Diag "Invoke-PopupHit: unknown action '$action'" }
        }
        return
    }

    Invoke-PopupClick -SessionId $Tag
}

# --- main loop ---------------------------------------------------------------

function Start-Pet {
    # Refuse to become the second pet — atomically.
    #
    # Two mechanisms, because each alone leaves a hole that produced two whales in practice.
    #
    # **A named mutex** is the primary guard, and it is atomic: the OS guarantees exactly one
    # creator. The window scan below cannot do this job on its own, because it is racy — two
    # shells launched seconds apart both scan while NEITHER has a window yet, both conclude they
    # are the only pet, and both proceed. That is exactly what happened: a cold start exceeded the
    # watchdog's verification window, so a second launch was attempted while the first was still
    # starting, and the first shell's window arrived afterwards. A mutex has no such window of
    # opportunity.
    #
    # **A window scan** remains as a secondary check, because it catches the case a mutex cannot:
    # a pet started by an OLDER build that never took the mutex. It also gives a better log line,
    # naming the pid that already owns the screen.
    #
    # The mutex is held for the process lifetime; the OS releases it when the shell exits, so
    # there is nothing to clean up after a crash.
    $script:PetMutex = $null
    try {
        $createdNew = $false
        $script:PetMutex = New-Object System.Threading.Mutex($true, 'Local\BlueWhalePetShell', [ref]$createdNew)
        if (-not $createdNew) {
            Write-Diag 'startup: refusing to start; another pet shell already owns Local\BlueWhalePetShell'
            return
        }
    } catch {
        # If the mutex cannot be created, fall through to the window scan rather than refusing to
        # run: a pet that never appears is worse than a possible duplicate.
        Write-Diag "startup: could not create the shell mutex, relying on the window scan: $($_.Exception.Message)"
    }

    try {
        $mine = [int]$PID
        $others = @(Get-AllVisibleWindows | Where-Object {
            $_.Title -like ($WindowTitle + '*') -and $_.Owner -ne $mine
        })
        if ($others.Count -gt 0) {
            Write-Diag "startup: refusing to start; another pet (pid $($others[0].Owner)) is already on screen"
            return
        }
    } catch {
        # A failed scan must not block startup: a pet that never appears is worse than a
        # possible duplicate.
        Write-Diag "startup: duplicate check failed, continuing: $_"
    }

    # Probe once, not per click: the scan walks every loopback port.
    $script:HarnessUrls = @(Find-HarnessUrls)
    $script:Scale = [double]$Scale

    # Startup self-check for both open paths. A delegated callback into a PowerShell
    # script block (`EnumWindows`) can fail silently inside this host, and the only
    # symptom is that clicking the pet does nothing at all — no exception, nothing on
    # screen. Reporting both once at startup makes that visible.
    try {
        $probe = @(Get-AllVisibleWindows)
        $titled = @($probe | Where-Object { $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })
        Write-Diag "startup: $($probe.Count) window(s), $($titled.Count) Harness-titled"
        Write-Diag "startup: HarnessUrls=[$($script:HarnessUrls -join ', ')]"
    } catch {
        Write-Diag "startup: window enumeration FAILED: $_"
    }

    # A plain PowerShell host has no WPF Application, so `[Application]::Current`
    # is null and `Run()` cannot be called. Creating one also gives the shell a
    # dispatcher loop, which is what keeps the animation timers ticking.
    if ($null -eq [System.Windows.Application]::Current) {
        $script:App = New-Object System.Windows.Application
        $script:App.ShutdownMode = 'OnExplicitShutdown'
    }

    $initial = Restore-Position
    $size = Get-PetSize

    $sheet = New-Object System.Windows.Media.Imaging.BitmapImage
    $sheet.BeginInit()
    $sheet.UriSource = New-Object System.Uri($script:SpritePath)
    $sheet.CacheOption = 'OnLoad'
    $sheet.EndInit()
    $sheet.Freeze()
    $script:Frames = New-CroppedFrames -Source $sheet -Columns 8 -Rows 9 -CellW $script:CellW -CellH $script:CellH

    $pet = Build-PetWindow -InitialRect $initial -Size $size
    $popup = Build-PopupWindow
    $script:Sheet = $sheet

    $pet.Add_Loaded({
        # The rectangle is asserted once the window exists: the requested
        # physical size is what edge fixing depends on, and WPF's DIP conversion
        # is not observable until the window has a presentation source.
        $size = Get-PetSize
        Set-WindowSizePx -Window $script:PetWindow -Size $size
        Move-WindowExact -Window $script:PetWindow -Rect (Restore-Position)
        Write-Control
    })
    $pet.Add_Closed({ if (-not $script:Exiting) { Stop-Pet } })

    $tick = New-Object System.Windows.Threading.DispatcherTimer
    $tick.Interval = [TimeSpan]::FromMilliseconds($script:TimerMs)
    $tick.Add_Tick({
        Read-Snapshot
        Invoke-ShellCommand
        Step-Drag
        Step-PointerClick
        Step-Inertia

        $script:FrameAccum += $script:TimerMs
        $frameMs = if ($script:Mood -eq 'idle') { 110 } else { 80 }
        if ($script:FrameAccum -ge $frameMs) {
            $script:FrameAccum = 0
            Update-Frame
        }

        if ($null -ne $script:TiltTransform) {
            $script:TiltTransform.Angle = $script:TiltDeg
            $script:TiltTransform.CenterX = $script:PetImage.Width / 2
            $script:TiltTransform.CenterY = $script:PetImage.Height / 2
        }
        if ($script:Bounce -gt 0) {
            $script:Bounce = [Math]::Max(0, $script:Bounce - 0.12)
            $script:PetImage.Opacity = 1.0
            $script:PetHost.RenderTransform = New-Object System.Windows.Media.ScaleTransform(1.0, (1.0 + 0.05 * $script:Bounce))
            $script:PetHost.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 1.0)
        }
        elseif ($null -ne $script:PetHost.RenderTransform) {
            $script:PetHost.RenderTransform = $null
        }

        # A rebuild that was deferred for the duration of a drag is applied as soon as the
        # pet is still, so the timestamps are corrected immediately rather than lingering.
        if ($script:PopupContentDeferred -and -not $script:Dragging -and -not $script:Inertia) {
            if ($null -ne $script:View -and $script:PopupMode -ne 'hidden') {
                Update-Popup -View $script:View
            } else {
                $script:PopupContentDeferred = $false
            }
        }

        if ($null -ne $script:View) { Show-BubbleIfNeeded -View $script:View }
    })

    $control = New-Object System.Windows.Threading.DispatcherTimer
    $control.Interval = [TimeSpan]::FromMilliseconds(1000)
    $control.Add_Tick({ Write-Control })
    $script:TickTimer = $tick
    $script:ControlTimer = $control

    $tick.Start()
    $control.Start()

    $pet.Show()
    Move-WindowExact -Window $pet -Rect (Restore-Position)
    Write-Control
    [System.Windows.Application]::Current.Run() | Out-Null
}

Start-Pet
