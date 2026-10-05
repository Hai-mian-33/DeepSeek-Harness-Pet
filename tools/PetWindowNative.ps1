# PetWindowNative.ps1 - locate the pet's WPF windows without relying on titles.
#
# `FindWindow(null, title)` is not usable here: the pet's title is Chinese and the
# lookup is subject to console encoding, so it silently returns 0 even while the
# window is on screen. Windows are therefore matched by enumeration plus the
# geometry the pet actually has, which is encoding-independent.

Set-StrictMode -Version Latest

if (-not ('PetWindowNative' -as [type])) {
    Add-Type -Namespace PetWindowNative -Name Win -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc callback, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsIconic(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowTextLength(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder text, int count);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowLong(System.IntPtr hWnd, int index);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
}

# Window style bits used to tell the pet's own window from WPF's hidden helpers.
$script:WS_VISIBLE = 0x10000000
$script:WS_CAPTION = 0x00C00000            # title bar; the pet has none
$script:WS_EX_TOOLWINDOW = 0x00000080
$script:WS_EX_NOACTIVATE = 0x08000000

function Get-AllWindows {
    <#
    .SYNOPSIS
        Every top-level window with its owning process and rectangle.
    #>
    $windows = New-Object System.Collections.Generic.List[object]
    $callback = [PetWindowNative.Win+EnumWindowsProc] {
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        $owner = 0
        [PetWindowNative.Win]::GetWindowThreadProcessId($hWnd, [ref]$owner) | Out-Null
        $rect = New-Object PetWindowNative.Win+RECT
        [PetWindowNative.Win]::GetWindowRect($hWnd, [ref]$rect) | Out-Null
        $length = [PetWindowNative.Win]::GetWindowTextLength($hWnd)
        $builder = New-Object System.Text.StringBuilder ($length + 2)
        [PetWindowNative.Win]::GetWindowText($hWnd, $builder, $builder.Capacity) | Out-Null
        $windows.Add([pscustomobject]@{
            Handle  = $hWnd
            Owner   = [int]$owner
            Title   = $builder.ToString()
            Visible = [PetWindowNative.Win]::IsWindowVisible($hWnd)
            Width   = $rect.Right - $rect.Left
            Height  = $rect.Bottom - $rect.Top
            Left    = $rect.Left
            Top     = $rect.Top
        })
        return $true
    }
    [PetWindowNative.Win]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
    return $windows
}

function Get-PetWindow {
    <#
    .SYNOPSIS
        Find the pet window among every process.
    .DESCRIPTION
        Matched on the traits the pet window actually has: visible, no title bar
        (WS_CAPTION clear), has a non-empty title, and a size within the scaling
        range the pet allows at its sheet aspect ratio.
    #>
    param([int[]]$ProcessIds = @())

    foreach ($window in Get-AllWindows) {
        if (-not $window.Visible) { continue }
        if ($window.Title -eq '') { continue }
        if ($ProcessIds.Count -gt 0 -and ($ProcessIds -notcontains $window.Owner)) { continue }
        $style = [PetWindowNative.Win]::GetWindowLong($window.Handle, -16)
        if (($style -band $script:WS_CAPTION) -ne 0) { continue }
        # Aspect ratio of the sprite cell (192:208) across the whole 50%-200% range.
        $ratio = if ($window.Height -gt 0) { $window.Width / $window.Height } else { 0 }
        if ([Math]::Abs($ratio - (192.0 / 208.0)) -gt 0.06) { continue }
        if ($window.Width -lt 48 -or $window.Width -gt 384) { continue }
        return $window
    }
    return $null
}
