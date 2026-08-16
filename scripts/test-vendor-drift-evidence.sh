#!/usr/bin/env bash
# Controls for the EVIDENCE layer of the vendor drift check
# (scripts/lib/vendor-drift.sh, VGS-155): how a diff line is attributed to a
# side, when a commit time can be trusted, and how the two are read together.
# What the check reports on top of that — repairs, preconditions, wrappers — is
# scripts/test-vendor-drift.sh, and what the libraries promise about their own
# shape is scripts/test-vendor-drift-contracts.sh. The parser and the reading
# are driven directly here, so a shape can be pinned without a fixture that
# produces it; the age states need real repositories and get them.
#
# WHY THIS FILE EXISTS. The classifier decides whether the mirror-to-tracked
# rsync can destroy content, by matching human-readable diff text. It used to
# FAIL OPEN — no default arm, so any line it did not recognise was dropped and
# left "nothing is at risk", which is how a tracked-only content line reading
# `++ x`, a file-vs-directory difference, and a locale-translated marker each
# reached the destructive command. The property under test is therefore not
# "the known shapes are classified", it is "an UNKNOWN shape is treated as
# content at risk".
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

TRACKED_REL="third_party/$ENGINE"
MIRROR_REL=".agents/skills/$ENGINE"

# What `diff -r -u` actually emits before a differing pair. Headers are
# recognised by POSITION now, so a fixture feeding a bare `+++ ` line is not a
# header — it is content, which is the whole point — and every fixture that
# means "a header" has to say it the way diff does.
PAIR="diff -r -u -- $MIRROR_REL/references/settings.md $TRACKED_REL/references/settings.md"$'\n'"--- $MIRROR_REL/references/settings.md	2023-11-14"$'\n'"+++ $TRACKED_REL/references/settings.md	2023-11-14"

class_tracked_only=""
class_at_risk=""
classify() {
  local result
  result="$(vendor_drift_classify "$TRACKED_REL" "$MIRROR_REL" <<<"$1")"
  class_tracked_only="${result%%$'\n'*}"
  class_at_risk=""
  # An `if`, not `[[ ]] && ...`: as the last statement of a function the latter
  # returns 1 whenever the pattern does not match, which aborts the caller under
  # errexit. That is a real trap, not a style point — it is how this helper
  # first behaved.
  if [[ "$result" == *$'\n'* ]]; then
    class_at_risk="${result#*$'\n'}"
  fi
}

# $1 label, $2 expected yes|no, $3 diff text, $4 optional at-risk entry.
# The entry is matched as a WHOLE LINE: every at-risk path also appears inside
# the raw diff line that produced it, so a substring match cannot tell "recorded
# the file" from "recorded the line it could not attribute".
expect_class() {
  local label="$1" expected="$2" input="$3" entry="${4:-}"
  classify "$input"
  [[ "$class_tracked_only" == "$expected" ]] ||
    fail "$label" "expected tracked_only=$expected, got $class_tracked_only"$'\n'"--- input ---"$'\n'"$input"
  [[ -z "$entry" ]] || expect_line_in "$class_at_risk" "$entry" "$label"
}

# ── lines that are provably not tracked-side evidence ─────────────────────
# Each ignore arm is one chance to drop something that mattered, so each is
# pinned on its own rather than as a block.
expect_class "context line" no " shared line"
expect_class "empty context line" no ""
expect_class "mirror-only content" no "-only the mirror has this"
expect_class "hunk header" no "@@ -1,2 +1 @@"
expect_class "diff provenance line" no "diff -r -u -- $MIRROR_REL/a $TRACKED_REL/a"
expect_class "no-newline marker" no '\ No newline at end of file'
expect_class "mirror file header" no "--- $MIRROR_REL/references/settings.md	2023-11-14"
# The quoted form, the one ignore arm that had no case of its own. The input has
# to run past the `---` line to bite: a line starting with `-` is swallowed by
# the mirror-content arm anyway, so stopping there classifies the same with the
# quoted arm present or gone. What the arm actually decides is whether the NEXT
# line is in header position — so the entry is the FILE, not the header line.
expect_class "mirror file header, quoted" yes \
  "diff -r -u -- \"$MIRROR_REL/with space.md\" \"$TRACKED_REL/with space.md\""$'\n'"--- \"$MIRROR_REL/with space.md\""$'\n'"+++ \"$TRACKED_REL/with space.md\""$'\n'"+a tracked-only row" \
  "$TRACKED_REL/with space.md"
