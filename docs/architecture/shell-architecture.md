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
| `Modules/` | Bar, settings, launcher, dash, control center, popouts, greetd greeter |
| `Widgets/` | Shared visual components |
| `config/vshell/plugins/` | Internal packages for bundled VGS modules, loaded read-only by the component service |
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
10. Optional widgets check helper/backends and degrade when unavailable.

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
