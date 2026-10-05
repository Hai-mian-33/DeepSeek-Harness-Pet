# Install-Autostart.ps1 - make the pet start automatically while Harness is open.
#
# WHAT THIS DOES
#   Installs a hidden watchdog into the user's Startup folder. At every logon it begins
#   watching: when DeepSeek Harness is running, the pet is started; when Harness closes,
#   the pet is stopped. Nothing to run by hand, and no terminal window involved.
#
# WHY A WATCHDOG AND NOT A DIRECT LAUNCH
#   "Start the pet when Harness opens" cannot be done by a one-shot launch at logon, because
#   Harness may well start later. A resident check is needed, and it must live outside any
#   restricted host, because raising another application's window is refused inside one
#   (see the README). Windows launches this at logon, so the pet it starts inherits the
#   ability to raise Harness -- the same reason running start-pet.cmd from a normal terminal
#   works.
#
# USAGE
#   powershell -NoProfile -File tools\Install-Autostart.ps1            # install
#   powershell -NoProfile -File tools\Install-Autostart.ps1 -Remove    # uninstall
#   powershell -NoProfile -File tools\Install-Autostart.ps1 -Status    # report only

param(
    [string]$Root = '',
    [switch]$Remove,
    [switch]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }

$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$installedVbs = Join-Path $startupDir 'BlueWhalePet.vbs'
$sourceVbs = Join-Path $Root 'tools\Watch-Pet.vbs'
$watchScript = Join-Path $Root 'tools\Watch-Pet.ps1'

function Write-Result {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

# --- status -----------------------------------------------------------------

function Get-InstallState {
    $installed = Test-Path -LiteralPath $installedVbs
    $watchdogState = Join-Path $Root 'state\watchdog.json'
    $running = $false
    $detail = 'no heartbeat file'
    if (Test-Path -LiteralPath $watchdogState) {
        try {
            $state = Get-Content -LiteralPath $watchdogState -Raw -Encoding UTF8 | ConvertFrom-Json
            $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$state.at
            # A recent heartbeat is NECESSARY but not sufficient: `-Once` runs also write one and
            # then exit, so a 27-second-old heartbeat from a process that is already gone would
            # be reported as "running". The recorded pid is therefore checked as well.
            #
            # The pid is only evidence of THIS watchdog if its start time is at or before the
            # heartbeat: Windows reuses pids, and a recycled one would otherwise make a dead
            # watchdog look alive.
            if ($age -ge 30000) {
                $detail = "heartbeat is $([int]($age / 1000))s old"
            } else {
                $proc = Get-Process -Id ([int]$state.pid) -ErrorAction SilentlyContinue
                if ($null -eq $proc) {
                    $detail = "heartbeat is fresh but pid $($state.pid) is not running"
                } elseif ($proc.ProcessName -ne 'powershell') {
                    $detail = "pid $($state.pid) is '$($proc.ProcessName)', not the watchdog"
                } else {
                    $running = $true
                    $detail = "pid $($state.pid), heartbeat $([int]($age / 1000))s ago"
                }
            }
        } catch {
            $detail = "unreadable heartbeat: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{ Installed = $installed; Running = $running; Detail = $detail }
}

if ($Status) {
    $state = Get-InstallState
    Write-Result '蓝鲸小深 · 自动启动状态' 'Cyan'
    Write-Result ''
    Write-Result ("  Startup 快捷方式 : {0}" -f $(if ($state.Installed) { "已安装  ($installedVbs)" } else { '未安装' }))
    Write-Result ("  看门狗进程       : {0}" -f $(if ($state.Running) { "正在运行（$($state.Detail)）" } else { "未运行（$($state.Detail)）" }))
    Write-Result ''
    $watchdogState = Join-Path $Root 'state\watchdog.json'
    if (Test-Path -LiteralPath $watchdogState) {
        try {
            $s = Get-Content -LiteralPath $watchdogState -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Result ("  Harness 运行中   : {0}" -f $s.harnessRunning)
            Write-Result ("  桌宠运行中       : {0}" -f $s.petRunning)
            Write-Result ("  最近动作         : {0}" -f $s.lastAction)
        } catch { }
    }
    Write-Result ''
    Write-Result ("  日志: {0}" -f (Join-Path $Root 'build\watchdog.log'))
    exit 0
}

# --- remove -----------------------------------------------------------------

if ($Remove) {
    Write-Result '卸载自动启动...' 'Cyan'
    if (Test-Path -LiteralPath $installedVbs) {
        Remove-Item -LiteralPath $installedVbs -Force
        Write-Result "  已删除 $installedVbs" 'Green'
    } else {
        Write-Result '  没有已安装的自动启动项'
    }

    # Stop a watchdog that is already running, so removal takes effect now rather than at
    # the next logon. It is identified by its command line, because powershell.exe is
    # shared with every other script on the machine.
    $killed = 0
    try {
        $watchdogs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like '*Watch-Pet.ps1*' })
        foreach ($proc in $watchdogs) {
            try {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                $killed++
            } catch { }
        }
    } catch { }
    if ($killed -gt 0) { Write-Result "  已停止 $killed 个正在运行的看门狗进程" 'Green' }

    Write-Result ''
    Write-Result '自动启动已关闭。桌宠不会再自动出现在屏幕上。' 'Green'
    Write-Result '（手动启动仍然可用：scripts\start-pet.cmd）'
    exit 0
}

# --- install ----------------------------------------------------------------

Write-Result '安装蓝鲸小深自动启动' 'Cyan'
Write-Result ''

if (-not (Test-Path -LiteralPath $sourceVbs)) {
    Write-Result "找不到 $sourceVbs" 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $watchScript)) {
    Write-Result "找不到 $watchScript" 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $startupDir)) {
    Write-Result "找不到启动文件夹 $startupDir" 'Red'
    exit 1
}

