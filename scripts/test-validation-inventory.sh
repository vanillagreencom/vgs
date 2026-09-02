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
# A CONTROL THAT COULD NOT BE CREATED IS NOT A CONTROL THAT PASSED. Printing a
# SKIP notice and returning 0 made this suite report "all checks passed" while a
# named mutation control had never run — the false green behind VGS-69 and the
# exit-77 rule, reached from inside a suite instead of from a refusing tool. Skips
# are counted here so the status can carry them: AGENTS.md's four-valued
# convention makes 77 "what ran passed, but something did NOT run".
#
# READ THIS BEFORE CHASING A RED CI HERE. scripts/validate will report that 77 as
# a plain FAILURE, not as a named skip, and that is deliberate. The runner honours
# 77 only from a row tagged `may-skip`; this suite's manifest row is tagged `-`,
# and the grammar refuses `-,may-skip` — an exclusive tag cannot combine with
# another. Making it combinable means relaxing the exclusive class's max=1 arity,
# which would leave this row skippable for ANY reason thereafter: a permanent
# widening of the vocabulary bought to improve one message in an environment this
# project's CI does not run on. So the trade is deliberate — on a musl or older
# libc, where no locale resolves a Unicode space through `[[:space:]]`, this suite
# fails loudly instead of quietly claiming a control it never created.
skips=0
skipped_names=()
skip() { # $1 = control name, remaining args = the reason, one line each
  # ARITY CHECKED, because the alternative is this helper killing the run from
  # inside the reporting path: `$1` after the shift is unbound under `set -u`, so
  # a call passing only a name ended the suite with no verdict line at all —
  # neither a skip nor a failure — in the one helper whose whole purpose is to
  # make an absent control visible. A malformed call is a FAILURE, not a skip: it
  # is a defect in the suite, and recording it as a skip would let the suite
  # excuse itself with the mechanism it uses to excuse a control.
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

# ...and that guard is itself controlled, in a SUBSHELL so the malformed call is
# observed without its failure being counted against this run. Without the arity
# check the subshell dies on the unbound `$1` and prints bash's own message
# instead, which is exactly the silence being prevented.
skip_arity_said="$( (skip "a control with no reason") 2>&1 )" || true
expect_contains "$skip_arity_said" "skip was called with no reason" "skip helper arity"
case_failed=0 # the subshell's `fail` printed into the capture, not into this run
ok "a skip call with no reason is reported as a malformed call, not a dead run"

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
  "as a validate area, but scripts/validate does not"
  "anchor around its validate area list"
  "but only inside a code fence"
  "a code fence is opened and never closed"
  "opens the validate area anchor but never closes it"
  "a reversed pair anchors nothing"
  "must be anchored exactly once"
  "anchors an empty validate area list"
  "could not read"
  "has no table introduced by"
  "does not act on it"
  "the runner's derivation and the definition have drifted"
  "CI coverage was NOT checked"
  "which .github/workflows/ci.yml does not"
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
    ("CI_PATH", "CI"),
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

# ...ALONGSIDE EVERY OTHER ARM'S VERDICT, which a fragment grep cannot tell from
# an abort at the first raise. The probe machinery reads and executes the runner,
# so it raises on this same fixture; unwrapped, that discarded the manifest_rows
# finding collected moments earlier and printed one line. The guard collects, so
# a LATER arm's message must still be there.
expect_contains "$guard_out" "the per-area and CI-coverage arms did NOT run" \
  "missing MANIFEST_EOF heredoc is reported"
ok "a runner with no manifest delimiter still reports every arm, not just the first raise"

# ...BY EVERY READER OF THAT DELIMITER, not just the one that happens to run
# first. The case above enters through manifest_rows, which refuses loudly; the
# other two used to no-op. `runner_logic` returned text with the manifest's rows
# still in it — the vacuity it documents itself as preventing, since every
# attribute in real use appears in some row — and `build` returned a probe
# carrying the REAL manifest, answering the participation question about the
# wrong rows. Neither shipped a false green, but only because a sibling arm
# refused the same file, which is an implicit coupling nothing asserted. Called
# DIRECTLY here, so the reliance is a checked property rather than an assumption.
heredoc_said="$(python3 - "$repo_root" "$tmp" <<'HEREDOC' 2>&1 || true
import importlib.util, pathlib, sys
root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "vm", root / "scripts" / "lib" / "validation_manifest.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
runner = root / "scripts" / "validate"
# The grammar is read from the REAL runner: a mangled delimiter must be refused
# for the delimiter, not for a grammar the probe could not dump.
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

# ...AND THE AGGREGATION HOLDS FOR EVERY TYPE THAT PATH RAISES, not only the
# library's own. token_participates writes files, chmods them and executes the
# result under text-mode capture, so OSError (an occupied workdir) and
# UnicodeDecodeError (a probe whose output is not UTF-8) reach the loop beside
# ManifestError — both verified against the real function. Catching one type left
# the identical abort through the other two. Driven by making the call raise each
# type in turn, since what is under test is the guard's aggregation policy rather
# than any particular way of provoking it.
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
  # ...and a LATER arm still reported, which is what separates collected from
  # aborted — the same assertion the heredoc case above now makes.
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

# This case proves the guard reports an AREA WITH NO ROWS, so the fixture has to
# empty `docs` completely. It used to retag one named row, which silently stops
# emptying the area the moment the manifest grows a second docs row — VGS-124
# added one, watched this case go green while proving nothing, then cut that row
# again, so the hole is latent rather than fixed. The substitution is global now
# and the emptiness ASSERTED, so the next docs row cannot quietly disable it.
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

# A SELECTOR THAT STOPS BEING UNIVERSAL. The mutation is one character and every
# row stays well formed, so nothing downstream can see it: `always` rows simply
# leave every named area, taking the inventory guard with them. The runner now
# refuses it in its pre-flight, and this is the guard's half — it reads a dump
# that never arrives, so it relays the runner's own sentence.
grammar_case "a selector class that stops being universal is reported" \
  "${real_grammar/cli=no  universal=yes/cli=no  universal=no }" \
  "selects nothing in any named area"

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

# The prose arm's OTHER direction: a document that stops stating the list where
# the guard can read it used to be skipped silently, so the read turned itself
# off while the page kept a real — and possibly wrong — list on it.
#
# THE ANCHOR IS WHAT IS READ, not a phrasing. The parser used to key on the word
# `areas` followed by backticked names, so rewording a lead-in moved the list out
# of view; now only the markers matter. Both directions are pinned below: the
# missing anchor refuses, and a completely reworded region does not.
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

# ...and the fail-closed direction survives the move: a list that is short
# INSIDE the anchor is still reported. A control that only proved wording
# independence would be satisfied by a parser that reads nothing at all.
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

# The anchor's own malformed shapes, each of which would otherwise read one
# region and ignore the rest.
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

# ...and the CLOSING marker is counted too. One opener and two closers reads
# open..close#1, leaving anything between the two closers in a region no reader
# looks at — the same silently-ignored region the opener count exists to prevent,
# reached through the other marker.
python3 - "$repo_root/AGENTS.md" >"$anchored" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
assert t.count("<!-- /validate-areas -->") == 1, "AGENTS.md no longer closes the anchor once"
print(t + "\nstray `docs-only`<!-- /validate-areas -->\n", end="")
MUT
run_guard "AGENTS_PATH=$anchored"
expect_refused "two closing markers" "must be anchored exactly once"
ok "a second closing marker is reported, not read as a wider region"

# THE REVERSE DIRECTION of the prose comparison, which had no fixture at all
# while the anchor rewrite routed MORE input into it: every backticked lowercase
# token inside the region is now read as an area name, so a stray one must be
# reported rather than quietly widening the guard's idea of the vocabulary.
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

# ...and the empty-region raise, which the anchor made reachable: a region with
# prose but no backticked name at all. Distinct from the missing-anchor case —
# the markers are present and correct, and there is simply nothing in them.
# shellcheck disable=SC2016  # the fixture prose is deliberately backtick-free
printf 'see the runner for the areas <!-- validate-areas -->run it for what you touched<!-- /validate-areas -->\n' >"$anchored"
run_guard "AGENTS_PATH=$anchored"
expect_refused "empty anchored region" "anchors an empty validate area list"
ok "an anchor holding prose but no area names is reported"

# A MARKER INSIDE A CODE FENCE IS A PICTURE OF THE CONTRACT, NOT THE CONTRACT.
# Without this, the document that documents the anchor could not show it: a
# second literal opener anywhere on the page — even in a block demonstrating the
# rule — trips the exactly-once refusal, so the mechanism was unnameable in the
# one place it is explained. The refusal direction is what is pinned here: a doc
# whose ONLY anchor is fenced has no anchor at all.
areas_probe="$tmp/areas-probe.md"
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'the guard reads markers like this:\n\n'
  printf '```markdown\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "fenced marker" "but only inside a code fence"
# ...and NOT as "restore the anchor", which is the wrong-cause diagnosis: the
# marker is plainly on the page, so an author sent to re-add it has been told to
# fix something that is not broken while the fence is never mentioned.
expect_absent "$guard_out" "Restore the anchor" "fenced marker"
ok "a marker inside a code fence is reported as fenced, not as missing"

# ...AT EITHER END. Keying the fenced diagnosis on the opener alone left the
# identical wrong cause reachable through the closer: a page whose closing marker
# sits only inside a fence was reported as one that "never closes it", sending
# the author after a marker plainly on the page while the fence went unnamed.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`\n\n'
  printf '```markdown\n<!-- /validate-areas -->\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "fenced closing marker" "but only inside a code fence"
expect_absent "$guard_out" "never closes it" "fenced closing marker"
ok "a closing marker inside a code fence is reported as fenced, not as never closed"

# ...and a pair in the WRONG ORDER is neither. Both markers are unfenced and
# present exactly once, so every count above is satisfied; the region is read
# between them, so a reversed pair anchors nothing — and "never closes it" would
# again name a marker the page carries.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
printf '<!-- /validate-areas -->areas <!-- validate-areas -->`go`\n' >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "reversed anchor pair" "a reversed pair anchors nothing"
expect_absent "$guard_out" "never closes it" "reversed anchor pair"
ok "a closing marker that precedes the opening one is reported as reversed, not as never closed"

# ...and the accept side, which is the whole point: a real anchor plus a fenced
# demonstration of one is exactly what the instructions file now carries, and it
# must parse. Without this case the strip above could delete the real region too.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '```markdown\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "real anchor beside a fenced one"
ok "a document may show the markers in a fence and still carry a real anchor"

# AN UNCLOSED FENCE MOVES THE REGION THAT IS READ, which is why the strip refuses
# one rather than returning what it managed to remove. Fences are paired from the
# top of the page, so ONE stray opener swallows everything below it: the real
# anchor is stripped as if it were the picture, and the illustration's markers
# become the live contract. Both fixtures below passed or misdiagnosed before the
# strip refused an unclosed fence, and each is the shape a reviewer reproduced.
# The stray opener runs FOUR backticks in both, so the illustration's own
# three-backtick fences cannot close it and the page is unclosed by the same rule
# a reader applies — otherwise these would pin the fenced-marker arm instead.
#
# (i) THE SILENT PASS: with the fenced example carrying the COMPLETE list, the
# swap leaves a document that answers correctly for the wrong reason — so a
# later edit to the REAL list would never be compared against anything.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf '````bash\n'
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '```markdown\n<!-- validate-areas -->areas `go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "unclosed fence swallowing the anchor" "a code fence is opened and never closed"
ok "a stray fence that relocates the read region is refused, not answered from the picture"

# (ii) THE WRONG-CAUSE DIAGNOSIS: the same swap with an ordinary fenced block
# carrying no markers leaves nothing anchored, and the report was "restore the
# anchor" — pointing at a marker plainly present and never naming the fence.
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

# ...and the ACCEPT side, so the rule is not merely tight: a page whose fences
# all close parses, however many of them there are. Without this the check above
# would be satisfied by refusing every fenced document.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '```sh\nfirst\n```\n\n```markdown\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\n```\n\n```sh\nthird\n```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "balanced fences"
ok "a page with several balanced fences still parses"

# AN INFO STRING CLOSES NOTHING. CommonMark allows one only on an OPENING fence,
# so backticks followed by other text are ordinary content and the block runs on.
# Closing on run length alone therefore ended the fence early and handed the text
# BELOW the pseudo-closer to the parser as the live contract — a complete anchored
# list that actually renders inside the fence, passing this guard with no
# maintained list on the page. The fixture is that exact page: length-only pairing
# answers it CLEAN, which is why the refusal is what pins the rule.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf '```markdown\nan illustration\n``` not-a-closing-fence\n'
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "info string on a closing fence" "a code fence is opened and never closed"
ok "a fence is not closed by a run carrying an info string, so the text below it stays fenced"

# ...and the ACCEPT side of that same rule: what CommonMark DOES permit after a
# closing run — spaces and tabs — still closes. Without this the refusal above
# would be satisfied by a closer that tolerates nothing at all, which would refuse
# ordinary pages over invisible trailing whitespace.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '```sh\nfirst\n```  \t\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "closing fence with trailing whitespace"
ok "spaces and tabs after a closing run still close the fence"

# ...AND THE PERMITTED SET IS THE RUNNER'S, NOT A PAIR SPELLED HERE. `_read`
# opens with newline="" and the strip splits on \n, so on a CRLF checkout every
# line — closing fences included — ends in a carriage return. A hand-written
# `[ \t]` read that CR as content: no fence closed, and a page whose fences are
# perfectly balanced was refused as unclosed. CR is only the first character the
# two sets disagreed on, which is why the fix is the shared set and this fixture
# is written in CRLF end to end.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\r\n\r\n'
  printf '```markdown\r\n<!-- validate-areas -->areas `go`<!-- /validate-areas -->\r\n```\r\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "CRLF checkout"
ok "a CRLF page whose fences are balanced parses, because the permitted set is the runner's"

# AN OPENER MAY NOT CARRY A BACKTICK IN ITS INFO STRING — the mirror of the case
# above, and the same false accept from the other side. CommonMark forbids a
# backtick in a backtick fence's info string, so such a line is ordinary text;
# treating it as an opener INVERTS which text is live. The fixture is that
# inversion, and it is balanced under BOTH readings so the difference is what is
# read rather than a parse accident: opening on run length alone swallows the
# stale live list on the second line, leaves the complete example live, and the
# page passes on a list nobody renders as the contract. Read correctly the first
# line is prose, the stale list is the live one, and the complete list is the
# picture — so the drift is reported. The `all`-less list is what makes the two
# answers distinguishable at all.
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

# AN INDENTED FENCE IS NOT A FENCE HERE, and the contract paragraph in
# .github/instructions/validation-scripts.instructions.md says so in those
# words. Pinned rather than left incidental: markers demonstrated inside a
# bullet-indented block are read as the real thing, which refuses LOUDLY — the
# right direction, but only if the limit stays where the doc claims it is.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf -- '- demonstrated under a bullet:\n\n  ```markdown\n  <!-- validate-areas -->areas `go`<!-- /validate-areas -->\n  ```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "indented fence" "must be anchored exactly once"
ok "an indented fence does not hide its markers, exactly as the contract states"

# ...and an indented fence does not leave a block OPEN either. Treating a line the
# strip never pairs as an opener would refuse a page whose read region is
# perfectly intact — the wrong-cause direction of the very defect the refusal
# exists to catch — so an indented ``` neither opens nor closes.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf -- '- a lone fence marker quoted in prose:\n\n  ```\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "indented fence never opens a block"
ok "an indented fence neither opens nor closes a block, so it cannot move the region"

# A NESTED FENCE PAIRS BY RUN LENGTH, and this is the FALSE ACCEPT that forced
# the pairing to honour it. A four-backtick block containing a complete
# three-backtick example passes any fence COUNT, but pairing each fence line with
# the next one regardless of length splits the outer block around the inner one
# and leaves the example's middle LIVE — so markers correctly read as a picture
# at one nesting level were silently honoured as the real anchor one level down,
# and a page could pass this guard on a list nobody maintains. The illustration
# below is the only anchor on the page, so being read at all is the defect.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'how to write the anchor:\n\n'
  printf '````markdown\n```md\n<!-- validate-areas -->areas `bogus-area`<!-- /validate-areas -->\n```\n````\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_refused "nested fenced marker" "but only inside a code fence"
expect_absent "$guard_out" "bogus-area" "nested fenced marker"
ok "a marker nested two fences deep is a picture, not the contract"

# ...and the same nesting BESIDE a real anchor parses, which is the accept side
# and what a page documenting the contract actually looks like. Without this the
# case above would be satisfied by refusing every nested document — the false
# refusal the run-length rule also removes.
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
{
  printf 'areas: <!-- validate-areas -->`go`, `qml`, `helper`, `packaging`, `docs`, `all`<!-- /validate-areas -->\n\n'
  printf '````markdown\n```md\n<!-- validate-areas -->areas `bogus-area`<!-- /validate-areas -->\n```\n````\n'
} >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "nested fence beside a real anchor"
ok "a page may nest a fenced illustration and still carry a real anchor"

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
rules = mod.grammar(root / "scripts" / "validate")
for doc in mod.AREA_ENUMERATING_DOCS:
    stated = mod.prose_areas(doc, rules)
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
a non-hex whitespace codepoint is refused;whitespace 20 09;whitespace 20 tab
an odd-length whitespace codepoint is refused;whitespace 20 09;whitespace 20 9
an uppercase whitespace codepoint is refused;whitespace 20 09;whitespace 20 0A
a non-ASCII whitespace codepoint is refused;whitespace 20 09;whitespace 20 a0
a repeated whitespace codepoint is refused;whitespace 20 09;whitespace 20 20
a second whitespace line is refused;whitespace 20 09 0a 0d 0c 0b;APPEND
DUMPS

# ...and the three REQUIRED dump lines, whose absence is the shape a
# `${x/from/to}` mutation cannot express.
for required in source default whitespace; do
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
# The literal is the point: a count derived from the manifest would agree with
# a parser that returned nothing. Adding or dropping a manifest row therefore
# moves it here too; a small mismatch is that, not a broken parser.
expect_contains "$pyyaml_out" "ROWS 80" "PyYAML absent"
expect_contains "$pyyaml_out" "MANIFESTERROR PyYAML is not installed" "PyYAML absent"
expect_absent "$pyyaml_out" "Traceback" "PyYAML absent"
ok "without PyYAML the module imports, the other parsers work, and ci.yml fails with one line"

# prose_areas CANNOT SILENTLY TRUNCATE. The old regex ended its capture at a
# separator it could not follow, so the shape worth pinning was "which
# punctuation still parses". The anchor removed that class of question entirely
# — the region is delimited, and every backticked name inside it is read — so
# what is pinned now is that PUNCTUATION AND LAYOUT DO NOT MATTER, with the
# fail-closed direction covered by the short-list case above.
areas_probe="$tmp/areas-probe.md"
# shellcheck disable=SC2016  # backticks are markdown quoting in the fixture prose
printf '<!-- validate-areas -->areas `go`; `qml` / `helper`\n| `packaging` | `docs` | and `all`.<!-- /validate-areas -->\n' >"$areas_probe"
run_guard "AGENTS_PATH=$areas_probe"
expect_clean_run "punctuation inside the anchor"
ok "separators and line breaks inside the anchor cannot truncate the list"

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

# C4's WHITESPACE SET IS THE RUNNER'S, not a second spelling of it. The library
# used to carry its own `[ \t\n\r\f\v]` under a comment claiming the two moved
# together; nothing enforced that, and no locale control could — a locale changes
# what a CLASS means, never what a spelled-out set contains. Dropping a character
# from the runner's constant is the edit that used to divide the readers
# silently, so it is the control: both must now refuse the row identically,
# because both read the same dumped set.
ws_probe="$tmp/ws-probe/scripts/validate"
mkdir -p "$tmp/ws-probe/scripts/lib"
cp "$repo_root/scripts/lib/validation-grammar.conf" "$tmp/ws-probe/scripts/lib/"
python3 - "$runner" >"$ws_probe" <<'MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
old = "ASCII_SPACE=$' \\t\\n\\r\\f\\v'"
assert t.count(old) == 1, "the ASCII_SPACE constant moved"
t = t.replace(old, "ASCII_SPACE=$' \\n\\r\\f\\v'")
# ...and a row whose tag field carries the character that was dropped. A reader
# still spelling six characters strips the tab and ACCEPTS `qml`; a reader using
# the runner's five keeps it and refuses a malformed tag field. That divergence
# is the whole point of the control — asserting only that the set arrives would
# pass just as well against a pattern built from a hardcoded set.
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

# ...and the set is what each reader APPLIES, asked of the row rather than of the
# value. Compared to each other, never to an expectation: two readers checked
# only against expectations can both be wrong in the same direction.
# The probe exits 2 by design, so its status is taken deliberately rather than
# through a command substitution errexit would abort on.
ws_rc=0
LC_ALL=C "$ws_probe" --list docs >/dev/null 2>"$tmp/stderr" || ws_rc=$?
ws_runner_said="$(LC_ALL=C sed -e 's/^scripts\/validate: //' -e 's/`.*//' \
  -e 's/[ \t]*$//' "$tmp/stderr" | head -1)"
[[ "$ws_rc" != 0 ]] || ws_runner_said="ACCEPTED"
# `|| true` on both substitutions: a module broken badly enough to raise
# something other than ManifestError must be REPORTED by the assertions below,
# not end the run under errexit with the remaining arms unstated. An abort is
# fail-closed in status and useless as a diagnosis.
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

# THE MANIFEST HEREDOC IS FOUND ON A CRLF RUNNER TOO. `_read` opens with
# `newline=""`, so CRLF reaches the patterns intact and a heredoc pattern
# requiring a bare \n matches nothing. `runner_logic` now REFUSES such a miss, so
# a CRLF regression reaches an author as a ManifestError naming the delimiter —
# this case prints that error in place of STRIPPED rather than the SURVIVED it
# was written to catch, and both are failures here. Asserted on a row that
# appears ONLY in the manifest, so a survivor is unambiguous either way.
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
    # The refusal, not a traceback: this is the shape a CRLF regression takes
    # now that a missed delimiter raises, and it must read as the delimiter
    # problem it is.
    print(f"REFUSED {error}")
else:
    print("STRIPPED" if row not in logic and "MANIFEST_EOF" not in logic else "SURVIVED")
CRLF
)"
expect_contains "$crlf_said" "STRIPPED" "CRLF manifest heredoc"
ok "a CRLF-lined runner's manifest is still stripped from the logic the tag check scans"

