---
name: project-management
description: "Load to plan a cycle, audit issues, build a roadmap, or decompose research into issues."
summary: "TPM planning, audit, roadmap, and research-driven decomposition: the cycle-plan, audit-issues, roadmap and research wrappers and the TPM workflows under them."
license: MIT
user-invocable: true
dependencies:
  required: [orch, linear, github]
  optional: [decider, second-opinion]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "3.0.0"
tags: [planning]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

## Linear projects

Every new non-mirror issue gets exactly one project. The set (all team
vg-shell):

| Project | Scope |
|---------|-------|
| `Tech Debt & Bugs` | Hygiene and discovered pre-existing issues — bugs, cleanup, tooling/workflow debt that fits no feature area. |
| `Shell Runtime & Widgets` | Quickshell runtime, modules, widget primitives, design language, idle/lock/greeter session surfaces. |
| `Theme Engine & Wallpapers` | Themes, palettes, blueprints, generated app targets, wallpaper pipeline and upscaling. |
| `Backend & System Services` | Go backend daemon, socket protocol/capability gating, system integrations (network, logind, BlueZ, CUPS), helper CLI. |
| `Packaging & Install Channels` | install.sh, distro packages (Arch/Debian/Fedora/Gentoo/Void/Nix), release verification, channel upkeep. |
| `Cloud Sync` | Supervised rclone, accounts/OAuth, sync modes and safety rails, watcher, FUSE mounts, Cloud Sync app/widget. |

A bug inside a feature area goes to that area's project, not Tech Debt & Bugs;
the hygiene project is for cross-cutting debt and pre-existing discoveries.
Synced `nightly-ci:` mirrors arrive with no project — route them to
`Tech Debt & Bugs` on first triage. Creating a new project is an owner
decision: propose it, do not create it unprompted.

## Project issue label taxonomy

Use this taxonomy with the linear skill's label-inventory preflight for roadmap
creation, audit-created issues, research issues, and any other issue
create/update path.

Required for new non-historical issues:
- Exactly one Agent label.
- Classification and Workflow labels are optional and additive.
- Domain labels apply when the work clearly sits in that domain.

Label creation rule: if a label listed here is missing from live Linear
inventory, stop and ask for explicit user authorization to create it. Do not
create labels automatically and do not silently omit or substitute labels.

### Agent labels (exclusive; choose exactly one)

| Label | Use when |
|-------|----------|
| `agent:generalist` | Maintenance, docs cleanup, tooling/workflow tasks, repository organization, or mixed low-risk work — including QML/Go/helper implementation until dedicated domain agents exist. |
| `agent:multi` | Bundle parent or coordination issue whose children span 2+ domains. Avoid on leaf implementation issues unless the issue is truly orchestration-only. |
| `agent:human` | Manual/user-owned work, external dependency/vendor action, or work intentionally not delegated to an AI agent. |
| `agent:researcher` | Research issue owned by the researcher workflow/agent. Must be paired with `research`. |

`agent:iced` and `agent:rust` are workspace-level labels inherited by every
team; they serve other projects (hyprtrade), so never assign them in VGS.

### Domain labels (non-exclusive; choose all that apply)

| Label | Use when |
|-------|----------|
| `ci-infra` | CI, review gates, runners, and repo tooling — the validation suite, `.github/workflows/`, packaging automation. |
| `test` | Testing itself: coverage, harnesses, fixtures, flakes. Pairs with `ci-infra` when the harness is CI-owned. |
| `frontend` | UI-surface work: shell surfaces, widgets, modals, settings screens under `quickshell/vshell/`. |
| `design` | Visual design language, tokens, typography, surface layout — the Flatline language in `docs/architecture/design-language.md`. |
| `component` | Reusable widget/control work, especially primitives in `quickshell/vshell/Widgets/`. |

Priority rule: `ci-infra` implies Urgent unless the issue deliberately records
why it is lower. Everything VGS uses to decide whether a change is safe to merge
lives in that category, so a defect there invalidates the evidence behind every
other issue's "verified" claim.

