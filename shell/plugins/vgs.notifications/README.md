# notifications

`vgs.notifications`: the desktop notification daemon. Every notification an application sends shows as a Spotlight glass capsule at the top of every screen, and leaves into the history when it expires, is dismissed, is acted on, is closed by its sender or is let go by a full stack. An Inbox lists what arrived since the last Mark read and a History everything kept; Silence keeps notifications off the screen and records them. It is a port of the customised Spotlight notifications of the owner's Omarchy dotfiles, drawn and behaving as that one does, on this shell's plugin contract.

The core's notification server takes the `org.freedesktop.Notifications` name while the plugin is enabled, so another notification daemon must not run beside it.

## Opening the panel

| Path | How |
|---|---|
| Shortcut | The service registers `vgs.notifications:inbox`, and the manifest binds it to `SUPER+N` in the Hyprland layer the shell writes while the plugin is enabled ([hyprland.md](../../../docs/architecture/hyprland.md)). To change the key, give the plugin's row in `~/.config/vgs/shell.json` a `keys` entry, `{ "id": "vgs.notifications", "keys": { "inbox": "SUPER+SHIFT+N" } }`; `null` in place of the key unbinds it. |
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
| `status` | none | one JSON line: `silence`, `panel`, `store` (`state`, `problem`), `onScreen`, `history`, `readBefore` |

## Toasts

- A toast shows for at least 5 seconds at low urgency and 8 at normal, longer when the sender's timeout asks, up to 30 seconds. A critical toast stays until it is closed. The pointer on a toast, or an open panel, pauses its clock.
- A sender replacing its notification updates the toast in place and starts its clock over; a sender closing it ends the toast.
- Hovering a card reveals its actions: the sender's own while it is live, Show when it has none and one of its windows is open, and Dismiss. A click on the card runs the sender's default action, or shows its window, and a right click dismisses it.
- The body renders the markup the server advertises, less every image tag, and a Chromium-family sender's leading site address. The summary is plain text.
- At most 20 toasts show at once; a newer one lets the oldest non-critical toast go into the history.
- Silence keeps every notification off the screen and records it in the history, bar a critical one from the bare command line (`notify-send -u critical`). A notification from the bare command line that is not critical, or one marked transient, is not recorded under Silence.

Omarchy's own hints, `omarchy-glyph` and `omarchy-exec-argv`, and its `omarchy-action` sender are not ported: nothing in this shell sends them.

## State

`$XDG_STATE_HOME/vgs/notifications/` (`~/.local/state/vgs/notifications/`) holds `state.json`, with Silence, the last Mark read, the toasts on screen and the history, and `images/`, the copies of the images the stored notifications show, since a sender deletes its own files once a notification closes. The history keeps the newest 100 notifications and a panel shows at most 40 of them. A sender's text is stored up to 512 characters of summary and 4096 of body, and an image up to 5 MiB, so the directory holds at most 120 entries and two images each.

The file is written whole at the end of each change. After a restart or a rebuild, the toasts that were on screen show again with a whole lifetime and no live actions, and the ones whose time ran out meanwhile go into the history. A file the service cannot read or does not accept is logged as `notifications: state refused: file=<path> reason=<defect>` or `state unreadable`, shown in the panel's subtitle and in `status`, and left as it is: the service keeps working in memory until Clear history starts the file over. A write that fails is logged and tried again with the next change.

## Look

`Appearance.js` holds every value the notifications draw with, as the `appearance` table [docs/decisions/D023](../../../docs/decisions/D023-plugin-owned-appearance.md) sets out. The theme reaches it through `scheme.mode`, `palette.accent` and `motion.scale` alone, so a theme's palette, fonts and metrics leave the glass as it is. The accent lights the edge reflection of a critical toast and the Silence switch. With the motion scale at 0 nothing animates and the edge lights stand still.

The glass, the edge light, the pills and the switch are the plugin's own files, drawn from its own table: a plugin imports no other plugin's files.

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
