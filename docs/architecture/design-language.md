# Design language

Covers: quickshell/vshell/Widgets/

The shell reads as one system because every surface pulls from the same tokens and scales rather than being tuned in isolation. The look is quiet neutral surfaces, hairline borders, tight radii, restrained motion and clear typographic hierarchy; the colour engine underneath it is the wallpaper-driven palette, so the language governs form and never hue.

## Boundaries

- Form tokens live in `Common/Theme.qml`; rounding, spacing and motion scales live in `Common/Appearance.qml`. A surface reads them and does not restate a value.
- Radius, elevation, ripple and animation stay user-tunable. The language sets the defaults and never removes the preference.
- Elevation is toned down rather than removed: VGS surfaces float over the wallpaper, not over a solid page, so shadow still carries the figure-ground separation a flat background would give for free.

## Invariants

1. A themable colour maps to a semantic token; no raw hex and no fixed `Qt.rgba`. The only legitimate literals are pure black and white used with alpha for glass rims, sheens and shadow scrims, which are material effects rather than palette colours. Enforced by `scripts/test-flatline-controls.js`.
2. `surfaceHover`, `surfacePressed` and `surfaceSelected` are translucent washes sized for a control that is transparent at rest. Assigning one to a control that is opaque at rest replaces its fill, so it goes see-through on hover instead of lighting up; `Theme.hoverOn(base)`, `pressedOn(base)` and `selectedOn(base)` return a solid colour for a filled base.
3. Those washes tint toward the on-surface colour, not toward `surfaceVariant`. Tinting toward a surface colour reads as a highlight only over the darker base surfaces; composited onto an already-elevated fill it is a near-invisible darkening, which is the opposite of what hover means.
4. Sizes come from the four font-size tokens and the six spacing steps. A container's padding is equal on all four sides unless a trailing control needs an optical adjustment.
5. Radius is `containerRadius` for cards, popouts and modals, `controlRadius` for buttons, chips, tiles and rows, and full rounding only for true circles and pills. A card is a fill step plus, on compact cards, a hairline that defines the edge rather than carrying the contrast.
6. A popout's layer surface is anchored top and bottom, so the compositor sizes its height to the output and a content resize never reaches the compositor. Never bind a popout window's `implicitHeight` to its content, and add no per-popout opt-out: two geometry paths is how the two behaviours drift apart. Input and dismissal track the body rect rather than the surface. Enforced by `popout_check` in `scripts/qml-smoke.sh`, whose degenerate-surface heuristic tests screen width and screen height together and must not be split.
7. A namespace belongs in the helper's Hyprland blur allowlist when its whole surface rectangle is an acceptable per-frame live-blur region, because the blur pass is not clipped to the painted body — the discard of the transparent remainder confines the result, not the cost. Whole-output painters, the popouts' own dismiss windows and backdrop-less surfaces stay out. Enforced by `test_hyprland_blur_script` in `scripts/check-vshell-helper.py`, which pins exact allowlist membership plus a match table over namespaces real surfaces declare.
8. A tooltip host is chosen by the host window, never by what nearby code uses. A bar, dock or plugin pill is a layer surface roughly one widget tall, so its tooltip needs its own overlay surface with screen-absolute coordinates; anything inside a `FloatingWindow` cannot use that, because a Wayland client cannot learn where its own toplevel sits, so it uses the in-window popup. Neither can do the other's job.
9. Every tooltip host declares whether it has a backdrop. The shared body cannot infer it, and glass over nothing reads as a translucent surface floating on a hard edge, so a new host answers the question rather than inheriting a default.
10. A settings section that a popout grows into is a page beside the current one, not content pushed below it. The surface grows to the settings page rather than by it, the disclosure control becomes the back control, the header follows the page, and a pushed page is view state that resets when the surface hides. Escape pops one level and every other dismissal closes outright, routed through the container's `canPopBack` and `popBack()` rather than a key handler inside the plugin.
