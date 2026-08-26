---
name: linear
description: "Bash CLI over Linear's GraphQL API with a local cache. Load for ANY Linear interaction: reading, searching, creating, or updating an issue, project, cycle, milestone, initiative, or label."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.1.0"
tags: [integration]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

## Tracker policy: Linear is canonical; GitHub Issues is intake-only

Create, label, and work issues ONLY in Linear (team vg-shell, identifiers
VGS-<n>). GitHub Issues stays as intake, and nothing syncs back. Before creating
a Linear issue, dedupe across BOTH trackers (`gh issue list --search` + Linear
cache) — never file the same problem twice.

Mirroring GitHub intake into Linear is a MANUAL triage step. No automation does
it: there is no sync workflow under `.github/` and no Linear-side GitHub
integration creating issues, so an unmirrored GitHub issue never reaches the
canonical tracker and can sit unseen indefinitely. Run the triage pass when
picking up work:

```bash
gh issue list --state open --limit 50 --json number,title,url,createdAt \
  --jq '.[] | [.number, .createdAt, .url, .title] | @tsv' &&
.agents/skills/linear/scripts/linear.sh cache issues list --all-projects
```

The two listings are chained: a `gh issue list` that fails prints nothing, and
unchained the Linear listing's success becomes the block's — an empty GitHub
column then reads as "nothing to mirror", the exact false-clean this pass exists
to prevent.

For each GitHub issue with no Linear counterpart, fetch title, body and url in
one call and build the description — the full body plus a provenance line back
to the GitHub issue — then create it in team vg-shell and work the Linear issue
rather than the GitHub one:

```bash
gh_json= gh_body= &&
gh_json="$(mktemp)" &&
gh_body="$(mktemp)" &&
gh issue view <n> --json title,body,url > "$gh_json" &&
jq -r '(.body | sub("\\s+$"; "")) + "\n\n---\n\nMirrored from GitHub issue [" + .url + "](<" + .url + ">) (intake-only tracker)."' "$gh_json" > "$gh_body" &&
{ [ -s "$gh_body" ] || { echo "mirror: description body is empty, not creating" >&2; false; }; } &&
title="$(jq -r .title "$gh_json")" &&
.agents/skills/linear/scripts/linear.sh issues create --title "$title" \
  --description-file "$gh_body"
created=$?
cleaned=0
for tmp in "$gh_json" "$gh_body"; do
  [ -n "$tmp" ] || continue
  rm -f -- "$tmp" || { cleaned=1; echo "mirror: could not remove $tmp, which still holds the issue JSON or body" >&2; }
done
( exit "$(( created ? created : cleaned ))" )
```

Run that block as a UNIT, in one shell — the `mktemp` paths live in variables,
so a command run on its own would find them empty and redirect to nothing.

NO STEP'S FAILURE MAY BE MASKED BY A LATER STEP'S SUCCESS. Every producing step
is chained with `&&`, so the first failure short-circuits the rest and becomes
the list's status; `created=$?` captures it, the cleanup loop runs on every path,
and `( exit ... )` re-raises it. That direction is the worst one here — this is
the manual GitHub-to-Linear step, so a masked failure means work never filed and
never noticed. Each shape below was a real silent failure before it was written
this way:

* `rm -f` last made ITS status the block's, and `rm -f` almost always succeeds:
  a create that failed on credentials, validation or an API error reported
  success and the agent believed the issue was filed.
* `gh issue view` and the description `jq` ran unchecked, so the create ran on
  whatever landed in the file — an empty description, the GitHub body and the
  provenance line lost, reported as success.
* the title `jq` ran inside the create's own argument list, where a command
  substitution's status is discarded whatever it exits with; hoisting it into
  `title=` is what makes that status visible.
* `[ -s "$gh_body" ]` because a status is a PROXY — what must be true is that
  the file has CONTENT — and it speaks when it refuses, since an
  empty-but-succeeded producer prints no diagnostic of its own.
* the cleanup itself ran unchecked, so a `rm` that failed after a successful
  create left the issue JSON and the rendered body on disk while the block
  reported success. `cleaned` records it, the loop names the file that survived,
  and the status is `created` when the create failed and `cleaned` otherwise —
  the create's failure is the more important one and still wins, but a cleanup
  failure can no longer vanish behind it.

`gh_json= gh_body=` BEFORE the first `mktemp`, and this one is about the
operator's own shell rather than about statuses. You paste this block into an
interactive shell, where `set -u` is off and both names may already be in use.
If the FIRST `mktemp` fails, the `&&` chain stops before `gh_body` is ever
assigned — and the cleanup at the bottom still runs, expanding whatever
`gh_body` happened to mean in your session and `rm`-ing a file this block never
created. Initializing both to empty first is what makes that impossible, and the
loop skips an empty path rather than passing it to `rm`. A runbook a person
pastes into their own shell must not be able to delete a file they named.

