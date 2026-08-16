#!/usr/bin/env bash
# Shared drift check for the vstack engines VGS vendors into third_party/.
#
# Sourced by scripts/check-review-gate-vendor.sh and
# scripts/check-size-ratchet-vendor.sh so both judge drift, and both name the
# repair, the same way. This half holds the EVIDENCE and the DECISION;
# scripts/lib/vendor-drift-report.sh holds everything the operator reads, and
# the rule governing the destructive repair. The dependency runs one way: this
# file sources that one, and that one calls nothing back.
#
# WHY THERE ARE TWO COPIES. An engine has to be IN the repository: CI runs it
# from a plain checkout, which has no vstack and no shared skills mirror. The
# sibling repos track theirs at `.agents/skills/`, but VGS symlinks `.agents`
# wholesale into every worktree (AGENTS.md § Project skills), so a file tracked
# under that path reports as deleted in every worktree — git cannot stat through
# the symlinked directory. Tracking it there would leave a permanently dirty
# tree. So the tracked, CI-facing copy lives at third_party/<engine>/,
# `vstack refresh` keeps maintaining .agents/skills/<engine> for agent
# discovery, and this check stops the two from drifting. Cite THIS paragraph for
# the two-copy rationale; the wrappers only name their engine.
#
# WHY THE REPAIR IS NOT A CONSTANT (VGS-155). Drift happens in BOTH directions,
# and this check once printed the mirror→tracked rsync unconditionally, as a
# procedure — which, run right after a vendoring PR merged, DELETED the merged
# engine change and then went green on the reverted content. What the check may
# and may not print as a result is stated once, in vendor-drift-report.sh.
#
# WHAT THE DIRECTION EVIDENCE IS, AND IS NOT. There is no per-skill source
# revision to compare: `.vstack-refreshed` holds one value for every skill a
# refresh wrote, so the strongest available signals are the commit time of the
# tracked copy, the mtime of that marker, and which side holds content the other
# lacks. They can disagree, and the check then says so rather than picking one —
# `undetermined` is a real answer here, not a fallback. Every signal that cannot
# be READ resolves to undetermined too: an absent marker, an absent repository,
# an unparseable diff line. If vstack ever records the source revision each
# skill was installed from, that becomes an exact comparison and
# vendor_drift_direction should use it instead.
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

# Classify the drift diff arriving on stdin. Prints:
#
#   line 1      yes|no — does the TRACKED copy hold content the mirror does not,
#                        i.e. would `rsync --delete` from the mirror DESTROY
#                        something
#   lines 2..n  the paths and raw lines behind a `yes`, deduplicated
#
# Returned rather than left in globals so a caller that skips this step cannot
# inherit a stale or absent "nothing is at risk" from a previous run.
#
# FAILS CLOSED BY CONSTRUCTION, which is the property that matters and the one
# this function did not have. Only lines PROVABLY not tracked-side evidence are
# ignored, and each ignore arm is anchored to something structural:
#
#   `--- <mirror>`/`+++ <tracked>`  the unified file headers, anchored to the two
#                                   roots diff was actually given — a bare `+++ `
#                                   prefix is NOT a header, because a tracked-only
#                                   content line reading `++ x` is printed as
#                                   `+++ x` and was silently eaten as one
#   `diff `, `@@ `                  diff's own provenance and hunk headers; a
#                                   content line always carries a +/-/space
#                                   prefix, so neither can be content
#   ` `, empty                      context: present in BOTH copies
#   `-`                             mirror-only content, or a `---` header: what
#                                   the rsync would ADD, never what it destroys
#   `\`                             the "No newline at end of file" marker, which
#                                   annotates an adjacent +/- line rather than
#                                   being evidence itself
#   `Only in <mirror>`              a file only the mirror has
#
# EVERYTHING ELSE — including anything this parser does not recognise — counts
# as tracked-only and is listed. `File A is a regular file while file B is a
# directory`, a locale-translated `Only in`, a diff format that grows a new line
# kind: each lands in the default arm and withholds the destructive command,
# which is the safe direction to be wrong in.
vendor_drift_classify() {
  local tracked_rel="$1" mirror_rel="$2"
  local line entry current="" tracked_only=no at_risk=""

  while IFS= read -r line; do
    entry=""
    case "$line" in
      "+++ $tracked_rel"*)
        # Names the tracked-side file the `+` lines below belong to; the
        # trailing tab-separated mtime is not part of the path.
        current="${line#+++ }"
        current="${current%%$'\t'*}"
        ;;
      "--- $mirror_rel"* | 'diff '* | '@@ '* | ' '* | '' | '-'* | \\*) ;;
      "Only in $mirror_rel"*) ;;
      "Only in $tracked_rel"*)
        tracked_only=yes
        entry="$(vendor_drift_only_in_path "$line")"
        ;;
      '+'*)
        tracked_only=yes
        entry="${current:-$line}"
        ;;
      *)
        tracked_only=yes
        entry="$line"
        ;;
    esac

    # Deduplicated: one file yields one entry however many of its lines differ.
    [[ -n "$entry" ]] || continue
    case $'\n'"$at_risk" in
      *$'\n'"$entry"$'\n'*) ;;
      *) at_risk+="$entry"$'\n' ;;
    esac
  done

  printf '%s\n' "$tracked_only"
  printf '%s' "$at_risk"
}

