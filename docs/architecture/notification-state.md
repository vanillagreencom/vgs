# Notification state

Covers: shell/plugins/vgs.notifications/Store.qml

What `vgs.notifications` keeps on disk and what a restart restores. The plugin's [README](../../shell/plugins/vgs.notifications/README.md) says what the user sees.

`$XDG_STATE_HOME/vgs/notifications/` (`~/.local/state/vgs/notifications/`) holds `state.json`, with Silence, the last Mark read, the toasts on screen and the history, and `images/`, the copies of the images the stored notifications show, since a sender deletes its own files once a notification closes. The history keeps the newest 100 notifications and a panel shows at most 40 of them. A sender's text is stored up to 512 characters of summary and 4096 of body, and an image up to 5 MiB, so the directory holds at most 120 entries and two images each.

The file is written whole at the end of each change. After a restart or a rebuild, the toasts that were on screen show again with a whole lifetime and no live actions, and the ones whose time ran out meanwhile go into the history. A file the service cannot read or does not accept is logged as `notifications: state refused: file=<path> reason=<defect>` or `state unreadable`, shown in the panel's subtitle and in `status`, and left as it is: the service keeps working in memory until Clear history starts the file over. A write that fails is logged and tried again with the next change.
