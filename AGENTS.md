# AGENTS.md

Reviewing a PR as a review bot? Follow `review-bots.md` (repo root) — reviewer context stays there, not here.

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
| `docs/architecture/notification-ownership.md` | Touching notifications: the `org.freedesktop.Notifications` registration, `vshell notifications`, conflicting daemons, or the packaging conflict |
| `docs/architecture/idle-lock-screensaver.md` | Touching the idle→lock→screensaver→blank-to-black flow, DPMS/suspend tiers, the idle inhibitor, or `IdleService` |
| `docs/architecture/display-brightness.md` | Touching `vshell brightness`, brightness backends (backlight/DDC/Apple HID), device identity, or the Apple udev rule |
| `docs/architecture/design-language.md` | Touching visual design: primitives in `Widgets/`, form tokens in `Common/Theme.qml`/`Appearance.qml`, or surface layout (radii, borders, motion, the "Flatline" shadcn/Vercel language) |
| `docs/architecture/wallpaper-upscaling.md` | Upscaling wallpapers to 6K with `bin/vshell-upscale` (one-shot local AI, model routing, cache, why no diffusion/daemon) |
| `docs/architecture/remote-desktop.md` | Touching the Sunshine remote-desktop host: `vshell remote-desktop`, the virtual-output lifecycle, the streaming-vs-listening indicator, or the `remoteDesktop` plugin |
| `docs/architecture/cloud-sync.md` | Touching cloud file sync: the supervised `rclone rcd` process, accounts/OAuth, sync modes and safety rails, the inotify watcher, FUSE mounts, or the Cloud Sync app/widget |
| `docs/architecture/scratchpads.md` | Touching scratchpads: the `scratchpads` setting, percentage sizing and anchors, the generated `hypr/vgs/scratchpads.lua`, `vshell scratchpad ...`, or the reveal-time re-assert |

## Project skills
| Skill | Path | Notes |
|-------|------|-------|
| VGS development | `project-skills/vshell-dev/SKILL.md` | Quickshell runtime, plugins, theme engine, generated targets, Go backend daemon |

Tracked project skills live in `project-skills/`, never under `.agents/skills/`
— that mirror is untracked and symlinked wholesale into every worktree, so a
tracked file there is unwritable by git while `git status` looks clean.
`vstack refresh` links each `project-skills/<name>` into `.agents/skills/<name>`
for discovery. See `project-skills/README.md`.

The vstack `review-gate` engine needs a **tracked** copy, because CI runs its
predicate from a plain checkout with no vstack and no mirror — and for the
reason above it cannot be tracked under `.agents/skills/`, so VGS vendors it
at `third_party/review-gate/` while `vstack refresh` keeps updating
`.agents/skills/review-gate` for agent discovery.
`scripts/check-review-gate-vendor.sh` fails when the two drift, so a refresh
that changes the engine cannot be forgotten.

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
  is intake-only, and nothing syncs back. File and work issues in Linear; dedupe
  across both before creating one.
- **Mirroring GitHub intake into Linear is a manual triage step — no automation
  does it.** There is no sync workflow under `.github/` and no Linear-side GitHub
  integration creating issues, so an unmirrored GitHub issue is invisible to the
  canonical tracker and can sit unseen indefinitely. Run the triage pass when
  picking up work — list both sides, then mirror anything GitHub-only:
  ```bash
  gh issue list --state open --limit 50 --json number,title,url,createdAt \
    --jq '.[] | [.number, .createdAt, .url, .title] | @tsv'
  .agents/skills/linear/scripts/linear.sh cache issues list --all-projects

  # Per GitHub-only issue: title, body and url in one fetch, then the
  # description — full body plus the provenance line back to GitHub.
  gh issue view <n> --json title,body,url > /tmp/gh-<n>.json
  jq -r '(.body | sub("\\s+$"; "")) + "\n\n---\n\nMirrored from GitHub issue [" + .url + "](<" + .url + ">) (intake-only tracker)."' /tmp/gh-<n>.json > /tmp/gh-<n>-body.md

  .agents/skills/linear/scripts/linear.sh issues create --title "$(jq -r .title /tmp/gh-<n>.json)" \
    --description-file /tmp/gh-<n>-body.md
  ```
  The list query carries `url` so the triage table is actionable; `body` is
  fetched per issue rather than for all 50, and every field the description
  needs comes from these commands alone. Then work the Linear issue, not the
  GitHub one. Automating this needs owner action — see
  `docs/decisions/D002-github-linear-intake-sync.md`.
