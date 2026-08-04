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
| `docs/architecture/notification-ownership.md` | Touching notifications: the `org.freedesktop.Notifications` registration, `vshell notifications`, conflicting daemons, or the packaging conflict |
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

The vstack `review-gate` engine needs a **tracked** copy, because CI runs its
predicate from a plain checkout with no vstack and no mirror. The sibling repos
track it at `.agents/skills/review-gate/`; VGS cannot, for the reason above —
git cannot stat through the symlinked directory, so those files report as
deleted in every worktree and the tree is permanently dirty. VGS therefore
vendors it at `third_party/review-gate/`, and `vstack refresh` keeps updating
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
Scope to the area touched (Go-only: inventory guard + go block; QML-only: naming, QML smoke, surfaces; helper: py_compile + helper checks; packaging: the three packaging checks); run the full suite for cross-cutting work:
```bash
scripts/check-naming.sh
python3 scripts/lib/shell_scan.py
scripts/check-validation-inventory.py
scripts/gen-package-metadata.py
scripts/check-package-assets.sh
scripts/check-aur-sync.py
scripts/check-command-declarations.py
node --check scripts/check-settings-migration.js
scripts/check-settings-migration.js
scripts/test-restyle-queue.js
scripts/test-theme-requests.js
scripts/test-sudo-toggle-confirm.js
scripts/test-latest-transaction-queue.js
scripts/test-bundled-override.js
scripts/test-idle-reload-snapshot.js
scripts/test-idle-lock-request.js
scripts/check-vshell-helper.py
scripts/check-brightness.py
scripts/check-backend-inventory.py
scripts/check-backend-inventory-tests.py
scripts/check-lock-reload-order.py
scripts/check-display-config-fixtures.js
scripts/check-vgs-menu-capabilities.js
scripts/check-vshell-ipc.sh
scripts/test-pill-hover-safety.js
python3 -m py_compile bin/vshell-helper
bash -n bin/vshell
git diff --check
scripts/check-workflows.sh
scripts/check-coderabbit-config.py
scripts/check-review-gate-vendor.sh
scripts/test-review-gate-step.sh
third_party/review-gate/scripts/review-predicate-selftest.sh
scripts/qml-smoke.sh --nested --require-static
scripts/check-validation-safety.sh
scripts/check-label-taxonomy.py
scripts/smoke-surfaces.sh
(cd backend && go build ./... && go vet ./... && go test -race ./...)
```

Every script above is invoked bare, and every one of them carries the
executable bit — a `node`/`bash`/`python3` prefix the doc omitted is what made
the suite fail for anyone following it literally (VGS-30).
`scripts/lib/session-snapshot.sh` stays non-executable on purpose: it is
sourced, never run. `bin/vshell_niri.py`, `bin/vshell_niri_kdl.py` and
`bin/vshell_theme_color.py` likewise — they are importable modules with no
shebang and no `__main__`.

`scripts/check-validation-inventory.py` is what keeps this list honest in both
directions: every executable check under `scripts/` must appear here and in CI
or carry a written exclusion, and every command here must run exactly as
written. Four checks sat committed and never invoked by anything before it
existed (VGS-50).

### What CI covers, and what it cannot

`.github/workflows/ci.yml` runs this suite on every pull request, on
merge-queue entries, and on `main` pushes.

**The merge queue requires `CI / ci-ok`.** That is the workflow's one *suite*
job — named for the required context rather than for what it does, which is the
indirection a separate aggregator job would have bought. There are no
conditional lanes that could leave a required context permanently skipped, so
there is nothing to aggregate; if lanes are ever added, the work moves to new
jobs and `ci-ok` becomes the aggregator over them, and branch protection never
has to change.

`Review gate` is intended as the second required context, but it is **not one
yet**: it is added to the merge queue's required checks only after the gate has
been observed publishing on a real PR, because requiring a context nothing
produces would block every merge. That step is a GitHub ruleset change, not
code. See § Review gate.

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

Three checks in the list above **cannot run in CI** and stay local-only. Their
absence is deliberate, not an oversight, and
`scripts/check-validation-inventory.py` holds the machine-readable copy of this
table so the two cannot disagree silently:

| Check | Why it is local-only |
|-------|----------------------|
| `scripts/check-label-taxonomy.py` | Compares `vstack.toml`'s label taxonomy against live Linear; CI has no Linear credentials and no local cache. It FAILS rather than skipping when the inventory is unreachable — `--allow-missing-inventory` is the explicit "I accept the sweep did not happen". |
| `scripts/qml-smoke.sh --nested` | Its sandbox needs both Hyprland and `quickshell` on PATH (`scripts/qml-smoke.sh::nested_check`); neither is reasonably installable on a CI runner. CI runs the static half instead, via `scripts/check-validation-safety.sh --require-static`, which forwards the flag to the smoke. Quickshell is not needed for that half — the static check tolerates unresolved `qs.*` imports by design and fails only on `[syntax…]` findings. |
| `scripts/smoke-surfaces.sh` | Needs a **live** Hyprland VGS session and reads `hyprctl layers`. Anywhere else it prints a skip and exits 0, so running it in CI would manufacture a false green. |

The live-session half of `scripts/check-validation-safety.sh` is likewise
inert in CI: with no compositor and no Quickshell CLI its snapshots report
"nothing of that kind exists on this system" and pass. The repo-wide
unsafe-launch instruction scan — the other half — runs in full.

