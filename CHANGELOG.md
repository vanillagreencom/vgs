# Changelog

## Unreleased

- Slack sender photos are now an owner-only extra, off by default. An install that had them keeps them: a one-time migration sets `"slackPhotos": true` in the `vgs.notifications` row of `plugins` in `~/.config/vgs/shell.json` when a Slack token is stored. New one-time migrations run once per user from `vgsh run` and `vgsh self update`. With it off, Settings shows no Slack token rows and the plugin reads no token and calls no Slack API. Workspace icons, custom emoji from Slack's cache, initials faces and one card per message need no setup. A manifest's new `extras` key declares such a switch.
- Jarvis adds Talk, Mute and Stop keys, hold or toggle mode, and persistent privacy mute. Key tests use a private scripted engine. The installed daemon remains unconfigured and captures no audio.
- Menus and select lists fill their rows to the border: a hover or selected row meets the list's top and side edges, the row insets its own text, and the scroll bar draws over a strip each row keeps clear. The `menu.padding` token is removed, and a theme that sets it is refused; `menu.item.radius` now follows `menu.radius`.
- Settings Status and Requirements rows are divided into groups: 4 px between a row's own lines, 12 px and a faint hairline between rows, from the new `groupList` tokens and the `GroupList` component.
- A key/value label and its value read as one pair: labels, section headings, buttons, badges and key caps draw at 12 px, a read-only value draws in the new 13 px `text.value` role, and the label column is 140 px wide.
- Jarvis adds one-click local voice setup with pinned Python packages, model verification and a real bundled-clip probe. Failed setup clears readiness. Settings rechecks after the setup terminal closes.

- Jarvis adds a masked Add key floating terminal, libsecret storage and metadata-only key presence in Settings. Provider keys stay out of files, command arguments, logs and status. The reference API supports future provider adapters and the accounts picker.