# The launcher has __PET_ROOT__ substituted with this project's real path first, because a
# copy sitting in the Startup folder cannot work out where the project lives from its own
# location. The check runs before any write, so a bad path fails without leaving a broken
# launcher behind that would show a message box at every logon.
if ($Root -match '"') {
    Write-Result "项目路径含有双引号，无法安全写入 VBS 启动器：$Root" 'Red'
    exit 1
}

# Writing into the Startup folder is outside the session workspace, which a restricted host
# refuses. That is expected and is reported as an instruction rather than a crash: the user
# can always perform this one step in their own terminal.
try {
    $launcher = [System.IO.File]::ReadAllText($sourceVbs, [System.Text.UTF8Encoding]::new($false))
    $launcher = $launcher.Replace('__PET_ROOT__', $Root)
    [System.IO.File]::WriteAllText($installedVbs, $launcher, [System.Text.UTF8Encoding]::new($false))
} catch {
    Write-Result '无法写入启动文件夹（当前环境限制了工作区之外的写入）' 'Yellow'
    Write-Result ''
    Write-Result '请在普通终端（Win+R 输入 cmd 回车）执行下面这一行完成安装：' 'White'
    Write-Result ''
    Write-Result ("  powershell -NoProfile -ExecutionPolicy Bypass -File ""{0}\tools\Install-Autostart.ps1""" -f $Root) 'Green'
    Write-Result ''
    Write-Result '它会写好启动项、立即启动看门狗，不需要重启电脑。'
    exit 2
}

Write-Result "  已安装: $installedVbs" 'Green'
Write-Result ''

# Stop any watchdog already running before starting a fresh one.
#
# Installing repeatedly used to leave every previous watchdog alive, and they do not cooperate:
# each independently decides to start its own pet, so the desktop accumulated one whale per
# watchdog. The log showed paired events hundredths of a second apart, which is how the cause was
# identified. Watch-Pet.ps1 now also refuses to run twice, but that would make a NEW watchdog exit
# while an OLD one kept going — so replacing it here is what actually installs the new code.
$killedWatchdogs = 0
try {
    $existing = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*Watch-Pet.ps1*' })
    foreach ($proc in $existing) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $killedWatchdogs++
        } catch { }
    }
} catch { }
if ($killedWatchdogs -gt 0) {
    Write-Result "  已停止 $killedWatchdogs 个旧的看门狗进程（避免重复启动桌宠）" 'Yellow'
    Start-Sleep -Milliseconds 800
}

# Start it now too, so the user does not have to log off and back on to see the effect.
$started = $false
try {
    Start-Process -FilePath 'powershell' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                        '-File', $watchScript) `
        -WindowStyle Hidden
    Start-Sleep -Milliseconds 1500
    $started = $true
} catch {
    Write-Result "  无法立即启动看门狗: $($_.Exception.Message)" 'Yellow'
}

if ($started) { Write-Result '  看门狗已启动，正在监视 DeepSeek Harness' 'Green' }

Write-Result ''
Write-Result '完成。现在的行为：' 'Cyan'
Write-Result '  * 打开 DeepSeek Harness  →  桌宠自动出现'
Write-Result '  * 关闭 DeepSeek Harness  →  桌宠自动收起'
Write-Result '  * 以后开机登录后也会自动生效，不需要终端'
Write-Result ''
Write-Result '查看状态: powershell -NoProfile -File tools\Install-Autostart.ps1 -Status'
Write-Result '取消:     powershell -NoProfile -File tools\Install-Autostart.ps1 -Remove'
