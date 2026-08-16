#!/usr/bin/env bash
# End-to-end controls for the vendor drift check — scripts/lib/vendor-drift.sh
# and scripts/lib/vendor-drift-report.sh, behind
# scripts/check-review-gate-vendor.sh and scripts/check-size-ratchet-vendor.sh
# (VGS-155). Three suites split by what each one reads. This file covers what
# the check REPORTS: readings, repairs, preconditions and the wrappers. What it
# may BELIEVE — how a diff line is attributed and when a commit time can be
# trusted — is scripts/test-vendor-drift-evidence.sh. What the libraries promise
# about their own shape, asserted against source and driving nothing, is
# scripts/test-vendor-drift-contracts.sh.
#
# THE BUG THIS EXISTS FOR. The check used to print the mirror-to-tracked rsync
# unconditionally, as a procedure. Immediately after a vendoring PR merged the
# tracked copy was the NEWER side, so running it deleted the merged change — and
# the check then passed, because the two copies agreed again. Every case below
# is written so reintroducing an unconditional or unexplained repair fails one.
#
# Fixtures build a throwaway git repo per case, with its own commit time and its
# own refresh-marker mtime, so this runs anywhere — no vstack, no .agents
# mirror, no network. The GNU-only tooling they assume is stated once, on the
# harness that provides them.
#
# SIZE EXCEPTION, BASELINED. This file carries a size-ratchet baseline row above
# the 400-line threshold, argued and granted rather than inherited: it is
# MAJORITY CODE — 269 code to 123 comment — and it crossed at 399 lines, one
# under the line, when a reviewer found a repair branch no case drove (the
# overridden merged deletion below). The alternatives were splitting the suite,
# which buys a new file, a manifest row and a CI change to avoid a 22-line
# overage, or shipping that fix with nothing driving its branch — an assertion
# that cannot witness its subject. The baseline only ever moves DOWN, so this
# cannot grow again without the same argument. Reason also recorded in
# tools/size-ratchet-excludes and vstack.settings.toml, since the baseline row
# itself cannot carry a comment.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# shellcheck source=scripts/lib/vendor-drift.sh
source "$repo_root/scripts/lib/vendor-drift.sh"

PROG=check-demo-vendor
ENGINE=demo-engine

# shellcheck source=scripts/lib/vendor-drift-test.sh
source "$repo_root/scripts/lib/vendor-drift-test.sh"

# ── control: the two copies agree ─────────────────────────────────────────
# Without this, every "expected absent" assertion below would also pass on an
# engine that printed nothing at all.
root="$(new_fixture in-sync)"
set_refresh "$root" "$REFRESH"
commit_tracked "$root" "$COMMIT_OLD"
run_check "$root"
expect_rc "$rc" 0 "in-sync"
expect_contains "$out" "ok (third_party/$ENGINE matches the vstack copy)" "in-sync"
for verdict in "${VERDICTS[@]}"; do
  expect_absent "$out$err" "$verdict" "in-sync"
done
expect_absent "$out$err" "$RSYNC_COMMAND" "in-sync"
expect_absent "$out$err" "$REPAIR_REFRESH_SOLE" "in-sync"
ok "matching copies pass, and print no reading and no repair"

# ── the VGS-155 incident: tracked copy ahead ──────────────────────────────
# A vendoring PR merged after the last refresh. The old check printed the rsync
# here, and running it deleted the merged change.
root="$(new_fixture tracked-ahead)"
set_refresh "$root" "$REFRESH"
printf 'shared line\nREVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS\n' \
  >"$root/third_party/$ENGINE/references/settings.md"
commit_tracked "$root" "$COMMIT_NEW"
run_check "$root"
expect_rc "$rc" 1 "tracked-ahead"
expect_contains "$err" "$READING_TRACKED_AHEAD" "tracked-ahead"
# The repair LINE, not the phrase: "vstack refresh" also appears in this
# reading's own prose, so the phrase alone survives deleting the command.
expect_contains "$err" "$REPAIR_REFRESH_SOLE" "tracked-ahead"
expect_absent "$err" "$RSYNC_COMMAND" "tracked-ahead"
# The refresh pulls from the LOCAL vstack catalog, so name the second step.
expect_contains "$err" "the local vstack source catalog is older" "tracked-ahead"
saw_verdict "the TRACKED copy is newer"
ok "a commit after the last refresh names vstack refresh alone, and no rsync"

