/**
 * Window geometry for the pet: edge fixing, multi-monitor work areas, display
 * overlays, inertia and position persistence.
 *
 * This is where the product differs from ChatGPT's pet and most open-source
 * desktop pets. Those half-hide at a screen edge (GooglePiggy tucks its tail
 * away). Here an edge is a *fixture*: the pet is pinned flush to the physical
 * edge of the monitor it is on and can only slide along it — it is never
 * hidden, and an interior seam between two monitors is not an edge at all.
 *
 * Everything is pure geometry over plain rectangles so it can be unit tested
 * without a window.
 *
 * @module geometry
 */

import { clamp } from './clock.mjs';

/** @typedef {{x: number, y: number, width: number, height: number}} Rect */
/** @typedef {{x: number, y: number}} Vec2 */

/** Intersection of two rectangles, or `null` when they do not overlap. */
export function intersect(a, b) {
  const x = Math.max(a.x, b.x);
  const y = Math.max(a.y, b.y);
  const right = Math.min(a.x + a.width, b.x + b.width);
  const bottom = Math.min(a.y + a.height, b.y + b.height);
  if (right <= x || bottom <= y) return null;
  return { x, y, width: right - x, height: bottom - y };
}

/** Area of a rectangle (0 for degenerate input). */
export function area(rect) {
  return Math.max(0, rect.width) * Math.max(0, rect.height);
}

/** Overlap area between two rectangles. */
export function overlapArea(a, b) {
  const hit = intersect(a, b);
  return hit === null ? 0 : area(hit);
}

/** Center point of a rectangle. */
export function centerOf(rect) {
  return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
}

/**
 * Pick the display that owns the window.
 *
 * Overlap area decides, so a window spanning a seam belongs to the monitor it
 * mostly covers. When it overlaps nothing (it was dragged fully off-screen) the
 * nearest display by centre distance wins, which is what makes recovery from an
 * off-screen position possible.
 *
 * @param {Rect} petRect current window rectangle
 * @param {Array<{id: string|number, workArea: Rect}>} displays monitor list
 */
export function displayFor(petRect, displays) {
  if (displays.length === 0) return null;
  let best = null;
  let bestOverlap = 0;
  for (const display of displays) {
    const overlap = overlapArea(petRect, display.workArea);
    if (overlap > bestOverlap) {
      bestOverlap = overlap;
      best = display;
    }
  }
  if (best !== null) return best;

  const petCenter = centerOf(petRect);
  let nearest = displays[0];
  let nearestDistance = Infinity;
  for (const display of displays) {
    const displayCenter = centerOf(display.workArea);
    const dx = displayCenter.x - petCenter.x;
    const dy = displayCenter.y - petCenter.y;
    const distance = dx * dx + dy * dy;
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = display;
    }
  }
  return nearest;
}

/**
 * Fraction of a rectangle's area that lies inside another rectangle.
 */
export function containment(rect, container) {
  const own = area(rect);
  if (own <= 0) return 0;
  return overlapArea(rect, container) / own;
}

/**
 * Clamp a window rectangle into a display's work area, fixing (not hiding) any
 * edge that would otherwise leave the screen.
 *
 * The pet is never partially off-screen: each axis is pinned flush to the
 * boundary it crossed, and a window larger than the work area is pinned to the
 * top-left so it still starts inside the visible region.
 *
 * @param {Rect} petRect desired rectangle
 * @param {Rect} workArea target display work area
 * @returns {{rect: Rect, edges: {left: boolean, right: boolean, top: boolean, bottom: boolean}}}
 */
export function clampToWorkArea(petRect, workArea) {
  const maxX = workArea.x + Math.max(0, workArea.width - petRect.width);
  const maxY = workArea.y + Math.max(0, workArea.height - petRect.height);
  const x = clamp(petRect.x, workArea.x, Math.max(workArea.x, maxX));
  const y = clamp(petRect.y, workArea.y, Math.max(workArea.y, maxY));
  return {
    rect: { x, y, width: petRect.width, height: petRect.height },
    edges: {
      left: x <= workArea.x,
      right: x >= maxX,
      top: y <= workArea.y,
      bottom: y >= maxY,
    },
  };
}

/**
 * Axis interval the window may occupy across the whole arrangement.
 *
 * The bounds are the outer extremes of every work area, so an interior seam
 * falls *inside* the interval and the pet can sit on it or be dragged across it.
 * Only the arrangement's own outer boundary ends the interval. (Displays
 * arranged with an actual gap between them would still count the gap as
 * traversable; Windows does not produce that for a normal desktop, and allowing
 * it is the same trade as the seam.)
 */