- Branch names carry the issue: `vgs-<n>-<slug>`. That is what Linear's GitHub
  integration matches to attach the PR, and what `GH_ISSUE_PATTERN` reads.
- Commit style: `area: imperative summary` (e.g. `backend:`, `frontend:`, `docs:`,
  `theme:`), lowercase. When the work has a Linear issue, put the identifier in
  the scope: `area(VGS-12): imperative summary`.
- Releases use `.agents/skills/vgs-release/SKILL.md`. Every release updates and verifies all maintained install channels; unavailable channels must be named, never silently skipped.
- Session handoff lives only at `docs/handoff/HANDOFF.md` (gitignored) — exactly one file,
  overwritten in place, pruned to live context with no history or prose; Linear remains the
  source of truth for pending work. Read or write it only on request, or when resuming from one.

## Validation
The suite is `scripts/validate [AREA]` — areas `go`, `qml`, `helper`,
`packaging`, `docs`, `all`. Scope to the area you touched; run `all` for
cross-cutting work. The command manifest and the per-area scoping live in that
runner's header, and `scripts/check-validation-inventory.py` enforces it against
CI and `scripts/` in both directions (VGS-50, VGS-30).

**Exit 77 is not a pass.** The status is four-valued: `0` everything selected
ran and passed; `77` what ran passed but something did NOT run — report it as
"passed, N skipped", naming each skipped command from the summary, never as a
bare pass; `1` a real failure; `2` a broken invocation (bad area or malformed
manifest) where NOTHING ran, so it is neither a pass nor a validation failure —
fix the invocation and re-run. (Agents running under orch record that skip in
`dev-return-write --validate-note`, which is orch's tool, not this repo's.)

A green CI run does not prove the shell starts. Run the qml area before
finishing QML work — most agent shells have no `WAYLAND_DISPLAY`, and the nested
smoke is `--require-nested`, so point it at the session socket (the sandbox
keeps its own runtime dir, HOME and bus, so the live session is untouched):

```bash
WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/$(id -u) scripts/validate qml
```

Never read `smoke-surfaces.sh`'s refusal as a pass (VGS-69). Which checks CI
cannot run, and why, is in
`.github/instructions/validation-scripts.instructions.md` § "What CI covers,
and what it cannot".

### Review gate

Merges gate on AI-review evidence via the vstack `review-gate` engine, vendored
at `third_party/review-gate/`. The engine posts one commit status —
`Review gate` — on the PR head: `pending` while no review evidence exists for
that exact head or while threads are unresolved, `failure` on
changes-requested, `success` only from an evidence-backed evaluation.

Two moving parts (the v2 single-writer architecture, cutover 2026-08-08):

| Piece | Role |
|-------|------|
| `.github/workflows/review-gate-writer.yml` | The ONLY writer of the gate status, in a relay/converge shape (VST-210). PR-attached legs — PR pushes, review events, status events — only *request* a converge pass and exit; they run no engine. The converge legs (`workflow_dispatch`, the 15-minute cron floor for transitions with no webhook) run the **default-branch** engine and converge every open PR per run. Merge-group entries post an unconditional success on their own job, and the fork read-only leg is a no-op the cron floor covers. Relaying is what keeps an evicted run off a PR's checks: converge runs attach to the default branch, so a burst's cancellation marks land on merged `main` commits instead of pinning open PRs at `UNSTABLE`. A PR can never influence its own gate evaluation. |
| `ci.yml` § `review-gate-selftest` | Pins the engine's decision table offline against VGS's own trust values, and runs the writer and writer-template suites — the latter checks THIS repo's adopted `review-gate-writer.yml`, not only the catalog template, so topology drift cannot pass unseen. Ungated but **blocking**: `ci-ok` takes `needs:` on it, so a PR that breaks the predicate cannot merge with its own selftest red (rationale in the workflow's comments). |

