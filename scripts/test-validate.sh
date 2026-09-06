#!/usr/bin/env bash
# scripts/validate behaviour: area selection, fail-closed arguments, manifest refusal,
# execution reporting and --no-live omission.
# Token refusal and acceptance rows are derived from the shipped grammar, so a new token
# joins those tables with no second vocabulary list here. Parser agreement reads the real
# runner: no fixture can show that the two shipped readers still agree on the real manifest.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/scripts/validate"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

failures=0
case_failed=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
  case_failed=1
}
# Consume each case failure flag before printing ok so a failed case cannot also report success.
ok() {
  if [[ $case_failed -eq 0 ]]; then
    printf '  ok    %s\n' "$1"
  fi
  case_failed=0
}

# Shared neutral world: a repository of stub commands whose manifest body each case writes.
# A case that needs a malformed row owns that row; no case inherits another case's manifest.
fixture_repo="$tmp/repo"
mkdir -p "$fixture_repo/scripts/lib"
# Copy the grammar because these fixtures change the manifest, not its vocabulary.
cp "$repo_root/scripts/lib/validation-grammar.conf" "$fixture_repo/scripts/lib/"

for stub in stub-go stub-qml stub-both stub-always stub-only-all stub-docs stub-helper \
  stub-packaging stub-under-test; do
  printf '#!/usr/bin/env bash\necho "ran %s"\n' "$stub" >"$fixture_repo/scripts/$stub"
  chmod +x "$fixture_repo/scripts/$stub"
done
printf '#!/usr/bin/env bash\necho "a ran"\nexit 1\n' >"$fixture_repo/scripts/stub-fail-a"
printf '#!/usr/bin/env bash\necho "b ran"\nexit 3\n' >"$fixture_repo/scripts/stub-fail-b"
printf '#!/usr/bin/env bash\necho "no prerequisite"\nexit 77\n' >"$fixture_repo/scripts/stub-skip"
printf '#!/usr/bin/env bash\necho "ran stub-live"\nexit 1\n' >"$fixture_repo/scripts/stub-live"
printf '#!/usr/bin/env bash\necho "ran stub-live77"\nexit 77\n' >"$fixture_repo/scripts/stub-live77"
chmod +x "$fixture_repo/scripts/stub-fail-a" "$fixture_repo/scripts/stub-fail-b" \
  "$fixture_repo/scripts/stub-skip" "$fixture_repo/scripts/stub-live" \
  "$fixture_repo/scripts/stub-live77"

write_runner() {
  # Replace only the manifest body while retaining the shipped runner logic.
  local body="$1" out="$fixture_repo/scripts/validate"
  python3 - "$runner" "$out" "$body" <<'PY'
import re, sys
src, dst, body = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()
new, n = re.subn(
    r"(<<'MANIFEST_EOF'\n).*?(\nMANIFEST_EOF\n)",
    lambda m: m.group(1) + body + m.group(2),
    text,
    flags=re.DOTALL,
)
if n != 1:
    raise SystemExit("test-validate: could not find the MANIFEST_EOF heredoc to replace")
open(dst, "w", encoding="utf-8").write(new)
PY
  chmod +x "$out"
}

# Include a multi-tag row even when the real manifest has none.
FIXTURE_MANIFEST='go        | scripts/stub-go
qml       | scripts/stub-qml
go,qml    | scripts/stub-both
always    | scripts/stub-always
-         | scripts/stub-only-all
docs      | scripts/stub-docs
helper    | scripts/stub-helper
packaging | scripts/stub-packaging'

fixture() {
  # Capture stdout, stderr, and status separately.
  rc=0
  out="$("$fixture_repo/scripts/validate" "$@" 2>"$tmp/stderr")" || rc=$?
  err="$(cat "$tmp/stderr")"
}

expect_rc() {
  [[ "$rc" == "$1" ]] || fail "$2" "expected exit $1, got $rc"
}
expect_list() {
  # Compare expected commands in manifest order.
  [[ "$out" == "$1" ]] || fail "$2" "expected list:
$1
got:
$out"
}
expect_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3" "expected to contain: $2 (got: $1)"
}
expect_absent() {
  [[ "$1" != *"$2"* ]] || fail "$3" "expected NOT to contain: $2 (got: $1)"
}

