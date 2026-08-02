---
name: vshell-dev
description: >
  Work on VanillaGreen Shell (VGS / vshell), a Hyprland and Niri Quickshell 0.3.0 runtime.
  Use for shell modules, services, bundled plugins, theme engine targets, wallpaper/palette
  flows, IPC, settings UI, or removing stale legacy upstream assumptions.
compatibility: Designed for Claude Code, Pi, Codex, and similar agents
metadata:
  author: VanillaGreen
  version: "1.1"
  domain: qml-desktop-development
  framework: Quickshell
  languages: qml, javascript, python, bash
allowed-tools: Bash Read Write Edit
---

# VGS development

## Always know
- Runtime name is `vshell`; do not add a `vgs` CLI.
- VGS targets Hyprland or Niri + Quickshell 0.3.0 only.
- VGS owns themes, wallpapers, blueprints, generated app themes, and settings UI.
- Dotfiles only wire the workstation.
- No legacy upstream runtime dependency.
- No external theme-engine runtime dependency.
- Prefer helper code over heavy QML business logic.

## Load first when needed
- Shell overview: `docs/architecture/shell-architecture.md`
- Theme overview: `docs/architecture/theme-architecture.md`
- Backend daemon: `docs/architecture/backend-daemon.md`
- Runtime conventions: `AGENTS.md`
- Overlays/deps: `docs/architecture/overlay-and-dependencies.md`

## Docs source
Use CTX7 CLI for Quickshell API docs when unsure:

| Topic | ctx7 ID | Notes |
|-------|---------|-------|
| Quickshell 0.3.0 | `/websites/quickshell_v0_3_0` | `Process`, `Quickshell`, IPC, QML services, singleton behavior |

## Repo layout
```text
quickshell/vshell/        # QML runtime
config/vshell/            # default settings and bundled plugins
bin/vshell                # CLI wrapper
bin/vshell-helper         # Python helper and theme engine
backend/                  # Go backend daemon (runner/supervisor, socket, system services)
themes/<name>/            # built-in theme packages (theme.json, colors.toml, backgrounds/, apps/)
themes/targets/           # generated app-theme target templates
docs/architecture/        # short architecture docs
```

## Common tasks

### Shell/QML work
1. Read `docs/architecture/shell-architecture.md`.
2. Use existing services/modules/widgets before adding new structure.
3. For external commands, call `Paths.vshellCli`, not bare `vshell`.
4. Gate optional features through `vshell deps` or helper unavailable JSON.
5. Keep QML UI-focused. Move parsing/generation/privileged logic to helper.
6. Smoke with `scripts/qml-smoke.sh` — never `qs -c vshell` in a live session.

Reference: `references/qml-runtime.md`.

### Theme work
1. Read `docs/architecture/theme-architecture.md`.
2. Put built-in theme packages in `themes/<name>/` (user themes overlay from `~/.config/vshell/themes/`).
3. Put target templates in `themes/targets/<id>/`.
4. Implement role derivation/rendering in `bin/vshell-helper`.
5. Keep output paths VGS-named.
6. Validate `vshell theme apply tokyo-night`.

Reference: `references/theme-engine.md`.

### Bundled plugin work
1. Work under `config/vshell/plugins/<id>/`.
2. Keep plugin IDs stable.
3. Use VGS imports: `qs.Common`, `qs.Widgets`, `qs.Services`, `qs.Modules.Plugins` as existing code does.
4. Do not introduce `vgs` command calls.
5. Keep plugin UI on VGS theme tokens, not hardcoded colors/sizes.

Reference: `references/plugin-development.md`.

### Backend (Go daemon) work
1. Read `docs/architecture/backend-daemon.md`. The backend runs as a supervised
   `vshell-backend serve` child of the runner; QML talks to it over `VGS_SOCKET`
   via `Services/VGSBackendService.qml`.
2. Every registered method must map to a capability documented in
   `docs/architecture/backend-methods.json`; `scripts/check-backend-inventory.py`
   enforces this on both the Go and QML sides.
3. QML gates features on advertised `capabilities`/`methods`, never raw
   `apiVersion` numbers, and keeps a fallback when the capability is absent.
4. One owner per resource: do not add a second watcher/daemon for something the
   helper or QML already owns (e.g. clipboard watching stays with
   `vshell clipboard watch`; compositor output layout stays config-owned).
5. Debug with `vshell backend doctor|methods|request <method> [json]`; a scratch
   daemon runs with `VGS_BACKEND_SOCKET=/run/user/$UID/test.sock vshell backend serve`.
6. Never log secrets or frame payloads; exec external tools with argv arrays.

## Validation
Run relevant checks before final response:

```bash
scripts/check-naming.sh
node --check scripts/check-settings-migration.js
scripts/check-settings-migration.js
scripts/check-vshell-helper.py
scripts/check-backend-inventory.py
python3 -m py_compile bin/vshell-helper
bash -n bin/vshell
git diff --check
```

For backend changes:

```bash
(cd backend && go build ./... && go vet ./... && go test -race ./...)
```

For runtime changes:

```bash
scripts/qml-smoke.sh              # static QML parse check, always safe
scripts/qml-smoke.sh --nested     # + real shell in an isolated nested compositor
scripts/check-validation-safety.sh
```

QML errors, missing binary warnings, and process start failures are not fine.

**Never** run `qs -c vshell` or `qs -p quickshell/vshell` in a live session: that
starts a second full VGS instance, which fights the session shell for
WlSessionLock, the fade-to-lock overlay, and the idle/DPMS tiers, and leaves
orphaned full-screen layer surfaces behind (cursors over black, recoverable only
with `vshell ipc call lock forceReset`). Never `pkill quickshell` either — other
Quickshell applications on the seat are legitimate. Use `vshell instances list`
to see live VGS shells and `vshell logs -n 200` for the running shell's QML
errors.

For theme changes:

```bash
vshell theme list --json
vshell theme apply tokyo-night --json
```

## Red flags
- `vgs` command in QML runtime.
- Personal command required by default widget startup.
- Legacy external theme path in generated target.
- `qrc:/qs-blackhole/bin/vshell` used as process command.
- Bare `vshell` command inside QML.
- QML parsing TOML/JSON formats that helper should parse.
- Theme target writes to a legacy external path.
