# Notification actions

Covers: shell/plugins/vgs.notifications/Service.qml, shell/plugins/vgs.notifications/CardSlot.qml

What a choice on a notification in `vgs.notifications` does, which windows it brings into view, which notifications the service keeps holding after their toast leaves, and what the senders it was built for carry. The plugin's [README](../../shell/plugins/vgs.notifications/README.md) says what the user sees. The Quickshell 0.3.1 facts this rests on are in [§ Quickshell 0.3.1](#quickshell-031), and the Hyprland ones in [runtime-hyprland.md](runtime-hyprland.md).

## The open rule

- A choice on a card is one of three, and `NotificationLogic.choicePlan` answers what it does for every sender alike. `open` is a click on a toast or an inbox row, Show and the `invoke-latest` IPC. `action:<identifier>` is a pill of the sender's own. `dismiss` is Dismiss or a right click.
- Opening delivers `default`, and a pill its own action, while the service holds the notification and it offers that action. Every action names a place in the sender, so either then brings the sender's window into view, delivered or not. The server gives the sender no activation token, so on Wayland neither Slack nor Chromium can raise its own window after the click.
- Bringing into view is the core's `shell.compositor.reveal` ([capabilities.md](capabilities.md)), never a dispatch of the plugin's own: after a delivered action it first waits briefly for the sender to raise its own window, and moves nothing when it did. [D051](../decisions/D051-notification-actions-reveal-the-sender.md) records the rule and why it differs from Omarchy.
- Dismissing delivers and raises nothing.
- Each choice that raises logs `notifications: chose delivered=<identifier|none> windows=<n>`, with no content, and the core logs where the reveal ended, so a live check can read what a click reached.

## The sender's window

`NotificationLogic.senderWindows` names the windows that may have sent the notification, and the core's reveal picks one: the window the sender asks for, else the one the user focused last. The windows are:

1. those whose class is the notification's desktop entry, else its application name, case folded;
2. else, for a browser's web notification ([notification-senders.md § Browser notifications](notification-senders.md#browser-notifications)), the Chromium-family windows whose class names the site's host, as an installed web app's does;
3. else every Chromium-family window open;
4. else none, and nothing moves.

A Slack message from a browser therefore raises a browser, never Slack's desktop client, and a copy the desktop client sent raises Slack.

## What the service holds

- Holding an expired toast's notification for its inbox row is [D051](../decisions/D051-notification-actions-reveal-the-sender.md)'s. The service holds a notification, tracked on the server with its `closed` and update signals connected, under the key its toast and its history entry share. `NotificationLogic.heldAfterLeave` decides what happens when the row leaves. A toast that expires or that a full stack lets go stays held. So does one opened or acted on, which the server itself closes unless the sender marked it resident. A silenced notification is held once its image copies exist.
- A held notification is closed on the server when its entry leaves the stored toasts and the history (expired, `heldPastHistory`), when the user dismisses its toast or its inbox row or clears the history (dismissed), and when the service is destroyed (dismissed). A transient notification is never held.
- A sender that closes a held notification drops it. Its inbox row stays and then raises the sender's window alone.
- At most one notification is held for each stored entry, so the history's 100 and the 20 toasts on screen bound them. `status` counts them in `held`.
- A sender that updates a notification held for the history sends something new. It arrives again as a new notification under a new key, a toast or under Silence a history entry, and the history keeps the entry as it was shown. Without that, an update reaches no screen: the server updates the object in place and signals no new notification. The server signals each changed property on its own, so the service takes a held notification's signals together at the end of the event-loop turn: one replacement is one update and one history entry, and no update reads the object half changed.
- The server does not watch a sender's connection. A sender that exits without closing its notification leaves it held until its entry goes. Opening its row then delivers to nobody and still raises by class.

## What the senders carry

