# D068: Keyboard support is a first-class standard

[← Decision Index](INDEX.md)

**Date**: 2026-09-30
**Status**: Active
**Research**: VGS-597
**Refines**: [D054](D054-list-motion-is-one-cursor-in-qs-ui.md), [D067](D067-overlay-keyboard-capture.md)

## Context

VGS surfaces had keyboard support in some paths and pointer-only behavior in others. That made a surface look complete while a keyboard user could not reach the same action, see focus, or close the same layer. The design system needed one standard instead of per-plugin exceptions.

## Decision

Keyboard support is part of the VGS design system. `docs/architecture/keyboard.md` is the standard. `qs.Ui` components implement the standard by default, and plugins compose those components before adding local behavior.

One shared navigator, `KeyNav`, owns roving movement, activation, paging, reveal and type-ahead for lists, menus, tabs, carousels and similar composites. `KeyNav` reads one pure rule file, `KeyNavLogic.js`, so unit tests and QML use the same key rules.

Button-like controls activate on Enter, Return and Space. Qt's default `ButtonPressKeys` returns Space and Select in `qtbase` 6.11.0 `src/gui/kernel/qplatformtheme.cpp` lines 693-694, read on 2026-09-30. VGS owns the Enter and Return path in its controls.

Summoned surface hosts own Escape and initial focus. A plugin may name `initialFocus`. The host focuses it with the summon reason: `Qt.ShortcutFocusReason` for an unanchored shortcut or IPC summon, and `Qt.MouseFocusReason` for an anchored click summon. A focus ring therefore appears at once for key-opened surfaces and stays hidden for click-opened flyouts.

Passive layers take no keyboard input. An interactive surface that needs keyboard input, such as the notifications inbox, is a summoned panel. Runtime facts and smoke rows for this boundary are in [runtime-qml-focus.md](../architecture/runtime-qml-focus.md).

Bar widgets do not take focus. They reach their interactive surfaces through global shortcuts. Tooltips show the effective keys from `shell.shortcut.keys`, which [D059](D059-keycodes-and-effective-shortcut-keys.md) defines.

`scripts/check-keyboard.py` enforces the static part. A click-only path needs an inline `keyboard-path` marker that names the real keyboard path. A focusable item needs a `FocusRing` or an inline `focus-indicator` marker that names the real indicator. `vgs-plugin check` runs the same rule on plugin trees.

Each interactive surface owns a keyboard-only smoke path. The path opens the surface by key where the manifest supplies one, reads focus and the visible ring through the smoke probe, walks the surface by keys, activates an action by key, and closes by Escape.

## Rationale

- One component standard makes keyboard support a default behavior, not a plugin audit item.
- One navigator prevents each surface from interpreting the same keys differently.
- One pure rule file lets Node tests plant key-rule controls without a QML scene.
- Host-owned Escape makes close behavior uniform across panels, menus, overlays and windows.
- Host-owned initial focus keeps the focus reason visible to `visualFocus`.
- Passive layers stay passive, so a toast or decoration cannot steal text from the focused application.
- Global shortcuts keep bar widgets reachable without putting the bar in the Tab chain.
- Static markers make exceptions reviewable and local to the pointer action or focus indicator they justify.

## Omarchy comparison

Omarchy's `shell/Ui/PanelKeyCatcher.qml` centralizes panel keys. Its panels use `shell/Ui/CursorSurface.qml` so pointer hover and keyboard selection draw one cursor. Its `shell/Ui/KeyboardPanel.qml` primes a layer-shell panel with `WlrKeyboardFocus.Exclusive` for 75 ms, then settles on `OnDemand`. These paths are from branch `quattro`, read on 2026-09-30. Its notifications are drawn on a no-keyboard layer.

VGS keeps the shared cursor idea through [D054](D054-list-motion-is-one-cursor-in-qs-ui.md), but puts the key rules in `KeyNav` and `KeyNavLogic.js` because VGS surfaces include application windows, popups, overlays and panels. VGS does not use the Exclusive prime for passive layers because VGS keeps passive layers keyboard-free and [runtime-qml-focus.md](../architecture/runtime-qml-focus.md) records the OnDemand fact VGS relies on. VGS makes notifications interactive through a summoned panel and leaves toasts passive, so ordinary typing stays with the active client.

VGS differs from Omarchy's keyboard panels for full-screen overlays because [D067](D067-overlay-keyboard-capture.md) lets Hyprland focus binds route into the frontmost overlay. Omarchy owns its default binds, while VGS must work inside a user-owned Hyprland configuration.

## Impact

- D054 remains the list cursor decision. D068 adds the keyboard contract that uses the cursor as the focus indicator for composites.
- D067 remains the full-screen overlay capture decision. D068 adds the frontmost-overlay rule to the keyboard standard and adds the host rule for Escape and `initialFocus` on every summoned surface.
- D059 remains the effective shortcut key decision. D068 makes those labels part of the bar widget keyboard path.

**Revisit When**: Quickshell gives passive layer surfaces reliable keyboard focus without an Exclusive prime, Qt changes the default button activation keys, or a surface class needs a keyboard model that `KeyNav` cannot express.

**Verification**: `scripts/qml-unit.sh` and `scripts/test-qml-unit.sh` pin component focus, activation, scrolling and popup behavior. `node scripts/test-key-nav-logic.js` pins the shared key rules. `python3 scripts/check-keyboard.py shell` and `python3 scripts/test-check-keyboard.py` pin the static markers. Keyboard-only smoke paths live in `scripts/smoke/rows/surfaces.sh`, `launcher.sh`, `themes.sh`, `theme-browser.sh`, `notifications.sh`, `updates.sh`, `agent-warden.sh`, `manager.sh`, `settings.sh`, `devtools.sh` and `gallery.sh`.

**References**: [keyboard.md](../architecture/keyboard.md), [components.md](../architecture/components.md), [surfaces.md](../architecture/surfaces.md), [runtime-qml-focus.md](../architecture/runtime-qml-focus.md), [D054](D054-list-motion-is-one-cursor-in-qs-ui.md), [D059](D059-keycodes-and-effective-shortcut-keys.md), [D067](D067-overlay-keyboard-capture.md)
