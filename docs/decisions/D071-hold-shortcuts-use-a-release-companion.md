# D071: Hold shortcuts complete through a release companion

[← Decision Index](INDEX.md)

**Date**: 2026-09-30

**Status**: Active

**Research**: VGS-615, [Jarvis plan § Decisions to record](../plans/v2-jarvis-plan.md#10-decisions-to-record), [Hyprland key research](../plans/v2-jarvis-plan-research.md#21-hyprland-super--right-alt-v0562-source-not-yet-run-on-a-compositor)

**Refines**: [D028](D028-one-generated-hyprland-layer.md), [D012](D012-core-owns-lent-objects.md)

**Context**: A Lua global bind can miss release when its key changes the modifier mask or the user releases the chord's modifier first. An ignored release would leave a push-to-talk consumer active. A release bind that ignores modifiers also sees unrelated plain-key releases.

**Decision**: A manifest bind with `hold: true` adds a modifier-independent release bind. A registration with the optional `onReleased` callback owns a native `<name>.release` companion under the same disposer as its main shortcut. The companion receives the release edge. The owner completes only a hold that its own down started. [hyprland-shortcuts.md § Hold shortcuts](../architecture/hyprland-shortcuts.md#hold-shortcuts) defines the API, bind flags, cancellation and ordinary-caller contract.

**Rationale**:

- The release bind is non-consuming, so it does not swallow the plain key's down event. It is transparent, so another matched bind cannot shadow it.
- The companion separates hold completion from the main Lua bind's unreliable native release. Its dotted name cannot collide with a public registration name.
- The owner ignores duplicate down and unmatched up. A release callback therefore cannot run just because the compositor matched an unrelated release bind.
- Key changes and disposal complete an active hold. A consumer needs no second lifetime or teardown path.
- The generated layer renders the same pair in the default and overlay-capture maps. The existing conflict judge either admits or skips the whole declaration.
- The helper is validation-only. No runtime command or package requirement changes under [D035](D035-manifest-requirements.md).

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Use only the main `GlobalShortcut.released` signal | Lua release matching can lose the edge after the modifier mask changes. |
| Add a consuming release bind | It can swallow a plain key before the plugin has started a hold. |
| Invoke every release callback matched by `ignore_mods` | Unrelated chords and plain key releases would reach idle consumers. |
| Let the plugin register and dispose a release shortcut separately | It duplicates lifetime ownership and permits partial teardown. |
| Drive acceptance with `hyprctl dispatch global` | It bypasses physical keycode matching, modifier order and client delivery. |

## Omarchy comparison

The read-only `basecamp/omarchy` default-branch reference is `8b4eae66da2938ba9559f103b18dbf85cdf28a70`. Its [shell shortcut registry](https://github.com/basecamp/omarchy/blob/8b4eae66da2938ba9559f103b18dbf85cdf28a70/shell/shell.qml) handles native presses. Its [voxtype binds](https://github.com/basecamp/omarchy/blob/8b4eae66da2938ba9559f103b18dbf85cdf28a70/default/hypr/bindings/voxtype.lua) pair F9 down with a release bind that stops recording. VGS takes the separate release-bind approach. It adds modifier independence and an active-hold guard because Right Alt is itself a modifier and several plugin chords can share its physical key.

The separate read-only omarchy-voice reference's `share/bindings.lua.snippet` uses `SUPER+SHIFT+V` to toggle listening. It explicitly has no hold-to-talk mode. VGS keeps the reusable core API separate from Jarvis's mode policy.

**Revisit When**: Hyprland guarantees Lua global release delivery across modifier changes, or its shortcut protocol supplies an input identity that requires a different hold owner.

**Verification**: `scripts/test-hyprland-layer.js` tests the declaration, normalization, paired rendering and flags with planted controls. `scripts/qml-tests/tst_shortcutregistry.qml` drives the shipped registration owner, repeated and unrelated edges, key changes, disposal and a throwing release callback. `scripts/test-qml-unit.sh` supplies its controls. `scripts/smoke/rows/hold-shortcuts.sh` delivers physical keycodes through the nested virtual-keyboard helper and reads fixture edges and client key events. It covers modifier-release order, layout changes, plain Right Alt, repeated input, early disposal and disable. Controls remove modifier-independent release and actual key delivery.
