# AGENTS.md

VGS = VanillaGreen Shell. Runtime name stays `vshell` because `vgs` conflicts with LVM `vgs`.

## Mission
- VGS owns shell runtime, default widgets, clipboard history (`wl-paste --watch` + VGS state), capture/recording UX, wallpapers, palette extraction, blueprints, app theme generation, and settings UI.
- Agents may modify `~/dotfiles` as needed. Dotfiles stay a personal wiring/overlay layer for hyper-specific customization; portable/default behavior belongs in VGS.
- No runtime dependency on legacy upstream shell daemons or external theme engines.
- Rollback means reinstalling/restoring another shell if needed; VGS does not keep a disabled rollback service as part of normal workstation wiring.
- Target is Hyprland + Quickshell 0.3.0 only.
- Prefer helpers/libraries over large QML business logic.

## Layout
| Path | Purpose |
|------|---------|
| `quickshell/vshell/` | Quickshell runtime: shell, services, modules, widgets |
| `config/vshell/` | Default seeds, dependency manifest, bundled plugins, shared plugin assets |
| `bin/vshell` | CLI wrapper for `qs`, IPC, service helpers, and helper dispatch |
| `bin/vshell-helper` | Python helper for theme engine and OS integrations |
| `bin/vshell-upscale` | One-shot local AI wallpaper upscaler (ncnn, no daemon; models cached outside the repo) |
| `backend/` | Go backend daemon: runner/supervisor, Unix-socket protocol, system services (network, logind, BlueZ, CUPS, …) |
| `themes/<name>/` | Built-in theme packages (`theme.json`, `colors.toml`, `backgrounds/`, curated `apps/`) |
| `themes/targets/` | App target templates and generation metadata |
| `systemd/user/vshell.service` | User service template |
| `docs/architecture/` | Short architecture references for agents |

## Architecture docs
| File | When to read |
|------|--------------|
| `docs/architecture/shell-architecture.md` | Touching QML runtime structure, entrypoints, IPC, plugins, external-command rules |
| `docs/architecture/theme-architecture.md` | Touching themes, palettes, wallpapers, generated app targets, preview machinery |
| `docs/architecture/overlay-and-dependencies.md` | Touching dependency gating, menu/webapp overlays, user-state vs repo boundaries |
| `docs/architecture/backend-daemon.md` | Touching `backend/`, the socket protocol, `VGSBackendService`, or capability gating |
| `docs/architecture/greeter-auto-login-keyring.md` | Touching greeter sync, auto-login, or keyring behavior |
| `docs/architecture/idle-lock-screensaver.md` | Touching the idle→lock→screensaver→blank-to-black flow, DPMS/suspend tiers, the idle inhibitor, or `IdleService` |
| `docs/architecture/display-brightness.md` | Touching `vshell brightness`, brightness backends (backlight/DDC/Apple HID), device identity, or the Apple udev rule |
| `docs/architecture/design-language.md` | Touching visual design: primitives in `Widgets/`, form tokens in `Common/Theme.qml`/`Appearance.qml`, or surface layout (radii, borders, motion, the "Flatline" shadcn/Vercel language) |
| `docs/architecture/wallpaper-upscaling.md` | Upscaling wallpapers to 6K with `bin/vshell-upscale` (one-shot local AI, model routing, cache, why no diffusion/daemon) |

## Project skills
| Skill | Path | Notes |
|-------|------|-------|
| VGS development | `.agents/skills/vshell-dev/SKILL.md` | Quickshell runtime, plugins, theme engine, generated targets, Go backend daemon |

## Documentation resources
Use CTX7 CLI when library/API docs are needed. Prefer pinned resource IDs over general web search.

| Topic | ctx7 ID | Notes |
|-------|---------|-------|
| Quickshell 0.3.0 | `/websites/quickshell_v0_3_0` | QML shell APIs, services, `Process`, `Quickshell`, singleton patterns, IPC |

## Live workstation wiring
Expected symlinks on this machine:
- `~/.config/quickshell/vshell` -> `~/dev/vgs/quickshell/vshell`
- `~/.local/bin/vshell` -> `~/dev/vgs/bin/vshell`
- `~/.config/vshell` is a real user-state directory, not a whole-directory repo symlink. Bundled plugins load from `~/dev/vgs/config/vshell/plugins`; user plugin overrides live in `~/.config/vshell/plugins`.