# Decide which copy is newer, or refuse to decide, and say why in the same
# breath. Prints "<reading><TAB><reason>" — exactly one of tracked-ahead,
# mirror-ahead or undetermined, with a reason that is empty for the two decided
# readings. One function owns both halves because when they were two, they
# diverged: the header reported an unreadable git while the verdict asserted a
# repository that did not exist.
#
#   $1 tracked_epoch  last commit touching third_party/<engine>, "" if unknown
#   $2 refresh_epoch  mtime of the mirror's .vstack-refreshed, "" if absent
#   $3 tracked_dirty  yes|no|unknown — uncommitted changes under third_party/
#   $4 tracked_only   yes|no — from vendor_drift_classify
#   $5 engine
#
# THESE ARE READINGS OF THE EVIDENCE, NOT VERDICTS, and only `tracked-ahead` is
# allowed to name a repair on its own — see vendor-drift-report.sh.
#
# The two decided readings are disjoint by construction: one needs the commit
# strictly newer than the refresh, the other strictly older, so their order here
# is immaterial and no ordering trick is load-bearing. What separates a merged
# DELETION from an upstream addition is that `mirror-ahead` names no repair
# alone — not that it is tested second.
#
# Unreadable evidence is answered before either: no repository, no commit, no
# refresh marker, or a tracked tree whose uncommitted changes mean its commit
# time does not describe what is on disk. `tracked_dirty` disqualifies the
# commit time for BOTH rules, not one, because it is the commit time itself that
# has stopped describing the tree.
vendor_drift_direction() {
  local tracked_epoch="$1" refresh_epoch="$2" tracked_dirty="$3" tracked_only="$4" engine="$5"

  if [[ "$tracked_dirty" == unknown ]]; then
    printf 'undetermined\tgit could not be consulted for third_party/%s, so the tracked copy has no verifiable age' "$engine"
    return 0
  fi
  if [[ -z "$tracked_epoch" ]]; then
    printf 'undetermined\tno commit in this repository touches third_party/%s, so the tracked copy has no age to compare' "$engine"
    return 0
  fi
  if [[ -z "$refresh_epoch" ]]; then
    printf 'undetermined\tthe mirror carries no .vstack-refreshed marker, so there is nothing to compare its age against'
    return 0
  fi
  if [[ "$tracked_dirty" == yes ]]; then
    printf 'undetermined\tthird_party/%s has uncommitted changes, so its last commit time does not describe what is on disk' "$engine"
    return 0
  fi
  if ((tracked_epoch > refresh_epoch)); then
    printf 'tracked-ahead\t'
    return 0
  fi
  if ((refresh_epoch > tracked_epoch)); then
    if [[ "$tracked_only" == no ]]; then
      printf 'mirror-ahead\t'
      return 0
    fi
    printf 'undetermined\tthe refresh is newer than the last commit that touched the tracked copy, but the tracked copy still holds content the mirror does not — which is also what a vendoring commit PULLED IN after that refresh looks like'
    return 0
  fi
  printf 'undetermined\tboth timestamps are identical'
}

# Seconds since the epoch for a path's mtime, or nothing. GNU `stat` only: these
# checks are local-only on a Linux workstation, and an untested BSD fallback is
# the fail-open shape this file exists to avoid. Elsewhere it returns nothing,
# which reads as unknown and answers undetermined.
vendor_drift_mtime_epoch() {
  stat -c %Y -- "$1" 2>/dev/null || return 1
}

# When `vstack refresh` last wrote the mirror, from its own per-refresh marker.
#
# NOTHING is returned when the marker is absent. The directory's mtime was used
# for that once and is a guess in both directions — it moves when any unrelated
# entry is created or removed, and does NOT move when a refresh rewrites file
# contents in place — so a freshly installed mirror always read as "now", hence
# as newer, feeding the one reading that names the destructive command.
vendor_drift_refresh_epoch() {
  local marker="$1/.vstack-refreshed"
  [[ -e "$marker" ]] || return 0
  vendor_drift_mtime_epoch "$marker" || true
}

