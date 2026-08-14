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
# Runs check-validation-inventory.py against a fixture, capturing BOTH its
# output and its exit status. Capturing only the text was the hole: every case
# below then asserted that the right diagnosis appeared, and a guard that printed
# the right message and returned 0 would have passed — verifying diagnosis, not
# refusal, in a file whose whole purpose is refusal.
#
# The path constants are patched on the loaded module, so the guard reads a
# mutated runner or doc while every other path it touches (ci.yml, scripts/)
# stays real. That injection point is why the library takes explicit paths.
#
# Usage: run_guard [VAR=PATH ...]   VAR in RUNNER_PATH AGENTS_PATH TABLES_PATH
# Sets: guard_out, guard_rc
run_guard() {
  guard_rc=0
  guard_out="$(env "$@" python3 - "$repo_root" <<'GUARD_PY'
import contextlib, importlib.util, io, os, pathlib, sys
spec = importlib.util.spec_from_file_location(
    "inv", pathlib.Path(sys.argv[1]) / "scripts" / "check-validation-inventory.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for var, attr in (
    ("RUNNER_PATH", "RUNNER"),
    ("AGENTS_PATH", "AGENTS"),
    ("TABLES_PATH", "TABLES_DOC"),
):
    if os.environ.get(var):
        setattr(mod, attr, pathlib.Path(os.environ[var]))
# AREA_ENUMERATING_DOCS captured the originals at import time.
mod.AREA_ENUMERATING_DOCS = (mod.AGENTS, mod.TABLES_DOC, mod.SKILL_DOC)
buf = io.StringIO()
status = 0
try:
    with contextlib.redirect_stderr(buf):
        status = mod.main()
except mod.ManifestError as error:
    buf.write(str(error))
    status = 1
except SystemExit as exc:
    buf.write(str(exc))
    # SystemExit("text") carries a STRING code; passing it to sys.exit would
    # print it to the real stderr and exit 1, leaking past this capture.
    status = exc.code if isinstance(exc.code, int) else 1
print(buf.getvalue())
sys.exit(status if isinstance(status, int) else 1)
GUARD_PY
  )" || guard_rc=$?
}

# expect_refused <case name> <message fragment> — a mutated fixture must both
# DIAGNOSE and REFUSE. Asserting only the text is what item #4 caught.
expect_refused() {
  expect_contains "$guard_out" "$2" "$1"
  [[ "$guard_rc" -ne 0 ]] || fail "$1" "guard printed the message but exited 0 — it diagnosed without refusing"
}

guard_case() {
  # $1 = case name, $2 = fixture runner content, $3 = expected message fragment
  local name="$1" probe="$tmp/probe-runner"
  printf '%s' "$2" >"$probe"
  chmod +x "$probe"
  run_guard "RUNNER_PATH=$probe"
  expect_refused "$name" "$3"
  ok "$name"
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

guard_case "an unknown tag is reported (by the shared grammar)" \
  "$(python3 - "$runner" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("docs      | scripts/check-doc-growth.py",
                "dcos      | scripts/check-doc-growth.py"), end="")
PY
)" \
  "malformed tag field"

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

# THE REALISTIC UNWIRING, and the one the arm used to miss entirely: a token
# that is declared AND carried by a manifest row, whose branch is gone. Leaving
# the heredoc in the searched body made the row itself satisfy the test, so
# deleting the `may-skip` branch outright still looked wired.
guard_case "a declared tag carried by a manifest row but unwired is reported" \
  "$(python3 - "$runner" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
t = t.replace("TAG_ATTRIBUTES=(- always may-skip)", "TAG_ATTRIBUTES=(- always may-skip nightly)")
t = t.replace("docs      | scripts/check-doc-growth.py",
              "docs,nightly | scripts/check-doc-growth.py")
print(t, end="")
MUT
)" \
  "never acts on it outside that array"

# The COMMENT-STRIPPING half of the same parser. Without it, a token mentioned
# once in the header prose reads as wired — the exact scenario the stripping
# exists to catch, and the half that had no control at all.
guard_case "a declared tag named only in a comment is reported" \
  "$(python3 - "$runner" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
t = t.replace("TAG_ATTRIBUTES=(- always may-skip)", "TAG_ATTRIBUTES=(- always may-skip nightly)")
t = t.replace("# Exit status a `may-skip` row uses",
              "# nightly rows would be for a nightly lane.\n# Exit status a `may-skip` row uses")
print(t, end="")
MUT
)" \
  "never acts on it outside that array"

# The prose arm's OTHER direction: a document that stops stating the list at all
# used to be skipped silently, so rewording a lead-in turned the comparison off.
reworded="$tmp/reworded-agents.md"
python3 - "$repo_root/AGENTS.md" >"$reworded" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("areas `go`, `qml`, `helper`,\n`packaging`, `docs`, `all`",
                "one area per run: `go`, `qml`, `helper`,\n`packaging`, `docs`, `all`"), end="")
MUT
run_guard "AGENTS_PATH=$reworded"
expect_refused "reworded lead-in" "no longer states the validate area list"
ok "a document that stops stating the area list is reported, not skipped"

