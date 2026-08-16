#!/usr/bin/env bash
# The operator-facing half of the vendor drift check: usage, the two sides and
# their labels, and the repair branches. scripts/lib/vendor-drift.sh holds the
# evidence and the decision and sources this file; this file is a LEAF and calls
# nothing back, so the pair has no cycle to resolve at call time.
#
# THE RULE, STATED ONCE, HERE. Everything else points at this paragraph. The
# mirror-to-tracked `rsync -a --delete` is the destructive half — it is what
# reverted a merged engine fix in VGS-155 — so it is never printed as a default
# or an unconditioned repair. It appears exactly three ways:
#
#   1. behind the numbered condition that selects it, when nothing it would
#      destroy could be found;
#   2. behind an operator asserting the direction with
#      --confirm-mirror-is-newer — and wherever there is anything to destroy,
#      under the list of it, on EVERY reading including tracked-ahead, which is
#      the invocation where the evidence is being overridden;
#   3. not at all — withheld, with that same list — when there is something to
#      destroy and the operator has asserted nothing.
#
# The list holds two kinds of entry: content attributed to the tracked side, and
# drift the classifier could not attribute to either. It is headed for both,
# because a heading naming only the first states the opposite of the truth for
# the second.
#
# A SINGLE repair is named only for `tracked-ahead`, and only while the operator
# has not asserted the opposite; what it names is the non-destructive half. No
# output claims that adopting the mirror costs nothing: in a deletion-shaped
# drift the rsync deletes nothing and still reverts a merged removal.
#
# Same reason as the other half sets these: sourced files inherit the caller's
# options, and stating them keeps that a guarantee rather than a coincidence.
set -euo pipefail