# The diff sides are named rather than left as bare markers to decode.
expect_contains "$err" "- lines are only in .agents/skills/$ENGINE/ (mirror)" "tracked-ahead labels"
expect_contains "$err" "+ lines are only in third_party/$ENGINE/ (tracked)" "tracked-ahead labels"
expect_contains "$err" "third_party/$ENGINE/references/settings.md" "tracked-ahead labels"
expect_contains "$err" ".agents/skills/$ENGINE/references/settings.md" "tracked-ahead labels"
ok "the diff carries both side labels and both real paths"

# Asserting the direction is still possible, and still says what the evidence
# says: the operator gets the command AND the contradiction.
run_check "$root" --confirm-mirror-is-newer
expect_rc "$rc" 1 "tracked-ahead confirmed"
expect_contains "$err" "$RSYNC_COMMAND" "tracked-ahead confirmed"
expect_contains "$err" "CONTRADICTS" "tracked-ahead confirmed"
# The most dangerous invocation the tool has: the evidence says the tracked copy
# is newer and the operator is overriding it. What dies must be named HERE, not
# left implicit in a diff further up the scrollback — this path once printed the
# command with the doomed file named nowhere after it.
expect_contains "$err" "$AT_RISK_PREFIX""third_party/$ENGINE/references/settings.md" \
  "tracked-ahead confirmed"
# -F on both: these patterns carry `.md` and `.vstack-refreshed`, whose dots
# match any character in regex mode, so the lookup could select a different line
# and make the ordering assertion silently wrong — in the control that pins the
# promise three reviewers blocked on.
cost_line="$(printf '%s' "$err" | grep -nF -- "third_party/$ENGINE/references/settings.md" | tail -1 | cut -d: -f1)"
command_line="$(printf '%s' "$err" | grep -nF -- "$RSYNC_COMMAND" | tail -1 | cut -d: -f1)"
((cost_line < command_line)) ||
  fail "tracked-ahead confirmed" "the cost list must print ABOVE the command, not below it"
ok "--confirm-mirror-is-newer names what dies above the command, and flags the contradiction"

# ── a merged commit that REMOVES engine content ───────────────────────────
# The shape that defeats a content-only test. The mirror holds the removed line,
# so it is the side with extra content and the rsync would delete nothing — yet
# running it re-adds what the merge deleted.
root="$(new_fixture merged-deletion)"
set_refresh "$root" "$REFRESH"
printf 'shared line\nretired setting\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
commit_tracked "$root" "$COMMIT_NEW"
run_check "$root"
expect_rc "$rc" 1 "merged deletion"
expect_contains "$err" "$READING_TRACKED_AHEAD" "merged deletion"
expect_contains "$err" "$REPAIR_REFRESH_SOLE" "merged deletion"
expect_absent "$err" "$RSYNC_COMMAND" "merged deletion"
ok "a merged deletion names vstack refresh alone, though the rsync would delete nothing"

