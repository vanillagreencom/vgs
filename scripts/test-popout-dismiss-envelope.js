#!/usr/bin/env node

// Guards the rule that a popout's dismiss carve-out is the body AS DRAWN, at
// every frame of every transition (VGS-133 review).
//
// The background dismiss window is a full-output surface whose input mask is
// `maskRect` MINUS `contentHoleRect`. If that hole is not exactly the popup
// body currently on screen, one of two things is wrong for a real user, during
// the very animation this PR added: a click on the visible popout dismisses it
// instead of reaching its content, or a click just outside it fails to dismiss.
//
// WHY THIS FILE IS SHAPED THE WAY IT IS. The carve-out used to be written
// imperatively from SETTLED geometry by every handler that changed anything,
// while the body draws from ANIMATED geometry. That produced four separate
// reports - a grow whose entry curve overshoots past its target Y, a shrink
// whose rendered height lags, a reposition mid-shrink, a width change
// mid-shrink - which were one defect at four call sites. The fix derives the
// hole once from the drawn geometry, so this file does not test four handlers.
// It evaluates the SHIPPED BINDINGS and asserts one invariant across all four
// paths: hole == drawn body, on every frame.
//
// The bindings are extracted from the QML and evaluated, never transcribed. A
// transcription keeps passing after the QML moves on, which is the failure mode
// this whole review was about. Extraction fails loudly if the shapes move.

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const POPOUT = path.join(ROOT, "quickshell/vshell/Widgets/VgsPopoutStandalone.qml");
const source = fs.readFileSync(POPOUT, "utf8");

let failures = 0;
const fail = (name, detail) => { console.error(`FAIL [${name}]: ${detail}`); failures += 1; };
const ok = (name) => console.log(`  ok    ${name}`);

// --- extraction ------------------------------------------------------------
// Deliberately NOT a brace counter: these are single-line property bindings, so
// the block is bounded by its `id:` and the first line that closes it. A miss
// throws rather than returning something partial (VGS-187 covers the brace
// counter that used to live here).
function bindingsOf(id, names) {
  const at = source.indexOf(`id: ${id}`);
  if (at === -1) throw new Error(`could not find ${id} in ${POPOUT}`);
  const block = source.slice(at, at + 1200);
  const out = {};
  for (const name of names) {
    const m = new RegExp(`^\\s*${name}:\\s*(.+)$`, "m").exec(block);
    if (!m) throw new Error(`could not read ${id}.${name} from ${POPOUT}`);
    out[name] = m[1].trim();
  }
  return out;
}

function propertyBinding(name) {
  const m = new RegExp(`readonly property real ${name}:\\s*(.+)`).exec(source);
  if (!m) throw new Error(`could not read property ${name} from ${POPOUT}`);
  return m[1].trim();
}

const hole = bindingsOf("contentHoleRect", ["x", "y", "width", "height"]);
const container = bindingsOf("contentContainer", ["x", "y", "width", "height"]);
const bodyRect = {
  x: propertyBinding("bodyRectX"),
  y: propertyBinding("bodyRectY"),
  w: propertyBinding("bodyRectW"),
  h: propertyBinding("bodyRectH"),
};

// `root.` and bare names both resolve against the same state here.
const evalIn = (expr, ctx) => {
  const src = expr.replace(/\broot\./g, "");
  // eslint-disable-next-line no-new-func
  return new Function("ctx", `with (ctx) { return (${src}); }`)(ctx);
};

// --- the model -------------------------------------------------------------
function makeState(over = {}) {
  const st = {
    shouldBeVisible: true,
    backgroundDismissWindowRequired: true,
    backgroundInteractive: true,
    shadowBuffer: 32,
    alignedX: 40,
    alignedY: 100,
    alignedWidth: 400,
    alignedHeight: 600,
    renderedAlignedY: 100,
    renderedAlignedHeight: 600,
    ...over,
  };
  // What the settle path records for the SURFACE. Deliberately settled: the
  // surface must not resize per frame (that is the VGS-133 flash). If the hole
  // were still derived from this, every assertion below would fail.
  st._surfaceBodyX = st.alignedX;
  st._surfaceBodyY = st.alignedY;
  st._surfaceBodyW = st.alignedWidth;
  st._surfaceBodyH = st.alignedHeight;
  st._surfaceMarginLeft = st._surfaceBodyX - st.shadowBuffer;
  // Both `bodyRect*` and the contentContainer bindings are evaluated from the
  // same state, so the comparison is between two shipped expressions.
  for (const [k, expr] of Object.entries(bodyRect)) st[`bodyRect${k.toUpperCase()}`] = evalIn(expr, st);
  return st;
}

