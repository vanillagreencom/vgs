#!/usr/bin/env bash
# Behavioral coverage for `scripts/validate` itself (VGS-123). The must-fail
# controls for the guard that READS the runner live in
# `scripts/test-validation-inventory.sh`.
#
# The runner is the entry point every agent and dev session invokes and trusts,
# and before this nothing committed executed it. The demonstrated hole: dropping
# the last manifest row — the whole Go block — left `validate go` and `all`
# printing `ok` while every other check exited 0.
#
# TWO FIXTURE STRATEGIES: (1) selection and reporting run from a THROWAWAY REPO
# holding a copy of `scripts/validate` with a fixture manifest and stub
# commands, so nothing here reaches this checkout; (2) membership assertions run
# against the REAL manifest through `--list`, which executes nothing — a fixture
# cannot answer "does `validate qml` still contain the surface smoke", and
# retagging that row is a shrink the inventory guard does not see.
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
# `ok` closes a case and consumes the per-case flag. Printing it unconditionally
# meant a failed case emitted FAIL to stderr and then `ok` to stdout for the same
# assertion — a transcript asserting the opposite of the result.
ok() {
  if [[ $case_failed -eq 0 ]]; then
    printf '  ok    %s\n' "$1"
  fi
  case_failed=0
}

# --- fixture repo -----------------------------------------------------------
# Exercises every selection shape the real manifest does, plus the multi-tag row
# it has none of (so that branch is not dead on real data).
fixture_repo="$tmp/repo"
mkdir -p "$fixture_repo/scripts"

write_runner() {
  # $1 = fixture manifest body. Everything else about the runner is the real
  # file, so this tests the shipped logic rather than a paraphrase of it.
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
  # Runs the fixture runner, capturing stdout, stderr and status separately.
  rc=0
  out="$("$fixture_repo/scripts/validate" "$@" 2>"$tmp/stderr")" || rc=$?
  err="$(cat "$tmp/stderr")"
}

