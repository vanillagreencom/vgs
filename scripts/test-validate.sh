#!/usr/bin/env bash
# Test runner selection and reporting with copied scripts and stub commands.
# Read the real manifest through --list for area membership because fixtures cannot prove
# that the repository still includes a required check.
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

# Include multi-tag rows even when the real manifest has none.
fixture_repo="$tmp/repo"
mkdir -p "$fixture_repo/scripts/lib"
# Copy the grammar because this fixture changes the manifest, not its vocabulary.
cp "$repo_root/scripts/lib/validation-grammar.conf" "$fixture_repo/scripts/lib/"

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

FIXTURE_MANIFEST='go        | scripts/stub-go
qml       | scripts/stub-qml
go,qml    | scripts/stub-both
always    | scripts/stub-always
-         | scripts/stub-only-all
docs      | scripts/stub-docs
helper    | scripts/stub-helper
packaging | scripts/stub-packaging'

for stub in stub-go stub-qml stub-both stub-always stub-only-all stub-docs stub-helper stub-packaging; do
  printf '#!/usr/bin/env bash\necho "ran %s"\n' "$stub" >"$fixture_repo/scripts/$stub"
  chmod +x "$fixture_repo/scripts/$stub"
done
write_runner "$FIXTURE_MANIFEST"

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

echo "=== area selection (fixture manifest) ==="


fixture --list go
expect_rc 0 "go selection"
expect_list 'scripts/stub-go
scripts/stub-both
scripts/stub-always' "go selection"
ok "go selects its rows, the multi-tag row and the always row"


fixture --list qml
expect_rc 0 "qml selection"
expect_list 'scripts/stub-qml
scripts/stub-both
scripts/stub-always' "qml selection"
ok "qml selects the same multi-tag row (go,qml is not go-only)"


for area in go qml docs helper packaging; do
  fixture --list "$area"
  expect_absent "$out" "scripts/stub-only-all" "- row excluded from $area"
done
ok "the - row is in no named area"

fixture --list all
expect_rc 0 "all selection"
expect_list 'scripts/stub-go
scripts/stub-qml
scripts/stub-both
scripts/stub-always
scripts/stub-only-all
scripts/stub-docs
scripts/stub-helper
scripts/stub-packaging' "all selection"
ok "all selects every row, in manifest order"

# Universal rows must run in every area, including format checks during Go validation.
for area in go qml docs helper packaging all; do
  fixture --list "$area"
  expect_contains "$out" "scripts/stub-always" "always row in $area"
done
ok "the always row is selected by every area"

# Default invocation must select the declared all-rows argument.
fixture --list
expect_rc 0 "default area"
expect_contains "$out" "scripts/stub-only-all" "default area"
ok "no area argument defaults to all"

echo "=== fail-closed argument handling ==="


fixture nope
expect_rc 2 "unknown area"
expect_contains "$err" "unknown area nope" "unknown area"
expect_absent "$out" "ran " "unknown area"
ok "unknown area exits 2 having run nothing"

# Reject multiple area arguments so the invocation cannot silently discard a requested area.
fixture --list go qml
expect_rc 2 "two areas"
expect_contains "$err" "one area per run; got go and qml" "two areas"
expect_absent "$out" "scripts/stub-" "two areas"
ok "two areas exit 2 and select nothing"

fixture --bogus
expect_rc 2 "unknown option"
expect_contains "$err" "unknown option --bogus" "unknown option"
ok "unknown option exits 2"

echo "=== malformed manifest rows are fatal, never dropped ==="

# Test malformed tag syntax before execution in named and default areas.
# Require refusal and no executed commands so omitted rows cannot look like scoped success.
rejected_everywhere() {
  local area
  write_runner "$2"
  for area in all go qml docs; do
    fixture --list "$area"
    expect_rc 2 "$1 in $area"
    expect_contains "$err" "$3" "$1 in $area"
    expect_absent "$out" "scripts/" "$1 in $area"
  done
  ok "$1"
}

# Generate token cases from declared class properties. Syntax separator cases remain explicit
# because they belong to the tag-field format rather than individual tokens.
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
  rejected_everywhere "$name" "$row
always    | scripts/stub-always" "$expect"
done <"$tmp/generated-cases"

# Generate acceptance cases too so an over-restrictive grammar cannot pass.
python3 - "$repo_root" >"$tmp/generated-accepts" <<'GEN'
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
    print(f"standalone `{token}` is accepted;{token};{area}")
for token in sorted(g.row_tags - g.standalone - g.exclusive):
    for area in sorted(g.areas):
        print(f"`{token}` beside an area is accepted;{area},{token};{area}")
        break