### Classification labels (non-exclusive; additive)

| Label | Use when |
|-------|----------|
| `bug` | Defect in shipped behavior. |
| `enhancement` | New feature or request. |
| `chore` | Mechanical/maintenance work, no behavior change. |
| `docs` | Documentation work. |
| `security` | Security-relevant surface or hardening work. |
| `refactor` | Restructure/migration/cleanup where behavior should mostly remain unchanged. |
| `research` | Research spike/issue whose primary output is findings/decision support. Pair with `agent:researcher`. |
| `baseline` | Establishes a measurement baseline, benchmark fixture, golden data, or pre-optimization reference. |

### Workflow labels (non-exclusive; additive)

| Label | Use when |
|-------|----------|
| `needs-research` | Blocked on unresolved research. Prefer a blocking relation to a research issue when one exists. |
| `needs-review` | Requires an explicit review gate before execution/merge/close. |
| `needs-safety-audit` | Concurrency, lock-free, memory/thread safety, or safety-critical validation required. |
| `needs-perf-test` | Benchmark/profiling/performance validation required before acceptance. |
| `critical-path` | Blocks or enables major project progress; align priority accordingly. |
| `blocked` | External blocker only (vendor/license/access/manual dependency). For issue dependencies, use blocking relations instead. |
| `owner-gated` | Needs an owner decision or owner-only action to proceed. |
| `hardware-blocked` | Blocked on physical hardware or device/OS access — a second monitor, a fingerprint reader, an Apple display — rather than on a decision or another issue. |
| `re-triage` | Request one triage-janitor pass (Linear Loop 2) over an issue whose labels, project, or priority look wrong. The automation REMOVES it when the pass completes, so it is a trigger, not a state — an issue carrying it long-term means the loop did not run. Expect zero issues to carry it at rest. |

`ci-nightly` marks CI-failure mirrors; the taxonomy above does not apply to
mirrored issues — do not retitle or relabel them to satisfy it. Note there is
no automated ingest: mirroring GitHub intake into Linear is manual, per the
tracker policy in the linear skill instructions.

### Never-use labels

These are live in the workspace and must never be assigned in VGS. The reason
matters as much as the verdict: a label omitted with no explanation reads as an
oversight, and gets "fixed" by someone assigning it.

| Label | Why never |
|-------|-----------|
| `Agent` | Group/parent label. Assign one of its children, never the group itself. |
| `Platform` | Group/parent label, same rule. |
| `ios` | VGS is a Wayland shell for Hyprland or Niri. Can never apply. |
| `macos` | Same. |
| `windows` | Same. |
| `cross-platform` | Same — VGS targets exactly one platform, so nothing here is cross-platform. |
| `linux` | Vacuously true for every VGS issue, so it carries no information. |
| `agent:iced` | Workspace-level label inherited by every team; serves hyprtrade. |
| `agent:rust` | Same. |
| `iced` | Same. |
| `rust-core` | Same. |
| `feature` | Duplicate of `enhancement` ("New capability or product behavior" vs "New feature or request"). VGS uses `enhancement`; `feature` is on zero VGS issues. It is workspace-level and may serve another team, so do not delete it — just do not assign it here. |

<!-- kendex:project-instructions:end -->

# Project Management

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Wrappers run in the primary session: they own the user dialog and every tracker mutation. TPM workflows analyze and return JSON inline; they never mutate the tracker and never write the artifact.

## Disposition