vendor_drift_usage() {
  local prog="$1" engine="$2"
  cat <<USAGE
$prog — assert third_party/$engine matches the vstack-managed
copy at .agents/skills/$engine.

  scripts/$prog.sh
  scripts/$prog.sh --allow-missing-source
      accept that the vstack copy is absent and the comparison did not happen
  scripts/$prog.sh --confirm-mirror-is-newer
      assert that the mirror is the newer side, so the mirror-to-tracked rsync
      is printed on every reading, including where it would destroy content —
      and wherever there is anything to destroy, the list of it prints above
      the command, never instead of it

On drift the check reports one of three readings, quoted here exactly as it
prints them, and each licenses a different repair:

  "the TRACKED copy is newer"
      \`vstack refresh\` is the only repair named, and copying the mirror across
      is warned against — unless you assert the direction with the flag above,
      which prints that command too, under what it destroys.
  "the evidence is CONSISTENT WITH the MIRROR being newer"
      both repairs, each behind the numbered condition that selects it; the
      rsync is the one the evidence favours.
  "which side is newer is NOT ESTABLISHED"
      both repairs print with their conditions. The rsync is WITHHELD only
      where the tracked copy holds content the command would destroy, and then
      that content is named. Where it holds none — which is every path that
      got here through unusable evidence, a dirty tree or a shallow clone or
      equal timestamps among them — the rsync prints under condition (2) with
      no flag required, because copying across would destroy nothing.

So the mirror-to-tracked rsync never appears as a default or an unconditioned
repair, and no output claims that adopting the mirror costs nothing.

Why the repair is not a constant: scripts/lib/vendor-drift-report.sh for what
may be printed, scripts/lib/vendor-drift.sh for how the side is decided and why
there are two copies at all (VGS-155).
USAGE
}

# Human-readable UTC for an epoch, or `unknown`. GNU `date` only, for the reason
# vendor_drift_mtime_epoch gives; a stamp is display, so a failure here prints
# the raw epoch rather than changing any reading.
vendor_drift_stamp() {
  local epoch="$1"
  [[ -n "$epoch" ]] || {
    printf 'unknown'
    return 0
  }
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "$epoch"
}

# The provenance of each side, then how to read the diff that follows.
#   $1 prog  $2 engine  $3 repo_root  $4 tracked_epoch  $5 refresh_epoch  $6 age_state
vendor_drift_print_sides() {
  local prog="$1" engine="$2" repo_root="$3"
  local tracked_epoch="$4" refresh_epoch="$5" age_state="$6"
  local tracked_rel="third_party/$engine" mirror_rel=".agents/skills/$engine"

  # Why the commit time is missing belongs beside the missing commit time.
  local dirty_note=""
  case "$age_state" in
    dirty) dirty_note=", plus uncommitted changes" ;;
    git-unreadable) dirty_note=", commit state unreadable" ;;
    shallow) dirty_note=" (shallow clone: no usable age)" ;;
    no-history) dirty_note=", no commit touches it here" ;;
  esac

  printf '%s:\n' "$prog"
  printf '%s: repository %s\n' "$prog" "$repo_root"
  printf '%s: tracked  %s/ — CI runs this; last commit %s%s\n' \
    "$prog" "$tracked_rel" "$(vendor_drift_stamp "$tracked_epoch")" "$dirty_note"
  printf '%s: mirror   %s/ — the vstack copy; last refreshed %s\n' \
    "$prog" "$mirror_rel" "$(vendor_drift_stamp "$refresh_epoch")"
  printf '%s:\n' "$prog"
  printf '%s: In the diff below:\n' "$prog"
  printf '%s:   - lines are only in %s/ (mirror)\n' "$prog" "$mirror_rel"
  printf '%s:   + lines are only in %s/ (tracked)\n' "$prog" "$tracked_rel"
  printf '%s:   "Only in DIR" names a whole file only that side has\n' "$prog"
}

# The destructive command. Printed only by the three routes named in the header,
# and always carrying the tree it belongs to: both its paths are repo-relative,
# every VGS worktree has an .agents symlink and a third_party/ tree, so pasted
# into a shell sitting in a different worktree it would succeed there — silently
# reverting engine content one worktree over.
vendor_drift_print_rsync() {
  local prog="$1" engine="$2" repo_root="$3" indent="${4:-  }"
  printf '%s: %scd -- %q \\\n' "$prog" "$indent" "$repo_root"
  printf '%s: %s  && rsync -a --delete --exclude=.vstack-refreshed \\\n' "$prog" "$indent"
  printf '%s: %s     .agents/skills/%s/ third_party/%s/\n' "$prog" "$indent" "$engine" "$engine"
}

# What the command would destroy, one entry per line, under a heading true of
# every entry it can contain. The list holds two kinds — a path the classifier
# attributed to the tracked side, and a raw line it could not attribute to
# either — and a heading naming only the first states the opposite of the truth
# for the second, which is how a MIRROR-side path once printed under "content
# only the tracked copy holds".
vendor_drift_print_at_risk() {
  local prog="$1" at_risk="$2" indent="${3:-    }" lead="${4:-    }" entry
  printf '%s: %scontent this check reads as tracked-side, or drift it could not\n' "$prog" "$lead"
  printf '%s: %sattribute to either side:\n' "$prog" "$lead"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    printf '%s: %s%s\n' "$prog" "$indent" "$entry"
  done <<<"$at_risk"
}

# Both repairs, each behind the condition that selects it, non-destructive
# first. Printed for every reading except `tracked-ahead`.
#   $1 prog  $2 engine  $3 repo_root  $4 confirm_mirror  $5 tracked_only  $6 at_risk
vendor_drift_print_both() {
  local prog="$1" engine="$2" repo_root="$3" confirm_mirror="$4" tracked_only="$5" at_risk="$6"

  printf '%s:\n' "$prog"
  printf '%s: (1) If the TRACKED copy is newer — the usual case right after a vendoring\n' "$prog"
  printf '%s:     PR merges — refresh the mirror. This deletes nothing:\n' "$prog"
  printf '%s:       vstack refresh\n' "$prog"
  printf '%s:\n' "$prog"

  if [[ "$tracked_only" != yes ]]; then
    printf '%s: (2) If the MIRROR is newer — the usual case right after vstack refresh\n' "$prog"
    printf '%s:     pulled an engine update — copy it across and commit the result:\n' "$prog"
    vendor_drift_print_rsync "$prog" "$engine" "$repo_root" "      "
    return 0
  fi

  # The cost list is printed on BOTH paths. Asserting the direction is what
  # releases the command, never what hides what it costs — the operator is one
  # flag from the destructive half exactly where the list is most useful.
  if [[ "$confirm_mirror" == true ]]; then
    printf '%s: (2) If the MIRROR is newer: you asserted that with\n' "$prog"
    printf '%s:     --confirm-mirror-is-newer, so here is the command. It DESTROYS:\n' "$prog"
    vendor_drift_print_at_risk "$prog" "$at_risk" "       " "     "
    vendor_drift_print_rsync "$prog" "$engine" "$repo_root" "      "
    return 0
  fi
  printf '%s: (2) If the MIRROR is newer, the repair is an rsync — WITHHELD here,\n' "$prog"
  printf '%s:     because it would destroy:\n' "$prog"
  vendor_drift_print_at_risk "$prog" "$at_risk" "       " "     "
  printf '%s:     Establish the direction first, then re-run with\n' "$prog"
  printf '%s:     --confirm-mirror-is-newer to print that command.\n' "$prog"
}

# The reading, and the repair or repairs it licenses.
#   $1 prog  $2 engine  $3 repo_root  $4 reading  $5 reason
#   $6 confirm_mirror  $7 tracked_only  $8 at_risk
vendor_drift_print_repairs() {
  local prog="$1" engine="$2" repo_root="$3" reading="$4" reason="$5"
  local confirm_mirror="$6" tracked_only="$7" at_risk="$8"
  local tracked_rel="third_party/$engine"

  printf '%s:\n' "$prog"
  case "$reading" in
    tracked-ahead)
      # The ONLY reading that names a single repair, and it is earned rather
      # than assumed. The evidence is a commit that landed after the mirror was
      # last written. A full fresh clone or a new worktree cannot fabricate
      # that, since a commit time is a property of history; an unreadable or
      # absent repository, an uncommitted tracked tree and a mirror with no
      # refresh marker are each answered as undetermined BEFORE this rule is
      # reached; and a SHALLOW clone — which genuinely can fabricate it, because
      # git reports the tip date for every path there — is answered the same
      # way, by vendor_drift_tracked_age, rather than being impossible. What
      # this rule names is also the non-destructive half, so being wrong costs a
      # no-op refresh and a second failing run, never content.
      printf '%s: the TRACKED copy is newer — it changed after the last vstack refresh.\n' "$prog"
      printf '%s: The mirror is the stale side, so refresh it:\n' "$prog"
      printf '%s:   vstack refresh\n' "$prog"
      printf '%s:\n' "$prog"
      # `vstack refresh` rewrites the mirror from the LOCAL vstack source
      # catalog, not from third_party/. A commit vendored from a newer vstack
      # than this machine has writes the OLDER engine back, and the check fails
      # again with the same advice — so the second step is named up front.
      printf '%s: If that leaves this check red, the local vstack source catalog is older\n' "$prog"
      printf '%s: than the vendored copy: update the vstack checkout (or\n' "$prog"
      printf '%s: vstack add --skill %s) and refresh again.\n' "$prog" "$engine"
      if [[ "$confirm_mirror" == true ]]; then
        printf '%s:\n' "$prog"
        printf '%s: --confirm-mirror-is-newer CONTRADICTS that evidence. If you are sure,\n' "$prog"
        printf '%s: this is the command. It DESTROYS:\n' "$prog"
        # The most dangerous invocation the tool has — the evidence says the
        # tracked copy is newer and the operator is overriding it — so this is
        # the LAST place the cost may be left implicit in a diff further up.
        [[ "$tracked_only" != yes ]] ||
          vendor_drift_print_at_risk "$prog" "$at_risk" "       " "  "
        vendor_drift_print_rsync "$prog" "$engine" "$repo_root"
      else
        printf '%s:\n' "$prog"
        printf '%s: Do NOT copy the mirror over %s/ here: that reverts the\n' "$prog" "$tracked_rel"
        printf '%s: commit above, and leaves this check GREEN on the reverted content.\n' "$prog"
      fi
      ;;
    mirror-ahead)
      printf '%s: the evidence is CONSISTENT WITH the MIRROR being newer: vstack refresh\n' "$prog"
      printf '%s: wrote it after the last commit that touched the tracked copy, and the\n' "$prog"
      printf '%s: rsync would delete no file the tracked copy holds.\n' "$prog"
      printf '%s:\n' "$prog"
      printf '%s: THAT IS NOT THE SAME AS LOSING NOTHING, and it is not proof. A merged\n' "$prog"
      printf '%s: commit that REMOVES engine content reads exactly like this from a fresh\n' "$prog"
      printf '%s: clone or a new worktree — the mirror still holds what was deleted, so it\n' "$prog"
      printf '%s: is the side with the extra content, and copying it across RESTORES what\n' "$prog"
      printf '%s: that commit removed. So both repairs, with the condition that selects\n' "$prog"
      printf '%s: each; (2) is the one this evidence favours:\n' "$prog"
      vendor_drift_print_both "$prog" "$engine" "$repo_root" "$confirm_mirror" "$tracked_only" "$at_risk"
      ;;
    *)
      printf '%s: which side is newer is NOT ESTABLISHED: %s.\n' "$prog" "$reason"
      printf '%s: So both repairs, with the condition that selects each:\n' "$prog"
      vendor_drift_print_both "$prog" "$engine" "$repo_root" "$confirm_mirror" "$tracked_only" "$at_risk"
      ;;
  esac
}

# ── the strings vendor_drift_main used to hold ────────────────────────────
# It now returns status and prints nothing, so the rule the other header states
# — this file holds everything the operator reads — is true rather than aspired
# to. Each emitter writes where its caller needs it: diagnostics to stderr, the
# two success lines to stdout.

vendor_drift_say_ok() {
  printf '%s: ok (third_party/%s matches the vstack copy)\n' "$1" "$2"
}

vendor_drift_say_missing_tracked() {
  printf '%s: FAIL: %s is missing; CI has nothing to run\n' "$1" "$2" >&2
}

vendor_drift_say_missing_mirror() {
  local prog="$1" engine="$2" allowed="$3" mirror_rel=".agents/skills/$2"
  if [[ "$allowed" == true ]]; then
    printf '%s: skipped: no vstack copy at %s, so drift was NOT checked\n' "$prog" "$mirror_rel"
    return 0
  fi
  printf '%s: FAIL: no vstack copy at %s\n' "$prog" "$mirror_rel" >&2
  printf "%s: run 'vstack add --skill %s', or pass\n" "$prog" "$engine" >&2
  printf '%s: --allow-missing-source to accept an unchecked vendor copy.\n' "$prog" >&2
}

# The comparison did not happen. Never a drift verdict: nothing was compared, so
# there is nothing to be a direction about.
vendor_drift_say_not_compared() {
  local prog="$1" kind="$2" detail="$3"
  case "$kind" in
    no-cwd) printf '%s: FAIL: could not enter %s, so the two copies were NOT compared\n' "$prog" "$detail" >&2 ;;
    *)
      printf '%s: FAIL: diff could not compare the two copies (exit %s)\n' "$prog" "$kind" >&2
      printf '%s\n' "$detail" >&2
      ;;
  esac
}

vendor_drift_say_classifier_broke() {
  printf '%s: WARNING: the drift classifier answered %q; treating the drift as\n' "$1" "$2" >&2
  printf '%s: destructive to overwrite.\n' "$1" >&2
}

vendor_drift_say_drifted() {
  printf '%s: FAIL: third_party/%s has drifted from the vstack copy\n' "$1" "$2" >&2
}

vendor_drift_say_unknown_option() {
  printf '%s: unknown option: %s\n' "$1" "$2" >&2
}

# The drift itself, passed through verbatim between the sides block that
# explains how to read it and the repairs it justifies.
vendor_drift_print_diff() {
  printf '%s\n' "$1" >&2
}
