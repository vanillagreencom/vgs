# Notification ownership

Covers: quickshell/vshell/Modules/Notifications/, quickshell/vshell/Services/, bin/

`Services/NotificationService.qml` owns the notification server. The helper owns conflict detection, takeover and restoration.

## Invariants

- Detection uses the session bus and activation files. An unreadable query is unknown, not unowned. See the notification status implementation in `bin/vshell_helper.py`.
- A takeover stops or masks only a unit proven to own the notification process. Compositor unit membership alone is insufficient. The helper notification tests in `scripts/check-vshell-helper.py` cover ownership.
- Takeover and restoration use the persisted undo record as provenance. Partial actions and missing records produce errors. See the helper notification tests and `scripts/check-notification-takeover.js`.
- Automatic takeover is spent durably before it runs and only follows loaded settings. `scripts/check-notification-takeover.js` checks the startup path.
- The CLI status report never withholds the manual takeover command over what the shell might do. Whether the automatic takeover fires is `Services/NotificationService.qml`'s decision, made from settings state the helper cannot see; the helper reports an actionable conflict and adds the unspent one-shot as a further note. A manual takeover touches only the undo record, so it is valid whatever settings.json's readability or writability. `test_notification_status_always_names_the_actionable_takeover` in `scripts/check-vshell-helper.py` checks it across the states a gate here previously suppressed.
- The automatic-takeover notice must reach the user and remain available. `scripts/test-toast-actions.js` checks protected categories and sticky delivery.
- Opt-out reverses an automatic takeover after any in-flight helper operation finishes. See `Services/NotificationService.qml` and the takeover check.
- A saved popup image reaches its history entry by that entry's own id, which `NotificationService.addToHistory` hands to the notification wrapper. The freedesktop notification id is not a key for it: `replaces_id` reuses one within a session, and the daemon's counter restarts with the shell, so entries from different notifications carry the same one. A notification the history keeps no entry for saves no image, because nothing could ever name it. `attachHistoryImage` copies the entry and changes only its image, so attaching one drops no field the entry carries. `scripts/test-notification-history-trim.js` checks that decision and the popup wiring that feeds it.
- The history owns its cached images in `~/.cache/vshell/notification_images/`. `NotificationService.addToHistory` deletes the images of the entries the count cap drops, unless a kept entry names the same file; `scripts/test-notification-history-trim.js` checks that split. `vshell cache prune`, which `VGS.qml` runs when it loads, deletes the images no entry in `notification_history.json` names once they are older than `NOTIFICATION_IMAGE_GRACE_SECONDS`, matching by file name, and deletes none when that file cannot be read. `test_cache_prune_bounds_imagecache_and_drops_unreferenced_notification_images` in `scripts/check-vshell-helper.py` checks it.
