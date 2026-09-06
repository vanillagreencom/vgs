#!/usr/bin/env bash
# Drive inventory-guard refusal paths with mutated runner, grammar, document, and CI fixtures.
# Require each case's own diagnostic and failing status; keep an unmutated acceptance control.
# Unchanged path constants still point at the real repository.
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
# Uncreatable controls return skip status instead of passing. This suite's exclusive manifest row
# does not permit skips, so the runner reports that status as failure. A libc without a locale
# that exposes Unicode whitespace classification can leave the locale control uncreatable.
skips=0
skipped_names=()
skip() { # Report an uncreatable control by name and reason. Missing arguments are a fixture defect
# and must fail rather than crash during the reporting path or excuse themselves as a skip.
  if [[ $# -lt 2 ]]; then
    fail "skip helper" "skip was called with no reason for \`${1:-<no control name>}\`, so nothing could be reported about it"
    return 0
  fi
  local name="$1"
  shift
  skips=$((skips + 1))
  skipped_names+=("$name")
  printf '  SKIP  %s: %s\n' "$name" "$1" >&2
  shift
  printf '        %s\n' "$@" >&2
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

# Exercise malformed reporting in a subshell so its intended failure does not contaminate the suite count.
skip_arity_said="$( (skip "a control with no reason") 2>&1 )" || true
expect_contains "$skip_arity_said" "skip was called with no reason" "skip helper arity"
case_failed=0
ok "a skip call with no reason is reported as a malformed call, not a dead run"

# Derive shared diagnostics from the grammar and verify guard-only messages remain present.
# Use the same fragments for clean-run exclusions and fixture-specific failure checks.
ARM_MESSAGES=()
while IFS= read -r text; do
  [[ -n "$text" ]] && ARM_MESSAGES+=("$text")
done < <(sed -n 's/^message  *[a-z-]*  *//p' "$repo_root/scripts/lib/validation-grammar.conf")

# Guard-only diagnostics are checked against their emitting source below.
GUARD_ONLY_MESSAGES=(
  "no manifest row is tagged with it"
  "is not executable"
  "enumerates the validate areas but omits"
  "as a validate area, but scripts/validate does not"
  "anchor around its validate area list"
  "but only inside a code fence"
  "a code fence is opened and never closed"
  "opens the validate area anchor but never closes it"
  "a reversed pair anchors nothing"
  "must be anchored exactly once"
  "anchors an empty validate area list"
  "could not read"
  "does not act on it"
  "the runner's derivation and the definition have drifted"
  "CI coverage was NOT checked"
  "which .github/workflows/ci.yml does not"
)
ARM_MESSAGES+=("${GUARD_ONLY_MESSAGES[@]}")

# Require a consumer for each shared diagnostic key so an unused declaration cannot count as coverage.
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  if ! grep -qF -- "$key" "$repo_root/scripts/validate" \
    && ! grep -qF -- "$key" "$repo_root/scripts/lib/validation_manifest.py"; then
    fail "shared diagnostics" "the grammar declares message \`$key\` that neither reader uses"
  fi
done < <(sed -n 's/^message  *\([a-z-]*\) .*/\1/p' "$repo_root/scripts/lib/validation-grammar.conf")

# Join adjacent literals before checking diagnostic text; emitted f-strings can span source literals.
if ! python3 - "$repo_root" "${GUARD_ONLY_MESSAGES[@]}" <<'LIVE'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
sources = ""
for name in ("scripts/check-validation-inventory.py", "scripts/lib/validation_manifest.py"):
    sources += (root / name).read_text(encoding="utf-8")

joined = re.sub(r'"\s*f?"', "", sources)
dead = [f for f in sys.argv[2:] if f not in joined]
for fragment in dead:
    print(f"no reader emits {fragment!r}, so asserting its absence proves nothing")
sys.exit(1 if dead else 0)
LIVE
then
  fail "guard-only diagnostics" "the fragments above are not emitted by either reader"
fi
ok "every fragment the unmutated control asserts is one some arm can emit"

# Detect PyYAML availability because only CI parsing needs it. Other guard arms must still report.
have_yaml=1
python3 -c 'import yaml' >/dev/null 2>&1 || have_yaml=0

noyaml_path="$tmp/noyaml"
mkdir -p "$noyaml_path/yaml"
printf 'raise ImportError("no yaml (test shim)")\n' >"$noyaml_path/yaml/__init__.py"

# A clean non-YAML result can still carry the sole missing-PyYAML prerequisite error.
expect_clean_run() {
  local name="$1" msg
  for msg in "${ARM_MESSAGES[@]}"; do

    [[ "$msg" == "CI coverage was NOT checked" ]] && continue
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

# Run the guard with patched fixture paths and retain output plus exit status.
# Grammar fixtures live beside a copied runner because the guard consumes the runner's dump.
# Set guard_out and guard_rc; accepted path overrides identify runner, docs, CI, grammar, or imports.
run_guard() {
  local arg grammar_override="" runner_override=""
  local -a env_args=()
  for arg in "$@"; do
    case "$arg" in
      GRAMMAR_PATH=*) grammar_override="${arg#GRAMMAR_PATH=}" ;;
      RUNNER_PATH=*) runner_override="${arg#RUNNER_PATH=}" ;;
      *) env_args+=("$arg") ;;
    esac
  done
  # Keep an already complete fixture layout in place so paths containing spaces stay under test.
  if [[ -z "$grammar_override" && -n "$runner_override" ]] &&
    [[ -r "$(dirname -- "$runner_override")/lib/validation-grammar.conf" ]]; then
    env_args+=("RUNNER_PATH=$runner_override")
  elif [[ -n "$grammar_override" || -n "$runner_override" ]]; then
    rm -rf "$tmp/paired"
    mkdir -p "$tmp/paired/scripts/lib"
    # Preserve copied mode so the non-executable-runner control remains non-executable.
    cp "${runner_override:-$runner}" "$tmp/paired/scripts/validate"
    cp "${grammar_override:-$repo_root/scripts/lib/validation-grammar.conf}" \
      "$tmp/paired/scripts/lib/validation-grammar.conf"
    env_args+=("RUNNER_PATH=$tmp/paired/scripts/validate")
  fi
  guard_rc=0
  guard_out="$(env "${env_args[@]}" python3 - "$repo_root" <<'GUARD_PY'
import contextlib, importlib.util, io, os, pathlib, sys
spec = importlib.util.spec_from_file_location(
    "inv", pathlib.Path(sys.argv[1]) / "scripts" / "check-validation-inventory.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for var, attr in (
    ("RUNNER_PATH", "RUNNER"),
    ("AGENTS_PATH", "AGENTS"),
    ("CI_PATH", "CI"),
):
    if os.environ.get(var):
        setattr(mod, attr, pathlib.Path(os.environ[var]))
# Refresh document paths captured by the module during import.
mod.AREA_ENUMERATING_DOCS = (mod.AGENTS,)
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
    # Capture a string SystemExit code here; forwarding it to sys.exit would print outside this capture.
    status = exc.code if isinstance(exc.code, int) else 1
print(buf.getvalue())
sys.exit(status if isinstance(status, int) else 1)
GUARD_PY
  )" || guard_rc=$?
}

# Require both the expected diagnosis and a nonzero refusal status.
expect_refused() {
  expect_contains "$guard_out" "$2" "$1"
  [[ "$guard_rc" -ne 0 ]] || fail "$1" "guard printed the message but exited 0 — it diagnosed without refusing"
}

