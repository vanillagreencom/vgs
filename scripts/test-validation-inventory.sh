#!/usr/bin/env bash
# Drive the inventory guard's manifest and grammar arms with mutated runner and grammar
# fixtures. Each case requires its own diagnostic and a failing status, and the unmutated
# runner is the acceptance control that runs last.
# The reader agreement, document, dump and CI-coverage arms have suites of their own.
set -euo pipefail

# shellcheck source=scripts/lib/validation-testkit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/validation-testkit.sh"
assert_fragments_live

case_missing_heredoc() { # A runner with no manifest delimiter reports every arm, not just the first raise.
  local probe="$tmp/probe-runner"
  printf '%s' "${real_runner//MANIFEST_EOF/MANIFEST_END}" >"$probe"
  chmod +x "$probe"
  run_guard "RUNNER_PATH=$probe"
  expect_refused "missing MANIFEST_EOF heredoc" "has no MANIFEST_EOF heredoc"
  # Require a later arm's message as well so an earlier parser exception cannot hide aggregation failure.
  expect_contains "$guard_out" "the per-area and CI-coverage arms did NOT run" \
    "missing MANIFEST_EOF heredoc"
  ok "a runner with no manifest delimiter is refused and still reports every arm, not just the first raise"
}

case_probe_exceptions() { # Each expected exception class from the probe is collected, not aborted on.
  # Inject the class into the probe call to test aggregation independently of the filesystem
  # or output condition that produced it.
  local etype raised_said
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
}

case_row_shapes() { # One manifest row, replaced whole, must be refused by its own diagnostic.
  # Every row below replaces the same real row, so the tag half and the command half are
  # judged on one input and no row can pass because another row stayed well formed.
  local label row expect probe="$tmp/probe-runner"
  while IFS=';' read -r label row expect; do
    [[ -n "$label" ]] || continue
    if ! ROW="$row" python3 - "$runner" >"$probe" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "always    | scripts/check-format-lint.sh"
assert t.count(old) == 1, "the format-lint manifest row moved"
print(t.replace(old, os.environ["ROW"]), end="")
MUT
    then
      fail "$label" "the row substitution did not apply (see the message above)"
      continue
    fi
    chmod +x "$probe"
    run_guard "RUNNER_PATH=$probe"
    expect_refused "$label" "$expect"
  done <<'ROW_SHAPES'
a row with no separator;scripts/check-format-lint.sh;manifest row has no `AREAS | COMMAND` separator
a row with an empty command;always    |;manifest row has an empty command
a row with an unknown tag;dcos      | scripts/check-format-lint.sh;malformed tag field
a row with an empty tag field;          | scripts/check-format-lint.sh;has an empty tag field
a row with a trailing tag separator;always,   | scripts/check-format-lint.sh;malformed tag field
a row with a leading tag separator;,always   | scripts/check-format-lint.sh;malformed tag field
a row with a repeated tag separator;a,,always | scripts/check-format-lint.sh;malformed tag field
a row combining the dash tag;-,go      | scripts/check-format-lint.sh;malformed tag field
a row carrying only a modifier;may-skip  | scripts/check-format-lint.sh;cannot stand alone
a row whose command is invalid shell;always    | scripts/check-format-lint.sh "oops;invalid shell syntax
ROW_SHAPES
  ok "every malformed shape of a manifest row is refused by the diagnostic that names it"
}

case_empty_area() { # An area the runner accepts with no row tagged for it is reported.
  # Remove every docs row and assert the area is empty so added rows cannot disable the control.
  local docs_emptied
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
}

case_empty_manifest() { # A runner whose manifest heredoc is empty is reported.
  guard_case "an empty manifest is reported" \
    "$(python3 - "$runner" <<'MUT'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
print(re.sub(r"(<<'MANIFEST_EOF'\n).*?(\nMANIFEST_EOF\n)", r"\1\2", t, flags=re.DOTALL), end="")
MUT
)" \
    "manifest is empty"
}