function axisRange(rects, axis, size) {
  const key = axis === 'x' ? 'width' : 'height';
  let min = Infinity;
  let max = -Infinity;
  for (const rect of rects) {
    min = Math.min(min, rect[axis]);
    max = Math.max(max, rect[axis] + rect[key]);
  }
  if (min === Infinity) return null;
  return [min, Math.max(min, max - size)];
}

/** Clamp `value` into one inclusive interval. */
function clampToRange(value, range) {
  if (range === null) return value;
  const [start, end] = range;
  if (end < start) return start;
  return clamp(value, start, end);
}

/**
 * Which edges is `rect` fixed against, out of its axis ranges?
 *
 * An edge counts only when the rect actually sits on that boundary *and* the
 * arrangement ends there. Two monitors abutting leave a shared boundary that
 * another monitor continues past, so the pet may sit on it (and be dragged
 * across it) without being fixed.
 */
function outerEdges(rect, displays, xRange, yRange) {
  const rects = displays.map((display) => display.workArea);
  const tolerance = 1;

  const anyLeftOf = rects.some((r) => r.x + r.width <= rect.x + tolerance);
  const anyRightOf = rects.some((r) => r.x >= rect.x + rect.width - tolerance);

  const xMin = xRange === null ? rect.x : xRange[0];
  const xMax = xRange === null ? rect.x : xRange[1];
  const yMin = yRange === null ? rect.y : yRange[0];
  const yMax = yRange === null ? rect.y : yRange[1];

  return {
    left: Math.abs(rect.x - xMin) <= tolerance && !anyLeftOf,
    right: Math.abs(rect.x - xMax) <= tolerance && !anyRightOf,
    top: Math.abs(rect.y - yMin) <= tolerance,
    bottom: Math.abs(rect.y - yMax) <= tolerance,
  };
}

/**
 * Resolve a desired window rectangle against the full display arrangement.
 *
 * @param {Rect} petRect desired rectangle
 * @param {Array<{id: string|number, workArea: Rect}>} displays monitor list
 * @returns {{rect: Rect, anchor: string[], atSeam: boolean, straddling: boolean}}
 */
export function resolveOnDisplays(petRect, displays) {
  if (displays.length === 0) return { rect: petRect, anchor: [], atSeam: false, straddling: false };

  // A pet that straddles a seam is already somewhere legitimate: leave it
  // alone rather than letting one monitor's work area push it back.
  const straddling = displays.some((display) => containment(petRect, display.workArea) >= 0.999) === false
    && displays.some((display) => containment(petRect, display.workArea) > 0.2);

  const xRange = axisRange(displays.map((d) => d.workArea), 'x', petRect.width);
  const yRange = axisRange(displays.map((d) => d.workArea), 'y', petRect.height);
  const x = clampToRange(petRect.x, xRange);
  const y = clampToRange(petRect.y, yRange);

  const rect = { x, y, width: petRect.width, height: petRect.height };
  const outer = outerEdges(rect, displays, xRange, yRange);
  const anchor = Object.entries(outer).filter(([, on]) => on).map(([edge]) => edge);
  return { rect, anchor, atSeam: straddling, straddling };
}

/**
 * Diagnostic form of the brief's `clampPosition`: describes which edges are
 * anchored (used by tests and the shell's edge feedback).
 *
 * @param {Rect} petRect desired rectangle
 * @param {Array<{id: string|number, workArea: Rect}>} displays monitor list
 * @param {Array<Rect>} [seams] interior seams that must not attract the pet
 */
export function clampPosition(petRect, displays, seams = []) {
  const display = displayFor(petRect, displays);
  if (display === null) return { rect: petRect, anchor: [], displayId: null, seamsIgnored: seams.length };
  const resolved = resolveOnDisplays(petRect, displays);
  return {
    rect: resolved.rect,
    anchor: resolved.anchor,
    displayId: display.id,
    atSeam: resolved.straddling || seams.some((seam) => isOnSeam(resolved.rect, seam)),
    seamsIgnored: seams.length,
  };
}

/** Whether a window sits exactly on an interior seam (two monitors abutting). */
export function isOnSeam(rect, seam) {
  const tolerance = 1;
  if (seam.width <= seam.height) {
    // Vertical seam line.
    return Math.abs(rect.x + rect.width - seam.x) <= tolerance || Math.abs(rect.x - (seam.x + seam.width)) <= tolerance;
  }
  // Horizontal seam line.
  return Math.abs(rect.y + rect.height - seam.y) <= tolerance || Math.abs(rect.y - (seam.y + seam.height)) <= tolerance;
}

