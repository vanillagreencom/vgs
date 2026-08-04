# Shell architecture

## Purpose
VGS is a Hyprland and Niri Quickshell runtime. Hyprland is the reference
implementation; Niri support is additive and uses native dynamic workspaces and
the Niri IPC event stream.

Runtime name: `vshell`.

## Entrypoints
| Entry | Role |
|-------|------|
| `systemd/user/vshell.service` | Starts `~/.local/bin/vshell run` so QML gets `VSHELL_ROOT` |
| `bin/vshell` | CLI wrapper for run, IPC, logs, restart, greeter/auth sync, helper commands |
| `backend/` (via `vshell-backend run`) | Go runner: binds the backend socket, supervises the `serve` daemon child, exports `VGS_SOCKET`, spawns Quickshell (see `docs/architecture/backend-daemon.md`) |
| `quickshell/vshell/shell.qml` | Quickshell root; loads `VGS` or `VGSGreeter` based on `VSHELL_RUN_GREETER` |
| `quickshell/vshell/VGSIPC.qml` | IPC surface for runtime calls |

## Main runtime tree
| Path | Role |
|------|------|
| `Common/` | Shared paths, theme state, settings, session data |
| `Services/` | Long-lived shell services and command bridges |
| `Modules/` | Bar, settings, dash, control center, popouts, greetd greeter |
| `Widgets/` | Shared visual components |
| `config/vshell/plugins/` | Internal packages for bundled VGS modules, loaded read-only by the component service |
| `config/vshell/plugins/vgsMenu/` | The app launcher. Required: the shell has no other launcher, and the dock/bar launcher buttons route to it |
| `Modals/Launcher/` | Shared search UI (`LauncherContent` + `Controller`). Its only entry point is the niri overview overlay; `LauncherSettingsPanel` and `FilePreviewPanel` are also used by `vgsMenu` |
| `config/vshell/*.default.json` | Shipped seed defaults, not live user state |
| `config/vshell/dependencies.json` | Feature dependency manifest |
| `~/.config/vshell/` | Mutable user settings/state and user plugin overrides |
| `~/.config/vshell-local/` | Local overlays outside product repo |

## Data flow
1. `vshell.service` starts `~/.local/bin/vshell run`, which exports `VSHELL_ROOT` and execs the Go runner: backend socket bound, `VGS_SOCKET` exported, supervised backend child started, then Quickshell config `vshell` is launched.
2. `shell.qml` loads common singletons, services, and modules.
3. Services read mutable user settings/state from `~/.config/vshell` and bundled defaults/plugins from the repo.
4. UI modules bind to services and shared theme tokens.
5. External actions go through `bin/vshell` / `bin/vshell-helper` when work is not pure UI. Niri KDL parsing and rendering is isolated in `bin/vshell_niri.py` behind that helper CLI; QML passes structured JSON rather than rendering config text. System-integration state (network, logind, BlueZ, CUPS, ...) flows over the backend socket through `Services/VGSBackendService.qml`, gated on advertised capabilities with QML fallbacks.
6. Font rendering settings are helper-owned VGS settings. `vshell fonts apply/reset` writes fontconfig, GTK settings blocks, and supported desktop font-rendering keys; it is not part of theme generation.
7. Compositor shape settings are helper-owned. `vshell config apply-layout
   hyprland` writes `~/.config/hypr/vgs/layout.lua`; `vshell config apply-layout
   niri` writes `~/.config/niri/vgs/layout.kdl`. The compositor config includes
   the matching VGS fragment.
