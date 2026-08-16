#!/usr/bin/env bash
# Shared drift check for the vstack engines VGS vendors into third_party/.
#
# Sourced by scripts/check-review-gate-vendor.sh and
# scripts/check-size-ratchet-vendor.sh so both judge drift, and both name the
# repair, the same way.
#
# WHY THERE ARE TWO COPIES. An engine has to be IN the repository: CI runs it
# from a plain checkout, which has no vstack and no shared skills mirror. The
# sibling repos track theirs at `.agents/skills/`, but VGS symlinks `.agents`
# wholesale into every worktree (AGENTS.md § Project skills), so a file tracked
# under that path reports as deleted in every worktree — git cannot stat through
# the symlinked directory. Tracking it there would leave a permanently dirty
# tree. So the tracked, CI-facing copy lives at third_party/<engine>/,
# `vstack refresh` keeps maintaining .agents/skills/<engine> for agent
# discovery, and this check stops the two from drifting.
#
# WHY THE REPAIR IS NOT A CONSTANT (VGS-155). Drift happens in BOTH directions:
# `vstack refresh` moves the mirror ahead, and merging a vendoring PR moves the
# tracked copy ahead. This check used to print the mirror→tracked rsync
# unconditionally, as a procedure. Run right after a vendoring PR merged, that
# command DELETED the merged engine change — and the check then went GREEN,
# because the two copies agreed again: failure into a passing state, on the
# wrong content. So the direction is decided from evidence here, the mirror→
# tracked rsync is printed only when it can lose nothing or when the caller
# asserts the direction, and the diff sides are labelled instead of leaving
# bare `<`/`>` markers whose meaning depends on knowing the argument order.
#
# WHAT THE DIRECTION EVIDENCE IS, AND IS NOT. There is no per-skill source
# revision to compare: `.vstack-refreshed` holds one value for every skill a
# refresh wrote, so the strongest available signals are the commit time of the
# tracked copy, the mtime of that marker, and which side holds content the other
# lacks. Two of the three can disagree, and the check then says so rather than
# picking one — `undetermined` is a real answer here, not a fallback. If vstack
# ever records the source revision each skill was installed from, that becomes
# an exact comparison and vendor_drift_direction should use it instead.
#
# Entry point:
#   vendor_drift_main <prog> <engine> <repo_root> [ARGS...]
#
# `<engine>` names both paths by convention — third_party/<engine> and
# .agents/skills/<engine> — which is also what lets the tests drive the whole
# check against a fixture repo root.

# Sourced files inherit the caller's options, and every caller here already
# sets these three. Setting them anyway is what makes that a guarantee rather
# than a coincidence: the functions below read command output into variables and
# branch on it, so an unset variable or a swallowed non-zero must abort rather
# than be classified.
set -euo pipefail

# shellcheck source=scripts/lib/vendor-drift-report.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/vendor-drift-report.sh"

# Report `Only in DIR: NAME` as the path it refers to.
vendor_drift_only_in_path() {
  local line="$1" dir name
  dir="${line#Only in }"
  name="${dir#*: }"
  dir="${dir%%: *}"
  printf '%s/%s' "$dir" "$name"
}

# Collect a path whose content an rsync from the mirror would overwrite or
# delete. Deduplicated, because one file yields one entry however many of its
# lines differ.
vendor_drift_at_risk_add() {
  local entry="$1"
  [[ -n "$entry" ]] || return 0
  case $'\n'"$vendor_drift_at_risk" in
    *$'\n'"$entry"$'\n'*) return 0 ;;
  esac
  vendor_drift_at_risk+="$entry"$'\n'
}