# Require refusal and no executed commands in every area, so an omitted row cannot look like
# scoped success. Callers drive this per row and print one ok for the whole table.
rejected_everywhere() { # name, manifest body, expected diagnostic fragment
  local area
  write_runner "$2"
  for area in all go qml docs; do
    fixture --list "$area"
    expect_rc 2 "$1 in $area"
    expect_contains "$err" "$3" "$1 in $area"
    expect_absent "$out" "scripts/" "$1 in $area"
  done
}

# The exact command list per area proves both directions on one input: the rows the area
# must select, in manifest order, and every row it must not.
SELECTS='go;scripts/stub-go,scripts/stub-both,scripts/stub-always
qml;scripts/stub-qml,scripts/stub-both,scripts/stub-always
docs;scripts/stub-always,scripts/stub-docs
helper;scripts/stub-always,scripts/stub-helper
packaging;scripts/stub-always,scripts/stub-packaging
all;scripts/stub-go,scripts/stub-qml,scripts/stub-both,scripts/stub-always,scripts/stub-only-all,scripts/stub-docs,scripts/stub-helper,scripts/stub-packaging
BARE;scripts/stub-go,scripts/stub-qml,scripts/stub-both,scripts/stub-always,scripts/stub-only-all,scripts/stub-docs,scripts/stub-helper,scripts/stub-packaging'

case_area_selection() {
  local area expect rows=0
  write_runner "$FIXTURE_MANIFEST"
  while IFS=';' read -r area expect; do
    [[ -n "$area" ]] || continue
    rows=$((rows + 1))
    # BARE is the no-argument invocation, which must resolve to the grammar default.
    if [[ "$area" == BARE ]]; then
      fixture --list
    else
      fixture --list "$area"
    fi
    expect_rc 0 "selection $area"
    expect_list "${expect//,/$'\n'}" "selection $area"
  done <<<"$SELECTS"
  [[ $rows -eq 7 ]] || fail "area selection" "expected 7 table rows, drove $rows"
  ok "each area selects exactly its own rows, the universal row, and nothing else"
}

USAGE_ERRORS='an unknown area;nope
two area arguments;--list go qml
an unknown option;--bogus'

case_usage_errors() {
  local name argv rows=0
  local -a args
  write_runner "$FIXTURE_MANIFEST"
  while IFS=';' read -r name argv; do
    [[ -n "$name" ]] || continue
    rows=$((rows + 1))
    read -r -a args <<<"$argv"
    fixture "${args[@]}"
    expect_rc 2 "$name"
    [[ -z "$out" ]] || fail "$name" "expected empty stdout, got: $out"
  done <<<"$USAGE_ERRORS"
  [[ $rows -eq 3 ]] || fail "usage errors" "expected 3 table rows, drove $rows"
  ok "a malformed invocation exits 2 having listed and run nothing"
}

