#!/usr/bin/env node

// Guards the rule that a popout's dismiss carve-out covers what is ON SCREEN,
// not what the animation is aiming at (VGS-133 review, Codex P2).
//
// The background dismiss window is a full-output surface whose input mask is
// `maskRect` MINUS `contentHoleRect`, and `contentHoleRect` is sized from
// `_surfaceBodyY` / `_surfaceBodyH`. `alignedHeight` is the TARGET height;
// `renderedAlignedHeight` is what the body actually draws and, on a shrink,
// animates down to meet it. Recording the target immediately shrinks the hole
// at once, so for the length of the animation the still-visible lower band of
// the popout lies OUTSIDE the hole and INSIDE the dismiss window: a click there
// dismisses the popout instead of reaching the content under the cursor.
//
// The envelope is the fix, and this file is what keeps it. The predicate is not
// "the function exists" but "at every frame of a shrink, the carve-out contains
// the rendered body" — checked by stepping an animation.
//
// THE FUNCTION IS SLICED OUT OF THE SHIPPED QML AND RUN, not transcribed. A
// transcription would keep passing after the QML changed, which is the failure
// mode this whole PR is about. Extraction fails loudly if its shape moves.

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const POPOUT = path.join(ROOT, "quickshell/vshell/Widgets/VgsPopoutStandalone.qml");
const source = fs.readFileSync(POPOUT, "utf8");

let failures = 0;
function fail(name, detail) {
  console.error(`FAIL [${name}]: ${detail}`);
  failures += 1;
}
function ok(name) {
  console.log(`  ok    ${name}`);
}

// --- slice the function body out of the QML -------------------------------
function sliceFunctionBody(src, name) {
  const marker = `function ${name}() {`;
  const start = src.indexOf(marker);
  if (start === -1)
    throw new Error(`could not find ${name}() in ${POPOUT}`);
  let i = start + marker.length;
  let depth = 1;
  while (i < src.length && depth > 0) {
    const ch = src[i];
    if (ch === "{") depth += 1;
    else if (ch === "}") depth -= 1;
    i += 1;
  }
  if (depth !== 0)
    throw new Error(`unbalanced braces reading ${name}() in ${POPOUT}`);
  return src.slice(start + marker.length, i - 1);
}

const envelopeBody = sliceFunctionBody(source, "_setDismissCarveOutEnvelope");
const settledBody = sliceFunctionBody(source, "_setSettledSurfaceGeometry");

// `with` is what lets the sliced body keep its bare identifiers (`alignedY`,
// `_surfaceBodyH`, ...) exactly as QML resolves them against the component
// scope. Deliberate, and confined to this harness.
function compile(body) {
  // eslint-disable-next-line no-new-func
  return new Function("ctx", `with (ctx) { ${body} }`);
}

// --- a popout, and the two rects that matter ------------------------------
function makePopout() {
  const ctx = {
    shouldBeVisible: true,
    alignedX: 40,
    alignedWidth: 400,
    alignedY: 100,
    alignedHeight: 600,
    renderedAlignedY: 100,
    renderedAlignedHeight: 600,
    _surfaceBodyX: 0,
    _surfaceBodyY: 0,
    _surfaceBodyW: 0,
    _surfaceBodyH: 0,
    _surfaceMarginLeft: 0,
    _surfaceW: 0,
    shadowBuffer: 32,
    carveOutSettleTimer: { restart() {} },
    Math,
    // Snapping is identity here: this file is about which RECT is recorded,
    // and a device-pixel round would only blur the comparison.
    _setSurfaceGeometry(bodyX, bodyY, bodyW, bodyH) {
      ctx._surfaceBodyX = bodyX;
      ctx._surfaceBodyY = bodyY;
      ctx._surfaceBodyW = bodyW;
      ctx._surfaceBodyH = bodyH;
    },
  };
  return ctx;
}

// The band the user can see: what the body actually draws this frame.
const renderedBand = (c) => [c.renderedAlignedY, c.renderedAlignedY + c.renderedAlignedHeight];
// The band the dismiss window does NOT swallow.
const carveBand = (c) => [c._surfaceBodyY, c._surfaceBodyY + c._surfaceBodyH];

function carveCoversRendered(c) {
  const [rTop, rBottom] = renderedBand(c);
  const [cTop, cBottom] = carveBand(c);
  return cTop <= rTop && cBottom >= rBottom;
}

