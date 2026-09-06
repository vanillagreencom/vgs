#!/usr/bin/env bash
# Drive inventory-guard refusal paths with mutated runner, grammar, document, and CI fixtures.
# Require each case's own diagnostic and failing status; keep an unmutated acceptance control.
# Unchanged path constants still point at the real repository.
set -euo pipefail

# shellcheck source=scripts/lib/validation-testkit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/validation-testkit.sh"
assert_fragments_live

echo "=== check-validation-inventory.py manifest arms ==="

guard_case "missing MANIFEST_EOF heredoc is reported" \
  "${real_runner//MANIFEST_EOF/MANIFEST_END}" \
  "has no MANIFEST_EOF heredoc"

# Require a later arm's message as well so an earlier parser exception cannot hide aggregation failure.
expect_contains "$guard_out" "the per-area and CI-coverage arms did NOT run" \
  "missing MANIFEST_EOF heredoc is reported"
ok "a runner with no manifest delimiter still reports every arm, not just the first raise"

# Inject each expected exception class into the probe call to test aggregation independently
# of the filesystem or output condition that produced it.
for etype in OSError UnicodeDecodeError ManifestError; do
  raised_said="$(ETYPE="$etype" python3 - "$repo_root" <<'RAISED' 2>&1 || true
import contextlib, io, os, pathlib, sys
from vgstk import guard_module
root = pathlib.Path(sys.argv[1])
mod = guard_module(root)
kind = os.environ["ETYPE"]


def boom(*_args, **_kwargs):
    if kind == "OSError":
        raise NotADirectoryError(20, "Not a directory")
    if kind == "UnicodeDecodeError":
        raise UnicodeDecodeError("utf-8", b"\xff", 0, 1, "invalid start byte")
    raise mod.ManifestError("the probe could not be built")


mod.token_participates = boom
buf = io.StringIO()
try:
    with contextlib.redirect_stderr(buf):
        mod.main()
except BaseException as error:  # noqa: BLE001 - the abort is what is under test
    print(f"ABORTED {type(error).__name__}: {error}")
print(buf.getvalue())
RAISED
)"
  expect_contains "$raised_said" "was NOT determined" "probe raises $etype"
  expect_absent "$raised_said" "ABORTED" "probe raises $etype"

  expect_contains "$raised_said" "check-validation-inventory: FAIL" "probe raises $etype"
done
ok "a probe failing with ManifestError, OSError or UnicodeDecodeError is collected, not aborted on"

guard_case "a row with no separator is reported" \
  "$(python3 - "$runner" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("always    | scripts/check-format-lint.sh",
                "scripts/check-format-lint.sh"), end="")
