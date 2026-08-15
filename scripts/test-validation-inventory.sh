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
# The fragments the unmutated control asserts are ABSENT. Built from the shared
# diagnostics definition plus the guard-only arms, never retyped: four of these
# had drifted to text no code emits, so those arms could not fire and a real
# leakage regression would have passed them. Third vacuous control in this PR.
ARM_MESSAGES=()
while IFS= read -r text; do
  [[ -n "$text" ]] && ARM_MESSAGES+=("$text")
done < <(sed -n 's/^message  *[a-z-]*  *//p' "$repo_root/scripts/lib/validation-grammar.conf")

# Arms that belong to the guard alone, so they have no entry in the shared
# definition. Each is proved live by the liveness check below.
GUARD_ONLY_MESSAGES=(
  "no manifest row is tagged with it"
  "is not executable"
  "enumerates the validate areas but omits"
  "no longer states the validate area list"
  "has no table introduced by"
  "does not act on it"
  "the runner's derivation and the definition have drifted"
  "CI coverage was NOT checked"
)
ARM_MESSAGES+=("${GUARD_ONLY_MESSAGES[@]}")

# LIVENESS, in two halves, because the two kinds go stale differently.
#
# A shared fragment is live if some reader looks its KEY up — a message declared
# in the definition and used by neither is the message equivalent of a declared
# but unwired token.
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  if ! grep -qF -- "$key" "$repo_root/scripts/validate" \
    && ! grep -qF -- "$key" "$repo_root/scripts/lib/validation_manifest.py"; then
    fail "shared diagnostics" "the grammar declares message \`$key\` that neither reader uses"
  fi
done < <(sed -n 's/^message  *\([a-z-]*\) .*/\1/p' "$repo_root/scripts/lib/validation-grammar.conf")

# A guard-only fragment is retyped here, so it is live only if a reader's source
# still contains it. Compared against the source with ADJACENT STRING LITERALS
# JOINED: these messages are built from split f-strings, so a raw grep for the
# emitted sentence finds nothing and would call every one of them dead.
if ! python3 - "$repo_root" "${GUARD_ONLY_MESSAGES[@]}" <<'LIVE'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
sources = ""
for name in ("scripts/check-validation-inventory.py", "scripts/lib/validation_manifest.py"):
    sources += (root / name).read_text(encoding="utf-8")
# Join implicit string concatenation before searching.
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
    # The CI prerequisite has its own assertion below, both directions: without
    # PyYAML it MUST appear, so it is not noise here.
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
#                                   GRAMMAR_PATH PYTHONPATH
# Sets: guard_out, guard_rc
#
# GRAMMAR_PATH IS NO LONGER A PATH THE GUARD READS. The grammar has one parser —
# scripts/validate — and the guard consumes `--dump-grammar`, so a grammar
# fixture is a RUNNER fixture and a runner fixture needs its grammar: both are
# laid out at the paths the runner resolves (scripts/validate plus
# scripts/lib/<conf>) and RUNNER_PATH is pointed at that copy. Every call site
# below is unchanged, which is the point — the cases still say "this grammar" or
# "this runner", and the plumbing that makes the runner the one reader lives
# here.
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
  # A runner fixture that ALREADY has its grammar beside it is used where it
  # lies. Copying it unconditionally silently relocated it, which made the
  # spaced-path control vacuous: the fixture was built under a directory with a
  # space and then copied to one without, so it passed with the bug restored.
  if [[ -z "$grammar_override" && -n "$runner_override" ]] &&
    [[ -r "$(dirname -- "$runner_override")/lib/validation-grammar.conf" ]]; then
    env_args+=("RUNNER_PATH=$runner_override")
  elif [[ -n "$grammar_override" || -n "$runner_override" ]]; then
    rm -rf "$tmp/paired"
    mkdir -p "$tmp/paired/scripts/lib"
    # `cp` carries the source's mode, which the non-executable-runner case
    # depends on: a fixture that silently gained the executable bit here would
    # make that control unable to fail.
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

