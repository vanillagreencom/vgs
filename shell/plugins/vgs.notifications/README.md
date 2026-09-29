# Notifications

`vgs.notifications`: the desktop notification daemon. Every notification an application sends shows as a Spotlight glass capsule at the top of every screen, and leaves into the history when it expires, is dismissed, is acted on, is closed by its sender or is let go by a full stack. An Inbox lists what arrived since the last Mark read and a History everything kept; Silence keeps notifications off the screen and records them. It is a port of the customised Spotlight notifications of the owner's Omarchy dotfiles, drawn and behaving as that one does, on this shell's plugin contract.

The core's notification server takes the `org.freedesktop.Notifications` name while the plugin is enabled, so another notification daemon must not run beside it.

## Opening the panel

| Path | How |
|---|---|
| Shortcut | The service registers `vgs.notifications:inbox`, and the manifest binds it to `SUPER+N` in the Hyprland layer the shell writes while the plugin is enabled ([hyprland.md](../../../docs/architecture/hyprland.md)). To change the key, edit it under Keys on the plugin's Settings page, or give the plugin's row in `~/.config/vgs/shell.json` a `keys` entry, `{ "id": "vgs.notifications", "keys": { "inbox": "SUPER+SHIFT+N" } }`; `null` in place of the key unbinds it. |
| IPC | `vgsh ipc call vgs.notifications invoke <name> <arg>`, names below. |

While a panel is open the toasts stay and do not expire, a press outside the stack closes it, and the header holds Silence, Mark read (the Inbox) or Clear history (the History), and the switch between the two. Mark read marks everything so far read and closes the panel; Clear history removes the kept notifications and leaves the panel open. The panel takes no keyboard.

| IPC name | Argument | Reply |
|---|---|---|
| `inbox` | none | toggles the Inbox; `ok` |
| `history` | none | opens the History; `ok` |
| `close` | none | closes the panel; `ok` |
| `mark-read` | none | as the button; `ok` |
| `clear-history` | none | as the button; `ok` |
| `silence` | `on`, `off`, `toggle`, or empty to read it | `on` or `off`, or `refused: silence=<arg> want=on\|off\|toggle` |
| `dismiss-all` | none | dismisses every toast; `ok`, or `none` with none on screen |
| `dismiss-latest`, `invoke-latest` | none | dismisses, or clicks, the newest toast; `ok` or `none` |
| `status` | none | one JSON line: `silence`, `panel`, `store` (`state`, `problem`), `onScreen`, `history`, `readBefore`, `duplicates` (`keptDesktop`, `keptBrowser`, below) |

## Toasts

- A toast shows for at least `duration` seconds at normal urgency, 8 by default, and for the shorter of 5 seconds and `duration` at low urgency, longer when the sender's timeout asks, up to 30 seconds. Set `duration` from 2 to 30 on the plugin's Settings page, or as `{ "id": "vgs.notifications", "duration": 12 }` in `plugins` in `~/.config/vgs/shell.json`. A critical toast stays until it is closed. The pointer on a toast, or an open panel, pauses its clock.
- A sender replacing its notification updates the toast in place and starts its clock over; a sender closing it ends the toast.
- Hovering a card reveals its actions: the sender's own while it is live, Show when it has none and one of its windows is open, and Dismiss. A click on the card runs the sender's default action, or shows its window, and a right click dismisses it.
- The body renders the markup the server advertises, less every image tag and a browser's leading site address ([notification-senders.md § Browser notifications](../../../docs/architecture/notification-senders.md#browser-notifications)). The summary is plain text.
- At most 20 toasts show at once; a newer one lets the oldest non-critical toast go into the history.
- Silence keeps every notification off the screen and records it in the history, bar a critical one from the bare command line (`notify-send -u critical`). A notification from the bare command line that is not critical, or one marked transient, is not recorded under Silence.

Omarchy's own hints, `omarchy-glyph` and `omarchy-exec-argv`, and its `omarchy-action` sender are not ported: nothing in this shell sends them.

## Senders read by a rule

A per-application rule in `NotificationLogic.js` (`ENRICHERS`) reads who wrote and where from a sender's own text. A rule matches its sender's own client by desktop entry or application name, and the same service in a browser by the site address the body opens with, its `origins`. Other senders draw as above.

- **Faces.** The people a notification names show in the icon's place as round faces: the notification's own image on the first, the person's initials otherwise, on a tint the name always picks. One person fills the icon slot. A group shows at most three smaller faces overlapping, the sender first, each over the one before it, and a "+N" chip for the rest on top.
- **Workspace icon.** The workspace a card belongs to shows as that workspace's icon, a small rounded square before the rule's title. With no icon, the card keeps its summary as it came.

Slack is the one rule. Slack on Linux sends no image, so the default face is initials. Its titles are the ones its web client builds: `[workspace] from Name` for a direct message, `[workspace] in channel` for a channel, and `[workspace] in name, name, name` for a group message, whose body opens with its sender. The bracketed name is the workspace's domain, and shows only when more than one workspace is signed in; with one, and always in a browser, the titles read `New message from Name`, `New message in channel` and `New thread message in channel`. The card draws every one as `from Name` or `in channel` beside the workspace's icon.

- **Browser.** Slack in a browser, `app.slack.com`, is read by the same rule: its site line goes, its sender shows as a face and its title as above. It names no workspace. The card takes the only workspace known, from Slack's workspace list and the photo cache together, or else the one photo team whose users hold the sender's name; with neither, it keeps its summary and initials.
- **One card per message.** When Slack's desktop client and a browser both deliver the same message within 10 seconds, one card shows: the desktop copy, which names the workspace. `status` counts the copies kept in `duplicates`. [notification-senders.md § One card per message](../../../docs/architecture/notification-senders.md#one-card-per-message) holds the rule.