Service expectations:
- `vshell.service` active/enabled
- No legacy rollback shell service is expected to stay enabled or installed
- Hyprland/app reload hooks are helper-owned; no separate `vgs-hypr-reload.service` required
- With voxtype clipboard restoration enabled, the restored prior item is correctly newest in VGS history and the dictated text appears second.

Live-machine etiquette:
- This repo drives the live shell session; `systemctl --user restart vshell.service` disrupts it — ask first unless the user requested the restart.
- Never suspend the machine or destructively test Wi-Fi joins / Bluetooth pairing/removal as part of verification.

## Known upstream issues
- **Hyprland 0.56.0 native-Lua-config breaks `hyprctl binds -j`**: every bind registered via the Lua config's `__lua` dispatcher (this machine's `~/.config/hypr/hyprland.lua` uses Lua exclusively) serializes with unquoted bare identifiers (e.g. `"keycode": Q`, `"allow_input_capture": Close window`), producing invalid JSON. `bin/vshell-helper`'s `hypr_binds_json()` catches the parse failure and silently falls back to an empty bind list, so the keybinds cheatsheet popup (Super+/) opens with every category empty. Not a vshell regression — confirmed via `git blame` (parser unchanged since Jul 4/5) and upstream discussion [hyprwm/Hyprland#14255](https://github.com/hyprwm/Hyprland/discussions/14255). **Check each session whether a newer Hyprland release has fixed `hyprctl binds -j` JSON output for Lua-registered binds; once it has, remove this note** (and re-test the keybinds popup renders binds again).

## Theme rules
- Built-in theme packages live in `themes/<name>/`; user themes in `~/.config/vshell/themes/<name>/` (file-level overlay, user wins).
- Curated palettes (`source: curated`) pass through untouched; only generated palettes get contrast enforcement.
- Legacy v1 user blueprints in `~/.config/vshell/blueprints/` still load; convert with `vshell theme migrate`.
- Current generated shell state is `~/.config/vshell/theme.json`.
- Local machine overlays live outside the repo at `~/.config/vshell-local/`.
- QML reads theme state through `Common/MethodTheme.qml` and `Services/VGSThemeService.qml`.
- Heavy generation stays in `bin/vshell-helper`; QML shells out to `vshell theme ...`.
- Generated targets must write to VGS-named paths.

## Backend rules
- Every backend method must map to a documented capability in `docs/architecture/backend-methods.json`; `scripts/check-backend-inventory.py` enforces this on the Go and QML sides.
- QML gates features on advertised `capabilities`/`methods` (never raw `apiVersion` ordinals) and keeps a working fallback when the capability is absent.
- One owner per resource: never add a second watcher/daemon/poller for something the helper or QML already owns.
- Exec external tools with argv arrays; never log secrets or raw frame payloads.
- Verify backend changes against a scratch daemon (`VGS_BACKEND_SOCKET=/run/user/$UID/test.sock vshell backend serve`), not the live session socket; unix socket paths must stay short (sun_path limit).

## Conventions
- Commit style: `area: imperative summary` (e.g. `backend:`, `frontend:`, `docs:`, `theme:`), lowercase.

## Validation
Scope to the area touched (Go-only: inventory guard + go block; QML-only: naming, `qs` smoke, surfaces; helper: py_compile + helper checks); run the full suite for cross-cutting work:
```bash
scripts/check-naming.sh
node --check scripts/check-settings-migration.js
scripts/check-settings-migration.js
scripts/check-vshell-helper.py
scripts/check-brightness.py
scripts/check-backend-inventory.py
python3 -m py_compile bin/vshell-helper
bash -n bin/vshell
git diff --check
qs -c vshell
scripts/smoke-surfaces.sh
(cd backend && go build ./... && go vet ./... && go test -race ./...)
```
For `qs -c vshell`, timeout is acceptable for smoke; investigate QML errors, missing binaries, and process failures.

## Do not
- Do not introduce a `vgs` CLI binary.
- Do not depend on legacy upstream runtime services or external theme engines.
- Do not call `vgs` from VGS runtime paths.
- Do not reintroduce legacy upstream naming into runtime code, default config, generated paths, or docs outside attribution/license lineage.
- Do not move portable/default runtime behavior into dotfiles; edit VGS and use `~/dotfiles` only for wiring or hyper-specific overlays.
- Do not put privileged writes or large template renderers in QML.