# A token the runner never acts on. WHAT "UNWIRED" MEANS CHANGED when the last
# literal rules became properties: a `modifier` token now participates by
# construction, because `skips=yes` is what grants the skip channel and the
# runner reads that property rather than matching `may-skip`. So the inert case
# is a token in a class that grants NOTHING — which is the honest shape, and the
# one a new class can still get wrong.
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

# A SECOND UNIVERSAL TOKEN is what distinguishes a DERIVED rule from a literal
# one. With only `always` declared, `*",always,"*` and "any universal tag"
# behave identically, so no behavioural test can tell them apart — adding a
# second selector-class token can: the derived rule selects it, the literal does
# not. This is the control for "rules come from the definition, not a branch".
printf '%s\ntoken everywhere selector\n' "$real_grammar" >"$tmp/second-universal.conf"
run_guard "GRAMMAR_PATH=$tmp/second-universal.conf"
expect_absent "$guard_out" "does not act on it" "second universal token"
[[ "$guard_rc" -eq 0 || $have_yaml -eq 0 ]] ||
  fail "second universal token" "a second universal token is not acted on (rc $guard_rc)"
ok "a second universal token selects, so the rule is derived and not a literal"

# The accept side: every real token participates, so the unmutated grammar
# passes. Asserted explicitly — "everything is rejected" would otherwise look
# like success.
run_guard
expect_absent "$guard_out" "does not act on it" "real tokens participate"
ok "every token the real grammar declares is found to participate"

grammar_case "a second exclusive token is reported" \
  "$real_grammar
token none       exclusive" \
  "wrong number of tokens in a class"

# CLASS PROPERTIES ARE PARSED BY KEY IN BOTH READERS. The bash side read them
# positionally while python read them by key, so REORDERING the same four pairs
# made the two readers interpret one definition differently — in the file
# written to end reader disagreements. The reorder case must PASS; it is the one
# that proves the fix rather than the refusals.
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

# A FINAL LINE WITH NO TRAILING NEWLINE. `read` returns non-zero at EOF, so the
# bash loop dropped it while python's splitlines() kept it — one reader saw a
# token the other did not. grammar_case writes with printf and no trailing
# newline, so every case above also exercises this; asserted explicitly because
# an incidental exercise is not a control.
printf '%s\ntoken nightly    inert' "${real_grammar/class argument   /$INERT_CLASS
class argument   }" >"$tmp/unterminated.conf"
run_guard "GRAMMAR_PATH=$tmp/unterminated.conf"
expect_refused "unterminated final line" "does not act on it"
ok "a final line with no trailing newline is read by both readers"

# INCOMPLETE RECORDS, one case per line kind per shape. Each branch used to
# index fields it had not proven present: three of four kinds gave the runner a
# raw bash error at rc 1 — indistinguishable from an ordinary check failure —
# and three of four gave the guard a traceback instead of a diagnostic.
#
# The runner assertion is exit 2 with NOTHING RUN; the guard assertion is a
# named problem with NO TRACEBACK. The traceback assertion is explicit because a
# traceback plus a non-zero status satisfies a status-only check — the vacuous
# shape this PR has hit three times.
while IFS=';' read -r label bad expect; do
  [[ -n "$label" ]] || continue
  printf '%s\n%s\n' "$real_grammar" "$bad" >"$tmp/arity.conf"

  # Runner: exit 2, no check run, no raw shell error.
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
  # A bash error reads `scripts/validate: line 314: ...`; the legitimate
  # diagnostic contains "grammar line has", so match the `: line ` marker.
  expect_absent "$err" ": line " "arity: $label (raw shell error)"

  # Guard: a named problem, no traceback.
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

# A kind permitting zero fields would leave every branch's NAME read unproven.
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
  "wrong number of tokens in a class"

