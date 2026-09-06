#!/usr/bin/env bash
# Shared fixtures and assertions for the suites that drive scripts/validate,
# scripts/lib/validation_manifest.py and scripts/check-validation-inventory.py.
# Sourcing this installs the temporary tree, its trap, the failure counters and the
# guard drivers; `finish <suite>` reports and exits.
# The suite CI runs last sets SKIPS_ALLOWED=1 before sourcing; in every other suite a
# `skip` call is a failure, so only that one can exit 77.

# The fixtures below abort on an unchecked failure rather than run on a half-built tree.
# A sourced file cannot assume the caller chose that mode, so state it here.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/scripts/validate"
# An empty tmp would root every fixture path at the filesystem root, so name the cause.
tmp="$(mktemp -d)" || {
  printf 'validation-testkit: could not create a temporary directory\n' >&2
  exit 1
}
fixture_dir="$tmp/fixture"
mkdir -p "$fixture_dir/scripts/lib"
trap 'rm -rf "${tmp:?}"' EXIT INT TERM

failures=0
case_failed=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
  case_failed=1
}
# An uncreatable control returns skip status rather than passing, and 77 is a failure to both
# consumers: no manifest row here carries `may-skip`, and CI must not read it as success. Only
# the suite CI runs last can report it without hiding the steps that would have followed.
SKIPS_ALLOWED="${SKIPS_ALLOWED:-0}"
skips=0
skipped_names=()
skip() { # Report an uncreatable control by name and reason. Missing arguments are a fixture defect
# and must fail rather than crash during the reporting path or excuse themselves as a skip.
  if [[ $# -lt 2 ]]; then
    fail "skip helper" "skip was called with no reason for \`${1:-<no control name>}\`, so nothing could be reported about it"
    return 0
  fi
  if [[ "$SKIPS_ALLOWED" != 1 ]]; then
    fail "$1" "this suite is not the one CI runs last, so a control it cannot create is a failure rather than a skip: $2"
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

finish() { # Report the named suite's collected failures or skips and exit with its status.
  if [[ $failures -ne 0 ]]; then
    printf '\n%s: %d failure(s)\n' "$1" "$failures" >&2
    exit 1
  fi
  # Record skipped control names with status 77 so an uncreatable case cannot report complete success.
  if [[ $skips -ne 0 ]]; then
    printf '%s: passed, %d skipped: %s\n' \
      "$1" "$skips" "$(IFS=', '; echo "${skipped_names[*]}")" >&2
    exit 77
  fi
  printf '%s: all checks passed\n' "$1"
}

# Import the readers under test from one place so each fixture's Python states only its own case.
# The guard driver below keeps its own loader because its fixtures replace PYTHONPATH to hide PyYAML.
testkit_pylib="$tmp/pylib"
mkdir -p "$testkit_pylib"
cat >"$testkit_pylib/vgstk.py" <<'TESTKIT_PY'
"""Import the validation readers from a repository checkout under test."""

import importlib.util
import pathlib


def _load(root, relative, name):
    spec = importlib.util.spec_from_file_location(name, pathlib.Path(root) / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def manifest_module(root):
    """Return scripts/lib/validation_manifest.py as loaded from `root`."""
    return _load(root, "scripts/lib/validation_manifest.py", "vm")


def guard_module(root):
    """Return scripts/check-validation-inventory.py as loaded from `root`."""
    return _load(root, "scripts/check-validation-inventory.py", "inv")
TESTKIT_PY
export PYTHONPATH="$testkit_pylib${PYTHONPATH:+:$PYTHONPATH}"

# Derive shared diagnostics from the grammar so a clean run's exclusions come from the artifact
# under test rather than from a second list kept in a suite.
ARM_MESSAGES=()
while IFS= read -r text; do
  [[ -n "$text" ]] && ARM_MESSAGES+=("$text")
done < <(sed -n 's/^message  *[a-z-]*  *//p' "$repo_root/scripts/lib/validation-grammar.conf")

# Guard-only diagnostics are checked against their emitting source by assert_fragments_live.
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

assert_fragments_live() { # Require every fragment a clean run excludes to be one a reader still emits.
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
}

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
    rm -rf "${tmp:?}/paired"
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

# Build a runner fixture and require the expected refusal.
guard_case() {
  local name="$1" probe="$tmp/probe-runner"
  printf '%s' "$2" >"$probe"
  chmod +x "$probe"
  run_guard "RUNNER_PATH=$probe"
  expect_refused "$name" "$3"
  ok "$name"
}

# The three fixtures below are the sourcing suite's mutation bases, read there and not here.
# shellcheck disable=SC2034  # read by the sourcing suite
real_runner="$(cat "$runner")"
# shellcheck disable=SC2034  # read by the sourcing suite
real_grammar="$(cat "$repo_root/scripts/lib/validation-grammar.conf")"
# A token class with no selection or skip properties models an unwired token.
# shellcheck disable=SC2034  # read by the sourcing suite
INERT_CLASS="class inert      selects=no  standalone=no  rowtag=yes exclusive=no  cli=no  universal=no  skips=no  min=0"
