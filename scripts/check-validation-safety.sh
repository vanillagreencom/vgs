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
vgs_snapshot_prefix="check-validation-safety: "

# --- 1. no unsafe launch instructions ---------------------------------------

detector_rc=0
SELF_TEST="$self_test" python3 - <<'PY' || detector_rc=$?
import os
import re
import subprocess
import sys

# A mention is fine only when it tells the reader NOT to do it. Anything inside
# a fenced code block is a runnable instruction and is never fine.
LAUNCH = re.compile(r"qs\s+(?:-c\s+vshell|-p\s+\S*quickshell/vshell)")
NEGATED = re.compile(r"never|do not|don't|must not|refus|instead of|rather than", re.IGNORECASE)

# Exemptions are scoped to the exact line context, never to a whole file: a new
# unsafe instruction added to one of these files must still be caught. Each
# entry lists substrings that identify the known-good lines — the runner
# describing the child it spawns, the guard explaining what it exists to stop,
# and the greeter fixtures (a greeter runs from /var/cache, never against a
# live session).
ALLOWED_CONTEXTS = {
    "backend/internal/runner/runner.go": (
        "QSArgs are extra args",
        "otherwise `qs -c vshell`",
    ),
    "docs/architecture/backend-daemon.md": (
        "VGS_BACKEND_LISTEN_FD",
    ),
    # shell.qml's guard comment carries its own "rather than" on the matched
    # line, so it needs no per-file exemption at all.
    "scripts/check-vshell-helper.py": (
        "/var/cache/vshell-greeter",
        "Config-path matching covers",
    ),
}

# This script defines the rule, so its own header and detector fixtures have to
# spell the forbidden commands out.
SELF_PATH = "scripts/check-validation-safety.sh"


def scan(path, lines):
    """Line numbers in `lines` that instruct a direct shell launch."""
    allowed = ALLOWED_CONTEXTS.get(path, ())
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
        # Matched per line, never over a window: a neighbouring exempt line must
        # not launder a new instruction next to it. Prose that wraps away from
        # its exempting phrase is reworded instead.
        if any(context in line for context in allowed):
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
    # A scoped exemption must not blanket the rest of its file.
    ("backend/internal/runner/runner.go", [
        "// QSArgs are extra args appended after `qs -c vshell`.",
        "// smoke it yourself with qs -c vshell",
    ], [2]),
    # A wrapped comment must carry its own exemption on the matched line; an
    # exempt neighbour must not launder the line below it.
    ("quickshell/vshell/shell.qml", [
        "// this is the runtime backstop for someone who runs",
        "// `qs -c vshell` by hand rather than the script.",
        "//   qs -c vshell",
    ], [3]),
    ("docs/architecture/backend-daemon.md", [
        "```text",
        "(VGS_BACKEND_LISTEN_FD), then spawn `qs -c vshell` as a child",
        "qs -c vshell",
        "```",
    ], [3]),
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

tracked = subprocess.run(["git", "ls-files"], text=True, stdout=subprocess.PIPE, check=True).stdout.split()

violations = []
for path in tracked:
    if path == SELF_PATH or path.startswith("trees/") or os.path.islink(path):
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
# 2 == policy violations found. Any other non-zero status is the scanner itself
# failing (unreadable tree, git missing) and must not be reported as a clean
# bill of health *or* as a violation.
sys.exit(2 if violations else 0)
PY
# $? inside an `if ! cmd` branch is the negation's status, not the command's, so
# the status is captured directly above.
if [[ "$detector_rc" == 2 ]]; then
  fail "unsafe direct shell launch instructions found (use scripts/qml-smoke.sh)"
elif [[ "$detector_rc" != 0 ]]; then
  fail "the instruction detector could not run (exit $detector_rc)"
fi