`( exit ... )` rather than a bare `exit`, which would close an operator's
interactive shell, and rather than a `trap ... EXIT`, which would linger in that
shell for the rest of the session. `mktemp`, not `/tmp/gh-<n>.json`: that path is
fully predictable from the issue number, so two lanes mirroring the same issue
overwrite each other's file, and a pre-created symlink there would be followed by
the redirect.

The list query carries `url` so the triage table is actionable; `body` is
fetched per issue rather than for all 50, and every field the description needs
comes from these commands alone — no extra lookup.

Automating this needs owner action (Linear workspace admin, or a LINEAR_API_KEY
repo secret) — see docs/decisions/D002-github-linear-intake-sync.md.

Link work to its issue through the branch name: `vgs-<n>-<slug>`. Linear's
GitHub integration matches that to attach the PR, and `GH_ISSUE_PATTERN` in
vstack.settings.toml reads the same shape. Commit subjects carry the identifier
as the scope — `area(VGS-12): imperative summary` — per AGENTS.md § Conventions.

Issue labels are live Linear issue labels. Inventory source of truth:

```bash
.agents/skills/linear/scripts/linear.sh cache labels list &&
.agents/skills/linear/scripts/linear.sh sync --reconcile
```

Chained for the same reason: a `cache labels list` that fails prints no labels,
and unchained the reconcile's success becomes the block's — leaving an agent
believing it read the live inventory when it read nothing.

Use the project-management label taxonomy when assigning labels. If the
taxonomy and live inventory disagree, stop before mutation and report the
missing/extra label; do not substitute a nearby label. Never create labels
without explicit user authorization.

`issues create/update --labels` replaces the full issue label set. For label
updates, compute the intended final full set from current labels: replace only
the target exclusive category (`agent:*`), preserve unrelated
classification/workflow labels, then pass the full validated set.

<!-- kendex:project-instructions:end -->

# Linear CLI

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

```bash
.agents/skills/linear/scripts/linear.sh <resource> <action> [options]
```

Reads go through `cache`; writes go through the live commands, which write through to the cache. `linear.sh <resource> --help` prints per-resource options.

## Commands

| Resource | Actions |
|----------|---------|
| `issues` | list, get, bulk-get, create, update, bulk-update, archive, trash/delete, children, list-relations, add-relation, remove-relation, activate, block, unblock, complete, validate-completion |
| `comments` | list, create, update, delete |
| `projects` | list, get, create, update, delete, list-dependencies, add-dependency, remove-dependency, post-update, list-updates, reorder, set-sort-order |
| `initiatives` | list, get, create, update, delete, add-project, remove-project |
| `milestones` | list, get, create, update, delete |
| `labels` / `project-labels` | list, create, update, delete |
| `teams` / `users` / `statuses` / `documents` | list, get (`users` also has `me`) |
| `cycles` | list, create, update |
| `sync` | Refresh the local cache (`--full`, `--reconcile`, `--if-stale N`, `--stats`) |
| `cache` | Cache-only reads: issues, projects, comments, labels, initiatives, cycles, attachments, status |
| `auth-check` | Report the resolved key/team and `writes_enabled` (`--strict` exits non-zero when writes would refuse) |
| `session-status` | Aggregated status for the `/start` workflow |

Aliases: `issues relations` → `list-relations`, `projects dependencies` → `list-dependencies`. Singular resource names (`issue`, `project`, …) route to the plural.

There is no `view`/`show`. Single-issue lookups are `issues get <ID>` (live) or `cache issues get <ID>`; multi-issue lookups are `issues bulk-get <ID1> <ID2> ...`, which is also the post-mutation verification path.

Schema reference over ctx7: `/websites/studio_apollographql_public_linear-api_variant_current` (API), `/linear/linear` (SDK), `/websites/linear_app_developers` (guides). [patterns/workflow-actions.md](patterns/workflow-actions.md) covers multi-step state changes.

## Cache

```bash
linear.sh cache issues list --project "Phase 2" --state "Todo,In Progress"
linear.sh cache issues get ABC-100 --with-bundle
linear.sh sync --reconcile
```

`cache issues list --all-projects` enumerates every project in one command (each row carries its `project` name); `--no-project` returns only unassigned issues. Both are mutually exclusive with `--project`. Use `--all-projects`; never loop per project. An unrecognized filter flag is rejected. Repeated `--label` flags (and `--labels a,b`) require ALL named labels.

Both `issues list` and `cache issues list` return the first 75 rows by default and warn on stderr when that truncated the result; `--max` fetches everything. `--limit N` caps a CACHE listing's total; on the live path it is the per-page size (`--max --limit N` pages at N under a 200-page cap that warns when it truncates). An audit that must see the whole backlog passes `--max`.

The cache lives at `.cache/linear` under the physical worktree root from `git rev-parse --show-toplevel`. A missing-cache error names the `cache_dir` and `meta_path` it checked. A cache file that exists but does not parse is reported as corrupt, never as an empty result.

In a linked worktree whose `.cache` should be a `WORKTREE_SYMLINKS`-managed symlink but is a real directory, `sync` refuses before touching the API and names the repair (`worktree fix-links <PATH>` from the main checkout). Repos whose `WORKTREE_SYMLINKS` deliberately excludes `.cache` are exempt.

