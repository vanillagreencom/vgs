---
name: linear
description: "Load for any Linear read or write: issues, projects, cycles, milestones, initiatives, labels."
summary: "Bash CLI over Linear's GraphQL API with a local cache: read, search, create, or update issues, projects, cycles, milestones, initiatives, and labels."
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

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->

## Tracker policy: Linear is canonical; GitHub Issues is intake-only

Create, label, and work issues ONLY in Linear (team vg-shell, identifiers VGS-<n>). GitHub Issues stays as intake, and nothing syncs back. Before creating a Linear issue, dedupe across BOTH trackers (`gh issue list --search` + Linear cache) — never file the same problem twice.

Mirroring GitHub intake into Linear is a MANUAL triage step. No automation does it: there is no sync workflow under `.github/` and no Linear-side GitHub integration creating issues, so an unmirrored GitHub issue never reaches the canonical tracker and can sit unseen indefinitely. Run the triage pass when picking up work:

```bash
gh issue list --state open --limit 50 --json number,title,url,createdAt \
  --jq '.[] | [.number, .createdAt, .url, .title] | @tsv' &&
.agents/skills/linear/scripts/linear.sh cache issues list --all-projects
```

The two listings are chained: a `gh issue list` that fails prints nothing, and unchained the Linear listing's success becomes the block's — an empty GitHub column then reads as "nothing to mirror", the exact false-clean this pass exists to prevent.

For each GitHub issue with no Linear counterpart, fetch title, body and url in one call and build the description — the full body plus a provenance line back to the GitHub issue — then create it in team vg-shell and work the Linear issue rather than the GitHub one:

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

Run that block as a UNIT, in one shell — the `mktemp` paths live in variables, so a command run on its own would find them empty and redirect to nothing.

NO STEP'S FAILURE MAY BE MASKED BY A LATER STEP'S SUCCESS. Every producing step is chained with `&&`, so the first failure short-circuits the rest and becomes the list's status; `created=$?` captures it, the cleanup loop runs on every path, and `( exit ... )` re-raises it. That direction is the worst one here — this is the manual GitHub-to-Linear step, so a masked failure means work never filed and never noticed. Each shape below was a real silent failure before it was written this way:

* `rm -f` last made ITS status the block's, and `rm -f` almost always succeeds: a create that failed on credentials, validation or an API error reported success and the agent believed the issue was filed.
* `gh issue view` and the description `jq` ran unchecked, so the create ran on whatever landed in the file — an empty description, the GitHub body and the provenance line lost, reported as success.
* the title `jq` ran inside the create's own argument list, where a command substitution's status is discarded whatever it exits with; hoisting it into `title=` is what makes that status visible.
* `[ -s "$gh_body" ]` because a status is a PROXY — what must be true is that the file has CONTENT — and it speaks when it refuses, since an empty-but-succeeded producer prints no diagnostic of its own.
* the cleanup itself ran unchecked, so a `rm` that failed after a successful create left the issue JSON and the rendered body on disk while the block reported success. `cleaned` records it, the loop names the file that survived, and the status is `created` when the create failed and `cleaned` otherwise — the create's failure is the more important one and still wins, but a cleanup failure cannot vanish behind it.

`gh_json= gh_body=` BEFORE the first `mktemp`, and this one is about the operator's own shell rather than about statuses. You paste this block into an interactive shell, where `set -u` is off and both names may already be in use. If the FIRST `mktemp` fails, the `&&` chain stops before `gh_body` is ever assigned — and the cleanup at the bottom still runs, expanding whatever `gh_body` happened to mean in your session and `rm`-ing a file this block never created. Initializing both to empty first is what makes that impossible, and the loop skips an empty path rather than passing it to `rm`. A runbook a person pastes into their own shell must not be able to delete a file they named.

`( exit ... )` rather than a bare `exit`, which would close an operator's interactive shell, and rather than a `trap ... EXIT`, which would linger in that shell for the rest of the session. `mktemp`, not `/tmp/gh-<n>.json`: that path is fully predictable from the issue number, so two lanes mirroring the same issue overwrite each other's file, and a pre-created symlink there would be followed by the redirect.

The list query carries `url` so the triage table is actionable; `body` is fetched per issue rather than for all 50, and every field the description needs comes from these commands alone — no extra lookup.

Automating this needs owner action (Linear workspace admin, or a LINEAR_API_KEY repo secret) — see docs/decisions/D002-github-linear-intake-sync.md.