expect_class "tracked file header" no "$PAIR"
expect_class "file only the mirror has" no "Only in $MIRROR_REL/references: retired.md"
# GNU diff SHELL-quotes the directory when it contains a space — a different
# quoting style from the double quotes it uses in the unified headers. Unquoted
# anchors alone made a MIRROR-only file read as tracked-side, which withheld the
# rsync permanently for any engine shipping such a directory and printed a
# mirror path under a heading saying the tracked copy held it.
expect_class "file only the mirror has, quoted directory" no \
  "Only in '$MIRROR_REL/sub dir': extra.md"
ok "every ignore arm attributes its line to the mirror side or to structure"

# ── lines that ARE tracked-side evidence ──────────────────────────────────
expect_class "tracked-only content" yes \
  "$PAIR"$'\n'"+a tracked-only row" \
  "$TRACKED_REL/references/settings.md"
expect_class "file only the tracked copy has" yes \
  "Only in $TRACKED_REL/references: error-patterns.md" \
  "$TRACKED_REL/references/error-patterns.md"
expect_class "file only the tracked copy has, quoted directory" yes \
  "Only in '$TRACKED_REL/sub dir': error-patterns.md" \
  "$TRACKED_REL/sub dir/error-patterns.md"
# A directory containing `: `. Splitting at the first produced a path that does
# not exist, in a list an operator reads before running a destructive command.
expect_class "tracked-only file under a directory containing a colon-space" yes \
  "Only in '$TRACKED_REL/foo: bar': doomed.txt" \
  "$TRACKED_REL/foo: bar/doomed.txt"
ok "tracked-only content and tracked-only files are both counted, and named"

# ── the shapes that used to escape ────────────────────────────────────────
# A tracked-only CONTENT line reading `++ x` is printed by unified diff as
# `+++ x`, which the old parser ate as a file header. The header arm is anchored
# to the root diff was given, so this is content again.
expect_class "content line that looks like a header" yes \
  "$PAIR"$'\n'"+++ a line that itself begins with ++" \
  "$TRACKED_REL/references/settings.md"
# The shape that defeated the anchored prefix test: content naming the tracked
# root itself. Out of header position, so it is content.
expect_class "content naming the tracked root" yes \
  "$PAIR"$'\n'"+++ $TRACKED_REL/references/x.md is discussed here" \
  "$TRACKED_REL/references/settings.md"
# GNU diff QUOTES a header whose path contains a space. Still a header, so the
# content below it is attributed to that file rather than to the header line.
expect_class "quoted tracked file header" yes \
  "diff -r -u -- \"$MIRROR_REL/references/with space.md\" \"$TRACKED_REL/references/with space.md\""$'\n'"--- \"$MIRROR_REL/references/with space.md\""$'\n'"+++ \"$TRACKED_REL/references/with space.md\""$'\n'"+a tracked-only row" \
  "$TRACKED_REL/references/with space.md"
# A `+++ ` header naming neither root is not a header this run produced.
expect_class "header for a foreign root" yes "+++ /somewhere/else/file.md"
# GNU diff emits the SINGULAR "File" here, matching no marker the parser knows.
expect_class "file versus directory" yes \
  "File $MIRROR_REL/references/thing is a regular file while file $TRACKED_REL/references/thing is a directory" \
  "File $MIRROR_REL/references/thing is a regular file while file $TRACKED_REL/references/thing is a directory"
# Under another locale the markers are translated. LC_ALL=C on the diff keeps
# that from happening; the default arm keeps it SAFE if it ever does.
expect_class "translated marker" yes "Nur in $MIRROR_REL/references: retired.md"
expect_class "binary difference" yes \
  "Binary files $MIRROR_REL/references/f.bin and $TRACKED_REL/references/f.bin differ" \
  "Binary files $MIRROR_REL/references/f.bin and $TRACKED_REL/references/f.bin differ"
expect_class "a line kind that does not exist yet" yes "Some future diff remark"
expect_class "Only in under a foreign root" yes \
  "Only in somewhere/else: x.md" "Only in somewhere/else: x.md"
ok "every unrecognised shape counts as content the rsync would destroy"