// The body's screen rect, from contentContainer's own bindings. Its x is
// SURFACE-LOCAL, so the surface's left margin is added back to reach screen
// coordinates - the same arithmetic the compositor does.
const drawnBody = (st) => ({
  x: st._surfaceMarginLeft + evalIn(container.x, st),
  y: evalIn(container.y, st),
  w: evalIn(container.width, st),
  h: evalIn(container.height, st),
});

const carveOut = (st) => ({
  x: evalIn(hole.x, st),
  y: evalIn(hole.y, st),
  w: evalIn(hole.width, st),
  h: evalIn(hole.height, st),
});

const mismatch = (st) => {
  const b = drawnBody(st), c = carveOut(st);
  const bad = ["x", "y", "w", "h"].filter((k) => b[k] !== c[k]);
  return bad.length ? `body ${JSON.stringify(b)} vs carve-out ${JSON.stringify(c)} (differs on ${bad.join(",")})` : null;
};

// Steps a transition and checks the invariant on EVERY frame, not just the ends.
function sweep(label, frames) {
  const bad = [];
  frames.forEach((st, i) => {
    const m = mismatch(st);
    if (m) bad.push(`frame ${i}: ${m}`);
  });
  if (bad.length) fail(label, `the carve-out did not track the drawn body:\n    ${bad.join("\n    ")}`);
  else ok(`${label}: the carve-out is the drawn body on every frame`);
  return bad.length;
}

const lerp = (a, b, t) => a + (b - a) * t;
const FRAMES = 8;

// --- the four paths, all against ANIMATED geometry -------------------------

// 1. GROW WITH OVERSHOOT. The expressive entry curves carry y control points of
//    1.21 (expressiveDefaultSpatial) and 1.5/1.67 (expressiveFastSpatial), so
//    renderedAlignedY travels PAST its target before settling. A model that
//    interpolated between endpoints would never produce these frames.
{
  const startY = 300, targetY = 100;
  const frames = [];
  for (let i = 0; i <= FRAMES; i += 1) {
    const t = i / FRAMES;
    // Overshoot above the target, then settle back onto it.
    const y = t < 0.75 ? lerp(startY, targetY - 40, t / 0.75) : lerp(targetY - 40, targetY, (t - 0.75) / 0.25);
    frames.push(makeState({ alignedY: targetY, renderedAlignedY: y, alignedHeight: 600, renderedAlignedHeight: lerp(200, 600, t) }));
  }
  const overshot = frames.some((f) => f.renderedAlignedY < Math.min(startY, targetY));
  if (!overshot) fail("grow setup", "no frame overshot the target, so this path cannot witness the defect");
  sweep("grow with Y overshoot", frames);
}

// 2. SHRINK WHERE THE RENDERED HEIGHT LAGS.
{
  const frames = [];
  for (let i = 0; i <= FRAMES; i += 1)
    frames.push(makeState({ alignedHeight: 200, renderedAlignedHeight: lerp(600, 200, i / FRAMES) }));
  if (!frames.some((f) => f.renderedAlignedHeight > f.alignedHeight))
    fail("shrink setup", "no frame lagged the target, so this path cannot witness the defect");
  sweep("shrink with lagging height", frames);
}

// 3. REPOSITION DURING A SHRINK. X and Y targets move while the height is still
//    animating - the Dash tab-switch path, where currentTabIndex is assigned and
//    updateSurfacePosition() called on an already-visible popout.
{
  const frames = [];
  for (let i = 0; i <= FRAMES; i += 1) {
    const t = i / FRAMES;
    frames.push(makeState({
      alignedX: lerp(40, 500, t), alignedY: 120,
      alignedHeight: 200, renderedAlignedHeight: lerp(600, 200, t),
      renderedAlignedY: lerp(100, 120, t),
    }));
  }
  sweep("reposition during a shrink", frames);
}

