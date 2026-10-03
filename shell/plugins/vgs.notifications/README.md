# Notifications

Application notifications appear at the top of each screen. Open the panel to read them later. Silence keeps new notifications in History without showing them on screen.

![Three notifications on screen](../../../docs/images/plugins/vgs.notifications-toasts.webp)

![The inbox with three notifications](../../../docs/images/plugins/vgs.notifications-inbox.webp)

## Open the panel

Press Super+N to open or close the panel. Change this shortcut under Keys on the Notifications Settings page.

- Unread shows notifications received since the last Mark read.
- History shows saved notifications.
- Mark read marks current notifications as read and closes the panel.
- Clear history removes saved notifications and keeps the panel open.
- Escape closes the panel. The panel also closes when another window takes keyboard focus.

Notifications do not expire while the panel is open. Use Tab to reach the header controls. Use the arrow keys, Home, End, PageUp or PageDown to select a notification. Press Enter to open it. Press Delete to dismiss it. Left and Right select its action buttons. Enter or Space activates the selected button.

## Notifications on screen

Set Notification duration on the Notifications Settings page. It sets the minimum time for a normal notification. Low priority notifications use the shorter of this time and five seconds. An application can ask for more time, up to thirty seconds. Critical notifications stay until closed. Point at a notification to pause its timer.

Point at a notification to see its actions. Select an action to send it to the application. Select Show, or click the notification, to bring the application's window into view. Dismiss and a right click remove it from the screen. Dismiss does not open the application.

When a notification leaves the screen, History keeps it. New notifications can replace older ones on a full screen.

If saved history is damaged or cannot be read, the panel says so. Select History, then Clear history to start a new saved history. This removes the old history.

## Open a notification

A notification can open its application or a file. File notifications open in your selected editor, or the default file application. If another notification file is open, close its window and try again.

Slack notifications from a browser open that browser. Slack does not provide a link to the message in its notifications. An old Slack notification can therefore bring Slack into view without opening the message.

## Slack

Slack notifications show sender initials and workspace icons without setup. Custom emoji appear in the message when Slack has saved their images. See [Slack notifications](slack.md).

The Notifications Settings page lists optional tools under Requirements. Select Install to add a missing tool. Notifications, the panel and Silence work without these tools.

## Extras (not supported)

These features need developer setup. They are off by default and do not appear in Settings. They are kept for the owner and are not supported. See [D075](../../../docs/decisions/D075-consumer-features-need-no-developer-setup.md).

- **Slack photos**, `slackPhotos`: sender photos and cached workspace icons from a Slack app user token per workspace, and custom emoji from Slack's emoji list. Turn it on with `{ "id": "vgs.notifications", "slackPhotos": true }` in `plugins` in `~/.config/vgs/shell.json`. The Settings page then lists a Slack tokens row with Connect for each workspace, and `curl` and `secret-tool` under Requirements. With it off, the plugin reads no token, calls no Slack API, removes the photos it cached and shows no token row. An install that had Slack photos before they became an extra keeps them: a one-time migration turns the extra on when a Slack token is stored ([migrations.md](../../../docs/architecture/migrations.md)). The setup is below.

With no token, or with no `secret-tool` binary installed, the Slack rule keeps the initials faces and the disk-cache workspace icons above, and it prints no token-missing log line.

Each workspace takes its own token, in libsecret under `service vgs-notifications` and `account slack:<team id>`, the team id Slack's workspace list gives it. The plugin's Settings page lists each workspace the list names, with its token's state. **Connect** opens a masked field: paste the workspace's token and press Save. VGS stores it in your keyring through `secret-tool`, handing it over on stdin, never on a command line, and the photos load at once. **Disconnect** removes a stored token. Show command, beside each, reveals the `secret-tool` command that does the same by hand ([D061](../../../docs/decisions/D061-no-manual-commands.md)).

A token is a Slack app's user token (`xoxp-`): create an app at api.slack.com/apps, add the user token scopes `users:read` and `team:read` under OAuth & Permissions, and `emoji:read` if you want custom emoji, then install it to the workspace.

The single-workspace token of earlier versions, `account slack`, still works. It serves the one team its `team.info` names, unless that team has its own token, and Settings says which workspace it serves. Its line connects and disconnects the same way.

Settings shows a Slack tokens row: a line for each listed workspace, and a line for the single-workspace token when no workspace is listed or it is stored. Each reads Present, Absent, Locked or Unavailable (no `secret-tool`, or the keyring cannot be asked). Connect shows while a token is absent and Disconnect while one is stored; an Unavailable line offers neither, and the Requirements section offers to install `secret-tool`. The check runs at start, when the workspace list changes, after each Connect or Disconnect and after each photo refresh; it never reads a token or unlocks the keyring.

The helper calls `team.info` and `users.list`. It stores only the team id, team names, the team icon, each user id, each user's display name, real name, Slack name and `image_48` photo, under `$XDG_CACHE_HOME/vgs/notifications/slack-photos/`. It does not read or store messages, channels, presence, email, profile text or tokens. Without a token, faces stay initials: no local Slack store maps a sender's name to a photo. [notification-senders.md](../../../docs/architecture/notification-senders.md) holds the cache, its refresh and its limits.

## Developer details

The file-opening TUI records its refusal keys in `$XDG_STATE_HOME/vgs/notifications/diagnostics.log`, or `~/.local/state/vgs/notifications/diagnostics.log` when the variable is unset. The terminal shows a plain explanation. A run outside the presenter keeps its keyed refusal on stderr. Editor and `xdg-open` output passes through unchanged.

The core's notification server takes the `org.freedesktop.Notifications` name while the plugin is enabled. Another notification daemon must not run beside it.

Screenshots come from `scripts/readme-shots.sh` in the nested sandbox, with the default theme at scale 2. VGS uses a summoned panel to give the list keyboard focus. Omarchy uses its own notification surfaces. VGS does not port the `omarchy-glyph`, `omarchy-exec-argv` or `omarchy-action` contracts because VGS has no sender for them.

The service registers `vgs.notifications:inbox`. The manifest binds it to `SUPER+N` in the generated Hyprland layer. The IPC entry is `vgsh ipc call vgs.notifications invoke <name> <arg>`.

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
| `status` | none | one JSON line: `silence`, `panel`, `store` (`state`, `problem`), `onScreen`, `history`, `held` (below), `readBefore`, `duplicates` (`keptDesktop`, `keptBrowser`, below) |

Senders can add VGS hints for an icon, tone or file to open: [notification-hints.md](../../../docs/architecture/notification-hints.md). Notification action ownership and window selection: [notification-actions.md](../../../docs/architecture/notification-actions.md).

State, appearance and shader details: [Developer reference](developer.md).