grammar_case "an uppercase token is reported" \
  "${real_grammar/token qml        area/token Qml        area}" \
  "token name must be lowercase"

# A NAME DECLARED TWICE, one case per line kind. `class` is the reported defect:
# it was accepted SILENTLY by both former readers and merged differently by each
# — python replaced the whole record, bash overwrote only the later line's keys
# — so one file meant two things. The other three kinds are here because
# "declared twice" is the rule; fixing `class` alone would have been the ninth
# shape.
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

# A COUNT IS AN INTEGER, and saying so is half the fix: `min=banana` was already
# refused, but as "class property must be yes or no", which names a rule `min`
# does not have. Both the `class` and `kind` sites are covered — the `kind` one
# was not validated at all, so a typo there silently turned that kind's arity
# off by arithmetic-evaluating an unknown word to 0.
while IFS=';' read -r label from to; do
  [[ -n "$label" ]] || continue
  # The anchor must exist and must be on a REAL line: matching inside a comment
  # would produce a fixture the runner strips before parsing, i.e. a control
  # that cannot fail. Both anchors are checked against the uncommented text.
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

# NON-CANONICAL DECIMAL FORMS, at BOTH numeric sites. `^[0-9]+$` accepted `08`,
# which bash arithmetic reads as octal and then rejects: `[[ 2 -lt 08 ]]` wrote
# "value too great for base" to stderr and evaluated FALSE, so the arity check
# and the class-count invariant silently switched themselves off while the run
# carried on at rc 0. Every form is asserted against the runner directly —
# exit 2, nothing listed, and NO raw shell error, which is the half a status
# check alone would miss.
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

# ...and the accept side: ordinary values still parse, so the rule is not merely
# tight. Proven by the whole suite passing on the real grammar, and pinned here
# on the two values a reader is most likely to break — 0 and a multi-digit
# count, neither of which any shipped line uses.
canon_from='universal=yes skips=no  min=0'
canon_to='universal=yes skips=no  min=0 max=10'
printf '%s' "${real_grammar/$canon_from/$canon_to}" >"$tmp/canon.conf"
grep -qF -- "$canon_to" "$tmp/canon.conf" ||
  fail "canonical counts accepted" "the mutation did not apply, so the case cannot fail"
run_guard "GRAMMAR_PATH=$tmp/canon.conf"
expect_clean_run "canonical counts accepted"
ok "ordinary decimal counts still parse, including 0 and a multi-digit value"

# EXACTLY ONE CLI DEFAULT, COUNTED ACROSS ALL CLASSES. `argument min=1 max=1`
# bounds the tokens of ONE class and says nothing about how many classes carry
# `cli=yes rowtag=no`, which is the pair that decides the default. A second such
# class left `--list docs` at rc 0 over four commands while the runner picked
# one of two candidates silently — the runner running against a grammar the
# guard rejected, which is the split this whole change exists to close.
#
# Both shapes are covered, and they are caught by DIFFERENT rules on purpose:
# two eligible tokens in one class is the class cardinality invariant, two in
# different classes is the new cross-class one. Testing only the first would
# have passed before this fix.
while IFS=';' read -r label extra expect; do
  [[ -n "$label" ]] || continue
  # `%%` stands in for a newline: a case's added lines have to fit one record
  # of this table.
  printf '%s\n%s\n' "$real_grammar" "${extra//%%/$'\n'}" >"$tmp/default.conf"
  cp "$tmp/default.conf" "$fixture_dir/scripts/lib/validation-grammar.conf"
  cp "$runner" "$fixture_dir/scripts/validate"
  chmod +x "$fixture_dir/scripts/validate"
  # A named area, `all`, and a real run: the reported symptom was rc 0 from
  # `--list docs`, so `--list` is not optional coverage here.
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

