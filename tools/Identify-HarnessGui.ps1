# Identify-HarnessGui.ps1 - 19387 与 49374 分别是什么？哪个才是用户在用的 GUI？
#
# 这决定了"打开 Harness"应该打开哪个地址。两个端口都提供 DSH 图标，但可能是不同的
# 前端实例（例如一个正在服务、一个只是残留的监听）。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($port in @(19387, 49374)) {
    Write-Host "=== 端口 $port ==="
    foreach ($path in @('/', '/index.html', '/manifest.webmanifest')) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port$path" -UseBasicParsing -TimeoutSec 5
            $len = $r.Content.Length
            # 判断返回的是 SPA 外壳还是登录页
            $kind = 'HTML'
            if ($r.Content -match '<div id="root">') { $kind = 'SPA 外壳（#root）' }
            elseif ($r.Content -match 'policy-login|login') { $kind = '登录/策略页' }
            Write-Host ("  {0,-22} -> {1}  {2}  {3} 字节" -f $path, $r.StatusCode, $kind, $len)
        } catch {
            $code = ''
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            Write-Host ("  {0,-22} -> {1} {2}" -f $path, $(if ($code) { $code } else { 'ERR' }), $_.Exception.Message.Split([Environment]::NewLine)[0])
        }
    }

    # 哪个进程在监听
    $line = netstat -ano | Select-String -Pattern ":$port\s" | Select-String -Pattern 'LISTENING' | Select-Object -First 1
    if ($line) {
        $ownerPid = ($line.ToString().Trim() -split '\s+')[-1]
        $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host ("  监听进程: pid {0}  {1}" -f $ownerPid, $proc.ProcessName)
            Write-Host ("  启动时间: {0}" -f $proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
        } else {
            Write-Host "  监听进程: pid $ownerPid （已退出）"
        }
    }
    Write-Host ''
}

Write-Host '=== 用户在用的 Harness 窗口标题 ==='
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'tools\PetWindowNative.ps1')
foreach ($w in @(Get-AllWindows | Where-Object { $_.Visible -and $_.Title -match 'Harness' -and $_.Title -notmatch '蓝鲸小深' })) {
    $proc = Get-Process -Id $w.Owner -ErrorAction SilentlyContinue
    Write-Host ("  pid {0} {1}  '{2}'" -f $w.Owner, $(if ($proc) { $proc.ProcessName } else { '?' }), $w.Title)
}
