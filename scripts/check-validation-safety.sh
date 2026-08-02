#!/usr/bin/env bash
# Regression guard for the validation path itself.
#
# 1. No repo instruction (docs, agent guidance, scripts) may tell anyone to
#    launch the VGS shell directly with `qs -c vshell` / `qs -p quickshell/vshell`.
#    That is how a validation run ends up with duplicate full-screen
#    fade-to-lock surfaces and a black live session.
# 2. Running the canonical smoke must leave the live session unchanged: same
#    VGS Quickshell instances, same VGS layer surfaces, no strays.
#
# Usage: scripts/check-validation-safety.sh [--nested] [--self-test]
#   --self-test  exercise the instruction detector against fixtures and exit
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

self_test=false
smoke_args=()
for arg in "$@"; do
  case "$arg" in
    --self-test) self_test=true ;;
    *) smoke_args+=("$arg") ;;
  esac
done
status=0
fail() { printf 'check-validation-safety: FAIL: %s\n' "$*" >&2; status=1; }
note() { printf 'check-validation-safety: %s\n' "$*"; }

# shellcheck source=scripts/lib/session-snapshot.sh
source "$repo_root/scripts/lib/session-snapshot.sh"

# --- 1. no unsafe launch instructions ---------------------------------------

# Files that legitimately mention a direct launch: the CLI fallback that *is*
# the session shell, the runner that spawns it, and the greeter command
# fixtures (a greeter runs from /var/cache, never against a live session).
allowed_paths=(
  "bin/vshell"
  "backend/internal/runner/runner.go"
  "docs/architecture/backend-daemon.md"
  "scripts/check-vshell-helper.py"
  "scripts/check-vshell-niri.py"
  "scripts/qml-smoke.sh"
  "scripts/check-validation-safety.sh"
  "quickshell/vshell/shell.qml"
)

if ! ALLOWED_PATHS="$(printf '%s\n' "${allowed_paths[@]}")" SELF_TEST="$self_test" python3 - <<'PY'
import os
import re
import subprocess
import sys

# A mention is fine only when it tells the reader NOT to do it. Anything inside
# a fenced code block is a runnable instruction and is never fine.
LAUNCH = re.compile(r"qs\s+(?:-c\s+vshell|-p\s+\S*quickshell/vshell)")
NEGATED = re.compile(r"never|do not|don't|must not|refus|instead of|rather than", re.IGNORECASE)


def scan(path, lines):
    """Line numbers in `lines` that instruct a direct shell launch."""
    hits = []
    fenced = False
    for number, line in enumerate(lines, 1):
        if path.endswith(".md") and line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if not LAUNCH.search(line):
            continue
        if not fenced and NEGATED.search(line):
            continue
        hits.append(number)
    return hits


FIXTURES = [
    ("doc.md", ["```bash", "qs -c vshell", "```"], [2]),
    ("doc.md", ["Never run `qs -c vshell` in a live session."], []),
    ("doc.md", ["Smoke with `qs -c vshell` before finishing."], [1]),
    ("doc.md", ["```bash", "qs -p /home/me/dev/vgs/quickshell/vshell", "```"], [2]),
    ("skill.md", ["Use scripts/qml-smoke.sh; do not run `qs -p quickshell/vshell`."], []),
    ("notes.txt", ["qs -c vshell"], [1]),
    ("greeter.py", ['cmd = "/usr/bin/qs -p /var/cache/vshell-greeter/runtime"'], []),
]

if os.environ.get("SELF_TEST") == "true":
    failed = False
    for path, lines, expected in FIXTURES:
        actual = scan(path, lines)
        if actual != expected:
            failed = True
            print(f"self-test: {path} {lines!r}: expected {expected}, got {actual}", file=sys.stderr)
    if failed:
        sys.exit(1)
    print(f"self-test: instruction detector passed ({len(FIXTURES)} fixtures)")
    sys.exit(0)

allowed = {line for line in os.environ["ALLOWED_PATHS"].splitlines() if line}
tracked = subprocess.run(["git", "ls-files"], text=True, stdout=subprocess.PIPE, check=True).stdout.split()

violations = []
for path in tracked:
    if path in allowed or path.startswith("trees/") or os.path.islink(path):
        continue
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except (OSError, UnicodeDecodeError):
        continue
    for number in scan(path, lines):
        violations.append(f"{path}:{number}:{lines[number - 1].strip()}")

for violation in violations:
    print(violation, file=sys.stderr)
sys.exit(1 if violations else 0)
PY
then
  fail "unsafe direct shell launch instructions found (use scripts/qml-smoke.sh)"
fi

if [[ "$self_test" == true ]]; then
  # The surface comparison must tolerate the live shell's normal popup churn
  # while still catching a duplicated or orphaned surface.
  self_before="$(printf 'DP-1\tvshell:bar\nDP-1\tvshell:spotlight\nDP-2\tvshell:bar')"
  if ! vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:bar\nDP-2\tvshell:bar')"; then
    fail "self-test: a closed popup must not read as damage"
  fi
  if vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:bar\nDP-1\tvshell:bar\nDP-2\tvshell:bar')" 2>/dev/null; then
    fail "self-test: a duplicated surface must be caught"
  fi
  if vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:bar\nDP-1\tvshell:fade-to-lock\nDP-2\tvshell:bar')" 2>/dev/null; then
    fail "self-test: a new orphaned overlay must be caught"
  fi
  if [[ "$status" -eq 0 ]]; then
    note "self-test: surface comparison passed (3 fixtures)"
  fi
  exit "$status"
fi
if [[ "$status" -eq 0 ]]; then
  note "no unsafe 'qs' launch instructions in tracked guidance"
fi

# --- 2. the canonical smoke leaves no strays --------------------------------

instances_before="$(vgs_snapshot_instances)"
layers_before="$(vgs_snapshot_layers)"

smoke_status=0
./scripts/qml-smoke.sh "${smoke_args[@]}" || smoke_status=$?
if [[ "$smoke_status" -ne 0 ]]; then
  fail "scripts/qml-smoke.sh exited $smoke_status"
fi

instances_after="$(vgs_snapshot_instances)"
layers_after="$(vgs_snapshot_layers)"

if [[ "$instances_after" != "$instances_before" ]]; then
  printf -- '--- VGS instances before\n%s\n--- after\n%s\n' "$instances_before" "$instances_after" >&2
  fail "validation changed the live VGS Quickshell instance set"
else
  note "VGS Quickshell instances unchanged by validation"
fi

if vgs_layers_regressed "$layers_before" "$layers_after"; then
  note "no VGS layer surface multiplied during validation"
else
  fail "validation multiplied live VGS layer surfaces (duplicate shell or orphaned overlay)"
fi

# The specific incident signature: more fade-to-lock overlays than monitors.
overlays="$(printf '%s\n' "$layers_after" | grep -c 'vshell:fade-to-lock' || true)"
if [[ "$overlays" -gt 0 ]]; then
  monitors="$(hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
  if [[ "$monitors" -gt 0 && "$overlays" -gt "$monitors" ]]; then
    fail "orphaned fade-to-lock surfaces: $overlays across $monitors monitors"
  fi
fi

if [[ "$status" -eq 0 ]]; then
  note "ok"
fi
exit "$status"