## Team Target

`LINEAR_TEAM` has no default. With it unset every write refuses before any API call; reads drop the team filter. `--team <name>` overrides per call only on `issues create`, `projects create`, `cycles create`, and `labels create`. Run `auth-check --strict` before the first mutation in a project.

| Variable | Purpose | Default |
|----------|---------|---------|
| `LINEAR_API_KEY` | Required for live commands and sync; not for cache reads | — |
| `LINEAR_API_KEY_OVERRIDE` | Inline/test key that beats project files | — |
| `LINEAR_TEAM` | Team every write targets | — (unset refuses writes) |
| `LINEAR_FORMAT` | Default output format | `safe` |
| `LINEAR_TEAM_PREFIX` | Issue identifier prefix | `PROJ` |
| `LINEAR_AGENT_LABELS` | Declared `agent:*` taxonomy; non-empty makes `issues create` refuse unrouted creates | — (unset = off) |

`LINEAR_API_KEY` belongs in `.env.local`; non-secret defaults in committed `kendex.settings.toml` `[env]`. A key from project files beats one inherited from the environment, and `auth-check` warns (fingerprints only) when it shadows a differing inherited key.

## Issue Creation Routing

Never create a tracked issue directly from an orchestration or review session — route it through the TPM pipeline (project-management skill), which owns labels, project, priority, estimate, and relations.

Where `LINEAR_AGENT_LABELS` declares a taxonomy, `issues create` refuses — before any API call — a create carrying no agent label from that set, including a typoed `agent:*` name. `--no-agent-label` permits a deliberate bare create.

## Attachments

`issues create`, `issues update`, and `comments create` take a repeatable `--attach <path>`. Images embed as markdown in the description/body — on `issues update` without `--description`, the embed appends to the existing description rather than replacing it. Other files become Linear attachments on issues, or markdown links on comments (comments have no attachment surface). An unreadable path refuses before any API call; an attachment failure after a successful issue write reports `partial: true` and exits non-zero.

## Output Formats

| Format | Description |
|--------|-------------|
| `safe` | DEFAULT. Flat, null-safe JSON |
| `compact` | `safe` minus descriptions and other large text |
| `ids` | Newline-separated identifiers |
| `table` | Human-readable table |
| `raw` | Original GraphQL nesting — do not assume top-level jq paths |

`safe` renames fields: `identifier`→`id`, `id`→`uuid`, `state.name`→`state`, `state.type`→`state_type`, `sortOrder`→`sort_order`.

## Blocked Label vs Issue Relations

| Scenario | Use |
|----------|-----|
| Issue A blocked by Issue B (both in Linear) | Relation: `--blocked-by` |
| Issue blocked by an external factor (vendor, license) | `blocked` label + comment |

Blocking relations must connect peers of one bundle: same direct parent, or both top-level. The two issues need not share a project. An issue cannot block its own ancestor or descendant; use `--related` for traceability. Rejections for cross-subtree pairs prescribe the valid pair at the level where the subtrees separate. Incomplete, cyclic, or malformed hierarchy data is rejected before mutation.

A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata** — Linear itself already treats the dependent issue as unblocked. The relation stays for provenance; never remove or "fix" it, and audits must never classify it as stale. The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule").

## Option Behavior

| Option | Accepts | On failure |
|--------|---------|-----------|
| `--project` / `--milestone` | Name or UUID | Fail with "not found" |
| `--state` | Exact name, case-sensitive and team-specific | Fail, listing available states |
| `--parent` | Issue identifier or UUID | Fail; create also fails if the link cannot be verified or repaired |
| `--assignee` | Name or `me` | Fail with "not found" |
| `--labels` | Comma-separated issue-label names | Fail; nothing is written |
| `--cycle` | Cycle UUID | Fail before the mutation |
| `--priority` / `--estimate` / `--sort-order` | Numbers (`--priority` 0-4) | Fail naming the flag |

Available states: Backlog, Todo, In Progress, In Review, Done, Canceled (not "Cancelled"). Verify with `statuses list`.

`--labels` REPLACES the whole issue-label set. Fetch current labels, compute the final set, validate it against `cache labels list --format=safe` (which reports `is_group` so parent/group labels can be rejected), then pass the complete set. A name that does not resolve fails the update; `--clear-labels` is the only way to empty the set.

- `agent:*` labels are mutually exclusive, one per issue; `issues activate` applies them with the "In Progress" transition (semantics: `issues --help`).
- `issues bulk-update` is non-atomic: on partial failure it emits `partial: true` with per-issue results and exits non-zero.
- `issues block` applies the `blocked` label, creates the blocking relation, and comments. A rejected relation fails the command.

## validate-completion

The pre-merge check on state plus summary comment. The expected-state matrix — session root vs bundle children vs `--container` parents, and the fail-closed flag pairing — is in `issues --help` § Validate-Completion.

A "labelIds not exclusive child labels" error means two labels from one exclusive group. Requires Bash 4.0+ (macOS system Bash 3.2 is unsupported), `curl`, and `jq`.