case_grammar_refusals() { # Every malformed grammar record is refused by its own diagnostic.
  # The op column says how the row damages the grammar: `replace` substitutes `from|to`,
  # `append` adds a record, `drop` removes the lines matching a pattern, and `inert` adds a
  # token in a class that grants nothing.
  local label op argument expect from to grammar probe="$tmp/probe-grammar.conf"
  while IFS=';' read -r label op argument expect; do
    [[ -n "$label" ]] || continue
    case "$op" in
      replace)
        from="${argument%%|*}"
        to="${argument#*|}"
        grammar="${real_grammar/$from/$to}"
        if [[ "$grammar" == "$real_grammar" ]]; then
          fail "$label" "the anchor \`$from\` is not in the grammar, so the row cannot fail"
          continue
        fi
        ;;
      append)
        grammar="$real_grammar
$argument"
        ;;
      drop)
        grammar="$(printf '%s\n' "$real_grammar" | grep -v -- "$argument")"
        if [[ "$grammar" == "$real_grammar" ]]; then
          fail "$label" "no grammar line matches \`$argument\`, so the row cannot fail"
          continue
        fi
        ;;
      inert)
        grammar="${real_grammar/class argument   /$INERT_CLASS
class argument   }
token $argument    inert"
        ;;
      *)
        fail "$label" "unknown grammar mutation op \`$op\`"
        continue
        ;;
    esac
    printf '%s' "$grammar" >"$probe"
    run_guard "GRAMMAR_PATH=$probe"
    expect_refused "$label" "$expect"
  done <<'GRAMMAR_REFUSALS'
a token in a class that grants nothing;inert;nightly;does not act on it
an inert token colliding with a runner variable;inert;status;does not act on it
an inert token colliding with a runner word;inert;run;does not act on it
a selector class that stops being universal;replace;cli=no  universal=yes|cli=no  universal=no ;selects nothing in any named area
a class missing a property;replace;class area       selects=yes standalone=yes rowtag=yes  exclusive=no|class area       selects=yes standalone=yes rowtag=yes;is missing a property
a class with an unknown property;replace;class area       selects=yes standalone=yes rowtag=yes  exclusive=no|class area       selects=yes standalone=yes rowtag=yes exclusive=no bogus=yes;has an unknown field
a class repeating a property;replace;class area       selects=yes standalone=yes rowtag=yes  exclusive=no|class area       selects=yes selects=no standalone=yes rowtag=yes exclusive=no;repeats a field
a class property without an equals sign;replace;class area       selects=yes standalone=yes rowtag=yes  exclusive=no|class area       selectsyes standalone=yes rowtag=yes exclusive=no;must be key=value
a class property that is neither yes nor no;replace;class area       selects=yes standalone=yes rowtag=yes  exclusive=no|class area       selects=maybe standalone=yes rowtag=yes exclusive=no;must be yes or no
a token line with an extra field;replace;token go         area|token go         area extra;wrong number of fields
an uppercase token name;replace;token qml        area|token Qml        area;token name must be lowercase
a second exclusive token;append;token none       exclusive;wrong number of tokens in a class
a token with an unknown class;append;token weird      nosuchclass;unknown class
an area the runner does not offer;append;token rust       area;no manifest row is tagged with it
a duplicated token;append;token qml        area;declares the same record twice
a duplicated class;append;class area       selects=no  standalone=no  rowtag=no   exclusive=no  cli=no  universal=no  skips=no;declares the same record twice
a duplicated message;append;message row-empty-tags  a different wording;declares the same record twice
a duplicated line kind;append;kind token   min=5;declares the same record twice
the default argument removed;drop;^token all ;wrong number of tokens in a class
GRAMMAR_REFUSALS
  ok "every malformed grammar record is refused by the diagnostic that names it"
}

