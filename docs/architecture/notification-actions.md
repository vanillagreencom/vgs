# Notification actions

Covers: shell/plugins/vgs.notifications/Service.qml, shell/plugins/vgs.notifications/CardSlot.qml

What opening a notification in `vgs.notifications` does, which window it raises, which notifications the service keeps holding after their toast leaves, and what the senders it was built for carry. The plugin's [README](../../shell/plugins/vgs.notifications/README.md) says what the user sees. The Quickshell 0.3.1 facts this rests on are in [runtime.md § Notifications](runtime.md#notifications).

## The open rule

- A choice on a card is one of three, and `NotificationLogic.choicePlan` answers what it does for every sender alike. `open` is a click on a toast or an inbox row, Show and the `invoke-latest` IPC. `action:<identifier>` is a pill of the sender's own. `dismiss` is Dismiss or a right click.
- Opening, and the pill of the `default` action, delivers `default` while the service holds the notification and it offers that action. It then raises the sender's window through the `compositor` capability's `focusWindow`, held or not. The server gives the sender no activation token, so on Wayland neither Slack nor Chromium can raise its own window after the click.
- Another action of the sender's, such as Reply or Mark read, is delivered and raises nothing, since it is meant to act without a change of context.
- Each open logs `notifications: opened delivered=<identifier|none> raised=<address|none>`, with no content, so a live check can read what a click reached.

## The sender's window

`NotificationLogic.senderAddress` names the window to raise, or none:

1. the window whose class is the notification's desktop entry or application name, case folded;
2. else, for a browser's web notification ([notification-senders.md § Browser notifications](notification-senders.md#browser-notifications)), the one Chromium-family window whose class names the site's host, as an installed web app's does;
3. else the one Chromium-family window open;
4. else none: with several browser windows and none naming the site, no guess is raised.

A Slack message from a browser therefore raises that browser, never Slack's desktop client, and a copy the desktop client sent raises Slack.

## What the service holds

- The service holds a notification, tracked on the server with its `closed` and update signals connected, under the key its toast and its history entry share. `NotificationLogic.heldAfterLeave` decides what happens when the row leaves. A toast that expires or that a full stack lets go stays held. So does one opened or acted on, which the server itself closes unless the sender marked it resident. A silenced notification is held once its image copies exist.
- A held notification is closed on the server when its entry leaves the stored toasts and the history (expired, `heldPastHistory`), when the user dismisses its toast or its inbox row or clears the history (dismissed), and when the service is destroyed (dismissed). A transient notification is never held.
- A sender that closes a held notification drops it. Its inbox row stays and then raises the sender's window alone.
- At most one notification is held for each stored entry, so the history's 100 and the 20 toasts on screen bound them. `status` counts them in `held`.
- A sender that updates a notification held for the history sends something new. It arrives again as a new notification under a new key, a toast or under Silence a history entry, and the history keeps the entry as it was shown. Without that, an update reaches no screen: the server updates the object in place and signals no new notification.
- The server does not watch a sender's connection. A sender that exits without closing its notification leaves it held until its entry goes. Opening its row then delivers to nobody and still raises by class.

## What the senders carry

- Slack's desktop client is Electron. Its libnotify notification sends a title, a body, one `default` action labelled Show, the urgency, an image when it has one, and the `desktop-entry` and `sender-pid` hints; the `append` hint only to a server that advertises it, which Quickshell does not. Nothing in it names a channel, a thread or a URL (`LibnotifyNotification::Show` in `shell/browser/notifications/linux/libnotify_notification.cc`, electron/electron main, read on 2026-09-29). The click reaches Electron's `NotificationClicked`, which runs the application's own click handler, where Slack decides what to open. Electron asks libnotify for the activation token on the click (`OnNotificationView`) and gets none. VGS therefore builds no `slack://` link: nothing to build one from arrives.
- Chromium sends a web notification's body with the site's address first, a `default` action labelled Activate and a `settings` action. Its origin is the site, never the page (`NotificationPlatformBridgeLinuxImpl` in `chrome/browser/notifications/notification_platform_bridge_linux.cc`, chromium/chromium main, read on 2026-09-29). It forgets a notification once told it closed (`OnNotificationClosed`), so an action after that reaches nothing.

## Omarchy

Omarchy's notifications (`shell/plugins/notifications/Service.qml` `invokePopupDefault`, basecamp/omarchy default branch, read on 2026-09-29) invoke a toast's `default` action and focus the sender's window only when the invoke fails; a history replay has no live action, so it only focuses the window. VGS raises the window on every open, because the sender cannot raise it on Wayland, and holds the notification for the inbox, so an inbox row reaches the sender as a toast does.

## Invariants

1. Opening delivers `default` while it is held and offered, and raises the sender's window either way; another action raises nothing. Enforced by `scripts/test-notifications-logic.js`, each rule with a control, and by `scripts/smoke/rows/notifications.sh`, which reads the sender's signals and the focused window after a toast click, the Open pill and a Reply, starting each from another window.
2. A toast that expired stays deliverable from its inbox row; a dismissed one and one its sender closed deliver nothing and still raise. Enforced by `scripts/smoke/rows/notifications.sh` and by the holding rules' controls in `scripts/test-notifications-logic.js`.
3. No notification is held past its stored entry. Enforced by `scripts/test-notifications-logic.js`, `heldPastHistory` with a control.
4. A browser's web notification raises a browser window and never the desktop client of the same service. Enforced by `scripts/test-notifications-logic.js`, each window rule with a control.