# The same fixture with the operator OVERRIDING the direction — the branch no
# case drove, and the one the incident actually walks: a merged commit removed
# engine content, so the mirror is the side holding it, the rsync deletes
# nothing, and running it restores what the merge removed. The cost is real and
# it is not a deletion, so a report that can only describe deletions describes
# this one as nothing.
run_check "$root" --confirm-mirror-is-newer
expect_rc "$rc" 1 "merged deletion confirmed"
expect_contains "$err" "$RSYNC_COMMAND" "merged deletion confirmed"
expect_contains "$err" "CONTRADICTS" "merged deletion confirmed"
# What the command DOES here, named on the command's own screen rather than
# inferable from the diff further up: it reverts, and the check then passes on
# the reverted content — which is the whole failure mode this check exists for.
expect_contains "$err" "It REVERTS the commit above" "merged deletion confirmed"
expect_contains "$err" "GREEN on the reverted content" "merged deletion confirmed"
# And the impact must sit ABOVE the command, for the same reason the cost list
# does in the tracked-only case: below it, the paste has already happened.
impact_line="$(printf '%s' "$err" | grep -nF -- "It REVERTS the commit above" | tail -1 | cut -d: -f1)"
command_line="$(printf '%s' "$err" | grep -nF -- "$RSYNC_COMMAND" | tail -1 | cut -d: -f1)"
((impact_line < command_line)) ||
  fail "merged deletion confirmed" "the impact must print ABOVE the command, not below it"
ok "an overridden merged deletion names the revert it performs, above the command"

# ── a merged commit that REMOVES A FILE, read after a later refresh ───────
# The same removal read where the vendoring commit predates the refresh — a
# fresh clone, or a new worktree. `diff -r` reports it as `Only in <mirror>`, so
# nothing is tracked-only and the rsync would delete no file; running it still
# restores what the merge deleted, whereupon the copies agree and the check goes
# green on the reverted content.
root="$(new_fixture merged-file-deletion)"
printf 'retired predicate fixture\n' >"$root/.agents/skills/$ENGINE/references/error-patterns.md"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "merged file deletion"
expect_contains "$err" "$REPAIR_REFRESH_BOTH" "merged file deletion"
expect_contains "$err" "$RSYNC_CONDITION" "merged file deletion"
expect_contains "$err" "(1) If the TRACKED copy is newer" "merged file deletion"
expect_contains "$err" "NOT THE SAME AS LOSING NOTHING" "merged file deletion"
expect_contains "$err" "Only in .agents/skills/$ENGINE" "merged file deletion"
saw_verdict "the evidence is CONSISTENT WITH the MIRROR being newer"
ok "a merged file removal never yields the rsync as the sole repair, nor a claim it is lossless"

# ── the ordinary case: mirror ahead ───────────────────────────────────────
root="$(new_fixture mirror-ahead)"
commit_tracked "$root" "$COMMIT_OLD"
printf 'shared line\nnew upstream line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "mirror-ahead"
expect_contains "$err" "the evidence is CONSISTENT WITH the MIRROR being newer" "mirror-ahead"
expect_contains "$err" "$REPAIR_REFRESH_BOTH" "mirror-ahead"
expect_contains "$err" "$RSYNC_CONDITION" "mirror-ahead"
expect_contains "$err" "$RSYNC_COMMAND" "mirror-ahead"
# Both of the command's paths are repo-relative and every VGS worktree has an
# .agents symlink and a third_party/ tree, so pasted into a different worktree
# it would succeed THERE. It carries its own tree for that reason.
expect_contains "$err" "cd -- $root" "mirror-ahead"
ok "favourable evidence prints both repairs, the rsync conditioned and rooted in its own tree"

# ── refresh newer, but the tracked copy still holds content ───────────────
# The pull-after-refresh shape: the timestamps favour the mirror and the content
# favours the tracked copy. Neither half decides alone, so the check refuses.
root="$(new_fixture undetermined)"
printf 'shared line\ntracked-only line\n' \
  >"$root/third_party/$ENGINE/references/settings.md"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "undetermined"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "undetermined"
expect_contains "$err" "$REPAIR_REFRESH_BOTH" "undetermined"
expect_absent "$err" "$RSYNC_COMMAND" "undetermined"
expect_contains "$err" "$AT_RISK_PREFIX""third_party/$ENGINE/references/settings.md" "undetermined"
expect_contains "$err" "--confirm-mirror-is-newer" "undetermined"
# The other half of the --help promise, asserted where this state is produced:
# withheld only where the tracked copy holds content the command would destroy.
help_text="$("$repo_root/scripts/check-review-gate-vendor.sh" --help)"
expect_contains "$help_text" "The rsync is WITHHELD only" "undetermined"
expect_contains "$help_text" "where the tracked copy holds content the command would destroy" "undetermined"
saw_verdict "which side is newer is NOT ESTABLISHED"
ok "timestamps and content disagreeing withholds the rsync and names what it would delete"