if [[ "$self_test" == true ]]; then
  # The surface comparison must tolerate the live shell's normal popup churn
  # while still catching a duplicated or orphaned surface.
  self_before="$(printf 'DP-1\tvshell:bar\nDP-1\tvshell:spotlight\nDP-2\tvshell:bar')"
  if ! vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:bar\nDP-2\tvshell:bar')"; then
    fail "self-test: a closed popup must not read as damage"
  fi
  if vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:bar\nDP-1\tvshell:bar\nDP-2\tvshell:bar')" 1 2>/dev/null; then
    fail "self-test: a second surface with one live shell must be caught"
  fi
  # One shell raising its own fade-to-lock when the seat idles is normal.
  if ! vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:bar\nDP-1\tvshell:fade-to-lock\nDP-2\tvshell:bar')" 1 2>/dev/null; then
    fail "self-test: one shell's own overlay must not read as damage"
  fi
  # ...but two of them with only one shell running cannot be.
  if vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:fade-to-lock\nDP-1\tvshell:fade-to-lock')" 1 2>/dev/null; then
    fail "self-test: a doubled overlay must be caught"
  fi
  # An unreadable snapshot must never be mistaken for "nothing changed".
  if vgs_compare_snapshots "probe" "a" 0 "" 1 exact 2>/dev/null; then
    fail "self-test: a failed post-validation snapshot must not pass"
  fi
  if vgs_compare_snapshots "probe" "" 1 "a
b" 0 exact 2>/dev/null; then
    fail "self-test: a failed baseline must not discard visible damage"
  fi
  if vgs_compare_snapshots "probe" "a" 0 "" 2 exact 2>/dev/null; then
    fail "self-test: a registry that vanished mid-run must not pass"
  fi
  if ! vgs_compare_snapshots "probe" "" 2 "" 2 exact >/dev/null 2>&1; then
    fail "self-test: nothing to collect must skip, not fail"
  fi
  if [[ "$status" -eq 0 ]]; then
    note "self-test: surface and snapshot comparison passed (8 fixtures)"
  fi
  exit "$status"
fi
if [[ "$status" -eq 0 ]]; then
  note "no unsafe 'qs' launch instructions in tracked guidance"
fi

# --- 2. the canonical smoke leaves no strays --------------------------------

instances_before="$(vgs_snapshot_instances)" && instances_before_status=0 || instances_before_status=$?
layers_before="$(vgs_snapshot_layers)" && layers_before_status=0 || layers_before_status=$?

smoke_status=0
./scripts/qml-smoke.sh "${smoke_args[@]}" || smoke_status=$?
if [[ "$smoke_status" -ne 0 ]]; then
  fail "scripts/qml-smoke.sh exited $smoke_status"
fi

instances_after="$(vgs_snapshot_instances)" && instances_after_status=0 || instances_after_status=$?
layers_after="$(vgs_snapshot_layers)" && layers_after_status=0 || layers_after_status=$?

vgs_compare_snapshots "VGS Quickshell instances" \
  "$instances_before" "$instances_before_status" \
  "$instances_after" "$instances_after_status" exact || status=1
vgs_compare_snapshots "VGS layer surfaces" \
  "$layers_before" "$layers_before_status" \
  "$layers_after" "$layers_after_status" growth \
  "$(printf '%s' "$instances_after" | grep -c . || true)" || status=1

# The specific incident signature: more fade-to-lock overlays than monitors.
overlays="$(printf '%s\n' "$layers_after" | grep -c 'vshell:fade-to-lock' || true)"
if [[ "$overlays" -gt 0 ]]; then
  monitors="$(hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
  if [[ "$monitors" -gt 0 ]]; then
    if [[ "$overlays" -gt "$monitors" ]]; then
      fail "orphaned fade-to-lock surfaces: $overlays across $monitors monitors"
    fi
  else
    # This is the only check that catches overlays orphaned before the run, so
    # say when it could not run rather than passing silently.
    note "could not count monitors; the orphaned-overlay check did not run"
  fi
fi

if [[ "$status" -eq 0 ]]; then
  note "ok"
fi
exit "$status"