8. `vshell greeter sync` writes `/var/cache/vshell-greeter`, copied greeter runtime, `/etc/greetd/config.toml`, and `/etc/pam.d/greetd`; `vshell auth sync` writes `/etc/pam.d/vshell`, `/etc/pam.d/vshell-u2f`, and refreshes greetd PAM.
9. Empty-password login keyring conversion is explicit: `vshell greeter keyring empty --force` backs up `~/.local/share/keyrings/login.keyring` before replacing it; normal greeter sync refuses destructive conversion.
10. `vshell sudo-toggle` owns the passwordless-sudo protocol used by the
    `sudoToggle` plugin. The privileged drop-in is
    `/etc/sudoers.d/50-<user>-nopasswd-toggle`, validated with `visudo` under a
    dot-suffixed staging name (which sudo ignores) before it is moved into
    place, and mirrored to `~/.local/state/vshell/sudo-passwordless-toggle`
    because `/etc/sudoers.d` is unreadable to the logged-in user. The mirror is
    written without following symlinks at any component, since root writes it
    into a user-controlled tree. The pre-VGS-11 path
    `~/.local/state/sudo-passwordless-toggle` is still read for migration and
    is retired on the next write.

    Two rules keep the mirror from becoming a privilege-escalation path:
    - **The direction is never inferred.** UIs call `set on|off` with the state
      they displayed. When reality disagrees (drop-in removed by an admin,
      restored home backup) the privileged half changes nothing, re-syncs the
      mirror, and exits `3` so the caller re-reads. Inferring the direction
      root-side turned a "revoke" click into a permanent grant.
    - **Enabling always goes through a terminal.** Only the disable direction
      may take the quiet `sudo -n` path. Where sudo already runs without
      prompting, a quiet enable would install `NOPASSWD: ALL` from one click
      with no prompt or window. The terminal comes from `launch_terminal`
      (`$TERMINAL`, then installed candidates), never a hardcoded emulator, and
      a candidate that dies immediately is treated as failed rather than
      launched.

    The terminal requirement is **enable-only**. `available` covers
    sudo/visudo/`/etc/sudoers.d`; the terminal is reported separately as
    `canEnable`/`enableReason`. Gating both directions on it left a machine
    with no terminal unable to revoke an existing grant.

    Because the terminal only guarantees visibility — sudo will not prompt when
    a `NOPASSWD` rule already matches — the widget's confirmation is the real
    gate in that configuration, and it has to hold against two different
    things:
    - **An accidental double-click.** The second click is ignored (not counted,
      not cancelled) until `confirmMinMs`, and the pointer must have left the
      pill since arming. The tracked state is only the *leaving*; that amounts
      to "left and came back" solely because a click requires the pointer to be
      over the pill.
    - **Activation that is not a click at all.** `BarHoverController` calls
      `triggerHoverPopout` on every `PluginComponent`, and `triggerPopout`
      forwards a zero-argument `pillClickAction`, so with `hoverPopouts`
      enabled a pointer crossing the bar reached the action — arming, then
      confirming, with no click. Both guards above are *satisfied* by that
      traversal rather than defeated by it. Two mechanisms close it, both landed
      in VGS-36: `PluginComponent.pillClickOnHover` (opt-in, default `false`)
      stops hover from invoking the action, and `PluginComponent.pillActionOrigin`
      tells the action how it was reached so `toggle()` can refuse anything but
      `"click"` at the decision point. Unannounced invocations default to
      `"ipc"`, so a caller that forgets to declare an origin fails closed.

    `sudoToggle` is deliberately **not** in `settings.default.json`. The plugin
    ships and is enabled, so it appears in the widget picker, but a permanent
    no-expiry passwordless-root switch is not something a stock bar should offer
    by default — the user places it. The guards above are what make the control
    safe once placed; keeping it out of the default bar is what keeps it from
    being offered to users who never asked for it.

    `scripts/test-sudo-toggle-confirm.js` extracts the decision functions from
    the QML and exercises them directly, since bundled plugins get no runtime
    coverage from the nested smoke (VGS-19).

    `status --json` reports `available`/`reason`, `canEnable`/`enableReason`,
    `dropinInstalled` (VGS's own rule) and `sudoNonInteractive` (whether sudo
    prompts at all right now, from any rule or a cached credential). The sudo
    probe is not run at shell start: for a non-sudoer it logs a security event
    and mails root under the default `mail_no_user`, so the widget passes
    `--no-sudo-probe` at startup and asks for real only once the user hovers
    the control. It is not filtered by group membership, which would skip a
    user granted sudo by a direct sudoers rule.
11. Optional widgets check helper/backends and degrade when unavailable.

## Single instance per session
One session owns one VGS shell. A second full instance competes for
session-global resources — `WlSessionLock`, the `vshell:fade-to-lock` overlay,
the idle/DPMS tiers in `Services/IdleService.qml` — and leaves orphaned
full-screen layer surfaces behind when it dies, which presents as a live session
of movable cursors over black screens.

`shell.qml` therefore runs a duplicate-instance guard before loading `VGS`:
`vshell instances guard --pid <pid> --shell-id <id>` (helper-owned; reads the
Quickshell instance registry for the current `XDG_RUNTIME_DIR`). Age comes from
kernel process start times, with the registry's launch time as a fallback. Only
an instance *provably* younger than a live peer yields, and it terminates itself
instead of drawing anything. Every unknown — no CLI, unreadable registry,
unprovable age, no answer within 2s — fails open, so the guard can never keep
the session shell from starting. `VSHELL_DISABLE_INSTANCE_GUARD=1` overrides it; greeter mode
(`VSHELL_RUN_GREETER`) skips it, since the greeter runs from its own copied
runtime.