# UNREADABLE SURFACES ARE DIAGNOSED, NOT TRACEBACKS. Every read in the library
# goes through one helper for this reason; before it, a document that had become
# unreadable escaped as a traceback out of whichever arm touched it first —
# fail-closed in direction, noise in diagnosis. Driven with a directory in place
# of each file, which is an OSError no fixture content can produce.
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
    # The grammar the probe COPIES is the unreadable one. Reached by pointing the
    # decoded source at it, the same injection the guard's own harness uses on
    # the module's path constants — the alternative is a hand-built dump, which
    # would exercise the decoder rather than this read.
    rules = mod.grammar(runner)
    rules.source = nowhere
    return mod.token_participates(runner, rules, "always", tmp / "participate-work")


for label, call in (
    ("ROWS", lambda: mod.manifest_rows(nowhere)),
    ("PROSE", lambda: mod.prose_areas(nowhere, mod.grammar(runner))),
    ("TABLE", lambda: mod.documented_table(nowhere, "**Local-only")),
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
for label in ROWS PROSE TABLE LOGIC PARTICIPATE; do
  expect_contains "$unreadable_out" "$label could not read" "unreadable surface"
done
if [[ $have_yaml -eq 1 ]]; then
  expect_contains "$unreadable_out" "CI could not read" "unreadable surface"
else
  # Without PyYAML the CI arm never reaches its read, and says so. Asserting the
  # read message here would make the case report a prerequisite as a defect.
  expect_contains "$unreadable_out" "CI PyYAML is not installed" "unreadable surface"
fi
expect_absent "$unreadable_out" "Traceback" "unreadable surface"
expect_absent "$unreadable_out" "ACCEPTED" "unreadable surface"
ok "an unreadable surface raises ManifestError naming the path, not a traceback"

# ...and the invariant is SELF-ENFORCING rather than sampled. The loop above
# covers the six call sites that exist today; a seventh added tomorrow would go
# uncovered, and the arms it feeds would emit a traceback in the one file whose
# stated rule is that they do not. So the rule is checked at the source: nothing
# in the module reads a file except the helper that turns the failure into a
# diagnostic. Same shape as the shared-diagnostic liveness block above.
#
# EVERY SPELLING OF A READ, not the one the module happens to use today. This
# keyed on `read_text(` alone, so the instrument built to REPLACE an enumeration
# of call sites reported green on `open(p).read()`, `read_bytes()` and
# `.readlines()` — the same enumeration, wearing a regex.
#
# ASKED OF THE SYNTAX, NOT OF THE LINES. A text scan matches read verbs in PROSE
# as readily as in code, so it needs a prose exemption — and the one it had
# covered `#` comments only, while that module states nearly every rule it has in
# a DOCSTRING. Nothing is misreported today: the module's only prose naming a
# read verb is `_read`'s own docstring, which the `_read` line range already
# skips. The hole is the next line written, not a line present — a docstring
# anywhere else in the module explaining the one-reader rule is a false CI
# failure on prose about the rule, in the file whose convention is to explain
# rules exactly there. Only real call sites are nodes, so parsing needs no prose
# exemption at all, and the docstring hole and the line arithmetic go with it.
one_reader_scan() { # $1 = module to scan. Prints each stray read; non-zero if any.
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

# ...and the SCAN ITSELF is proven, in both directions, against a copy of the
# module: a widened pattern asserted rather than demonstrated is how the first
# one shipped recognising a single verb.
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

# ...and the other direction, which is not hypothetical: PROSE mentioning a read
# must not be reported, or the rule cannot be written down beside itself. Both
# forms the module actually uses are here — a comment, and a docstring, which is
# where that module states nearly every rule it has and where a line-shaped scan
# reported a false breach.
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

# The runner fixture: an area that no row carries. Every docs row has to go, and
# the mutator asserts the area really is empty afterwards — naming one row holds
# only while `docs` has exactly one, and the second row VGS-124 briefly added is
# what stopped this fixture and the one above from emptying anything.
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
# check — the guard correctly fails on the missing prerequisite instead. That
# makes this control UNCREATABLE rather than passing, so the else arm is a skip
# and not an `ok`: it reported one for as long as it existed, which is the same
# false green the skip machinery above exists to close, reached through the
# prerequisite instead of through a locale.
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

# THE TWO READERS, COMPARED TO EACH OTHER on the same row — not each against
# its own expectation, since two readers checked only against expectations can
# both be wrong in the same direction. `may-skip,may-skip` is the case that
# proves it: the python side collapsed a row's tags with set() and the runner
# did not, so the same row was "cannot stand alone" to one and "carries no
# selector" to the other. Length now comes from the list, membership from a set.
agree_probe="$fixture_dir/scripts/agree-probe"
# A FUNCTION, so the table below is not the only way in: two of these rows carry
# a CONTROL CHARACTER, which a quoted heredoc cannot express and an unquoted one
# would only express by turning every other row into an expansion.
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

# AGREEMENT IS ONLY HALF OF WHAT THE CONTROL ROWS BELOW NEED. Two readers that
# both REFUSED `qml\x0b` would agree perfectly while the shared whitespace set
# was broken in exactly the direction those rows exist to catch, so the row must
# also be TAKEN — and the command LISTED — by each reader.
agree_accepts() {
  local row_tags="$1" label="${2:-$1}" rc=0 listed library
  agree_row "$row_tags" "$label" # ...which is what writes $agree_probe
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

# THE LINE BOUNDARY IS PART OF C4, and these are the rows that prove it. Sharing
# the whitespace set settled which characters are STRIPPED; it said nothing about
# where a row ENDS. `str.splitlines()` breaks on \v and \f — two of the six
# characters in that same set — so a row tagged `qml\x0b` was one line to the
# runner, which stripped it to `qml` and RAN the command, and two lines to the
# library, whose first had no `|` and was refused as a row with no separator.
# \r is the third: `Path.read_text()` opens in universal-newline mode, so the
# split never saw it — the row arrived here already broken in two, one layer
# below the boundary the \v fix moved. The runner is the authority on both
# questions, so both readers must take these rows.
for control in '\v' '\f' '\r'; do
  printf -v control_tags 'qml%b' "$control"
  agree_accepts "$control_tags" "qml followed by a literal $control"
done
ok "a row tagged with a \\v, \\f or \\r is one row to both readers, and taken by both"

# THE DUMP IS THE SECOND CHANNEL WITH THE SAME BOUNDARY, and it had no control
# at all: reverting `Grammar._decode`'s `dump.split("\n")` to splitlines() left
# the whole suite green. A message text carrying one of these characters is ONE
# dump line to the runner and TWO to a reader that ends a line there, whose tail
# is refused as an unknown dump line kind — a refusal aimed at the wrong thing,
# against a grammar the runner accepted.
#
# BOTH HALVES OF THE BOUNDARY ARE HERE, because they break at different layers:
# splitlines() ends a line on \v, and `text=True` capture ends one on \r before
# the decoder is ever reached. Driven through the real runner rather than a
# hand-built dump, so the emission path is exercised too.
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
  # The character must actually REACH the dump, or the decode below proves
  # nothing about where the decoder ends a line.
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
#
# BOUNDED, not exhaustive. This iterated every UTF-8 locale `locale -a` reports
# × 3 codepoints × 2 readers, which on a locale-rich system is minutes of
# subprocesses and a diagnostic nobody reads — while proving nothing the second
# locale had not already proven. What the control needs is ONE locale that is not
# C, since the property under test is "the rule survives a locale that resolves
# character classes differently", so it takes at most two: the preferred locale
# when present, plus one more as a hedge against that one behaving like C.
# Selection is deterministic (sorted, preferred name first) so a failure here
# reproduces.
LOCALE_SAMPLE=2
PREFERRED_LOCALE=en_US.utf8
locales=()
utf8_locales=()
c_locales=()
while IFS= read -r loc; do
  case "$loc" in
    # `C.utf8` is RANKED LAST, not disqualified. It was written here as the one
    # UTF-8 locale that cannot demonstrate a locale-resolved class, and that is
    # measurably false on this glibc: with the runner's tag strip reverted to
    # `[[:space:]]`, plain C refused a U+2002-tagged row while C.utf8 accepted
    # it, exactly as en_US.utf8 did — modern glibc derives C.utf8's LC_CTYPE
    # from Unicode. So it is a working control and is kept as a fallback; a
    # named regional locale simply comes first, for reproducibility and because
    # older glibc and musl may resolve C.utf8 like C. Whether a selected locale
    # ACTUALLY resolves the class is measured below rather than inferred from
    # its name, so this ordering cannot decide the verdict either way.
    C.utf8 | C.UTF-8) c_locales+=("$loc") ;;
    *.utf8 | *.UTF-8) utf8_locales+=("$loc") ;;
  esac
done < <(locale -a 2>/dev/null | LC_ALL=C sort)
utf8_locales+=("${c_locales[@]}")
for loc in "$PREFERRED_LOCALE" "${utf8_locales[@]}"; do
  [[ ${#locales[@]} -lt $LOCALE_SAMPLE ]] || break
  # The preferred name is a CANDIDATE, not an assumption: it is taken only if
  # this system actually provides it, and skipped silently otherwise.
  printf '%s\n' "${utf8_locales[@]}" | grep -qxF -- "$loc" || continue
  printf '%s\n' "${locales[@]}" | grep -qxF -- "$loc" && continue
  locales+=("$loc")
done

# A SAMPLE THAT RESOLVES NOTHING IS A SKIP, NOT A PASS — and whether it resolves
# anything is MEASURED, never inferred from the locale's name. The first version
# of this asked "are they all named C.*", which is the same guess the comment
# above got wrong; a name-based answer would call a working C.utf8 control a
# skip on one libc and miss a genuinely inert locale on another.
#
# The probe is the property under test, one layer down: does `[[:space:]]`
# swallow a character that is whitespace only in Unicode? The input is written as
# raw UTF-8 BYTES rather than with printf's \u, so the same bytes are fed to
# every locale — under C, ` ` would not even encode the same way.
locale_resolves_class() { # $1 locale
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
  # NAMED, not substituted. A weaker test passing here would assert that the
  # rule holds under a locale nobody exercised.
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

# CI LOCKSTEP FOR A MANIFEST ROW OUTSIDE scripts/. The scripts/-keyed arm walks
# executable_checks(), so a row naming a rendered engine was compared against
# ci.yml by nothing at all — its workflow step could be deleted with the guard
# still green. The fixture adds one such row for a real, executable file ci.yml
# does not run; the unmutated control below is the other polarity.
offtree_runner="$tmp/offtree-runner"
awk '/^MANIFEST_EOF$/ && !seen {
  print "-         | .agents/skills/worktree/scripts/worktree"; seen = 1
} { print }' "$runner" >"$offtree_runner"
chmod +x "$offtree_runner"
run_guard "RUNNER_PATH=$offtree_runner"
expect_refused "off-tree manifest row" "which .github/workflows/ci.yml does not"
ok "a manifest row outside scripts/ that ci.yml never runs is reported"

# MENTIONING A PATH IS NOT RUNNING IT. The CI half of both lockstep arms asked
# `path in ci_text`, a substring test over the concatenated `run:` blocks, so a
# workflow that stopped invoking a lane kept the guard green as long as the path
# survived anywhere. ONE SHAPE PER CASE, because a single fixture carrying all
# three would pass while two of them regressed: the argument, the trailing
# comment that ci_run_commands' whole-line filter does not reach, and the
# separator inside a quoted string that defeated the first repair's line
# splitting, the two the tokenizing repair still got wrong — a redirection
# TARGET (`: > <path>` truncates the file and runs nothing) and a function
# DEFINITION (`<path>() { :; }` defines a name, it does not call one) — and two
# where the path IS a command that may never run — the right side of `||`, and a
# conditional body — and an array ELEMENT, which is data. Each is the real ci.yml
# with one step's invocation replaced, so the fixtures track the workflow rather
# than restating it.
#
# THE HEREDOC TERMINATOR CASE IS SEPARATE, below, because its shape needs three
# lines rather than one and the loop above substitutes a single line.
while IFS='|' read -r shape replacement; do
  [[ -n "$shape" ]] || continue
  doctored="$tmp/ci-$shape.yml"
  SHAPE_REPLACEMENT="$replacement" python3 - "$repo_root" "$doctored" <<'MENTION_ONLY'
import os, pathlib, sys
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
step = "        run: .agents/skills/size-ratchet/scripts/size-ratchet\n"
if step not in text:
    sys.exit("the size-ratchet ci.yml step these fixtures doctor has moved")
body = os.environ["SHAPE_REPLACEMENT"].replace("@", ".agents/skills/size-ratchet/scripts/size-ratchet")
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

# A HEREDOC BODY IS DATA, and its terminator is matched by the shell's rule, not
# by a trimmed comparison. `<<EOF` closes on a line that is EXACTLY the
# delimiter; a space-indented look-alike is body text. Trimming closed the body
# early and read the real data lines after it as commands, so a lane replaced by
# this shape stayed covered.
heredoc_ci="$tmp/ci-heredoc-terminator.yml"
python3 - "$repo_root" "$heredoc_ci" <<'HEREDOC_SHAPE'
import pathlib, sys
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = (root / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
step = "        run: .agents/skills/size-ratchet/scripts/size-ratchet\n"
if step not in text:
    sys.exit("the size-ratchet ci.yml step these fixtures doctor has moved")
# The space before the first EOF is the whole point: bash keeps reading.
out.write_text(text.replace(step,
    "        run: |\n"
    "          cat <<EOF\n"
    "           EOF\n"
    "          .agents/skills/size-ratchet/scripts/size-ratchet\n"
    "          EOF\n", 1), encoding="utf-8")
HEREDOC_SHAPE
if [[ ! -s "$heredoc_ci" ]]; then
  fail "ci heredoc terminator" "the fixture workflow was not written (see the message above)"
else
  run_guard "CI_PATH=$heredoc_ci"
  expect_refused "ci heredoc terminator" "which .github/workflows/ci.yml does not"
  ok "a path inside a heredoc body is data, whatever the body looks like"
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
# 77, NOT 0, when a control could not be created: what ran passed, but something
# did NOT run, and the two must not report the same status. The names are
# repeated here because the notice above scrolls past in a long run.
if [[ $skips -ne 0 ]]; then
  printf 'test-validation-inventory: passed, %d skipped: %s\n' \
    "$skips" "$(IFS=', '; echo "${skipped_names[*]}")" >&2
  exit 77
fi
echo "test-validation-inventory: all checks passed"