# A FIELD REPEATED INSIDE ONE RECORD, on every record kind that has named
# fields. `class` validated this and `kind` did not, so `kind class min=100
# min=2` was silently last-one-wins — an ambiguous declaration of the rule that
# governs how every OTHER record is read, with the runner then executing checks
# against it. The two record kinds with named fields are `kind` (min, max) and
# `class` (the seven booleans plus min and max); `token <name> <class>` and
# `message <key> <text>` are positional and have no named field to repeat, and
# token's `max=2` arity refuses an extra field before it could be one — that
# case is asserted below so "not covered" and "cannot happen" stay distinct.
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

# A HAND-BUILT DUMP THE RUNNER WOULD NEVER EMIT. The decoder is the ONLY
# consumer of the dump, so it is the last place a runner dump bug can be caught
# — and a runner bug is the one class the single-reader shape cannot catch any
# other way. It coerced a non-digit min/max to -1 and dropped it, which is the
# "decoder supplying a default" the dump's own design note forbids. Each case
# is a stub runner printing a corrupted dump; every one must raise, name the
# RUNNER'S DUMP as the defect, and reach the guard as a collected problem with
# no traceback.
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
DUMPS

# ...and the two REQUIRED dump lines, whose absence is the shape a `${x/from/to}`
# mutation cannot express.
for required in source default; do
  printf '#!/usr/bin/env bash\ncat <<%s\n%s\nDUMP_EOF\n' "'DUMP_EOF'" \
    "$(printf '%s\n' "$good_dump" | grep -v "^$required ")" >"$dump_stub"
  chmod +x "$dump_stub"
  run_guard "RUNNER_PATH=$dump_stub"
  expect_refused "missing $required line" "no \`$required\` line"
  expect_absent "$guard_out" "Traceback" "missing $required line"
done
ok "a dump missing a required line is refused, naming the line"

# The accept side: the real grammar resolves ONE default, the runner dumps it,
# and a bare `scripts/validate --list` still uses it. Asserted against the dump
# rather than against `all` spelled here, so the case tracks the definition.
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

# ONE READER, PROVEN BY RELAY. The guard no longer parses the definition — it
# consumes `scripts/validate --dump-grammar` — so the property worth pinning is
# that a refusal reaches it as the RUNNER'S OWN sentence, unchanged. Compared
# against what the runner actually printed, not against an expected string:
# comparing both sides to one expectation is how two readers drift together.
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

# ...and the accept side of the same relay: the guard's view of a GOOD grammar
# is the dump, byte for byte. A decoder that quietly supplied a default, or
# dropped a record, would pass every refusal case above and fail here.
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
lines = [f"source {g.source}", f"default {g.default_area}"]
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
expect_contains "$pyyaml_out" "ROWS 69" "PyYAML absent"
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
# Both places the module launches bash are covered: the row syntax check, and
# the grammar dump the single-reader change added. A dump that cannot be
# launched is the worst case of the two — every arm is derived from it.
launch_out="$(python3 - "$repo_root" 2>&1 <<'NOBASH' || true
import importlib.util, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
runner = root / "scripts" / "validate"
rules = mod.grammar(runner)  # a real dump, before bash is taken away

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
printf '%s\ntoken nightly    inert\n' "${real_grammar/class argument   /$INERT_CLASS
class argument   }" >"$noyaml_grammar"
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

# THE TWO READERS, COMPARED TO EACH OTHER on the same row — not each against
# its own expectation, since two readers checked only against expectations can
# both be wrong in the same direction. `may-skip,may-skip` is the case that
# proves it: the python side collapsed a row's tags with set() and the runner
# did not, so the same row was "cannot stand alone" to one and "carries no
# selector" to the other. Length now comes from the list, membership from a set.
agree_probe="$fixture_dir/scripts/agree-probe"
while IFS= read -r row_tags; do
  [[ -n "$row_tags" ]] || continue
  ROW="$row_tags" python3 - "$runner" >"$agree_probe" <<'MUT'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "qml       | scripts/check-naming.sh"