Known limits, deliberate rather than accidental:
- A peer is only counted when the pid is a live `qs`/`quickshell` process. A
  registry entry can outlive its shell and the number can be reused, and acting
  on a recycled pid would make the session shell terminate *itself*.
- A shell launched from a different checkout (a git worktree) has a different
  config path, so it is neither listed nor guarded. `scripts/qml-smoke.sh` is
  still the defence there.
- A yielding shell exits on SIGTERM, which systemd reads as a clean stop, so a
  `vshell.service` shell that yielded is not restarted. That is why yielding
  requires positive proof of an older live peer.

Validation must never launch a shell into the live session. `scripts/qml-smoke.sh`
is the canonical QML smoke: a static `qmllint` parse pass by default, and with
`--nested` a real shell run inside an isolated nested compositor (own runtime
dir, own `HOME`/XDG dirs, private D-Bus session, no `VGS_SOCKET`, no
`HYPRLAND_INSTANCE_SIGNATURE`) with process-group-scoped cleanup.
`scripts/check-validation-safety.sh` asserts a validation run left the live
instance set and layer surfaces untouched.

## IPC
Use:
```bash
vshell ipc call <target> <function> [args...]
```

Common calls:
```bash
vshell ipc call capture open
vshell ipc call theme reload
vshell ipc call settings openWith theme
vshell ipc call settings openWith wallpaper
```

### Capture state

`Services/CaptureService.qml` is the single QML owner for capture UI state. It
reads recording status from the VGS recording helper and receives delayed
screenshot countdown updates through the `capture` IPC target. The bundled
`screenRecord` widget ID is intentionally stable for existing bar layouts, but
its product name is **Capture**: idle click opens the chooser, countdown click
cancels the pending screenshot, recording click stops recording, and
right-click always opens the chooser.

## Extension and bundled-module model
Bundled VGS modules live under `config/vshell/plugins/<id>/` as an internal packaging detail and are loaded read-only from the repo. Product UI presents their widget surfaces as normal VGS widgets, and they are always available rather than enabled or disabled as third-party plugins. User plugin overrides live under `~/.config/vshell/plugins/<id>/` and take precedence over bundled and system packages; those external packages remain managed in the Plugins settings page.

Minimum shape:
```text
plugin.json
Component.qml
Settings.qml optional
*.js optional
```

Bundled packages are VGS product UX, not third-party extensions.
Local/private commands belong in overlays or plugin settings.
Keep legacy metadata only where the loader still needs it for third-party compatibility.
Do not add legacy runtime calls.

### Pill actions must know how they were reached
A widget's `pillClickAction` is not only run by a click. With `hoverPopouts`
enabled the bar's hover controller reaches every `PluginComponent` through
`triggerHoverPopout`, and `BarWidgetService` runs the same action for the
`widget toggle` IPC call. Two rules follow, both enforced by
`scripts/test-pill-hover-safety.js`:

- **Hover-activation is opt-in.** `pillClickOnHover` defaults `false`, so
  hovering falls through to the popout branch. A widget only sets it `true` when
  running its action on hover is genuinely harmless.
- **Destructive actions check the origin.** `PluginComponent` invokes every pill
  action through `_runPillAction`, which sets `pillActionOrigin` and fails closed
  to `"ipc"` when a caller does not name one; only the pills' own click handlers
  report `"click"`. An action whose effect is unrecoverable must require that,
  rather than trusting that it can only have been reached by a click —
  `config/vshell/plugins/screenRecord/` is the worked example.

## External commands
QML may use `Process` for small calls.
Use `Paths.vshellCli` for VGS helper calls.
Do not rely on inherited `PATH` inside Quickshell.

## Local overlays
Menu overlay:
```text
~/.config/vshell-local/menu.json
```

Schema reference: `docs/architecture/overlay-and-dependencies.md`.

## Greeter/keyring note
See `docs/architecture/greeter-auto-login-keyring.md` for the auto-login GNOME keyring decision and safety policy.

## Rollback
Rollback is an explicit restore/reinstall operation, not a kept service-level dependency. Normal VGS runtime features must start clean on a machine with only VGS state and helpers installed.