# Asserting the direction releases the command — and must not hide its cost.
run_check "$root" --confirm-mirror-is-newer
expect_rc "$rc" 1 "undetermined confirmed"
expect_contains "$err" "$RSYNC_COMMAND" "undetermined confirmed"
expect_contains "$err" "It DESTROYS:" "undetermined confirmed"
expect_contains "$err" "$AT_RISK_PREFIX""third_party/$ENGINE/references/settings.md" "undetermined confirmed"
ok "--confirm-mirror-is-newer releases the rsync, still under the list of what it destroys"

# ── a tracked-only FILE, not just a tracked-only line ─────────────────────
root="$(new_fixture tracked-only-file)"
printf 'new predicate fixture\n' >"$root/third_party/$ENGINE/references/error-patterns.md"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "tracked-only file"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "tracked-only file"
expect_absent "$err" "$RSYNC_COMMAND" "tracked-only file"
expect_contains "$err" "$AT_RISK_PREFIX""third_party/$ENGINE/references/error-patterns.md" "tracked-only file"
ok "a file only the tracked copy has counts as content the rsync would delete"

# ── a difference diff declines to show as content ─────────────────────────
# Binary files yield only "Binary files A and B differ", which names no side.
# That reaches the fail-closed default, and must withhold rather than release.
root="$(new_fixture binary-drift)"
printf '\x00\x01tracked\x00' >"$root/third_party/$ENGINE/references/fixture.bin"
printf '\x00\x01mirror\x00' >"$root/.agents/skills/$ENGINE/references/fixture.bin"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "binary drift"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "binary drift"
expect_absent "$err" "$RSYNC_COMMAND" "binary drift"
expect_contains "$err" "$AT_RISK_PREFIX""Binary files" "binary drift"
expect_contains "$err" "third_party/$ENGINE/references/fixture.bin" "binary drift"
ok "a binary difference names no side, so it is treated as content the rsync would delete"

# ── a shape the parser has no arm for at all ──────────────────────────────
# File on one side, directory on the other: GNU diff emits the SINGULAR "File A
# is a regular file while file B is a directory", which matches no marker the
# classifier knows. The default arm is what makes that safe.
root="$(new_fixture file-vs-directory)"
printf 'a plain file\n' >"$root/.agents/skills/$ENGINE/references/thing"
mkdir -p "$root/third_party/$ENGINE/references/thing"
printf 'inside\n' >"$root/third_party/$ENGINE/references/thing/inner"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "file vs directory"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "file vs directory"
expect_absent "$err" "$RSYNC_COMMAND" "file vs directory"
expect_contains "$err" "$AT_RISK_PREFIX""File .agents/skills/$ENGINE" "file vs directory"
expect_contains "$err" "is a regular file while file" "file vs directory"
ok "an unrecognised diff line is treated as content at risk, not as nothing"

# ── preconditions ─────────────────────────────────────────────────────────
root="$(new_fixture missing-mirror)"
commit_tracked "$root" "$COMMIT_OLD"
rm -rf "${root:?}/.agents/skills/$ENGINE"
run_check "$root"
expect_rc "$rc" 1 "missing mirror"
expect_contains "$err" "no vstack copy at .agents/skills/$ENGINE" "missing mirror"
run_check "$root" --allow-missing-source
expect_rc "$rc" 0 "missing mirror allowed"
expect_contains "$out" "drift was NOT checked" "missing mirror allowed"
ok "a missing mirror fails, and --allow-missing-source says the comparison did not happen"

root="$(new_fixture missing-tracked)"
rm -rf "${root:?}/third_party/$ENGINE"
run_check "$root"
expect_rc "$rc" 1 "missing tracked"
expect_contains "$err" "CI has nothing to run" "missing tracked"
run_check "$root" --allow-missing-source
expect_rc "$rc" 1 "missing tracked allowed"
ok "a missing vendored copy fails even with --allow-missing-source: CI would have nothing"