GEN
while IFS=';' read -r name tags area; do
  [[ -n "$name" ]] || continue
  write_runner "$(printf '%-10s| scripts/stub-under-test' "$tags")
always    | scripts/stub-always"
  fixture --list "$area"
  expect_rc 0 "$name"
  expect_contains "$out" "scripts/stub-under-test" "$name"
  ok "$name"
done <"$tmp/generated-accepts"


while IFS=';' read -r name expect row; do
  [[ -n "$name" ]] || continue
  rejected_everywhere "$name" "$row
always    | scripts/stub-always" "$expect"
done <<SHAPES
a row with no separator is fatal;manifest row has no;scripts/stub-qml
an empty command is fatal;has an empty command;qml       |
an empty tag field is fatal;has an empty tag field;          | scripts/stub-go
a separator-only row is fatal;has an empty tag field;   |
a trailing separator is fatal;it ends with a separator;qml,      | scripts/stub-go
a leading separator is fatal;it starts with a separator;,qml      | scripts/stub-go
a repeated separator is fatal;it has a repeated separator;qml,,go   | scripts/stub-go
a non-breaking space is fatal;malformed tag field;$(printf 'go\xc2\xa0')      | scripts/stub-go
SHAPES

# Validate shell syntax for every row before running any check, including rows outside the requested area.
while IFS=';' read -r name command; do
  [[ -n "$name" ]] || continue
  rejected_everywhere "$name" "always    | $command
