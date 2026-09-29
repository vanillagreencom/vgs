# Cards

Covers: shell/Ui/layout/AngledCard.qml, shell/Ui/foundation/Scrim.qml, scripts/qml-tests/tst_angledcard.qml, scripts/qml-tests/tst_scrim.qml

The theme and wallpaper browsers draw their choices as leaning cards over a dimmed screen. `AngledCard` is one card and `Scrim` is the dimmed screen. Both are components of `qs.Ui` under [design-system.md](design-system.md): they draw from tokens alone, and a theme restyles them as it restyles every other component.

## Components

- `AngledCard` clips the content declared inside it to a parallelogram. The top edge sits `skew` pixels right of the bottom edge, or left of it for a negative `skew`; `skew` is `angledCard.skew` unless the caller sets it. An outline follows the same edge: `angledCard.borderWidth` of `angledCard.border`, or `selectedBorderWidth` of `selectedBorder` while the card is `selected`. A dimmed card draws `angledCard.dim` over its content; `dimmed` holds while the card is not `selected`, unless the caller sets it. `corners` holds the four corners in the card's own coordinates, so a row of cards can overlap edge to edge. The caller sizes and places the card.
- The clip is a `QtQuick.Shapes` parallelogram, drawn as a hidden layer and used as a `MultiEffect` mask over a layer of the content. The mask reads coverage alone, so its path keeps the default opaque fill of `ShapePath` and no theme colour reaches it. The wash is inside the masked layer, so it is clipped with the content. The outline is drawn over the layer.
- `Scrim` fills its parent with `color.scrim`, the background at 0.6. It takes the presses that land on it, so nothing under it answers, and emits `clicked`, so the surface declared after it can close on a click away.

## Omarchy

The card is Omarchy's image picker card (`shell/plugins/image-picker/ImagePicker.qml`): the same mask technique, the same 28 pixel lean, the background at 0.42 as the wash, and a 3 pixel selected outline in the accent. Each of its values is a token here. VGS differs in three places:

- The outline of a card that is not selected is `color.borderStrong`, the opaque neutral 0.27 of the way from the background to the foreground. Omarchy draws the foreground at 0.28 alpha. With the default palette, over the background, the two colours are within 2 of 255 on each channel. `color.borderStrong` is the role every strong outline shares, so a theme moves them together.
- The mask keeps the default thresholds of `MultiEffect`, where Omarchy sets `maskThresholdMin` and `maskSpreadAtMin` to 0.3. The edge of the content is the mask's own antialiased coverage, and the outline is drawn over it, so the card holds no edge value for a theme to set.
- Omarchy washes the screen with the background at 0.5. `Scrim` draws `color.scrim`, the one scrim role the token table already held, at 0.6.

## Invariants

1. The corners, the mask's path and the outline's path are one parallelogram, leaning either way, and the mask is opaque. Enforced by `scripts/qml-tests/tst_angledcard.qml`, which reads the effect, its mask and both paths. The unit runner draws no `MultiEffect` ([runtime-qml.md](runtime-qml.md)), so the test reads the clip as properties and the outline as pixels.
2. A dimmed card is washed with `angledCard.dim` and an undimmed card is not, whether it is selected or not. The outline is `borderWidth` of `border`, or `selectedBorderWidth` of `selectedBorder` while selected. Enforced by `scripts/qml-tests/tst_angledcard.qml` under the defaults and under a light theme that moves the palette, the lean and the selected width.
3. `Scrim` fills its parent, draws `color.scrim` under two themes, reports a click and keeps the press from the button under it. Enforced by `scripts/qml-tests/tst_scrim.qml`.

`scripts/test-qml-unit.sh` applies one mutation per guarantee to a copy of the module and requires its test to fail.