# ── evidence that cannot be READ ──────────────────────────────────────────
# Each of these resolves to undetermined with its own cause named. Wrong-cause
# output is the failure being guarded: the reason must describe the decision
# that was actually made.
root="$(new_fixture dirty-tracked)"
set_refresh "$root" "$REFRESH"
commit_tracked "$root" "$COMMIT_NEW"
printf 'shared line\nedited in the working tree\n' \
  >"$root/third_party/$ENGINE/references/settings.md"
run_check "$root"
expect_rc "$rc" 1 "dirty tracked"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "dirty tracked"
expect_contains "$err" "has uncommitted changes" "dirty tracked"
expect_absent "$err" "$RSYNC_COMMAND" "dirty tracked"
ok "uncommitted changes under third_party disqualify the commit-time evidence"

root="$(new_fixture uncommitted)"
printf 'shared line\ntracked-only line\n' \
  >"$root/third_party/$ENGINE/references/settings.md"
set_refresh "$root" "$REFRESH"
run_check "$root"
expect_rc "$rc" 1 "no history"
expect_contains "$err" "no commit in this repository touches third_party/$ENGINE" "no history"
expect_absent "$err" "$RSYNC_COMMAND" "no history"
ok "a tracked copy with no commit history yields no direction and no rsync"

root="$(new_fixture_nogit no-repository)"
printf 'shared line\nmirror-only line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
set_refresh "$root" "$REFRESH"
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  fail "no repository" "fixture precondition unmet: $root is inside a git repository"
fi
run_check "$root"
expect_rc "$rc" 1 "no repository"
expect_contains "$err" "git could not be consulted for third_party/$ENGINE" "no repository"
expect_contains "$err" "commit state unreadable" "no repository"
expect_absent "$err" "no commit in this repository" "no repository"
ok "an absent repository is reported as unreadable git, not as a repository with no commit"

root="$(new_fixture no-marker)"
commit_tracked "$root" "$COMMIT_OLD"
printf 'shared line\nnew upstream line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
run_check "$root"
expect_rc "$rc" 1 "no refresh marker"
expect_contains "$err" "yielded no usable time" "no refresh marker"
expect_contains "$err" "last refreshed unknown" "no refresh marker"
ok "a mirror with no refresh marker has no age, rather than borrowing the directory mtime"