Link work to its issue through the branch name: `vgs-<n>-<slug>`. Linear's GitHub integration matches that to attach the PR, and `GH_ISSUE_PATTERN` in kendex.settings.toml reads the same shape. Commit subjects carry the identifier as the scope — `area(VGS-12): imperative summary` — per AGENTS.md § Conventions.

Issue labels are live Linear issue labels. Inventory source of truth:

```bash
.agents/skills/linear/scripts/linear.sh cache labels list &&
.agents/skills/linear/scripts/linear.sh sync --reconcile
```

Chained for the same reason: a `cache labels list` that fails prints no labels, and unchained the reconcile's success becomes the block's — leaving an agent believing it read the live inventory when it read nothing.

Use the project-management label taxonomy when assigning labels. If the taxonomy and live inventory disagree, stop before mutation and report the missing/extra label; do not substitute a nearby label. Never create labels without explicit user authorization.

`issues create/update --labels` replaces the full issue label set. For label updates, compute the intended final full set from current labels: replace only the target exclusive category (`agent:*`), preserve unrelated classification/workflow labels, then pass the full validated set.

<!-- kendex:project-instructions:end -->

# Linear CLI

```bash
.agents/skills/linear/scripts/linear.sh <resource> <action> [options]
```

Reads go through `cache`; writes go through the live commands, which write through to the cache. `linear.sh <resource> --help` prints per-resource options. `--format` values: `safe` (the default, flat and null-safe), `compact` (a smaller shape for workflow routing), `ids` (identifiers only), `table`, `raw` (the GraphQL nesting, so never assume top-level jq paths). `safe` renames fields: `identifier`→`id`, `id`→`uuid`, `state.name`→`state`, `state.type`→`state_type`, `sortOrder`→`sort_order`.

## Commands

| Resource | Actions |
|----------|---------|
| `issues` | list, get, bulk-get, create, update, bulk-update, archive, trash/delete, children, list-relations, add-relation, remove-relation, activate, block, unblock, complete, validate-completion |
| `comments` / `labels` / `project-labels` | list, create, update, delete |
| `projects` | list, get, create, update, delete, list-dependencies, add-dependency, remove-dependency, post-update, list-updates, reorder, set-sort-order |
| `initiatives` / `milestones` | list, get, create, update, delete (`initiatives` also add-project, remove-project) |
| `teams` / `users` / `statuses` / `documents` | list, get (`users` also has `me`) |
| `cycles` | list, create, update |
| `sync` | Refresh the local cache (`--full`, `--reconcile`, `--if-stale N`, `--stats`) |
| `cache` | Cache-only reads: issues, projects, comments, labels, initiatives, cycles, attachments, status |
| `auth-check` | Report the resolved key/team and `writes_enabled` (`--strict` exits non-zero when writes would refuse) |
| `session-status` | Aggregated status for the `/start` workflow |

Aliases: `issues relations` → `list-relations`, `projects dependencies` → `list-dependencies`. Singular resource names (`issue`, `project`, …) route to the plural. There is no `view`/`show`: single-issue lookups are `issues get <ID>` (live) or `cache issues get <ID>`, and multi-issue lookups are `issues bulk-get <ID1> <ID2> ...`, which is also the post-mutation verification path.

Schema reference over ctx7: `/websites/studio_apollographql_public_linear-api_variant_current` (API), `/linear/linear` (SDK), `/websites/linear_app_developers` (guides). [patterns/workflow-actions.md](patterns/workflow-actions.md) covers multi-step state changes.

## Cache

```bash
linear.sh cache issues list --project "Phase 2" --state "Todo,In Progress"
linear.sh cache issues get ABC-100 --with-bundle
linear.sh sync --reconcile
```

`cache issues list --all-projects` enumerates every project in one command (each row carries its `project` name); `--no-project` returns only unassigned issues. Both are mutually exclusive with `--project`. Use `--all-projects`; never loop per project. An unrecognized filter flag is rejected. Repeated `--label` flags (and `--labels a,b`) require ALL named labels.

Both `issues list` and `cache issues list` return the first 75 rows by default and warn on stderr when that truncated the result; `--max` fetches everything. `--limit N` caps a CACHE listing's total; on the live path it is the per-page size (`--max --limit N` pages at N under a 200-page cap that warns when it truncates). An audit that must see the whole backlog passes `--max`.

The cache is `.cache/linear` under the physical worktree root ([README.md](README.md)); a linked worktree whose `.cache` should be a `WORKTREE_SYMLINKS`-managed symlink but is a real directory refuses `sync` and names the repair. A repo whose `WORKTREE_SYMLINKS` deliberately excludes `.cache` is exempt.

