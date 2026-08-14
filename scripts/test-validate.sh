#!/usr/bin/env bash
# Behavioral coverage for `scripts/validate` and the manifest arms of
# `scripts/check-validation-inventory.py` (VGS-123).
#
# The runner is the entry point every agent and dev session now invokes and
# trusts, and before this nothing committed ever executed it: the inventory guard
# parses the manifest statically by design, CI enumerates the commands as
# individual steps and never calls the runner, and check-format-lint.sh only
# lints it. The demonstrated hole: dropping the last manifest row — the whole Go
# block — left `validate go` and `validate all` printing `ok` while every other
# check exited 0.
#
# TWO FIXTURE STRATEGIES, deliberately:
#
#   1. Selection and reporting behavior runs from a THROWAWAY REPO — a temp dir
#      holding a copy of `scripts/validate` whose manifest heredoc is replaced
#      with a fixture, plus stub commands. `repo_root` derives from the script's
#      own location, so nothing here reaches this checkout, and the fixture can
#      carry shapes the real manifest has none of.
#
#   2. Membership assertions run against the REAL manifest through `--list`,
#      which executes nothing. A fixture cannot answer "does `validate qml` still
#      contain the surface smoke" — that is a fact about the shipped manifest,
#      and retagging that row is a shrink the inventory guard does not see.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runner="$repo_root/scripts/validate"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
}
ok() { printf '  ok    %s\n' "$1"; }

# --- fixture repo -----------------------------------------------------------
# The fixture manifest exercises every selection shape the real one does, plus
# the multi-tag row it has none of (so that branch is not dead on real data) and
# two failing commands (so collection is proven, not assumed).
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

# The `always` row reaches every area — the regression that made a Go-scoped
# run skip the format/lint floor over the Go it had just changed.
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

write_runner 'go        | scripts/stub-go
scripts/stub-qml
always    | scripts/stub-always'
fixture --list all
expect_rc 2 "separator-less row"
expect_contains "$err" "manifest row has no AREAS | COMMAND separator" "separator-less row"
expect_absent "$out" "scripts/stub-go" "separator-less row"
ok "a row with no | exits 2 instead of vanishing from every area"

write_runner 'go        | scripts/stub-go
qml       |
always    | scripts/stub-always'
fixture --list all
expect_rc 2 "empty command row"
expect_contains "$err" "manifest row has an empty command" "empty command row"
ok "a row with an empty command exits 2"

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
expect_contains "$err" "FAIL (go, 2 of 3 commands)" "two failures"
expect_contains "$out" "ran stub-go" "two failures"
ok "both failures are listed, exit 1, and nothing fail-fasts"

# (f) --list prints without executing: the failing stubs produce no output and
# the status stays 0.
fixture --list go
expect_rc 0 "--list does not execute"
expect_absent "$out" "a ran" "--list does not execute"
expect_contains "$out" "scripts/stub-fail-a" "--list does not execute"
ok "--list prints the commands without running them"

# The skip channel: exit 77 from a `may-skip` row is neither pass nor failure,
# and the summary names it so `ok` is never bare.
write_runner 'qml,may-skip | scripts/stub-skip
qml          | scripts/stub-qml'
fixture qml
expect_rc 0 "declared skip"
expect_contains "$out" "1 skipped (scripts/stub-skip)" "declared skip"
ok "a may-skip row exiting 77 is reported as a named skip, not a bare ok"

# ...and 77 from a row that did NOT declare it stays a failure, so an unrelated
# check cannot be demoted out of the failure list by picking that status.
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
expect_contains "$err" "1 skipped (scripts/stub-skip)" "skip plus failure"
expect_contains "$err" "  - scripts/stub-fail-a" "skip plus failure"
ok "a skip never masks a failure"

echo "=== the shipped manifest still reaches the local-only checks ==="

# These are the checks CI cannot run, so a scoped local run is the only thing
# that ever executes them. Retagging one to `-` shrinks the area silently:
# check-validation-inventory.py sees a valid tag and stays green.
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

# The degraded modes that can be flag-forced must be forced: a plain skip is
# indistinguishable from a pass, which is the rule the whole suite rests on.
expect_contains "$real_qml" "--require-nested" "qml-smoke require flags"
expect_contains "$real_qml" "--require-static" "qml-smoke require flags"
ok "the QML smoke is required, not allowed to degrade to a skip"

echo "=== check-validation-inventory.py manifest arms ==="

# The guard's manifest arms, driven by pointing its RUNNER at a fixture. Each
# mutation must produce its OWN message: a control that merely fails proves
# nothing about which arm caught it.
# Runs check-validation-inventory.py with its RUNNER pointed at $1, capturing
# stderr and any SystemExit message. Importing rather than exec'ing swaps the
# fixture runner in without a whole fake repo: every other path the guard reads
# stays real, so a mutation's message is the only thing that changes.
run_guard() {
  RUNNER_PATH="$1" python3 - "$repo_root" <<'GUARD_PY'
import contextlib, importlib.util, io, os, pathlib, sys
spec = importlib.util.spec_from_file_location(
    "inv", pathlib.Path(sys.argv[1]) / "scripts" / "check-validation-inventory.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.RUNNER = pathlib.Path(os.environ["RUNNER_PATH"])
buf = io.StringIO()
try:
    with contextlib.redirect_stderr(buf):
        mod.main()
except SystemExit as exc:
    buf.write(str(exc))
print(buf.getvalue())
GUARD_PY
}

guard_case() {
  # $1 = case name, $2 = fixture runner content, $3 = expected message fragment
  local name="$1" expect="$3" probe="$tmp/probe-runner" got
  printf '%s' "$2" >"$probe"
  chmod +x "$probe"
  got="$(run_guard "$probe")"
  if [[ "$got" == *"$expect"* ]]; then
    ok "$name"
  else
    fail "$name" "expected message fragment: $expect
got:
$got"
  fi
}

real_runner="$(cat "$runner")"

guard_case "missing MANIFEST_EOF heredoc is reported" \
  "${real_runner//MANIFEST_EOF/MANIFEST_END}" \
  "has no MANIFEST_EOF heredoc"

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

guard_case "an unknown tag is reported" \
  "$(python3 - "$runner" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("docs      | scripts/check-doc-growth.py",
                "dcos      | scripts/check-doc-growth.py"), end="")
PY
)" \
  "which is neither an area in the runner's AREAS list"

guard_case "an area with no rows is reported" \
  "$(python3 - "$runner" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("docs      | scripts/check-doc-growth.py",
                "-         | scripts/check-doc-growth.py"), end="")
PY
)" \
  "no manifest row is tagged with it"

# The executable-bit arm (VGS-30 applied to the entry point itself).
non_exec="$tmp/non-exec-runner"
cp "$runner" "$non_exec"
chmod -x "$non_exec"
guard_out="$(run_guard "$non_exec")"
expect_contains "$guard_out" "scripts/validate is not executable" "runner executable bit"
ok "a non-executable runner is reported"

# CONTROL: the unmutated runner produces none of those messages, so the cases
# above are catching their mutation rather than pre-existing noise.
guard_out="$(run_guard "$runner")"
for noise in "has no MANIFEST_EOF heredoc" "manifest row has no" "empty command" \
  "is neither an area" "no manifest row is tagged with it" "is not executable"; do
  expect_absent "$guard_out" "$noise" "unmutated control"
done
ok "the unmutated runner triggers none of those arms"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-validate: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-validate: all checks passed"
