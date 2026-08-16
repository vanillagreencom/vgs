#!/usr/bin/env bash
# The operator-facing half of the vendor drift check: usage, the sides and
# their labels, and the repair branches. scripts/lib/vendor-drift.sh holds the
# evidence and the decision, and sources this; nothing else should source it.
#
# THE RULE THIS FILE EXISTS TO HOLD IN ONE PLACE. The mirror-to-tracked
# `rsync -a --delete` is the destructive half — it is what reverted a merged
# engine fix in VGS-155 — so it is never printed as a default or an
# unconditioned repair. It appears exactly three ways: behind the numbered
# condition that selects it, behind an operator asserting the direction with
# --confirm-mirror-is-newer, or not at all, when it would delete content only
# the tracked copy holds. A single repair is named only for the one reading
# strong enough to carry it, and that reading names the non-destructive half.
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
      is printed even when it would delete content the tracked copy holds

On drift the check reports which side the evidence says is newer and prints
only the repair for that direction. Why that matters, and why the rsync is
withheld by default: scripts/lib/vendor-drift.sh (VGS-155).
USAGE
}

# The rsync that adopts the mirror. It is the destructive half, so it is never
# the default or an unconditioned repair: every caller below either states the
# condition that selects it, or prints it because the operator asserted the
# direction with --confirm-mirror-is-newer.
vendor_drift_print_rsync() {
  local prog="$1" engine="$2" indent="${3:-  }"
  printf '%s: %srsync -a --delete --exclude=.vstack-refreshed \\\n' "$prog" "$indent"
  printf '%s: %s  .agents/skills/%s/ third_party/%s/\n' "$prog" "$indent" "$engine" "$engine"
}

# shellcheck disable=SC2154 # vendor_drift_at_risk is set by
# vendor_drift_classify in vendor-drift.sh; defaulting it here would turn a
# missing classify call into a silent "nothing is at risk".
vendor_drift_print_at_risk() {
  local prog="$1" indent="${2:-    }" entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    printf '%s: %s%s\n' "$prog" "$indent" "$entry"
  done <<<"$vendor_drift_at_risk"
}

# Both repairs, each behind the condition that selects it, non-destructive
# first. Printed whenever the direction is not soundly determined — which is
# every reading except `tracked-ahead`.
#
# The destructive half is withheld entirely when it would delete content only
# the tracked copy holds: that is the shape of a just-merged vendoring commit,
# and handing over a runnable command there is what VGS-155 reported.
# shellcheck disable=SC2154 # vendor_drift_tracked_only is set by
# vendor_drift_classify in vendor-drift.sh; see the note above.
vendor_drift_print_both() {
  local prog="$1" engine="$2" confirm_mirror="$3"

  printf '%s:\n' "$prog"
  printf '%s: (1) If the TRACKED copy is newer — the usual case right after a vendoring\n' "$prog"
  printf '%s:     PR merges — refresh the mirror. This deletes nothing:\n' "$prog"
  printf '%s:       vstack refresh\n' "$prog"
  printf '%s:\n' "$prog"
  if [[ "$vendor_drift_tracked_only" == yes && "$confirm_mirror" != true ]]; then
    printf '%s: (2) If the MIRROR is newer, the repair is an rsync — WITHHELD here, because\n' "$prog"
    printf '%s:     it would delete content that only the tracked copy holds:\n' "$prog"
    vendor_drift_print_at_risk "$prog" "       "
    printf '%s:     Establish the direction first, then re-run with\n' "$prog"
    printf '%s:     --confirm-mirror-is-newer to print that command.\n' "$prog"
    return 0
  fi
  printf '%s: (2) If the MIRROR is newer — the usual case right after vstack refresh\n' "$prog"
  printf '%s:     pulled an engine update — copy it across and commit the result:\n' "$prog"
  vendor_drift_print_rsync "$prog" "$engine" "      "
}

# Everything the operator reads on a drift: the two sides with their evidence,
# the labelled diff, and the repair — or repairs — the reading licenses.
#
#   $1 prog  $2 engine  $3 confirm_mirror
#   $4 tracked_epoch  $5 refresh_epoch  $6 tracked_dirty  $7 direction  $8 drift
#
# Reads vendor_drift_tracked_only and vendor_drift_at_risk, which
# vendor_drift_classify set from that same diff.
vendor_drift_report() {
  local prog="$1" engine="$2" confirm_mirror="$3"
  local tracked_epoch="$4" refresh_epoch="$5" tracked_dirty="$6" direction="$7" drift="$8"
  local tracked_rel="third_party/$engine" mirror_rel=".agents/skills/$engine"

  local dirty_note=""
  [[ "$tracked_dirty" == yes ]] && dirty_note=", plus uncommitted changes"
  [[ "$tracked_dirty" == unknown ]] && dirty_note=", commit state unknown"

  {
    printf '%s: FAIL: %s has drifted from the vstack copy\n' "$prog" "$tracked_rel"
    printf '%s:\n' "$prog"
    printf '%s: tracked  %s/ — CI runs this; last commit %s%s\n' \
      "$prog" "$tracked_rel" "$(vendor_drift_stamp "$tracked_epoch")" "$dirty_note"
    printf '%s: mirror   %s/ — vstack refresh writes this; last refreshed %s\n' \
      "$prog" "$mirror_rel" "$(vendor_drift_stamp "$refresh_epoch")"
    printf '%s:\n' "$prog"
    printf '%s: In the diff below:\n' "$prog"
    printf '%s:   - lines are only in %s/ (mirror)\n' "$prog" "$mirror_rel"
    printf '%s:   + lines are only in %s/ (tracked)\n' "$prog" "$tracked_rel"
    printf '%s:   "Only in DIR" names a whole file only that side has\n' "$prog"
  } >&2
  printf '%s\n' "$drift" >&2

  {
    printf '%s:\n' "$prog"
    case "$direction" in
      tracked-ahead)
        # The ONLY reading that names a single repair. Two things earn it that:
        # the evidence is a commit that landed after the mirror was last
        # written, which a fresh clone, a new worktree, a never-refreshed mirror
        # and an untracked tree all fail to produce (each falls through to the
        # branch below instead of inverting this one); and the repair it names
        # is the non-destructive half, so being wrong here costs a no-op refresh
        # and a second failing run, never content.
        printf '%s: the TRACKED copy is newer — it changed after the last vstack refresh.\n' "$prog"
        printf '%s: The mirror is the stale side, so refresh it:\n' "$prog"
        printf '%s:   vstack refresh\n' "$prog"
        if [[ "$confirm_mirror" == true ]]; then
          printf '%s:\n' "$prog"
          printf '%s: --confirm-mirror-is-newer CONTRADICTS that evidence. If you are sure,\n' "$prog"
          printf '%s: this is the command, and it discards the tracked change above:\n' "$prog"
          vendor_drift_print_rsync "$prog" "$engine"
        else
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
        vendor_drift_print_both "$prog" "$engine" "$confirm_mirror"
        ;;
      *)
        printf '%s: which side is newer is NOT ESTABLISHED: %s.\n' "$prog" \
          "$(vendor_drift_undetermined_reason \
            "$tracked_epoch" "$refresh_epoch" "$tracked_dirty" "$engine")"
        printf '%s: So both repairs, with the condition that selects each:\n' "$prog"
        vendor_drift_print_both "$prog" "$engine" "$confirm_mirror"
        ;;
    esac
  } >&2
}
