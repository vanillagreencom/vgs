#!/usr/bin/env bash
# Must-fail controls for scripts/lib/vendor-drift.sh, the shared engine behind
# scripts/check-review-gate-vendor.sh and scripts/check-size-ratchet-vendor.sh
# (VGS-155).
#
# THE BUG THIS EXISTS FOR. The check used to print the mirror-to-tracked rsync
# unconditionally, as a procedure. Immediately after a vendoring PR merged, the
# tracked copy was the NEWER side, so running that command deleted the merged
# engine change — and the check then passed, because the two copies agreed
# again. Every case below is written so that reintroducing an unconditional
# repair fails at least one of them: the destructive command must be absent
# where it would lose content, present where it cannot, and the verdict must
# name which side the evidence says is newer.
#
# Fixture-driven throughout: each case builds a throwaway repo with its own
# third_party/<engine> and .agents/skills/<engine>, its own commit time and its
# own refresh-marker mtime, so this runs anywhere — no vstack, no .agents mirror,
# no network. The two real checks are covered by the static arm at the end,
# which is what stops one of them from being wired to the other's engine.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

# shellcheck source=scripts/lib/vendor-drift.sh
source "$repo_root/scripts/lib/vendor-drift.sh"

PROG=check-demo-vendor
ENGINE=demo-engine

# Fixed epochs, so the verdicts depend on the ORDER this file states and never
# on when it runs. REFRESH sits between the two commit times, which is what
# makes "commit before the refresh" and "commit after the refresh" two cases
# rather than a race.
COMMIT_OLD=1700000000 # 2023-11-14T22:13:20Z
REFRESH=1700003600
COMMIT_NEW=1700007200

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
ok "matching copies pass, and print no verdict and no repair"

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
expect_contains "$err" "the TRACKED copy is newer" "tracked-ahead"
expect_contains "$err" "vstack refresh" "tracked-ahead"
expect_absent "$err" "$RSYNC_COMMAND" "tracked-ahead"
saw_verdict "the TRACKED copy is newer"
ok "a commit after the last refresh routes to vstack refresh, with no rsync printed"

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
ok "--confirm-mirror-is-newer prints the rsync but flags the contradicting evidence"

# ── a merged commit that REMOVES engine content ───────────────────────────
# The shape that defeats a content-only test. The mirror holds the removed line,
# so it is the side with extra content and the rsync would delete nothing — yet
# running it re-adds what the merge deleted. Only the timestamp evidence
# separates this from an upstream addition, which is why it is read first.
root="$(new_fixture merged-deletion)"
set_refresh "$root" "$REFRESH"
printf 'shared line\nretired setting\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
commit_tracked "$root" "$COMMIT_NEW"
run_check "$root"
expect_rc "$rc" 1 "merged deletion"
expect_contains "$err" "the TRACKED copy is newer" "merged deletion"
expect_contains "$err" "vstack refresh" "merged deletion"
expect_absent "$err" "$RSYNC_COMMAND" "merged deletion"
ok "a merged deletion routes to vstack refresh, though the rsync would delete nothing"

# ── a merged commit that REMOVES A FILE, read after a later refresh ───────
# The reported P1 shape, at file granularity: the tracked copy dropped a file,
# the mirror still carries it, and the refresh marker is newer. `diff -r` reports
# it as `Only in <mirror>`, so NOTHING is tracked-only, the rsync would delete no
# file — and running it restores the file the merge deleted, whereupon the two
# copies agree and the check goes green on the reverted content.
#
# The old behavior named that rsync as the SOLE repair and called it lossless.
# Both halves are asserted here: the repair set, and the absence of any safety
# claim about it.
root="$(new_fixture merged-file-deletion)"
printf 'retired predicate fixture\n' >"$root/.agents/skills/$ENGINE/references/error-patterns.md"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "merged file deletion"
# Not the sole repair: the non-destructive branch is present, and the rsync sits
# behind its condition rather than being handed over as the answer.
expect_contains "$err" "vstack refresh" "merged file deletion"
expect_contains "$err" "$RSYNC_CONDITION" "merged file deletion"
expect_contains "$err" "(1) If the TRACKED copy is newer" "merged file deletion"
# And no claim that adopting the mirror costs nothing.
for claim in "${SAFETY_CLAIMS[@]}"; do
  expect_absent "$err" "$claim" "merged file deletion"
