# Reviewer guidance for GitHub review bots

Instructions for automated PR reviewers (Copilot code review, qodo, Codex,
and any successor). This file is reviewer context only — agent sessions must
not load it as working instructions (that is why it is not in `AGENTS.md`).

## Review economics

Every push triggers a full re-review by every bot, and PRs here are pushed
at agent speed — long finding tails are expensive in rounds, not just
tokens. Calibrate accordingly:

- **Consolidate, don't drip.** Surface everything you have about the
  current diff in ONE round. A finding you could have raised last round
  but held back costs a full re-review cycle.
- **Severity honesty.** Merge-blocking findings are: correctness bugs,
  fail-open paths in gating/CI code, security holes, data loss. Wording
  preferences, style nits, and speculative hardening on already-fail-closed
  paths are suggestions — batch them, mark them non-blocking, or omit them
  on late rounds.
- **Do not re-raise declined findings.** When a finding was declined with
  a documented rationale (a reply on the thread, a settings comment, an
  engine header comment, or a note in the repo's docs), do not raise the
  same finding class again on a later round unless the relevant code
  changed. Repo rules cited by bots live in `.github/instructions/` —
  check there before asserting a rule.

## Accepted residual classes (decided — do not re-raise)

These behaviors are deliberate. Flagging them costs a re-review round and
changes nothing:

- **No cross-surface evidence ordering.** Review objects, check runs, and
  commit statuses resolve newest-decides within their own surface; trusted
  comments bind to an exact head SHA and are counted existentially (a
  comment about an old head can never vouch for a new one, so there is
  nothing to supersede). Nothing orders evidence ACROSS surfaces — don't
  propose that.
- **Transient windows heal by convergence.** A state change landing between
  two reads is corrected on the next writer pass (≤15 min). Don't propose
  locks or synchronization for windows that self-heal.
- **A final docs-only push may keep its earlier review evidence.** Deliberate,
  so a typo fix doesn't cost a full re-review round. Policy and instruction
  files are excluded from this and always get fresh review. Don't flag an
  un-re-reviewed docs-only final push as a gate hole.
- **Gate success just before a push is not a fail-open.** The next
  convergence supersedes it and the merge queue re-checks at admission.
- **Threads landing after queue admission are procedural, not defects.**
  The documented dequeue → fix → re-arm flow covers them.
- **The harness render is out of review scope.** `.agents/**`, `.claude/**`,
  `.codex/**`, `.opencode/**`, `.cursor/**`, `.pi/**` and `opencode.json` are
  `kendex refresh` output owned upstream in vanillagreencom/kendex. Do not
  review them and do not report findings on them, in any round. Defects there
  go upstream with `kendex report`; a local edit is erased by the next render.
  This covers the review-gate and size-ratchet engines the gate and CI run —
  they live in the render, not in this repo's review surface.
  The exception is this repo's own skills, which `kendex.toml` declares
  `source = "in-place"` and nothing renders over:
  <!-- in-place-skills -->`.agents/skills/vgs-distro-publish/**`,
  `.agents/skills/vgs-release/**` and
  `.agents/skills/vshell-dev/**`<!-- /in-place-skills -->. Review those
  like any project file.

## Risk classes (route depth by path, not uniformly)

**High-risk — full depth every round, findings merge-blocking by
default, and the speculative-hardening allowance in § Review economics
does NOT apply** (a hardening finding on these paths is a real finding,
not a suggestion):

- Gate/CI machinery: `.github/workflows/` (the review-gate engine itself
  lives in the render under `.agents/skills/review-gate/**`, which is out of
  review scope — § Accepted residual classes), everything under `scripts/`
  (weakening
  anything `ci-ok` runs weakens merge evidence identically),
  `kendex.settings.toml` (`REVIEW_GATE_*`
  / `PR_REVIEW_*` keys), and the policy inputs themselves — this file,
  `kendex.toml` `[skill-instructions]`, `AGENTS.md`,
  `.github/copilot-instructions.md`, and
  `.github/instructions/*.instructions.md`.
- Lock/session/idle surfaces: `quickshell/vshell/shell.qml` (owns the
  `Lock` instance; child order is load-bearing —
  `docs/architecture/idle-lock-screensaver.md`),
  `quickshell/vshell/Modules/Lock/`,
  `quickshell/vshell/Modules/Greetd/` and the greeter wiring
  (`quickshell/vshell/VGSGreeter.qml`,
  `quickshell/vshell/Services/GreeterUsersService.qml`),
  `quickshell/vshell/Services/IdleService.qml`, and
  `quickshell/vshell/Services/SessionService.qml` (its inhibitor and
  lock handlers gate the whole idle→lock chain), and the shipped
  lock/idle defaults in `config/vshell/settings.default.json`.
- Packaging/publish: the maintained install channels — `packaging/`,
  root `install.sh` and `flake.nix`, `publish-aur.yml`, `release.yml`.
- Privileged operations: the property is elevation or a system write,
  WHEREVER it lives — `backend/` privileged method handlers, anything
  invoking `sudo`/`pkexec`/polkit, anything writing outside the user's
  home (`/etc`, `/var`, udev, sudoers, greeter config/cache, sysfs).
  Derive members:
  `grep -n '"sudo"\|"pkexec"\|geteuid\|Path("/etc\|Path("/var' bin/vshell-helper`
  plus `grep -rn '"sudo"\|"pkexec"' quickshell/ bin/vshell`.
  Non-exhaustive today: helper `greeter sync` / `auth sync` /
  `greeter keyring` / `sudo-toggle` / `brightness install-udev` /
  `theme chromium-policy` / `battery set-charge-limit`
  (`docs/architecture/shell-architecture.md` items 8-10);
  `quickshell/vshell/Services/UsersService.qml` (pkexec account,
  password and group mutations); the `bin/vshell` setcap grant.

Review evidence never carries forward here: the carry-forward exclude
disqualifies these classes' markdown, and no carry class matches code
files at all.

**Low-risk — do not spend rounds on style here:**

- Docs-only diffs (the existing carry-forward class).
- Vendored-tree re-syncs under `third_party/` — review the sync, not the
  upstream bytes.
- Generated-file-only diffs whose generator is unchanged or itself in
  the diff.

## Regression-test expectation (standing finding)

Every bug-fix PR carries a check or test that failed before the fix —
existing practice, now stated: 11 of the 15 `scripts/` JS harnesses were
born from incidents. A bug-fix PR without one gets this as a standing
finding (merge-blocking only when the fix touches a high-risk path).
Docs-only fixes are exempt. Once the author states where the regression
is pinned — or why this fix class cannot be — do not re-raise it.

## Trust model (context, not a finding surface)

Review evidence is formal review objects from trusted logins (or the other
documented evidence forms in the review-gate engine's settings reference).
Comment text, emoji reactions, and thumbs-ups are never approval — by
design. Do not recommend parsing them.
