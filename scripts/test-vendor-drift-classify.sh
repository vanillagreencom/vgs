#!/usr/bin/env bash
# Unit controls for the two decisions inside the vendor drift check
# (scripts/lib/vendor-drift.sh, VGS-155): how a diff line is attributed to a
# side, and how the evidence is read. Whole runs are covered by
# scripts/test-vendor-drift.sh; this file drives the two functions directly, so
# a shape can be pinned without a fixture that produces it.
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

# $1 label, $2 expected yes|no, $3 diff text, $4 optional at-risk fragment
expect_class() {
  local label="$1" expected="$2" input="$3" fragment="${4:-}"
  classify "$input"
  [[ "$class_tracked_only" == "$expected" ]] ||
    fail "$label" "expected tracked_only=$expected, got $class_tracked_only"$'\n'"--- input ---"$'\n'"$input"
  [[ -z "$fragment" ]] || expect_contains "$class_at_risk" "$fragment" "$label"
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
expect_class "tracked file header" no "+++ $TRACKED_REL/references/settings.md	2023-11-14"
expect_class "file only the mirror has" no "Only in $MIRROR_REL/references: retired.md"
ok "every ignore arm attributes its line to the mirror side or to structure"

# ── lines that ARE tracked-side evidence ──────────────────────────────────
expect_class "tracked-only content" yes \
  "+++ $TRACKED_REL/references/settings.md"$'\n'"+a tracked-only row" \
  "$TRACKED_REL/references/settings.md"
expect_class "file only the tracked copy has" yes \
  "Only in $TRACKED_REL/references: error-patterns.md" \
  "$TRACKED_REL/references/error-patterns.md"
ok "tracked-only content and tracked-only files are both counted, and named"

# ── the shapes that used to escape ────────────────────────────────────────
# A tracked-only CONTENT line reading `++ x` is printed by unified diff as
# `+++ x`, which the old parser ate as a file header. The header arm is anchored
# to the root diff was given, so this is content again.
expect_class "content line that looks like a header" yes \
  "+++ $TRACKED_REL/references/settings.md"$'\n'"+++ a line that itself begins with ++" \
  "$TRACKED_REL/references/settings.md"
# A `+++ ` header naming neither root is not a header this run produced.
expect_class "header for a foreign root" yes "+++ /somewhere/else/file.md"
# GNU diff emits the SINGULAR "File" here, matching no marker the parser knows.
expect_class "file versus directory" yes \
  "File $MIRROR_REL/references/thing is a regular file while file $TRACKED_REL/references/thing is a directory" \
  "is a regular file while file"
# Under another locale the markers are translated. LC_ALL=C on the diff keeps
# that from happening; the default arm keeps it SAFE if it ever does.
expect_class "translated marker" yes "Nur in $MIRROR_REL/references: retired.md"
expect_class "binary difference" yes \
  "Binary files $MIRROR_REL/references/f.bin and $TRACKED_REL/references/f.bin differ" \
  "$TRACKED_REL/references/f.bin"
expect_class "a line kind that does not exist yet" yes "Some future diff remark"
ok "every unrecognised shape counts as content the rsync would destroy"

# ── the locale fix itself ─────────────────────────────────────────────────
# Asserted on the source, not behaviourally: no translated locale is guaranteed
# installed anywhere this suite runs, so a behavioural test would silently pass
# on a C-only machine. What the default arm above already guarantees is that a
# translated marker is SAFE; this pins that it is also CORRECT.
diff_invocation="$(grep -n 'diff -r -u' "$repo_root/scripts/lib/vendor-drift.sh" || true)"
expect_contains "$diff_invocation" "LC_ALL=C diff -r -u" "locale pin"
ok "the drift diff runs under LC_ALL=C, so the markers stay in the parsed language"

# ── the reading, and the cause it reports ─────────────────────────────────
# Every row asserts the REASON as well as the reading: an explanation that
# describes a decision other than the one made is the defect this pins. The two
# decided readings are disjoint on the epoch comparison, so no ordering trick is
# load-bearing — what is load-bearing is that unreadable evidence is answered
# before either.
while IFS='|' read -r tracked refresh dirty tracked_only expected fragment; do
  [[ -n "$expected" ]] || continue
  [[ "$tracked" != EMPTY ]] || tracked=""
  [[ "$refresh" != EMPTY ]] || refresh=""
  decided="$(vendor_drift_direction "$tracked" "$refresh" "$dirty" "$tracked_only" "$ENGINE")"
  reading="${decided%%$'\t'*}"
  reason="${decided#*$'\t'}"
  label="direction($tracked,$refresh,$dirty,$tracked_only)"
  [[ "$reading" == "$expected" ]] || fail "decision table" "$label expected $expected, got $reading"
  if [[ -n "$fragment" ]]; then
    expect_contains "$reason" "$fragment" "decision table"
  elif [[ -n "$reason" ]]; then
    fail "decision table" "$label is a decided reading but carries reason: $reason"
  fi
done <<TABLE
1700007200|1700003600|no|no|tracked-ahead|
1700007200|1700003600|no|yes|tracked-ahead|
1700000000|1700003600|no|no|mirror-ahead|
1700000000|1700003600|no|yes|undetermined|PULLED IN after that refresh
1700000000|1700003600|yes|no|undetermined|has uncommitted changes
1700007200|1700003600|yes|no|undetermined|has uncommitted changes
1700007200|1700003600|unknown|yes|undetermined|git could not be consulted
1700003600|1700003600|no|no|undetermined|both timestamps are identical
EMPTY|1700003600|no|no|undetermined|no commit in this repository
1700000000|EMPTY|no|no|undetermined|no .vstack-refreshed marker
EMPTY|EMPTY|unknown|no|undetermined|git could not be consulted
TABLE
ok "every row reads as written and reports the cause of that reading, not another"

if ((failures > 0)); then
  printf 'test-vendor-drift-classify: FAIL (%d)\n' "$failures" >&2
  exit 1
fi
printf 'test-vendor-drift-classify: ok\n'
