# Gallery

Covers: shell/plugins/vgs.gallery/**, scripts/smoke/rows/gallery.sh

The Gallery is a first-party application window ([surfaces.md](surfaces.md)) that draws `qs.Ui` components for theme review.

- It draws every component in every variant and state.
- It draws every focusable control in its focused state in the Focus section.
- It draws every role of `Theme.text` in its typography section, read from the group itself.
- It opens on its scrollable body, so keyboard focus starts somewhere safe and PageUp, PageDown, Home and End scroll the examples.
- It is built only while summoned.

## Invariants

1. The Gallery draws every component the `qs.Ui` module exports, except non-item helpers. Enforced by `scripts/smoke/rows/gallery.sh`, through `galleryMissing`.
2. The Gallery draws one focused example for each required focusable control. Enforced by `scripts/smoke/rows/gallery.sh`, through `galleryFocusMissing` and a control copy without one `focusPreview`.
3. No example draws past the window's right edge. Enforced by `scripts/smoke/rows/gallery.sh`, through `galleryOverflow`.
4. The Gallery is a Hyprland application window, so Hyprland owns its border, focus, movement and close. Enforced by `scripts/smoke/app-window.sh`, through the Gallery row.

## Omarchy comparison

Omarchy's dev gallery uses one panel cursor model for its examples. VGS keeps the Gallery as an application window and uses `focusPreview` for static focus states, because the window must preview reusable `qs.Ui` controls rather than one panel's cursor state.
