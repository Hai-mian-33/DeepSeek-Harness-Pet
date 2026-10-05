# Watch-Pet.ps1 - keep the pet running exactly while DeepSeek Harness is running.
#
# Why this exists
# ---------------
# Starting the pet from a terminal works, but it has two problems: it has to be done by
# hand every time, and it must be done from a NORMAL terminal, because raising another
# application's window is refused inside a restricted host (see the README). A watchdog
# launched by Windows itself is outside any such host, so the pet it starts inherits the
# ability to raise Harness -- the same reason `start-pet.cmd` works.
#
# What it does
# ------------
# Every few seconds: if a `DeepSeek Harness` process exists and no pet is running, start
# the pet. If Harness is gone, stop the pet. That is the whole policy -- "the pet is
# visible exactly while Harness is open".
#
# Design notes
# ------------
# * Detection uses the process name, not a window title. Harness may legitimately have no
#   window (minimised to tray, or still starting up), and the pet should not flicker off
#   in those moments. `Get-Process` is also far cheaper than enumerating every window.
# * The pet's own liveness is judged by its WINDOW, not by its process: the shell is a
#   `powershell` process, and there are always other powershell processes around. This
#   reuses the same window-based detection the stop/list tools use, so all three agree.
# * A short debounce on the "Harness disappeared" edge avoids stopping the pet during a
#   restart of Harness, which is common (updating, or the app relaunching itself).
# * Every exit path is logged, and failures never throw: a watchdog that dies silently is
#   worse than no watchdog, because the pet then never appears and nothing explains why.

