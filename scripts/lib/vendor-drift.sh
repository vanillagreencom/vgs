#!/usr/bin/env bash
# Shared drift check for the vstack engines VGS vendors into third_party/.
#
# Sourced by scripts/check-review-gate-vendor.sh and
# scripts/check-size-ratchet-vendor.sh. This half holds the EVIDENCE and the
# DECISION and returns a status; scripts/lib/vendor-drift-report.sh holds every
# string the operator reads, and the rule governing the destructive repair. The
# dependency runs one way: this file sources that one, which calls nothing back.
#
# WHY THERE ARE TWO COPIES. An engine has to be IN the repository: CI runs it
# from a plain checkout, which has no vstack and no shared skills mirror. The
# sibling repos track theirs at `.agents/skills/`, but VGS symlinks `.agents`
# wholesale into every worktree (AGENTS.md § Project skills), so a file tracked
# under that path reports as deleted in every worktree — git cannot stat through
# the symlinked directory, leaving a permanently dirty tree. So the tracked,
# CI-facing copy lives at third_party/<engine>/, `vstack refresh` maintains
# .agents/skills/<engine> for agent discovery, and this check stops the two from
# drifting. Cite THIS paragraph for the two-copy rationale; the wrappers only
# name their engine, and the report half only states what may be printed.
#
# WHY THE REPAIR IS NOT A CONSTANT (VGS-155). Drift happens in BOTH directions,
# and this check once printed the mirror→tracked rsync unconditionally, as a
# procedure — which, run right after a vendoring PR merged, DELETED the merged
# change and then went green on the reverted content.
#
# WHAT THE DIRECTION EVIDENCE IS, AND IS NOT. There is no per-skill source
# revision to compare: `.vstack-refreshed` holds one value for every skill a
# refresh wrote. So the signals are the tracked copy's commit time, that
# marker's mtime, and which side holds content the other lacks. They can
# disagree, and the check then says so rather than picking one — `undetermined`
# is a real answer, not a fallback — and every signal that cannot be READ
# resolves there too: an absent marker, an absent or shallow repository, an
# unparseable diff line. If vstack ever records the source revision each skill
# was installed from, that becomes exact and vendor_drift_direction should use
# it instead.
#
# Entry point: vendor_drift_main <prog> <engine> <repo_root> [ARGS...], where
# <engine> names both paths by convention — third_party/<engine> and
# .agents/skills/<engine> — which is also what lets the tests drive the whole
# check against a fixture repo root.

# Sourced files inherit the caller's options; setting them makes that a
# guarantee rather than a coincidence, and these functions read command output
# into variables and branch on it, so an unset variable or a swallowed non-zero
# must abort rather than be classified.
set -euo pipefail

# shellcheck source=scripts/lib/vendor-drift-report.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/vendor-drift-report.sh"

# Report `Only in DIR: NAME` as the path it refers to. GNU diff SHELL-quotes DIR
# when it contains a space — `Only in '.agents/skills/x/sub dir': f.md` — which
# is a different quoting style from the double quotes it uses in the unified
# headers, so the two are stripped separately rather than by one helper.
vendor_drift_only_in_path() {
  local line="$1" dir name
  dir="${line#Only in }"
  name="${dir#*: }"
  dir="${dir%%: *}"
  dir="${dir#\'}"
  dir="${dir%\'}"
  printf '%s/%s' "$dir" "$name"
}

