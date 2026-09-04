#!/usr/bin/env node

// Evaluate shipped geometry bindings across growth, shrink, reposition, and width-change frames.
// The dismissal hole must match the drawn body. A smaller hole can dismiss content clicks;
// a larger hole can let outside clicks pass without dismissal.

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const POPOUT = path.join(ROOT, "quickshell/vshell/Widgets/VgsPopoutStandalone.qml");
const source = fs.readFileSync(POPOUT, "utf8");
// Blank comments before behavior-oriented source checks so prose cannot satisfy or trip them.
const code = source.replace(/\/\/[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "");

let failures = 0;
const fail = (name, detail) => { console.error(`FAIL [${name}]: ${detail}`); failures += 1; };
const ok = (name) => console.log(`  ok    ${name}`);

// Read single-line bindings from an ID-bounded block and throw when extraction fails.
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

// Limit evaluated geometry expressions to the accepted token grammar. Reject calls, indexing,
// strings, and assignments instead of executing arbitrary repository expressions.
const EXPR_TOKEN = /^(?:[A-Za-z_$][A-Za-z0-9_$]*(?:\s*\.\s*[A-Za-z_$][A-Za-z0-9_$]*)*|[0-9]+|\?|:|&&|\+|-|\(|\))/;
function assertSafeExpression(expr, what) {
  let rest = expr.trim();
  let previous = null;
  while (rest.length) {
    const m = EXPR_TOKEN.exec(rest);
    if (!m) throw new Error(`refusing to evaluate ${what}: unsupported syntax at ${JSON.stringify(rest.slice(0, 24))}`);
    const token = m[0];
    // Reject an identifier followed by an opening parenthesis because it forms a call.
    if (token === "(" && previous && /[A-Za-z0-9_$)]$/.test(previous))
      throw new Error(`refusing to evaluate ${what}: looks like a call at ${JSON.stringify(rest.slice(0, 24))}`);
    // Adjacent ++ or -- can pass a single-character token list but mutate the model. Reject them explicitly.
    if ((token === "+" || token === "-") && previous === token)
      throw new Error(`refusing to evaluate ${what}: '${token}${token}' mutates state at ${JSON.stringify(rest.slice(0, 24))}`);
    previous = token;
    rest = rest.slice(token.length).replace(/^\s+/, "");
  }
  return expr;
}

// Require each identifier root in the model. Dotted syntax alone also permits Node global reads.
function assertKnownIdentifiers(expr, ctx, what) {
  const heads = expr.replace(/\broot\./g, "").match(/[A-Za-z_$][A-Za-z0-9_$]*(?=\s*\.)|[A-Za-z_$][A-Za-z0-9_$]*/g) || [];
  for (const head of heads) {
    if (!Object.prototype.hasOwnProperty.call(ctx, head))
      throw new Error(`refusing to evaluate ${what}: '${head}' is not part of the popout state`);
  }
  return expr;
}

// Bare names and root-qualified names resolve against the same model state.
const evalIn = (expr, ctx) => {
  assertSafeExpression(expr, "a QML binding");
  assertKnownIdentifiers(expr, ctx, "a QML binding");
  const src = expr.replace(/\broot\./g, "");
  // eslint-disable-next-line no-new-func
  return new Function("ctx", `with (ctx) { return (${src}); }`)(ctx);
};


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
  // Keep settled surface geometry distinct from animated body geometry so the wrong source fails.
  st._surfaceBodyX = st.alignedX;
  st._surfaceBodyY = st.alignedY;
  st._surfaceBodyW = st.alignedWidth;
  st._surfaceBodyH = st.alignedHeight;
  st._surfaceMarginLeft = st._surfaceBodyX - st.shadowBuffer;
  // Compare body and hole expressions evaluated from the same state.
  for (const [k, expr] of Object.entries(bodyRect)) st[`bodyRect${k.toUpperCase()}`] = evalIn(expr, st);
  return st;
}

// Add the surface left margin to content-local X to compare screen coordinates.
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

// Check each sampled transition frame, not only endpoints.
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