param(
    [string]$Root = '',
    # How often to check, in milliseconds.
    [int]$IntervalMs = 4000,
    # How long Harness must be absent before the pet is stopped. Absorbs a Harness restart.
    [int]$GraceMs = 20000,
    # Run one check and exit. Used by the tests; the normal mode loops forever.
    [switch]$Once,
    # Print what would happen without starting or stopping anything.
    [switch]$DryRun,
    # The process whose lifetime the pet follows.
    #
    # Overridable on purpose. It lets the real detection and the real loop be exercised
    # against a harmless process, so the behaviour can be verified without closing the user's
    # DeepSeek Harness; and if a future build ever ships under a different image name, the fix
    # is a parameter rather than a code change.
    [string]$HarnessProcessName = 'DeepSeek Harness',
    # The window-title prefix that identifies the pet.
    #
    # Production always uses the pet's real title. It is a parameter so a test can run its own
    # throwaway pet without colliding with a real one that happens to be on screen: liveness is
    # judged from a window title, and titles are global to the desktop, so with a real pet up a
    # test could never reach the start branch at all.
    [string]$PetWindowTitle = '蓝鲸小深',
    # Skip the window-based Harness signal and decide on the process name alone.
    #
    # Detection ORs two signals (see Test-HarnessRunning). The window signal is essential in
    # production — the process holding Harness's window is not always named `DeepSeek Harness` —
    # but it makes the loop test unable to isolate: a real Harness window on the desktop keeps
    # answering "running" no matter what the test's stand-in process does, so the stop branch can
    # never be reached. This switch lets that test exercise the full cycle by name only.
    #
    # It is test-only and defaults to off; nothing in production passes it.
    [switch]$IgnoreHarnessWindow,
    # Force the tray-mode decision instead of reading the app's marker file.
    #
    # Tray mode changes which signals count (see Test-HarnessRunning), so a test that wants to
    # exercise the process-based branch must be able to pin it regardless of what the machine's
    # real Harness is configured to do.
    #
    # The type is [string] with an empty default, NOT [nullable[bool]]: `powershell -File` passes
    # every argument as text, and binding "False" to a nullable Boolean fails with "Cannot process
    # argument transformation" — which made the script exit before doing anything, so the only
    # symptom was a watchdog that silently never ran. Empty means "read the marker"; the strings
    # 'true'/'false' pin it. A [switch] was also unsuitable: it cannot express the third state
    # ("unset") and cannot be forced OFF.
    [string]$BackgroundTrayEnabled = '',
    # Override the tray marker path, for tests that must not touch real app data.
    [string]$BackgroundTrayMarker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') {
    $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
. (Join-Path $Root 'tools\PetWindowNative.ps1')

$logFile = Join-Path $Root 'build\watchdog.log'
$stateFile = Join-Path $Root 'state\watchdog.json'

# How long a "stay closed" marker suppresses the pet before it is treated as stale.
#
# Bounded on purpose: an unbounded marker turns any non-deliberate quit into a permanent lockout,
# and the symptom (`lastAction=quit` while nothing appears) gives no hint that a leftover file is
# responsible. 12 hours spans a working day, so a real quit still means what the user expects.
$script:QuitMaxAgeMs = 12 * 60 * 60 * 1000

# How long a launch latch blocks a second launch while the first is still starting up.
#
# Must comfortably exceed a cold start (measured: window up after 0.5-2.2s warm, longer cold) and
# be short enough that a genuinely failed launch is retried promptly.
$script:LaunchLatchMs = 45 * 1000

function Write-WatchLog {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Message
    try {
        $dir = Split-Path -Parent $logFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}

<#
.SYNOPSIS
    Has the user enabled "hide to tray when the window is closed"?
.DESCRIPTION
    DeepSeek Harness ships a Windows tray mode, and once the user acknowledges it (the app
    writes `background-close-confirmed` into its userData directory, and its own dialog says
    "正在运行的任务不会中断，可在系统托盘中重新打开窗口") closing the window **hides it to the
    tray instead of quitting**. The processes stay alive by design.

    That single fact decides how "is Harness open?" must be answered. With tray mode on, a
    process-based check reports "running" forever after the window is closed, so the pet would
    never hide — the exact requirement it exists to satisfy would silently fail.

    The marker is read rather than assumed, so the behaviour follows the user's real setting
    instead of a guess. The path is the app's own userData location for this product; if it is
    ever moved, both this check and the window check degrade to the previous OR behaviour, which
    is the safe direction (the pet stays visible rather than vanishing unexpectedly).
#>
function Test-BackgroundTrayEnabled {
    param([string]$MarkerPath)

    # An explicit override wins, so a test can pin either setting. The accepted text forms are the
    # ones `powershell -File` can actually deliver.
    $forced = Get-Variable -Name 'BackgroundTrayEnabled' -ValueOnly -ErrorAction SilentlyContinue
    if ($forced -is [string] -and $forced -ne '') {
        return ($forced -match '^(?i)(true|1|yes)$')
    }
    if ($forced -is [bool]) { return $forced }

    # Overridable so the tests can exercise both settings without touching the real app data.
    $path = $MarkerPath
    if ([string]::IsNullOrEmpty($path)) {
        $override = Get-Variable -Name 'BackgroundTrayMarker' -ValueOnly -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrEmpty($override)) { $path = $override }
    }
    if ([string]::IsNullOrEmpty($path)) {
        $path = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\background-close-confirmed'
    }
    return (Test-Path -LiteralPath $path)
}

<#
.SYNOPSIS
    Is a window that identifies DeepSeek Harness currently visible?
.DESCRIPTION
    Matched on the title, which is what the user actually sees. The pet's own windows are titled
    with the whale name and so do not match `*Harness*`; this is asserted by the tests.
#>
function Test-HarnessWindowVisible {
    try {
        $windows = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like '*Harness*' })
        return $windows.Count -gt 0
    } catch {
        # A denied enumeration must not read as "closed", which would hide the pet.
        return $true
    }
}

<#
.SYNOPSIS
    Is DeepSeek Harness open?
.DESCRIPTION
    Three signals, and which ones apply depends on whether tray mode is on.

    **Tray mode ON** (the user confirmed "hide to tray on close"): the processes deliberately
    outlive the window, so they say nothing about whether the app is *open* to the user. Only the
    window does. Judging this by process would keep the pet on screen forever after the user
    closed the app, which is precisely the failure the watchdog exists to prevent.

    **Tray mode OFF** (the default, and the state before any such confirmation): closing the
    window quits the app on Windows — the bundle's own lifecycle is
    `app.on("window-all-closed", () => { if (platform !== "darwin") app.quit(); })`. So a process
    is a reliable sign of "open", and checking it first also keeps the pet alive while Harness is
    starting up, before any window exists.

    In both cases a *window* mentioning Harness counts as open, because the process holding that
    window is not always named `DeepSeek Harness` on this machine (an Electron helper owns it),
    so a name-only check would call a plainly open Harness "closed".

    A denied process query is treated as "running", so a permission failure cannot retract the
    pet either.