# Commit time of the last commit touching the tracked copy, or nothing when the
# path has no history (or this is not a repository).
vendor_drift_last_commit_epoch() {
  git -C "$1" log -1 --format=%ct -- "$2" 2>/dev/null || true
}

# yes|no|unknown — `unknown` when git could not answer at all, which is a
# different thing from a clean tree and is read as such.
vendor_drift_tracked_dirty() {
  local porcelain
  if ! porcelain="$(git -C "$1" status --porcelain -- "$2" 2>/dev/null)"; then
    printf 'unknown'
    return 0
  fi
  if [[ -n "$porcelain" ]]; then printf 'yes'; else printf 'no'; fi
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

  # Unified, and against paths relative to the repo root, so every path in the
  # output is one the reader can act on and each hunk carries the two file names
  # rather than bare `<`/`>` markers. (`--label` would replace those per-file
  # names with one constant pair, so it is not the way to label the sides.)
  #
  # LC_ALL=C on this command alone — the `LC_ALL=C sort` precedent in
  # scripts/validate — because `Only in`, `Files` and `Binary files` are
  # TRANSLATED under another locale, and the classifier matches them by text.
  #
  # `cd` runs inside the substitution's subshell so the caller's cwd is never
  # moved: this function is sourced into a long-lived shell by the tests. Exit 3
  # is the sentinel for "cd failed" — diff itself uses 0, 1 and 2 only — so a
  # dependency that never ran cannot be read as "no differences" or as a
  # difference. That branch guards the window between the directory checks above
  # and this command; it is deliberately not fixture-reachable, since a repo
  # root that cannot be entered fails the `-d` checks first. The diff-trouble
  # branch below IS reachable, and is pinned by a fixture.
  # .vstack-refreshed is vstack's own bookkeeping, not engine content.
  local drift rc=0
  drift="$(
    cd -- "$repo_root" || exit 3
    LC_ALL=C diff -r -u --exclude=.vstack-refreshed -- "$mirror_rel" "$tracked_rel"
  )" || rc=$?
  case "$rc" in
    0)
      printf '%s: ok (%s matches the vstack copy)\n' "$prog" "$tracked_rel"
      return 0
      ;;
    1) ;;
    3)
      printf '%s: FAIL: could not enter %s, so the two copies were NOT compared\n' "$prog" "$repo_root" >&2
      return 1
      ;;
    *)
      printf '%s: FAIL: diff could not compare the two copies (exit %d)\n' "$prog" "$rc" >&2
      printf '%s\n' "$drift" >&2
      return 1
      ;;
  esac

  local classified tracked_only at_risk=""
  classified="$(vendor_drift_classify "$tracked_rel" "$mirror_rel" <<<"$drift")"
  tracked_only="${classified%%$'\n'*}"
  if [[ "$classified" == *$'\n'* ]]; then
    at_risk="${classified#*$'\n'}"
  fi
  # The classifier's own contract, enforced rather than assumed: an answer that
  # is neither yes nor no is a parser defect, and the safe reading of a parser
  # defect is that content is at stake.
  if [[ "$tracked_only" != yes && "$tracked_only" != no ]]; then
    printf '%s: WARNING: the drift classifier answered %q; treating the drift as\n' "$prog" "$tracked_only" >&2
    printf '%s: destructive to overwrite.\n' "$prog" >&2
    tracked_only=yes
    at_risk="$classified"
  fi

  local tracked_epoch refresh_epoch tracked_dirty decided reading reason
  tracked_epoch="$(vendor_drift_last_commit_epoch "$repo_root" "$tracked_rel")"
  refresh_epoch="$(vendor_drift_refresh_epoch "$mirror")"
  tracked_dirty="$(vendor_drift_tracked_dirty "$repo_root" "$tracked_rel")"
  decided="$(vendor_drift_direction \
    "$tracked_epoch" "$refresh_epoch" "$tracked_dirty" "$tracked_only" "$engine")"
  reading="${decided%%$'\t'*}"
  reason="${decided#*$'\t'}"

  {
    printf '%s: FAIL: %s has drifted from the vstack copy\n' "$prog" "$tracked_rel"
    vendor_drift_print_sides "$prog" "$engine" \
      "$tracked_epoch" "$refresh_epoch" "$tracked_dirty"
  } >&2
  printf '%s\n' "$drift" >&2
  vendor_drift_print_repairs "$prog" "$engine" "$reading" "$reason" \
    "$confirm_mirror" "$tracked_only" "$at_risk" >&2
  return 1
}
