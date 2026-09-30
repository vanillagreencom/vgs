# Slack

How `vgs.notifications` reads Slack's notifications. The plugin's [README](README.md) holds the rest of what it does.

## Senders read by a rule

A per-application rule in `NotificationLogic.js` (`ENRICHERS`) reads who wrote and where from a sender's own text. A rule matches its sender's own client by desktop entry or application name, and the same service in a browser by the site address the body opens with, its `origins`. Other senders draw as the [README](README.md) says.

- **Faces.** The people a notification names show in the media slot as round faces, drawn by the `AvatarGroup` of `qs.Ui`: the person's photo where the sender's cache knows one, the notification's own image on the first, and the person's initials otherwise, on a tint the name always picks. One person fills the slot as a circle. Two to four overlap clockwise from the top left, the sender first and each over the one before it: two on the diagonal, three as a triangle, four as a 2 by 2 cluster. Past four, three faces and a "+N" chip for the rest.
- **Workspace icon.** The workspace a card belongs to shows as that workspace's icon, a small rounded square before the rule's title. With no icon, the card keeps its summary as it came.

Slack is the one rule. Slack on Linux sends no image, so the default face is initials. Its titles are the ones its web client builds: `[workspace] from Name` for a direct message, `[workspace] in channel` for a channel, and `[workspace] in name, name, name` for a group message, whose body opens with its sender. The bracketed name is the workspace's domain, and shows only when more than one workspace is signed in; with one, and always in a browser, the titles read `New message from Name`, `New message in channel` and `New thread message in channel`. The card draws every one as `from Name` or `in channel` beside the workspace's icon.

- **Browser.** Slack in a browser, `app.slack.com`, is read by the same rule: its site line goes, its sender shows as a face and its title as above. It names no workspace. The card takes the only workspace known, from Slack's workspace list and the photo cache together, or else the one photo team whose users hold the sender's name; with neither, it keeps its summary and initials.
- **One card per message.** When Slack's desktop client and a browser both deliver the same message within 10 seconds, one card shows: the desktop copy, which names the workspace. `status` counts the copies kept in `duplicates`. [notification-senders.md § One card per message](../../../docs/architecture/notification-senders.md#one-card-per-message) holds the rule.

The workspace icons come from Slack's own client, read-only and with no credentials: its workspace list and the icons its disk cache already holds ([notification-senders.md § Workspace icons](../../../docs/architecture/notification-senders.md#workspace-icons)). A workspace whose icon Slack has not cached keeps its name unless the optional Slack token cache has a workspace icon.

## Slack photos

Slack photos are optional. With no token, or with no `secret-tool` binary installed, the Slack rule keeps the initials faces and the disk-cache workspace icons above, and it prints no token-missing log line.

Each workspace takes its own token, in libsecret under `service vgs-notifications` and `account slack:<team id>`, the team id Slack's workspace list gives it. The plugin's Settings page lists each workspace the list names, with its token's state. **Connect** opens a masked field: paste the workspace's token and press Save. VGS stores it in your keyring through `secret-tool`, handing it over on stdin, never on a command line, and the photos load at once. **Disconnect** removes a stored token. Show command, beside each, reveals the `secret-tool` command that does the same by hand ([D061](../../../docs/decisions/D061-no-manual-commands.md)).

A token is a Slack app's user token (`xoxp-`): create an app at api.slack.com/apps, add the user token scopes `users:read` and `team:read` under OAuth & Permissions, and `emoji:read` if you want custom emoji, then install it to the workspace.

The single-workspace token of earlier versions, `account slack`, still works. It serves the one team its `team.info` names, unless that team has its own token, and Settings says which workspace it serves. Its line connects and disconnects the same way.

Settings shows a Slack tokens row: a line for each listed workspace, and a line for the single-workspace token when no workspace is listed or it is stored. Each reads Present, Absent, Locked or Unavailable (no `secret-tool`, or the keyring cannot be asked). Connect shows while a token is absent and Disconnect while one is stored; an Unavailable line offers neither, and the Requirements section offers to install `secret-tool`. The check runs at start, when the workspace list changes, after each Connect or Disconnect and after each photo refresh; it never reads a token or unlocks the keyring.

The helper calls `team.info` and `users.list`. It stores only the team id, team names, the team icon, each user id, each user's display name, real name, Slack name and `image_48` photo, under `$XDG_CACHE_HOME/vgs/notifications/slack-photos/`. It does not read or store messages, channels, presence, email, profile text or tokens. Without a token, faces stay initials: no local Slack store maps a sender's name to a photo. [notification-senders.md](../../../docs/architecture/notification-senders.md) holds the cache, its refresh and its limits.

## Slack custom emoji

A Slack notification whose text holds one of its workspace's custom emoji, such as `:party-parrot:`, draws the emoji's image in the card's body, in the toast and in the Inbox. Standard emoji already arrive as characters. A shortcode the workspace does not have stays as text, and so does a shortcode from another workspace.

- **Source.** Slack's own disk cache, read-only and with no token: every custom emoji Slack's client has shown. With a workspace token that has the `emoji:read` scope, Slack's emoji list adds the emoji Slack has not cached, aliases, and the new image of an emoji changed since Slack cached it. Without that scope, the cache alone is read and nothing is logged.
- **When.** The photo helper builds the emoji when the service starts, when Slack's workspace list or the setting changes, while images wait to be converted, and every hour. It asks Slack's emoji list at most once a day. A notification never starts a build, so an emoji Slack has not shown yet appears on the cards after the next build.
- **What is cached.** Under `$XDG_CACHE_HOME/vgs/notifications/slack-photos/<team id>/`: `emoji.json`, each name and alias with its image and where the image came from, and `emoji/`, one 48 by 48 pixel PNG per image, the first frame of an animated one. No message, channel or token is read or stored.
- **Limits.** A source image of at most 256 KiB and a converted one of at most 64 KiB; at most 2,048 emoji and 8 MiB of images per workspace; at most 256 new images per build, the rest in the next build a minute later; at most 64 emoji drawn in one body.
- **Needs.** ImageMagick, `magick` or `convert`. Without it the cards keep the shortcodes as text and the log reads `notifications-slack-photos: emoji magick=missing`.
- **Turn it off.** Switch off **Slack custom emoji** in the Slack group of the plugin's Settings page, or set `{ "id": "vgs.notifications", "customEmoji": false }` in `plugins` in `~/.config/vgs/shell.json`. The cards show the shortcodes at once, and the next build removes the cached images. Removing the `emoji:read` scope from a token only drops Slack's emoji list.