// Include overshoot beyond the target; endpoint interpolation cannot represent expressive entry curves.
{
  const startY = 300, targetY = 100;
  const frames = [];
  for (let i = 0; i <= FRAMES; i += 1) {
    const t = i / FRAMES;

    const y = t < 0.75 ? lerp(startY, targetY - 40, t / 0.75) : lerp(targetY - 40, targetY, (t - 0.75) / 0.25);
    frames.push(makeState({ alignedY: targetY, renderedAlignedY: y, alignedHeight: 600, renderedAlignedHeight: lerp(200, 600, t) }));
  }
  const overshot = frames.some((f) => f.renderedAlignedY < Math.min(startY, targetY));
  if (!overshot) fail("grow setup", "no frame overshot the target, so this path cannot witness the defect");
  sweep("grow with Y overshoot", frames);
}


{
  const frames = [];
  for (let i = 0; i <= FRAMES; i += 1)
    frames.push(makeState({ alignedHeight: 200, renderedAlignedHeight: lerp(600, 200, i / FRAMES) }));
  if (!frames.some((f) => f.renderedAlignedHeight > f.alignedHeight))
    fail("shrink setup", "no frame lagged the target, so this path cannot witness the defect");
  sweep("shrink with lagging height", frames);
}

// Move position targets while height is still shrinking to model tab changes.
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

// Change width during shrink to model a settings update within a transition.
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

// Use settled geometry for the hole as a failure control. A useful sweep must detect that disagreement.
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

// Test the evaluator's rejection rules before trusting repository expressions.
{
  const rejected = [
    'require("child_process").execSync("id")',
    'root.alignedX + process.env.HOME',
    'root.alignedX; global.x = 1',
    'root.thing["key"]',
    "root.alignedX + `x`",
    'Math.max(root.alignedX, 0)',
    // Increment and decrement controls use valid model names but must still fail because they mutate fixtures.
    'root.alignedX++',
    '++root.alignedX',
    'root.alignedX--',
    'root.renderedAlignedHeight - --root.alignedX',
  ];
  const probeState = makeState();
  for (const bad of rejected) {
    let threw = false;
    try {
      assertSafeExpression(bad, "control");
      assertKnownIdentifiers(bad, probeState, "control");
    } catch { threw = true; }
    if (!threw) fail("expression guard", `accepted an expression it must refuse: ${bad}`);
  }
  // Require every shipped binding shape to pass so blanket rejection cannot count as protection.
  for (const [what, expr] of [...Object.entries(hole), ...Object.entries(container), ...Object.entries(bodyRect)]) {
    try { assertSafeExpression(expr, what); assertKnownIdentifiers(expr, probeState, what); }
    catch (e) { fail("expression guard", `refused a real shipped binding (${what}): ${e.message}`); }
  }
  ok("the evaluator refuses anything but a geometry expression, and accepts every real one");
}

// Verify that the actual mask binds to the derived body rectangle.
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

// Reject imperative envelope updates that would create separate geometry owners.
{
  for (const gone of ["_setDismissCarveOutEnvelope", "carveOutSettleTimer"]) {
    if (source.includes(gone))
      fail("no call sites", `${gone} is back: the carve-out is being written imperatively again, so per-path defects have somewhere to occur`);
  }
  if (!failures) ok("no imperative carve-out writer remains");
}