The workspace icons come from Slack's own client, read-only and with no credentials: its workspace list and the icons its disk cache already holds ([notification-senders.md § Workspace icons](../../../docs/architecture/notification-senders.md#workspace-icons)). A workspace whose icon Slack has not cached keeps its name unless the optional Slack token cache has a workspace icon.

## Slack photos

Slack photos are optional. With no token, or with no `secret-tool` binary installed, the Slack rule keeps the initials faces and the disk-cache workspace icons above, and it prints no token-missing log line.

Each workspace takes its own token, in libsecret under `service vgs-notifications` and `account slack:<team id>`, the team id Slack's workspace list gives it. Settings lists each workspace the list names, with its token's state and the command that stores it, such as:

```bash
secret-tool store --label='VGS notifications Slack token T0123ABCD' service vgs-notifications account slack:T0123ABCD
```

Type the token at `secret-tool`'s prompt. Do not put the token on the command line. A token is a Slack app's user token (`xoxp-`): create an app at api.slack.com/apps, add the user token scopes `users:read` and `team:read` under OAuth & Permissions, and `emoji:read` if you want custom emoji, then install it to the workspace.

The single-workspace token of earlier versions, `account slack`, still works. It serves the one team its `team.info` names, unless that team has its own token, and Settings says which workspace it serves. Store it with:

```bash
secret-tool store --label='VGS notifications Slack token' service vgs-notifications account slack
```

Settings shows a Slack tokens row: a line for each listed workspace, and a line for the single-workspace token when no workspace is listed or it is stored. Each reads Present, Absent, Locked or Unavailable (no `secret-tool`, or the keyring cannot be asked). The check runs at start, when the workspace list changes and after each photo refresh; it never reads a token or unlocks the keyring. A token stored for a listed workspace loads within 15 minutes.

Remove a token with the same attributes:

```bash
secret-tool clear service vgs-notifications account slack:T0123ABCD
```

The helper calls `team.info` and `users.list`. It stores only the team id, team names, the team icon, each user id, each user's display name, real name, Slack name and `image_48` photo, under `$XDG_CACHE_HOME/vgs/notifications/slack-photos/`. It does not read or store messages, channels, presence, email, profile text or tokens. Without a token, faces stay initials: no local Slack store maps a sender's name to a photo. [notification-senders.md](../../../docs/architecture/notification-senders.md) holds the cache, its refresh and its limits.

## State

`$XDG_STATE_HOME/vgs/notifications/` (`~/.local/state/vgs/notifications/`) holds `state.json`, with Silence, the last Mark read, the toasts on screen and the history, and `images/`, the copies of the images the stored notifications show, since a sender deletes its own files once a notification closes. The history keeps the newest 100 notifications and a panel shows at most 40 of them. A sender's text is stored up to 512 characters of summary and 4096 of body, and an image up to 5 MiB, so the directory holds at most 120 entries and two images each.

The file is written whole at the end of each change. After a restart or a rebuild, the toasts that were on screen show again with a whole lifetime and no live actions, and the ones whose time ran out meanwhile go into the history. A file the service cannot read or does not accept is logged as `notifications: state refused: file=<path> reason=<defect>` or `state unreadable`, shown in the panel's subtitle and in `status`, and left as it is: the service keeps working in memory until Clear history starts the file over. A write that fails is logged and tried again with the next change.

## Look

`Appearance.js` holds every value the notifications draw with, as the `appearance` table [docs/decisions/D023](../../../docs/decisions/D023-plugin-owned-appearance.md) sets out. The theme reaches it through `scheme.mode`, `palette.accent` and `motion.scale` alone, so a theme's palette, fonts and metrics leave the glass as it is. The accent lights the edge reflection of a critical toast and the Silence switch. With the motion scale at 0 nothing animates and the edge lights stand still.

The glass, the edge light, the pills and the switch are the plugin's own files, drawn from its own table: a plugin imports no other plugin's files.

A card keeps `card.pad` above and below its content. Rectangular text starts at least one clearance step past the drawn rounded end on both sides. A round image, face stack or pill may stay at `card.pad`, because its centre follows the capsule end. The card grows with its text up to `card.maxHeight`. A longer body shows the whole lines that fit and elides the last one, so the vertical space stays the same.

The stack draws on the core's passive layer, `vgs:layer` ([docs/architecture/layers.md](../../../docs/architecture/layers.md)). Hyprland blurs what is behind the glass only when a layer rule asks it to. The manifest declares that rule, and the Hyprland layer writes it as:

```lua
hl.layer_rule({ name = "vgs.notifications:layer", match = { namespace = "^vgs:layer$" }, blur = true, ignore_alpha = 0.6 })
```

`hyprland.lua` runs the layer from the line `vgsh hypr wire` keeps first in it, so your own settings after that line win. To change the rule, call `hl.layer_rule` with its name and new values after the line; `enabled = false` turns it off.

## Shader

The edge reflection is `shaders/edgelight.frag`, compiled to `shaders/edgelight.frag.qsb` beside it. After editing the source, compile it again from this directory with Qt 6's `qsb`:

```bash
/usr/lib/qt6/bin/qsb --glsl "100es,120,150" --hlsl 50 --msl 12 -o shaders/edgelight.frag.qsb shaders/edgelight.frag
```