# Build a grammar fixture beside its runner and require the expected refusal.
grammar_case() {
  local name="$1" probe="$tmp/probe-grammar.conf"
  printf '%s' "$2" >"$probe"
  run_guard "GRAMMAR_PATH=$probe"
  expect_refused "$name" "$3"
  ok "$name"
}

guard_case() {

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

# Require a later arm's message as well so an earlier parser exception cannot hide aggregation failure.
expect_contains "$guard_out" "the per-area and CI-coverage arms did NOT run" \
  "missing MANIFEST_EOF heredoc is reported"
ok "a runner with no manifest delimiter still reports every arm, not just the first raise"

# Call each delimiter reader directly. One sibling's refusal cannot prove the others reject the same input.
heredoc_said="$(python3 - "$repo_root" "$tmp" <<'HEREDOC' 2>&1 || true
import importlib.util, pathlib, sys
root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
runner = root / "scripts" / "validate"
# Use the real grammar so a malformed manifest delimiter fails for its own cause.
rules = mod.grammar(runner)
mangled = tmp / "no-heredoc-runner"
mangled.write_text(
    runner.read_text(encoding="utf-8").replace("MANIFEST_EOF", "MANIFEST_END"),
    encoding="utf-8",
)
mangled.chmod(0o755)
work = tmp / "no-heredoc-work"
for label, call in (
    ("LOGIC", lambda: mod.runner_logic(mangled)),
    ("BUILD", lambda: mod.token_participates(mangled, rules, "always", work)),
):
    try:
        call()
        print(f"{label} ACCEPTED")
    except mod.ManifestError as error:
        print(f"{label} {error}")
HEREDOC
)"
for label in LOGIC BUILD; do
  expect_contains "$heredoc_said" "$label scripts/validate has no MANIFEST_EOF heredoc" \
    "heredoc miss is refused"
done
expect_absent "$heredoc_said" "ACCEPTED" "heredoc miss is refused"
expect_absent "$heredoc_said" "Traceback" "heredoc miss is refused"
ok "a runner whose manifest delimiter is renamed is refused by runner_logic and by the probe builder"

# Inject each expected exception class into the probe call to test aggregation independently
# of the filesystem or output condition that produced it.
for etype in OSError UnicodeDecodeError ManifestError; do
  raised_said="$(ETYPE="$etype" python3 - "$repo_root" <<'RAISED' 2>&1 || true
import contextlib, importlib.util, io, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "inv", root / "scripts" / "check-validation-inventory.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
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

# Real tokens must still participate; blanket refusal cannot pass.
run_guard
expect_absent "$guard_out" "does not act on it" "real tokens participate"
ok "every token the real grammar declares is found to participate"

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


  cp "$runner" "$fixture_dir/scripts/validate" 2>/dev/null || {
    mkdir -p "$fixture_dir/scripts/lib"; cp "$runner" "$fixture_dir/scripts/validate"
  }
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

# Locate document areas by markers, independent of surrounding phrasing.
# Missing markers must refuse while a reworded valid region still parses.
anchored="$tmp/anchored-agents.md"
python3 - "$repo_root/AGENTS.md" >"$anchored" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("<!-- validate-areas -->", "").replace("<!-- /validate-areas -->", ""), end="")
MUT
run_guard "AGENTS_PATH=$anchored"
expect_refused "anchor removed" "anchor around its validate area list"
ok "a document whose area anchor is gone is reported, not skipped"

python3 - "$repo_root/AGENTS.md" >"$anchored" <<'MUT'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
new = re.sub(
    r"<!-- validate-areas -->.*?<!-- /validate-areas -->",
    "<!-- validate-areas -->one area per run, spelled `go` / `qml` / `helper` / "
    "`packaging` / `docs`; or `all`<!-- /validate-areas -->",
    t,
    flags=re.DOTALL,
)
assert new != t, "the anchored region was not found"
print(new, end="")
MUT
run_guard "AGENTS_PATH=$anchored"
expect_clean_run "reworded inside the anchor"
ok "prose reworded inside the anchor still reads, so the wording coupling is gone"

# A shortened anchored list must fail so a parser that reads nothing cannot pass.
python3 - "$repo_root/AGENTS.md" >"$anchored" <<'MUT'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
new = re.sub(
    r"<!-- validate-areas -->.*?<!-- /validate-areas -->",
    "<!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `all`"
    "<!-- /validate-areas -->",
    t,
    flags=re.DOTALL,
)
assert new != t, "the anchored region was not found"
print(new, end="")
MUT
run_guard "AGENTS_PATH=$anchored"
expect_refused "short list inside the anchor" "enumerates the validate areas but omits"
ok "an area missing from inside the anchor is still reported"


python3 - "$repo_root/AGENTS.md" >"$anchored" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t.replace("<!-- /validate-areas -->", ""), end="")
MUT
run_guard "AGENTS_PATH=$anchored"
expect_refused "unterminated anchor" "but never closes it"
ok "an anchor that is opened and never closed is reported"

python3 - "$repo_root/AGENTS.md" >"$anchored" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
print(t + "\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n", end="")
MUT
run_guard "AGENTS_PATH=$anchored"
expect_refused "two anchors" "must be anchored exactly once"
ok "a second anchored region is reported rather than silently ignored"

# Count closing markers too; an extra closer can leave an ignored region.
python3 - "$repo_root/AGENTS.md" >"$anchored" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
assert t.count("<!-- /validate-areas -->") == 1, "AGENTS.md no longer closes the anchor once"
print(t + "\nstray `docs-only`<!-- /validate-areas -->\n", end="")
MUT
run_guard "AGENTS_PATH=$anchored"
expect_refused "two closing markers" "must be anchored exactly once"
ok "a second closing marker is reported, not read as a wider region"

# Unexpected backticked names within the anchor must fail instead of widening the area vocabulary.
python3 - "$repo_root/AGENTS.md" >"$anchored" <<'MUT'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
new = re.sub(
    r"<!-- validate-areas -->.*?<!-- /validate-areas -->",
    "<!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `docs`, "
    "`docs-only`, `all`<!-- /validate-areas -->",
    t,
    flags=re.DOTALL,
)
assert new != t, "the anchored region was not found"
print(new, end="")
MUT
run_guard "AGENTS_PATH=$anchored"
expect_refused "extra area in the anchor" "as a validate area, but scripts/validate does not"
ok "a token inside the anchor that the runner does not accept is reported"

# A present but empty anchor is distinct from a missing anchor.
# shellcheck disable=SC2016  # the fixture prose is deliberately backtick-free
printf 'see the runner for the areas <!-- validate-areas -->run it for what you touched<!-- /validate-areas -->\n' >"$anchored"
run_guard "AGENTS_PATH=$anchored"
expect_refused "empty anchored region" "anchors an empty validate area list"
ok "an anchor holding prose but no area names is reported"

# Fenced markers illustrate the contract and cannot define the live document area list.
areas_probe="$tmp/areas-probe.md"
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'the guard reads markers like this:\n\n'
  printf '```markdown\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "fenced marker" "but only inside a code fence"
# A fenced-marker diagnosis must name fencing, not ask for a marker already present.
expect_absent "$guard_out" "Restore the anchor" "fenced marker"
ok "a marker inside a code fence is reported as fenced, not as missing"

# Apply fenced-marker diagnostics to closers as well as openers.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`\n\n'
  printf '```markdown\n<!-- /validate-areas -->\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "fenced closing marker" "but only inside a code fence"