case_second_universal() { # A second universal token selects, so the rule is derived, not literal.
  # A literal `always` check would imitate property-derived selection on the real grammar alone.
  printf '%s\ntoken everywhere selector\n' "$real_grammar" >"$tmp/second-universal.conf"
  run_guard "GRAMMAR_PATH=$tmp/second-universal.conf"
  expect_absent "$guard_out" "does not act on it" "second universal token"
  [[ "$guard_rc" -eq 0 || $have_yaml -eq 0 ]] ||
    fail "second universal token" "a second universal token is not acted on (rc $guard_rc)"
  ok "a second universal token selects, so the rule is derived and not a literal"
}

case_reordered_class() { # Reordering equivalent keyed class fields preserves acceptance.
  local reordered
  reordered="${real_grammar/class area       selects=yes standalone=yes rowtag=yes  exclusive=no/class area       rowtag=yes  exclusive=no selects=yes standalone=yes}"
  printf '%s' "$reordered" >"$tmp/reordered.conf"
  run_guard "GRAMMAR_PATH=$tmp/reordered.conf"
  expect_clean_run "reordered class properties"
  ok "reordering a class line's properties changes nothing"
}

case_unterminated_line() { # A final record with no trailing newline is still read.
  printf '%s\ntoken nightly    inert' "${real_grammar/class argument   /$INERT_CLASS
class argument   }" >"$tmp/unterminated.conf"
  run_guard "GRAMMAR_PATH=$tmp/unterminated.conf"
  expect_refused "unterminated final line" "does not act on it"
  ok "a final line with no trailing newline is read by both readers"
}

case_arity() { # Every line kind refuses an incomplete record, through the runner and the guard.
  # Require runner usage status with no execution, and a named guard diagnostic without a traceback.
  local label bad expect rc out err
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
}

case_zero_arity_kind() { # A line kind may not permit zero fields.
  # A kind allowing no fields cannot safely provide the name every branch reads.
  printf '%s\nkind bogus   min=0\n' "$real_grammar" >"$tmp/arity.conf"
  run_guard "GRAMMAR_PATH=$tmp/arity.conf"
  expect_refused "min=0 kind" "min must be at least 1"
  expect_absent "$guard_out" "Traceback" "min=0 kind"
  ok "a line kind may not permit zero fields"
}

case_counts() { # A non-integer count is diagnosed as a count, not as a boolean.
  local label from to
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
  done <<'COUNTS'
a non-integer class count is reported;skips=no  min=1;skips=no  min=banana
a non-integer kind arity is reported;kind class   min=2;kind class   min=banana
COUNTS
  ok "a count that is not an integer is diagnosed as a count at both the kind and class sites"
}

case_canonical_counts() { # Noncanonical decimals are refused before Bash arithmetic reads them.
  # Leading zeros would otherwise be interpreted as octal. Require no listed commands and no
  # raw shell error as well as usage status.
  local label from to area rc out err
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
  done <<'CANON'
a leading zero on a kind count is reported;kind token   min=2 max=2;kind token   min=08 max=08
a leading zero on a class count is reported;skips=no  min=1;skips=no  min=08
a signed kind count is reported;kind token   min=2;kind token   min=+2
a decimal-point kind count is reported;kind token   min=2;kind token   min=2.0
an empty kind count is reported;kind token   min=2;kind token   min=
a signed class count is reported;skips=no  min=1;skips=no  min=+1
CANON
  ok "a noncanonical decimal count is refused by both readers, with no shell arithmetic error"
}

case_canonical_counts_accepted() { # Ordinary decimal counts still parse, including 0 and two digits.
  # Numeric validation that rejected every uncommon form would pass the table above.
  local canon_from='universal=yes skips=no  min=0'
  local canon_to='universal=yes skips=no  min=0 max=10'
  printf '%s' "${real_grammar/$canon_from/$canon_to}" >"$tmp/canon.conf"
  grep -qF -- "$canon_to" "$tmp/canon.conf" ||
    fail "canonical counts accepted" "the mutation did not apply, so the case cannot fail"
  run_guard "GRAMMAR_PATH=$tmp/canon.conf"
  expect_clean_run "canonical counts accepted"
  ok "ordinary decimal counts still parse, including 0 and a multi-digit value"
}