# ── a shallow clone reports the tip date for every path ───────────────────
# `git log -1 --format=%ct -- <path>` answers with the TIP commit in a --depth 1
# clone whether or not that commit touched the path. The tip normally beats the
# mirror's refresh mtime, so a genuine mirror-ahead drift read as a confident
# `tracked-ahead` and told the operator NOT to copy the mirror across — pointing
# away from the only correct repair. Here the vendoring commit is deliberately
# not the tip.
root="$(new_shallow_fixture shallow-clone "$COMMIT_OLD" "$COMMIT_NEW")"
set_refresh "$root" "$REFRESH"
[[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] ||
  fail "shallow clone" "fixture precondition unmet: the clone is not shallow"
run_check "$root"
expect_rc "$rc" 1 "shallow clone"
expect_contains "$err" "which side is newer is NOT ESTABLISHED" "shallow clone"
expect_contains "$err" "this is a shallow clone" "shallow clone"
expect_contains "$err" "shallow clone: no usable age" "shallow clone"
expect_absent "$err" "$READING_TRACKED_AHEAD" "shallow clone"
expect_absent "$err" "Do NOT copy the mirror over" "shallow clone"
ok "a shallow clone has no usable commit age, rather than a confident tracked-ahead"

# ── a git that answers the shallow question with something else ──────────
# Only the first half of "anything but `false` is read as shallow" was executed:
# a probe that FAILS was covered, one that SUCCEEDS oddly was not, so `!= false`
# could become `== true` and kill nothing. A wrapper or a noisy alias is how
# that arrives.
root="$(new_fixture git-probe-odd)"
printf 'shared line\nnew upstream line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
commit_tracked "$root" "$COMMIT_NEW"
set_refresh "$root" "$REFRESH"
stub="$(new_git_stub shallow-odd --is-shallow-repository 'echo maybe; exit 0')"
if [[ "$(PATH="$stub:$PATH" git -C "$root" rev-parse --is-shallow-repository)" != maybe ]]; then
  fail "odd shallow answer" "stub precondition unmet: the probe did not answer maybe"
else
  saved_path="$PATH"
  PATH="$stub:$PATH"
  run_check "$root"
  PATH="$saved_path"
  expect_rc "$rc" 1 "odd shallow answer"
  expect_contains "$err" "this is a shallow clone" "odd shallow answer"
  expect_absent "$err" "$READING_TRACKED_AHEAD" "odd shallow answer"
fi
ok "a probe answering anything but false is read as shallow, not as a full repository"

# ── a git that cannot answer the shallow question ─────────────────────────
# The probe is the only thing standing between a shallow clone and a confident
# wrong direction, so a git that cannot answer it must not be read as "full".
# Driven with a stub first on PATH that fails ONLY that subcommand and delegates
# everything else to the real git — the same stub technique
# scripts/test-smoke-surfaces.sh uses for its precondition classifier.
root="$(new_fixture git-probe-fails)"
printf 'shared line\nnew upstream line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
commit_tracked "$root" "$COMMIT_NEW"
set_refresh "$root" "$REFRESH"
stub="$(new_git_stub shallow-fails --is-shallow-repository 'exit 3')"
# The stub only proves something if it really intercepts.
if PATH="$stub:$PATH" git -C "$root" rev-parse --is-shallow-repository >/dev/null 2>&1; then
  fail "git probe fails" "stub precondition unmet: the probe still answered"
else
  saved_path="$PATH"
  PATH="$stub:$PATH"
  run_check "$root"
  PATH="$saved_path"
  expect_rc "$rc" 1 "git probe fails"
  expect_contains "$err" "which side is newer is NOT ESTABLISHED" "git probe fails"
  expect_contains "$err" "git could not be consulted" "git probe fails"
  expect_absent "$err" "$READING_TRACKED_AHEAD" "git probe fails"
fi
ok "a git that cannot answer the shallow question yields no direction"

# ── a git log that fails, in a repository that has commits ───────────────
# An empty result means no commit touches the path; a FAILURE means git could
# not be consulted, and reporting the second as the first is the wrong-cause
# family. Same stub technique: fail only `log`, delegate the rest.
root="$(new_fixture git-log-fails)"
printf 'shared line\nnew upstream line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
stub="$(new_git_stub log-fails log 'exit 3')"
if PATH="$stub:$PATH" git -C "$root" log -1 >/dev/null 2>&1; then
  fail "git log fails" "stub precondition unmet: log still answered"
else
  saved_path="$PATH"
  PATH="$stub:$PATH"
  run_check "$root"
  PATH="$saved_path"
  expect_rc "$rc" 1 "git log fails"
  expect_contains "$err" "git could not be consulted" "git log fails"
  expect_absent "$err" "no commit in this repository touches" "git log fails"
fi
ok "a git log that fails is unreadable git, not a repository with no such commit"

# ── the reading, and the cause it reports ─────────────────────────────────
# Every row asserts the REASON as well as the reading: an explanation that
# describes a decision other than the one made is the defect this pins. The two
# decided readings are disjoint on the epoch comparison, so no ordering trick is
# load-bearing — what is load-bearing is that unreadable evidence is answered
# before either.
while IFS='|' read -r state tracked refresh tracked_only expected fragment; do
  [[ -n "$expected" ]] || continue
  [[ "$tracked" != EMPTY ]] || tracked=""
  [[ "$refresh" != EMPTY ]] || refresh=""
  decided="$(vendor_drift_direction "$state" "$tracked" "$refresh" "$tracked_only" "$ENGINE")"
  reading="${decided%%$'\t'*}"
  reason="${decided#*$'\t'}"
  label="direction($state,$tracked,$refresh,$tracked_only)"
  [[ "$reading" == "$expected" ]] || fail "decision table" "$label expected $expected, got $reading"
  if [[ -n "$fragment" ]]; then
    expect_contains "$reason" "$fragment" "decision table"
  elif [[ -n "$reason" ]]; then
    fail "decision table" "$label is a decided reading but carries reason: $reason"
  fi
done <<TABLE
usable|1700007200|1700003600|no|tracked-ahead|
usable|1700007200|1700003600|yes|tracked-ahead|
usable|1700000000|1700003600|no|mirror-ahead|
usable|1700000000|1700003600|yes|undetermined|PULLED IN after that refresh
usable|1700003600|1700003600|no|undetermined|both timestamps are identical
usable|1700000000|EMPTY|no|undetermined|yielded no usable time
dirty|EMPTY|1700003600|no|undetermined|has uncommitted changes
git-unreadable|EMPTY|1700003600|no|undetermined|git could not be consulted
no-history|EMPTY|1700003600|no|undetermined|no commit in this repository
shallow|EMPTY|1700003600|no|undetermined|this is a shallow clone
shallow|EMPTY|EMPTY|no|undetermined|this is a shallow clone
bogus-state|EMPTY|1700003600|no|undetermined|unrecognised state bogus-state
usable|EMPTY|1700003600|no|undetermined|which is not a timestamp
usable|not-a-number|1700003600|no|undetermined|which is not a timestamp
usable|1700000000|not-a-number|no|undetermined|which is not a timestamp
TABLE
ok "every row reads as written and reports the cause of that reading, not another"

# ── the two decided readings are disjoint, so their order is immaterial ────
# The prose claimed this; driving it is what makes it true. A `>=` in either
# comparison would overlap them at equality and this fires.
for pair in "100 100" "100 200" "200 100"; do
  # shellcheck disable=SC2086 # the pair IS the argument list; splitting is the point
  set -- $pair
  decided="$(vendor_drift_direction usable "$1" "$2" no "$ENGINE")"
  case "${decided%%$'\t'*}" in
    tracked-ahead) (($1 > $2)) || fail "disjoint readings" "tracked-ahead at tracked=$1 refresh=$2" ;;
    mirror-ahead) (($2 > $1)) || fail "disjoint readings" "mirror-ahead at tracked=$1 refresh=$2" ;;
    *) (($1 == $2)) || fail "disjoint readings" "undetermined at a strict ordering: tracked=$1 refresh=$2" ;;
  esac