expect_absent "$guard_out" "never closes it" "fenced closing marker"
ok "a closing marker inside a code fence is reported as fenced, not as never closed"

# Markers present once each can still occur in reverse order.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
printf '<!-- /validate-areas -->areas <!-- validate-areas -->`go`\n' >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "reversed anchor pair" "a reversed pair anchors nothing"
expect_absent "$guard_out" "never closes it" "reversed anchor pair"
ok "a closing marker that precedes the opening one is reported as reversed, not as never closed"

# Accept a live anchor beside its fenced illustration.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '```markdown\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "real anchor beside a fenced one"
ok "a document may show the markers in a fence and still carry a real anchor"

# An unclosed longer fence can swap which area list the reader sees.
# Keep the illustration complete so naive parsing would pass on the wrong region.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf '````bash\n'
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '```markdown\n<!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "unclosed fence swallowing the anchor" "a code fence is opened and never closed"
ok "a stray fence that relocates the read region is refused, not answered from the picture"

# With no markers in the swallowed example, report the unclosed fence rather than a missing anchor.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf '````bash\n'
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '```sh\nan ordinary illustration\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "unclosed fence above the anchor" "a code fence is opened and never closed"
expect_absent "$guard_out" "anchor around its validate area list" "unclosed fence above the anchor"
ok "an unclosed fence is named as the defect, not reported as a missing anchor"

# Balanced fenced documents must still parse so blanket rejection cannot pass.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '```sh\nfirst\n```\n\n```markdown\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n```\n\n```sh\nthird\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "balanced fences"
ok "a page with several balanced fences still parses"

# Text after a fence run prevents it from closing. A length-only reader can expose
# a fenced example as the live contract.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf '```markdown\nan illustration\n``` not-a-closing-fence\n'
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "info string on a closing fence" "a code fence is opened and never closed"
ok "a fence is not closed by a run carrying an info string, so the text below it stays fenced"

# Permit whitespace after a closing run so valid trailing spaces do not cause refusal.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '```sh\nfirst\n```  \t\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "closing fence with trailing whitespace"
ok "spaces and tabs after a closing run still close the fence"

# Use CRLF throughout the fixture. The shared whitespace set must handle carriage returns
# without treating every closing fence as content.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\r\n\r\n'
  printf '```markdown\r\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\r\n```\r\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "CRLF checkout"
ok "a CRLF page whose fences are balanced parses, because the permitted set is the runner's"

# A backtick in a backtick fence info string prevents opening. Keep both interpretations
# balanced but give their live lists different contents so the rule decides the result.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf '````markdown with a `tick` in the info string\n'
  printf '<!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `all`<!-- /validate-areas -->\n'
  printf '````\n'
  printf '<!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n'
  printf '````markdown with a `tick` in the info string\n'
  printf '````\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
# shellcheck disable=SC2016  # the backticks quote an area name in the guard's own message
expect_refused "backtick in an opening info string" 'omits `docs`'
expect_absent "$guard_out" "never closed" "backtick in an opening info string"
ok "a run whose info string carries a backtick is prose, so the list it appears to fence stays live"

# The area parser recognizes only unindented backtick fences. Markers inside
# an indented example still count and must cause a duplicate-anchor refusal.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf -- '- demonstrated under a bullet:\n\n  ```markdown\n  <!-- validate-areas -->areas `go`<!-- /validate-areas -->\n  ```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "indented fence" "must be anchored exactly once"
ok "an indented fence does not hide its markers, exactly as the contract states"

# Indented fences are outside this parser's recognized fence syntax and must not open an unmatched block.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf -- '- a lone fence marker quoted in prose:\n\n  ```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "indented fence never opens a block"
ok "an indented fence neither opens nor closes a block, so it cannot move the region"

# Pair fences by run length. Shorter nested examples cannot close a longer outer fence
# and expose their markers as the live contract.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'how to write the anchor:\n\n'
  printf '````markdown\n```md\n<!-- validate-areas -->areas `bogus-area`<!-- /validate-areas -->\n```\n````\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "nested fenced marker" "but only inside a code fence"
expect_absent "$guard_out" "bogus-area" "nested fenced marker"
ok "a marker nested two fences deep is a picture, not the contract"

# A live anchor beside a nested fenced example must still pass.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '````markdown\n```md\n<!-- validate-areas -->areas `bogus-area`<!-- /validate-areas -->\n```\n````\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "nested fence beside a real anchor"
ok "a page may nest a fenced illustration and still carry a real anchor"

# Require actual documents to yield lists so wording controls cannot pass on an empty extraction.
python3 - "$repo_root" <<'PROBE' || fail "enumerating docs" "a named document yields no area list today"
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "inv", root / "scripts" / "check-validation-inventory.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
rules = mod.grammar(root / "scripts" / "validate")
for doc in mod.AREA_ENUMERATING_DOCS:
    stated = mod.prose_areas(doc, rules)
    assert stated, doc
    print(f"  ok    {doc.name} states {len(stated)} areas")
PROBE
ok "every named document states its area list today"

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

# Stub corrupt runner dumps to test the decoder's own refusal. A runner bug can emit data
# that normal grammar fixtures never produce. Require a dump-specific collected diagnostic.
dump_stub="$tmp/dump-stub/scripts/validate"
mkdir -p "$tmp/dump-stub/scripts/lib"
cp "$repo_root/scripts/lib/validation-grammar.conf" "$tmp/dump-stub/scripts/lib/"
good_dump="$("$runner" --dump-grammar)"
while IFS=';' read -r label from to; do
  [[ -n "$label" ]] || continue
  if [[ "$to" == "APPEND" ]]; then
    corrupt="$good_dump
$from"
  else
    corrupt="${good_dump/$from/$to}"
    [[ "$corrupt" != "$good_dump" ]] ||
      fail "$label" "the dump mutation did not apply, so the case cannot fail"
  fi
  printf '#!/usr/bin/env bash\ncat <<%s\n%s\nDUMP_EOF\n' "'DUMP_EOF'" "$corrupt" >"$dump_stub"
  chmod +x "$dump_stub"
  run_guard "RUNNER_PATH=$dump_stub"
  expect_refused "$label" "defect in the runner's dump"
  expect_absent "$guard_out" "Traceback" "$label"
  ok "$label"
done <<'DUMPS'
a non-integer count in the dump is refused;skips=no min=1 max=-;skips=no min=banana max=-
a dash min in the dump is refused;skips=no min=1 max=-;skips=no min=- max=-
a non-canonical count in the dump is refused;skips=no min=1 max=-;skips=no min=08 max=-
an unknown class field in the dump is refused;skips=no min=1;skips=no bogus=yes min=1
a non-boolean class field in the dump is refused;class area selects=yes;class area selects=maybe
a missing class field in the dump is refused;universal=no skips=no min=1 max=-;universal=no min=1 max=-
a repeated class field in the dump is refused;class area selects=yes;class area selects=yes selects=no
a malformed token line in the dump is refused;token go area;token go area extra
a duplicated token in the dump is refused;token qml area;APPEND
a message with no text in the dump is refused;message grammar-arity grammar line has the wrong number of fields;message grammar-arity
a second default in the dump is refused;default qml;APPEND
an unknown dump line kind is refused;bogus line;APPEND
a non-hex whitespace codepoint is refused;whitespace 20 09;whitespace 20 tab
an odd-length whitespace codepoint is refused;whitespace 20 09;whitespace 20 9
an uppercase whitespace codepoint is refused;whitespace 20 09;whitespace 20 0A
a non-ASCII whitespace codepoint is refused;whitespace 20 09;whitespace 20 a0
a repeated whitespace codepoint is refused;whitespace 20 09;whitespace 20 20
a second whitespace line is refused;whitespace 20 09 0a 0d 0c 0b;APPEND
DUMPS