- Slack's desktop client is Electron. Its libnotify notification sends a title, a body, one `default` action labelled Show, the urgency, an image when it has one, and the `desktop-entry` and `sender-pid` hints; the `append` hint only to a server that advertises it, which Quickshell does not. Nothing in it names a channel, a thread or a URL (`LibnotifyNotification::Show` in `shell/browser/notifications/linux/libnotify_notification.cc`, electron/electron main, read on 2026-09-29). The click reaches Electron's `NotificationClicked`, which runs the application's own click handler, where Slack decides what to open. Electron asks libnotify for the activation token on the click (`OnNotificationView`) and gets none. VGS therefore builds no `slack://` link: nothing to build one from arrives.
- Chromium sends a web notification's body with the site's address first, a `default` action labelled Activate and a `settings` action. Its origin is the site, never the page (`NotificationPlatformBridgeLinuxImpl` in `chrome/browser/notifications/notification_platform_bridge_linux.cc`, chromium/chromium main, read on 2026-09-29). It forgets a notification once told it closed (`OnNotificationClosed`), so an action after that reaches nothing.

## Quickshell 0.3.1

What the Quickshell 0.3.1 notification server does, from its source at tag `v0.3.1` (commit `1a4716c`, `src/services/notifications/`), which the notifications rest on:

- `NotificationAction::invoke()` emits `ActionInvoked` with the notification's id and the action's identifier, then closes the notification as `Dismissed` unless its `resident` hint is set (`notification.cpp`, lines 45 to 56).
- The server emits no `ActivationToken`: `org.freedesktop.Notifications.xml` declares the signal (line 46) and nothing under `src/` emits it. A sender that raises its window with the token it waits for gets none.
- `Notification::expire()` and `dismiss()` close the notification (`notification.cpp`, lines 65 to 79). `NotificationServer::deleteNotification` then emits the object's `closed`, drops the id, emits `NotificationClosed` and destroys the object (`server.cpp`, lines 100 to 113). An action on a destroyed notification is refused with `Cannot invoke destroyed notification`. A sender's `CloseNotification` takes the same path as `CloseRequested` (lines 136 to 142).
- `Notify` with the id of a notification the server still tracks updates that object in place and emits no new `notification` signal, only the changed properties' signals (`server.cpp`, lines 177 to 220). An id it no longer tracks makes a new notification with a new id.
- The server watches only its own bus name (`server.cpp`, lines 48 to 57), never a sender's connection: a notification stays tracked until the service or its sender closes it.

## Omarchy

Omarchy's notifications (`shell/plugins/notifications/Service.qml` `invokePopupDefault`, basecamp/omarchy default branch, read on 2026-09-29) invoke a toast's `default` action and focus the sender's window by class only when the invoke fails; a history replay has no live action, so it only focuses the window. VGS brings the window into view on every action, because the sender cannot raise it on Wayland, picks among several windows the one the sender asked for or the user used last, and holds the notification for the inbox, so an inbox row reaches the sender as a toast does.

## Invariants

1. Every action but Dismiss delivers the sender's action while it is held and offered, and brings the sender's window into view either way; Dismiss does neither. Enforced by `scripts/test-notifications-logic.js`, each rule with a control, and by `scripts/smoke/rows/notifications.sh`, which reads the sender's signals and the focused window after a toast click, the Open and Reply pills and the Dismiss pill, starting each from another window.
2. A toast that expired stays deliverable from its inbox row; a dismissed one and one its sender closed deliver nothing and still raise. Enforced by `scripts/smoke/rows/notifications.sh` and by the holding rules' controls in `scripts/test-notifications-logic.js`.
3. No notification is held past its stored entry. Enforced by `scripts/test-notifications-logic.js`, `heldPastHistory` with a control, and by the bound `scripts/smoke/rows/notifications.sh` reads after the history is full.
4. A browser's web notification names browser windows and never the desktop client of the same service. Enforced by `scripts/test-notifications-logic.js`, each window rule with a control.
