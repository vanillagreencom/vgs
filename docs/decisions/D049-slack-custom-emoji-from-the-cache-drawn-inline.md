# D049: Slack custom emoji from Slack's cache, drawn inline by an ImageText component

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: VGS-589

**Refines**: [D046](D046-slack-tokens-per-workspace-and-one-card-per-message.md)

**Context**: A Slack notification carries a workspace's custom emoji as its shortcode, such as `:values-prioritize-the-customer:`, and the card drew the shortcode as text where Slack's clients draw the image; standard emoji already arrive as characters. The owner asked for the images with notifications staying fast and free of races. Slack's disk cache on the owner's machine held 2,542 custom emoji of one team among 17,765 entries on 2026-09-29, keyed `1/0/https://emoji.slack-edge.com/<team id>/<name>/<hash>.<ext>`, the key form the workspace icons are already read by; the owner had stored no token. Qt's StyledText loads an `<img>` synchronously on the GUI thread, and its multi-line elision draws an earlier line's image over the elided line ([runtime-qml-text.md](../architecture/runtime-qml-text.md)).

**Decision**:

- **Cache first, `emoji.list` beside it.** The photo helper's run builds each listed team's emoji from Slack's disk cache, read-only and with no token, and complements it once a day with `emoji.list` and the token that serves the team: names Slack has not cached, aliases, and images changed since. `missing_scope` is a steady state. [notification-slack-cache.md § Slack custom emoji](../architecture/notification-slack-cache.md#slack-custom-emoji) holds the layout, the caps and the refresh.
- **One helper, one tree.** The emoji live in the photo cache's team directories, `emoji.json` and `emoji/`, written by the same helper run, so an emoji write never races a photo sweep. Images are normalized ahead of time to a 48 pixel PNG named by its content, and the index is swapped by rename while the previous index's files stay one run.
- **No work on the notification path.** A card reads its workspace's lookup from memory, one own-property read per shortcode. No notification starts a run or reads a file; a new emoji shows after the next build, hourly or on a workspace or setting change.
- **`ImageText` in `qs.Ui`.** Text with local images inline is a component of the library, not a card's one-off: it elides a text with images itself, at whole words and images, and `ImagePool` starts one asynchronous `Image` per URL and device size before a text names it, so the text waits on that load. A failed image draws its alt text.
- **Full-strength images.** The card's body fades by its colour's alpha, `text.subtitle.color`, not by item opacity, so an emoji draws as Slack draws it.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| `emoji.list` alone | The owner stores no token; the cache already holds every emoji Slack has shown, with no scope and no network. |
| Download or convert on a notification that misses | Puts a process and the network on the notification path and races the helper's sweep; the next build catches up within an hour. |
| One `Image` item per emoji inside the card's layout | Wrapping and elision would have to be re-implemented around items, and every card would carry its own loaders. |
| `Text.RichText` | It has no elision, and it would read the sender's markup as HTML. |
| Qt's `ElideRight` on the StyledText | It draws an image of the first line over the elided line's text and keeps an image past the cut. |
| Draw the cached source files as they are | Sizes up to 256 KiB and animated GIFs would reach the GUI thread's decode; one normalized square keeps every draw small and bounded. |

## Omarchy comparison

Checked against basecamp/omarchy `quattro` at `b421b1b`: `shell/plugins/notifications/components/NotificationCard.qml`, `NotificationLogic.js` and `Service.qml`, and `shell/plugins/emojis/`.

| Omarchy | VGS | Where VGS takes it, or why it differs |
|---|---|---|
| The body is StyledText with `ElideRight`; no rule substitutes a shortcode, so a Slack custom emoji shows as text. | The body is `ImageText`; a Slack card's shortcodes of its workspace draw as images. | The owner asked for the images; Qt's elision cannot draw them in place. |
| The body's dimming is in its colour, `Qt.darker(...)`, not in opacity. | The body's fade is its colour's alpha. | Taken: images inline stay at full strength. |
| `plugins/emojis` is a picker over Unicode emoji. | No picker. | Unrelated to drawing notifications. |

## Consequences

- ImageMagick becomes the one converter of both photos and emoji; without it a card keeps the shortcodes.
- The workspace icons and `slack-emoji.js` both read a simple-cache entry's body, the first for one icon URL, the second over a whole listing. One reader, `slack-cache.js`, serves both: [notification-slack-cache.md § Slack's disk cache](../architecture/notification-slack-cache.md#slacks-disk-cache).
- The body's colour token replaces its opacity on the card; `InboxHeader` still reads the opacity.

**Revisit When**: Slack sends custom emoji as images in its notifications; Slack's cache changes its key form; Qt's StyledText gains asynchronous images or a correct multi-line elision.

**Verification**: `scripts/test-notifications-slack-cache.js` (the cache reader through both callers, each rule with a control); `scripts/test-notifications-slack-emoji.js` (cache route, newest entry, name rule, first frame, alias, API-only and updated emoji, `missing_scope`, swap grace, reuse, budget, chunk fallback, no ImageMagick, disable, each with a control); `scripts/test-notifications-logic.js` (segments, own workspace, own names, cap, pending delay); `scripts/test-image-text-logic.js`; `scripts/qml-tests/tst_imagetext.qml` with its mutations in `scripts/test-qml-unit.sh`; `scripts/smoke/rows/notifications.sh` (the image drawn, no run per card with its control, the two latencies).

**References**: [D046](D046-slack-tokens-per-workspace-and-one-card-per-message.md), [D023](D023-plugin-owned-appearance.md), [notification-senders.md](../architecture/notification-senders.md), [notification-slack-cache.md](../architecture/notification-slack-cache.md), [components.md](../architecture/components.md), [runtime-qml-text.md](../architecture/runtime-qml-text.md)
