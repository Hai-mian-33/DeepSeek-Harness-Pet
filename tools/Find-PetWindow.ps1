# Find-PetWindow.ps1 - locate the pet's WPF windows for verification.
#
# Windows are matched by owning process and by the geometry the pet is expected
# to have, not by window title: a window title is subject to console encoding
# when read back, while the rectangle is not.

param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [int[]]$ProcessIds = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -Namespace PetProbe -Name Native -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc callback, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowTextLength(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder text, int count);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowLong(System.IntPtr hWnd, int index);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@

$configPath = Join-Path $Root 'state\shell-config.json'
$config = $null
if (Test-Path -LiteralPath $configPath) {
    try { $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}

# Every PowerShell process other than this one is a candidate: the shell is
# launched as a hidden child, so it has no console of its own to identify it by.
$candidates = @(Get-Process powershell, pwsh -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -ne $PID -and ($ProcessIds.Count -eq 0 -or $ProcessIds -contains $_.Id) } |
    Select-Object -ExpandProperty Id)

$found = New-Object System.Collections.Generic.List[object]
$callback = [PetProbe.Native+EnumWindowsProc] {
    param([IntPtr]$hWnd, [IntPtr]$lParam)
    $owner = 0
    [PetProbe.Native]::GetWindowThreadProcessId($hWnd, [ref]$owner) | Out-Null
    if ($candidates -contains [int]$owner) {
        $length = [PetProbe.Native]::GetWindowTextLength($hWnd)
        $builder = New-Object System.Text.StringBuilder ($length + 2)
        [PetProbe.Native]::GetWindowText($hWnd, $builder, $builder.Capacity) | Out-Null
        $rect = New-Object PetProbe.Native+RECT
        [PetProbe.Native]::GetWindowRect($hWnd, [ref]$rect) | Out-Null
        $found.Add([pscustomobject]@{
            Handle  = $hWnd.ToInt64()
            Owner   = [int]$owner
            Title   = $builder.ToString()
            Visible = [PetProbe.Native]::IsWindowVisible($hWnd)
            Width   = $rect.Right - $rect.Left
            Height  = $rect.Bottom - $rect.Top
            Left    = $rect.Left
            Top     = $rect.Top
        })
    }
    return $true
}
[PetProbe.Native]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null

Write-Host "candidate processes: $($candidates -join ', ')"
if ($null -ne $config) {
    Write-Host "stored config: scale=$($config.scale) display=$($config.displayKey) norm=($([math]::Round($config.nx,3)),$([math]::Round($config.ny,3))) px=($($config.x),$($config.y))"
} else {
    Write-Host "stored config: (none)"
}
Write-Host ""
if ($found.Count -eq 0) {
    Write-Host "no windows found for those processes"
    exit 1
}
foreach ($window in $found | Sort-Object Owner, Handle) {
    Write-Host ("hwnd={0,-10} pid={1,-7} {2,4}x{3,-4} at ({4},{5}) visible={6} title='{7}'" -f `
        $window.Handle, $window.Owner, $window.Width, $window.Height, $window.Left, $window.Top, $window.Visible, $window.Title)
}