assert t.count(old) == 1, "the naming-check manifest row moved"
print(t.replace(old, f"{os.environ['ROW']} | scripts/check-naming.sh"), end="")
MUT
  chmod +x "$agree_probe"
  runner_rc=0
  "$agree_probe" --list docs >/dev/null 2>"$tmp/stderr" || runner_rc=$?
  # Trailing space matters: stripping from the backtick leaves one on the
  # runner side and not the library's, which reads as a difference that is not.
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
  library_rc=0
  [[ -n "$library_said" ]] && library_rc=2
  [[ "$runner_rc" == 0 ]] && runner_said=""
  if [[ "$runner_said" != "$library_said" ]]; then
    fail "reader agreement" "row \`$row_tags\` classified differently:
  runner  ($runner_rc): ${runner_said:-accepted}
  library ($library_rc): ${library_said:-accepted}"
  fi
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

# C4 UNDER A NON-C LOCALE, which is the only place this can be tested. The
# runner used `[[:space:]]`, whose meaning bash resolves through the LOCALE:
# under this machine's own en_US.UTF-8 it matched U+2002 EN SPACE and U+3000
# IDEOGRAPHIC SPACE, so a row tagged `qml<U+2002>` was normalised to `qml` and
# ACCEPTED by the runner while the library — explicitly ASCII — refused it. C4
# was asserted by the definition and true only incidentally. A control run in
# whatever locale happens to be ambient cannot catch that, so this one names its
# locales and fails if none is available rather than quietly proving nothing.
#
# glibc excludes NBSP from `space`, so U+00A0 — the character the review named —
# is not the one that bites here. All three are exercised: the rule is about the
# CLASS being locale-resolved, not about one character.
locales=()
while IFS= read -r loc; do
  case "$loc" in
    *.utf8 | *.UTF-8) locales+=("$loc") ;;
  esac
done < <(locale -a 2>/dev/null)