# Classify the drift diff arriving on stdin. Prints:
#
#   line 1      yes|no — does the TRACKED copy hold content the mirror does not,
#                        i.e. would `rsync --delete` from the mirror DESTROY
#                        something
#   lines 2..n  the entries behind a `yes`, deduplicated: a path where this
#                        could attribute one, the raw line where it could not
#
# Returned rather than left in globals, so a caller that skips this step cannot
# inherit a stale or absent "nothing is at risk".
#
# HEADERS ARE RECOGNISED BY POSITION, NOT BY PREFIX. `diff -r -u` emits
# `diff …`, `--- <mirror>`, `+++ <tracked>` in that order before every differing
# pair, so a `+++ ` line is a header only where a header can occur, and content
# can never be read as one whatever it starts with. Prefix tests were tried
# twice and defeated twice: a tracked-only content line reading `++ x` prints as
# `+++ x`, and anchoring to the roots only moved the goalposts to
# `++ third_party/<engine>` — which these trees do discuss, being documentation
# about diffs and vendored paths. A prefix test is a guess, and the destructive
# question is the one thing here that may not be guessed.
#
# FAILS CLOSED BY CONSTRUCTION. Only lines PROVABLY not tracked-side evidence
# are ignored: the three header lines in header position; `@@ `, ` ` and empty
# (hunk headers and context, present in BOTH copies); `-` (mirror-only content,
# what the rsync would ADD); `\` (the no-newline marker annotating an adjacent
# line); and `Only in <mirror>`, quoted or not. EVERYTHING else — a translated
# marker, a new diff line kind, a header out of position — counts as
# tracked-only and is listed, withholding the destructive command. The cost is
# over-withholding, and the report names the list for what it is rather than
# claiming every entry is tracked-side content.
vendor_drift_classify() {
  local tracked_rel="$1" mirror_rel="$2"
  local line entry current="" tracked_only=no at_risk="" expect=file

  while IFS= read -r line; do
    entry=""
    case "$line" in
      'diff '*)
        # Emitted by `diff -r` before each differing pair, so it is the only
        # place a header can begin.
        expect=mirror_header
        continue
        ;;
      "--- $mirror_rel"* | "--- \"$mirror_rel"*)
        if [[ "$expect" == mirror_header ]]; then
          expect=tracked_header
          continue
        fi
        expect=body
        continue
        ;;
      "+++ $tracked_rel"* | "+++ \"$tracked_rel"*)
        if [[ "$expect" == tracked_header ]]; then
          # Names the tracked-side file the `+` lines below belong to; the
          # trailing tab-separated mtime is not part of the path, and GNU diff
          # double-quotes the name when it contains a space.
          current="${line#+++ }"
          current="${current%%$'\t'*}"
          current="${current%\"}"
          current="${current#\"}"
          expect=body
          continue
        fi
        ;;
    esac
    expect=body

    case "$line" in
      '@@ '* | ' '* | '' | '-'* | \\*) ;;
      "Only in $mirror_rel"* | "Only in '$mirror_rel"*) ;;
      "Only in $tracked_rel"* | "Only in '$tracked_rel"*)
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
# breath. Prints "<reading><TAB><reason>": tracked-ahead, mirror-ahead or
# undetermined, the reason empty for the two decided readings.
#
#   $1 age_state  $2 tracked_epoch  $3 refresh_epoch  $4 tracked_only  $5 engine
#
# THESE ARE READINGS, NOT VERDICTS, and only `tracked-ahead` may name a repair
# on its own — see vendor-drift-report.sh.
#
# The two decided readings are disjoint by construction: one needs the commit
# strictly newer than the refresh, the other strictly older, so their order is
# immaterial and no ordering trick is load-bearing. What separates a merged
# DELETION from an upstream addition is that `mirror-ahead` names no repair
# alone, not that it is tested second.
#
# Unusable evidence is answered before either, and every way it can be unusable
# disqualifies the commit time for BOTH rules: it is the commit time itself that
# has stopped describing the tree. An unrecognised state, or a `usable` one
# whose epoch is not a timestamp, is answered there too rather than falling
# through to an arithmetic comparison that reads an empty value as 0.
vendor_drift_direction() {
  local age_state="$1" tracked_epoch="$2" refresh_epoch="$3" tracked_only="$4" engine="$5"

  case "$age_state" in
    git-unreadable)
      printf 'undetermined\tgit could not be consulted for third_party/%s, so the tracked copy has no verifiable age' "$engine"
      return 0
      ;;
    shallow)
      printf 'undetermined\tthis is a shallow clone, where git reports the tip commit date for every path whether or not that commit touched it, so third_party/%s has no usable age' "$engine"
      return 0
      ;;
    no-history)
      printf 'undetermined\tno commit in this repository touches third_party/%s, so the tracked copy has no age to compare' "$engine"
      return 0
      ;;
    dirty)
      printf 'undetermined\tthird_party/%s has uncommitted changes, so its last commit time does not describe what is on disk' "$engine"
      return 0
      ;;
    usable) ;;
    *)
      printf 'undetermined\tthe commit-age collector returned the unrecognised state %s, so nothing here can be compared' "$age_state"
      return 0
      ;;
  esac
  # `usable` is a CLAIM about the epoch, enforced here rather than trusted: the
  # two halves talk through a tab-delimited string across a function boundary,
  # and bash arithmetic reads an empty or non-numeric value as 0, which makes
  # the refresh look newer and lands on the one reading that favours the rsync.
  if [[ -z "$tracked_epoch" || -n "${tracked_epoch//[0-9]/}" ]]; then
    printf 'undetermined\tthe tracked commit time was reported as %q, which is not a timestamp' "$tracked_epoch"
    return 0
  fi
  if [[ -n "${refresh_epoch//[0-9]/}" ]]; then
    printf 'undetermined\tthe mirror refresh time was reported as %q, which is not a timestamp' "$refresh_epoch"
    return 0
  fi
  if [[ -z "$refresh_epoch" ]]; then
    printf 'undetermined\tthe mirror carries no .vstack-refreshed marker, so there is nothing to compare its age against'
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

