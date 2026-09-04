# Notification ownership

Covers: quickshell/vshell/Modules/Notifications/, quickshell/vshell/Services/, bin/

`Services/NotificationService.qml` owns the notification server. The helper owns conflict detection, takeover and restoration.

## Invariants

- Detection uses the session bus and activation files. An unreadable query is unknown, not unowned. See the notification status implementation in `bin/vshell-helper`.
- A takeover stops or masks only a unit proven to own the notification process. Compositor unit membership alone is insufficient. The helper notification tests in `scripts/check-vshell-helper.py` cover ownership.
- Takeover and restoration use the persisted undo record as provenance. Partial actions and missing records produce errors. See the helper notification tests and `scripts/check-notification-takeover.js`.
- Automatic takeover is spent durably before it runs and only follows loaded settings. `scripts/check-notification-takeover.js` checks the startup path.
- The automatic-takeover notice must reach the user and remain available. `scripts/test-toast-actions.js` checks protected categories and sticky delivery.
- Opt-out reverses an automatic takeover after any in-flight helper operation finishes. See `Services/NotificationService.qml` and the takeover check.