done
expect_contains "$err" "NOT THE SAME AS LOSING NOTHING" "merged file deletion"
expect_contains "$err" "Only in .agents/skills/$ENGINE" "merged file deletion"
ok "a merged file removal never yields the rsync as the sole repair, nor a claim it is lossless"

# ── the ordinary case: mirror ahead ───────────────────────────────────────
# THE INVERSION, and why this reading may not name a repair alone: byte for
# byte this fixture is the case above, read where the vendoring commit predates
# the last refresh — a fresh clone, or a new worktree. The timestamps now favour
# the mirror and the rsync still deletes nothing, yet it could equally be the
# merged deletion above. So both repairs, each conditioned.
root="$(new_fixture mirror-ahead)"
commit_tracked "$root" "$COMMIT_OLD"
printf 'shared line\nnew upstream line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "mirror-ahead"
expect_contains "$err" "the evidence is CONSISTENT WITH the MIRROR being newer" "mirror-ahead"
# Both repairs, and the destructive one only behind its condition. Asserting the
# rsync alone would pass on the pre-VGS-155 behavior this file exists to forbid.
expect_contains "$err" "vstack refresh" "mirror-ahead"
expect_contains "$err" "$RSYNC_CONDITION" "mirror-ahead"
expect_contains "$err" "$RSYNC_COMMAND" "mirror-ahead"
expect_contains "$err" ".agents/skills/$ENGINE/ third_party/$ENGINE/" "mirror-ahead"
saw_verdict "the evidence is CONSISTENT WITH the MIRROR being newer"
ok "favourable evidence still prints both repairs, the rsync only behind its condition"

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
expect_contains "$err" "vstack refresh" "undetermined"
expect_absent "$err" "$RSYNC_COMMAND" "undetermined"
expect_contains "$err" "third_party/$ENGINE/references/settings.md" "undetermined"
expect_contains "$err" "--confirm-mirror-is-newer" "undetermined"
saw_verdict "which side is newer is NOT ESTABLISHED"
ok "timestamps and content disagreeing withholds the rsync and names what it would delete"

run_check "$root" --confirm-mirror-is-newer
expect_rc "$rc" 1 "undetermined confirmed"
expect_contains "$err" "$RSYNC_COMMAND" "undetermined confirmed"
ok "--confirm-mirror-is-newer releases the withheld rsync"

# ── a tracked-only FILE, not just a tracked-only line ─────────────────────
# `diff -r` reports this as `Only in ...` rather than as `+` lines, so it is a
# separate arm of the classifier; missing it would call a deleting rsync safe.
root="$(new_fixture tracked-only-file)"
printf 'new predicate fixture\n' >"$root/third_party/$ENGINE/references/error-patterns.md"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "tracked-only file"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "tracked-only file"
expect_absent "$err" "$RSYNC_COMMAND" "tracked-only file"
expect_contains "$err" "third_party/$ENGINE/references/error-patterns.md" "tracked-only file"
ok "a file only the tracked copy has counts as content the rsync would delete"

# ── uncommitted tracked changes ───────────────────────────────────────────
# The commit time stops describing what is on disk, so the newest-commit
# evidence is not usable and the check must not claim a direction from it.
root="$(new_fixture dirty-tracked)"
set_refresh "$root" "$REFRESH"
commit_tracked "$root" "$COMMIT_NEW"
printf 'shared line\nedited in the working tree\n' \
  >"$root/third_party/$ENGINE/references/settings.md"
run_check "$root"
expect_rc "$rc" 1 "dirty tracked"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "dirty tracked"
expect_contains "$err" "uncommitted changes" "dirty tracked"
expect_absent "$err" "$RSYNC_COMMAND" "dirty tracked"
ok "uncommitted changes under third_party disqualify the commit-time evidence"

# ── no history at all ─────────────────────────────────────────────────────
root="$(new_fixture uncommitted)"
printf 'shared line\ntracked-only line\n' \
  >"$root/third_party/$ENGINE/references/settings.md"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "no history"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "no history"
expect_contains "$err" "no commit in this repository touches third_party/$ENGINE" "no history"
expect_absent "$err" "$RSYNC_COMMAND" "no history"
ok "a tracked copy with no commit history yields no direction and no rsync"