## Team Target

`LINEAR_TEAM` has no default. With it unset every write refuses before any API call; reads drop the team filter. `--team <name>` overrides per call only on `issues create`, `projects create`, `cycles create`, and `labels create`. Run `auth-check --strict` before the first mutation in a project.

`LINEAR_API_KEY` belongs in `.env.local`; non-secret defaults in committed `kendex.settings.toml` `[env]`. A key from project files beats one inherited from the environment, and `auth-check` warns (fingerprints only) when it shadows a differing inherited key.

## Issue Creation Routing

Never create a tracked issue directly from an orchestration or review session. Route it through the TPM pipeline (project-management skill), which owns labels, project, priority, estimate, and relations.

Where `LINEAR_AGENT_LABELS` declares a taxonomy, `issues create` refuses before any API call a create with no agent label from that set (`--no-agent-label` permits a deliberate bare create). Where `LINEAR_REQUIRE_REACH` is set, it refuses a description with no `Reached by:` line and, with `--review-born` and `--priority 2`, one with no `Symptom:` line; a placeholder or null token counts as no line. Each guard is its own setting. What the lines say is the author's to judge; the rule is the project-management skill's SKILL.md § Disposition, **Name what reaches it**, which is also where a create decides whether it is review-born.

## Attachments

`issues create`, `issues update`, and `comments create` take a repeatable `--attach <path>`. Images embed as markdown in the description/body. On `issues update` without `--description`, the embed appends to the existing description rather than replacing it. Other files become Linear attachments on issues, or markdown links on comments (comments have no attachment surface). An unreadable path refuses before any API call; an attachment failure after a successful issue write reports `partial: true` and exits non-zero.

## Blocked Label vs Issue Relations

A blocker that is itself a Linear issue is a relation (`--blocked-by`); an external one (vendor, license) is the `blocked` label plus a comment.

Blocking relations must connect peers of one bundle: same direct parent, or both top-level. The two issues need not share a project. An issue cannot block its own ancestor or descendant; use `--related` for traceability. The check reads each issue's own direct parent in one query.

A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata**. The relation stays for provenance; never remove or "fix" it, and audits must never classify it as stale. The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule").

Normalized issue lists, gets, bulk gets, bundles, recursive children, relation reads, and session status keep each blocking relation in `blocked_by` and list only nonterminal blockers in `blocked_by_open`.

## Option Behavior

What each option accepts: `issues --help`. Refused before any write, on the create and update paths alike: `--cycle` on a non-UUID, `--project`/`--milestone`/`--assignee` on a reference that matches nothing, and `--priority` on an out-of-range value. Available states: Backlog, Todo, In Progress, In Review, Done, Canceled (not "Cancelled"). Verify with `statuses list`.

A **name** selects one project on `issues create` / `update` / `bulk-update --project`, `projects get` / `cache projects get`, `projects list-dependencies` (the live spelling only; `cache projects list-dependencies` matches on the name alone), `milestones --project`, and `initiatives add-project` / `remove-project`. There a canceled project sharing that name loses to the live one, and a name with no live match is refused, naming each match and its state; pass a UUID to reach a canceled project. Name **filters** never resolve: `issues list --project`, `cache issues list --project` and `documents list --project` match on the name alone, so their results can mix a live project with its canceled twin.

`--labels` REPLACES the whole issue-label set. Fetch current labels, compute the final set, validate it against `cache labels list --format=safe` (which reports `is_group` so parent/group labels can be rejected), then pass the complete set. A name that does not resolve fails the update; `--clear-labels` is the only way to empty the set.

- `agent:*` labels are mutually exclusive, one per issue; `issues activate` applies them with the "In Progress" transition (semantics: `issues --help`).
- `issues bulk-update` is non-atomic: on partial failure it emits `partial: true` with per-issue results and exits non-zero.
- `issues block` applies the `blocked` label, creates the blocking relation, and comments. A rejected relation fails the command.

## validate-completion

The pre-merge check on state plus summary comment, live only: `issues validate-completion`, with no `cache` spelling. The expected-state matrix is in `issues --help` § Validate-Completion: session root vs bundle children vs `--container` parents, and the fail-closed flag pairing.

A "labelIds not exclusive child labels" error means two labels from one exclusive group. Requires Bash 4.0+ (macOS system Bash 3.2 is unsupported), `curl`, and `jq`.
