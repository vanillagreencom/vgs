#!/usr/bin/env bash
# Shared drift check for the vstack engines VGS vendors into third_party/.
# Sourced by scripts/check-review-gate-vendor.sh and
# scripts/check-size-ratchet-vendor.sh; scripts/lib/vendor-drift-report.sh is
# the other half. Which half holds what, and that the dependency runs one way,
# are asserted by the contract controls in scripts/test-vendor-drift-contracts.sh
# rather than described here.
#
# WHY THERE ARE TWO COPIES. An engine has to be IN the repository: CI runs it
# from a plain checkout, which has no vstack and no shared skills mirror. The
# sibling repos track theirs at `.agents/skills/`, but VGS symlinks `.agents`
# wholesale into every worktree (AGENTS.md § Project skills), so a file tracked
# under that path reports as deleted in every worktree — git cannot stat through
# the symlinked directory, leaving a permanently dirty tree. So the tracked,
# CI-facing copy lives at third_party/<engine>/, `vstack refresh` maintains
# .agents/skills/<engine> for agent discovery, and this check stops the two from
# drifting. Cite THIS paragraph for the two-copy rationale.
#
# WHY THE REPAIR IS NOT A CONSTANT (VGS-155). Drift happens in BOTH directions,
# and this check once printed the mirror→tracked rsync unconditionally, as a
# procedure — which, run right after a vendoring PR merged, DELETED the merged
# change and then went green on the reverted content.
#
# THE LIMIT OF THE EVIDENCE. There is no per-skill source revision to compare:
# `.vstack-refreshed` holds one value for every skill a refresh wrote. So the
# signals are the tracked copy's commit time, that marker's mtime, and which
# side holds content the other lacks — three weak signals rather than one
# authoritative one, which is why `undetermined` is a real answer here. If
# vstack ever records the source revision each skill was installed from, that
# becomes exact and vendor_drift_direction should use it instead.
#
# SIZE EXCEPTION, BASELINED. This file carries a size-ratchet baseline row
# above the 400-line threshold. It was argued and granted, not inherited: the
# file is MAJORITY CODE — 253 code to 146 comment — and the growth is rounds of
# reviewer-demanded fixes, not padding. The prose-to-guard audit already ran
# here and converted everything convertible, taking it 425 to 369 with code
# unchanged, which REMOVED an earlier exception rather than arguing for one; the
# comments left are the residue that cannot execute (the VGS-155 incident, why a
# prefix test was tried and defeated, the limits of the evidence). The baseline
# only ever moves DOWN, so this file cannot grow again without the same
# argument. Reason also recorded in tools/size-ratchet-excludes and
# vstack.settings.toml, since the baseline row itself cannot carry a comment.
#
# Entry point: vendor_drift_main <prog> <engine> <repo_root> [ARGS...], where
# <engine> names both paths by convention — third_party/<engine> and
# .agents/skills/<engine> — which is also what lets the tests drive the whole
# check against a fixture repo root.

set -euo pipefail

# shellcheck source=scripts/lib/vendor-drift-report.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/vendor-drift-report.sh"