# Test missing required dump records by removing whole lines.
for required in source default whitespace; do
  printf '#!/usr/bin/env bash\ncat <<%s\n%s\nDUMP_EOF\n' "'DUMP_EOF'" \
    "$(printf '%s\n' "$good_dump" | grep -v "^$required ")" >"$dump_stub"
  chmod +x "$dump_stub"
  run_guard "RUNNER_PATH=$dump_stub"
  expect_refused "missing $required line" "no \`$required\` line"
  expect_absent "$guard_out" "Traceback" "missing $required line"
done
ok "a dump missing a required line is refused, naming the line"

# Compare bare --list with the default resolved by the real dump.
dumped_default="$("$runner" --dump-grammar | sed -n 's/^default //p')"
[[ -n "$dumped_default" ]] || fail "default resolves" "the runner dumped no default area"
if [[ "$("$runner" --list)" != "$("$runner" --list "$dumped_default")" ]]; then
  fail "default resolves" "a bare --list does not match --list $dumped_default"
fi
python3 - "$repo_root" "$dumped_default" <<'DEF' || fail "default resolves" "the decoder disagrees with the dumped default"
import importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
g = mod.grammar(root / "scripts" / "validate")
sys.exit(0 if g.default_area == sys.argv[2] else 1)
DEF
ok "the real grammar resolves one default, and every consumer reads the same one"

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

# Compare decoded valid grammar with the emitted dump so dropped records or invented defaults fail.
run_guard
expect_clean_run "dump is the guard's only source"
python3 - "$repo_root" <<'DUMP' || fail "dump agreement" "the decoded grammar does not match the dump"
import importlib.util, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
runner = root / "scripts" / "validate"
dump = subprocess.run(
    ["bash", str(runner), "--dump-grammar"], capture_output=True, text=True, check=True
).stdout
g = mod.grammar(runner)
whitespace = " ".join(f"{ord(c):02x}" for c in g.whitespace)
lines = [f"source {g.source}", f"default {g.default_area}", f"whitespace {whitespace}"]
for name in sorted(g.classes):
    props = " ".join(f"{p}={'yes' if g.classes[name][p] else 'no'}" for p in mod.CLASS_PROPERTIES)
    counts = g.counts[name]
    lines.append(
        f"class {name} {props} min={counts.get('min', 0)} "
        f"max={counts['max'] if 'max' in counts else '-'}"
    )
for token, cls in g.token_class.items():
    lines.append(f"token {token} {cls}")
for key in sorted(g.messages):
    lines.append(f"message {key} {g.messages[key]}")
if "\n".join(lines) + "\n" != dump:
    import difflib
    sys.stdout.writelines(difflib.unified_diff(
        dump.splitlines(True), [line + "\n" for line in lines],
        "dump", "decoded"))
    sys.exit(1)
print(f"  ok    the decoder round-trips all {len(dump.splitlines())} dumped records")
DUMP
ok "the guard's grammar is exactly what the runner dumped, with nothing supplied"

# Simulate absent yaml on import. Non-YAML readers must still work and CI parsing must
# report the prerequisite without a module-import traceback.
pyyaml_out="$(python3 - "$repo_root" "$tmp" 2>&1 <<'NOYAML' || true
import importlib.util, pathlib, shlex, sys
sys.modules["yaml"] = None
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("IMPORTED")
# Keep the real grammar producer, but give the row reader a fixed manifest.
probe = pathlib.Path(sys.argv[2]) / "noyaml-manifest"
probe.write_text(
    "#!/usr/bin/env bash\n"
    f"if [[ ${{1:-}} == --dump-grammar ]]; then exec bash {shlex.quote(str(root / 'scripts' / 'validate'))} --dump-grammar; fi\n"
    "cat <<'MANIFEST_EOF'\nqml | true\nhelper | false\nMANIFEST_EOF\n",
    encoding="utf-8",
)
print("ROWS", mod.manifest_rows(probe))
try:
    mod.ci_run_commands(root / ".github" / "workflows" / "ci.yml")
except mod.ManifestError as error:
    print("MANIFESTERROR", error)
NOYAML
)"
expect_contains "$pyyaml_out" "IMPORTED" "PyYAML absent"
expect_contains "$pyyaml_out" "ROWS [('qml', 'true'), ('helper', 'false')]" "PyYAML absent"
expect_contains "$pyyaml_out" "MANIFESTERROR PyYAML is not installed" "PyYAML absent"
expect_absent "$pyyaml_out" "Traceback" "PyYAML absent"
ok "without PyYAML the module imports, the other parsers work, and ci.yml fails with one line"

# Punctuation and layout inside a valid anchor must not truncate backticked area names.
areas_probe="$tmp/areas-probe.md"
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
printf '<!-- validate-areas -->areas `go`; `qml` / `helper`\n| `packaging` | `docs` | and `all`.<!-- /validate-areas -->\n' >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "punctuation inside the anchor"
ok "separators and line breaks inside the anchor cannot truncate the list"

# Inject launch OSError for both row syntax and grammar dump subprocesses.
# Report the unavailable Bash invocation without an unrelated traceback.
launch_out="$(python3 - "$repo_root" 2>&1 <<'NOBASH' || true
import importlib.util, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
runner = root / "scripts" / "validate"
rules = mod.grammar(runner)  # Collect a real dump before replacing Bash launch behavior.

def boom(*_args, **_kwargs):
    raise PermissionError(13, "Permission denied")

subprocess.run = boom
try:
    mod._check_shell_syntax("true", "qml | true", rules)
    print("ACCEPTED")
except mod.ManifestError as error:
    print("SYNTAX", error)
try:
    mod.grammar(runner)
    print("ACCEPTED")
except mod.ManifestError as error:
    print("DUMP", error)
NOBASH
)"
expect_contains "$launch_out" "SYNTAX could not run bash" "bash unlaunchable"
expect_contains "$launch_out" "DUMP could not run validate --dump-grammar" "bash unlaunchable"
expect_absent "$launch_out" "Traceback" "bash unlaunchable"
expect_absent "$launch_out" "ACCEPTED" "bash unlaunchable"
ok "an unlaunchable bash raises ManifestError at both call sites, not a traceback"

# Mutate the runner whitespace set and require the library to consume that same dumped set.
ws_probe="$tmp/ws-probe/scripts/validate"
mkdir -p "$tmp/ws-probe/scripts/lib"
cp "$repo_root/scripts/lib/validation-grammar.conf" "$tmp/ws-probe/scripts/lib/"
python3 - "$runner" >"$ws_probe" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "ASCII_SPACE=$' \\t\\n\\r\\f\\v'"
assert t.count(old) == 1, "the ASCII_SPACE constant moved"
t = t.replace(old, "ASCII_SPACE=$' \\n\\r\\f\\v'")
# Use the removed whitespace character in a real row. Checking only the dumped set
# cannot detect a reader that applies a separate hardcoded pattern.
row = "qml       | scripts/check-naming.sh"
assert t.count(row) == 1, "the naming-check manifest row moved"
print(t.replace(row, "qml\t      | scripts/check-naming.sh"), end="")
MUT
chmod +x "$ws_probe"
ws_dumped="$("$ws_probe" --dump-grammar | sed -n 's/^whitespace //p')"
[[ "$ws_dumped" == "20 0a 0d 0c 0b" ]] ||
  fail "whitespace is dumped" "the probe dumped \`$ws_dumped\`, so the mutation did not reach the dump"
