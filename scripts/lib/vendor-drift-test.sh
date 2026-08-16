#!/usr/bin/env bash
# The harness the three suites run through. What each takes differs, and the
# difference matters:
#
#   scripts/test-vendor-drift.sh           the assertion helpers, the fixture
#   scripts/test-vendor-drift-evidence.sh  builders and run_check — so the three
#                                          invariants apply to every case in them
#   scripts/test-vendor-drift-contracts.sh the assertion helpers, the failures
#                                          counter, and the caller-sweep set
#                                          (vendor_drift_caller_surfaces,
#                                          flag_carriers, CONFIRM_FLAG,
#                                          new_caller_fixture). It never calls
#                                          run_check, so the three invariants do
#                                          NOT apply to it — that is the
#                                          load-bearing half of this table
#
# The lists are what each suite takes today, not a promise: the caller-sweep set
# has one consumer and moved here with it.
#
# The invariants hold for EVERY case that goes through run_check, rather than
# for the ones that remember to check.
#
# Split out of that file when it crossed the size-ratchet threshold, at the seam
# between the machinery and the cases. The invariants live here deliberately:
# they are the acceptance bar for the whole check, so they belong where no new
# case can be written without them applying.
#
# Requires, from the sourcing script: repo_root, tmp, PROG, ENGINE.
#
# GNU-ONLY, DELIBERATELY. The fixtures below use `touch -d @epoch` and GNU
# `git`, matching the GNU-only `stat` and `date` the libraries require. There is
# no BSD path in the fixtures because there is none in the code they exercise;
# the libraries return nothing rather than guessing where those tools differ,
# which reads as unknown and answers undetermined.
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

# Fixed epochs, so the readings depend on the ORDER the cases state and never on
# when they run. REFRESH sits between the two commit times, which is what makes
# "commit before the refresh" and "commit after the refresh" two cases rather
# than a race. Defined here so both suites use one set.
# Each carries its own directive: a disable applies to the next command only,
# and all three are read by the suites across the source seam.
# shellcheck disable=SC2034
COMMIT_OLD=1700000000 # 2023-11-14T22:13:20Z
# shellcheck disable=SC2034
REFRESH=1700003600
# shellcheck disable=SC2034
COMMIT_NEW=1700007200

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
# Whole-line membership in a newline-separated list. A `contains` check is not
# enough for at-risk entries: the raw diff line that produced one also contains
# the path, so a substring assertion stays green when the classifier records the
# line instead of the file.
expect_line_in() {
  # Both ends padded: command substitution strips the list's trailing newline,
  # so the last entry has none to match against.
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) ;;
    *) fail "$3" "expected a line exactly: $2"$'\n'"--- got ---"$'\n'"$1" ;;
  esac
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

# The tracked-ahead READING, with its prefix. The bare phrase also appears in
# condition (1) of the both-repairs block, so an assertion that a run did NOT
# reach this reading has to name the line.
# shellcheck disable=SC2034 # read by the cases across the source seam.
READING_TRACKED_AHEAD="$PROG: the TRACKED copy is newer"

# Safety claims the check must never make about the mirror-to-tracked rsync. In
# a deletion-shaped drift the rsync genuinely deletes nothing and still reverts
# a merged removal, so "loses nothing" is false exactly where it reads most
# reassuring.
SAFETY_CLAIMS=(
  "loses nothing"
  "would delete nothing"
  "costs nothing"
  "safe to run"
)
# A heading that PROMISES a list of what dies. Printing it without the list is
# the same false reassurance the claims above are banned for, arrived at by
# punctuation instead of by wording: a colon answered with nothing reads as a
# cost of nothing. Deletion-shaped drift under --confirm-mirror-is-newer printed
# exactly that, on the one shape that IS the incident this check exists for.
COST_PROMISE="DESTROYS:"

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

# The list's own heading, which vendor_drift_print_at_risk prints and nothing
# else does. The invariant below keys on THIS, not on AT_RISK_PREFIX: the
# rsync's continuation line carries the same eight-space indent, so a prefix
# test could never observe the list missing — vacuous in exactly the way this
# suite keeps catching elsewhere.
# shellcheck disable=SC2034 # read by the cases across the source seam.
AT_RISK_HEADING="content this check reads as tracked-side"

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

  # THE COST LIST IS AN INVARIANT, not a property of the branch that happened to
  # print it. The rule: the command printed, over a run whose tracked side holds
  # content, means the list of that content is printed too. Ground truth comes
  # from the classifier over the same diff the check just made, so this cannot
  # drift with the report. A point fix repairs one branch; this stops any future
  # branch diverging from the promise the header makes.
  if [[ "$out$err" == *"$DRIFT_BANNER"* && "$out$err" == *"$RSYNC_COMMAND"* ]]; then
    # Two statements, not a pipeline: `diff` exits 1 on differences, which under
    # `pipefail` fails the whole substitution and aborts the caller — the same
    # errexit trap this suite exists to keep catching.
    local drift_text truth
    drift_text="$(
      cd -- "$root" &&
        LC_ALL=C diff -r -u --exclude=.vstack-refreshed \
          -- ".agents/skills/$ENGINE" "third_party/$ENGINE" 2>/dev/null
    )" || true
    truth="$(vendor_drift_classify "third_party/$ENGINE" ".agents/skills/$ENGINE" <<<"$drift_text")"
    if [[ "${truth%%$'\n'*}" == yes && "$out$err" != *"$AT_RISK_HEADING"* ]]; then
      fail "cost-list invariant" "the rsync printed over tracked-side content with no list of what it destroys"
    fi
  fi

  # THE PROMISE AND THE LIST TRAVEL TOGETHER, on every run rather than in the
  # branch that happened to get it right. Asserted as an invariant for the same
  # reason as the cost list above: a point fix repairs one branch, and the
  # branch that had this wrong was the one no case drove.
  if [[ "$out$err" == *"$COST_PROMISE"* && "$out$err" != *"$AT_RISK_HEADING"* ]]; then
    fail "cost-promise invariant" "the output promises \"$COST_PROMISE\" and then lists nothing, which reads as a cost of nothing"
  fi

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