PY
)" \
  "manifest row has no \`AREAS | COMMAND\` separator"

guard_case "a row with an empty command is reported" \
  "$(python3 - "$runner" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("always    | scripts/check-format-lint.sh", "always    |"), end="")
PY
)" \
  "manifest row has an empty command"

guard_case "an unknown tag is reported (by the shared grammar)" \
  "$(python3 - "$runner" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("docs      | scripts/test-owned-skills-e2e.py",
                "dcos      | scripts/test-owned-skills-e2e.py"), end="")
PY
)" \
  "malformed tag field"

# Remove every docs row and assert the area is empty so added rows cannot disable the control.
docs_emptied="$(python3 - "$runner" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("docs      | ", "-         | "), end="")
PY
)"
if printf '%s\n' "$docs_emptied" | grep -q '^docs '; then
  fail "an area with no rows is reported" \
    "the fixture left docs-tagged rows behind, so the docs area is not empty and this case cannot prove the guard reports an empty area. Widen the substitution to cover every docs row"
else
  guard_case "an area with no rows is reported" \
    "$docs_emptied" \
    "no manifest row is tagged with it"
fi

real_grammar="$(cat "$repo_root/scripts/lib/validation-grammar.conf")"

# Use a token class with no selection or skip properties to model an unwired token.
INERT_CLASS="class inert      selects=no  standalone=no  rowtag=yes exclusive=no  cli=no  universal=no  skips=no  min=0"
while IFS=';' read -r label token; do
  [[ -n "$label" ]] || continue
  grammar_case "$label" \
    "${real_grammar/class argument   /$INERT_CLASS
class argument   }
token $token    inert" \
    "does not act on it"
done <<'INERT'
a token in a class that grants nothing is reported;nightly
an inert token colliding with a runner variable is reported;status
an inert token colliding with a runner word is reported;run
INERT

# Add another universal token so a literal always check cannot imitate property-derived selection.
printf '%s\ntoken everywhere selector\n' "$real_grammar" >"$tmp/second-universal.conf"
run_guard "GRAMMAR_PATH=$tmp/second-universal.conf"
expect_absent "$guard_out" "does not act on it" "second universal token"
[[ "$guard_rc" -eq 0 || $have_yaml -eq 0 ]] ||
  fail "second universal token" "a second universal token is not acted on (rc $guard_rc)"
ok "a second universal token selects, so the rule is derived and not a literal"

# A selector that loses universal behavior can hide the inventory row from scoped runs.
# Require the guard to relay the runner's preflight refusal.
grammar_case "a selector class that stops being universal is reported" \
  "${real_grammar/cli=no  universal=yes/cli=no  universal=no }" \
  "selects nothing in any named area"

grammar_case "a second exclusive token is reported" \
  "$real_grammar
token none       exclusive" \
  "wrong number of tokens in a class"

# Reordering equivalent keyed class fields must preserve acceptance.
reordered="${real_grammar/class area       selects=yes standalone=yes rowtag=yes  exclusive=no/class area       rowtag=yes  exclusive=no selects=yes standalone=yes}"
printf '%s' "$reordered" >"$tmp/reordered.conf"
run_guard "GRAMMAR_PATH=$tmp/reordered.conf"
expect_clean_run "reordered class properties"
ok "reordering a class line's properties changes nothing"

while IFS=';' read -r label line expect; do
  [[ -n "$label" ]] || continue
  grammar_case "$label" \
    "${real_grammar/class area       selects=yes standalone=yes rowtag=yes  exclusive=no/$line}" \
    "$expect"
done <<'CLASSES'
a class missing a property is reported;class area       selects=yes standalone=yes rowtag=yes;is missing a property
a class with an unknown property is reported;class area       selects=yes standalone=yes rowtag=yes exclusive=no bogus=yes;has an unknown field
a class repeating a property is reported;class area       selects=yes selects=no standalone=yes rowtag=yes exclusive=no;repeats a field
a class property without = is reported;class area       selectsyes standalone=yes rowtag=yes exclusive=no;must be key=value
a class property that is not yes/no is reported;class area       selects=maybe standalone=yes rowtag=yes exclusive=no;must be yes or no
CLASSES

# Write a final record without newline so EOF cannot silently drop it.
printf '%s\ntoken nightly    inert' "${real_grammar/class argument   /$INERT_CLASS
class argument   }" >"$tmp/unterminated.conf"
run_guard "GRAMMAR_PATH=$tmp/unterminated.conf"
expect_refused "unterminated final line" "does not act on it"
ok "a final line with no trailing newline is read by both readers"

# Test incomplete records per kind. Require runner usage status with no execution,
# and a named guard diagnostic without a traceback.
while IFS=';' read -r label bad expect; do
  [[ -n "$label" ]] || continue
  printf '%s\n%s\n' "$real_grammar" "$bad" >"$tmp/arity.conf"


  cp "$runner" "$fixture_dir/scripts/validate"
  chmod +x "$fixture_dir/scripts/validate"
  cp "$tmp/arity.conf" "$fixture_dir/scripts/lib/validation-grammar.conf"
  rc=0
  out="$("$fixture_dir/scripts/validate" --list docs 2>"$tmp/stderr")" || rc=$?
  err="$(cat "$tmp/stderr")"
  [[ "$rc" == 2 ]] || fail "arity: $label" "runner exited $rc, not 2"
  expect_absent "$out" "scripts/" "arity: $label"
  # Distinguish raw Bash line diagnostics from the grammar's own line messages.
  expect_absent "$err" ": line " "arity: $label (raw shell error)"


  run_guard "GRAMMAR_PATH=$tmp/arity.conf"
  expect_refused "arity: $label" "$expect"
  expect_absent "$guard_out" "Traceback" "arity: $label"
done <<'ARITY'
a bare class line;class;wrong number of fields
a bare token line;token;wrong number of fields
a token line with only a name;token nightly;wrong number of fields
a bare message line;message;wrong number of fields
a bare kind line;kind;wrong number of fields
a kind line with no counts;kind bogus;wrong number of fields
a message line with no text;message somekey;wrong number of fields
an unknown line kind;bogus x y;unknown line kind
ARITY
ok "every line kind refuses an incomplete record: exit 2, nothing run, no traceback"

# A kind allowing no fields cannot safely provide the name every branch reads.
printf '%s\nkind bogus   min=0\n' "$real_grammar" >"$tmp/arity.conf"
run_guard "GRAMMAR_PATH=$tmp/arity.conf"
expect_refused "min=0 kind" "min must be at least 1"
expect_absent "$guard_out" "Traceback" "min=0 kind"
ok "a line kind may not permit zero fields"

grammar_case "a token line with an extra field is reported" \
  "${real_grammar/token go         area/token go         area extra}" \
  "wrong number of fields"

grammar_case "a token with an unknown class is reported" \
  "$real_grammar
token weird      nosuchclass" \
  "unknown class"

grammar_case "an area the runner does not offer is reported" \
  "$real_grammar
token rust       area" \
  "no manifest row is tagged with it"

# Exercise library refusal paths directly through fixtures.
guard_case "an empty manifest is reported" \
  "$(python3 - "$runner" <<'MUT'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
print(re.sub(r"(<<'MANIFEST_EOF'\n).*?(\nMANIFEST_EOF\n)", r"\1\2", t, flags=re.DOTALL), end="")
MUT
)" \
  "manifest is empty"

# Require runner and library to reject the same malformed tag fields.
while IFS=';' read -r label bad expect; do
  [[ -n "$label" ]] || continue
  guard_case "$label" \
    "$(MUT_TO="$bad" python3 - "$runner" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "always    | scripts/check-format-lint.sh"
assert t.count(old) == 1, "the format-lint manifest row moved"
print(t.replace(old, os.environ["MUT_TO"] + "| scripts/check-format-lint.sh"), end="")
MUT
)" \
    "$expect"
done <<'SHAPES'
a row with an empty tag field is reported;          ;has an empty tag field
a row with a trailing separator is reported;always,   ;malformed tag field
a row with a leading separator is reported;,always   ;malformed tag field
a row with a repeated separator is reported;a,,always ;malformed tag field
a row combining the dash tag is reported;-,go      ;malformed tag field
a row carrying only a modifier is reported;may-skip  ;cannot stand alone
SHAPES

# Both readers use Bash syntax validation for the command half.
guard_case "a row with invalid shell syntax is reported" \
  "$(python3 - "$runner" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "always    | scripts/check-format-lint.sh"
assert t.count(old) == 1, "the format-lint manifest row moved"
print(t.replace(old, 'always    | scripts/check-format-lint.sh "oops'), end="")
MUT
)" \
  "invalid shell syntax"

# Removing the default argument must fail before a bare invocation can run.
grammar_case "removing the all argument is reported" \
  "$(printf '%s\n' "$real_grammar" | grep -v '^token all ')" \
  "wrong number of tokens in a class"

grammar_case "an uppercase token is reported" \
  "${real_grammar/token qml        area/token Qml        area}" \
  "token name must be lowercase"

# Reject duplicate names for every record kind, even when declarations agree.
while IFS=';' read -r label extra; do
  [[ -n "$label" ]] || continue
  grammar_case "$label" "$real_grammar
$extra" "declares the same record twice"
done <<'DUPES'
a duplicated token is reported;token qml        area
a duplicated class is reported;class area       selects=no  standalone=no  rowtag=no   exclusive=no  cli=no  universal=no  skips=no
a duplicated message is reported;message row-empty-tags  a different wording
a duplicated line kind is reported;kind token   min=5
DUPES

# Counts require integer diagnostics at both kind and class sites; boolean wording names the wrong rule.
while IFS=';' read -r label from to; do
  [[ -n "$label" ]] || continue
  # Require mutation anchors in uncommented records so fixture edits affect parsed grammar.
  if ! sed -e 's/#.*//' "$repo_root/scripts/lib/validation-grammar.conf" | grep -qF -- "$from"; then
    fail "$label" "the anchor '$from' is not on an uncommented line, so the mutation is inert"
    continue
  fi
  printf '%s' "${real_grammar/$from/$to}" >"$tmp/counts.conf"
  run_guard "GRAMMAR_PATH=$tmp/counts.conf"
  expect_refused "$label" "min and max must be decimal integers"
  expect_absent "$guard_out" "must be yes or no" "$label"
  ok "$label"
done <<'COUNTS'
a non-integer class count is reported;skips=no  min=1;skips=no  min=banana
a non-integer kind arity is reported;kind class   min=2;kind class   min=banana
COUNTS

# Reject noncanonical decimals before Bash arithmetic can interpret leading-zero values as octal.
# Require no listed commands and no raw shell error as well as usage status.
while IFS=';' read -r label from to; do
  [[ -n "$label" ]] || continue
  printf '%s' "${real_grammar/$from/$to}" >"$tmp/canon.conf"
  cp "$tmp/canon.conf" "$fixture_dir/scripts/lib/validation-grammar.conf"
  cp "$runner" "$fixture_dir/scripts/validate"
  chmod +x "$fixture_dir/scripts/validate"
  for area in docs all; do
    rc=0
    out="$("$fixture_dir/scripts/validate" --list "$area" 2>"$tmp/stderr")" || rc=$?
    err="$(cat "$tmp/stderr")"
    [[ "$rc" == 2 ]] || fail "$label" "runner exited $rc in area $area, not 2"
    expect_absent "$out" "scripts/" "$label ($area)"
    expect_contains "$err" "min and max must be decimal integers" "$label ($area)"
    expect_absent "$err" "value too great for base" "$label ($area)"
  done
  run_guard "GRAMMAR_PATH=$tmp/canon.conf"
  expect_refused "$label" "min and max must be decimal integers"
  ok "$label"
done <<'CANON'
a leading zero on a kind count is reported;kind token   min=2 max=2;kind token   min=08 max=08
a leading zero on a class count is reported;skips=no  min=1;skips=no  min=08
a signed kind count is reported;kind token   min=2;kind token   min=+2
a decimal-point kind count is reported;kind token   min=2;kind token   min=2.0
an empty kind count is reported;kind token   min=2;kind token   min=
a signed class count is reported;skips=no  min=1;skips=no  min=+1
CANON

# Accept zero and multi-digit values where permitted so numeric validation cannot reject all uncommon forms.
canon_from='universal=yes skips=no  min=0'
canon_to='universal=yes skips=no  min=0 max=10'
printf '%s' "${real_grammar/$canon_from/$canon_to}" >"$tmp/canon.conf"
grep -qF -- "$canon_to" "$tmp/canon.conf" ||
  fail "canonical counts accepted" "the mutation did not apply, so the case cannot fail"
run_guard "GRAMMAR_PATH=$tmp/canon.conf"
expect_clean_run "canonical counts accepted"
ok "ordinary decimal counts still parse, including 0 and a multi-digit value"

# Test duplicate default eligibility within one class and across separate classes.
# A per-class cardinality check alone cannot establish global uniqueness.
while IFS=';' read -r label extra expect; do
  [[ -n "$label" ]] || continue

  printf '%s\n%s\n' "$real_grammar" "${extra//%%/$'\n'}" >"$tmp/default.conf"
  cp "$tmp/default.conf" "$fixture_dir/scripts/lib/validation-grammar.conf"
  cp "$runner" "$fixture_dir/scripts/validate"
  chmod +x "$fixture_dir/scripts/validate"
  # Exercise list mode in a named area and the default area as well as execution.
  for invocation in "--list docs" "--list all" "docs"; do
    rc=0
    # shellcheck disable=SC2086  # the invocation is a deliberate word list
    out="$("$fixture_dir/scripts/validate" $invocation 2>"$tmp/stderr")" || rc=$?
    [[ "$rc" == 2 ]] || fail "$label" "runner exited $rc for \`$invocation\`, not 2"
    expect_absent "$out" "scripts/" "$label ($invocation)"
    expect_contains "$(cat "$tmp/stderr")" "$expect" "$label ($invocation)"
  done
  run_guard "GRAMMAR_PATH=$tmp/default.conf"
  expect_refused "$label" "$expect"
  expect_absent "$guard_out" "Traceback" "$label"
  ok "$label"
done <<'DEFAULTS'
two default-eligible tokens in different classes are reported;class other      selects=no  standalone=no  rowtag=no   exclusive=no  cli=yes universal=no  skips=no  min=1 max=1%%token everything other;exactly one CLI default token
two default-eligible tokens in one class are reported;token everything argument;wrong number of tokens in a class
DEFAULTS

# Reject repeated named fields in kind and class records. Positional token/message records
# have no named-field repetition; token arity must reject extra fields.
while IFS=';' read -r label from to expect; do
  [[ -n "$label" ]] || continue
  printf '%s' "${real_grammar/$from/$to}" >"$tmp/repeat.conf"
  grep -qF -- "$to" "$tmp/repeat.conf" ||
    fail "$label" "the mutation did not apply, so the case cannot fail"
  cp "$tmp/repeat.conf" "$fixture_dir/scripts/lib/validation-grammar.conf"
  cp "$runner" "$fixture_dir/scripts/validate"
  chmod +x "$fixture_dir/scripts/validate"
  for area in docs all; do
    rc=0
    out="$("$fixture_dir/scripts/validate" --list "$area" 2>"$tmp/stderr")" || rc=$?
    [[ "$rc" == 2 ]] || fail "$label" "runner exited $rc in area $area, not 2"
    expect_absent "$out" "scripts/" "$label ($area)"
    expect_contains "$(cat "$tmp/stderr")" "$expect" "$label ($area)"
  done
  run_guard "GRAMMAR_PATH=$tmp/repeat.conf"
  expect_refused "$label" "$expect"
  ok "$label"
done <<'REPEATS'
a repeated min on a kind record is reported;kind class   min=2;kind class   min=100 min=2;repeats a field
a repeated max on a kind record is reported;kind token   min=2 max=2;kind token   min=2 max=2 max=9;repeats a field
a repeated boolean on a class record is reported;class area       selects=yes;class area       selects=yes selects=no;repeats a field
a repeated count on a class record is reported;skips=no  min=1;skips=no  min=1 min=9;repeats a field
a repeated token field is refused as arity;token go         area;token go         area area;wrong number of fields
REPEATS

# Compare the relayed refusal with the runner's actual diagnostic so consumers cannot substitute their own rule.
printf '%s\ntoken qml        area\n' "$real_grammar" >"$tmp/relay.conf"
mkdir -p "$tmp/relay/scripts/lib"
cp "$runner" "$tmp/relay/scripts/validate"
chmod +x "$tmp/relay/scripts/validate"
cp "$tmp/relay.conf" "$tmp/relay/scripts/lib/validation-grammar.conf"
relay_rc=0
relay_said="$("$tmp/relay/scripts/validate" --dump-grammar 2>&1 >/dev/null)" || relay_rc=$?
[[ "$relay_rc" == 2 ]] || fail "runner relay" "the runner accepted the bad grammar (rc $relay_rc)"
run_guard "GRAMMAR_PATH=$tmp/relay.conf"
expect_refused "runner relay" "$relay_said"
expect_contains "$guard_out" "refuses its own grammar" "runner relay"
expect_absent "$guard_out" "Traceback" "runner relay"
ok "a grammar the runner refuses reaches the guard as the runner's own diagnostic"


non_exec="$tmp/non-exec-runner"
cp "$runner" "$non_exec"
chmod -x "$non_exec"
run_guard "RUNNER_PATH=$non_exec"
expect_refused "runner executable bit" "scripts/validate is not executable"
ok "a non-executable runner is reported"

# Require the unmutated runner to avoid every controlled diagnostic and return success.
run_guard
expect_clean_run "unmutated control"
ok "the unmutated runner triggers none of its arms"

finish test-validation-inventory