# Whether the tracked copy's commit time can be trusted, and if not, WHICH way
# it cannot. Prints "<state><TAB><epoch>", the epoch empty for every state but
# `usable`:
#
#   usable          a commit time that describes what is on disk
#   git-unreadable  git could not answer at all
#   shallow         a shallow clone, where `git log -1 -- <path>` reports the
#                   TIP date for EVERY path, touched or not — normally newer
#                   than the mirror's refresh mtime, so a genuine mirror-ahead
#                   drift reads as a confident `tracked-ahead`. How far off
#                   depends on the clone, so no figure is quoted here; the
#                   fixture in the evidence suite reproduces the mechanism.
#   no-history      no commit in this repository touches the path
#   dirty           uncommitted changes, so the last commit time has stopped
#                   describing the tree
#
# One collector rather than two signals: each state maps to exactly one reason,
# and when the two were computed separately they diverged — reporting an
# unreadable git while asserting a repository that did not exist.
vendor_drift_tracked_age() {
  local repo_root="$1" path="$2" shallow porcelain epoch

  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'git-unreadable\t'
    return 0
  fi
  # A probe that cannot answer says so, rather than being read as `false`: the
  # failure mode of assuming a full repository is a confident wrong direction.
  # An answer that is neither `true` nor `false` is read as shallow for the same
  # reason — every route out of here is undetermined.
  if ! shallow="$(git -C "$repo_root" rev-parse --is-shallow-repository 2>/dev/null)"; then
    printf 'git-unreadable\t'
    return 0
  fi
  if [[ "$shallow" != false ]]; then
    printf 'shallow\t'
    return 0
  fi
  if ! epoch="$(git -C "$repo_root" log -1 --format=%ct -- "$path" 2>/dev/null)"; then
    # A repository with no commits at all fails here rather than returning
    # empty, and that IS "no history" — calling it unreadable git would be the
    # same wrong-cause diagnostic one state over.
    if git -C "$repo_root" rev-parse --verify HEAD >/dev/null 2>&1; then
      printf 'git-unreadable\t'
    else
      printf 'no-history\t'
    fi
    return 0
  fi
  if [[ -z "$epoch" ]]; then
    printf 'no-history\t'
    return 0
  fi
  if ! porcelain="$(git -C "$repo_root" status --porcelain -- "$path" 2>/dev/null)"; then
    printf 'git-unreadable\t'
    return 0
  fi
  if [[ -n "$porcelain" ]]; then
    printf 'dirty\t'
    return 0
  fi
  printf 'usable\t%s' "$epoch"
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
        vendor_drift_say_unknown_option "$prog" "$arg"
        return 2
        ;;
    esac
  done

  local tracked_rel="third_party/$engine" mirror_rel=".agents/skills/$engine"
  local tracked="$repo_root/$tracked_rel" mirror="$repo_root/$mirror_rel"

  if [[ ! -d "$tracked" ]]; then
    vendor_drift_say_missing_tracked "$prog" "$tracked"
    return 1
  fi

  if [[ ! -d "$mirror" ]]; then
    vendor_drift_say_missing_mirror "$prog" "$engine" "$allow_missing"
    [[ "$allow_missing" == true ]] && return 0
    return 1
  fi

  # Unified, against repo-relative paths, so every path in the output is one the
  # reader can act on and each hunk carries both file names rather than bare
  # `<`/`>` markers. (`--label` would replace those per-file names with one
  # constant pair, so it is not the way to label the sides.) `LC_ALL=C` on this
  # command alone — the `LC_ALL=C sort` precedent in scripts/validate — keeps
  # the markers the classifier matches in the language it parses.
  # `.vstack-refreshed` is vstack's own bookkeeping, not engine content.
  #
  # `cd` runs inside the substitution's subshell so the caller's cwd is never
  # moved: this is sourced into a long-lived shell by the tests. Exit 3 is the
  # sentinel for "cd failed" — diff uses 0, 1 and 2 only — so a dependency that
  # never ran cannot be read as a difference or as none. That branch guards the
  # window after the directory checks and is deliberately not fixture-reachable
  # (an unenterable root fails `-d` first); the diff-trouble branch below is
  # reachable and is pinned by a fixture.
  local drift rc=0
  drift="$(
    cd -- "$repo_root" || exit 3
    LC_ALL=C diff -r -u --exclude=.vstack-refreshed -- "$mirror_rel" "$tracked_rel"
  )" || rc=$?
  case "$rc" in
    0)
      vendor_drift_say_ok "$prog" "$engine"
      return 0
      ;;
    1) ;;
    3)
      vendor_drift_say_not_compared "$prog" no-cwd "$repo_root"
      return 1
      ;;
    *)
      vendor_drift_say_not_compared "$prog" "$rc" "$drift"
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
    vendor_drift_say_classifier_broke "$prog" "$tracked_only"
    tracked_only=yes
    at_risk="$classified"
  fi

  local age age_state tracked_epoch refresh_epoch decided reading reason
  age="$(vendor_drift_tracked_age "$repo_root" "$tracked_rel")"
  age_state="${age%%$'\t'*}"
  tracked_epoch="${age#*$'\t'}"
  refresh_epoch="$(vendor_drift_refresh_epoch "$mirror")"
  decided="$(vendor_drift_direction \
    "$age_state" "$tracked_epoch" "$refresh_epoch" "$tracked_only" "$engine")"
  reading="${decided%%$'\t'*}"
  reason="${decided#*$'\t'}"

  vendor_drift_say_drifted "$prog" "$engine"
  vendor_drift_print_sides "$prog" "$engine" "$repo_root" \
    "$tracked_epoch" "$refresh_epoch" "$age_state" >&2
  vendor_drift_print_diff "$drift"
  vendor_drift_print_repairs "$prog" "$engine" "$repo_root" "$reading" "$reason" \
    "$confirm_mirror" "$tracked_only" "$at_risk" >&2
  return 1
}