expect_rc() {
  [[ "$rc" == "$1" ]] || fail "$2" "expected exit $1, got $rc"
}
expect_list() {
  # $1 = expected --list output (exact, order-sensitive), $2 = case name
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

# (a) each area selects exactly its tagged rows, plus every `always` row.
fixture --list go
expect_rc 0 "go selection"
expect_list 'scripts/stub-go
scripts/stub-both
scripts/stub-always' "go selection"
ok "go selects its rows, the multi-tag row and the always row"

# (c) the multi-tag row is selected by BOTH of its areas.
fixture --list qml
expect_rc 0 "qml selection"
expect_list 'scripts/stub-qml
scripts/stub-both
scripts/stub-always' "qml selection"
ok "qml selects the same multi-tag row (go,qml is not go-only)"

# (b) a `-` row is excluded from every named area and included in `all`.
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

# The `always` row reaches every area — the regression that made a Go-scoped run
# skip the format/lint floor over the Go it had just changed.
for area in go qml docs helper packaging all; do
  fixture --list "$area"
  expect_contains "$out" "scripts/stub-always" "always row in $area"
done
ok "the always row is selected by every area"

# No argument means `all`.
fixture --list
expect_rc 0 "default area"
expect_contains "$out" "scripts/stub-only-all" "default area"
ok "no area argument defaults to all"

echo "=== fail-closed argument handling ==="

# (d) an unknown area exits 2 and runs nothing.
fixture nope
expect_rc 2 "unknown area"
expect_contains "$err" "unknown area nope" "unknown area"
expect_absent "$out" "ran " "unknown area"
ok "unknown area exits 2 having run nothing"

# Two positionals are rejected rather than last-one-wins, which silently ran
# one area under the other's name.
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

# THE TAG FIELD IS VALIDATED AGAINST A GRAMMAR, so these are samples of a
# rejected complement, not the definition of it. Two holes came from the
# opposite approach — rules written against whatever a split produced, missing
# the empty field (no elements) and the trailing comma (dropped one). Each case
# asserts the exit STATUS and that NOTHING RAN, across a named area as well as
# `all`: the named area is where each was dropped, and the message was absent
# because nothing fired.
rejected_everywhere() { # $1 name, $2 fixture manifest, $3 expected fragment
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

# name ; expected diagnosis ; the malformed row. `all` is an ARGUMENT not a tag,
# `-` cannot be combined with an area, and normalisation is ASCII in BOTH
# readers so a non-breaking space stays a bad tag for each.
while IFS=';' read -r name expect row; do
  [[ -n "$name" ]] || continue
  rejected_everywhere "$name" "$row
always    | scripts/stub-always" "$expect"
done <<SHAPES
a row with no separator is fatal;has no AREAS | COMMAND separator;scripts/stub-qml
an empty command is fatal;has an empty command;qml       |
an empty tag field is fatal;has an empty tag field;          | scripts/stub-go
a separator-only row is fatal;has an empty tag field;   |
a trailing separator is fatal;it ends with a separator;qml,      | scripts/stub-go
a leading separator is fatal;it starts with a separator;,qml      | scripts/stub-go
a repeated separator is fatal;it has a repeated separator;qml,,go   | scripts/stub-go
a combined dash tag is fatal;cannot be combined;-,go      | scripts/stub-go
an unknown tag is fatal;malformed tag field;qmll      | scripts/stub-go
all is rejected as a row tag;malformed tag field;all       | scripts/stub-go
a non-breaking space is fatal;malformed tag field;$(printf 'go\xc2\xa0')      | scripts/stub-go
SHAPES

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

# (e) two failing checks both appear, with no fail-fast: the command after the
# first failure still runs.
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

# (f) --list prints without executing: the failing stubs produce no output and
# the status stays 0.
fixture --list go
expect_rc 0 "--list does not execute"
expect_absent "$out" "a ran" "--list does not execute"
expect_contains "$out" "scripts/stub-fail-a" "--list does not execute"
ok "--list prints the commands without running them"

# The skip channel: 77 from a `may-skip` row is neither pass nor failure.
write_runner 'qml,may-skip | scripts/stub-skip
qml          | scripts/stub-qml'
fixture qml
# The status carries the skip too. Exiting 0 here would hand a caller a pass
# over a check that never ran — VGS-69's "refusal read as a pass" one layer up,
# and the dev workflow records exactly this status field.
expect_rc 77 "declared skip"
# The leading count is what RAN, matching the FAIL line's N of M shape, rather
# than folding the skipped row into the total.
expect_contains "$out" "ok (qml, 1 of 2 commands, 1 skipped: scripts/stub-skip)" "declared skip"
expect_contains "$out" "exit 77 — passed, but 1 command did not run" "declared skip"
ok "a may-skip row exiting 77 gives a named skip, an N-of-M count and exit 77"

# CONTROL: nothing skipped means exit 0 and no skip text.
write_runner 'qml       | scripts/stub-qml
qml       | scripts/stub-go'
fixture qml
expect_rc 0 "no skip"
expect_absent "$out" "skipped" "no skip"
expect_absent "$out" "exit 77" "no skip"
ok "a fully-executed run still exits 0 with no skip text"

# ...and 77 from a row that did NOT declare it stays a failure.
write_runner 'qml       | scripts/stub-skip
qml       | scripts/stub-qml'
fixture qml
expect_rc 1 "undeclared 77"
expect_contains "$err" "  - scripts/stub-skip" "undeclared 77"
expect_absent "$out" "skipped" "undeclared 77"
ok "exit 77 without the may-skip tag is a plain failure"

# A skip alongside a real failure is still a failure, and both are reported.
write_runner 'qml,may-skip | scripts/stub-skip
qml          | scripts/stub-fail-a'
fixture qml
expect_rc 1 "skip plus failure"
expect_contains "$err" "1 skipped: scripts/stub-skip" "skip plus failure"
expect_contains "$err" "  - scripts/stub-fail-a" "skip plus failure"
ok "a skip never masks a failure"

# THE SELF-CONCEALING CASE, on the SHIPPED manifest. The malformed row is the
# inventory guard's own: lose it and every scoped run drops the check whose job
# is reporting malformed rows. A fixture cannot carry that, and without a named
# case the scenario surfaces only as an errexit abort further down.
self_probe="$tmp/self-concealing"
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

echo "=== the shipped manifest still reaches the local-only checks ==="

# The checks CI cannot run: a scoped local run is the only thing that executes
# them, and retagging one to `-` shrinks the area silently.
real_qml="$("$runner" --list qml)"
real_go="$("$runner" --list go)"
real_docs="$("$runner" --list docs)"
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

# The vendor-sync checks are deliberately NOT `always`: both hard-fail when the
# vstack-managed copy under .agents/ is absent, so a plain clone or a pre-refresh
# worktree would fail every scoped run for a reason unrelated to the change.
for tagged in scripts/check-review-gate-vendor.sh scripts/check-size-ratchet-vendor.sh; do
  expect_absent "$real_docs" "$tagged" "vendor checks stay out of scoped runs"
done
ok "the vendor-sync checks are reachable only from validate all"

# THE TWO PARSERS MUST AGREE. The runner's bash loop decides what actually runs;
# the shared python reader decides what the guard checks. Nothing tied them
# together: a row the python side dropped resurfaces only for `scripts/` paths,
# as "executable but the manifest never runs it", so the third_party/ engine
# tests and the Go block could have vanished from the guard's view unnoticed.
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

# Degraded modes that can be flag-forced must be: a skip reads as a pass.
expect_contains "$real_qml" "--require-nested" "qml-smoke require flags"
expect_contains "$real_qml" "--require-static" "qml-smoke require flags"
ok "the QML smoke is required, not allowed to degrade to a skip"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-validate: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-validate: all checks passed"
