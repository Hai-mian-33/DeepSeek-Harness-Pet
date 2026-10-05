/**
 * Geometry tests — the acceptance-critical half of the pet.
 *
 * These cover the behaviour the brief singles out as the product's
 * differentiator: dragging to an edge fixes the pet there instead of hiding it,
 * an interior monitor seam is not an edge, and a display change re-clamps the
 * window so it can never be left off-screen.
 *
 * Run: node --test tests/
 */

import assert from 'node:assert/strict';
import test from 'node:test';

import {
  clampPosition,
  clampToWorkArea,
  denormalizePosition,
  displayFor,
  dragStep,
  edgeAnchor,
  inertiaStep,
  isOnSeam,
  normalizePosition,
  overlapArea,
  placePopup,
  seamsOf,
} from '../src/core/geometry.mjs';

/** Two 1920x1080 monitors side by side, each with a 40 px taskbar. */
const single = [
  { id: 'primary', workArea: { x: 0, y: 0, width: 1920, height: 1040 } },
];

const dual = [
  { id: 'left', workArea: { x: 0, y: 0, width: 1920, height: 1040 } },
  { id: 'right', workArea: { x: 1920, y: 0, width: 1920, height: 1040 } },
];

/** A 96x104 pet at (x, y). */
const pet = (x, y, width = 96, height = 104) => ({ x, y, width, height });

test('clampToWorkArea pins a crossed edge flush instead of hiding the pet', () => {
  const workArea = single[0].workArea;
  const beyond = clampToWorkArea(pet(3000, 500), workArea);
  assert.equal(beyond.rect.x, workArea.width - 96, 'right edge fixed flush');
  assert.equal(beyond.rect.width, 96, 'full width retained — never partially hidden');
  assert.equal(beyond.edges.right, true);

  const beyondLeft = clampToWorkArea(pet(-500, 500), workArea);
  assert.equal(beyondLeft.rect.x, 0);
  assert.equal(beyondLeft.edges.left, true);
});

test('clampToWorkArea respects the taskbar as the bottom edge', () => {
  const result = clampToWorkArea(pet(500, 5000), single[0].workArea);
  assert.equal(result.rect.y, 1040 - 104);
  assert.equal(result.edges.bottom, true);
});

test('dragging outward past an edge slides along it rather than leaving the screen', () => {
  const workArea = single[0].workArea;
  // Cursor keeps moving right while already pinned at the right edge.
  const first = dragStep({
    petRect: pet(1800, 400),
    pointer: { x: 2600, y: 430 },
    grabOffset: { x: 20, y: 20 },
    displays: single,
    dtMs: 16,
  });
  assert.equal(first.anchor.includes('right'), true);

  const second = dragStep({
    petRect: first.rect,
    pointer: { x: 3400, y: 470 },
    grabOffset: { x: 20, y: 20 },
    displays: single,
    dtMs: 16,
  });
  assert.equal(second.rect.x, workArea.width - 96, 'still pinned');
  assert.equal(second.rect.y, 450, 'vertical movement continues along the edge');
});

test('a monitor seam does not attract the pet', () => {
  const seams = seamsOf(dual);
  assert.equal(seams.length, 1, 'one interior seam between the two work areas');
  assert.equal(seams[0].orientation, 'vertical');

  // Straddling the seam: the pet belongs to whichever monitor it mostly covers
  // and is NOT fixed to the seam itself.
  const straddling = pet(1900, 400);
  const result = clampPosition(straddling, dual, seams);
  assert.deepEqual(result.rect, straddling, 'position untouched at the seam');
  assert.equal(result.anchor.length, 0, 'no edge anchoring at an interior seam');
});

test('the physical outer edge of a monitor still fixes the pet', () => {
  // Right edge of the *right* monitor at x = 3840.
  const result = clampPosition(pet(3900, 400), dual, seamsOf(dual));
  assert.equal(result.displayId, 'right');
  assert.equal(result.rect.x, 3840 - 96);
  assert.deepEqual(result.anchor, ['right']);
});

test('crossing the seam keeps the pet whole and moving', () => {
  let rect = pet(1830, 500);
  for (const cursorX of [1900, 1980, 2060, 2140]) {
    const step = dragStep({
      petRect: rect,
      pointer: { x: cursorX, y: 560 },
      grabOffset: { x: 48, y: 52 },
      displays: dual,
      dtMs: 16,
    });
    rect = step.rect;
    assert.equal(rect.width, 96, 'width never shrinks while crossing');
  }
  assert.ok(rect.x > 1920, 'the pet ended up on the second monitor');
});

test('a fully off-screen window resolves to the nearest monitor and comes back', () => {
  const rescue = clampPosition(pet(-4000, -3000), dual);
  assert.equal(rescue.rect.x, 0, 'clamped into a real work area');
  assert.equal(rescue.rect.y, 0);
  assert.ok(rescue.displayId !== null);
});

test('display resolution and taskbar changes re-clamp a stored position', () => {
  const stored = normalizePosition(pet(1800, 900), single[0].workArea, 'primary');
  assert.equal(stored.displayKey, 'primary');
  assert.ok(stored.nx > 0.9 && stored.ny > 0.8);

  // Same monitor, now shorter: the taskbar grew and the screen shrank.
  const smaller = { x: 0, y: 0, width: 1280, height: 720 };
  const restored = denormalizePosition(stored, smaller, { width: 96, height: 104 });
  assert.equal(restored.width, 96);
  assert.ok(restored.x + restored.width <= smaller.width, 'still fully on screen');
  assert.ok(restored.y + restored.height <= smaller.height, 'still fully on screen');
});