# Report `Only in DIR: NAME` as the path it refers to, given the root that line
# was matched against. Prints NOTHING when the line does not parse into that
# root — the caller then records the raw line, which is the classifier's
# documented "could not attribute a path" mode, and is the fail-closed answer.
#
# WHY THIS IS NOT A SPLIT AT THE FIRST `: `. GNU diff SHELL-QUOTES a name or a
# directory containing a space, so `Only in 'm/foo: bar': doomed.txt` is a real
# line — and splitting it at the first `: ` yielded `m/foo/bar': doomed.txt`, a
# path that does not exist. An at-risk list is read by an operator deciding
# whether to run a destructive command, so naming a file that is not the one at
# risk is the whole of VGS-155 in one line. Unquoted is unambiguous by
# construction: no space means no `: `, so the first one is the separator.
vendor_drift_only_in_path() {
  local line="$1" root="$2" rest dir name
  rest="${line#Only in }"
  if [[ "$rest" == \'* ]]; then
    # Quoted: the directory ends at the closing quote, which `: ` follows.
    [[ "$rest" == *"': "* ]] || return 0
    dir="${rest%%\': *}"
    dir="${dir#\'}"
    name="${rest#*\': }"
  else
    # The separator must EXIST before it can be split on: both expansions below
    # return the WHOLE string when it does not, which fabricated `<root>/<root>`
    # out of a line that had no separator at all.
    [[ "$rest" == *': '* ]] || return 0
    # And UNAMBIGUOUS. That an unquoted directory cannot contain `: ` is a
    # property of the local diffutils, not of the format, and no machine here is
    # pinned to the version measured. Two separators make the split a guess.
    [[ "${rest%%: *}" == "${rest%: *}" ]] || return 0
    dir="${rest%%: *}"
    name="${rest#*: }"
  fi
  # The name is quoted independently of the directory.
  name="${name#\'}"
  name="${name%\'}"
  # Anchored: a parse that does not land inside the root diff was given is not a
  # path this can vouch for, so it says nothing rather than guessing.
  [[ -n "$dir" && -n "$name" && "$dir" == "$root"* ]] || return 0
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
# HEADERS ARE RECOGNISED BY POSITION, NOT BY PREFIX, and everything the parser
# cannot attribute counts as tracked-side. Both are executed in
# scripts/test-vendor-drift-evidence.sh — one fixture per ignore arm, plus the
# shapes that defeated the two earlier prefix tests — so neither is restated
# here. What those fixtures cannot record is WHY: a prefix test was tried twice
# and defeated twice, because these trees are documentation ABOUT diffs and
# vendored paths and so contain lines that look like diff headers. A prefix test
# is a guess, and the destructive question is the one thing here that may not be
# guessed. The cost of the choice is over-withholding.
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
          if [[ "$current" == \"*\" ]]; then
            # GNU diff C-QUOTES a header path containing a tab, quote,
            # backslash or newline, and stripping the outer quotes leaves the
            # ESCAPE in place — a name that does not exist, which every `+` line
            # below would then be recorded against. Decoding C escapes exactly
            # has its own ways to be subtly wrong, and a plausible wrong path is
            # worse than an honest one, so an escaped header attributes NOTHING.
            current="${current#\"}"
            current="${current%\"}"
            [[ "$current" != *\\* ]] || current=""
          fi
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
        entry="$(vendor_drift_only_in_path "$line" "$tracked_rel")"
        entry="${entry:-$line}"
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
# THESE ARE READINGS, NOT VERDICTS: what a merged DELETION and an upstream
# addition have in common is that neither can be told apart from the other here,
# so `mirror-ahead` names no repair alone. That, the disjointness of the two
# decided readings, and every unusable-evidence row are driven directly in the
# decision-table rows of scripts/test-vendor-drift-evidence.sh.
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
  # `usable` is a CLAIM about the epoch, enforced rather than trusted.
  if [[ -z "$tracked_epoch" || -n "${tracked_epoch//[0-9]/}" ]]; then
    printf 'undetermined\tthe tracked commit time was reported as %q, which is not a timestamp' "$tracked_epoch"
    return 0
  fi
  if [[ -n "${refresh_epoch//[0-9]/}" ]]; then
    printf 'undetermined\tthe mirror refresh time was reported as %q, which is not a timestamp' "$refresh_epoch"
    return 0
  fi
  if [[ -z "$refresh_epoch" ]]; then
    printf 'undetermined\tthe mirror .vstack-refreshed marker yielded no usable time — absent, or present and unreadable — so there is nothing to compare its age against'
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

# Seconds since the epoch for a path's mtime, or nothing. GNU `stat` only, by
# choice: these checks are local-only on a Linux workstation, and an untested
# BSD fallback is the fail-open shape this file exists to avoid.
vendor_drift_mtime_epoch() {
  stat -c %Y -- "$1" 2>/dev/null || return 1
}

# When `vstack refresh` last wrote the mirror, from its own per-refresh marker.
# The directory's mtime stood in for this once: it moves when any unrelated
# entry is created or removed and does NOT move when a refresh rewrites files in
# place, so it is a guess in both directions and no longer used.
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
#   shallow         a shallow clone, where git reports the tip date for every
#                   path — the evidence suite's fixture reproduces it
#   no-history      no commit in this repository touches the path
#   dirty           uncommitted changes, so the last commit time has stopped
#                   describing the tree
vendor_drift_tracked_age() {
  local repo_root="$1" path="$2" shallow porcelain epoch

  if ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'git-unreadable\t'
    return 0
  fi
  # A probe that cannot answer says so; anything but `false` is read as shallow.
  # Both halves are driven by stubs in scripts/test-vendor-drift-evidence.sh.
  if ! shallow="$(git -C "$repo_root" rev-parse --is-shallow-repository 2>/dev/null)"; then
    printf 'git-unreadable\t'
    return 0
  fi
  if [[ "$shallow" != false ]]; then
    printf 'shallow\t'
    return 0
  fi
  if ! epoch="$(git -C "$repo_root" log -1 --format=%ct -- "$path" 2>/dev/null)"; then
    # An unborn HEAD fails here rather than returning empty, and that IS
    # "no history" rather than an unreadable git.
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

  # Repo-relative paths so each hunk carries both real file names; `--label`
  # would replace them with one constant pair, which is why it is not used here.
  # `LC_ALL=C` follows the `LC_ALL=C sort` precedent in scripts/validate.
  # `.vstack-refreshed` is vstack's own bookkeeping, not engine content.
  #
  # `cd` runs inside the substitution's subshell so the caller's cwd is never
  # moved. Exit 3 is the sentinel for "cd failed" — diff uses 0, 1 and 2 only.
  # LIMIT: that branch guards the window after the directory checks and is
  # deliberately not fixture-reachable, since an unenterable root fails `-d`
  # first; the diff-trouble branch below is reachable and is pinned.
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
  # The classifier's own contract, enforced rather than assumed.
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
