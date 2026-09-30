# Design layout

Covers: shell/Commons/Inset.js, shell/Commons/ClearingInset.qml, scripts/test-inset.js, scripts/qml-tests/tst_spacing.qml

Where a container puts its content and how far apart a component spaces its parts. The tokens these rules read are in [design-system.md](design-system.md).

## Layout contract

A container owns one inset box, [D050](../decisions/D050-container-layout-contract.md). A boxed child, such as a button, list-row highlight or card, puts its outer box on that inset edge. Unboxed container content, such as a heading, notice, hint, description or field label, puts its text on that edge. A child then uses its own component padding for its internal text, icon or control. A scroll area in a container extends into the right inset strip: its content ends on the inset box, and its bar sits to the right of that content. A rounded container follows the shared corner-clearing rule below.

Dialogs and popovers use the same container. They fit their content until their max-height share is reached; after that, only the body scrolls. The Settings window's outer size is outside this contract and is owned by the window host.

## Component spacing

Every one-line control is `size.control.md` tall, with `control.paddingX` a side and `control.gap` between an icon and its text. Every row pads its content `row.paddingX` a side, and a row's inline label is `row.labelWidth` wide and `row.gap` from its control. A component token still names each value, derived from these, so a theme can move one component. Each component's measured height, padding, gap and radius beside the reference rule it follows is [design-values.md § Component spacing](../reference/design-values.md#component-spacing). `scripts/qml-tests/tst_spacing.qml` reads the rhythm back from drawn components under the defaults and under a theme that moves it. `scripts/smoke/rows/manager.sh` holds the Settings page's fields to one label edge and one control edge, [manager.md](manager.md).

Rectangular content inside a rounded container starts far enough in that each of its corners stays one spacing step inside the curve of the drawn corner, at the content's own distance from the top and bottom edges. Content lower in the container therefore needs less inset. Content within one step of the edge clears the whole corner. The drawn corner is `min(radius, width / 2, height / 2)`, and `shell/Commons/Inset.js` owns the calculation. A square corner keeps the component's normal padding. A round avatar, face stack or pill control may sit at the normal padding when its centre stays concentric with the rounded end. The notifications stack reads one text column for every card and for the inbox header: the inset of its tallest card, whose text starts `card.pad` from the top. The inset grows with the height, so the column also clears every shorter card, and the texts line up. `scripts/test-inset.js` checks the helper with controls. `scripts/qml-tests/tst_spacing.qml` checks `Toast`, and `scripts/smoke/rows/notifications.sh` checks the notifications cards and header in the sandbox.

A notification's media sits in one square slot whose size is a tier, not a property of the media: `compact` for a card whose text is one line, `regular` for every other, each a `media` entry of the notifications' own table. `NotificationLogic.mediaTier` is the one judge. It reads the lines the text runs to at the compact tier's width, which no tier changes, so the tier never moves the text it was read from. The text starts at the card's pad, plus the tier's slot and the gap after it, so every card of a tier starts its text at the same x, whether it shows an image, an icon, one person or a group. People draw through `AvatarGroup` ([components-media.md](components-media.md)), sized to the slot. `scripts/smoke/rows/notifications.sh` holds the text x per tier and the group inside the slot for two, three, four and seven people.

## Decisions

- Containers use one inset box, an inner scroll gutter and fitted popup height: [D050](../decisions/D050-container-layout-contract.md).