case_token_refusals() {
  local name expect row rows=0
  # Derive token cases from the declared class properties, so a new token is covered the
  # moment the grammar declares it. Separator syntax belongs to the row-shape table.
  python3 - "$repo_root" >"$tmp/generated-cases" <<'GEN'
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
g = mod.grammar(root / "scripts" / "validate")

def emit(name, expect, tags):
    print(f"{name};{expect};{tags:<10}| scripts/stub-go")

for token in sorted(g.tokens):
    cls = g.token_class[token]
    props = g.classes[cls]
    if not props.get("rowtag"):
        # CLI arguments that are not row tags must fail in a tag field.
        emit(f"{cls} token `{token}` is not a row tag", "malformed tag field", token)
        continue
    if not props.get("standalone"):
        # A modifier without standalone permission cannot select a row alone.
        emit(f"{cls} token `{token}` cannot stand alone", "cannot stand alone", token)
    if props.get("exclusive"):
        # Exclusive tags cannot combine with other tags.
        for other in sorted(g.row_tags - {token}):
            emit(f"exclusive `{token}` cannot combine with `{other}`",
                 "malformed tag field", f"{token},{other}")
            break

emit("a token outside the grammar", "malformed tag field", "notatoken")
GEN
  while IFS=';' read -r name expect row; do
    [[ -n "$name" ]] || continue
    rows=$((rows + 1))
    rejected_everywhere "$name" "$row
always    | scripts/stub-always" "$expect"
  done <"$tmp/generated-cases"
  # A floor plus a derived member: too few rows means the generator stopped reading the
  # grammar, not that the vocabulary got simpler.
  [[ $rows -ge 4 ]] || fail "token refusals" "the grammar-derived generator emitted $rows rows"
  # shellcheck disable=SC2016  # the backticks are literal text in the generated row
  grep -q 'token `all` is not a row tag' "$tmp/generated-cases" ||
    fail "token refusals" "the generated rows no longer cover the CLI-only token"
  ok "a token the grammar bars from a tag field is refused in every area, unrun"
}

