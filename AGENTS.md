# AGENTS.md

Review-bot context is `review-bots.md`, not here.

VGS = VanillaGreen Shell. Runtime name stays `vshell`: `vgs` collides with LVM.

## Mission
- VGS owns the shell runtime, widgets, clipboard history, capture/recording,
  wallpapers, palettes, blueprints, app theme generation, and settings UI.
- `~/dotfiles` is a personal wiring/overlay layer, editable as needed; portable
  and default behavior belongs in VGS.
- Rollback means reinstalling another shell; VGS keeps no disabled rollback
  service.
- Hyprland or Niri + Quickshell 0.3.0 only; Hyprland is the reference
  implementation and Niri support must be additive.

## Where the rest lives
- `docs/architecture/` — one reference per subsystem; read the one you touch.
- `.github/instructions/*.instructions.md` — path-scoped rules (CI, scripts,
  vendored trees). `kendex.settings.toml` — review-gate trust,
  every key with its rationale. `docs/decisions/INDEX.md` — decisions.
- `.agents/skills/` — the skills; `kendex.toml` names ours.
- `AGENTS.local.md` — this machine's wiring; untracked, absent on a fresh clone.

## Theme rules
- Built-in packages live in `themes/<name>/`; `~/.config/vshell/themes/<name>/` overlays them per file (user wins); machine-local overlays live outside the repo in `~/.config/vshell-local/`.
- Curated palettes (`source: curated`) pass through untouched; only generated ones get contrast enforcement.
- Heavy generation stays in `bin/vshell-helper`; QML shells out to `vshell theme ...`.
- Generated targets must write to VGS-named paths.

## Backend rules
- Every method must map to a documented capability in `docs/architecture/backend-methods.json`; `scripts/check-backend-inventory.py` enforces it.
- QML gates on advertised `capabilities`/`methods`, never raw `apiVersion` ordinals, and keeps a working fallback when one is absent.
- One owner per resource: never add a second watcher/daemon/poller for something the helper or QML already owns.
- Exec external tools with argv arrays; never log secrets or raw frame payloads.
- Verify against a scratch daemon (`VGS_BACKEND_SOCKET=/run/user/$UID/test.sock vshell backend serve`), never the live socket; keep socket paths short (sun_path).

## Validation
`scripts/validate [AREA]` — <!-- validate-areas -->areas `go`, `qml`, `helper`,
`packaging`, `docs`, `all`<!-- /validate-areas -->. Scope to what you touched; that
runner's header is the manifest. **Exit 77 is not a pass.**

## Never launch a second shell into the live session
Never run `qs -c vshell` or `qs -p quickshell/vshell`: each starts a **full
second VGS instance** that fights the session shell for session-global resources
and strands orphaned layer surfaces — the session ends up as cursors
over black, recoverable only with `vshell ipc call lock forceReset`. Never
`pkill quickshell` either: other Quickshell apps on the seat are legitimate.
`scripts/validate qml` is the sanctioned smoke.

## Conventions
- Tracker: **Linear** (team `vg-shell`, `VGS-<n>`). GitHub Issues is
  intake-only and nothing syncs back; mirroring into Linear is MANUAL —
  commands in the linear skill's instructions (`kendex.toml`), rationale in
  `docs/decisions/D002-github-linear-intake-sync.md`.
- Branch `vgs-<n>-<slug>` — attaches the PR to Linear; `GH_ISSUE_PATTERN` reads it.
- Commits `area: imperative summary`, lowercase; `area(VGS-12): ...` with an issue.
- Releases follow `.agents/skills/vgs-release/SKILL.md` and verify every
  maintained install channel; one that cannot be is named in the release notes,
  never silently skipped.
- Session handoff is only `docs/handoff/HANDOFF.md` (gitignored), overwritten in
  place; Linear stays the source of truth. Read or write on request only.

## Do not
- Do not introduce a `vgs` CLI binary, or call `vgs` from VGS runtime paths.
- Do not depend on legacy upstream runtime services or external theme engines,
  or reintroduce legacy upstream naming into runtime code, config, generated
  paths, or docs outside attribution/license lineage.
- Do not move portable/default behavior into dotfiles; `~/dotfiles` is for
  wiring and hyper-specific overlays only.
- Do not put privileged writes or large template renderers in QML — prefer
  helpers and libraries.
- Do not restart `vshell.service` unless asked — this repo drives the live
  session.
- Do not suspend the machine or destructively test Wi-Fi joins or Bluetooth
  pairing/removal to verify.
