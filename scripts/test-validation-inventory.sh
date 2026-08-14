#!/usr/bin/env bash
# Must-fail controls for the manifest arms of scripts/check-validation-inventory.py
# (VGS-123). Split from scripts/test-validate.sh, which covers the runner's own
# behavior; this file covers the GUARD that reads the runner.
#
# Each arm is driven by pointing the guard's RUNNER at a mutated copy and
# asserting its OWN message — a control that merely fails proves nothing about
# which arm caught it — with an unmutated control proving none of them fire on
# the real file. Importing the guard rather than exec'ing it is what lets the
# fixture be swapped in without building a whole fake repo: every other path it
# reads (ci.yml, the instruction tables, scripts/) stays real.
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
ok() {
  if [[ $case_failed -eq 0 ]]; then
    printf '  ok    %s\n' "$1"
  fi
  case_failed=0
}
expect_contains() {
  [[ "$1" == *"$2"* ]] || fail "$3" "expected to contain: $2 (got: $1)"
}
expect_absent() {
  [[ "$1" != *"$2"* ]] || fail "$3" "expected NOT to contain: $2 (got: $1)"
}

echo "=== check-validation-inventory.py manifest arms ==="

# The guard's manifest arms. Each mutation must produce its OWN message: a
# control that merely fails proves nothing about which arm caught it.
# Runs check-validation-inventory.py with its RUNNER pointed at $1. Importing
# rather than exec'ing swaps the fixture in without a whole fake repo: every
# other path the guard reads stays real, so only the mutation's message changes.
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

guard_case "a declared but unwired tag attribute is reported" \
  "${real_runner/TAG_ATTRIBUTES=(- always may-skip)/TAG_ATTRIBUTES=(- always may-skip nightly)}" \
  "never acts on it outside that array"

# Mutating AREAS rather than the docs keeps this inside guard_case's runner-only
# fixture: adding an area the prose omits is the same drift as deleting one.
guard_case "an area missing from the prose enumeration is reported" \
  "${real_runner/AREAS=(go qml helper packaging docs all)/AREAS=(go qml helper packaging docs rust all)}" \
  "enumerates the validate areas but omits \`rust\`"

# The executable-bit arm (VGS-30 applied to the entry point itself).
non_exec="$tmp/non-exec-runner"
cp "$runner" "$non_exec"
chmod -x "$non_exec"
guard_out="$(run_guard "$non_exec")"
expect_contains "$guard_out" "scripts/validate is not executable" "runner executable bit"
ok "a non-executable runner is reported"

# CONTROL: the unmutated runner produces none of those messages.
guard_out="$(run_guard "$runner")"
for noise in "has no MANIFEST_EOF heredoc" "manifest row has no" "empty command" \
  "is neither an area" "no manifest row is tagged with it" "is not executable"; do
  expect_absent "$guard_out" "$noise" "unmutated control"
done
ok "the unmutated runner triggers none of those arms"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-validation-inventory: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-validation-inventory: all checks passed"
