# List-PetWindows.ps1 - every window that carries the pet's title, with its process.
#
# The sandbox blocks Get-Process for many pids and denies tasklist outright, so a plain
# process listing cannot be trusted for this. Enumerating windows and reading each
# window's owning pid does work, and it is the metric that matters: a pet window means a
# shell is running.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $Root 'tools\PetWindowNative.ps1')

$all = @(Get-AllWindows)
Write-Host "枚举到窗口总数: $($all.Count)"
Write-Host ''

# Anchored on the pet's own title prefix. A loose `蓝鲸` match also catches the DeepSeek
# Harness window itself, whose title is `# DeepSeek Harness 桌面宠物"蓝鲸 — DeepSeek
# Harness`, and reporting a Harness window as a pet is actively misleading.
$pet = @($all | Where-Object { $_.Title -like '蓝鲸小深*' })
Write-Host "桌宠窗口: $($pet.Count)"
if ($pet.Count -eq 0) {
    Write-Host '  （无：当前屏幕上没有桌宠）'
} else {
    foreach ($w in $pet) {
        Write-Host ("  hwnd={0,-10} pid={1,-7} visible={2,-6} {3,4}x{4,-5} at ({5},{6})" -f `
            $w.Handle, $w.Owner, $w.Visible, $w.Width, $w.Height, $w.Left, $w.Top)
        Write-Host ("      title = '{0}'" -f $w.Title)
        $p = Get-Process -Id $w.Owner -ErrorAction SilentlyContinue
        if ($null -ne $p) {
            Write-Host ("      process = {0}, started {1}" -f $p.ProcessName, $p.StartTime)
        } else {
            Write-Host '      process = 沙箱内不可读取该 pid'
        }
    }
}

Write-Host ''
Write-Host '=== 桥接（由它自己发布的 pid 判定）==='
$statusFile = Join-Path $Root 'state\bridge-status.json'
if (Test-Path -LiteralPath $statusFile) {
    try {
        $status = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host ("  pid={0}  polls={1}  lastPoll={2}" -f `
            $status.pid, $status.pollCount, (Get-Date -Date ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$status.lastPollAt).LocalDateTime) -Format 'HH:mm:ss'))
        $p = Get-Process -Id ([int]$status.pid) -ErrorAction SilentlyContinue
        if ($null -ne $p) { Write-Host ("  进程可见: {0}" -f $p.ProcessName) }
        else { Write-Host '  进程不可见（它运行在沙箱之外，这正是 start-pet.cmd 的预期行为）' }
    } catch {
        Write-Host "  读取失败: $($_.Exception.Message)"
    }
} else {
    Write-Host '  （没有 bridge-status.json）'
}
