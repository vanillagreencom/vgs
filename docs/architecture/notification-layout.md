# Notification card layout

Covers: shell/plugins/vgs.notifications/NotificationCard.qml, shell/plugins/vgs.notifications/MediaSlot.qml

Where a notification card's text and media sit. The plugin's [README](../../shell/plugins/vgs.notifications/README.md) says what the user sees, and [design-layout.md § Component spacing](design-layout.md#component-spacing) holds the corner-clearing rule and the media tiers.

A card keeps `card.pad` above and below its content. A card without media starts its text on the stack's one text column: the inset that keeps the text's corners one clearance step inside the rounded ends of the tallest card, `card.maxHeight`. The inbox header's title starts on the same column, so it lines up with a card's text. Every text ends on that column at the right.

A card with media draws it in one square slot at `card.pad`, sized by its tier: `media.compact` for a card whose text is one line, `media.regular` for every other. `NotificationLogic.mediaTier` judges the tier from the lines the text runs to at the compact tier's width, which no tier changes, so the choice never moves the text it was read from. The text starts `card.gapIcon` after the slot, so every card of one tier starts its text at the same x, whatever the media. An image is cropped to the square with the tier's corner radius, an application icon is drawn at the tier's icon size in the middle, and people fill the slot as faces. The card grows with its text up to `card.maxHeight`. A longer body shows the whole lines that fit and elides the last one, so the vertical space stays the same.
