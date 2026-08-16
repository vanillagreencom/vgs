#!/usr/bin/env bash
# The harness scripts/test-vendor-drift.sh and
# scripts/test-vendor-drift-classify.sh run their cases through: assertion
# helpers, the fixture builders, and the three invariants that hold for EVERY
# case rather than for the ones that remember to check.
#
# Split out of that file when it crossed the size-ratchet threshold, at the seam
# between the machinery and the cases. The invariants live here deliberately:
# they are the acceptance bar for the whole check, so they belong where no new
# case can be written without them applying.
#
# Requires, from the sourcing script: repo_root, tmp, PROG, ENGINE.
#
# Same reason as the other two libs state them: sourced files inherit the
# caller's options, and setting them here keeps that a guarantee.
set -euo pipefail

# Fail at source time with a named cause when the sourcing script forgot one of
# these, instead of at first use with an empty path or a bare command-not-found.
repo_root="${repo_root:?scripts/lib/vendor-drift-test.sh: sourcing script must set repo_root first}"
tmp="${tmp:?scripts/lib/vendor-drift-test.sh: sourcing script must set tmp first}"
PROG="${PROG:?scripts/lib/vendor-drift-test.sh: sourcing script must set PROG first}"
ENGINE="${ENGINE:?scripts/lib/vendor-drift-test.sh: sourcing script must set ENGINE first}"

failures=0
case_failed=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
  case_failed=1
}
ok() {
  if [[ $case_failed -eq 0 ]]; then
    printf '  ok    %s\n' "$1"
  fi
  case_failed=0
}
expect_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3" "expected to contain: $2"$'\n'"--- got ---"$'\n'"$1"
}
expect_absent() {
  [[ "$1" != *"$2"* ]] || fail "$3" "expected NOT to contain: $2"$'\n'"--- got ---"$'\n'"$1"
}
expect_rc() {
  [[ "$1" == "$2" ]] || fail "$3" "expected exit $2, got $1"
}

# Every verdict this file drives the engine to produce. Used twice: as the
# noise list the in-sync control asserts is ABSENT, and as a liveness list —
# a verdict no case reaches is a case that stopped testing what it names.
# shellcheck disable=SC2034 # read by the cases in scripts/test-vendor-drift.sh,
# which sources this file; shellcheck lints the two separately.
VERDICTS=(
  "the TRACKED copy is newer"
  "the evidence is CONSISTENT WITH the MIRROR being newer"
  "which side is newer is NOT ESTABLISHED"
)

# The condition every printed rsync must sit behind. The acceptance bar is that
# the destructive half is never the default or an unconditioned repair, so
# "the rsync appeared" is only ever asserted together with this.
RSYNC_CONDITION="(2) If the MIRROR is newer"

# Safety claims the check must never make about the mirror-to-tracked rsync. In
# a deletion-shaped drift the rsync genuinely deletes nothing and still reverts
# a merged removal, so "loses nothing" is false exactly where it reads most
# reassuring.
SAFETY_CLAIMS=(
  "loses nothing"
  "would delete nothing"
  "copying it across loses nothing"
)
verdicts_seen=""
saw_verdict() { verdicts_seen+="$1"$'\n'; }

RSYNC_COMMAND="rsync -a --delete --exclude=.vstack-refreshed"

# The two repair LINES, with the prefix the check actually prints. Asserting the
# bare words "vstack refresh" proves nothing: they also appear in the prose of
# the tracked-ahead reading and of condition (2), so an assertion on the phrase
# stayed green with both repair lines deleted and the check naming no runnable
# command at all.
REPAIR_REFRESH_SOLE="$PROG:   vstack refresh"
REPAIR_REFRESH_BOTH="$PROG:       vstack refresh"

# Scopes the "names a repair" invariant to runs that actually reported drift;
# the precondition failures (missing mirror, missing vendored copy) carry their
# own guidance instead.
DRIFT_BANNER="has drifted from the vstack copy"

# The prefix vendor_drift_print_at_risk gives every entry it lists. Assertions
# about "what the rsync would delete" must use it: each of those paths also
# appears in the diff printed above, so a bare path is satisfied by the diff and
# stays green with the cost list removed.
# shellcheck disable=SC2034 # read by the cases across the source seam.
AT_RISK_PREFIX="$PROG:        "

# ── fixtures ──────────────────────────────────────────────────────────────
# One repo per case. `git init` and a real commit are the point: the direction
# evidence is a commit time compared against a refresh mtime, so a fixture that
# faked either would prove nothing about the comparison that runs for real.
new_fixture() {
  local root="$tmp/$1"
  mkdir -p "$root/third_party/$ENGINE/references" "$root/.agents/skills/$ENGINE/references"
  git -C "$root" init -q -b main
  git -C "$root" config user.email test@example.invalid
  git -C "$root" config user.name "vendor drift test"
  git -C "$root" config commit.gpgsign false
  printf 'shared line\n' >"$root/third_party/$ENGINE/references/settings.md"
  printf 'shared line\n' >"$root/.agents/skills/$ENGINE/references/settings.md"
  printf '%s' "$root"
}

