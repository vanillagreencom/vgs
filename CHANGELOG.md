# Changelog

## Unreleased

- Slack sender photos are now an owner-only extra, off by default. An install that had them keeps them: a one-time migration sets `"slackPhotos": true` in the `vgs.notifications` row of `plugins` in `~/.config/vgs/shell.json` when a Slack token is stored. New one-time migrations run once per user from `vgsh run` and `vgsh self update`. With it off, Settings shows no Slack token rows and the plugin reads no token and calls no Slack API. Workspace icons, custom emoji from Slack's cache, initials faces and one card per message need no setup. A manifest's new `extras` key declares such a switch.
- Jarvis adds Talk, Mute and Stop keys, hold or toggle mode, and persistent privacy mute. Key tests use a private scripted engine. The installed daemon remains unconfigured and captures no audio.
- Jarvis adds a masked Add key floating terminal, libsecret storage and metadata-only key presence in Settings. Provider keys stay out of files, command arguments, logs and status. The reference API supports future provider adapters and the accounts picker.
