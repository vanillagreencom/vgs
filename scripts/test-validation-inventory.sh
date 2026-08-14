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
fixture_dir="$tmp/fixture"
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

# Every arm-specific message this file drives a fixture to produce. Used two
# ways: as the noise list for the unmutated control, and to assert that a
# fixture's OWN verdict is never replaced by a prerequisite message.
ARM_MESSAGES=(
  "has no MANIFEST_EOF heredoc" "manifest row has no" "empty command"
  "malformed tag field" "carries no selector" "no manifest row is tagged with it"
  "is not executable" "does not act on it outside that array"
  "enumerates the validate areas but omits" "no longer states the validate area list"
  "invalid shell syntax" "has no table introduced by"
  "no longer declares" "is not a lowercase area token" "grammar A2"
)

# PyYAML is a PREREQUISITE of one arm, not of this file. Without it the guard
# cannot compare against ci.yml and correctly fails — so a well-formed tree
# exits 1 carrying exactly that one problem, and every other arm still answers.
# Detected rather than assumed, because the expectations below differ.
have_yaml=1
python3 -c 'import yaml' >/dev/null 2>&1 || have_yaml=0

noyaml_path="$tmp/noyaml"
mkdir -p "$noyaml_path/yaml"
printf 'raise ImportError("no yaml (test shim)")\n' >"$noyaml_path/yaml/__init__.py"