#>
function Test-HarnessRunning {
    $trayMode = Test-BackgroundTrayEnabled

    if ($trayMode) {
        # The window is the only honest signal: the processes are expected to linger.
        return (Test-HarnessWindowVisible)
    }

    # Signal 1: the named process.
    try {
        $found = @(Get-Process -Name $HarnessProcessName -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) { return $true }
    } catch {
        # A denial here would otherwise look like "Harness is closed" and stop the pet.
        # Reporting "running" is the safe default: it keeps an existing pet alive.
        return $true
    }

    # Signal 2: a window that identifies Harness.
    #
    # Skipped when -IgnoreHarnessWindow is set (test-only; see the parameter's comment).
    try {
        $ignoreWindow = Get-Variable -Name 'IgnoreHarnessWindow' -ValueOnly -ErrorAction SilentlyContinue
        if ($ignoreWindow -ne $true) {
            if (Test-HarnessWindowVisible) { return $true }
        }
    } catch { }

    return $false
}

<#
.SYNOPSIS
    Is a pet shell currently on screen?
.DESCRIPTION
    Judged by the pet's own window, for the same reason Stop-Pet.ps1 does it that way: the
    shell is a powershell process and cannot be told apart from other powershell processes
    by name alone.
#>
function Test-PetRunning {
    try {
        $windows = @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -like ($PetWindowTitle + '*') })
        return $windows.Count -gt 0
    } catch {
        return $false
    }
}