/**
 * Derive interior seams from a display list.
 *
 * A seam is a shared boundary between two monitors. The pet may cross it while
 * being dragged, but it must not be treated as an edge to fix against.
 *
 * @param {Array<{id: string|number, workArea: Rect}>} displays
 * @returns {Array<Rect>} zero-thickness rectangles describing each seam
 */
export function seamsOf(displays) {
  const seams = [];
  for (let i = 0; i < displays.length; i++) {
    for (let j = i + 1; j < displays.length; j++) {
      const a = displays[i].workArea;
      const b = displays[j].workArea;
      const verticalOverlap = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
      const horizontalOverlap = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
      const touchLeftRight = Math.abs(a.x + a.width - b.x) <= 1 || Math.abs(b.x + b.width - a.x) <= 1;
      const touchTopBottom = Math.abs(a.y + a.height - b.y) <= 1 || Math.abs(b.y + b.height - a.y) <= 1;
      if (touchLeftRight && verticalOverlap > 0) {
        const x = Math.abs(a.x + a.width - b.x) <= 1 ? b.x : a.x;
        const y = Math.max(a.y, b.y);
        seams.push({ x, y, width: 0, height: verticalOverlap, orientation: 'vertical' });
      } else if (touchTopBottom && horizontalOverlap > 0) {
        const y = Math.abs(a.y + a.height - b.y) <= 1 ? b.y : a.y;
        const x = Math.max(a.x, b.x);
        seams.push({ x, y, width: horizontalOverlap, height: 0, orientation: 'horizontal' });
      }
    }
  }
  return seams;
}

/**
 * Integrate one drag step with edge fixing.
 *
 * The window follows the cursor; when the cursor would carry an edge past the
 * physical boundary the position is pinned there, so continuing to pull outward
 * only slides the pet along the edge.
 *
 * @param {object} input
 * @param {Rect} input.petRect current rectangle
 * @param {Vec2} input.pointer current cursor position (screen coordinates)
 * @param {Vec2} input.grabOffset cursor offset inside the window at grab time
 * @param {Array<{id: string|number, workArea: Rect}>} input.displays
 * @param {number} input.dtMs step duration for velocity estimation
 * @param {number} [input.maxStepMs] cap so a stalled frame cannot inflate speed
 */
export function dragStep({ petRect, pointer, grabOffset, displays, dtMs, maxStepMs = 64 }) {
  const desired = {
    x: Math.round(pointer.x - grabOffset.x),
    y: Math.round(pointer.y - grabOffset.y),
    width: petRect.width,
    height: petRect.height,
  };
  const seams = seamsOf(displays);
  const { rect, anchor, displayId, atSeam } = clampPosition(desired, displays, seams);
  const dt = clamp(dtMs, 1, maxStepMs);
  const velocity = {
    x: ((rect.x - petRect.x) / dt) * 1000,
    y: ((rect.y - petRect.y) / dt) * 1000,
  };
  return { rect, anchor, displayId, atSeam, velocity };
}

/**
 * Advance one inertia frame after release.
 *
 * A flick glides and settles with a small rotation that returns to upright; a
 * gentle placement only gives a single soft bounce (the brief's 轻放只做一次轻微回弹).
 *
 * "Gentle" is decided by how far the throw *would* travel, not by its speed: a
 * release whose whole glide would cover only a few pixels is a placement, and
 * bouncing it reads better than sliding it a hair. Anything with real travel
 * glides to a stop.
 *
 * @param {object} input
 * @param {Rect} input.petRect
 * @param {Vec2} input.velocity pixels per second
 * @param {number} input.dtMs
 * @param {number} input.decayPerSecond velocity retained per second
 * @param {number} input.stopSpeed below this the glide ends
 * @param {number} input.bounceTravelPx glide distance under which a release is a placement
 * @param {Array<{id: string|number, workArea: Rect}>} input.displays
 */