# Classify the drift diff arriving on stdin. Sets three globals:
#
#   vendor_drift_tracked_only  yes|no  the tracked copy holds content the mirror
#                                      does not — i.e. `rsync --delete` from the
#                                      mirror would LOSE it
#   vendor_drift_at_risk       newline-separated paths behind the `yes` above
#
# Only the tracked side is classified: content the MIRROR alone holds is what
# the rsync would add, which loses nothing and needs no answer. Anything this
# cannot attribute to a side counts as tracked-only — a misread that understates
# the tracked side is exactly the failure VGS-155 describes, so unattributable
# drift is never classified as safe to overwrite.
vendor_drift_classify() {
  local tracked_rel="$1" mirror_rel="$2"
  local line current=""
  vendor_drift_tracked_only=no
  vendor_drift_at_risk=""

  while IFS= read -r line; do
    case "$line" in
      '+++ '*)
        # The unified header names the tracked-side file the `+` lines below
        # belong to; the trailing tab-separated mtime is not part of the path.
        current="${line#+++ }"
        current="${current%%$'\t'*}"
        ;;
      '--- '*|'@@'*|'diff '*) ;;
      "Only in $tracked_rel"*)
        vendor_drift_tracked_only=yes
        vendor_drift_at_risk_add "$(vendor_drift_only_in_path "$line")"
        ;;
      "Only in $mirror_rel"*) ;;
      'Only in '*|'Binary files '*|'Files '*)
        # A path under neither root, or a difference `diff` declined to show as
        # content: the side it favours is not visible, so treat it as tracked.
        vendor_drift_tracked_only=yes
        vendor_drift_at_risk_add "$line"
        ;;
      '+'*)
        vendor_drift_tracked_only=yes
        vendor_drift_at_risk_add "$current"
        ;;
    esac
  done
}

# Decide which copy is newer, or refuse to decide.
#
#   $1 tracked_epoch  last commit touching third_party/<engine>, "" if unknown
#   $2 refresh_epoch  when `vstack refresh` last wrote the mirror, "" if unknown
#   $3 tracked_dirty  yes|no|unknown — uncommitted changes under third_party/
#   $4 tracked_only   yes|no — from vendor_drift_classify
#
# Prints exactly one of: tracked-ahead | mirror-ahead | undetermined
#
# THESE ARE READINGS OF THE EVIDENCE, NOT VERDICTS, and only one of them is
# allowed to name a repair on its own — see vendor_drift_report.
#
# `tracked-ahead` is tested FIRST because a commit that lands after a refresh
# can also be a pure DELETION, which leaves the mirror holding the only extra
# content while the tracked copy is still the newer side. The content test alone
# reads that as `mirror-ahead` and hands back the rsync that undoes the
# deletion.
#
# `mirror-ahead` needs both halves — the refresh is newer AND copying across
# would delete nothing — and is STILL not proof. Take that same merged deletion
# and read it in a fresh clone or a new worktree, where the vendoring commit
# predates the last refresh: the timestamps favour the mirror, nothing would be
# deleted, and the rsync still reverts the deletion. An ordinary state inverts
# it, so it never names a repair alone.
vendor_drift_direction() {
  local tracked_epoch="$1" refresh_epoch="$2" tracked_dirty="$3" tracked_only="$4"

  if [[ -n "$tracked_epoch" && -n "$refresh_epoch" && "$tracked_dirty" == no ]] &&
    ((tracked_epoch > refresh_epoch)); then
    printf 'tracked-ahead'
    return 0
  fi
  if [[ -n "$tracked_epoch" && -n "$refresh_epoch" && "$tracked_only" == no ]] &&
    ((refresh_epoch > tracked_epoch)); then
    printf 'mirror-ahead'
    return 0
  fi
  printf 'undetermined'
}

# Why vendor_drift_direction gave up, in the reader's terms.
vendor_drift_undetermined_reason() {
  local tracked_epoch="$1" refresh_epoch="$2" tracked_dirty="$3" engine="$4"

  if [[ -z "$tracked_epoch" ]]; then
    printf 'no commit in this repository touches third_party/%s, so the tracked copy has no age to compare' "$engine"
    return 0
  fi
  if [[ -z "$refresh_epoch" ]]; then
    printf 'the mirror carries no refresh timestamp, so there is nothing to compare its age against'
    return 0
  fi
  if [[ "$tracked_dirty" == unknown ]]; then
    printf 'git could not be consulted here, so the tracked copy has no verifiable age'
    return 0
  fi
  if [[ "$tracked_dirty" == yes ]]; then
    printf 'third_party/%s has uncommitted changes, so its last commit time does not describe what is on disk' "$engine"
    return 0
  fi
  if ((tracked_epoch == refresh_epoch)); then
    printf 'both timestamps are identical'
    return 0
  fi
  printf 'the refresh is newer than the last commit that touched the tracked copy, but the tracked copy still holds content the mirror does not — which is also what a vendoring commit PULLED IN after that refresh looks like'
}

# Seconds since the epoch for a path's mtime, or nothing.
vendor_drift_mtime_epoch() {
  local path="$1"
  stat -c %Y -- "$path" 2>/dev/null && return 0
  stat -f %m -- "$path" 2>/dev/null && return 0
  return 1
}

