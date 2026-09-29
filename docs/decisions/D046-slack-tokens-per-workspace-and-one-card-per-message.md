# D046: Slack tokens per workspace, a list-of-presence status type, and one card per Slack message

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: VGS-588

**Refines**: [D037](D037-plugin-status.md)

**Context**: The owner signs in to several Slack workspaces. The photo helper of `vgs.notifications` took one token, from libsecret account `slack`, and its `team.info` named one team, so one workspace at most had sender photos; the owner had stored none, and every face read initials. Settings showed that one token's state as a `presence` row, which cannot list workspaces the manifest does not know ahead. The same message also arrived twice: once from Slack's desktop client, titled `[workspace] in channel`, and once from Slack in a browser, which Chromium on the owner's machine sends with no application name, titled `New message in channel` and with its body opening `app.slack.com` and a blank line. The browser copy matched no rule, kept its site line and drew no face.

**Decision**:

- **One token per workspace.** Each workspace's token lives in libsecret under `service vgs-notifications`, `account slack:<team id>`, the team id Slack's own workspace list gives. The single-workspace account `slack` still works and serves the one team its `team.info` names, unless that team has its own token. The helper takes the listed team ids, looks up each account, and keeps a cache directory per team with its own freshness, failure hold and 10 MiB image budget. A token whose `team.info` names another team is refused for that team. [notification-senders.md § Slack photo cache](../architecture/notification-senders.md#slack-photo-cache) holds the layout and the rules.
- **A `presenceList` status type.** The core's status gains one generic type: a list of at most 32 items `{ label, value, hint?, command? }`, each `value` a `presence`. `PluginLogic.statusValueFits` judges each item, `statusRows` hands each item its tone, and the Settings page draws one line per item: label, badge, hint and a copyable command. `vgs.notifications` replaces its `slackToken` presence with `slackTokens`, one item per listed workspace with the `secret-tool store` command for that workspace's account. No token enters status; the command names the team id alone.
- **Browser senders.** A rule may name the web origins of its service. A notification from a Chromium-family browser, or from a sender naming no application whose body opens with a host line and a blank line, matches the rule whose `origins` name that host, and the rule reads the text after it. Every body loses that site line.
- **One card per message.** Two notifications are one message when a rule reads both, one came from each client, their conversation, sender and text match, their workspaces match or one names none, and they arrived within 10 seconds. The desktop copy stays: a later browser copy is not shown or recorded, and a later desktop copy takes a browser card's place while it is on screen. Otherwise the first recorded copy stays. Two copies from one client are two messages.
- **No token-free photos.** Slack's disk cache keys user photos by team and user id, and no readable local store maps a sender's name to a user id. The only store holding a few names is the IndexedDB blob store: a cache of messages in Chromium's serialized V8 format. Initials stay the fallback without a token.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Key the account by workspace domain, `slack:<domain>` | A domain can be renamed and is text another application supplies; the team id is the stable key `team.info` answers, and letters and digits alone keep the copyable command free of shell text. |
| One global freshness for all teams | A token stored for a second workspace would wait for the first team's daily boundary. |
| Drop the single-workspace token | It already serves owners of one workspace; dropping it would empty their photos until they store a new token. |
| A `presence` entry per workspace in the manifest | The manifest cannot know the owner's workspaces; entries are fixed at install. |
| Status `data` drawn by the notifications plugin's own page code | The Settings page is drawn from manifests alone ([D032](D032-settings-plugin-and-manifest-settings-convention.md)); a generic type lets any plugin list per-account credentials. |
| Photos read from Slack's local storage | Rejected: no name-to-id map exists outside the IndexedDB blob store, reading it means reading messages, which the helper must never do, and its format is tied to Chromium's IndexedDB and V8 wire format, so it would break across Slack updates. |
| Fold identical notifications on screen, newest wins (Omarchy) | The two copies differ in app, title and body shape, so text equality never matches them; and two identical messages from one person, such as two "ok"s, are two messages. |
| Keep the browser copy | It names no workspace, so its card would lose the workspace icon the desktop copy carries. |

## Omarchy comparison

Checked against basecamp/omarchy `main` at `8b4eae6`: `shell/plugins/notifications/NotificationLogic.js` and `Service.qml`.

| Omarchy | VGS | Where VGS takes it, or why it differs |
|---|---|---|
| `isDuplicatePopup` folds a toast whose app, summary, body, image and click target equal one on screen; the newest copy stays and the older one is dismissed at the server, with one history entry. | A rule's reading matches the desktop and browser copies of one message, and the desktop copy stays. | Taken: the copy that goes is dismissed and leaves no history entry. Differs: Slack's two clients never send equal text, and copies from one client are not folded. |
| `sanitizeBody` strips a Chromium-derived sender's leading site address. | The same, and a sender naming no application loses a host line followed by a blank line. | Chromium on the owner's machine names no application, so Omarchy's check misses it. |
| No per-application rule, no Slack photos, no libsecret use. | Slack's rule, its photos from per-workspace tokens in libsecret, and their presence in Settings. | The owner asked for faces and workspace icons; libsecret keeps tokens out of files, argv and logs. |

## Consequences

- Slack's disk cache also holds custom emoji images keyed by `https://emoji.slack-edge.com/<team id>/<emoji name>/<hash>.<ext>`, a name-to-image map needing no token. A later custom-emoji change may read it as a named fallback beside `emoji.list`, whose scope `emoji:read` the token hint already names. The per-team cache leaves names it does not own, so that change adds files beside the photos.
- The cache layout changed; the helper's sweep removes the older flat layout's photos and root files.

**Revisit When**: Slack publishes a local, documented name-to-photo map; a browser starts naming Slack in its notifications; or a plugin needs status items with more than a presence.

**Verification**: `scripts/test-notifications-slack-photos.js` (two tokens, a missing token, the legacy token, a mismatch, per-team freshness, the layout sweep, each with a control); `scripts/test-notifications-token-status.sh` (one line per account, controls); `scripts/test-notifications-logic.js` (browser origins, titles, workspace resolution, token rows, duplicates, controls); `scripts/test-plugin-status.js` and `scripts/test-plugin-logic.js` (the `presenceList` judge and rows); `scripts/smoke/rows/notifications.sh` (token rows per account, a browser card, both duplicate orders) and `scripts/smoke/rows/settings.sh`.

**References**: [D037](D037-plugin-status.md), [D032](D032-settings-plugin-and-manifest-settings-convention.md), [status.md](../architecture/status.md), [notification-senders.md](../architecture/notification-senders.md)
