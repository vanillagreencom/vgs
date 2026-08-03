# AGENTS.md

VGS = VanillaGreen Shell. Runtime name stays `vshell` because `vgs` conflicts with LVM `vgs`.

## Mission
- VGS owns shell runtime, default widgets, clipboard history (`wl-paste --watch` + VGS state), capture/recording UX, wallpapers, palette extraction, blueprints, app theme generation, and settings UI.
- Agents may modify `~/dotfiles` as needed. Dotfiles stay a personal wiring/overlay layer for hyper-specific customization; portable/default behavior belongs in VGS.
- No runtime dependency on legacy upstream shell daemons or external theme engines.
- Rollback means reinstalling/restoring another shell if needed; VGS does not keep a disabled rollback service as part of normal workstation wiring.
- Target is Hyprland or Niri + Quickshell 0.3.0 only. Hyprland remains the
  reference implementation and Niri support must be additive.
- Prefer helpers/libraries over large QML business logic.

## Layout
| Path | Purpose |
|------|---------|
| `quickshell/vshell/` | Quickshell runtime: shell, services, modules, widgets |
| `config/vshell/` | Default seeds, dependency manifest, bundled plugins, shared plugin assets |
| `bin/vshell` | CLI wrapper for `qs`, IPC, service helpers, and helper dispatch |
| `bin/vshell-helper`, `bin/vshell_niri.py` | Python helper CLI plus the isolated Niri/KDL config subsystem |
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
| `docs/architecture/cloud-sync.md` | Touching cloud file sync: the supervised `rclone rcd` process, accounts/OAuth, sync modes and safety rails, the inotify watcher, FUSE mounts, or the Cloud Sync app/widget |

## Project skills
| Skill | Path | Notes |
|-------|------|-------|
| VGS development | `project-skills/vshell-dev/SKILL.md` | Quickshell runtime, plugins, theme engine, generated targets, Go backend daemon |

Tracked project skills live in `project-skills/`, never under `.agents/skills/`
— that mirror is untracked and symlinked wholesale into every worktree, so a
tracked file there is unwritable by git while `git status` looks clean.
`vstack refresh` links each `project-skills/<name>` into `.agents/skills/<name>`
for discovery. See `project-skills/README.md`.

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
- Issue tracker: **Linear** (team `vg-shell`, identifiers `VGS-<n>`). GitHub Issues
  is intake-only — a one-way GitHub → Linear sync mirrors it, nothing syncs back.
  File and work issues in Linear; dedupe across both before creating one.
- Branch names carry the issue: `vgs-<n>-<slug>`. That is what Linear's GitHub
  integration matches to attach the PR, and what `GH_ISSUE_PATTERN` reads.
- Commit style: `area: imperative summary` (e.g. `backend:`, `frontend:`, `docs:`,
  `theme:`), lowercase. When the work has a Linear issue, put the identifier in
  the scope: `area(VGS-12): imperative summary`.
- Releases use `.agents/skills/vgs-release/SKILL.md`. Every release updates and verifies all maintained install channels; unavailable channels must be named, never silently skipped.

## Validation
Scope to the area touched (Go-only: inventory guard + go block; QML-only: naming, QML smoke, surfaces; helper: py_compile + helper checks; packaging: the two packaging checks); run the full suite for cross-cutting work:
```bash
scripts/check-naming.sh
scripts/gen-package-metadata.py
scripts/check-package-assets.sh
node --check scripts/check-settings-migration.js
scripts/check-settings-migration.js
node scripts/test-restyle-queue.js
node scripts/test-theme-requests.js
node scripts/test-latest-transaction-queue.js
scripts/check-vshell-helper.py
scripts/check-brightness.py
scripts/check-backend-inventory.py
python3 -m py_compile bin/vshell-helper
bash -n bin/vshell
git diff --check
scripts/qml-smoke.sh --nested --require-static
scripts/check-validation-safety.sh
scripts/smoke-surfaces.sh
(cd backend && go build ./... && go vet ./... && go test -race ./...)
```

### What CI covers, and what it cannot

`.github/workflows/ci.yml` runs this suite on every pull request, on
merge-queue entries, and on `main` pushes.

**Branch protection and the merge queue should require `CI / ci-ok` alone.**
That is the workflow's one job — named for the required context rather than for
what it does, which is the indirection a separate aggregator job would have
bought. There are no conditional lanes that could leave a required context
permanently skipped, so there is nothing to aggregate; if lanes are ever added,
the work moves to new jobs and `ci-ok` becomes the aggregator over them, and
branch protection never has to change.

