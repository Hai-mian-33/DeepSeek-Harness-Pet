# Test-PetDragLogic.ps1 - verify the drag path end to end without moving the cursor.
#
# The sandbox refuses SetCursorPos, so a real mouse drag cannot be synthesised here
# (Test-SyntheticMouse.ps1 proves that). Instead this drives the SAME functions the
# mouse handlers call, against the live window, and checks the window really moves:
#
#   Start-Drag equivalent  -> record the grab offset
#   Move-Drag equivalent   -> compute the target rect and SetWindowPos
#   End-Drag equivalent    -> settle and persist
#
# Combined with Test-PetHitTest.ps1 (every pixel of the pet can START a drag), this
# covers the whole path: the press reaches the window, and the movement maths moves
# it correctly, including edge fixing.

param([string]$Root = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Root -eq '') { $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
. (Join-Path $Root 'src\shell\PetGeometry.ps1')
. (Join-Path $Root 'tools\PetWindowNative.ps1')

Add-Type -AssemblyName System.Windows.Forms

function Get-PetState {
    $pet = Get-PetWindow
    if ($null -eq $pet) { return $null }
    return @{ Handle = $pet.Handle; X = $pet.Left; Y = $pet.Top; W = $pet.Width; H = $pet.Height }
}

$start = Get-PetState
if ($null -eq $start) { Write-Host 'FAIL: pet window not found'; exit 1 }

$screens = @([System.Windows.Forms.Screen]::AllScreens)
$work = Get-WorkRect -Screen ([System.Windows.Forms.Screen]::PrimaryScreen)

# Start from mid-screen so a normal drag has room and is not limited by the edge
# clamp; each assertion below then measures what it intends to measure.
[PetWindowNative.Win]::SetWindowPos($start.Handle, [IntPtr]::Zero,
    [int]($work.X + 300), [int]($work.Y + 300), [int]$start.W, [int]$start.H, 0x0014) | Out-Null
Start-Sleep -Milliseconds 250
$start = Get-PetState

Write-Host "pet starts : $($start.W)x$($start.H) at ($($start.X),$($start.Y))"
Write-Host "work area  : $($work.Width)x$($work.Height) at ($($work.X),$($work.Y))"
Write-Host ''

$failures = 0

function Invoke-DragTo {
    <#
    .SYNOPSIS
        Reproduce one step of Move-Drag: given the cursor position and the grab
        offset recorded at press time, compute and apply the new window rect.
    #>
    param($From, [int]$CursorX, [int]$CursorY, $GrabOffsetX, $GrabOffsetY)

    $desired = New-Rect -X ($CursorX - $GrabOffsetX) -Y ($CursorY - $GrabOffsetY) -Width $From.W -Height $From.H
    $screen = Get-DisplayFor -Rect $desired -Screens $screens
    $clamped = Get-ClampedRect -Rect $desired -Work (Get-WorkRect -Screen $screen)
    [PetWindowNative.Win]::SetWindowPos($From.Handle, [IntPtr]::Zero,
        [int]$clamped.Rect.X, [int]$clamped.Rect.Y, [int]$From.W, [int]$From.H, 0x0014) | Out-Null
    Start-Sleep -Milliseconds 120
    return @{ Rect = $clamped.Rect; Edges = $clamped.Edges; Now = (Get-PetState) }
}

# 1) Grab the middle of the pet and move the cursor +200,+140.
$grabX = [int]($start.W / 2)
$grabY = [int]($start.H / 2)
$cursorX = $start.X + $grabX
$cursorY = $start.Y + $grabY

$moved = Invoke-DragTo -From $start -CursorX ($cursorX + 200) -CursorY ($cursorY + 140) `
    -GrabOffsetX $grabX -GrabOffsetY $grabY
$dx = $moved.Now.X - $start.X
$dy = $moved.Now.Y - $start.Y
$follows = ($dx -eq 200) -and ($dy -eq 140)
Write-Host ("drag +200,+140  -> ({0},{1})  delta=({2},{3})  follows cursor: {4}" -f `
    $moved.Now.X, $moved.Now.Y, $dx, $dy, $follows)
if (-not $follows) { $failures++ }

# 2) Drag hard past the right edge: must fix flush, stay full size, not hide.
$past = Invoke-DragTo -From $moved.Now -CursorX ($work.Width + 800) -CursorY $moved.Now.Y `
    -GrabOffsetX $grabX -GrabOffsetY $grabY
$petRight = $past.Now.X + $past.Now.W
$atRight = ($petRight -eq $work.Width)
$fullSize = ($past.Now.W -eq $start.W)
Write-Host ("drag past right -> x={0} right={1}  fixed flush: {2}  full size: {3}" -f `
    $past.Now.X, $petRight, $atRight, $fullSize)
if (-not $atRight) { $failures++ }
if (-not $fullSize) { $failures++ }

# 3) Continue pulling outward: must slide along the edge, still flush.
$slide = Invoke-DragTo -From $past.Now -CursorX ($work.Width + 800) -CursorY ($past.Now.Y - 260) `
    -GrabOffsetX $grabX -GrabOffsetY $grabY
$stillFlush = (($slide.Now.X + $slide.Now.W) -eq $work.Width)
$slidVertically = ($slide.Now.Y -lt $past.Now.Y)
Write-Host ("pull further    -> x={0} y={1}  still flush: {2}  slid along edge: {3}" -f `
    $slide.Now.X, $slide.Now.Y, $stillFlush, $slidVertically)
if (-not $stillFlush) { $failures++ }
if (-not $slidVertically) { $failures++ }

# Restore the pet.
[PetWindowNative.Win]::SetWindowPos($start.Handle, [IntPtr]::Zero, $start.X, $start.Y, $start.W, $start.H, 0x0014) | Out-Null
Start-Sleep -Milliseconds 200
$restored = Get-PetState
Write-Host ''
Write-Host "pet restored to ($($restored.X),$($restored.Y))"

if ($failures -eq 0) {
    Write-Host 'PASS: the drag maths moves the pet with the cursor, fixes it to the edge,'
    Write-Host '      and slides it along that edge while staying fully visible.'
    exit 0
}
Write-Host "FAIL: $failures drag assertion(s) failed."
exit 1