test('a stored position always restores inside the work area', () => {
  const restored = denormalizePosition({ nx: 5, ny: -3 }, single[0].workArea, { width: 96, height: 104 });
  assert.equal(restored.x, 1920 - 96);
  assert.equal(restored.y, 0);
});

test('a flick glides, decays and settles with the tilt unwound', () => {
  // Strong enough to reach the right edge: the exponential model predicts a
  // total travel of v0 / ln(1/k), so the throw is derived from the distance
  // rather than guessed.
  const decay = 0.06;
  const distance = 1920 - 96 - 600;
  const v0 = distance * Math.abs(Math.log(decay)) * 1.2;

  let rect = pet(600, 400);
  let velocity = { x: v0, y: 0 };
  let steps = 0;
  let settled = false;
  while (!settled && steps < 500) {
    const step = inertiaStep({ petRect: rect, velocity, dtMs: 16, displays: single });
    assert.ok(step.rect.x >= 0 && step.rect.x + step.rect.width <= 1920, 'never leaves the screen while gliding');
    assert.ok(step.rect.x >= rect.x, 'a rightward throw never moves left');
    rect = step.rect;
    velocity = step.velocity;
    settled = step.settled;
    steps += 1;
  }
  assert.equal(settled, true, 'the glide ends');
  assert.equal(velocity.x, 0, 'velocity is released at rest');
  assert.equal(rect.x, 1824, 'it came to rest fixed flush at the edge it hit');
});

test('a gentle release does not glide: it is a placement', () => {
  const step = inertiaStep({
    petRect: pet(900, 400),
    velocity: { x: 40, y: 10 },
    dtMs: 16,
    displays: single,
  });
  assert.equal(step.settled, true, 'a light placement settles immediately');
  assert.equal(step.bounce, 1, 'one soft bounce for 轻放');
  assert.deepEqual(step.velocity, { x: 0, y: 0 });
  assert.deepEqual(step.rect, pet(900, 400), 'the pet stays where it was put');
});

test('a weak throw that would barely travel bounces instead of creeping', () => {
  const step = inertiaStep({
    petRect: pet(900, 400),
    velocity: { x: 120, y: 0 },
    dtMs: 16,
    displays: single,
  });
  assert.equal(step.settled, true);
  assert.equal(step.bounce, 1);
  assert.deepEqual(step.rect, pet(900, 400));
});

test('a strong throw glides and reports no bounce', () => {
  const step = inertiaStep({
    petRect: pet(900, 400),
    velocity: { x: 1800, y: 0 },
    dtMs: 16,
    displays: single,
  });
  assert.equal(step.settled, false, 'still gliding');
  assert.equal(step.bounce, 0);
  assert.ok(step.rect.x > 900, 'moved in the throw direction');
  assert.ok(Math.abs(step.tiltDeg) > 0, 'tilts while gliding');
});

test('the popup prefers above the pet and flips below at the top edge', () => {
  const workArea = single[0].workArea;
  const low = placePopup({ anchorRect: pet(800, 800), size: { width: 240, height: 120 }, workArea });
  assert.equal(low.placement, 'above');
  assert.ok(low.rect.y + low.rect.height <= 800, 'sits above the pet');

  const high = placePopup({ anchorRect: pet(800, 2), size: { width: 240, height: 120 }, workArea });
  assert.equal(high.placement, 'below');
  assert.ok(high.rect.y >= 2 + 104, 'sits below the pet when there is no room above');
});

test('the popup is clamped horizontally at both screen edges', () => {
  const workArea = single[0].workArea;
  const left = placePopup({ anchorRect: pet(0, 500), size: { width: 240, height: 120 }, workArea });
  assert.ok(left.rect.x >= workArea.x, 'never hangs off the left edge');

  const right = placePopup({ anchorRect: pet(1920 - 96, 500), size: { width: 240, height: 120 }, workArea });
  assert.ok(right.rect.x + right.rect.width <= workArea.x + workArea.width, 'never hangs off the right edge');
});

test('edgeAnchor reports every edge the pet is flush against', () => {
  const workArea = single[0].workArea;
  assert.deepEqual(edgeAnchor({ x: 0, y: 0, width: 96, height: 104 }, workArea), {
    left: true, right: false, top: true, bottom: false,
  });
  assert.deepEqual(edgeAnchor({ x: 1920 - 96, y: 1040 - 104, width: 96, height: 104 }, workArea), {
    left: false, right: true, top: false, bottom: true,
  });
});

test('a window larger than the work area is pinned to its top-left', () => {
  const tiny = { x: 0, y: 0, width: 200, height: 200 };
  const result = clampToWorkArea(pet(50, 50, 400, 400), tiny);
  assert.equal(result.rect.x, 0);
  assert.equal(result.rect.y, 0);
});

test('displayFor picks the monitor with the largest overlap', () => {
  assert.equal(displayFor(pet(100, 100), dual).id, 'left');
  assert.equal(displayFor(pet(2500, 100), dual).id, 'right');
  // Mostly on the right monitor.
  assert.equal(displayFor(pet(1900, 100, 96, 104), dual).id, 'right');
  assert.equal(overlapArea({ x: 0, y: 0, width: 10, height: 10 }, { x: 5, y: 5, width: 10, height: 10 }), 25);
});

test('isOnSeam detects only exact seam contact', () => {
  const seam = { x: 1920, y: 0, width: 0, height: 1040 };
  assert.equal(isOnSeam(pet(1920 - 96, 100), seam), true, 'flush right against the seam');
  assert.equal(isOnSeam(pet(1920, 100), seam), true, 'flush left against the seam');
  assert.equal(isOnSeam(pet(1700, 100), seam), false, 'away from the seam');
});