if [[ ${#locales[@]} -eq 0 ]]; then
  # NAMED, not substituted. A weaker test passing here would assert that the
  # rule holds under a locale nobody exercised.
  printf '  SKIP  C4 locale control: this system provides no UTF-8 locale (locale -a), so the\n' >&2
  printf '        one condition that distinguishes an ASCII rule from a locale-resolved class\n' >&2
  printf '        could not be created. The rule is NOT proven on this machine.\n' >&2
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
      # The message is compared too, not just the verdict: two readers can
      # refuse a row for different reasons, which is the divergence that
      # produced `may-skip,may-skip`. Trimmed with an explicit ASCII set, since
      # a locale-resolved class in the TEST would have the same flaw.
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
    # Every verdict must be the same one: same status, same sentence, every
    # reader, every locale.
    first="${verdicts[0]#*: }"
    for verdict in "${verdicts[@]}"; do
      if [[ "${verdict#*: }" != "$first" ]]; then
        fail "C4 locale control" "U+$codepoint in a tag field is classified differently:
$(printf '  %s\n' "${verdicts[@]}")"
        break
      fi
    done
    # ...and that one verdict must be a REFUSAL. Agreeing to accept a Unicode
    # space would satisfy the loop above and defeat C4.
    [[ "$first" == 2\ * ]] ||
      fail "C4 locale control" "U+$codepoint in a tag field is ACCEPTED ($first)"
  done
  ok "C4 holds for both readers under C and ${locales[*]}"
fi

# A CHECKOUT UNDER A PATH CONTAINING A SPACE. The runner dumps the grammar's
# absolute path, and requiring that value to be one whitespace-free word made
# the guard refuse to run on a correct tree at such a path — the strictness was
# right, the shape of the field was wrong. Built as a real tree rather than a
# hand-written dump, so the actual emission path is what is exercised.
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

# ...and the field is still VALIDATED, not merely relaxed: an empty `source` is
# refused. The missing-line case is asserted above.
empty_source="$(printf '%s\n' "$good_dump" | sed -e 's|^source .*|source|')"
[[ "$empty_source" == *$'\nsource\n'* || "$empty_source" == source$'\n'* ]] ||
  fail "empty source" "the mutation did not produce a bare source line"
printf '#!/usr/bin/env bash\ncat <<%s\n%s\nDUMP_EOF\n' "'DUMP_EOF'" \
  "$empty_source" >"$dump_stub"
chmod +x "$dump_stub"
run_guard "RUNNER_PATH=$dump_stub"
expect_refused "empty source" "\`source\` line is empty"
ok "an empty source line is still refused, so the field is relaxed and not dropped"

# A PRODUCER THAT FAILS AFTER EMITTING. `done < <(producer)` discards the
# producer's status, so both grammar passes accepted whatever bytes arrived —
# and a TRUNCATED grammar is the worst input there is, since every rule below is
# derived from it: a class or token that never arrived does not fail, it
# silently changes what the runner selects. Reproduced the way it was reported,
# with a wrapper that emits the real output and then exits non-zero.
#
# Both grammar passes are covered by one case now: they read the same collected
# bytes, so there is one collection point rather than two to fail separately.
# The manifest heredoc is a second producer and gets its own case.
wrapper_dir="$tmp/failing-producers"
mkdir -p "$wrapper_dir"
while IFS=';' read -r tool invocations label; do
  [[ -n "$tool" ]] || continue
  real="$(command -v "$tool")"
  [[ -n "$real" ]] || { fail "$label" "no $tool on PATH to wrap"; continue; }
  printf '#!/usr/bin/env bash\n%s "$@"\nexit 42\n' "$real" >"$wrapper_dir/$tool"
  chmod +x "$wrapper_dir/$tool"
  # The invocations differ because the two producers are reached from different
  # paths: `--dump-grammar` answers from the grammar alone and never collects
  # the manifest, so listing it for the manifest producer would assert a
  # refusal that SHOULD not happen.
  # shellcheck disable=SC2086  # the invocation list is a deliberate word list
  for invocation in $invocations; do
    invocation="${invocation//+/ }"
    rc=0
    # shellcheck disable=SC2086  # the invocation is a deliberate word list
    out="$(PATH="$wrapper_dir:$PATH" "$runner" $invocation 2>"$tmp/stderr")" || rc=$?
    err="$(cat "$tmp/stderr")"
    [[ "$rc" == 2 ]] || fail "$label" "exited $rc for \`$invocation\`, not 2"
    expect_absent "$out" "scripts/" "$label ($invocation)"
    # A TRANSPORT failure must not read as a malformed grammar: the remedies
    # differ, so the message says which one happened.
    expect_contains "$err" "collection exited 42" "$label ($invocation)"
    expect_contains "$err" "read/transport failure" "$label ($invocation)"
  done
  rm -f "$wrapper_dir/$tool"
  ok "$label"
done <<'PRODUCERS'
sed;--list+docs --list+all docs --dump-grammar;a failing grammar producer exits 2 with nothing listed
cat;--list+docs --list+all docs;a failing manifest producer exits 2 with nothing listed
PRODUCERS

# CONTROL FOR THE CONTROL: the same wrapper that exits 0 changes nothing, so the
# cases above are catching the STATUS and not the wrapper's presence.
real_sed="$(command -v sed)"
printf '#!/usr/bin/env bash\n%s "$@"\n' "$real_sed" >"$wrapper_dir/sed"
chmod +x "$wrapper_dir/sed"
rc=0
PATH="$wrapper_dir:$PATH" "$runner" --list docs >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] || fail "producer wrapper" "a passthrough wrapper changed the outcome (rc $rc)"
rm -f "$wrapper_dir/sed"
ok "a passthrough wrapper is transparent, so the cases above catch the status"

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