// 4. WIDTH CHANGE DURING A SHRINK. The Dash binds popupWidth to
//    SettingsData.showWeekNumber, so a settings reload can land mid-transition.
{
  const frames = [];
  for (let i = 0; i <= FRAMES; i += 1) {
    const t = i / FRAMES;
    frames.push(makeState({
      alignedWidth: t < 0.5 ? 400 : 560,
      alignedHeight: 200, renderedAlignedHeight: lerp(600, 200, t),
    }));
  }
  if (!frames.some((f) => f.alignedWidth !== 400)) fail("width setup", "width never changed");
  sweep("width change during a shrink", frames);
}

// --- the must-fail control -------------------------------------------------
// The settled rect is what the carve-out used to come from, and it is still
// recorded for the surface - so this is the real pre-fix expression, not a straw
// man. If deriving the hole from it does NOT break the invariant, then none of
// the sweeps above are measuring anything.
{
  const settledHole = { x: "_surfaceBodyX", y: "_surfaceBodyY", width: "_surfaceBodyW", height: "_surfaceBodyH" };
  const saved = { ...hole };
  Object.assign(hole, settledHole);
  const st = makeState({ alignedHeight: 200, renderedAlignedHeight: 450, alignedY: 100, renderedAlignedY: 60 });
  const m = mismatch(st);
  Object.assign(hole, saved);
  if (!m) fail("control", "deriving the carve-out from the SETTLED rect did not break the invariant, so the sweeps prove nothing");
  else ok("deriving it from the settled rect breaks the invariant (control)");
}

// --- wiring ----------------------------------------------------------------
// The invariant above is only meaningful if the hole is bound to the derived
// rect rather than to a settled value that happens to agree in the steady state.
{
  for (const [k, expr] of Object.entries(hole)) {
    if (/_surfaceBody/.test(expr))
      fail("wiring", `contentHoleRect.${k} still reads the settled surface rect: ${expr}`);
  }
  if (!/bodyRectY/.test(hole.y) || !/bodyRectH/.test(hole.height))
    fail("wiring", "contentHoleRect's animated axes are not bound to bodyRectY/bodyRectH");
  else
    ok("contentHoleRect is bound to the drawn body rect");

  if (!/renderedAlignedY/.test(bodyRect.y) || !/renderedAlignedHeight/.test(bodyRect.h))
    fail("wiring", "bodyRectY/bodyRectH are not the ANIMATED values, so the hole cannot track the animation");
  else
    ok("bodyRectY/bodyRectH are the animated values");
}

// The imperative envelope is what produced four call sites to get wrong. If it
// comes back, this file's single-invariant premise is gone with it.
{
  for (const gone of ["_setDismissCarveOutEnvelope", "carveOutSettleTimer"]) {
    if (source.includes(gone))
      fail("no call sites", `${gone} is back: the carve-out is being written imperatively again, so per-path defects have somewhere to occur`);
  }
  if (!failures) ok("no imperative carve-out writer remains");
}

// The surface must still settle from SETTLED geometry - deriving the hole from
// the animation must not have dragged the surface along, which would be the
// VGS-133 flash returning.
{
  const m = /function _setSettledSurfaceGeometry\(\)[\s\S]{0,300}?_setSurfaceGeometry\(([^)]*)\)/.exec(source);
  if (!m) fail("surface", "could not read the settle path's _setSurfaceGeometry call");
  else if (/rendered/.test(m[1]))
    fail("surface", `the layer surface is being sized from ANIMATED geometry (${m[1].trim()}) - that is the resize flash`);
  else
    ok("the layer surface is still sized from settled geometry");
}

if (failures) {
  console.error(`\ntest-popout-dismiss-envelope: ${failures} failure(s)`);
  process.exit(1);
}
console.log("test-popout-dismiss-envelope: all checks passed");