- **Creation bar.** File an issue only when all three hold: it changes what a user or operator experiences, or blocks work that does; no open issue, active branch, or one-line fix already covers it; and someone could pick it up and finish it without a new investigation. A reproducible anomaly with evidence in hand passes all three as an investigation issue. Everything else is declined with one line in the report — no issue, no placeholder, no tracking artifact. A severe-sounding edge case that no real input reaches fails the first test, and so does a hypothetical of low severity, a coverage ask for a path that has not regressed, and a refactor that neither changes behavior nor unblocks user-visible work. The classes in [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Decision flow Step 0 fail this bar too, whatever source the candidate arrived from — a review, or a backlog sweep that never ran Step 0. Among what does reach it, two exceptions file at any likelihood: a security or data-loss defect a shipped path reaches, and an edge case whose failure is critical harm or financial loss.
- **Name what reaches it.** Every issue carries a `Reached by:` line giving the user action, run, check, or shipped producer that arrives at the defect; an owner-directed item names the ask. The thread a finding came from, a shape ("a name containing a quote"), or something true in theory is not a reach, and an unsubstituted placeholder or a null token (`TBD`, `n/a`, `none`, `-`) is no value at all — `linear.sh issues create` refuses each under `LINEAR_REQUIRE_REACH`, and an item with nothing to name is a decline, not an issue. A filing whose source is a review round carries, at priority 2, a `Symptom:` line naming the run, the user, or the red check that already showed the defect (`--review-born`). Priority 2 from any other source is structural, reports no symptom, and is not checked for one. Where a review-born finding files at all is [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Filing bar.
- **Burn down more than you create.** Every audit that reads an issue backlog sweeps its comparison set for issues the codebase has already satisfied, duplicated, or superseded, and proposes those for cancellation in the same pass, along with every active issue that fails the creation bar as it stands today. Report `created N / closed M`. `project-order` reorders projects, reads no backlog, and does not sweep.
- **Ask about work, never about mechanics.** The user decides what gets created, cancelled, and activated. Labels, priorities, relations, hierarchy, sort order, and project moves are corrections the workflow applies on its own authority.
- **Research is part of planning, not a work item.** Gather prior art, vendor docs, and approach comparisons inline during planning as an artifact on disk that issues cite. A tracker research issue exists only when the research is delegated as standalone work — run by the researcher agent, or prepared for later pickup (`research-spike`).
- **One approval per decision.** Ask the user to approve a body of work once — at the roadmap plan gate. Creation re-asks only what changed after that answer.

## Commands

| Command | Arguments | Workflow |
|---------|-----------|----------|
| `cycle-plan` | — | [cycle-plan](workflows/cycle-plan.md) |
| `audit-issues` | `project` \| `project "Name"` \| `team` \| `issue [IDs]` \| `--issues [file]` \| `--analyzed [file]` \| `project-order` | [audit-issues](workflows/audit-issues.md) |
| `roadmap plan` | `[feature]` \| `[feature] @[research-or-plan-path]` | [roadmap-plan](workflows/roadmap-plan.md) |
| `roadmap create` | `@[plan-file]` | [roadmap-create](workflows/roadmap-create.md) |
| `research-spike` | — | [research-spike](workflows/research-spike.md) |
| `research-complete` | `[ISSUE_ID]` | [research-complete](workflows/research-complete.md) |
| `research-issue` | — | [research-issue](workflows/research-issue.md) — internal, invoked by `research-spike` |

`audit-issues` is **primary-session only** ([audit-issues](workflows/audit-issues.md) preamble): the roadmap-plan § 5 answer that roadmap-create carries in is validated and admitted at § 6, never around it.

The `@[path]` given to `roadmap plan` may be research findings or a **finished plan** (a design the user has reviewed). A finished plan is the spec: derive issues from it instead of re-planning, and every issue cites it.

TPM analysis workflows, each returning JSON per its schema: [tpm-cycle-plan](workflows/tpm-cycle-plan.md), [tpm-audit](workflows/tpm-audit.md) (project / team / issue / project-order modes), [tpm-roadmap-plan](workflows/tpm-roadmap-plan.md).

## Execution Rules

- Run workflow sections in order. Skip only on an explicit **Skip if** condition, never on your own scope assessment.
- `<delegation_format>` and `<output_format>` are literal templates: fill `[PLACEHOLDERS]`, drop lines whose placeholders are empty, add nothing.
- Send a user-visible `<output_format>` report as a normal assistant message first, then invoke the question tool separately with only the question and short option labels. Never paste the report into question text or options.
- The Linear cache holds the whole workspace: `sync` sends no team filter, and `cache issues list` neither filters by team nor returns one. The two analysis workflows resolve the configured team and scope their own cached reads to it (tpm-audit § 1.1.1, tpm-roadmap-plan § 1.1) — an issue outside it is never an input, a comparison, a duplicate, an obsolescence candidate, or a cancellation, and a project outside it is never a placement. Every other workflow reads the cache workspace-wide.
- Every path's scope status is enumerated in § Scope by Path; a mode added later states its own row rather than inheriting silence.
- Sync the Linear cache before a workflow's first cache read: `sync --reconcile` in a run that mutates the tracker, `sync --if-stale 15` in a read-only lookup. That sync is the freshness mechanism; a cached read itself enforces presence, so a read that comes back missing halts the workflow and reports the sync failure — never a partial result, a live-only substitute, or a retry against the unsynced cache.
- Resolve tracker context once per run (audit-issues § 1.2) and route every preflight, fetch, and mutation through it. A GitHub-tracked run must not require Linear installation, sync, or authentication; where GitHub lacks a Linear concept, degrade in a documented note, never silently.
- Before any issue create or label update, run the label preflight in [references/labels.md](references/labels.md) against the live inventory and project taxonomy; any § Validation failure there halts before mutation.
- In multi-issue analysis, keep verification context per issue. One issue's PR, branch, or resolved path set never scopes another's checks.

## Scope by Path

The Linear cache is workspace-wide, so each path states whether it resolves the team scope (tpm-audit § 1.1.1) and what it filters. Silence is not inheritance: a new mode adds its row.

| Path | Resolves | Filters |
|------|----------|---------|
| tpm-audit `project`, `team` | yes | § 1.3 projects, § 1.4 input set, § 1.5 comparison set |
| tpm-audit `issues`, Linear | yes | § 1.5 comparison set; a § 1.4 input issue outside scope halts |
| tpm-audit `issues`, GitHub | n/a — reads no Linear cache | n/a |
| tpm-audit `project-order` | yes | § 11 initiatives, projects, and per-project issues |
| tpm-roadmap-plan | yes, § 1.1 | § 1.4 projects, § 1.5 comparison set |
| tpm-cycle-plan | **no** | **no** — `session-status` picks the active project workspace-wide, and every later read is scoped to that pick |
| audit-issues §§ 7.2-7.5 | n/a — executes an artifact tpm-audit produced under its scope | reads rooted at an in-scope project or an issue this run mutated |
| audit-issues § 1.2.1, § 3 | **no** | **no** — `session-status` selects projects workspace-wide |
| cycle-plan, roadmap-plan, roadmap-create, research-spike | **no** | **no** — project, initiative, and label reads span the workspace |
| research-complete | n/a | reads are rooted at the caller's issue identifier |
| research-issue | n/a | reads rooted at the caller's identifiers; the project it creates into is the caller's pick |

## Hierarchy

`Initiative → Project → Milestone → Issue → Sub-Issue`. Parent and child must share a project; blocking relations may cross projects freely. See [references/dependencies.md](references/dependencies.md).

## Contracts

| Kind | Files |
|------|-------|
| Schemas | [audit-issues-input](schemas/audit-issues-input.md), [audit-output](schemas/audit-output.md), [roadmap-plan-input](schemas/roadmap-plan-input.md), [roadmap-plan-output](schemas/roadmap-plan-output.md), [cycle-plan-output](schemas/cycle-plan-output.md) |
| Templates | [issue-description-template](templates/issue-description-template.md), [parent-issue-template](templates/parent-issue-template.md) |
| References | [labels](references/labels.md), [dependencies](references/dependencies.md) |
| Tracker CLI | Linear: `.agents/skills/linear/scripts/linear.sh`; GitHub: `gh` + `.agents/skills/github/scripts/github.sh` |

## Dependencies

`orch` skill (the excluded classes the creation bar defers to live in its `references/finding-disposition.md`), `linear` skill (Linear-tracked work), `github` skill + `gh` (GitHub-tracked issue audits), `git` and `jq` (audit verification scope).