case_row_shapes() {
  local name expect row rows=0
  while IFS=';' read -r name expect row; do
    [[ -n "$name" ]] || continue
    rows=$((rows + 1))
    rejected_everywhere "$name" "$row
always    | scripts/stub-always" "$expect"
  done <<SHAPES
a row with no separator;manifest row has no;scripts/stub-qml
an empty command;has an empty command;qml       |
an empty tag field;has an empty tag field;          | scripts/stub-go
a separator-only row;has an empty tag field;   |
a trailing tag separator;it ends with a separator;qml,      | scripts/stub-go
a leading tag separator;it starts with a separator;,qml      | scripts/stub-go
a repeated tag separator;it has a repeated separator;qml,,go   | scripts/stub-go
a non-breaking space in the tags;malformed tag field;$(printf 'go\xc2\xa0')      | scripts/stub-go
a trailing shell operator;invalid shell syntax;always    | scripts/stub-go &&
an unbalanced quote;invalid shell syntax;always    | scripts/stub-go "oops
an unclosed brace;invalid shell syntax;always    | { scripts/stub-go
an unclosed subshell;invalid shell syntax;always    | (cd backend && go build
SHAPES
  [[ $rows -eq 12 ]] || fail "row shapes" "expected 12 table rows, drove $rows"
  ok "a malformed tag half or command half is fatal in every area, unrun"
}

case_accepted_rows() {
  local name tags area command rows=0 explicit=0
  # Generate acceptance rows too, so an over-restrictive grammar cannot pass.
  python3 - "$repo_root" >"$tmp/accepts-generated" <<'GEN'
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
g = mod.grammar(root / "scripts" / "validate")
for token in sorted(g.standalone):
    area = token if token in g.areas else "all"
    print(f"standalone `{token}` is accepted;{token};{area};scripts/stub-under-test")
for token in sorted(g.row_tags - g.standalone - g.exclusive):
    for area in sorted(g.areas):
        print(f"`{token}` beside an area is accepted;{area},{token};{area};scripts/stub-under-test")
        break
GEN
  # Shapes the token loop cannot reach: several areas at once, a repeated tag, and a command
  # carrying the row separator after the tag field has been split off.
  cat >"$tmp/accepts-explicit" <<'ACCEPTS'
several areas select in each;go,qml;go;scripts/stub-under-test
an area with a modifier still selects;qml,may-skip;qml;scripts/stub-under-test
the universal tag with a modifier still selects;always,may-skip;helper;scripts/stub-under-test
a repeated tag is inert, not an error;qml,qml;qml;scripts/stub-under-test
a command may contain the separator;qml;qml;scripts/stub-under-test '|' x
ACCEPTS
  explicit="$(grep -c . "$tmp/accepts-explicit")"
  cat "$tmp/accepts-generated" "$tmp/accepts-explicit" >"$tmp/accepts"
  while IFS=';' read -r name tags area command; do
    [[ -n "$name" ]] || continue
    rows=$((rows + 1))
    write_runner "$(printf '%-10s| %s' "$tags" "$command")
always    | scripts/stub-always"
    fixture --list "$area"
    expect_rc 0 "$name"
    # A substring matched by another row cannot prove the target row was accepted.
    expect_contains "$out" "$command" "$name"
  done <"$tmp/accepts"
  [[ $explicit -eq 5 ]] || fail "accepted rows" "expected 5 explicit rows, read $explicit"
  [[ $rows -ge $((explicit + 6)) ]] ||
    fail "accepted rows" "the grammar-derived generator emitted too few rows: $rows total"
  # shellcheck disable=SC2016  # the backticks are literal text in the generated row
  grep -q 'standalone `always` is accepted' "$tmp/accepts-generated" ||
    fail "accepted rows" "the generated rows no longer cover the universal selector"
  ok "every accepted tag shape selects its row in the area it claims"
}

case_area_scoping() {
  # The only negative selection on an accepted row: a valid row absent from another area.
  write_runner "qml       | scripts/stub-under-test
always    | scripts/stub-always"
  fixture --list go
  expect_rc 0 "area scoping"
  expect_absent "$out" "scripts/stub-under-test" "area scoping"
  ok "a row tagged for one area is not selected by another"
}

case_failures_collect() {
  write_runner 'go        | scripts/stub-fail-a
go        | scripts/stub-fail-b
go        | scripts/stub-go'
  fixture go
  expect_rc 1 "two failures"
  expect_contains "$err" "  - scripts/stub-fail-a" "two failures"
  expect_contains "$err" "  - scripts/stub-fail-b" "two failures"
  expect_contains "$out" "ran stub-go" "two failures"
  ok "every failing command is named and the run continues past the first"
}

case_list_does_not_execute() {
  write_runner 'go        | scripts/stub-fail-a
go        | scripts/stub-go'
  fixture --list go
  expect_rc 0 "--list does not execute"
  expect_absent "$out" "a ran" "--list does not execute"
  expect_contains "$out" "scripts/stub-fail-a" "--list does not execute"
  ok "--list prints the commands without running them"
}

case_declared_skip() {
  write_runner 'qml,may-skip | scripts/stub-skip
qml          | scripts/stub-qml'
  fixture qml
  # Skip status must remain visible to callers; exit zero cannot represent a check that never ran.
  expect_rc 77 "declared skip"
  expect_contains "$out" "skipped: scripts/stub-skip" "declared skip"
  expect_contains "$out" "ran stub-qml" "declared skip"
  ok "a may-skip row exiting 77 is named in the skip channel and the run exits 77"
}

case_no_skip_run() {
  write_runner 'qml       | scripts/stub-qml
qml       | scripts/stub-go'
  fixture qml
  expect_rc 0 "no skip"
  expect_absent "$out" "skipped" "no skip"
  ok "a fully executed run exits 0 with no skip text"
}

case_undeclared_skip_fails() {
  write_runner 'qml       | scripts/stub-skip
qml       | scripts/stub-qml'
  fixture qml
  expect_rc 1 "undeclared 77"
  expect_contains "$err" "  - scripts/stub-skip" "undeclared 77"
  expect_absent "$out" "skipped" "undeclared 77"
  ok "exit 77 without the may-skip tag is a plain failure"
}

case_skip_never_masks_failure() {
  write_runner 'qml,may-skip | scripts/stub-skip
qml          | scripts/stub-fail-a'
  fixture qml
  expect_rc 1 "skip plus failure"
  expect_contains "$err" "skipped: scripts/stub-skip" "skip plus failure"
  expect_contains "$err" "  - scripts/stub-fail-a" "skip plus failure"
  ok "a skip never masks a failure"
}

case_inert_selector() {
  # Remove universal selection through class properties while leaving row syntax valid. The
  # runner must refuse before listing or executing, because this change can exclude its own guard.
  local grammar_probe="$tmp/grammar-probe" area
  mkdir -p "$grammar_probe/scripts/lib"
  cp "$runner" "$grammar_probe/scripts/validate"
  chmod +x "$grammar_probe/scripts/validate"
  python3 - "$repo_root/scripts/lib/validation-grammar.conf" \
    >"$grammar_probe/scripts/lib/validation-grammar.conf" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "cli=no  universal=yes"
assert t.count(old) == 1, "the selector class's universal property moved"
print(t.replace(old, "cli=no  universal=no "), end="")
MUT
  for area in docs go qml all; do
    rc=0
    out="$("$grammar_probe/scripts/validate" --list "$area" 2>"$tmp/stderr")" || rc=$?
    err="$(cat "$tmp/stderr")"
    expect_rc 2 "inert selector in $area"
    expect_contains "$err" "selects nothing in any named area" "inert selector in $area"
    expect_contains "$err" "always" "inert selector in $area"
    expect_absent "$out" "scripts/" "inert selector in $area"
  done
  ok "a selector class that stops being universal is refused, not silently narrowed"
}

case_parser_agreement() {
  # Compare the runner and library manifests directly, so a dropped non-script row cannot
  # remain unnoticed (docs/decisions/D009-manifest-second-reader.md).
  local python_rows
  python_rows="$(python3 - "$repo_root" <<'ROWS_PY'
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for _, command in mod.manifest_rows(root / "scripts" / "validate"):
    print(command)
ROWS_PY
  )"
  if [[ "$python_rows" != "$("$runner" --list all)" ]]; then
    fail "parser agreement" "scripts/validate --list all and validation_manifest.manifest_rows disagree:
$(diff <(printf '%s\n' "$python_rows") <(printf '%s\n' "$("$runner" --list all)") || true)"
  fi
  ok "the bash and python manifest readers see the same commands, in the same order"
}

# The live stub fails, so its presence in a run is observable: without the flag the run
# fails on it; with the flag it is omitted, named, and the rest pass.
LIVE_MANIFEST="$FIXTURE_MANIFEST
qml,may-skip,live | scripts/stub-live"

case_live_row_runs_by_default() {
  write_runner "$LIVE_MANIFEST"
  fixture qml
  expect_rc 1 "live row runs without the flag"
  expect_contains "$out" "ran stub-live" "live row runs without the flag"
  ok "without --no-live the live row runs and its failure fails the area (control)"
}

case_no_live_omits_and_names() {
  write_runner "$LIVE_MANIFEST"
  fixture --no-live qml
  expect_rc 0 "live row omitted"
  expect_absent "$out" "ran stub-live" "live row omitted"
  expect_contains "$out" "scripts/stub-live" "live row omitted"
  ok "--no-live omits the live row, names its path, and exits 0 on the rest"
}

case_no_live_list() {
  write_runner "$LIVE_MANIFEST"
  fixture --list --no-live all
  expect_rc 0 "list without live"
  expect_absent "$out" "scripts/stub-live" "list without live"
  expect_contains "$out" "scripts/stub-only-all" "list without live"
  ok "--list --no-live lists every row but the live one"
}

case_live_is_no_skip_permission() {
  # The live tag marks a row; it does not permit exit 77.
  write_runner "$FIXTURE_MANIFEST
qml,live  | scripts/stub-live77"
  fixture qml
  expect_rc 1 "live grants no skip"
  expect_contains "$err" "  - scripts/stub-live77" "live grants no skip"
  expect_absent "$out" "skipped" "live grants no skip"
  ok "a live row exiting 77 without may-skip is a plain failure"
}

CASES=(
  case_area_selection
  case_usage_errors
  case_token_refusals
  case_row_shapes
  case_accepted_rows
  case_area_scoping
  case_failures_collect
  case_list_does_not_execute
  case_declared_skip
  case_no_skip_run
  case_undeclared_skip_fails
  case_skip_never_masks_failure
  case_inert_selector
  case_parser_agreement
  case_live_row_runs_by_default
  case_no_live_omits_and_names
  case_no_live_list
  case_live_is_no_skip_permission
)
for validate_case in "${CASES[@]}"; do
  "$validate_case"
done

if [[ $failures -ne 0 ]]; then
  printf '\ntest-validate: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-validate: all checks passed"