case_defaults() { # Duplicate default eligibility is refused within a class and across classes.
  # A per-class cardinality check alone cannot establish global uniqueness.
  local label extra expect invocation rc out
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
  done <<'DEFAULTS'
two default-eligible tokens in different classes are reported;class other      selects=no  standalone=no  rowtag=no   exclusive=no  cli=yes universal=no  skips=no  min=1 max=1%%token everything other;exactly one CLI default token
two default-eligible tokens in one class are reported;token everything argument;wrong number of tokens in a class
DEFAULTS
  ok "a second default-eligible token is refused, whether it shares a class or not"
}

case_repeats() { # A repeated named field is refused in kind and class records.
  # Positional token and message records have no named-field repetition; token arity rejects
  # the extra field instead.
  local label from to expect area rc out
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
  done <<'REPEATS'
a repeated min on a kind record is reported;kind class   min=2;kind class   min=100 min=2;repeats a field
a repeated max on a kind record is reported;kind token   min=2 max=2;kind token   min=2 max=2 max=9;repeats a field
a repeated boolean on a class record is reported;class area       selects=yes;class area       selects=yes selects=no;repeats a field
a repeated count on a class record is reported;skips=no  min=1;skips=no  min=1 min=9;repeats a field
a repeated token field is refused as arity;token go         area;token go         area area;wrong number of fields
REPEATS
  ok "a repeated field is refused by both readers wherever a record names its fields"
}

case_runner_relay() { # A grammar the runner refuses reaches the guard as the runner's diagnostic.
  # Compare the relayed refusal with the runner's actual text so a consumer cannot substitute
  # a rule of its own.
  local relay_rc=0 relay_said
  printf '%s\ntoken qml        area\n' "$real_grammar" >"$tmp/relay.conf"
  mkdir -p "$tmp/relay/scripts/lib"
  cp "$runner" "$tmp/relay/scripts/validate"
  chmod +x "$tmp/relay/scripts/validate"
  cp "$tmp/relay.conf" "$tmp/relay/scripts/lib/validation-grammar.conf"
  relay_said="$("$tmp/relay/scripts/validate" --dump-grammar 2>&1 >/dev/null)" || relay_rc=$?
  [[ "$relay_rc" == 2 ]] || fail "runner relay" "the runner accepted the bad grammar (rc $relay_rc)"
  run_guard "GRAMMAR_PATH=$tmp/relay.conf"
  expect_refused "runner relay" "$relay_said"
  expect_contains "$guard_out" "refuses its own grammar" "runner relay"
  expect_absent "$guard_out" "Traceback" "runner relay"
  ok "a grammar the runner refuses reaches the guard as the runner's own diagnostic"
}

case_non_executable_runner() { # A runner without the executable bit is reported.
  local non_exec="$tmp/non-exec-runner"
  cp "$runner" "$non_exec"
  chmod -x "$non_exec"
  run_guard "RUNNER_PATH=$non_exec"
  expect_refused "runner executable bit" "scripts/validate is not executable"
  ok "a non-executable runner is reported"
}

case_unmutated_control() { # The unmutated runner triggers none of the arms above.
  run_guard
  expect_clean_run "unmutated control"
  ok "the unmutated runner triggers none of its arms"
}

echo "=== check-validation-inventory.py manifest and grammar arms ==="

# The acceptance control runs last so every refusal above has already been reported.
CASES=(
  case_missing_heredoc
  case_probe_exceptions
  case_row_shapes
  case_empty_area
  case_empty_manifest
  case_grammar_refusals
  case_second_universal
  case_reordered_class
  case_unterminated_line
  case_arity
  case_zero_arity_kind
  case_counts
  case_canonical_counts
  case_canonical_counts_accepted
  case_defaults
  case_repeats
  case_runner_relay
  case_non_executable_runner
  case_unmutated_control
)
for validation_case in "${CASES[@]}"; do
  "$validation_case"
done

finish test-validation-inventory