# When `vstack refresh` last wrote the mirror. `.vstack-refreshed` is vstack's
# own per-refresh marker, so its mtime answers directly; without it the
# directory's mtime is the closest available, and an unreadable mtime is
# reported as unknown rather than guessed.
vendor_drift_refresh_epoch() {
  local mirror="$1"
  if [[ -e "$mirror/.vstack-refreshed" ]]; then
    vendor_drift_mtime_epoch "$mirror/.vstack-refreshed" || true
    return 0
  fi
  vendor_drift_mtime_epoch "$mirror" || true
}

# Commit time of the last commit touching the tracked copy, or nothing when the
# path has no history (or this is not a repository).
vendor_drift_last_commit_epoch() {
  local repo_root="$1" path="$2"
  git -C "$repo_root" log -1 --format=%ct -- "$path" 2>/dev/null || true
}

vendor_drift_tracked_dirty() {
  local repo_root="$1" path="$2" porcelain
  if ! porcelain="$(git -C "$repo_root" status --porcelain -- "$path" 2>/dev/null)"; then
    printf 'unknown'
    return 0
  fi
  if [[ -n "$porcelain" ]]; then printf 'yes'; else printf 'no'; fi
}

vendor_drift_stamp() {
  local epoch="$1"
  if [[ -z "$epoch" ]]; then
    printf 'unknown'
    return 0
  fi
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null && return 0
  printf '%s' "$epoch"
}

vendor_drift_main() {
  local prog="$1" engine="$2" repo_root="$3"
  shift 3

  local allow_missing=false confirm_mirror=false arg
  for arg in "$@"; do
    case "$arg" in
      --allow-missing-source) allow_missing=true ;;
      --confirm-mirror-is-newer) confirm_mirror=true ;;
      -h | --help)
        vendor_drift_usage "$prog" "$engine"
        return 0
        ;;
      *)
        printf '%s: unknown option: %s\n' "$prog" "$arg" >&2
        return 2
        ;;
    esac
  done

  local tracked_rel="third_party/$engine" mirror_rel=".agents/skills/$engine"
  local tracked="$repo_root/$tracked_rel" mirror="$repo_root/$mirror_rel"

  if [[ ! -d "$tracked" ]]; then
    printf '%s: FAIL: %s is missing; CI has nothing to run\n' "$prog" "$tracked" >&2
    return 1
  fi

  if [[ ! -d "$mirror" ]]; then
    if [[ "$allow_missing" == true ]]; then
      printf '%s: skipped: no vstack copy at %s, so drift was NOT checked\n' "$prog" "$mirror_rel"
      return 0
    fi
    printf '%s: FAIL: no vstack copy at %s\n' "$prog" "$mirror_rel" >&2
    printf "%s: run 'vstack add --skill %s', or pass\n" "$prog" "$engine" >&2
    printf '%s: --allow-missing-source to accept an unchecked vendor copy.\n' "$prog" >&2
    return 1
  fi

  # Unified, and run from the repo root against relative paths, so every path in
  # the output is one the reader can act on and each hunk carries the two file
  # names rather than bare `<`/`>` markers. .vstack-refreshed is vstack's own
  # bookkeeping, not engine content.
  local drift rc=0
  drift="$(cd -- "$repo_root" && diff -r -u --exclude=.vstack-refreshed -- "$mirror_rel" "$tracked_rel")" || rc=$?
  if ((rc == 0)); then
    printf '%s: ok (%s matches the vstack copy)\n' "$prog" "$tracked_rel"
    return 0
  fi
  if ((rc > 1)); then
    printf '%s: FAIL: diff could not compare the two copies (exit %d)\n' "$prog" "$rc" >&2
    printf '%s\n' "$drift" >&2
    return 1
  fi

  vendor_drift_classify "$tracked_rel" "$mirror_rel" <<<"$drift"

  local tracked_epoch refresh_epoch tracked_dirty direction
  tracked_epoch="$(vendor_drift_last_commit_epoch "$repo_root" "$tracked_rel")"
  refresh_epoch="$(vendor_drift_refresh_epoch "$mirror")"
  tracked_dirty="$(vendor_drift_tracked_dirty "$repo_root" "$tracked_rel")"
  direction="$(vendor_drift_direction \
    "$tracked_epoch" "$refresh_epoch" "$tracked_dirty" "$vendor_drift_tracked_only")"

  vendor_drift_report "$prog" "$engine" "$confirm_mirror" \
    "$tracked_epoch" "$refresh_epoch" "$tracked_dirty" "$direction" "$drift"
  return 1
}