function Start-PetNow {
    $node = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
    $bridge = Join-Path $Root 'src\bridge.mjs'
    $shell = Join-Path $Root 'src\shell\WhalePet.ps1'

    # Resolve and check both entry points BEFORE launching anything. A missing path here is
    # the one failure mode that is otherwise invisible: PowerShell given a non-existent
    # `-File` target exits immediately, so nothing appears on screen and nothing is logged.
    if (-not (Test-Path -LiteralPath $node)) {
        Write-WatchLog "cannot start: bundled node not found at $node"
        return $false
    }
    if (-not (Test-Path -LiteralPath $bridge)) {
        Write-WatchLog "cannot start: bridge not found at $bridge"
        return $false
    }
    if (-not (Test-Path -LiteralPath $shell)) {
        Write-WatchLog "cannot start: shell not found at $shell"
        return $false
    }

    # Stop any partial instance first, so a half-dead shell cannot leave two pets behind.
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\Stop-Pet.ps1') 2>&1 | Out-Null
    } catch { }

    # Clear the "stay closed" marker AFTER stopping, and before launching.
    #
    # This ordering is essential, and getting it wrong caused a self-inflicted lockout: the shell
    # writes `pet-quit` whenever it shuts down (that is how 退出桌宠 tells a watchdog to stay
    # away), and `Stop-Pet.ps1` above kills the shell — so the stop step poisoned the start step,
    # leaving a marker that made every later iteration answer 'quit'. The pet then never appeared
    # again, with `lastAction=quit` as the only clue.
    #
    # Reaching this function at all means "Harness is open and the user has NOT asked for the pet
    # to stay closed" — the caller checks the marker before calling. So removing it here is
    # correct, and it must happen after Stop-Pet.ps1, which is what creates it.
    try {
        $quitMarker = Join-Path $Root 'state\pet-quit'
        if (Test-Path -LiteralPath $quitMarker) {
            Remove-Item -LiteralPath $quitMarker -Force -ErrorAction SilentlyContinue
            Write-WatchLog 'cleared a stale quit marker before starting the pet'
        }
    } catch { }

    # Take the launch latch. While it is fresh, Invoke-WatchStep will not start a second pet even
    # if this launch has not produced a window yet — which is the situation that produced two
    # whales. It is cleared as soon as the outcome is known, so a failure is retried promptly.
    $latch = Join-Path $Root 'state\pet-launching'
    try {
        [System.IO.File]::WriteAllText($latch, ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()).ToString(),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }

    try {
        # Hidden: this runs at logon, and a console window appearing uninvited would be
        # worse than the pet not starting.
        Start-Process -FilePath $node -ArgumentList 'src\bridge.mjs' `
            -WorkingDirectory $Root -WindowStyle Hidden
        Start-Sleep -Milliseconds 1800

        # Read the configured title defensively rather than using $PetWindowTitle directly.
        # That variable is a script parameter, so it exists whenever the whole script runs --
        # but this function is also extracted and invoked on its own by Test-WatchdogStart.ps1,
        # where a direct reference throws under StrictMode and the launch silently fails. The
        # fallback is the pet's own name, which is the correct production value anyway.
        $title = '蓝鲸小深'
        $configured = Get-Variable -Name 'PetWindowTitle' -ValueOnly -ErrorAction SilentlyContinue
        if ($configured -is [string] -and $configured -ne '') { $title = $configured }

        # The title is forwarded so a caller that renamed the pet (the loop test does, to avoid
        # colliding with a real pet on screen) gets a pet it can actually find. The shell accepts
        # the same name as its own parameter.
        Start-Process -FilePath 'powershell' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                            '-File', $shell, '-WindowTitle', $title) `
            -WorkingDirectory $Root -WindowStyle Hidden
    } catch {
        Write-WatchLog "failed to start the pet: $($_.Exception.Message)"
        Remove-Item -LiteralPath $latch -Force -ErrorAction SilentlyContinue
        return $false
    }

    # Verify the pet actually came up, rather than reporting success because no exception was
    # thrown. A child process that dies immediately raises nothing in THIS process, so an earlier
    # version logged "started the pet" even when the shell exited on the spot — exactly the kind of
    # false success that makes a watchdog useless.
    #
    # The wait must be generous, and a short one caused TWO PETS to appear: at 8 seconds a cold
    # start (parse a 2500-line script, set up WPF, decode a 406 KB sprite sheet) sometimes had not
    # finished, so this returned $false, the loop retried 4 seconds later and launched a SECOND
    # shell — and then the first one's window finally appeared. The log showed precisely that:
    #   started the processes but no pet window appeared within 8000ms
    #   started the processes but no pet window appeared within 8000ms
    #   started the pet (Harness is running, window up after 821ms)
    # 30 seconds removes the race for a cold start while still bounding a genuine failure.
    $deadline = 30000
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $deadline) {
        if (Test-PetRunning) {
            Write-WatchLog ("started the pet (Harness is running, window up after {0}ms)" -f $sw.ElapsedMilliseconds)
            Remove-Item -LiteralPath $latch -Force -ErrorAction SilentlyContinue
            return $true
        }
        Start-Sleep -Milliseconds 250
    }

    # The window never appeared. Release the latch so the next iteration retries, and report the
    # failure honestly rather than claiming success.
    Remove-Item -LiteralPath $latch -Force -ErrorAction SilentlyContinue
    Write-WatchLog "started the processes but no pet window appeared within ${deadline}ms"
    return $false
}

function Stop-PetNow {
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools\Stop-Pet.ps1') 2>&1 | Out-Null
        Write-WatchLog 'stopped the pet (Harness is closed)'
        return $true
    } catch {
        Write-WatchLog "failed to stop the pet: $($_.Exception.Message)"
        return $false
    }
}