ws_decoded="$(WS_PROBE="$ws_probe" python3 - "$repo_root" <<'LIB'
import importlib.util, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
g = mod.grammar(pathlib.Path(os.environ["WS_PROBE"]))
print(" ".join(f"{ord(c):02x}" for c in g.whitespace))
LIB
)" || true
[[ "$ws_decoded" == "$ws_dumped" ]] ||
  fail "whitespace is read" "the library decoded \`$ws_decoded\` where the runner dumped \`$ws_dumped\`"

# Compare each reader's actual row outcome, not only the decoded whitespace value.
ws_rc=0
LC_ALL=C "$ws_probe" --list docs >/dev/null 2>"$tmp/stderr" || ws_rc=$?
ws_runner_said="$(LC_ALL=C sed -e 's/^scripts\/validate: //' -e 's/`.*//' \
  -e 's/[ \t]*$//' "$tmp/stderr" | head -1)"
[[ "$ws_rc" != 0 ]] || ws_runner_said="ACCEPTED"
# Capture unexpected module failures for later diagnostic assertions instead of aborting the suite under errexit.
ws_library_said="$(WS_PROBE="$ws_probe" python3 - "$repo_root" <<'LIB'
import importlib.util, os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    mod.manifest_rows(pathlib.Path(os.environ["WS_PROBE"]))
    print("ACCEPTED")
except mod.ManifestError as error:
    print(re.sub(r"`.*", "", str(error).replace("scripts/validate: ", "")).strip())
LIB
)" || true
[[ "$ws_runner_said" == "$ws_library_said" ]] ||
  fail "whitespace is applied" "a tag field carrying the dropped character is classified differently:
  runner : ${ws_runner_said:-accepted}
  library: ${ws_library_said:-accepted}"
expect_contains "$ws_library_said" "malformed tag field" "whitespace is applied"
ok "the whitespace set travels from the runner's constant to the pattern each reader applies"

# A CRLF runner must still expose its manifest delimiter. Use a manifest-only row
# to make an unstripped result unambiguous.
crlf_said="$(python3 - "$repo_root" "$tmp" <<'CRLF' 2>&1 || true
import importlib.util, pathlib, sys
root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
runner = root / "scripts" / "validate"
crlf = tmp / "validate-crlf"
crlf.write_bytes(runner.read_bytes().replace(b"\n", b"\r\n"))
row = "scripts/test-owned-skills-e2e.py"
assert row in runner.read_text(encoding="utf-8"), "the owned-skills-e2e manifest row moved"
try:
    logic = mod.runner_logic(crlf)
except mod.ManifestError as error:
    # A delimiter refusal must remain a named result so the assertion can reject it without a traceback.
    print(f"REFUSED {error}")
else:
    print("STRIPPED" if row not in logic and "MANIFEST_EOF" not in logic else "SURVIVED")
CRLF
)"
expect_contains "$crlf_said" "STRIPPED" "CRLF manifest heredoc"
ok "a CRLF-lined runner's manifest is still stripped from the logic the tag check scans"

# Substitute directories for files to force OSError and require named read diagnostics.
unreadable_out="$(python3 - "$repo_root" "$tmp" 2>&1 <<'UNREADABLE' || true
import importlib.util, pathlib, sys
root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
nowhere = tmp / "a-directory-where-a-file-should-be"
nowhere.mkdir(exist_ok=True)
runner = root / "scripts" / "validate"


def participate():
    # Point the decoded source at the unreadable grammar so this reaches file copying,
    # not merely dump decoding.
    rules = mod.grammar(runner)
    rules.source = nowhere
    return mod.token_participates(runner, rules, "always", tmp / "participate-work")


for label, call in (
    ("ROWS", lambda: mod.manifest_rows(nowhere)),
    ("PROSE", lambda: mod.prose_areas(nowhere, mod.grammar(runner))),
    ("LOGIC", lambda: mod.runner_logic(nowhere)),
    ("CI", lambda: mod.ci_run_commands(nowhere)),
    ("PARTICIPATE", participate),
):
    try:
        call()
        print(f"{label} ACCEPTED")
    except mod.ManifestError as error:
        print(f"{label} {error}")
UNREADABLE
)"
for label in ROWS PROSE LOGIC PARTICIPATE; do
  expect_contains "$unreadable_out" "$label could not read" "unreadable surface"
done
if [[ $have_yaml -eq 1 ]]; then
  expect_contains "$unreadable_out" "CI could not read" "unreadable surface"
else
  # Without PyYAML, CI parsing stops before file reading; assert that prerequisite instead.
  expect_contains "$unreadable_out" "CI PyYAML is not installed" "unreadable surface"
fi
expect_absent "$unreadable_out" "Traceback" "unreadable surface"
expect_absent "$unreadable_out" "ACCEPTED" "unreadable surface"
ok "an unreadable surface raises ManifestError naming the path, not a traceback"

# Inspect syntax for file reads outside the shared diagnostic helper.
# This covers added call sites without treating comments or docstrings as executable reads.
one_reader_scan() { # Report file reads outside the designated helper in the supplied module.
  python3 - "$1" <<'READS'
import ast, pathlib, sys
module = pathlib.Path(sys.argv[1])
source = module.read_text(encoding="utf-8")
try:
    tree = ast.parse(source)
except SyntaxError as exc:
    print(f"{module.name} does not parse, so the one-reader rule cannot be checked: {exc}")
    sys.exit(1)
readers = [
    node for node in ast.walk(tree)
    if isinstance(node, ast.FunctionDef) and node.name == "_read"
]
if len(readers) != 1:
    print(f"{module.name} declares {len(readers)} `_read` helpers, so the "
          f"one-reader rule cannot be checked")
    sys.exit(1)
low, high = readers[0].lineno, readers[0].end_lineno
READ_VERBS = {"open", "read_text", "read_bytes", "readlines", "readline"}
lines = source.split("\n")
stray = []
for node in ast.walk(tree):
    if not isinstance(node, ast.Call):
        continue
    func = node.func
    if isinstance(func, ast.Name):
        name = func.id
    elif isinstance(func, ast.Attribute):
        name = func.attr
    else:
        continue
    if name in READ_VERBS and not (low <= node.lineno <= high):
        stray.append((node.lineno, lines[node.lineno - 1].strip()))
for number, line in sorted(set(stray)):
    print(f"{module.name}:{number} reads a file outside _read(): {line}")
sys.exit(1 if stray else 0)
READS
}

if ! one_reader_scan "$repo_root/scripts/lib/validation_manifest.py"; then
  fail "one reader per file" "the reads above bypass _read(), so they raise tracebacks instead of diagnostics"
fi
ok "every file read in the module goes through the helper that diagnoses failure"

# Use altered module copies to verify the read scanner rejects bypasses.
reads_probe="$tmp/reads-probe.py"
while IFS= read -r planted; do
  [[ -n "$planted" ]] || continue
  {
    cat "$repo_root/scripts/lib/validation_manifest.py"
    printf '\n\ndef _planted(p):\n    %s\n' "$planted"
  } >"$reads_probe"
  if scan_out="$(one_reader_scan "$reads_probe")"; then
    fail "one-reader scan control" "a planted \`$planted\` outside _read() was NOT reported"
  else
    expect_contains "$scan_out" "reads a file outside _read()" "one-reader scan control"
  fi