# Every TRACKED automation surface that could invoke the check, from git rather
# than from a find that silently returns nothing: a renamed workflows directory
# left the old discovery printing ok with a carrier sitting outside it. The
# caller asserts the result is non-empty and contains the known callers, so an
# enumeration that stops finding things fails loudly instead of passing.
#   $1 the repository root to enumerate, defaulting to the live repo_root
# `:(glob)` so `*` does not cross `/`: a plain git pathspec would sweep
# scripts/lib/ too, and those files DEFINE the flag — its option arm, its usage
# text, its messages. A caller is something that could PASS it, which the
# libraries and the suites themselves are not.
vendor_drift_caller_surfaces() {
  local root="${1:-$repo_root}"
  git -C "$root" ls-files -- \
    ':(glob)scripts/*.sh' 'scripts/validate' \
    ':(glob).github/workflows/*.yml' ':(glob).github/workflows/*.yaml' |
    grep -vE '^scripts/test-vendor-drift[^/]*\.sh$' |
    sed "s|^|$root/|"
}

# A throwaway repository laid out like this one, for planting carriers into.
# The sweep used to plant into the LIVE repo: concurrent runs fought over one
# index, an unguarded `git add -N` aborted the whole suite under errexit with
# neither an ok marker nor a FAIL line, and because the abort preceded the
# cleanup it could leave a file containing the destructive flag at a
# tracked-looking path. A test that writes that flag into the repository it is
# testing is not a shape to patch; this is the shape instead.
new_caller_fixture() {
  local root="$tmp/$1"
  mkdir -p "$root/scripts" "$root/.github/workflows"
  printf '#!/usr/bin/env bash\n# stand-in for the manifest\n' >"$root/scripts/validate"
  printf '#!/usr/bin/env bash\n# stand-in for a wrapper\n' >"$root/scripts/check-review-gate-vendor.sh"
  printf 'name: ci\non: [push]\n' >"$root/.github/workflows/ci.yml"
  git -C "$root" init -q -b main
  git -C "$root" config user.email test@example.invalid
  git -C "$root" config user.name "vendor drift test"
  git -C "$root" config commit.gpgsign false
  git -C "$root" add -A
  git -C "$root" commit -q -m "caller surfaces"
  printf '%s' "$root"
}

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

# A DEPTH-1 CLONE of a fixture whose vendoring commit is not the tip. Echoes the
# clone root. This is the one fixture that must be a real clone: the defect is
# that `git log -1 -- <path>` reports the TIP date in a shallow repository for
# every path, touched or not, so a stub could only restate the assumption.
#
#   commit A ($2)  both copies identical
#   commit B ($3)  touches the MIRROR only — so the tracked copy's true age is
#                  A, while a shallow clone reports B
new_shallow_fixture() {
  local name="$1" old_epoch="$2" new_epoch="$3" src root
  src="$(new_fixture "$name-src")"
  printf '0000000\n' >"$src/.agents/skills/$ENGINE/.vstack-refreshed"
  commit_tracked "$src" "$old_epoch"
  printf 'shared line\nnew upstream line\n' \
    >"$src/.agents/skills/$ENGINE/references/settings.md"
  commit_tracked "$src" "$new_epoch"
  root="$tmp/$name"
  git clone -q --depth 1 "file://$src" "$root"
  printf '%s' "$root"
}

# A `git` first on PATH that intercepts ONE subcommand or flag and delegates
# everything else to the real one, so the fixture keeps a real repository behind
# it. Echoes the directory to prepend; the caller checks the interception took.
#   $1 name  $2 the argument to match  $3 the shell body to run on a match
new_git_stub() {
  local dir="$tmp/gitstub-$1"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # the STUB's body: $@ and $a stay literal
    printf 'for a in "$@"; do [[ "$a" == %q ]] && { %s; }; done\n' "$2" "$3"
    printf 'exec %q "$@"\n' "$(command -v git)"
  } >"$dir/git"
  chmod +x "$dir/git"
  printf '%s' "$dir"
}