# expect_clean_run <case> — the guard found nothing of its OWN. With PyYAML that
# is exit 0; without it, exit 1 carrying the CI prerequisite and nothing else.
expect_clean_run() {
  local name="$1" msg
  for msg in "${ARM_MESSAGES[@]}"; do
    expect_absent "$guard_out" "$msg" "$name"
  done
  if [[ $have_yaml -eq 1 ]]; then
    [[ "$guard_rc" -eq 0 ]] || fail "$name" "the real tree does not pass the guard (rc $guard_rc)"
  else
    [[ "$guard_rc" -ne 0 ]] || fail "$name" "PyYAML is absent but the guard passed anyway"
    expect_contains "$guard_out" "CI coverage was NOT checked" "$name"
  fi
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
    ("GRAMMAR_PATH", "GRAMMAR"),
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

# grammar_case <name> <grammar content> <expected fragment> — the vocabulary
# moved out of the runner's arrays into scripts/lib/validation-grammar.conf, so
# the cases that used to mutate `AREAS=(...)` and `TAG_ATTRIBUTES=(...)` mutate
# the definition instead. That is the point of the move: there is one place to
# mutate, and one place a rule can be wrong.
grammar_case() {
  local name="$1" probe="$tmp/probe-grammar.conf"
  printf '%s' "$2" >"$probe"
  run_guard "GRAMMAR_PATH=$probe"
  expect_refused "$name" "$3"
  ok "$name"
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

real_grammar="$(cat "$repo_root/scripts/lib/validation-grammar.conf")"

# A token declared in the grammar but never acted on by the runner. Matched as a
# WHOLE TOKEN: `skip` occurs inside `may-skip`, and a substring test passed it.
grammar_case "a declared but unwired token is reported" \
  "$real_grammar
token nightly    modifier" \
  "does not act on it"

grammar_case "an unwired token that is a SUBSTRING of a wired one is reported" \
  "$real_grammar
token skip       modifier" \
  "does not act on it"

# PARTICIPATION, NOT APPEARANCE. `status` and `run` are exact whole-token
# matches against the runner's own variables, so a text search accepted either
# as a modifier while the tag did nothing. Both must be rejected, and the real
# tokens must still pass — an over-tight rule that rejects everything would
# satisfy the reject cases alone.
while IFS=';' read -r label token; do
  [[ -n "$label" ]] || continue
  grammar_case "$label" \
    "$real_grammar
token $token    modifier" \
    "does not act on it"
done <<'COLLISIONS'
an inert token colliding with a runner variable is reported;status
an inert token colliding with a runner word is reported;run
an inert token with no collision at all is reported;alsoinert
COLLISIONS

# The accept side: the real non-area tokens participate, so the unmutated
# grammar passes. Asserted explicitly rather than inferred from the control
# below, since "everything is rejected" would otherwise look like success.
run_guard
expect_absent "$guard_out" "does not act on it" "real tokens participate"
ok "the real always, may-skip and - tokens are all found to participate"

grammar_case "a second exclusive token is reported" \
  "$real_grammar
token none       exclusive" \
  "exclusive tokens"

grammar_case "a token with an unknown class is reported" \
  "$real_grammar
token weird      nosuchclass" \
  "unknown class"

grammar_case "an area the runner does not offer is reported" \
  "$real_grammar
token rust       area" \
  "no manifest row is tagged with it"

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
a row carrying only a modifier is reported;may-skip  ;cannot stand alone
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

# THE DECLARATION ITSELF. `all` is the runner's DEFAULT argument and is never a
# row tag, so removing it from the grammar breaks a bare `scripts/validate`.
grammar_case "removing the all argument is reported" \
  "$(printf '%s\n' "$real_grammar" | grep -v '^token all ')" \
  "the runner's derivation and the definition have drifted"

grammar_case "an uppercase token is reported" \
  "${real_grammar/token qml        area/token Qml        area}" \
  "not a lowercase token"

grammar_case "a duplicated token is reported" \
  "$real_grammar
token qml        area" \
  "declares a token twice"

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

# prose_areas CANNOT SILENTLY TRUNCATE. The concern was that a period straight
# after the final backtick would end the capture early and drop the last area.
# Probed rather than reasoned about: the optional separator matches empty, so
# the capture ends at the last backtick and the period sits outside it. Pinned
# here so a future regex edit that DID truncate there fails.
#
# A separator the pattern cannot follow (`;`, `/`) DOES truncate — and that is
# loud, not silent: a short capture makes the guard report the missing areas.
# The second case pins that fail-closed direction, which is the property that
# matters; a truncated capture can never equal the full set, so it can never
# agree by accident.
areas_probe="$tmp/areas-probe.md"
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
printf 'areas `go`, `qml`, `helper`, `packaging`, `docs`, `all`.\n' >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "period after final backtick"
ok "a period straight after the final backtick does not truncate the capture"

# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
printf 'areas `go`; `qml`; `helper`; `packaging`; `docs`; `all`.\n' >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "unfollowable separator" "enumerates the validate areas but omits"
ok "a separator the pattern cannot follow truncates LOUDLY, never silently"

# A bash that cannot be LAUNCHED — present but unreadable, non-executable, or
# failing for any other OSError reason — used to escape as a traceback, because
# only FileNotFoundError was caught. Fail-closed in direction, but the
# diagnostic degraded to noise exactly when someone is debugging it. Same shape
# as the PyYAML import, and pinned the same way.
launch_out="$(python3 - "$repo_root" 2>&1 <<'NOBASH' || true
import importlib.util, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

def boom(*_args, **_kwargs):
    raise PermissionError(13, "Permission denied")

subprocess.run = boom
try:
    mod.manifest_rows(root / "scripts" / "validate")
    print("ACCEPTED")
except mod.ManifestError as error:
    print("MANIFESTERROR", error)
NOBASH
)"
expect_contains "$launch_out" "MANIFESTERROR could not run bash" "bash unlaunchable"
expect_absent "$launch_out" "Traceback" "bash unlaunchable"
expect_absent "$launch_out" "ACCEPTED" "bash unlaunchable"
ok "an unlaunchable bash raises ManifestError, not a traceback"

# A MISSING PREREQUISITE MUST NOT REPLACE A FIXTURE'S VERDICT. The CI parse used
# to raise straight out of main, so on a python3 without PyYAML every fixture
# below reported the prerequisite instead of its own result — ten failures, none
# of them the fixtures' verdicts, one of them a false claim that the real tree
# does not pass. Driven under a PYTHONPATH shim whose `yaml` raises on import,
# which is what an absent or broken PyYAML looks like from here.
# The fixtures that matter here are the ones whose manifest PARSES — the area,
# prose and tag-wiring arms. A fixture with a malformed manifest raises before
# main reaches the CI parse, so it never exercised this at all; picking one of
# those would have been a control that could not fail.
noyaml_probe="$tmp/noyaml-probe"
noyaml_grammar="$tmp/noyaml-grammar.conf"

# The runner fixture: an area that no row carries.
python3 - "$runner" >"$noyaml_probe" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "docs      | scripts/check-doc-growth.py"
assert t.count(old) == 1, "the doc-growth manifest row moved"
print(t.replace(old, "-         | scripts/check-doc-growth.py"), end="")
MUT
chmod +x "$noyaml_probe"
run_guard "RUNNER_PATH=$noyaml_probe" "PYTHONPATH=$noyaml_path"
expect_refused "no-PyYAML fixture verdict" "no manifest row is tagged with it"
expect_contains "$guard_out" "CI coverage was NOT checked" "no-PyYAML fixture verdict"
expect_absent "$guard_out" "Traceback" "no-PyYAML fixture verdict"

# The grammar fixture: a declared token nothing acts on.
printf '%s\ntoken nightly    modifier\n' "$real_grammar" >"$noyaml_grammar"
run_guard "GRAMMAR_PATH=$noyaml_grammar" "PYTHONPATH=$noyaml_path"
expect_refused "no-PyYAML fixture verdict" "does not act on it"
expect_contains "$guard_out" "CI coverage was NOT checked" "no-PyYAML fixture verdict"
expect_absent "$guard_out" "Traceback" "no-PyYAML fixture verdict"
ok "without PyYAML a fixture still reports its own verdict, and the prerequisite is named too"

# SHARED DIAGNOSTIC TEXT COMES FROM THE GRAMMAR, in both readers. Asserted
# against the DEFINITION, never against each other: two readers compared only to
# one another can drift together and still agree. The lone-modifier text drifted
# twice and was hand-synchronised twice before the text moved into the grammar.
drift_probe="$fixture_dir/scripts/drift-probe"
mkdir -p "$fixture_dir/scripts/lib"
cp "$repo_root/scripts/lib/validation-grammar.conf" "$fixture_dir/scripts/lib/"
while IFS=';' read -r key row; do
  [[ -n "$key" ]] || continue
  text="$(sed -n "s/^message  *$key  *//p" "$repo_root/scripts/lib/validation-grammar.conf")"
  if [[ -z "$text" ]]; then
    fail "shared diagnostics" "the grammar declares no message for \`$key\`"
    continue
  fi
  ROW="$row" python3 - "$runner" >"$drift_probe" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "qml       | scripts/check-naming.sh"
assert t.count(old) == 1, "the naming-check manifest row moved"
print(t.replace(old, os.environ["ROW"]), end="")
MUT
  chmod +x "$drift_probe"
  runner_said="$("$drift_probe" --list docs 2>&1 >/dev/null || true)"
  library_said="$(GRAMMAR_PROBE="$drift_probe" python3 - "$repo_root" <<'LIB'
import importlib.util, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    mod.manifest_rows(pathlib.Path(os.environ["GRAMMAR_PROBE"]))
    print("ACCEPTED")
except mod.ManifestError as error:
    print(error)
LIB
)"
  expect_contains "$runner_said" "$text" "shared diagnostic $key (runner)"
  expect_contains "$library_said" "$text" "shared diagnostic $key (library)"
done <<'SHAPES'
row-no-separator;scripts/check-naming.sh
row-empty-tags;          | scripts/check-naming.sh
row-malformed-tags;notatoken | scripts/check-naming.sh
row-not-standalone;may-skip  | scripts/check-naming.sh
row-empty-command;qml       |
row-bad-syntax;qml       | scripts/check-naming.sh &&
SHAPES
ok "both readers word every shared diagnostic exactly as the grammar does"

# The success line reports what was PARSED, not a recomputed number. report()
# used to call manifest_rows again, re-running `bash -n` over every command on
# a clean run and leaving a reporting function that could fail.
# Only a CLEAN run prints a success line, so without PyYAML there is no count to
# check — the guard correctly fails on the missing prerequisite instead.
if [[ $have_yaml -eq 1 ]]; then
  run_guard
  parsed_count="$("$runner" --list all | grep -c .)"
  expect_contains "$guard_out" "$parsed_count documented commands" "documented count"
  ok "the success line's count matches the rows actually parsed"
else
  ok "documented-count case skipped: no PyYAML, so the guard prints no success line"
fi

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
expect_clean_run "unmutated control"
ok "the unmutated runner triggers none of its arms"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-validation-inventory: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-validation-inventory: all checks passed"