done <<'PLANTED'
return p.read_text(encoding="utf-8")
return p.read_bytes()
return open(p, encoding="utf-8").read()
return p.open(encoding="utf-8").readlines()
PLANTED
ok "every read spelling planted outside _read() is reported by the scan"

# Comments and docstrings mentioning read methods must remain accepted.
while IFS= read -r prose; do
  [[ -n "$prose" ]] || continue
  {
    cat "$repo_root/scripts/lib/validation_manifest.py"
    printf '\n\n%b\n' "$prose"
  } >"$reads_probe"
  one_reader_scan "$reads_probe" >/dev/null ||
    fail "one-reader scan control" "prose naming a read was reported as a read: $prose"
done <<'PROSE'
# Prose about the rule: nothing may call path.read_text( or open( here.
def _documented(p):\n    """Nothing here may call p.read_text( or open( directly."""\n    return p
PROSE
ok "a comment or docstring naming a read is prose, not a breach of the one-reader rule"

# Missing PyYAML must not replace another fixture's diagnostic. Use parseable manifest fixtures
# so execution reaches both the intended guard arm and the CI prerequisite.
noyaml_probe="$tmp/noyaml-probe"
noyaml_grammar="$tmp/noyaml-grammar.conf"

# Remove and verify every docs row so new rows cannot preserve the supposedly empty area.
python3 - "$runner" >"$noyaml_probe" <<'MUT'
import re
import sys
t = open(sys.argv[1], encoding="utf-8").read()
out = t.replace("docs      | ", "-         | ")
assert out != t, "no docs-tagged manifest row found; the tag column moved"
assert not re.search(r"^docs\s*\|", out, re.M), "a docs-tagged row survived, so the area is not empty"
print(out, end="")
MUT
chmod +x "$noyaml_probe"
run_guard "RUNNER_PATH=$noyaml_probe" "PYTHONPATH=$noyaml_path"
expect_refused "no-PyYAML fixture verdict" "no manifest row is tagged with it"
expect_contains "$guard_out" "CI coverage was NOT checked" "no-PyYAML fixture verdict"
expect_absent "$guard_out" "Traceback" "no-PyYAML fixture verdict"


printf '%s\ntoken nightly    inert\n' "${real_grammar/class argument   /$INERT_CLASS
class argument   }" >"$noyaml_grammar"
run_guard "GRAMMAR_PATH=$noyaml_grammar" "PYTHONPATH=$noyaml_path"
expect_refused "no-PyYAML fixture verdict" "does not act on it"
expect_contains "$guard_out" "CI coverage was NOT checked" "no-PyYAML fixture verdict"
expect_absent "$guard_out" "Traceback" "no-PyYAML fixture verdict"
ok "without PyYAML a fixture still reports its own verdict, and the prerequisite is named too"

# Require shared diagnostics to match the definition, not merely another reader that can drift with them.
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

# Success reporting must reuse parsed results. With missing PyYAML no clean run exists,
# so that reporting control is uncreatable and must be recorded as skipped.
if [[ $have_yaml -eq 1 ]]; then
  run_guard
  parsed_count="$("$runner" --list all | grep -c .)"
  expect_contains "$guard_out" "$parsed_count documented commands" "documented count"
  ok "the success line's count matches the rows actually parsed"
else
  skip "documented-count control" \
    "PyYAML is absent, so the guard fails on that prerequisite and prints no" \
    "success line at all. The count this control compares against is never" \
    "produced, and no other case checks it, so it was NOT exercised here."
fi

# Compare reader diagnostics on duplicate tags. Membership can use a set, but cardinality
# must retain repetitions where they affect the diagnosis.
agree_probe="$fixture_dir/scripts/agree-probe"
# Use a function entrypoint for control-character rows that cannot be represented by a quoted fixture table.
agree_row() {
  local row_tags="$1" label="${2:-$1}"
  ROW="$row_tags" python3 - "$runner" >"$agree_probe" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "qml       | scripts/check-naming.sh"
assert t.count(old) == 1, "the naming-check manifest row moved"
print(t.replace(old, f"{os.environ['ROW']} | scripts/check-naming.sh"), end="")
MUT
  chmod +x "$agree_probe"
  local runner_rc=0 runner_said library_said library_rc=0
  "$agree_probe" --list docs >/dev/null 2>"$tmp/stderr" || runner_rc=$?
  # Normalize trailing diagnostic whitespace consistently before comparing readers.
  runner_said="$(sed -e 's/^scripts\/validate: //' -e 's/`.*//' -e 's/[[:space:]]*$//' "$tmp/stderr" | head -1)"
  library_said="$(AGREE_PROBE="$agree_probe" python3 - "$repo_root" <<'LIB'
import importlib.util, os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    mod.manifest_rows(pathlib.Path(os.environ["AGREE_PROBE"]))
    print("")
except mod.ManifestError as error:
    print(re.sub(r"`.*", "", str(error).replace("scripts/validate: ", "")).strip())
LIB
)"
  [[ -n "$library_said" ]] && library_rc=2
  [[ "$runner_rc" == 0 ]] && runner_said=""
  if [[ "$runner_said" != "$library_said" ]]; then
    fail "reader agreement" "row $label classified differently:
  runner  ($runner_rc): ${runner_said:-accepted}
  library ($library_rc): ${library_said:-accepted}"
  fi
}
while IFS= read -r row_tags; do
  [[ -n "$row_tags" ]] || continue
  agree_row "$row_tags"
done <<'ROWS'
may-skip,may-skip
qml,qml
always,always
qml,may-skip,may-skip
may-skip
-,-
qml,
notatoken
ROWS
ok "both readers classify every duplicate and malformed row identically"

# Require accepted control rows to be listed by both readers. Agreement on refusal cannot prove whitespace acceptance.
agree_accepts() {
  local row_tags="$1" label="${2:-$1}" rc=0 listed library
  agree_row "$row_tags" "$label"
  listed="$("$agree_probe" --list qml 2>"$tmp/stderr")" || rc=$?
  if [[ "$rc" != 0 ]]; then
    fail "reader agreement" "row $label was refused by the runner (rc $rc): $(head -1 "$tmp/stderr")"
  fi
  expect_contains "$listed" "scripts/check-naming.sh" "reader agreement: runner lists $label"
  library="$(AGREE_PROBE="$agree_probe" python3 - "$repo_root" <<'LIB'
import importlib.util, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    rows = mod.manifest_rows(pathlib.Path(os.environ["AGREE_PROBE"]))
except mod.ManifestError as error:
    print(f"REFUSED {error}")
else:
    print("LISTED" if ("qml", "scripts/check-naming.sh") in rows else f"MISSING {rows[:3]}")
LIB
)" || true
  expect_contains "$library" "LISTED" "reader agreement: library lists $label"
}

# Split rows on newline only. Vertical tab, form feed, and carriage return belong to the
# ASCII whitespace set and must not create extra rows through splitlines or newline translation.
for control in '\v' '\f' '\r'; do
  printf -v control_tags 'qml%b' "$control"
  agree_accepts "$control_tags" "qml followed by a literal $control"
done
ok "a row tagged with a \\v, \\f or \\r is one row to both readers, and taken by both"