// Separate PanelWindow commits are not atomic. Map the background first on the same layer
// so content remains above it. During disagreement, a click can reach content or fall through;
// reversing the stack can turn a content click into dismissal.
{
  // Find content show assignments in comment-free code so explanatory mentions cannot count.
  const SHOW = /(background|content)Window\.visible\s*=\s*true/g;
  const shows = [...code.matchAll(SHOW)].map(m => m[1]);
  if (shows.length < 2)
    fail("stacking", "could not read the window show order; the input-routing argument above is unverified");
  else {
    // Require background mapping before each content show in its branch sequence.
    let bad = false;
    for (let i = 0; i < shows.length; i++)
      if (shows[i] === "content" && shows[i - 1] !== "background") bad = true;
    if (bad)
      fail("stacking", "contentWindow is shown before backgroundWindow, so the dismiss mask can stack ABOVE the body - a click during a transition can then dismiss instead of reaching content");
    else
      ok("the background window is mapped before the content window, so content stacks on top");
  }

  // Keep background mapped during the open session. Unmapping and remapping can place it above content.
  const handler = /onBackgroundWindowRequiredChanged:\s*\{([\s\S]*?)\n    \}/.exec(code);
  if (!handler)
    fail("stacking", "could not read onBackgroundWindowRequiredChanged; the no-remap property is unverified");
  else {
    // Compare the assigned value directly; a negative lookahead after optional whitespace can backtrack.
    const assigned = [...handler[1].matchAll(/backgroundWindow\.visible\s*=\s*([A-Za-z0-9_.]+)/g)].map(m => m[1]);
    const unmaps = assigned.filter(v => v !== "true");
    if (unmaps.length)
      fail("stacking", `onBackgroundWindowRequiredChanged can UNMAP the background window while the popout is open (assigns ${unmaps.join(", ")}); remapping it later stacks it above the content surface`);
    else
      ok("the background window is never unmapped mid-open, so the order survives a modal round trip");
  }
}

// A mask property change needs a surface commit. With a settled popout and no overlay,
// updatesEnabled needs a temporary commit window even when the background remains mapped.
{
  const mask = bindingsOf("maskRect", ["width", "height"]);
  const upd = /^\s*updatesEnabled:\s*(.+)$/m.exec(code);
  const handler = /onBackgroundDismissWindowRequiredChanged:\s*\{([\s\S]*?)\n    \}/.exec(code);

  if (!upd) fail("mask commit", "could not read backgroundWindow.updatesEnabled");
  else if (!handler) fail("mask commit", "no onBackgroundDismissWindowRequiredChanged handler: the collapsed mask is never committed, so the mapped surface keeps its previous full-output input region");
  else {
    // Assert the modeled updatesEnabled expression so additional dependencies cannot go unmodeled.
    const terms = (upd[1].match(/[A-Za-z_$][A-Za-z0-9_$]*/g) || []).filter(t => t !== "root" && t !== "null");
    const expected = ["overlayContent", "_bgCommitWindow", "bodyRectAnimating"];
    if (JSON.stringify(terms) !== JSON.stringify(expected))
      fail("mask commit", `updatesEnabled is no longer the three terms this control models (got ${terms.join(", ")}); re-derive the model before trusting it`);

    // Use settled state without overlay content so only _bgCommitWindow enables a commit.
    const opensCommit = /_bgCommitWindow\s*=\s*true/.test(handler[1]);
    // Commit on both edges of dismissal requirement. Checking only true restores the mask
    // but can leave the click catcher active when the requirement becomes false.
    const edgeGated = /backgroundDismissWindowRequired/.test(handler[1]);

    let committedMask = null;
    const sim = [];
    const step = (label, interactive) => {
      const st = makeState({ backgroundInteractive: interactive, backgroundDismissWindowRequired: interactive });
      st._frozenMaskWidth = 1920;
      st._frozenMaskHeight = 1080;
      const live = { w: evalIn(mask.width, st), h: evalIn(mask.height, st) };
      // The commit needs a window opened on this edge.
      if (opensCommit && !edgeGated) committedMask = live;
      sim.push({ label, live, committed: committedMask });
    };
    committedMask = { w: 1920, h: 1080 };
    step("power menu opens (backgroundInteractive -> false)", false);
    step("power menu closes (backgroundInteractive -> true)", true);

    const duringModal = sim[0].committed;
    const afterModal = sim[1].committed;
    if (duringModal.w !== 0 || duringModal.h !== 0)
      fail("mask commit", `with the power menu open the COMMITTED input mask is still ${duringModal.w}x${duringModal.h} - that surface is mapped above the modal's catcher and eats clicks without dismissing anything`);
    else if (afterModal.w === 0 || afterModal.h === 0)
      fail("mask commit", "after the modal closes the committed mask is still collapsed - the popout can no longer be dismissed by clicking outside it");
    else
      ok("the disabled mask is committed on both edges of a modal round trip");
  }
}

// Surface geometry must remain settled while the hole follows animation to avoid per-frame surface resize.
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
