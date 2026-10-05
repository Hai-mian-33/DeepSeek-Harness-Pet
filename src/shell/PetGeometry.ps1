# PetGeometry.ps1 — window placement math for the desktop pet.
#
# Pure functions over rectangles. They mirror src/core/geometry.mjs, which is
# the unit-tested reference implementation: the JavaScript side is the
# specification, this side is what runs inside the WPF shell. Keep the two in
# step; tests/geometry.test.mjs covers the reference behaviour and documents the
# contract these functions must satisfy.
#
# The product rule both sides implement (and the deliberate difference from
# ChatGPT's pet and GooglePiggy): an edge is a FIXTURE, not a hiding place. The
# pet pins flush to the physical edge of the monitor it is on and slides along
# it; it is never tucked away, and a seam between two monitors is not an edge.

Set-StrictMode -Version Latest

function New-Rect {
    param([double]$X, [double]$Y, [double]$Width, [double]$Height)
    [pscustomobject]@{ X = $X; Y = $Y; Width = $Width; Height = $Height }
}

function Get-WorkRect {
    param($Screen)
    New-Rect -X $Screen.WorkingArea.X -Y $Screen.WorkingArea.Y `
        -Width $Screen.WorkingArea.Width -Height $Screen.WorkingArea.Height
}

function Get-OverlapArea {
    param($A, $B)
    $w = [Math]::Min($A.X + $A.Width, $B.X + $B.Width) - [Math]::Max($A.X, $B.X)
    $h = [Math]::Min($A.Y + $A.Height, $B.Y + $B.Height) - [Math]::Max($A.Y, $B.Y)
    if ($w -le 0 -or $h -le 0) { return 0 }
    return $w * $h
}

<#
.SYNOPSIS
    Pick the monitor that owns a window rectangle.
.DESCRIPTION
    Overlap area decides, so a window straddling a seam belongs to the monitor
    it mostly covers. A rectangle overlapping nothing (dragged fully off-screen)
    resolves to the nearest monitor by centre distance, which is what makes
    recovery from an off-screen position possible.
#>
function Get-DisplayFor {
    param($Rect, $Screens)
    $best = $null
    $bestOverlap = 0
    foreach ($screen in $Screens) {
        $area = Get-OverlapArea -A $Rect -B (Get-WorkRect -Screen $screen)
        if ($area -gt $bestOverlap) { $bestOverlap = $area; $best = $screen }
    }
    if ($null -ne $best) { return $best }

    $cx = $Rect.X + $Rect.Width / 2
    $cy = $Rect.Y + $Rect.Height / 2
    $nearest = $null
    $nearestDistance = [double]::PositiveInfinity
    foreach ($screen in $Screens) {
        $work = Get-WorkRect -Screen $screen
        $dx = ($work.X + $work.Width / 2) - $cx
        $dy = ($work.Y + $work.Height / 2) - $cy
        $distance = $dx * $dx + $dy * $dy
        if ($distance -lt $nearestDistance) { $nearestDistance = $distance; $nearest = $screen }
    }
    return $nearest
}

<#
.SYNOPSIS
    Fix a rectangle inside a work area, pinning crossed edges instead of hiding.
.OUTPUTS
    PSCustomObject with Rect and an Edges record naming the pinned edges.
#>
function Get-ClampedRect {
    param($Rect, $Work)
    $maxX = $Work.X + [Math]::Max(0, $Work.Width - $Rect.Width)
    $maxY = $Work.Y + [Math]::Max(0, $Work.Height - $Rect.Height)

    $x = [Math]::Min([Math]::Max($Rect.X, $Work.X), [Math]::Max($Work.X, $maxX))
    $y = [Math]::Min([Math]::Max($Rect.Y, $Work.Y), [Math]::Max($Work.Y, $maxY))

    [pscustomobject]@{
        Rect  = (New-Rect -X $x -Y $y -Width $Rect.Width -Height $Rect.Height)
        Edges = [pscustomobject]@{
            Left   = ($x -le $Work.X)
            Right  = ($x -ge $maxX)
            Top    = ($y -le $Work.Y)
            Bottom = ($y -ge $maxY)
        }
    }
}

<#
.SYNOPSIS
    Areas two monitors share, so an interior seam can be excluded from edge
    fixing. Returns slim rectangles along the touching boundary.
#>
function Get-SeamRects {
    param($Screens)
    $seams = @()
    $rects = @($Screens | ForEach-Object { Get-WorkRect -Screen $_ })
    for ($i = 0; $i -lt $rects.Count; $i++) {
        for ($j = $i + 1; $j -lt $rects.Count; $j++) {
            $a = $rects[$i]; $b = $rects[$j]
            $vOverlap = [Math]::Min($a.Y + $a.Height, $b.Y + $b.Height) - [Math]::Max($a.Y, $b.Y)
            $hOverlap = [Math]::Min($a.X + $a.Width, $b.X + $b.Width) - [Math]::Max($a.X, $b.X)
            $touchLR = ([Math]::Abs($a.X + $a.Width - $b.X) -le 1) -or ([Math]::Abs($b.X + $b.Width - $a.X) -le 1)
            $touchTB = ([Math]::Abs($a.Y + $a.Height - $b.Y) -le 1) -or ([Math]::Abs($b.Y + $b.Height - $a.Y) -le 1)
            if ($touchLR -and $vOverlap -gt 0) {
                $x = if ([Math]::Abs($a.X + $a.Width - $b.X) -le 1) { $b.X } else { $a.X }
                $seams += New-Rect -X $x -Y ([Math]::Max($a.Y, $b.Y)) -Width 0 -Height $vOverlap
            }
            elseif ($touchTB -and $hOverlap -gt 0) {
                $y = if ([Math]::Abs($a.Y + $a.Height - $b.Y) -le 1) { $b.Y } else { $a.Y }
                $seams += New-Rect -X ([Math]::Max($a.X, $b.X)) -Y $y -Width $hOverlap -Height 0
            }
        }
    }
    return $seams
}

<#
.SYNOPSIS
    Place a popup next to the pet without leaving the screen.
.DESCRIPTION
    Prefers above the pet; flips below when there is no room above and room
    below; always clamps horizontally and vertically into the same work area.
#>
function Get-PopupPlacement {
    param($AnchorRect, $Size, $Work, [double]$Gap = 8, [double]$Margin = 6)

    $anchorCenterX = $AnchorRect.X + $AnchorRect.Width / 2
    $left = [Math]::Min(
        [Math]::Max($anchorCenterX - $Size.Width / 2, $Work.X + $Margin),
        [Math]::Max($Work.X + $Margin, $Work.X + $Work.Width - $Size.Width - $Margin))

    $spaceAbove = $AnchorRect.Y - $Work.Y
    $spaceBelow = $Work.Y + $Work.Height - ($AnchorRect.Y + $AnchorRect.Height)
    $placement = if ($spaceAbove -ge $Size.Height + $Gap) { 'above' }
                 elseif ($spaceBelow -ge $Size.Height + $Gap) { 'below' }
                 elseif ($spaceAbove -ge $spaceBelow) { 'above' }
                 else { 'below' }

    $top = if ($placement -eq 'above') { $AnchorRect.Y - $Size.Height - $Gap }
           else { $AnchorRect.Y + $AnchorRect.Height + $Gap }
    $top = [Math]::Min(
        [Math]::Max($top, $Work.Y + $Margin),
        [Math]::Max($Work.Y + $Margin, $Work.Y + $Work.Height - $Size.Height - $Margin))

    [pscustomobject]@{
        Placement = $placement
        Rect      = (New-Rect -X ([Math]::Round($left)) -Y ([Math]::Round($top)) -Width $Size.Width -Height $Size.Height)
    }
}

<#
.SYNOPSIS
    Advance one inertia frame after a drag release.
.DESCRIPTION
    A flick glides and settles with a small tilt that unwinds to upright; a
    gentle placement produces no glide at all (the brief's 轻放只做一次轻微回弹 is
    the shell's single bounce animation, driven by the returned Bounce flag).
#>
function Get-InertiaStep {
    param($Rect, $VelocityX, $VelocityY, [double]$DtMs, $Screens,
        [double]$DecayPerSecond = 0.06, [double]$StopSpeed = 24, [double]$LightSpeed = 260)

    $dt = [Math]::Min([Math]::Max($DtMs, 1), 64) / 1000.0
    $speed = [Math]::Sqrt($VelocityX * $VelocityX + $VelocityY * $VelocityY)
    $light = $speed -lt $LightSpeed

    $decay = [Math]::Pow($DecayPerSecond, $dt)
    $nextVx = $VelocityX * $decay
    $nextVy = $VelocityY * $decay

    $desired = New-Rect -X ([Math]::Round($Rect.X + $VelocityX * $dt)) `
        -Y ([Math]::Round($Rect.Y + $VelocityY * $dt)) -Width $Rect.Width -Height $Rect.Height
    $target = Get-DisplayFor -Rect $desired -Screens $Screens
    $clamped = Get-ClampedRect -Rect $desired -Work (Get-WorkRect -Screen $target)

    $nextSpeed = [Math]::Sqrt($nextVx * $nextVx + $nextVy * $nextVy)
    $settled = $light -or ($nextSpeed -le $StopSpeed)

    [pscustomobject]@{
        Rect      = $clamped.Rect
        Edges     = $clamped.Edges
        Settled   = $settled
        VelocityX = if ($settled) { 0 } else { $nextVx }
        VelocityY = if ($settled) { 0 } else { $nextVy }
        TiltDeg   = if ($settled) { 0 } else { [Math]::Min([Math]::Max($nextVx / 90, -10), 10) }
        Bounce    = ($light -and -not $settled)
    }
}

<#
.SYNOPSIS
    Normalize a position inside its work area for persistence, so a resolution
    or taskbar change restores the pet into the same relative spot.
#>
function Get-NormalizedPosition {
    param($Rect, $Work)
    $spanX = [Math]::Max(1, $Work.Width - $Rect.Width)
    $spanY = [Math]::Max(1, $Work.Height - $Rect.Height)
    [pscustomobject]@{
        NX = [Math]::Min([Math]::Max(($Rect.X - $Work.X) / $spanX, 0), 1)
        NY = [Math]::Min([Math]::Max(($Rect.Y - $Work.Y) / $spanY, 0), 1)
    }
}

function Get-DenormalizedRect {
    param([double]$NX, [double]$NY, $Work, $Size)
    $spanX = [Math]::Max(0, $Work.Width - $Size.Width)
    $spanY = [Math]::Max(0, $Work.Height - $Size.Height)
    $desired = New-Rect -X ([Math]::Round($Work.X + $NX * $spanX)) `
        -Y ([Math]::Round($Work.Y + $NY * $spanY)) -Width $Size.Width -Height $Size.Height
    (Get-ClampedRect -Rect $desired -Work $Work).Rect
}