One job is also the cheap shape here. Measured on this repo: the static suite is
~16s of work, and the Go block is ~6s warm / ~16s cold (build 4.4s, vet 0.8s,
`test -race` 11.0s). At ~30s of total compute, per-job overhead — runner
acquisition, checkout, toolchain setup — dominates, so splitting into lanes
would multiply billed minutes to save seconds, and a change-detection job to
gate those lanes would cost more than the work it could skip. The sibling repos
(hyprtrade, memsira, drovr) split because their lanes run for minutes; that
economics does not transfer. Revisit if any step crosses ~5 minutes. There is no
nightly split for the same reason.

Go caching is deliberately **off**. A cold Go run downloads 13 MB of modules but
leaves a 296 MB `GOCACHE`; saving and restoring that to skip ~10s of compute is
a net loss on a 2 vCPU runner. Re-measure before enabling it.

The runner resolves through the shared `CI_RUNNER_2V` repository variable
(Blacksmith when set, `ubuntu-latest` when unset — that fallback is supported
and must keep working). Nothing here is CPU-bound or disk-hungry, so the 4V/8V
tiers buy VGS nothing.

Two checks in the list above **cannot run in CI** and stay local-only. Their
absence is deliberate, not an oversight:

| Check | Why it is local-only |
|-------|----------------------|
| `scripts/qml-smoke.sh --nested` | Its sandbox needs both Hyprland and `quickshell` on PATH (`scripts/qml-smoke.sh::nested_check`); neither is reasonably installable on a CI runner. CI runs the static half instead, via `scripts/check-validation-safety.sh --require-static`, which forwards the flag to the smoke. Quickshell is not needed for that half — the static check tolerates unresolved `qs.*` imports by design and fails only on `[syntax…]` findings. |
| `scripts/smoke-surfaces.sh` | Needs a **live** Hyprland VGS session and reads `hyprctl layers`. Anywhere else it prints a skip and exits 0, so running it in CI would manufacture a false green. |

The live-session half of `scripts/check-validation-safety.sh` is likewise
inert in CI: with no compositor and no Quickshell CLI its snapshots report
"nothing of that kind exists on this system" and pass. The repo-wide
unsafe-launch instruction scan — the other half — runs in full.

So a green PR proves the static suite and the Go block. It does **not** prove
the shell starts or that its surfaces are sane. Run
`scripts/qml-smoke.sh --nested --require-static` and
`scripts/smoke-surfaces.sh` locally before finishing QML work.

`--require-static` is passed in CI so a missing qmllint **fails** rather than
skipping: a silent skip is indistinguishable from a pass.

One other local/CI difference: the bare `git diff --check` above is a
working-tree check, so on a clean CI checkout it would inspect nothing. CI runs
`git diff --check "$BASE_SHA...HEAD"` over the pull request range instead,
which is why the job checks out with `fetch-depth: 0`.

### Never launch a second shell into the live session
Never run `qs -c vshell` or `qs -p quickshell/vshell`: each starts a **full second
VGS instance**, which fights the session shell for session-global resources
(WlSessionLock, the fade-to-lock overlay, idle/DPMS tiers) and leaves orphaned
full-screen layer surfaces behind — the session ends up as cursors over black,
recoverable only with `vshell ipc call lock forceReset`. Never `pkill quickshell`
either: other Quickshell applications on the seat are legitimate.

- `scripts/qml-smoke.sh` is the canonical QML smoke. Know what each mode covers:
  - bare — a **parse** check only (`qmllint`, syntax errors). It does not catch
    unresolved `qs.*` imports, missing properties, or failed process starts.
  - `--nested` — runs the real shell inside an isolated nested compositor (own
    runtime dir, own HOME, private bus, no live backend socket, no live
    compositor IPC), with process-group-scoped cleanup, and fails on runtime QML
    errors. **This is the mode that replaces what `qs -c vshell` used to cover**,
    so use it for QML work.
  - `--require-static` / `--require-nested` — fail instead of skipping when a
    check's tooling is unavailable. Use them in any automated run; a plain skip
    is otherwise indistinguishable from a pass.
- `scripts/check-validation-safety.sh` proves validation left no extra VGS
  Quickshell instances or layer surfaces, and blocks unsafe launch instructions
  from returning to the docs.
- `vshell instances list` shows live VGS shells; a duplicate started by hand is
  refused at runtime by the guard in `quickshell/vshell/shell.qml`.
- To read runtime QML errors from the shell that is already running:
  `vshell logs -n 200`.

## Do not
- Do not introduce a `vgs` CLI binary.
- Do not depend on legacy upstream runtime services or external theme engines.
- Do not call `vgs` from VGS runtime paths.
- Do not reintroduce legacy upstream naming into runtime code, default config, generated paths, or docs outside attribution/license lineage.
- Do not move portable/default runtime behavior into dotfiles; edit VGS and use `~/dotfiles` only for wiring or hyper-specific overlays.
- Do not put privileged writes or large template renderers in QML.