# Drive control characters through the real grammar dump. Both subprocess capture and
# decoder splitting must preserve non-newline whitespace within a message record.
dump_line_dir="$tmp/dump-line"
mkdir -p "$dump_line_dir/scripts/lib"
cp "$runner" "$dump_line_dir/scripts/validate"
chmod +x "$dump_line_dir/scripts/validate"
while IFS=';' read -r label escape; do
  [[ -n "$label" ]] || continue
  printf -v control_char '%b' "$escape"
  MARK="$control_char" python3 - "$repo_root/scripts/lib/validation-grammar.conf" \
    >"$dump_line_dir/scripts/lib/validation-grammar.conf" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = [line for line in t.split("\n") if line.startswith("message row-empty-tags")]
assert len(old) == 1, "the row-empty-tags message moved"
print(t.replace(old[0], old[0] + f" ({os.environ['MARK']}marked)"), end="")
MUT
  dumped_line="$("$dump_line_dir/scripts/validate" --dump-grammar)" ||
    fail "dump line boundary" "the runner refused a grammar whose message carries $label"
  # Require the control character in the emitted dump before testing decoding.
  [[ "$dumped_line" == *"$control_char"* ]] ||
    fail "dump line boundary" "the runner dropped $label before dumping, so the case cannot fail"
  dump_line_said="$(DUMP_PROBE="$dump_line_dir/scripts/validate" MARK="$control_char" \
    python3 - "$repo_root" <<'LIB'
import importlib.util, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    rules = mod.grammar(pathlib.Path(os.environ["DUMP_PROBE"]))
except mod.ManifestError as error:
    print(f"REFUSED {error}")
else:
    text = rules.messages["row-empty-tags"]
    print("DECODED" if text.endswith(f"({os.environ['MARK']}marked)") else f"LOST {text!r}")
LIB
  )" || true
  expect_contains "$dump_line_said" "DECODED" "dump line boundary ($label)"
done <<'DUMPLINES'
a vertical tab;\x0b
a carriage return;\x0d
DUMPLINES
ok "a \\v or \\r inside a dumped message is one dump line to the decoder, as the runner emitted it"

# Use a locale that changes Unicode whitespace classification and measure that property directly.
# A bounded, deterministic locale sample avoids exhaustive subprocess work without assuming
# the ambient locale can distinguish ASCII stripping from locale-resolved space classes.
LOCALE_SAMPLE=2
PREFERRED_LOCALE=en_US.utf8
locales=()
utf8_locales=()
c_locales=()
while IFS= read -r loc; do
  case "$loc" in
    # Keep C.utf8 as a fallback because its classification depends on libc.
    # Measure the selected locale rather than inferring its behavior from the name.
    C.utf8 | C.UTF-8) c_locales+=("$loc") ;;
    *.utf8 | *.UTF-8) utf8_locales+=("$loc") ;;
  esac