done
ok "a decided reading implies its own strict ordering, so neither rule can shadow the other"

# ── each unusable state carries its own cause ─────────────────────────────
# Two functions once computed the state and the reason separately and diverged,
# reporting an unreadable git while asserting a repository that did not exist.
# One owner now, and no two states may report the same cause.
seen_reasons=""
for state in git-unreadable shallow no-history dirty; do
  decided="$(vendor_drift_direction "$state" "" 1700003600 no "$ENGINE")"
  reason="${decided#*$'\t'}"
  [[ -n "$reason" ]] || fail "one cause per state" "state $state reports no cause at all"
  case $'\n'"$seen_reasons" in
    *$'\n'"$reason"$'\n'*) fail "one cause per state" "state $state reuses another state's cause: $reason" ;;
  esac
  seen_reasons+="$reason"$'\n'
done
ok "each unusable state reports a cause no other state reports"

# ── an mtime that cannot be read answers undetermined ─────────────────────
# GNU `stat` only, deliberately: an untested BSD fallback is the fail-open shape
# this check exists to avoid. Where `stat` cannot answer, the age is unknown and
# the reading is undetermined — asserted with a stub rather than assumed.
root="$(new_fixture stat-fails)"
printf 'shared line\nnew upstream line\n' \
  >"$root/.agents/skills/$ENGINE/references/settings.md"
commit_tracked "$root" "$COMMIT_OLD"
set_refresh "$root" "$REFRESH"
mkdir -p "$tmp/statstub"
printf '#!/usr/bin/env bash\nexit 3\n' >"$tmp/statstub/stat"
chmod +x "$tmp/statstub/stat"
if PATH="$tmp/statstub:$PATH" stat -c %Y -- "$root" >/dev/null 2>&1; then
  fail "unreadable mtime" "stub precondition unmet: stat still answered"
else
  saved_path="$PATH"
  PATH="$tmp/statstub:$PATH"
  run_check "$root"
  PATH="$saved_path"
  expect_rc "$rc" 1 "unreadable mtime"
  expect_contains "$err" "which side is newer is NOT ESTABLISHED" "unreadable mtime"
  expect_contains "$err" "yielded no usable time" "unreadable mtime"
  # Nothing is at risk in this shape, so the rsync is correctly offered — but
  # only behind its condition, never as a decided repair.
  expect_contains "$err" "$RSYNC_CONDITION" "unreadable mtime"
  expect_absent "$err" "$READING_TRACKED_AHEAD" "unreadable mtime"
fi
ok "an mtime that cannot be read yields no direction and no destructive command"

if ((failures > 0)); then
  printf 'test-vendor-drift-evidence: FAIL (%d)\n' "$failures" >&2
  exit 1
fi
printf 'test-vendor-drift-evidence: ok\n'
