# Shell architecture

## Purpose
VGS is a Hyprland and Niri Quickshell runtime. Hyprland is the reference
implementation; Niri support is additive and uses native dynamic workspaces and
the Niri IPC event stream.

Runtime name: `vshell`. Quickshell config name `vshell`, started by
`vshell.service`. App id `com.vanillagreen.vshell` — what the shell's own
toplevels report, so bar and dock code treats it, alongside `org.quickshell`,
as a VGS window rather than a launchable app.

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
| `Widgets/Launcher/` | The launcher UI a bundled plugin may import: `LauncherSettingsPanel`, `FilePreviewPanel`. See "Core and the vgsMenu plugin" below |
| `Modules/WorkspaceOverlays/OverviewSearch/` | The niri overview's inline search (`OverviewSearchContent` + `Controller`). Owned by the overview; it has no other entry point and is unreachable on Hyprland |
| `config/vshell/plugins/` | Internal packages for bundled VGS modules, loaded read-only by the component service |
| `config/vshell/plugins/vgsMenu/` | The app launcher. Required: the shell has no other launcher, and the dock/bar launcher buttons route to it |
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
    - **An accidental double-click.** The confirmation is
      `Modals/SudoGrantConfirmModal.qml`: a modal with explicit Cancel/Grant
      controls, opened by the click and satisfied only by activating the grant
      control inside it — clicking it, or moving focus to it and pressing
      Return. Cancel is the default — it is what carries focus, and
      what Escape, a background click and the close button do — so the
      destructive action is never one stray Return away. Until VGS-55 this was
      a toast plus a pointer gesture (move off the pill, click again, no sooner
      than 600 ms and within 8 s); nothing on screen was interactive and the
      requirement was discoverable only by reading the toast.

      The modal carries a **"Don't ask me again"** checkbox, unticked on every
      prompt and honoured only by an actual confirmation — ticking it and then
      cancelling changes nothing. It persists to
      `SettingsData.sudoToggleSkipGrantConfirm` (a top-level settings key, not
      plugin data, default `false`), after which a click grants immediately.
      The plugin's settings pane, `SudoToggleSettings.qml`, is where that is
      turned back on; the opt-out must not be a one-way door. Revoking is
      unprompted either way.
    - **Activation that is not a click at all.** `BarHoverController` calls
      `triggerHoverPopout` on every `PluginComponent`, and `triggerPopout`
      forwards a zero-argument `pillClickAction`, so with `hoverPopouts`
      enabled a pointer crossing the bar reached the action — arming, then
      confirming, with no click. The pointer guards it used to face were
      *satisfied* by that traversal rather than defeated by it; a modal cannot
      be confirmed by traversal, but hover must still not raise one, and with
      confirmation opted out a hover would otherwise grant outright. Two
      mechanisms close it, both landed
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
One session owns one VGS shell: a second full instance competes for the
session-global resources (`WlSessionLock`, the `vshell:fade-to-lock` overlay,
the idle/DPMS tiers in `Services/IdleService.qml`) and strands orphaned
full-screen layer surfaces. The rule, its consequences, and the recovery path
are canonical in AGENTS.md § Never launch a second shell into the live session.

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

Validation must never launch a shell into the live session — the rule, the
smoke modes (`scripts/qml-smoke.sh`), and the post-run assertion
(`scripts/check-validation-safety.sh`) are canonical in AGENTS.md § Never
launch a second shell into the live session.

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

### Persisting a plugin setting: save, never assign
A widget property backed by plugin data is a **binding**:

```qml
property string headlineMode: pluginData.headlineMode || "pool"
```

A setter must call `pluginService.savePluginData(...)` and nothing else.
Assigning the property as well — the idiom that reads as "apply it now, then
persist it" — destroys that binding for that instance, and the assignment is
redundant anyway: the save emits `pluginDataChanged`,
`PluginComponent.loadPluginData()` reassigns `pluginData` to a fresh object, and
every live binding re-evaluates.

**Persist-never-assign holds everywhere. The *timing* does not.** There are two
`pluginService` implementations and they differ in exactly one respect:

| Host | `savePluginData` emits `pluginDataChanged` | So after the setter returns |
|------|-------------------------------------------|------------------------------|
| Bar widgets — the global `Services/PluginService.qml` reached by `PluginComponent` | synchronously (`SettingsData.setPluginSetting(...)` then the signal, in the same call) | every bound property already reads the new value |
| Desktop widgets — the instance-scoped service inside `Modules/Plugins/DesktopPluginWrapper.qml` | on the next event-loop turn (`Qt.callLater`), because the write goes through `SettingsData.updateDesktopWidgetInstanceConfig` for one instance | bound properties still read the **old** value |