function Write-WatchState {
    param([bool]$Harness, [bool]$Pet, [string]$Action)
    try {
        $payload = [pscustomobject]@{
            schema = 'dsh-pet-watchdog/1'
            pid = $PID
            at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            intervalMs = $IntervalMs
            harnessRunning = $Harness
            petRunning = $Pet
            lastAction = $Action
            root = $Root
        }
        [System.IO.File]::WriteAllText($stateFile, ($payload | ConvertTo-Json -Depth 3),
            (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

<#
.SYNOPSIS
    Has the user asked for the pet to stay closed?
.DESCRIPTION
    Right-click → 退出桌宠 must actually mean "closed", not "closed until the watchdog
    notices". Without this marker the pet would reappear a few seconds after being dismissed,
    because "Harness is running and no pet is on screen" is precisely the condition this
    watchdog exists to fix — so the quit command would look broken.

    The marker is written by the shell on exit and cleared when Harness stops running (a fresh
    launch should show the pet again), when the pet is started by hand (`start-pet.cmd` deletes
    it), or when the watchdog itself starts the pet (see Start-PetNow).

    **The marker also expires on its own.** Without an expiry, a marker left behind by anything
    other than a deliberate quit — a crash, or the `Stop-Pet.ps1` call inside a restart — suppressed
    the pet permanently. The only symptom was `lastAction=quit` in the heartbeat while nothing
    appeared on screen, which is very hard to interpret. A bounded lifetime makes a stale marker
    self-healing, while a genuine quit still holds for the rest of a working session.
#>
function Test-QuitRequested {
    $marker = Join-Path $Root 'state\pet-quit'
    if (-not (Test-Path -LiteralPath $marker)) { return $false }

    try {
        $raw = (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop).Trim()
        [long]$stamp = 0
        if (-not [long]::TryParse($raw, [ref]$stamp) -or $stamp -le 0) {
            # Unreadable content must not suppress the pet forever.
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            Write-WatchLog 'quit marker had no usable timestamp; removed it'
            return $false
        }
        $ageMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $stamp
        if ($ageMs -gt $script:QuitMaxAgeMs) {
            Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
            Write-WatchLog ("quit marker expired after {0:N1}h; the pet may start again" -f ($ageMs / 3600000))
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

function Clear-QuitRequest {
    $marker = Join-Path $Root 'state\pet-quit'
    if (Test-Path -LiteralPath $marker) {
        Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
        Write-WatchLog 'cleared the quit marker (Harness closed; the pet may start again)'
    }
}

<#
.SYNOPSIS
    Is a launch still in progress?
.DESCRIPTION
    A latch that closes the remaining hole in the single-instance defence.

    The shell's own guard compares WINDOW titles, so it can only see pets that have already shown
    a window. Two launches a few seconds apart are therefore both allowed to proceed — neither has
    a window yet when it checks — and the desktop ends up with two pets. That is not theoretical:
    it is exactly how two whales appeared, because a cold start exceeded the old 8-second
    verification, the loop retried, and the first shell's window arrived afterwards.

    Widening the verification window removes that particular trigger, but the latch makes the
    invariant hold regardless of timing: while it is fresh, no second launch is attempted. It is
    deliberately short-lived — long enough to cover a cold start, short enough that a genuinely
    failed launch is retried rather than abandoned.
#>
function Test-LaunchPending {
    $latch = Join-Path $Root 'state\pet-launching'
    if (-not (Test-Path -LiteralPath $latch)) { return $false }

    try {
        $raw = (Get-Content -LiteralPath $latch -Raw -ErrorAction Stop).Trim()
        [long]$stamp = 0
        if (-not [long]::TryParse($raw, [ref]$stamp) -or $stamp -le 0) {
            Remove-Item -LiteralPath $latch -Force -ErrorAction SilentlyContinue
            return $false
        }
        $ageMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $stamp
        if ($ageMs -gt $script:LaunchLatchMs) {
            Remove-Item -LiteralPath $latch -Force -ErrorAction SilentlyContinue
            Write-WatchLog ("launch latch expired after {0:N0}s; a retry is allowed" -f ($ageMs / 1000))
            return $false
        }
        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Run one check, and act on it.
.DESCRIPTION
    Returns the action taken, so `-Once` can report it and the tests can assert on it.
#>
function Invoke-WatchStep {
    param([ref]$AbsentSince)

    $harness = Test-HarnessRunning
    $pet = Test-PetRunning

    # A deliberate quit is cleared only once Harness stops, so that the NEXT launch shows the
    # pet again without the user having to remember they dismissed it once.
    if (-not $harness) { Clear-QuitRequest }

    if ($harness) {
        $AbsentSince.Value = $null
        if (-not $pet) {
            if (Test-QuitRequested) {
                Write-WatchState -Harness $true -Pet $false -Action 'quit'
                return 'quit'
            }
            # A launch already in flight: wait for it rather than starting a second pet. See
            # Test-LaunchPending for why this is needed even though the shell guards itself.
            if (Test-LaunchPending) {
                Write-WatchState -Harness $true -Pet $false -Action 'launching'
                return 'launching'
            }
            if ($DryRun) {
                Write-WatchLog 'DRY-RUN: would start the pet'
                Write-WatchState -Harness $true -Pet $false -Action 'would-start'
                return 'would-start'
            }
            [void](Start-PetNow)
            Write-WatchState -Harness $true -Pet $true -Action 'started'
            return 'started'
        }
        Write-WatchState -Harness $true -Pet $true -Action 'none'
        return 'none'
    }

    # Harness is not running. The pet is stopped only after it has been absent for the
    # grace period, so restarting Harness does not make the pet blink out and back.
    if (-not $pet) {
        $AbsentSince.Value = $null
        Write-WatchState -Harness $false -Pet $false -Action 'none'
        return 'none'
    }

    if ($AbsentSince.Value -eq $null) {
        $AbsentSince.Value = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        Write-WatchLog "Harness is gone; waiting ${GraceMs}ms before stopping the pet"
        Write-WatchState -Harness $false -Pet $true -Action 'grace'
        return 'grace'
    }

    $absentFor = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$AbsentSince.Value
    if ($absentFor -lt $GraceMs) {
        Write-WatchState -Harness $false -Pet $true -Action 'grace'
        return 'grace'
    }

    if ($DryRun) {
        Write-WatchLog 'DRY-RUN: would stop the pet'
        Write-WatchState -Harness $false -Pet $true -Action 'would-stop'
        return 'would-stop'
    }
    [void](Stop-PetNow)
    $AbsentSince.Value = $null
    Write-WatchState -Harness $false -Pet $false -Action 'stopped'
    return 'stopped'
}

# --- entry point -------------------------------------------------------------

# Refuse to become a second watchdog.
#
# This was the cause of duplicate pets. Several watchdogs were left running by successive
# restarts (each `Install-Autostart.ps1` and each test started one), and they do NOT cooperate:
# every instance independently decides "Harness is up and no pet is on screen" and starts its own
# pet. The log showed the tell-tale signature — paired events hundredths of a second apart:
#   started the processes but no pet window appeared within 8000ms
#   started the processes but no pet window appeared within 8000ms
#   started the pet ... (window up after 403ms)
#   started the pet ... (window up after 874ms)     <- two pets, one per watchdog
#
# A named mutex is used rather than a pid file or a window scan, because it is atomic: the OS
# guarantees exactly one creator, so there is no window in which two instances can both believe
# they are first. `$Once` runs (used by tests and by the shortcuts) are excluded, since they are
# short-lived by design and must not be blocked by a resident watchdog.
if (-not $Once) {
    $script:WatchdogMutex = $null
    $createdNew = $false
    try {
        $script:WatchdogMutex = New-Object System.Threading.Mutex($true, 'Local\BlueWhalePetWatchdog', [ref]$createdNew)
    } catch {
        # If the mutex cannot be created, proceed rather than refusing to run: a pet that never
        # appears is worse than a possible duplicate.
        Write-WatchLog "could not create the watchdog mutex; continuing: $($_.Exception.Message)"
        $createdNew = $true
    }
    if (-not $createdNew) {
        Write-WatchLog "another watchdog already owns Local\BlueWhalePetWatchdog (pid $PID exiting)"
        exit 0
    }
}

$absentSince = $null
Write-WatchLog "watchdog started (pid $PID, interval ${IntervalMs}ms, grace ${GraceMs}ms)"

if ($Once) {
    $action = Invoke-WatchStep -AbsentSince ([ref]$absentSince)
    Write-Host "action: $action"
    exit 0
}

while ($true) {
    try {
        [void](Invoke-WatchStep -AbsentSince ([ref]$absentSince))
    } catch {
        # Never let one bad iteration kill the watchdog: if it dies, the pet silently stops
        # appearing and there is nothing on screen to explain why.
        Write-WatchLog "step failed: $($_.Exception.GetType().Name): $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds $IntervalMs
}
