# Gallery

Covers: shell/plugins/vgs.gallery/**, scripts/smoke/rows/gallery.sh

The Gallery is a first-party application window ([surfaces.md](surfaces.md)) that draws `qs.Ui` components for theme review.

- It draws every component in every variant and state.
- It draws every focusable control in its focused state in the Focus section.
- It draws a `FormRow` with and without its warning, `DeviceRow`s under one `ListCursor` with a battery badge in two tones, a level badge, actions and an overflow menu, and a `LevelOsd` read as a percentage, as Muted and as a device's name.
- The device list uses `KeyNav` to move focus and its cursor together. Only the selected device row takes a Tab stop; Tab reaches its actions and overflow buttons.
- It draws every role of `Theme.text` in its typography section, read from the group itself.
- Its typography section names each role's size in pixels and draws key/value rows in the `label` and `value` pair. Its Groups section draws rows with their hints, an action and a command, divided by `GroupList` ([design-layout.md § Groups](design-layout.md#groups)).
- Its "Open a menu" button opens a `Menu`; `scripts/sandbox-shots.sh` takes it with the pointer on the first entry, whose highlight meets the menu's border.
- It opens on its scrollable body, so keyboard focus starts somewhere safe and PageUp, PageDown, Home and End scroll the examples.
- It is built only while summoned.

## Invariants

1. The Gallery draws every component the `qs.Ui` module exports, except non-item helpers. Enforced by `scripts/smoke/rows/gallery.sh`, through `galleryMissing`.
2. The Gallery draws one focused example for each required focusable control. Enforced by `scripts/smoke/rows/gallery.sh`, through `galleryFocusMissing` and a control copy without one `focusPreview`.
3. Each `FormRow`, `DeviceRow` and `LevelOsd` state the Gallery names above draws with a size. Enforced by `scripts/smoke/rows/gallery.sh`, through `gallery_drawn` and a control that flattens one row.
4. No example draws past the window's right edge. Enforced by `scripts/smoke/rows/gallery.sh`, through `galleryOverflow`.
5. The Gallery is a Hyprland application window, so Hyprland owns its border, focus, movement and close. Enforced by `scripts/smoke/app-window.sh`, through the Gallery row.
6. The Gallery shows a toast through its `toasts` capability, and hiding the Gallery releases it. Enforced by `scripts/smoke/rows/gallery.sh`, which reads the toast's title in the lending record under the plugin and its absence after the hide.

## Evidence

- The keyboard Tab tour reaches the focused device row with its ring in view. The device list's arrow and End keys move focus to the selected row. Tab reaches the selected row's overflow and skips an unselected row to its action. Disposable Gallery copies swallow movement or make every row a Tab stop; the same focus reading refuses each defect after a positive focus check.
- The Gallery row brings the slim list, a plain `Flickable` the plugin declares, into view and reads, through the probe's `viewHolding` and the harness's `view_pointer`, that a mouse drag leaves it where it was and a wheel notch scrolls it. Its control gives the list Qt's left-button drag back through `setViewButtons`, and the same drag then scrolls it ([components.md](components.md)).
- The Gallery row brings the `ImageText` custom-emoji sample into its viewport, reads `imageMode`, `failed`, `imageSize`, `deviceSize` and the held pool image's URL, status and `sourceSize`, then captures its box through `shot_grim` on the nested socket. The magenta threshold is one fifth of `deviceSize` squared, in device pixels, below the sample image's fill and above an alt-only text rendering. Its control draws a copy with `{ image: "", alt: ":sample:" }` over a surface fill and requires the same pixel reader to answer false.
- The Gallery row brings each discovered `VoiceOrb` example into its viewport and captures its box through `shot_grim` on the nested socket. It requires pixels in that example's tone. The VoiceOrb control first draws a blue ring in a blank slot beside the examples; hiding its shader then removes those pixels. This positive check prevents a hidden-control check from passing when nothing draws. The installed Gallery exercises the same pack from a read-only prefix. The status-cache limitation is in [runtime-qml-shaders.md](runtime-qml-shaders.md). These checks establish actual drawing, not GPU cost or no-frame-swap behavior.

## Omarchy comparison

Omarchy's dev gallery uses one panel cursor model for its examples. VGS keeps the Gallery as an application window and uses `focusPreview` for static focus states, because the window must preview reusable `qs.Ui` controls rather than one panel's cursor state.
