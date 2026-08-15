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
Mission, ownership boundaries, runtime naming (`vshell`, never a `vgs` CLI), and
the hard "do not" list are canonical in `AGENTS.md` (§ Mission, § Do not) — this
skill assumes them rather than restating them.

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
1. Read `docs/architecture/backend-daemon.md` (process model, protocol,
   security, reliability) and follow AGENTS.md § Backend rules — capability
   mapping and gating, one owner per resource, argv exec, no secrets in logs,
   scratch-daemon verification.
2. Debug with `vshell backend doctor|methods|request <method> [json]`.

## Validation
The suite is `scripts/validate [AREA]`, <!-- validate-areas -->areas `go`, `qml`, `helper`,
`packaging`, `docs`, `all`<!-- /validate-areas --> — run the area for what you touched. (Keep the
validate-areas markers: the inventory guard reads between them. Contract in
`.github/instructions/validation-scripts.instructions.md`.) The command
manifest and its per-area scoping live in that runner; no command list is
restated here, because a partial copy reads as complete. Its exit status is
four-valued: `0` ran and passed, `77` passed but something did not run — report
it as "passed, N skipped", naming them, never as a bare pass — `1` failed, `2` a
broken invocation that ran nothing.
The second-shell rule (never `qs -c vshell` or `qs -p quickshell/vshell`
against a live session, never `pkill quickshell`) and its recovery are under
AGENTS.md § Never launch a second shell into the live session. Smoke-mode
coverage is in `scripts/qml-smoke.sh`'s own header, and the sandbox recipe is
what that script prints when it cannot nest.

For theme changes (skill-unique; not part of the canonical list):

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
