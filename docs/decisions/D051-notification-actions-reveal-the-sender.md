# D051: Every notification action reveals the sender's window through one core helper, and an expired toast stays deliverable

[← Decision Index](INDEX.md)

**Date**: 2026-09-29

**Status**: Active

**Research**: VGS-603

**Context**: A click on a Slack notification, or its Open button, did not take the owner to the message. Three causes stacked. The service closed each notification on the server as soon as its toast left, so every inbox row was a dead copy that no action could reach. The Open button delivered the action and raised nothing. Quickshell 0.3.1's server emits no `ActivationToken` ([notification-actions.md § Quickshell 0.3.1](../architecture/notification-actions.md#quickshell-031)), so a sender on Wayland cannot raise its own window after the click. The owner then widened the ask: every action must take the user to the place it names, whatever workspace, scratchpad, group tab or monitor holds the window.

**Decision**:

- **One rule for every sender.** A click on a toast or an inbox row, and every action pill but Dismiss, deliver the sender's action while the service still holds the notification, then bring the sender's window into view, delivered or not (`NotificationLogic.choicePlan`). No per-application switch.
- **One core helper.** Bringing a window into view is `shell.compositor.reveal(addresses, awaitSender)` in `shell/Core/Compositor.qml`, with its decisions in `shell/Core/Dispatch.js`, for any plugin and for the core's own TUI focus. It picks the window the application asked for, marked urgent by Hyprland, else the one focused last, ranked by `focusHistoryID`, and moves nothing only when that window is Hyprland's active window and its workspace is on the screen, read in one batched `hyprctl` request; `focusHistoryID` is history, and the window focused last keeps 0 on an empty workspace. It shows the window through Hyprland's focus dispatcher, which already switches workspace, shows a hidden special workspace without a toggle, makes a group tab current and ends a fullscreen over it ([runtime-hyprland.md](../architecture/runtime-hyprland.md)).
- **A bounded, event-driven wait.** After an action the caller delivered, the helper waits up to `Dispatch.SENDER_WAIT_MS`, 250 ms, on Hyprland's event stream for the application to focus one of its windows itself, and then moves nothing, so the view never switches twice. A fixture sender raised itself within 11 ms of the action in the nested sandbox; the bound is the most a click waits when the sender raises nothing, the common case under Quickshell 0.3.1.
- **Held for the inbox.** A toast that expires or that a full stack lets go keeps its notification tracked under its history entry's key, as does one acted on that the server did not close, a resident one, so its inbox row reaches the sender as the toast did. It is closed on the server when its entry leaves the history, when the user dismisses it or clears the history, and when the service goes; its sender's close drops it. A transient notification is never held. The history's limit bounds the held set.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| Close each notification when its toast leaves, as before | Every inbox row became a copy no action reaches, the defect this fixes. |
| Raise only when the action fails, as Omarchy does | The action succeeds and the sender still cannot raise itself without a token, so nothing comes forward. |
| Named actions such as Reply raise nothing | The owner ruled that every action takes the user to its place. |
| The plugin dispatches `focusWindow` itself | Picks the first window of the class, knows no urgent or recent window, and switches twice when the sender raises another window after it; each plugin would repeat it. |
| Reveal at once, with no wait | A sender that raises its own window after the click would switch the view a second time. |
| A fixed sleep before revealing | Waits the whole bound even when the sender answered in milliseconds, and cannot see which window it raised. |
| Toggle a special workspace to show it | Hides one the sender or the user already showed; Hyprland's focus dispatcher shows it without a toggle. |
| Open a `slack://` link as the fallback | Neither Electron's nor Chromium's notification carries a channel, thread or URL, so there is nothing to build it from. |

## Omarchy comparison

Checked against basecamp/omarchy's default branch, `shell/plugins/notifications/Service.qml` `invokePopupDefault` and `bin/omarchy-hyprland-focus-app`, read on 2026-09-29.

| Omarchy | VGS | Where VGS takes it, or why it differs |
|---|---|---|
| A click invokes `default`; the window is focused by class only when the invoke fails. | Every action delivers, then reveals. | A delivered action raises nothing on Wayland without a token. |
| History replays have no live action and only focus the window. | An expired toast stays held; its inbox row delivers. | The owner opens Slack messages from the inbox. |
| The first window whose class matches is focused. | The window the sender asked for, else the one used last. | An application with several windows. |

**Revisit When**: Quickshell's server emits `ActivationToken` to the sender, so a sender raises its own window; Hyprland's focus dispatcher stops showing a hidden special workspace, a group tab or another workspace; a sender is measured raising itself later than 250 ms after the action.

**Verification**: `scripts/test-dispatch.js` (the reveal request, event and target rules, each with a control); `scripts/test-notifications-logic.js` (the choice plan, holding, the held bound and the sender's windows, each with a control); `scripts/smoke/rows/compositor-reveal.sh` (another workspace, a hidden special workspace, under a fullscreen, a background group tab, a second monitor, several windows and a self-raising sender, the old focus path as control where it differs); `scripts/smoke/rows/notifications.sh` (toast, pill and inbox row delivery and focus, with dismissed, sender-closed and Dismiss-pill controls).

**References**: [notification-actions.md](../architecture/notification-actions.md), [capabilities.md](../architecture/capabilities.md), [runtime-hyprland.md](../architecture/runtime-hyprland.md), [D046](D046-slack-tokens-per-workspace-and-one-card-per-message.md)