qml       | scripts/stub-qml" "invalid shell syntax"
done <<'SHAPES'
a trailing operator is fatal;scripts/stub-go &&
an unbalanced quote is fatal;scripts/stub-go "oops
an unclosed brace is fatal;{ scripts/stub-go
an unclosed subshell is fatal;(cd backend && go build
SHAPES

# Exercise accepted grammar productions with exact expected commands.
# A substring matched by another row cannot prove the target row was accepted.
accepted_row() {

  local name="$1" tags="$2" area="$3"
  write_runner "$tags | scripts/stub-under-test
always    | scripts/stub-always"
  fixture --list "$area"
  expect_rc 0 "$name"
  expect_contains "$out" "scripts/stub-under-test" "$name"
  ok "$name"
}

accepted_row "a single area selects in that area" "qml      " qml
accepted_row "several areas select in each" "go,qml   " go
accepted_row "always alone selects in every area" "always   " docs
accepted_row "a dash row is selected by all" "-        " all
accepted_row "an area with a modifier still selects" "qml,may-skip" qml
accepted_row "always with a modifier still selects" "always,may-skip" helper
accepted_row "a repeated tag is inert, not an error" "qml,qml  " qml
accepted_row "a command may contain a separator" "qml      " qml

# Require the same row to be absent from an unrelated area.
write_runner "qml       | scripts/stub-under-test
always    | scripts/stub-always"
fixture --list go
expect_rc 0 "area scoping"
expect_absent "$out" "scripts/stub-under-test" "area scoping"
ok "a row tagged for one area is not selected by another"

echo "=== execution, failure collection and the skip channel ==="

cat >"$fixture_repo/scripts/stub-fail-a" <<'EOF'
#!/usr/bin/env bash
echo "a ran"; exit 1
EOF
cat >"$fixture_repo/scripts/stub-fail-b" <<'EOF'
#!/usr/bin/env bash
echo "b ran"; exit 3
EOF
cat >"$fixture_repo/scripts/stub-skip" <<'EOF'
#!/usr/bin/env bash
echo "nothing to check here"; exit 77
EOF
chmod +x "$fixture_repo/scripts/stub-fail-a" "$fixture_repo/scripts/stub-fail-b" \
  "$fixture_repo/scripts/stub-skip"


write_runner 'go        | scripts/stub-fail-a
go        | scripts/stub-fail-b
go        | scripts/stub-go'
fixture go
expect_rc 1 "two failures"
expect_contains "$err" "  - scripts/stub-fail-a" "two failures"
expect_contains "$err" "  - scripts/stub-fail-b" "two failures"
expect_contains "$err" "FAIL (go, 2 of 3 commands failed)" "two failures"
expect_contains "$out" "ran stub-go" "two failures"
ok "both failures are listed, exit 1, and nothing fail-fasts"


fixture --list go
expect_rc 0 "--list does not execute"
expect_absent "$out" "a ran" "--list does not execute"
expect_contains "$out" "scripts/stub-fail-a" "--list does not execute"
ok "--list prints the commands without running them"


write_runner 'qml,may-skip | scripts/stub-skip
qml          | scripts/stub-qml'
fixture qml
# Skip status must remain visible to callers; exit zero cannot represent a check that never ran.
expect_rc 77 "declared skip"
# Report executed count separately from skipped rows.
expect_contains "$out" "ok (qml, 1 of 2 commands, 1 skipped: scripts/stub-skip)" "declared skip"
expect_contains "$out" "exit 77 — passed, but 1 command did not run" "declared skip"
ok "a may-skip row exiting 77 gives a named skip, an N-of-M count and exit 77"


write_runner 'qml       | scripts/stub-qml
qml       | scripts/stub-go'
fixture qml
expect_rc 0 "no skip"
expect_absent "$out" "skipped" "no skip"
expect_absent "$out" "exit 77" "no skip"
ok "a fully-executed run still exits 0 with no skip text"


write_runner 'qml       | scripts/stub-skip
qml       | scripts/stub-qml'
fixture qml
expect_rc 1 "undeclared 77"
expect_contains "$err" "  - scripts/stub-skip" "undeclared 77"
expect_absent "$out" "skipped" "undeclared 77"
ok "exit 77 without the may-skip tag is a plain failure"


write_runner 'qml,may-skip | scripts/stub-skip
qml          | scripts/stub-fail-a'
fixture qml
expect_rc 1 "skip plus failure"
expect_contains "$err" "1 skipped: scripts/stub-skip" "skip plus failure"
expect_contains "$err" "  - scripts/stub-fail-a" "skip plus failure"
ok "a skip never masks a failure"

# Corrupt the inventory guard's own row in the real manifest so silent omission cannot hide its detector.
self_probe="$fixture_repo/scripts/self-concealing"
for mutation in "alway     :malformed tag field" "          :an empty tag field" "always,   :ends with a separator"; do
  MUT_TO="${mutation%%:*}" python3 - "$runner" >"$self_probe" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "always    | scripts/check-validation-inventory.py"
assert t.count(old) == 1, "the inventory guard's manifest row moved"
print(t.replace(old, os.environ["MUT_TO"] + "| scripts/check-validation-inventory.py"), end="")
MUT
  chmod +x "$self_probe"
  for area in docs go qml all; do
    rc=0
    out="$("$self_probe" --list "$area" 2>"$tmp/stderr")" || rc=$?
    err="$(cat "$tmp/stderr")"
    [[ "$rc" == 2 ]] || fail "self-concealing" "expected exit 2 in area $area, got $rc"
    expect_contains "$err" "${mutation##*:}" "self-concealing"
    expect_absent "$out" "scripts/check-" "self-concealing"
  done
done
ok "a malformed tag on the inventory guard's OWN row fails in every area, unrun"

# Remove universal selection through class properties while leaving row syntax valid.
# The runner must refuse before listing or executing because this change can exclude its own guard.
grammar_probe="$tmp/grammar-probe"
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
  [[ "$rc" == 2 ]] || fail "inert selector" "expected exit 2 in area $area, got $rc"
  expect_contains "$err" "selects nothing in any named area" "inert selector in $area"
  expect_contains "$err" "always" "inert selector in $area"
  expect_absent "$out" "scripts/" "inert selector in $area"
done
ok "a selector class that stops being universal is refused, not silently narrowed"

echo "=== the shipped manifest still reaches the local-only checks ==="

# Verify area membership of local-only checks that CI cannot execute.
real_qml="$("$runner" --list qml)"
real_go="$("$runner" --list go)"
for needed in \
  "scripts/qml-smoke.sh --nested --require-static --require-nested" \
  "scripts/check-validation-safety.sh --require-static" \
  "scripts/smoke-surfaces.sh"; do
  expect_contains "$real_qml" "$needed" "validate qml membership"
done
ok "validate qml still runs the nested smoke, the safety guard and the surfaces"

expect_contains "$real_go" "(cd backend && go build ./... && go vet ./... && go test -race ./...)" \
  "validate go membership"
ok "validate go still runs the Go block"

# Compare runner and library manifests directly so a dropped non-script block cannot remain unnoticed.
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
if [[ "$python_rows" == "$("$runner" --list all)" ]]; then
  ok "the bash and python manifest readers see the same commands, in the same order"
else
  fail "parser agreement" "scripts/validate --list all and validation_manifest.manifest_rows disagree:
$(diff <(printf '%s\n' "$python_rows") <(printf '%s\n' "$("$runner" --list all)") || true)"
  ok "parser agreement"
fi

# Require non-skipping modes when the check exposes a forcing flag.
expect_contains "$real_qml" "--require-nested" "qml-smoke require flags"
expect_contains "$real_qml" "--require-static" "qml-smoke require flags"
ok "the QML smoke is required, not allowed to degrade to a skip"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-validate: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-validate: all checks passed"