commit_tracked() {
  local root="$1" epoch="$2"
  git -C "$root" add -A
  GIT_AUTHOR_DATE="@$epoch +0000" GIT_COMMITTER_DATE="@$epoch +0000" \
    git -C "$root" commit -q -m "vendor $ENGINE"
}

set_refresh() {
  local root="$1" epoch="$2"
  printf '0000000\n' >"$root/.agents/skills/$ENGINE/.vstack-refreshed"
  touch -d "@$epoch" "$root/.agents/skills/$ENGINE/.vstack-refreshed"
}

rc=0
out=""
err=""
run_check() {
  local root="$1"
  shift
  rc=0
  # shellcheck disable=SC2034 # rc, out and err are the case-facing results of
  # this call, read across the source seam.
  out="$(vendor_drift_main "$PROG" "$ENGINE" "$root" "$@" 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"

  # THE ACCEPTANCE BAR, ASSERTED ON EVERY RUN rather than case by case: the
  # destructive command may never appear as a default or unconditioned repair.
  # Either the condition that selects it is printed with it, or the operator
  # asserted the direction on this very invocation. A future case that forgets
  # to check this still cannot slip an unconditioned rsync past.
  if [[ "$out$err" == *"$RSYNC_COMMAND"* ]] &&
    [[ " $* " != *" --confirm-mirror-is-newer "* ]] &&
    [[ "$out$err" != *"$RSYNC_CONDITION"* ]]; then
    fail "rsync invariant" "the rsync was printed with neither its condition nor an operator assertion"
  fi

  # A drift the check calls lossless is a drift it has decided is safe to
  # overwrite, and the deletion shape proves it cannot know that.
  local claim
  for claim in "${SAFETY_CLAIMS[@]}"; do
    if [[ "$out$err" == *"$claim"* ]]; then
      fail "safety-claim invariant" "the output claims \"$claim\" about adopting the mirror"
    fi
  done

  # A reported drift that names no runnable command leaves the operator with a
  # diagnosis and no repair. Deleting both `vstack refresh` lines used to pass
  # every case in the suite; this is what makes that impossible.
  if [[ "$out$err" == *"$DRIFT_BANNER"* ]] &&
    [[ "$out$err" != *"$REPAIR_REFRESH_SOLE"* ]] &&
    [[ "$out$err" != *"$REPAIR_REFRESH_BOTH"* ]] &&
    [[ "$out$err" != *"$RSYNC_COMMAND"* ]]; then
    fail "repair invariant" "drift was reported but no runnable repair line was printed"
  fi
}

# A fixture that is NOT a git repository, for the evidence-unreadable path.
new_fixture_nogit() {
  local root="$tmp/$1"
  mkdir -p "$root/third_party/$ENGINE/references" "$root/.agents/skills/$ENGINE/references"
  printf 'shared line\n' >"$root/third_party/$ENGINE/references/settings.md"
  printf 'shared line\n' >"$root/.agents/skills/$ENGINE/references/settings.md"
  printf '%s' "$root"
}


# A fixture repo laid out like this one, carrying copies of the two libraries
# and a wrapper derived from the real one — same strict mode, same repo_root
# computation, same source line — so a case can drive the engine as a PROCESS
# under the call shape the wrappers use.
new_wrapper_fixture() {
  local root lib
  root="$(new_fixture "$1")"
  mkdir -p "$root/scripts/lib"
  for lib in vendor-drift.sh vendor-drift-report.sh; do
    cp "$repo_root/scripts/lib/$lib" "$root/scripts/lib/$lib"
  done
  sed "s|^vendor_drift_main .*|vendor_drift_main $PROG $ENGINE \"\$repo_root\" \"\$@\"|" \
    "$repo_root/scripts/check-review-gate-vendor.sh" >"$root/scripts/check-demo-vendor.sh"
  chmod +x "$root/scripts/check-demo-vendor.sh"
  printf '%s' "$root"
}

CONFIRM_FLAG="--confirm-mirror-is-newer"

# Which of the given files could RUN the flag. Comment lines are stripped first:
# a synopsis that MENTIONS it is documentation. A trailing comment still counts
# as a carrier, which errs toward reporting.
flag_carriers() {
  local file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    grep -nF -- "$CONFIRM_FLAG" "$file" 2>/dev/null |
      grep -vE '^[0-9]+:[[:space:]]*#' |
      sed "s|^|$file:|" || true
  done
}