done < <(locale -a 2>/dev/null | LC_ALL=C sort)
utf8_locales+=("${c_locales[@]}")
for loc in "$PREFERRED_LOCALE" "${utf8_locales[@]}"; do
  [[ ${#locales[@]} -lt $LOCALE_SAMPLE ]] || break
  # Use the preferred locale only when installed.
  printf '%s\n' "${utf8_locales[@]}" | grep -qxF -- "$loc" || continue
  printf '%s\n' "${locales[@]}" | grep -qxF -- "$loc" && continue
  locales+=("$loc")
done

# A locale that exposes no class difference cannot prove this control and must skip.
# Feed fixed UTF-8 bytes so locale-dependent escape encoding cannot change the input.
locale_resolves_class() {
  local stripped
  stripped="$(LC_ALL="$1" bash -c \
    'x="$(printf "x\xe2\x80\x82")"; printf "%s" "${x//[[:space:]]/}"')" || return 1
  [[ "$stripped" == "x" ]]
}

locale_sample_is_degenerate=1
for loc in ${locales[@]+"${locales[@]}"}; do
  if locale_resolves_class "$loc"; then
    locale_sample_is_degenerate=0
  fi
done

if [[ ${#locales[@]} -eq 0 ]]; then
  # Run the named locale explicitly so a substitute cannot satisfy its coverage claim.
  skip "C4 locale control" \
    "this system provides no UTF-8 locale (locale -a), so the one condition that" \
    "distinguishes an ASCII rule from a locale-resolved class could not be created." \
    "The rule is NOT proven on this machine."
else
  space_probe="$fixture_dir/scripts/space-probe"
  for codepoint in 00A0 2002 3000; do
    CODEPOINT="$codepoint" python3 - "$runner" >"$space_probe" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "qml       | scripts/check-naming.sh"
assert t.count(old) == 1, "the naming-check manifest row moved"
tag = "qml" + chr(int(os.environ["CODEPOINT"], 16))
print(t.replace(old, f"{tag}       | scripts/check-naming.sh"), end="")
MUT
    chmod +x "$space_probe"
    verdicts=()
    for loc in C "${locales[@]}"; do
      rc=0
      LC_ALL="$loc" "$space_probe" --list docs >/dev/null 2>"$tmp/stderr" || rc=$?
      said="accepted"
      # Compare diagnostics as well as statuses, trimming with the explicit ASCII set.
      [[ "$rc" != 0 ]] && said="$(LC_ALL=C sed -e 's/^scripts\/validate: //' -e 's/`.*//' \
        -e 's/[ \t]*$//' "$tmp/stderr" | head -1)"
      verdicts+=("runner/$loc: $rc $said")
      lib="$(LC_ALL="$loc" SPACE_PROBE="$space_probe" python3 - "$repo_root" <<'LIB'
import importlib.util, os, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    mod.manifest_rows(pathlib.Path(os.environ["SPACE_PROBE"]))
    print("0 accepted")
except mod.ManifestError as error:
    print("2 " + re.sub(r"`.*", "", str(error).replace("scripts/validate: ", "")).strip())
LIB
)"
      verdicts+=("library/$loc: $lib")
    done

    first="${verdicts[0]#*: }"
    for verdict in "${verdicts[@]}"; do
      if [[ "${verdict#*: }" != "$first" ]]; then
        fail "C4 locale control" "U+$codepoint in a tag field is classified differently:
$(printf '  %s\n' "${verdicts[@]}")"
        break
      fi
    done
    # Require refusal too; readers agreeing to accept Unicode whitespace would still violate the grammar.
    [[ "$first" == 2\ * ]] ||
      fail "C4 locale control" "U+$codepoint in a tag field is ACCEPTED ($first)"
  done
  if [[ $locale_sample_is_degenerate -eq 1 ]]; then
    # shellcheck disable=SC2016  # the backticks quote a shell pattern in the notice
    skip "C4 locale control" \
      "no locale this system provides (${locales[*]}) resolves a Unicode space" \
      'through `[[:space:]]`, measured directly, so the one condition that' \
      "distinguishes an ASCII rule from a locale-resolved class could not be created." \
      "Both readers agreed on every codepoint, but the rule is NOT proven here."
  else
    ok "C4 holds for both readers under C and ${locales[*]}"
  fi
fi

# Build a real fixture tree under a spaced path so the emitted source field exercises its transport.
spaced="$tmp/a directory with spaces"
mkdir -p "$spaced/scripts/lib"
cp "$runner" "$spaced/scripts/validate"
chmod +x "$spaced/scripts/validate"
cp "$repo_root/scripts/lib/validation-grammar.conf" "$spaced/scripts/lib/"
rc=0
"$spaced/scripts/validate" --list docs >/dev/null 2>"$tmp/stderr" || rc=$?
[[ "$rc" == 0 ]] || fail "spaced path" "the runner failed at a spaced path (rc $rc): $(cat "$tmp/stderr")"
run_guard "RUNNER_PATH=$spaced/scripts/validate"
expect_absent "$guard_out" "cannot read" "spaced path"
expect_clean_run "spaced path"
ok "a checkout under a path containing a space runs, and the guard reads its dump"

# An empty source field remains invalid even though spaces within paths are permitted.
empty_source="$(printf '%s\n' "$good_dump" | sed -e 's|^source .*|source|')"
[[ "$empty_source" == *$'\nsource\n'* || "$empty_source" == source$'\n'* ]] ||
  fail "empty source" "the mutation did not produce a bare source line"
printf '#!/usr/bin/env bash\ncat <<%s\n%s\nDUMP_EOF\n' "'DUMP_EOF'" \
  "$empty_source" >"$dump_stub"
chmod +x "$dump_stub"
run_guard "RUNNER_PATH=$dump_stub"
expect_refused "empty source" "\`source\` line is empty"
ok "an empty source line is still refused, so the field is relaxed and not dropped"

# Wrap each producer to emit valid bytes and then fail. Collection must preserve that status
# so partial grammar or manifest output cannot silently narrow validation.
wrapper_dir="$tmp/failing-producers"
mkdir -p "$wrapper_dir"
while IFS=';' read -r tool invocations label; do
  [[ -n "$tool" ]] || continue
  real="$(command -v "$tool")"
  [[ -n "$real" ]] || { fail "$label" "no $tool on PATH to wrap"; continue; }
  printf '#!/usr/bin/env bash\n%s "$@"\nexit 42\n' "$real" >"$wrapper_dir/$tool"
  chmod +x "$wrapper_dir/$tool"
  # Grammar-only dumping does not collect the manifest; choose invocations that reach the mutated producer.
  # shellcheck disable=SC2086  # the invocation list is a deliberate word list
  for invocation in $invocations; do
    invocation="${invocation//+/ }"
    rc=0
    # shellcheck disable=SC2086  # the invocation is a deliberate word list
    out="$(PATH="$wrapper_dir:$PATH" "$runner" $invocation 2>"$tmp/stderr")" || rc=$?
    err="$(cat "$tmp/stderr")"
    [[ "$rc" == 2 ]] || fail "$label" "exited $rc for \`$invocation\`, not 2"
    expect_absent "$out" "scripts/" "$label ($invocation)"
    # Transport failure needs a read diagnostic, not malformed-grammar advice.
    expect_contains "$err" "collection exited 42" "$label ($invocation)"
    expect_contains "$err" "read/transport failure" "$label ($invocation)"
  done
  rm -f "$wrapper_dir/$tool"
  ok "$label"
done <<'PRODUCERS'
sed;--list+docs --list+all docs --dump-grammar;a failing grammar producer exits 2 with nothing listed
cat;--list+docs --list+all docs;a failing manifest producer exits 2 with nothing listed
PRODUCERS

# The same wrapper with successful status must pass so wrapper presence alone cannot satisfy the refusal.
real_sed="$(command -v sed)"
printf '#!/usr/bin/env bash\n%s "$@"\n' "$real_sed" >"$wrapper_dir/sed"
chmod +x "$wrapper_dir/sed"
rc=0
PATH="$wrapper_dir:$PATH" "$runner" --list docs >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] || fail "producer wrapper" "a passthrough wrapper changed the outcome (rc $rc)"
rm -f "$wrapper_dir/sed"
ok "a passthrough wrapper is transparent, so the cases above catch the status"

# Add a real executable row outside scripts to verify CI coverage is not limited to script discovery.
offtree_runner="$tmp/offtree-runner"
awk '/^MANIFEST_EOF$/ && !seen {
  print "-         | .agents/skills/worktree/scripts/worktree"; seen = 1
} { print }' "$runner" >"$offtree_runner"
chmod +x "$offtree_runner"
run_guard "RUNNER_PATH=$offtree_runner"
expect_refused "off-tree manifest row" "which .github/workflows/ci.yml does not"
ok "a manifest row outside scripts/ that ci.yml never runs is reported"

# Replace one real CI invocation per case with a nonexecuting mention or conditional path.
# Arguments, comments, quoted separators, redirects, definitions, arrays, and optional branches
# cannot establish unconditional command execution. Heredoc terminators need a multiline fixture.
while IFS='|' read -r shape replacement; do
  [[ -n "$shape" ]] || continue
  doctored="$tmp/ci-$shape.yml"
  SHAPE_REPLACEMENT="$replacement" python3 - "$repo_root" "$doctored" <<'MENTION_ONLY'
import os, pathlib, sys
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
step = "        run: .agents/skills/doc-limits/scripts/doc-limits\n"
if step not in text:
    sys.exit("the doc-limits ci.yml step these fixtures doctor has moved")
body = os.environ["SHAPE_REPLACEMENT"].replace("@", ".agents/skills/doc-limits/scripts/doc-limits")
out.write_text(text.replace(step, f"        run: |\n          {body}\n", 1), encoding="utf-8")
MENTION_ONLY
  if [[ ! -s "$doctored" ]]; then
    fail "ci mention-only ($shape)" "the fixture workflow was not written (see the message above)"
    continue
  fi
  run_guard "CI_PATH=$doctored"
  expect_refused "ci mention-only ($shape)" "which .github/workflows/ci.yml does not"
  ok "a path CI only mentions ($shape) is not a path CI runs"
done <<'SHAPES'
argument|echo @
comment|true  # was @
quoted-separator|echo "( @ )"
redirection|: > @
function-definition|@() { :; }
short-circuit|true || @
conditional-branch|if false; then @; fi
array-element|saved=(@)
SHAPES

# For <<EOF, only the exact delimiter ends the body. An indented look-alike remains data
# and must not expose later payload lines as CI commands.
heredoc_ci="$tmp/ci-heredoc-terminator.yml"
python3 - "$repo_root" "$heredoc_ci" <<'HEREDOC_SHAPE'
import pathlib, sys
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
step = "        run: .agents/skills/doc-limits/scripts/doc-limits\n"
if step not in text:
    sys.exit("the doc-limits ci.yml step these fixtures doctor has moved")
# The space-indented EOF remains body text under the shell's delimiter rule.
out.write_text(text.replace(step,
    "        run: |\n"
    "          cat <<EOF\n"
    "           EOF\n"
    "          .agents/skills/doc-limits/scripts/doc-limits\n"
    "          EOF\n", 1), encoding="utf-8")
HEREDOC_SHAPE
if [[ ! -s "$heredoc_ci" ]]; then
  fail "ci heredoc terminator" "the fixture workflow was not written (see the message above)"
else
  run_guard "CI_PATH=$heredoc_ci"
  expect_refused "ci heredoc terminator" "which .github/workflows/ci.yml does not"
  ok "a path inside a heredoc body is data, whatever the body looks like"
fi


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

if [[ $failures -ne 0 ]]; then
  printf '\ntest-validation-inventory: %d failure(s)\n' "$failures" >&2
  exit 1
fi
# Record skipped control names with status 77 so an uncreatable case cannot report complete success.
if [[ $skips -ne 0 ]]; then
  printf 'test-validation-inventory: passed, %d skipped: %s\n' \
    "$skips" "$(IFS=', '; echo "${skipped_names[*]}")" >&2
  exit 77
fi
echo "test-validation-inventory: all checks passed"