export function inertiaStep({
  petRect,
  velocity,
  dtMs,
  decayPerSecond = 0.06,
  stopSpeed = 24,
  bounceTravelPx = 60,
  displays,
}) {
  const dt = clamp(dtMs, 1, 64) / 1000;
  const speed = Math.hypot(velocity.x, velocity.y);
  // Total glide distance of an exponentially decaying velocity: ∫v dt = v/ln(1/k).
  const travel = speed / Math.abs(Math.log(clamp(decayPerSecond, 0.001, 0.999)));
  const light = travel < bounceTravelPx;

  const decay = Math.pow(decayPerSecond, dt);
  const nextVelocity = { x: velocity.x * decay, y: velocity.y * decay };
  const desired = {
    x: Math.round(petRect.x + velocity.x * dt),
    y: Math.round(petRect.y + velocity.y * dt),
    width: petRect.width,
    height: petRect.height,
  };
  const seams = seamsOf(displays);
  const { rect, anchor, displayId } = clampPosition(desired, displays, seams);

  if (light) {
    // A placement does not travel: hold the position and report one bounce.
    const held = clampPosition(petRect, displays, seams);
    return {
      rect: held.rect,
      velocity: { x: 0, y: 0 },
      settled: true,
      tiltDeg: 0,
      bounce: 1,
      anchor: held.anchor,
      displayId,
    };
  }

  const nextSpeed = Math.hypot(nextVelocity.x, nextVelocity.y);
  const settled = nextSpeed <= stopSpeed;
  return {
    rect,
    velocity: settled ? { x: 0, y: 0 } : nextVelocity,
    settled,
    // Tilt follows horizontal speed and unwinds as the glide settles.
    tiltDeg: settled ? 0 : clamp(nextVelocity.x / 90, -10, 10),
    bounce: 0,
    anchor,
    displayId,
  };
}

/**
 * Normalized position for persistence, plus a resolver back to pixels.
 *
 * Position is stored per display key and normalized to the work area so a
 * resolution or taskbar change re-clamps into the same relative spot.
 *
 * @param {Rect} petRect
 * @param {Rect} workArea
 * @param {string|number} displayKey stable-ish identity of the monitor
 */
export function normalizePosition(petRect, workArea, displayKey) {
  const spanX = Math.max(1, workArea.width - petRect.width);
  const spanY = Math.max(1, workArea.height - petRect.height);
  return {
    displayKey: String(displayKey),
    nx: clamp((petRect.x - workArea.x) / spanX, 0, 1),
    ny: clamp((petRect.y - workArea.y) / spanY, 0, 1),
    width: petRect.width,
    height: petRect.height,
  };
}

/**
 * Resolve a stored normalized position back into pixels.
 *
 * @param {{nx: number, ny: number}} stored
 * @param {Rect} workArea
 * @param {{width: number, height: number}} size
 */
export function denormalizePosition(stored, workArea, size) {
  const spanX = Math.max(0, workArea.width - size.width);
  const spanY = Math.max(0, workArea.height - size.height);
  const desired = {
    x: Math.round(workArea.x + clamp(stored.nx, 0, 1) * spanX),
    y: Math.round(workArea.y + clamp(stored.ny, 0, 1) * spanY),
    width: size.width,
    height: size.height,
  };
  return clampToWorkArea(desired, workArea).rect;
}

/**
 * Place the popup (bubble or expanded list) next to the pet without leaving the
 * screen: above the pet when there is room, otherwise below, then clamped
 * horizontally and vertically inside the same work area.
 *
 * @param {object} input
 * @param {Rect} input.anchorRect pet rectangle
 * @param {{width: number, height: number}} input.size popup size
 * @param {Rect} input.workArea
 * @param {number} [input.gap] space between pet and popup
 * @param {number} [input.margin] minimum distance from the work-area edge
 */
export function placePopup({ anchorRect, size, workArea, gap = 8, margin = 6 }) {
  const anchorCenterX = anchorRect.x + anchorRect.width / 2;
  const left = clamp(
    Math.round(anchorCenterX - size.width / 2),
    workArea.x + margin,
    Math.max(workArea.x + margin, workArea.x + workArea.width - size.width - margin),
  );

  const spaceAbove = anchorRect.y - workArea.y;
  const spaceBelow = workArea.y + workArea.height - (anchorRect.y + anchorRect.height);
  const preferAbove = spaceAbove >= size.height + gap;
  const placement = preferAbove || spaceBelow < size.height + gap ? 'above' : 'below';

  let top = placement === 'above' ? anchorRect.y - size.height - gap : anchorRect.y + anchorRect.height + gap;
  top = clamp(
    top,
    workArea.y + margin,
    Math.max(workArea.y + margin, workArea.y + workArea.height - size.height - margin),
  );

  return { placement, rect: { x: left, y: Math.round(top), width: size.width, height: size.height } };
}

/** Which screen edges the window is currently fixed to, for tests and logs. */
export function edgeAnchor(rect, workArea) {
  const tolerance = 1;
  return {
    left: Math.abs(rect.x - workArea.x) <= tolerance,
    right: Math.abs(rect.x + rect.width - (workArea.x + workArea.width)) <= tolerance,
    top: Math.abs(rect.y - workArea.y) <= tolerance,
    bottom: Math.abs(rect.y + rect.height - (workArea.y + workArea.height)) <= tolerance,
  };
}