root="$(new_fixture bad-option)"
commit_tracked "$root" "$COMMIT_OLD"
run_check "$root" --not-an-option
expect_rc "$rc" 2 "bad option"
expect_contains "$err" "unknown option: --not-an-option" "bad option"
ok "an unrecognised option is a usage error, not a reading"

# ── the two real checks, RUN rather than read ─────────────────────────────
# Reading each wrapper's text proved only that the text was there: replacing the
# call with `exit 0` left the arm green while the wrapper became a no-op
# reporting success forever. Both probes below are hermetic — option parsing
# precedes every directory check — so they exercise the real entry point.
while IFS='|' read -r script prog engine; do
  [[ -n "$script" ]] || continue
  wrc=0
  wout="$("$repo_root/$script" --not-an-option 2>&1)" || wrc=$?
  expect_rc "$wrc" 2 "wiring $script"
  expect_contains "$wout" "$prog: unknown option: --not-an-option" "wiring $script"

  hrc=0
  hout="$("$repo_root/$script" --help 2>&1)" || hrc=$?
  expect_rc "$hrc" 0 "wiring $script"
  expect_contains "$hout" "third_party/$engine" "wiring $script"
  expect_contains "$hout" ".agents/skills/$engine" "wiring $script"
  # --help describes the three readings, so it must name the three the check
  # actually prints. It once described a superseded single-repair design, which
  # is the VGS-155 defect class in the operator text rather than the output.
  for verdict in "${VERDICTS[@]}"; do
    expect_contains "$hout" "$verdict" "wiring $script"
  done
  [[ -d "$repo_root/third_party/$engine" ]] ||
    fail "wiring $script" "names engine $engine, but third_party/$engine does not exist"
done <<'WIRING'
scripts/check-review-gate-vendor.sh|check-review-gate-vendor|review-gate
scripts/check-size-ratchet-vendor.sh|check-size-ratchet-vendor|size-ratchet
WIRING
ok "both wrappers run, reach the engine under their own name, and carry their own tree"

# ── diff itself could not compare the two copies ──────────────────────────
# `rc > 1` is diff reporting trouble, not a difference. It must fail with that
# named cause rather than classifying an empty diff and printing a repair
# derived from nothing.
root="$(new_fixture diff-error)"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
printf 'mirror side\n' >"$root/.agents/skills/$ENGINE/references/locked.md"
printf 'tracked side\n' >"$root/third_party/$ENGINE/references/locked.md"
chmod 000 "$root/.agents/skills/$ENGINE/references/locked.md"
# It must be a file diff OPENS: `diff -r` never descends into a directory that
# exists on one side only, so an unreadable directory reports "Only in ..." and
# exits 1 instead. And the fixture only proves something if the file really
# became unreadable — it does not, for root — so that is checked rather than
# assumed, and can never pass by silently testing nothing.
if cat "$root/.agents/skills/$ENGINE/references/locked.md" >/dev/null 2>&1; then
  fail "diff error" "fixture precondition unmet: the unreadable file is still readable"
else
  run_check "$root"
  expect_rc "$rc" 1 "diff error"
  expect_contains "$err" "diff could not compare the two copies" "diff error"
  expect_absent "$err" "$DRIFT_BANNER" "diff error"
  expect_absent "$err" "$RSYNC_COMMAND" "diff error"
fi
chmod 644 "$root/.agents/skills/$ENGINE/references/locked.md"
ok "a diff that could not compare is reported as that, not as a drift with a repair"

