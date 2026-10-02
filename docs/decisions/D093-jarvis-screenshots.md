# D093: Jarvis screenshots: taken on a user turn, private windows painted out, released by consent

[← Decision Index](INDEX.md)

**Date**: 2026-10-02
**Status**: Active
**Research**: [Jarvis plan § 6.1 Vision](../plans/v2-jarvis-plan.md#61-vision), [§ 3.8 Release](../plans/v2-jarvis-plan.md#38-release-gate-what-leaves-the-machine), [§ 3.11 Bounds](../plans/v2-jarvis-plan.md#311-bounds)
**Refines**: [D070](D070-jarvis-action-policy.md), [D082](D082-jarvis-approval-bound-to-the-action.md)

**Context**: The plan's vision row lets the brain read the screen, a monitor, a window, a region or an area the user draws. A screenshot can hold a password manager, a private browser window or any text on the screen, and the image can leave the machine. Hyprland reports layout coordinates; grim returns one composed image. A window can move, and the session can lock, while grim runs. No consent producer for release grants exists.

**Decision**: `Vision.js` is the one screen executor, registered through the executor seam, and `Screen.js` is its one geometry judge.

- A capture runs only for a call in the live thinking turn the user started that owns the running action, at most four a turn. The router's authority, which rejudges Policy and its lock rule, is asked before grim and again after it.
- Hyprland is read before and after the capture through the desktop session's one reader. A changed window set, a moved private window, a changed box or scale deletes the image and retries once, then refuses. An image taken across a lock is deleted.
- Masks are `(layout - box origin) * scale` in grim's upright image; the output transform enters through each output's layout size, by Hyprland's own rule. `-s` pins the scale and the PNG header must state the expected size.
- Every mapped window matching the `privateWindows` setting is painted black with `magick` before the image leaves the executor, on any workspace. A failed paint refuses. The executor registers only with both `grim` and `magick` present. The setting's text says this is limited protection.
- The image and any OCR text carry the label `screen`. `Policy.release` decides them by `cloudVision`, now a session setting whose change ends the conversation. The router delivers the image beside its text; wire brains and the MCP bridge encode it, and a brain without image input receives `tesseract` text of the painted image.
- The audit records the box, scale, size, byte count, SHA-256 and mask count, and refuses any other capture field.
- Files live in a 0700 directory under the runtime directory and are removed when the call ends, at install and at teardown.

**Rationale**:
- grim composes outputs in layout orientation (grim 1.5.0 `render.c`), so a mask rotated by the output transform would cover the wrong pixels; reading the size back makes a disagreement a refusal instead of a misplaced mask.
- Two readings prove the masks matched the screen the image shows, without freezing the screen through another program.
- Painting before the image leaves the executor keeps every consumer, audit included, from ever holding the unpainted pixels.
- A session setting for `cloudVision` keeps the frozen recipient set honest: a stricter choice takes effect at once by ending the conversation.
- Omarchy's capture freezes the screen with hyprpicker, floors the scaled size and swaps only transforms 1 and 3; VGS follows Hyprland's rounding and every odd transform. Omarchy paints no window. [jarvis-vision.md](../architecture/jarvis-vision.md#omarchy-comparison) states the rest.

## Alternatives considered

| Alternative | Reason rejected |
|---|---|
| Apply the output transform to each mask, as the plan's sentence reads | grim returns an upright composed image; a rotated mask misses the window |
| Freeze the screen with hyprpicker during the capture, as Omarchy does | A further requirement, and the masks would still rest on one reading |
| Mask only windows on a shown workspace | A workspace switch during the capture moves no rectangle but shows the window |
| Offer the screen tools with grim alone and skip masking without magick | An unpainted private window would leave the machine |
| Fall back to ImageMagick 6 `convert` where `magick` is absent | A second command spelling; Debian and Ubuntu users get no screen tools instead |
| Keep the files until the turn ends | Nothing reads them after the call; earlier removal holds fewer private pixels |
| OCR every capture | Doubles each release and the CPU cost for brains that take images |

**Boundaries**: J20 or a later consent row issues release grants; until then `ask` sends a marker. J37 owns GPT-Live delegation, whose brain would receive the same items. J30 owns ACP harness results. Layer surfaces, decorations and private text shown inside another window are not painted.

**Revisit When**: grim hands over output buffers instead of a composed image, Hyprland exposes a window's privacy or its capture exclusion, a consent producer exists, or a brain needs images resized.

**Verification**: `scripts/test-jarvis-vision.js` judges the geometry of all eight transforms, reads painted pixels at scale 1, 2 and 1.25 and with transforms 1, 2 and 5, refuses moved windows and locked sessions, and carries a control per rule. `scripts/test-jarvis-router.js`, `scripts/test-jarvis-audit.js`, `scripts/test-jarvis-brain-openai.js`, `scripts/test-jarvis-brain-anthropic.js`, `scripts/test-jarvis-mcp.js`, `scripts/test-jarvis-bridge.js`, `scripts/test-jarvis-engine.js`, `scripts/test-jarvis-protocol.js` and `scripts/test-jarvis-session.js` cover the changed owners.

**References**: [Jarvis vision](../architecture/jarvis-vision.md), [release](../architecture/jarvis-release.md), [wire brain](../architecture/jarvis-brain.md), [tool bridge](../architecture/jarvis-bridge.md).