So a desktop widget author must never read a `pluginData`-bound property back
in the same function that saved it, and must not sequence follow-up work — a
refresh, a fetch, a mode-dependent branch — off the assumption that the value
already changed. Do the follow-up work where the *change* is observed rather
than where the save is issued: an `onXChanged` handler on the bound property,
or a `Connections { target: pluginService; function onPluginDataChanged(id) }`.
That form is correct under both hosts, and it is also what keeps sibling
instances in step, since each one runs its own handler (see
`config/vshell/plugins/aiUsage/AiUsageWidget.qml::onProviderChanged`).

The reason it looks correct in testing is that a widget is instantiated **once
per configured bar**. On a single display the assignment and the binding agree.
On a second display the assigning instance has gone unbound while the other
still follows `pluginDataChanged`, so one persisted setting renders as two
different states (VGS-74).

**A setting that scopes a fetch owns two more rules** (VGS-118). When a widget
fetches per-source data — a provider, an account, a device — and a setting
chooses the source:

- **Attribute every result by what the payload says it is**, not by the source
  the fetch was launched for and never by the one selected when the output
  arrives. Launch tags race: a tag can be reassigned while the process holding
  it is still running, and the old process's payload then passes the tag check
  under the new source's name. Helpers must therefore stamp their own identity
  on every path they return from, failures included.
- **Invalidate the source-scoped state when the setting changes**, together and
  before the refetch. Anything left behind renders under the new source's label
  until a payload replaces it, and a dropped refetch makes that permanent — so
  relaunch on "is the state on screen the selected source's?", never on "did the
  selection move?", which answers no on a there-and-back toggle.

### Core and the vgsMenu plugin
The app launcher is a bundled plugin that core cannot do without, so the edge
between them is one-way and named at both ends. See
[D004](../decisions/D004-overview-search-ownership-and-plugin-boundary.md).

**Core → plugin** goes through a single seam in `PluginService`:
`appLauncherPluginId`, `toggleAppLauncher()`, `appLauncherOpen`. The dock
button, the bar widget and the changelog card all route through it, so the
plugin id is written once and the unavailable-launcher handling lives in one
place. Core shell code must not name `"vgsMenu"` directly.

**Plugin → core** is limited to the sanctioned import surfaces every plugin
already uses — `qs.Common`, `qs.Services`, `qs.Widgets`, `qs.Modules.Plugins` —
plus `qs.Widgets.Launcher` for the two shared launcher panels. A bundled plugin
must not import another feature's directory: that is the reach that made
`Modals/Launcher` unmovable while `vgsMenu` depended on its internals.

`Widgets/Launcher/` therefore holds only components with more than one
consumer. A panel used solely by `vgsMenu` belongs inside the plugin; one used
solely by the overview search belongs in `Modules/WorkspaceOverlays/OverviewSearch/`.

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

One deliberate exception is the system tray's `ContextMenu` fallback in
`Modules/Bar/Widgets/SystemTrayBar.qml`, which shells out because Quickshell
0.3.0 exposes no way to make that SNI call. It stays there rather than moving
to the helper CLI or the backend: see
[D003](../decisions/D003-system-tray-transport.md) for the alternatives and the
limitation that comes with keeping it.

## Local overlays
Menu overlay:
```text
~/.config/vshell-local/menu.json
```

Schema reference: `docs/architecture/overlay-and-dependencies.md`.

## Changelog ("What's New")
`Services/ChangelogService.qml` shows `Modals/Changelog/ChangelogModal.qml` once per
shipped version. Three rules make that dependable:

- **The version is the release, not a constant.** `currentVersion` is
  `ShellVersionService.semverVersion`, read from `quickshell/vshell/VERSION`. A
  release bump is what re-displays the changelog, so the notes in
  `ChangelogContent.qml` reach users exactly when the release carrying them ships.
  There is no separate changelog version to remember to bump.
- **Dismissal is per version.** Clicking through writes
  `~/.config/vshell/.changelog-<version>`; the marker for one version never
  suppresses the next.
- **Fresh installs are silent.** `FirstLaunchService.isFirstLaunch` suppresses the
  modal and the marker is written anyway, so a new user does not get upgrade notes
  for an upgrade they did not make. An existing user with no marker does see it —
  that is the upgrade path working.

Write user-visible breaking changes as `ChangelogUpgradeNote` entries in
`ChangelogContent.qml`, and keep the feature cards pointing at settings tab ids
that exist in `Modals/Settings/SettingsRegistry.qml`.

## Greeter/keyring note
See `docs/architecture/greeter-auto-login-keyring.md` for the auto-login GNOME keyring decision and safety policy.

## Rollback
Rollback is an explicit restore/reinstall operation, not a kept service-level dependency. Normal VGS runtime features must start clean on a machine with only VGS state and helpers installed.