Because the writer always runs the merged engine, a PR that repairs the gate
machinery itself can never open its own gate — the ruleset's bypass actor is
the sanctioned merge path for gate-repair-class PRs (state it in the merge
commit).

Per-repo trust lives in `vstack.settings.toml` under `REVIEW_GATE_*`. Every
key carries its VGS rationale in the comment above it, and that file is the
single source: when gate trust or behavior changes, edit the key and its
comment there — do not restate rationale here. Working posture since the
cutover:

- Evidence is review objects at the exact head from the trusted logins
  (`REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` — populated, non-optional on
  this public repo), at any non-dismissed state, plus the trusted
  check/status contexts (`REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` — populated at
  the cutover, superseding the earlier empty-list posture; skip patterns
  route "rate limited"/"skipped"/"queued" passes to not-evidence). No
  comment-form reviewer is configured.
- The reviewers actually reviewing are Copilot, qodo, and Codex. CodeRabbit
  has been disabled org-wide since 2026-08-08; its trust entries remain
  (fleet-identical config, pruned fleet-wide only) but are inert until it
  returns.
- The operator override (`REVIEW_GATE_OVERRIDE_CONTEXT`) is manual-only: an
  operator posts it on genuine total reviewer silence; orch never does.
- Docs-only pushes carry an ancestor's trusted review object forward (review
  objects only — trusted check/status evidence never carries), except
  policy-bearing paths (`AGENTS.md`/`CLAUDE.md`, `.github/*`,
  `review-bots.md`, vendored engine and skill trees), which always get fresh
  review (`REVIEW_GATE_CARRY_FORWARD` / `_EXCLUDE`).

Risk classes and the regression-test expectation: `review-bots.md`.

CodeRabbit's own config is checked too: an invalid `.coderabbit.yaml` makes
CodeRabbit silently review with **default** settings, which once left the whole
file inert on every PR, so `scripts/check-coderabbit-config.py` validates it
against CodeRabbit's own schema, vendored at `third_party/coderabbit-schema/`
so the check is offline.

### Never launch a second shell into the live session
Never run `qs -c vshell` or `qs -p quickshell/vshell`: each starts a **full second
VGS instance**, which fights the session shell for session-global resources
(WlSessionLock, the fade-to-lock overlay, idle/DPMS tiers) and leaves orphaned
full-screen layer surfaces behind — the session ends up as cursors over black,
recoverable only with `vshell ipc call lock forceReset`. Never `pkill quickshell`
either: other Quickshell applications on the seat are legitimate.

- `scripts/qml-smoke.sh` is the canonical QML smoke; its own header documents
  what each mode covers. Bare is a **parse** check only. `--nested` runs the
  real shell inside an isolated nested compositor sandbox, fails on runtime QML
  errors, and drives the popout and bundled-override paths loading alone never
  reaches — it is the mode that replaces what `qs -c vshell` used to cover, so
  use it for QML work. Pass `--require-static` / `--require-nested` in any
  automated run so a missing tool fails instead of skipping — a plain skip is
  otherwise indistinguishable from a pass.
- Most agent environments have no `WAYLAND_DISPLAY`, and `--nested` refuses to
  build a sandbox without a host socket to nest inside. Point it at the
  session's own socket and it runs — the sandbox still has its own runtime
  dir, HOME and bus, so the live session is untouched:
  ```bash
  WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=/run/user/$(id -u) \
    scripts/qml-smoke.sh --nested --require-static --require-nested
  ```
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