# ...and every named document must currently yield a non-empty list, so the
# case above is catching the rewording rather than a doc that never stated one.
python3 - "$repo_root" <<'PROBE' || fail "enumerating docs" "a named document yields no area list today"
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "inv", root / "scripts" / "check-validation-inventory.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for doc in mod.AREA_ENUMERATING_DOCS:
    stated = mod.prose_areas(doc)
    assert stated, doc
    print(f"  ok    {doc.name} states {len(stated)} areas")
PROBE
ok "every named document states its area list today"

# The remaining library raises, each cheap to reach through a fixture. Left
# uncovered deliberately: the PyYAML-missing raise (environment, not logic) and
# `states an empty validate area list` (the regex that finds the enumeration
# requires at least one backticked name, so a match can never be empty — it is a
# belt-and-braces raise kept for the day that regex is loosened).
guard_case "an empty manifest is reported" \
  "$(python3 - "$runner" <<'MUT'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
print(re.sub(r"(<<'MANIFEST_EOF'\n).*?(\nMANIFEST_EOF\n)", r"\1\2", t, flags=re.DOTALL), end="")
MUT
)" \
  "manifest is empty"

# BOTH READERS MUST REFUSE THE SAME ROWS, and by the same rule rather than by
# coincidence: the library holds the same tag grammar the runner does, so every
# shape scripts/test-validate.sh pins on the runner is pinned here on the
# library. An empty tag field and a trailing comma were each accepted by one
# reader and dropped by the other before the grammar replaced the shape checks.
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
SHAPES

# The command half, mirrored: the library shells out to the same parser the
# runner uses, so neither reader accepts a row the other refuses.
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

guard_case "a missing AREAS list is reported" \
  "${real_runner/AREAS=(go qml helper packaging docs all)/AREA_NAMES=(go qml helper packaging docs all)}" \
  "has no AREAS=( ... ) list"

guard_case "a missing TAG_ATTRIBUTES list is reported" \
  "${real_runner/TAG_ATTRIBUTES=(- always may-skip)/TAG_ATTRS=(- always may-skip)}" \
  "has no TAG_ATTRIBUTES=( ... ) list"

# The table lead-in the local-only/reached-indirectly comparison keys on.
no_table="$tmp/no-table.md"
python3 - "$repo_root/.github/instructions/validation-scripts.instructions.md" >"$no_table" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("**Local-only — CI cannot run these at all:**", "**Local-only:**"), end="")
MUT
run_guard "TABLES_PATH=$no_table"
expect_refused "missing table lead-in" "has no table introduced by"
ok "a table whose lead-in changed is reported"

# WITHOUT PyYAML the module must still import, every non-YAML parser must still
# work, and the ci.yml parse must fail with the concise prerequisite line rather
# than a traceback. This was raised at module scope, so the failure fired during
# IMPORT — before the caller installed its handler — turning one clear line into
# a traceback from the guard and a cascade of unrelated fixture failures here.
# Simulated with a sys.modules sentinel, which makes `import yaml` raise exactly
# as an absent package does.
pyyaml_out="$(python3 - "$repo_root" 2>&1 <<'NOYAML' || true
import importlib.util, pathlib, sys
sys.modules["yaml"] = None  # makes `import yaml` raise ModuleNotFoundError
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("IMPORTED")
print("ROWS", len(mod.manifest_rows(root / "scripts" / "validate")))
try:
    mod.ci_run_commands(root / ".github" / "workflows" / "ci.yml")
except mod.ManifestError as error:
    print("MANIFESTERROR", error)
NOYAML
)"
expect_contains "$pyyaml_out" "IMPORTED" "PyYAML absent"
expect_contains "$pyyaml_out" "ROWS 58" "PyYAML absent"
expect_contains "$pyyaml_out" "MANIFESTERROR PyYAML is not installed" "PyYAML absent"
expect_absent "$pyyaml_out" "Traceback" "PyYAML absent"
ok "without PyYAML the module imports, the other parsers work, and ci.yml fails with one line"

# The executable-bit arm (VGS-30 applied to the entry point itself).
non_exec="$tmp/non-exec-runner"
cp "$runner" "$non_exec"
chmod -x "$non_exec"
run_guard "RUNNER_PATH=$non_exec"
expect_refused "runner executable bit" "scripts/validate is not executable"
ok "a non-executable runner is reported"

# CONTROL: the unmutated runner produces none of those messages AND exits 0. The
# noise list covers every arm above — a parser whose filter breaks reports EVERY
# attribute as unwired, and without that fragment here the test owning the arm
# would stay green while a neighbouring check failed instead.
run_guard
for noise in "has no MANIFEST_EOF heredoc" "manifest row has no" "empty command" \
  "malformed tag field" "no manifest row is tagged with it" "is not executable" \
  "never acts on it outside that array" "enumerates the validate areas but omits" \
  "no longer states the validate area list"; do
  expect_absent "$guard_out" "$noise" "unmutated control"
done
[[ "$guard_rc" -eq 0 ]] || fail "unmutated control" "the real tree does not pass the guard (rc $guard_rc)"
ok "the unmutated runner triggers none of those arms and exits 0"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-validation-inventory: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-validation-inventory: all checks passed"
