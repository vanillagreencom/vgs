# Lock and polkit

Covers: shell/plugins/vgs.lock/**, shell/plugins/vgs.polkit/**, shell/Core/IdleRegistry.qml, bin/vgsh-lock, scripts/test-lock-model.js, scripts/test-lock-sleep-watch.sh, scripts/test-vgsh-lock.sh, scripts/test-polkit-model.js, scripts/smoke/rows/lock.sh, scripts/smoke/rows/polkit.sh

How a VGS session locks and how it answers polkit. Both are native plugins on objects the core owns: [D056](../decisions/D056-native-lock-and-polkit-plugins.md). The core's `lock`, `polkit` and `idle` capabilities are [capabilities.md](capabilities.md).

## Lock

- **Owner.** `vgs.lock` holds the core's `lock` capability and hands the core `LockView.qml`, which `shell/Hosts/LockHost.qml` builds inside each lock surface. The plugin owns no `WlSessionLock`. The core keeps a locked session locked when the plugin is disabled, updated or rebuilt, and a rebuilt plugin hands its lock screen over again.
- **Entry points.** All reach the service's one `lock()`:
  - the shortcut `lock`, `SUPER+L` in the manifest's `hyprland.binds`;
  - the IPC function `vgsh ipc call vgs.lock invoke lock ''`, which `vgsh lock` (`bin/vgsh-lock`) and the launcher's Lock row call;
  - an idle watch after `idleLockSeconds` without input;
  - the before-sleep hook.
- **Lock screen.** Every screen draws the theme's background image, the target of the state directory's `background` link ([theme-backgrounds.md](theme-backgrounds.md)), under `Scrim`. Over it sit the time, the date and one password `TextField`, all `qs.Ui` components on tokens. Every screen's field shows the one password the service holds. Enter checks it, Escape clears it, and a click anywhere returns the keyboard to the field. A spinner turns while PAM checks, and a failure shows in the danger colour: PAM's own message when it sent one, such as pam_faillock's pause, else the count.
- **PAM.** A `PamContext` reads `pam/vgs-lock` from the plugin's own directory through `configDirectory`, so nothing is installed under `/etc`. The stack is Omarchy's `omarchy-lock-password`, `auth` lines alone, since `PamContext` runs only that type: ten failures pause the check for two minutes, and a success clears the count. The conversation starts only when the user presses Enter, and the password reaches only the field and PAM's answer. It is never logged, published or answered over IPC.
- **Idle.** `shell.idle.watch(idleLockSeconds, fn)` locks when the seat has had no input for that long; idle inhibitors, such as a playing video's, hold it off. 0 turns it off. The default is Omarchy's 300 s.
- **Before sleep.** While `lockBeforeSleep` holds, the service runs `systemd-inhibit --what=sleep --mode=delay` over `bin/sleep-watch`, whose header states its protocol. When logind announces a suspend, the service locks and writes `secure` once the core confirms the lock. The hook then exits, which lets the suspend go. It waits at most Omarchy's budget: logind's `InhibitDelayMaxUSec` less a fifth, at least one second kept for logind, capped at 12 s. The status `sleep` reports whether the hook holds. A hook that fails, as with no logind, is retried a minute later.
- **Stranded lock.** At start the service reads `hyprctl -j monitors`; `hyprctl` is the core's, which the runner's preflight requires, so the manifest does not declare it again. A monitor that names `LOCK` in `solitaryBlockedBy` means an ext-session-lock holds, and Hyprland keeps it after its client dies. When the shell holds no lock, the service locks: the Hyprland layer's `misc.allow_session_lock_restore` lets the new lock take over the dead one ([hyprland.md](hyprland.md)). A monitor still coming up answers `WORKSPACE` first, so the service asks again every 500 ms, twenty times. `LockModel.sessionLockState` reads the answer as Omarchy's `omarchy-hyprland-session-locked` does.
- **Crash.** A shell that dies while locked leaves the session locked behind Hyprland's own warning screen. The next shell, started from a TTY or the autostart, takes the lock over with its lock screen.
- **Reload.** A Quickshell 0.3.1 reload while locked can unlock ([runtime.md](runtime.md)). `vgsh run` turns the engine's file watcher off and no code path reloads the engine, and `vgsh restart` refuses while locked.

## Polkit

- **Agent.** `vgs.polkit` names capability `polkit`, so the core builds its one `PolkitAgent` while the plugin is enabled. polkitd accepts one agent per session. Another agent registered first, or no polkitd, leaves `registered` false, and the service publishes the status `agent`.
- **Prompt.** The service summons the plugin's `overlay` when the agent's `isActive` turns true, and hides it when it turns false. A request no prompt can answer is cancelled.
  - The prompt is a `Scrim` and a `Dialog` whose `initialFocus` is a password `TextField` ([components.md](components.md)).
  - It names the requesting action by its message and its polkit action id.
  - It offers a `Select` of identities when the request accepts several; a choice starts the conversation again as that identity.
  - It shows PAM's messages and errors under the field.
  - `PolkitModel.js` maps the flow to what the prompt draws.
  - Cancel, Escape and the prompt closing by any other path cancel a live request.
  - The password lives only in the field. It is cleared on submit and on close, and never logged, published or exposed over IPC.
- **No flow, no prompt.** `open()` throws while no request is live, so the host refuses a summon and maps no surface.

## Validation

- No test runs PAM against the real account, whose pam_faillock counts each failure. On host cachy on 2026-09-29, two sandbox runs that ended a PAM conversation by signal locked the owner's account for ten minutes. `scripts/smoke/rows/lock.sh` types no password. The sandbox's probe, test code that never ships, releases the core's lock with `sessionUnlock` and takes a stranded lock over with `sessionLockBare`. The row asserts the plugin never started a check.
- A live polkit flow cannot run in the sandbox: it needs polkitd and the setuid `polkit-agent-helper-1`. `scripts/test-polkit-model.js` covers the prompt's decisions, and `scripts/smoke/rows/polkit.sh` the agent, its status and the refused flowless summon.
- The sandbox's system bus has no logind, so the lock row stands in `systemd-inhibit`, `busctl` and `dbus-monitor`, and announces one sleep through a trigger file.

## Invariants

1. Each entry point locks the nested session: the IPC function, `vgsh lock`, `SUPER+L`, two seconds of idle and an announced sleep, which the hook releases only after the lock is confirmed. Disabling the plugin while locked keeps the session locked, and the rebuilt plugin hands its lock screen over again. A shell killed by its pid while locked leaves the session locked, and the next shell takes the lock over. Enforced by `scripts/smoke/rows/lock.sh`, reading `LOCK` from `hyprctl -j monitors` and the core's lending record. Its control is a plugin copy that never takes a stranded lock over.
2. The stranded-lock reading, the failure line, the hook's protocol lines and the sleep status hold as `LockModel.js` decides them. Enforced by `scripts/test-lock-model.js`, one control per rule.
3. The hook's budget, its lines and its release on `secure`, on the budget's end and on a closed stdin hold, and a dbus-monitor that ends is refused. Enforced by `scripts/test-lock-sleep-watch.sh`, one control per rule on a copy of the script.
4. `vgsh lock` calls the lock function of the shell the instance lock names, and answers its reply or a keyed refusal. Enforced by `scripts/test-vgsh-lock.sh`, one control per rule.
5. `vgs.polkit` holds `polkit` and the agent exists while it is enabled, the agent is reported unregistered on a bus without polkitd, and no prompt surface exists without a flow. Disabling it destroys the agent and its status record. Enforced by `scripts/smoke/rows/polkit.sh`, whose control is a plugin copy whose prompt opens with no flow.
6. The prompt draws each flow state, the action and the identities as `PolkitModel.js` maps them, and cancels only a live flow. Enforced by `scripts/test-polkit-model.js`, one control per rule.