// Drives a shrink through the same sequence QML does: the target changes first,
// then renderedAlignedHeight animates toward it over several frames.
function runShrink(commit, frames = 6) {
  const c = makePopout();
  commit(c); // settle at the open size
  const startH = c.renderedAlignedHeight;
  const endH = 200;
  c.alignedHeight = endH; // the target lands immediately...
  commit(c); // ...and onAlignedHeightChanged fires here
  const exposed = [];
  for (let step = 1; step <= frames; step += 1) {
    // ...while the rendered body catches up over the animation.
    c.renderedAlignedHeight = startH + ((endH - startH) * step) / frames;
    if (!carveCoversRendered(c)) {
      const [rTop, rBottom] = renderedBand(c);
      const [cTop, cBottom] = carveBand(c);
      exposed.push(`frame ${step}: rendered ${rTop}..${rBottom} vs carve-out ${cTop}..${cBottom}`);
    }
  }
  return { ctx: c, exposed };
}

const envelope = compile(envelopeBody);
const settled = compile(settledBody);

// --- the guard ------------------------------------------------------------
{
  const { exposed } = runShrink(envelope);
  if (exposed.length)
    fail("shrink", `the dismiss window swallowed visible popout during a shrink:\n    ${exposed.join("\n    ")}`);
  else
    ok("a shrinking popout keeps its dismiss carve-out over the visible body");
}

// THE MUST-FAIL CONTROL. `_setSettledSurfaceGeometry` is the pre-fix behaviour
// and is still the shipped settle path, so this is not a straw man: it is the
// real function, and it must NOT be able to hold the invariant mid-shrink. If
// this ever stops reporting exposure, the check above has stopped measuring.
{
  const { exposed } = runShrink(settled);
  if (!exposed.length)
    fail("control", "recording the settled target alone did NOT expose the body, so the shrink check above proves nothing");
  else
    ok(`recording the target alone exposes the body (control: ${exposed.length} frame(s))`);
}

// A grow must not be narrowed either: the newly-grown area has to be inside the
// hole the moment it can be clicked.
{
  const c = makePopout();
  envelope(c);
  c.alignedHeight = 900;
  envelope(c);
  const [, cBottom] = carveBand(c);
  if (cBottom < c.alignedY + c.alignedHeight)
    fail("grow", `carve-out bottom ${cBottom} does not reach the grown target ${c.alignedY + c.alignedHeight}`);
  else
    ok("a growing popout's carve-out reaches the new target immediately");
}

// The envelope is monotonic, so something must collapse it or the hole would
// never shrink again. The settle path is that something.
{
  const c = makePopout();
  envelope(c);
  c.alignedHeight = 200;
  envelope(c);
  c.renderedAlignedHeight = 200;
  const beforeH = c._surfaceBodyH;
  settled(c);
  if (!(c._surfaceBodyH < beforeH))
    fail("settle", `the settle path did not collapse the envelope (${beforeH} -> ${c._surfaceBodyH})`);
  else if (c._surfaceBodyH !== c.alignedHeight)
    fail("settle", `the settle path left ${c._surfaceBodyH}, not the target ${c.alignedHeight}`);
  else
    ok("the settle path collapses the envelope back to the target");
}

// A second shrink arriving mid-flight must not narrow the hole below what the
// first one was still covering.
{
  const c = makePopout();
  envelope(c);
  c.alignedHeight = 400;
  envelope(c);
  c.renderedAlignedHeight = 500;
  c.alignedHeight = 300;
  envelope(c);
  if (!carveCoversRendered(c))
    fail("restacked shrink", `a second shrink narrowed the hole under the visible body: rendered ${renderedBand(c)} vs carve-out ${carveBand(c)}`);
  else
    ok("a second shrink mid-flight does not narrow the hole under the visible body");
}

// The wiring: the envelope has to be what the height path actually calls, or
// every assertion above is about a function nothing invokes.
{
  const heightHandler = source.slice(source.indexOf("onAlignedHeightChanged: {"));
  const body = heightHandler.slice(0, heightHandler.indexOf("\n    }"));
  if (!body.includes("_setDismissCarveOutEnvelope()"))
    fail("wiring", "onAlignedHeightChanged does not call _setDismissCarveOutEnvelope(), so the envelope is dead code");
  else
    ok("onAlignedHeightChanged routes through the envelope");
}

// And the carve-out has to be the thing sized from it.
{
  if (!/id:\s*contentHoleRect[\s\S]{0,400}root\._surfaceBodyH/.test(source))
    fail("wiring", "contentHoleRect is no longer sized from _surfaceBodyH, so this file is measuring the wrong rect");
  else
    ok("contentHoleRect is still sized from the recorded body rect");
}

if (failures) {
  console.error(`\ntest-popout-dismiss-envelope: ${failures} failure(s)`);
  process.exit(1);
}
console.log("test-popout-dismiss-envelope: all checks passed");