# ── preconditions ─────────────────────────────────────────────────────────
root="$(new_fixture missing-mirror)"
commit_tracked "$root" "$COMMIT_OLD"
rm -rf "$root/.agents/skills/$ENGINE"
run_check "$root"
expect_rc "$rc" 1 "missing mirror"
expect_contains "$err" "no vstack copy at .agents/skills/$ENGINE" "missing mirror"
run_check "$root" --allow-missing-source
expect_rc "$rc" 0 "missing mirror allowed"
expect_contains "$out" "drift was NOT checked" "missing mirror allowed"
ok "a missing mirror fails, and --allow-missing-source says the comparison did not happen"

root="$(new_fixture missing-tracked)"
rm -rf "$root/third_party/$ENGINE"
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
ok "an unrecognised option is a usage error, not a verdict"

# ── the decision table, driven directly ───────────────────────────────────
# The fixtures above cover the shapes that occur; this covers the rows they
# cannot reach cheaply, above all the PURE DELETION: a commit that REMOVES
# engine content leaves the mirror holding the only extra bytes, so the content
# test alone reads it as "mirror ahead" and hands back the rsync that undoes the
# deletion. Timestamp evidence is checked first precisely for this row.
#              tracked_epoch  refresh_epoch  dirty    tracked_only  expected
table=(
  "$COMMIT_NEW $REFRESH    no      no       tracked-ahead"
  "$COMMIT_NEW $REFRESH    no      yes      tracked-ahead"
  "$COMMIT_OLD $REFRESH    no      no       mirror-ahead"
  "$COMMIT_OLD $REFRESH    no      yes      undetermined"
  "$COMMIT_OLD $REFRESH    yes     no       mirror-ahead"  # reading only; never a sole repair
  "$COMMIT_NEW $REFRESH    yes     no       undetermined"
  "$COMMIT_NEW $REFRESH    yes     yes      undetermined"
  "$COMMIT_NEW $REFRESH    unknown yes      undetermined"
  "$REFRESH    $REFRESH    no      no       undetermined"
  "$REFRESH    $REFRESH    no      yes      undetermined"
  "'' $REFRESH             no      no       undetermined"
  "$COMMIT_OLD ''          no      no       undetermined"
)
for row in "${table[@]}"; do
  # shellcheck disable=SC2086 # the row IS the argument list; splitting is the point
  set -- $row
  tracked_epoch="$1"
  [[ "$tracked_epoch" == "''" ]] && tracked_epoch=""
  refresh_epoch="$2"
  [[ "$refresh_epoch" == "''" ]] && refresh_epoch=""
  got="$(vendor_drift_direction "$tracked_epoch" "$refresh_epoch" "$3" "$4")"
  [[ "$got" == "$5" ]] || fail "decision table" "($1 $2 $3 $4) expected $5, got $got"
done
ok "the direction table answers every row as written, deletions included"

# ── the two real checks are wired to their own engines ────────────────────
# One file was copied from the other, so the failure worth guarding is a
# wrapper carrying the other's engine name: it would compare the wrong pair and
# report ok on a real drift.
while IFS='|' read -r script prog engine; do
  [[ -n "$script" ]] || continue
  text="$(cat "$repo_root/$script")"
  expect_contains "$text" "source \"\$repo_root/scripts/lib/vendor-drift.sh\"" "wiring $script"
  expect_contains "$text" "vendor_drift_main $prog $engine \"\$repo_root\" \"\$@\"" "wiring $script"
  [[ -d "$repo_root/third_party/$engine" ]] ||
    fail "wiring $script" "names engine $engine, but third_party/$engine does not exist"
done <<'WIRING'
scripts/check-review-gate-vendor.sh|check-review-gate-vendor|review-gate
scripts/check-size-ratchet-vendor.sh|check-size-ratchet-vendor|size-ratchet
WIRING
ok "both checks call the shared engine with their own name and their own vendored tree"

# ── liveness: every verdict this file names was actually produced ─────────
for verdict in "${VERDICTS[@]}"; do
  case $'\n'"$verdicts_seen" in
    *$'\n'"$verdict"$'\n'*) ;;
    *) fail "liveness" "no case reached the verdict \"$verdict\"; the control asserting it is absent is vacuous" ;;
  esac
done
ok "all three verdicts are reached, so the in-sync control is not vacuous"

if ((failures > 0)); then
  printf 'test-vendor-drift: FAIL (%d)\n' "$failures" >&2
  exit 1
fi
printf 'test-vendor-drift: ok\n'