# ── the engine under a wrapper's own call shape ───────────────────────────
# run_check invokes vendor_drift_main as `out="$(...)" || rc=$?`, and bash
# SUSPENDS errexit for a call whose status is tested that way; the wrappers call
# it bare, where errexit is live. A statement that legitimately evaluates false
# can abort the check in production and stay invisible here — which is how the
# classifier's result-parsing line first behaved. So one drift runs as a real
# wrapper PROCESS, on the shape whose at-risk list is empty.
root="$(new_wrapper_fixture wrapper-process)"
commit_tracked "$root" "$COMMIT_OLD"
printf 'shared line\nnew upstream line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
set_refresh "$root" "$REFRESH"
prc=0
pout="$("$root/scripts/check-demo-vendor.sh" 2>&1)" || prc=$?
expect_rc "$prc" 1 "wrapper process"
expect_contains "$pout" "the evidence is CONSISTENT WITH the MIRROR being newer" "wrapper process"
expect_contains "$pout" "$REPAIR_REFRESH_BOTH" "wrapper process"
expect_contains "$pout" "$RSYNC_CONDITION" "wrapper process"
ok "a real wrapper process reports the whole drift, with errexit live throughout"

# ── the classifier breaks its own contract ────────────────────────────────
# vendor_drift_classify emits only yes or no today, so no real input reaches
# this branch — it defends against a future change to that contract, which is
# exactly the change most likely to break it unnoticed. Driven by shadowing the
# function in the live shell the suite sources it into, the same technique the
# evidence suite uses for its PATH git stub. The fixture is mirror-ahead shaped,
# so WITHOUT the guard this input prints the runnable rsync.
root="$(new_fixture classifier-contract)"
commit_tracked "$root" "$COMMIT_OLD"
printf 'shared line\nnew upstream line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
set_refresh "$root" "$REFRESH"
real_classify="$(declare -f vendor_drift_classify)"
vendor_drift_classify() { printf 'maybe\nsome unparsed thing\n'; }
run_check "$root"
eval "$real_classify"
expect_rc "$rc" 1 "classifier contract"
expect_contains "$err" "WARNING: the drift classifier answered" "classifier contract"
expect_absent "$err" "$RSYNC_COMMAND" "classifier contract"
# And the restore worked, or every case after this one is testing a stub.
classify_probe="$(vendor_drift_classify "third_party/$ENGINE" ".agents/skills/$ENGINE" <<<" context")"
[[ "$classify_probe" == no ]] ||
  fail "classifier contract" "the real classifier was not restored (probe: $classify_probe)"
ok "an answer that is neither yes nor no is treated as destructive, not as nothing"


# ── --help promises what the readings actually print ──────────────────────
# The sentence describing the destructive command was wrong in three
# consecutive cycles, because nothing executed it. This does, from both sides:
# each state asserts what the RUN does AND the phrase --help uses to promise it,
# so changing either one alone fails. The state that broke it three times is the
# first — undetermined with nothing at risk, where the rsync prints and the old
# text called it withheld.
root="$(new_fixture help-nothing-at-risk)"
commit_tracked "$root" "$REFRESH"
printf 'shared line\nnew upstream line\n' >"$root/.agents/skills/$ENGINE/references/settings.md"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "help vs readings"
expect_contains "$err" "$RSYNC_CONDITION" "help vs readings"
expect_absent "$err" "WITHHELD" "help vs readings"
# Single-line fragments: a phrase spanning a wrap asserts the wrapping.
expect_contains "$help_text" "the rsync prints under condition (2) with" "help vs readings"
expect_contains "$help_text" "no flag required, because copying across would destroy nothing." "help vs readings"

ok "--help promises what each reading prints, checked from both sides"

# ── liveness: every reading this file names was actually produced ─────────
for verdict in "${VERDICTS[@]}"; do
  case $'\n'"$verdicts_seen" in
    *$'\n'"$verdict"$'\n'*) ;;
    *) fail "liveness" "no case reached the reading \"$verdict\"; the control asserting it is absent is vacuous" ;;
  esac
done
ok "all three readings are reached, so the in-sync control is not vacuous"

if ((failures > 0)); then
  printf 'test-vendor-drift: FAIL (%d)\n' "$failures" >&2
  exit 1
fi
printf 'test-vendor-drift: ok\n'