`scripts/check-aur-sync.py` runs on every PR, but only its offline half:
PKGBUILD against `.SRCINFO` inside this repo. Comparing against what
aur.archlinux.org actually publishes needs network and is owned by
`.github/workflows/publish-aur.yml` — which pushes `packaging/arch/` to the AUR
and re-checks afterwards, plus a weekly drift run. A PR is never made red by an
AUR-side problem it cannot fix, and the offline run prints what it did **not**
check rather than implying the published package was verified. Run
`scripts/check-aur-sync.py --remote` by hand when you want that answer now.

So a green PR proves the static suite and the Go block. It does **not** prove
the shell starts or that its surfaces are sane. Run
`scripts/qml-smoke.sh --nested --require-static` and
`scripts/smoke-surfaces.sh` locally before finishing QML work.

### Review gate

Merges gate on AI-review evidence via the vstack `review-gate` engine, vendored
at `third_party/review-gate/`. The engine posts one commit status —
`Review gate` — on the PR head: `pending` while no review evidence exists for
that exact head or while threads are unresolved, `failure` on
changes-requested, `success` only from an evidence-backed evaluation.

Three moving parts:

| Piece | Role |
|-------|------|
| `ci.yml` § `review-gate` | Evaluates the predicate from the **base** revision with a read-only checkout and posts the status. Latency optimization. |
| `ci.yml` § `review-gate-selftest` | Ungated, no `needs`: pins the engine's decision table offline, and `scripts/test-review-gate-step.sh` pins the CI step that consumes it. A broken predicate approves nothing, so a gated selftest could never run when it matters. |
| `approval-rerun.yml` / `approval-sweep.yml` | The convergence writers of record — non-PR triggers, default-branch checkout. The sweep every 15 minutes is what catches thread resolution, which has no Actions trigger at all. |

`ci-ok` deliberately does **not** wait on the gate. The engine's default shape
skips heavy jobs until review lands, which pays off for lanes that run for
minutes; VGS's whole suite is ~30s, so gating it would only delay the author's
first signal. The gate blocks the merge, not the compute.

The gate job checks out the **base** revision, never the PR head — the safe
posture never runs PR-controlled predicate code under a token that can post the
status which opens the gate. The permanent consequence is that a base without
the engine (the adoption PR; a PR branched before the vendor commit; a deleted
or renamed vendor tree) cannot be evaluated. That case posts `pending` with the
reason and exits 0: merge stays blocked, which is correct for a head with no
evaluated evidence. It is never `failure` — that means "changes requested", a
false verdict — and never a crash, which posts nothing and so neither blocks nor
informs. `scripts/test-review-gate-step.sh` drives the step, extracted from the
shipped YAML, over all of those states.

Per-repo trust lives in `vstack.settings.toml` under `REVIEW_GATE_*`, each key
carrying the reason for its VGS value. Two are worth knowing: no check-run or
commit status is trusted as evidence (CodeRabbit reported `success` with
"Review rate limited" on PR #38 — a pass proving nothing ran), and no
comment-form reviewer is configured.

CodeRabbit's own config is checked too. `.coderabbit.yaml` shipped a
376-character `tone_instructions` against a documented 250-character limit;
CodeRabbit rejects an invalid config, reviews with **default** settings, and
says so nowhere a PR can see — so the whole file was inert on every PR.
`scripts/check-coderabbit-config.py` validates it against CodeRabbit's own
schema, vendored at `third_party/coderabbit-schema/` so the check is offline and
an endpoint outage cannot turn it into a skip. If a refreshed schema uses a
JSON Schema keyword the validator does not implement, the check fails and names
it rather than under-validating while reporting success.

`--require-static` is passed in CI so a missing qmllint **fails** rather than
skipping: a silent skip is indistinguishable from a pass.

One other local/CI difference: the bare `git diff --check` above is a
working-tree check, so on a clean CI checkout it would inspect nothing. CI
diffs a range instead, which is why the job checks out with `fetch-depth: 0`.
Each event has exactly one base:

| Event | Whitespace base |
|-------|-----------------|
| `pull_request` | `github.event.pull_request.base.sha` |
| `merge_group` | `HEAD^1` — the merge commit's first parent, so the range is everything the group adds, including a multi-PR combination no single PR range covered |
| `push` | `github.event.before`, the previous tip of the branch |

The step runs on **every** event rather than only on pull requests: skipping it
on `merge_group` and `push` would leave it green without checking on precisely
the two events that gate landing code.

**There is no fallback base, deliberately.** If the base above cannot be
resolved — a force-push can leave the previous tip unreachable, a
branch-creation push sends the all-zero sha, a root commit has no first parent —
the step prints `::error::` and **fails**. It does not substitute a narrower
range: doing so passes while claiming coverage it does not have, which is the
same defect as skipping the step. An unrecognised event fails the same way,
so adding a trigger forces a conscious decision about what to compare against.
A red run on a rewritten trunk is informative, not noise.

A whole-tree whitespace check is deliberately not used: the vendored trees under
`config/vshell/nvim/colorschemes/` and `config/vshell/icons/` carry ~2000
pre-existing findings, so it would be red from day one and would need an
exclusion list to maintain.

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
