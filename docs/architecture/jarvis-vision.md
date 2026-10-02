# Jarvis vision

Covers: shell/plugins/vgs.jarvis/backend/Vision.js, shell/plugins/vgs.jarvis/backend/Screen.js, shell/plugins/vgs.jarvis/backend/skills/computer/vision.md

The [plan § 6.1](../plans/v2-jarvis-plan.md#61-vision) defines the screen tools. [D093](../decisions/D093-jarvis-screenshots.md) records the choices. [The router](jarvis-approval.md) still owns policy, approval, audit and the result label. This file defines the executor behind the `vision.*` rows of `Tools.TABLE`, its geometry, its races and its release route.

## Owners

- `Vision.install` registers the `vision` executor through [the registration seam](jarvis-tools.md#owners), after the [desktop session](jarvis-desktop-tools.md#owners) probe reached Hyprland, and only when `grim` and `magick` are on PATH. An image whose private windows cannot be painted is not one this executor sends.
- `Screen.plan` is the one geometry judge: from a Hyprland reading and a call to the box grim captures, its scale, the image size and the mask rectangles. It runs no process.
- `DesktopSession.install` lends its one Hyprland reader, `reading()`, and its read bound. Vision runs no `hyprctl` of its own.
- `Desktop.runCommand` runs `grim`, `slurp`, `magick` and `tesseract` as it runs the [desktop commands](jarvis-tools.md#commands): the absolute file the PATH lookup found, under `setpriv --pdeathsig KILL`, in its own process group, with only the variables its command table lists. `grim` and `slurp` receive `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR`. `magick` receives `MAGICK_TEMPORARY_PATH`, the private directory. No key and no `VGSH_RUNNER_PID` reach a child.
- The daemon passes three facts: Session's record, the current `privateWindows` setting, and `route()`, which answers `image` when the chained engine's brain takes images.

## Tools

| Tool | Box | grim target |
|---|---|---|
| `vision.screen` | the bounding box of every output | none: every output |
| `vision.monitor` | the output named, or numbered, by `monitor` | `-o NAME` |
| `vision.window` | the window's `at` and `size` | `-g "X,Y WxH"` |
| `vision.region` | the rectangle given | `-g` |
| `vision.area` | the rectangle the user draws with `slurp -f "%x,%y %wx%h"` | `-g` |

- A window must be mapped and on screen by `Dispatch.onScreen`. A window that matches `privateWindows` refuses as `private-window`: a painted image would answer nothing.
- A region must lie inside the screen's bounding box and meet an output. That keeps grim's image no larger than the whole screen's.
- `vision.area` is offered only with `slurp` present. The help file tells the brain to use it only when the user says "this area". slurp exits 1 with `selection cancelled` when the user cancels (slurp `main.c`, emersion/slurp `a3998d3`); that refuses as `area-cancelled`.
- Every row is `read` and labels its result `screen`, so [taint](jarvis-policy.md) makes the turn's later persistent, exec, input and external calls confirm.

## Geometry

- Hyprland 0.56.2 prints an output's `width` and `height` as its mode in device pixels ([runtime-hyprland-monitors.md](runtime-hyprland-monitors.md)). Its layout size is that mode turned a quarter for an odd transform (1, 3, 5, 7), divided by the scale and rounded: `CMonitor::applyMonitorRule` in `src/output/Monitor.cpp`. `Screen.plan` uses the same rule, flipped transforms included.
- grim composes every captured output into one image of the requested layout box, at one scale, with each output's transform and flip already applied (`render.c::render`, grim 1.5.0). The image is in layout orientation. Its size is `(int)(width * scale)` by `(int)(height * scale)`.
- A mask is therefore `(layout - box origin) * scale` in image pixels. The output transform enters through each output's layout size, which sets the box and which windows it meets. A mask rotated by the transform would land on the wrong pixels of grim's upright image. The plan's sentence "then the output's transform" describes the output buffer, which grim never hands over.
- The executor pins `-s` to the highest scale among the outputs the box meets, the scale grim itself would guess, so the image size is known before the capture.
- Each mask is the private window's rectangle clipped to the box and rounded outward: floor at the start, ceil at the end. `Screen.masks` computes it.
- The PNG header must state the expected size, else the capture refuses as `image-size`. A layout that grim reads differently from Hyprland cannot shift a mask silently.

## Races and lock

One call reads Hyprland, asks the router's authority, runs grim, reads Hyprland again and asks the authority again.

- hyprctl reports a window's `at` and `size` as its animation goal, not the rectangle being drawn: `getWindowData` in Hyprland 0.56.2's `src/debug/HyprCtl.cpp` prints `position(GEOMETRIC_GOAL)` and `size(GEOMETRIC_GOAL)`. A workspace slide changes no `at` at all. Two readings therefore prove the masks against the goals, not against every drawn pixel.
- The router's synchronous authority rejudges Policy, which refuses while the session is locked, and the live action. Locked before the capture: refused, and grim never runs. Locked after it, or past the action's life: the image is deleted and the call refuses with the authority's reason.
- Both readings must give the same key: the box, the scale, each monitor's active and special workspace, the set of mapped windows and every private window's rectangle. A different key deletes the image and retries once. A second difference refuses as `screen-changed`. A plan the second reading refuses, such as a closed target, counts as a difference. A failed second reading refuses, because the masks are then unproven.
- Before the retry the call waits 800 ms for the animation the change started. That is Hyprland 0.56.2's default `global` speed, 8 (`src/config/shared/animation/AnimationTree.cpp`), at hyprutils' 100 ms per unit (`CBaseAnimatedVariable::getPercent`). It is the default, not the configured speed: no hyprctl read the executor already makes reports it, and a spring curve has no fixed length.
- Each private window is painted as the bounding box of every rectangle any reading of the call reported for it, so a window moving between two goals is covered along a straight path.
- A public window that moves keeps the key, so it costs no retry.
- The lock fact is the service's hello observation ([jarvis.md](jarvis.md#session-observation)). A lock that starts and ends between the two readings is not seen. The lock screen then covers the screen grim reads.

## Masking

- `privateWindows` is a comma-separated list. Each entry matches, without case, as a substring of a window's class, initial class, title or initial title. The shipped list names password managers, `pinentry`, `seahorse` and the private-browsing titles.
- Every mapped private window the box meets is painted, on any workspace, so a window on a workspace that slides in is painted at its rest rectangle.
- `magick png:IN +antialias -fill black -draw "rectangle X0,Y0 X1,Y1" ... PNG32:OUT` paints each mask, its end pixels inclusive. The named coders keep either file from being read or written as another format. A magick that does not exit 0 fails the call with its cause, as the other commands do; a painted file of another size refuses as `mask-failed`. Nothing unpainted is answered.
- This is limited protection, not a confidentiality guarantee. A title cannot reliably identify private browsing. Text a private application shows inside another window, borders, shadows and decorations outside a client's rectangle, and layer surfaces are not painted. Nor is a window still animating when grim reads the screen: a move or re-tile slower than the wait or along a curve, a workspace or special-workspace slide that started before the first reading, or a close fade of a window no reading saw.

## Release and route

- The router delivers the answer's text as an item labelled `screen` and the image as a second item with the same labels, `{type: "image/png", item}`. [Release](jarvis-release.md) judges both against the conversation's recipients. `cloudVision` decides `screen`: `allow` sends, `never` withholds, `ask` asks for a grant. A recipient set with only local or loopback recipients always receives it ([release](jarvis-release.md)). No consent producer issues a grant yet, so `ask` sends the marker.
- `cloudVision` is a session setting: changing it ends the conversation, so a frozen recipient set never carries an old answer.
- `route()` answers `image` when the conversation's brain row takes images (`Providers` `images`). The [wire brains](jarvis-brain.md) then send the image: Messages as an image block inside the call's `tool_result`, Chat Completions in one user message after the tool messages, since the pinned excerpt's tool message carries text parts only. The [tool bridge](jarvis-bridge.md#calls-and-results) sends an MCP image block, or the marker as a second text block.
- `text` runs `tesseract PAINTED stdout --oem 1 --psm 3 --dpi 300 -l eng -c preserve_interword_spaces=1` and answers its text. OCR reads the painted file, never the capture. Text past the 64 KiB output bound is answered cut, as a clipboard read is; the router marks its own cut. Without `tesseract` the call refuses as `ocr-unavailable` before it draws, captures or counts against the turn. A custom base URL, the [Codex harness](jarvis-codex.md) row and GPT-Live take no image, so a Codex conversation receives OCR text through the bridge. GPT-Live delegation is J37's; until it exists no GPT-Live brain calls a tool.
- The answer names the box and scale, so the brain can turn an image pixel into the layout point `input.click` takes.
- The audit record of the call's outcome holds `capture`: the box, scale, image size, byte count, SHA-256 and mask count. `Audit` refuses any other key, so no image byte enters the store; a refused record also withholds the image from the brain.

## Bounds and files

| Bound | Value | Past it |
|---|---|---|
| Captures a turn | 4, the [plan's bound](../plans/v2-jarvis-plan.md#311-bounds) | `screenshot-limit` |
| One image on the image route | 3 MiB | `image-bytes`. A [wire brain](jarvis-brain.md) sends only the current turn's images, so the turn's four, base64-encoded, stay under its 20 MiB request. The text route sends no image and has no image bound |
| `grim`, `magick` | 5 s each | the child's group is killed |
| `slurp` | 15 s, the user drawing | killed |
| `tesseract` | 15 s | killed |

These are recovery bounds, not measured latencies. `timeoutMs` is slurp, two captures with two readings each, the 800 ms wait, magick, tesseract and 1 s of slack: 54.8 s with the 2 s read bound. That stays under Session's 60 s thinking deadline.

- A call counts against the live turn the user started: Session's thinking turn that owns the running action. A call with no such turn refuses as `outside-turn`.
- Files live in `$XDG_RUNTIME_DIR/vgs/jarvis/vision`, created mode 0700 by `Private.directory`. A call removes its own files when it ends, before its turn ends. Install removes files a killed daemon left. Teardown removes the directory. Session's stop cancels a running call, which kills its child or ends its wait.
- An internal error answers `executor-failed` without its text, and the daemon's stderr gets one line, `jarvis: vision=internal cause=CODE`.

## Requirements

| Command | pacman | apt | dnf |
|---|---|---|---|
| `grim` | grim | grim | grim |
| `slurp` | slurp | slurp | slurp |
| `magick` | imagemagick | none | ImageMagick |
| `tesseract` | tesseract | tesseract-ocr | tesseract |

Debian trixie and Ubuntu noble ship ImageMagick 6, which installs no `magick` (packages.debian.org and packages.ubuntu.com file search, 2026-10-02). There the screen tools stay unoffered; VGS adds no second `convert` spelling. pacman's `tesseract` asks for a language data provider; `-l eng` needs English data.

## Evidence

[Vision validation](jarvis-vision-validation.md) holds the suites, their cases and controls.

## Omarchy comparison

Omarchy (basecamp/omarchy `c05d901`) captures with `omarchy-capture-screenshot`, which hands off to `omasnap`, and picks a rectangle in `omarchy-capture-region`. That script freezes the screen with `hyprpicker`, then runs `slurp`. Its monitor geometry floors `width / scale` and swaps for transforms 1 and 3. `omarchy-capture-text` pipes `grim -g "$(slurp)" -` into `tesseract stdin stdout --oem 1 --psm 6 -l eng --dpi 300 -c preserve_interword_spaces=1`.

VGS keeps grim, slurp and those OCR flags, with automatic page segmentation for a whole screen. It differs in four ways. It uses Hyprland's own rule, rounding and every odd transform, flipped ones included. It reads the window list twice instead of freezing the screen, which needs no hyprpicker and proves its masks. It writes files in a private directory, because masking needs a file and the bounded child owner collects text. It paints private windows; Omarchy paints none.
