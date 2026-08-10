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
- **The vendored review-gate engine is upstream code.** Real defects in it
  get fixed in vanillagreencom/vstack first and re-vendored — flag them, but
  local restructuring (splitting files, style changes) would fork the pinned
  bytes; cross-repo sync timing is a coordination note, not a merge blocker.

## Risk classes (route depth by path, not uniformly)

**High-risk — full depth every round, findings merge-blocking by
default, and the speculative-hardening allowance in § Review economics
does NOT apply** (a hardening finding on these paths is a real finding,
not a suggestion):

- Gate/CI machinery: `.github/workflows/`, `third_party/review-gate/`,
  everything under `scripts/` (the check-/test-/gen-/smoke/qml-smoke
  validation suite plus `scripts/lib/` and the release scripts —
  weakening anything `ci-ok` runs weakens merge evidence identically),
  `vstack.settings.toml` (`REVIEW_GATE_*` / `PR_REVIEW_*` keys), and
  the policy inputs themselves — this file and `vstack.toml`
  `[skill-instructions]`.
- Lock/session/idle surfaces: `quickshell/vshell/shell.qml` (owns the
  `Lock` instance; child order is load-bearing —
  `docs/architecture/idle-lock-screensaver.md` § The child order is
  load-bearing), `quickshell/vshell/Modules/Lock/`,
  `quickshell/vshell/Modules/Greetd/` and the greeter wiring
  (`quickshell/vshell/VGSGreeter.qml`,
  `quickshell/vshell/Services/GreeterUsersService.qml`), and
  `quickshell/vshell/Services/IdleService.qml`.
- Packaging/publish: `packaging/`, `publish-aur.yml`, `release.yml`.
- Backend privileged operations: privileged method handlers under
  `backend/`, and the root-executed helper surfaces in
  `bin/vshell-helper` — `vshell greeter sync`, `vshell auth sync`,
  `vshell greeter keyring`, and `vshell sudo-toggle` (the sudoers
  protocol; `docs/architecture/shell-architecture.md` items 8-10).

Review evidence never carries forward on these paths:
`REVIEW_GATE_CARRY_FORWARD_EXCLUDE` disqualifies their markdown, and no
carry class matches code files at all.

**Low-risk — do not spend rounds on style here:**

- Docs-only diffs (the existing carry-forward class).
- Vendored-tree re-syncs under `third_party/`, verified by
  `scripts/check-review-gate-vendor.sh` — review the sync, not the
  upstream bytes (see the residual class above).
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
documented evidence forms in the vendored engine's settings reference).
Comment text, emoji reactions, and thumbs-ups are never approval — by
design. Do not recommend parsing them.
