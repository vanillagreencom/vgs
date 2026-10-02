# Slack notifications

Slack notifications show sender initials, workspace icons and custom emoji. See [Notifications](README.md) for the panel and its controls.

## Senders and workspaces

A direct message shows its sender. A group message shows several senders. More people appear as a count beside the faces. If the notification includes a picture, it can replace the first sender's initials.

A workspace icon appears beside the title when Slack has saved it. Otherwise, the notification keeps its original title. Slack notifications from a browser use the same display. If VGS cannot identify the workspace, it keeps the original title and sender initials.

When Slack and a browser send the same message, VGS shows one notification. The Slack application copy supplies the workspace name.

## Custom emoji

A custom emoji appears as an image when Slack has saved it for that workspace. An unknown emoji stays as text. Emoji from another workspace stay as text.

Open Notifications in Settings to change Slack custom emoji. Switch it off to show emoji names as text. If an image tool is missing, select Install under Requirements.

New images appear after VGS reads Slack's saved images again. A notification does not start this work itself. Animated emoji show their first frame.

Sender photos need developer setup. See [Extras (not supported)](README.md#extras-not-supported).

## Developer details

`NotificationLogic.js` owns the Slack rule in `ENRICHERS`. It matches Slack by desktop entry or application name. Browser messages match `app.slack.com` at the start of the body. External names, titles and message bodies remain sender data.

Workspace icons come from Slack's local cache. This uses no credentials. The emoji helper uses ImageMagick and stores images under `$XDG_CACHE_HOME/vgs/notifications/slack-photos/<team id>/`. It stores no messages or tokens. Cache rules, refresh times and limits: [notification-senders.md](../../../docs/architecture/notification-senders.md).
