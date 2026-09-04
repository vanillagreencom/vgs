#!/usr/bin/env bash
# Check direct shell-launch instructions and compare live session resources around the canonical smoke.
# A direct shell launch can duplicate lock surfaces and obscure the live session.
# Usage: scripts/check-validation-safety.sh [--nested] [--self-test]; --self-test runs the detector fixtures and exits.
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



detector_rc=0
SELF_TEST="$self_test" python3 - <<'PY' || detector_rc=$?
import os
import re
import subprocess
import sys

# A negated mention can describe the launch prohibition. Fenced commands remain instructions.
LAUNCH = re.compile(r"qs\s+(?:-c\s+vshell|-p\s+\S*quickshell/vshell)")
NEGATED = re.compile(r"never|do not|don't|must not|refus|instead of|rather than", re.IGNORECASE)

# Negation applies to one sentence. Split on sentence-ending punctuation followed by whitespace;
# colons and dashes continue its clause, while a filename dot is not a sentence boundary.
SENTENCE_SPLIT = re.compile(r"(?<=[.;!?])\s+")

# Exempt only exact sanctioned occurrences containing a launch command.
# Recheck the remaining line so an appended instruction or neighboring line cannot inherit exemption.
# The entries cover nested launch text, greeter fixtures, and a wrapped bot prohibition.
ALLOWED_CONTEXTS = {
    "backend/internal/runner/runner.go": (
        "extra args appended after `qs -c vshell`",
        "otherwise `qs -c vshell` (with VGS_SOCKET",
    ),
    "scripts/check-vshell-helper.py": (
        "/usr/bin/qs -p /var/cache/vshell-greeter/runtime/quickshell/vshell",
        # Use one span for overlapping command examples so deletion offsets cannot conflict.
        "Config-path matching covers `qs -c vshell` vs `qs -p quickshell/vshell`",
    ),
    ".coderabbit.yaml": (
        "`qs -p quickshell/vshell`. Each starts a second full shell",
    ),
}


def exemption_defects():
    """Exemptions that do not contain the command they claim to sanction.

    Deleting such a span removes only prose, so it can never exempt anything and
    the line it was written for is reported anyway. Failing loudly points at that
    mistake, instead of leaving someone to "fix" the false positive by going back
    to skipping the whole matched line — which is the bypass this shape removes.
    """
    return [(path, span)
            for path, spans in ALLOWED_CONTEXTS.items()
            for span in spans
            if not LAUNCH.search(span)]


# Detector fixtures must spell the prohibited commands they test.
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
        # Remove only the accepted span on this line, then inspect remaining instructions.
        remainder = line
        for span in allowed:
            remainder = remainder.replace(span, " ")
        if not LAUNCH.search(remainder):
            continue
        # Negation qualifies its sentence only. Inside a fence, command lines are treated as runnable.
        if not fenced:
            unnegated = [
                clause for clause in SENTENCE_SPLIT.split(remainder)
                if LAUNCH.search(clause) and not NEGATED.search(clause)
            ]
            if not unnegated:
                continue
        hits.append(number)
    return hits


FIXTURES = [
    ("doc.md", ["```bash", "qs -c vshell", "```"], [2]),
    ("doc.md", ["Never run `qs -c vshell` in a live session."], []),
    # An earlier negated sentence cannot excuse a later instruction.
    ("doc.md", ["Never run `qs -c vshell`. Now run `qs -c vshell`."], [1]),
    ("doc.md", ["Never run `qs -c vshell`; now run `qs -c vshell`."], [1]),
    # A harmless later sentence must still pass so splitting cannot turn every negation into failure.
    ("doc.md", ["Never run `qs -c vshell`. Use scripts/qml-smoke.sh instead."], []),

    ("doc.md", ["Never do this: `qs -c vshell` starts a second full instance."], []),
    ("doc.md", ["Never do this — `qs -c vshell` starts a second full instance."], []),

    ("doc.md", ["Use scripts/qml-smoke.sh rather than `qs -c vshell`."], []),
    ("doc.md", ["Smoke with `qs -c vshell` before finishing."], [1]),
    ("doc.md", ["```bash", "qs -p /home/me/dev/vgs/quickshell/vshell", "```"], [2]),
    ("skill.md", ["Use scripts/qml-smoke.sh; do not run `qs -p quickshell/vshell`."], []),
    ("notes.txt", ["qs -c vshell"], [1]),
    ("greeter.py", ['cmd = "/usr/bin/qs -p /var/cache/vshell-greeter/runtime"'], []),

    ("backend/internal/runner/runner.go", [
        "// QSArgs are extra args appended after `qs -c vshell`.",
        "// smoke it yourself with qs -c vshell",
    ], [2]),
    # A neighboring line's exemption must not cover a wrapped instruction.
    ("quickshell/vshell/shell.qml", [
        "// this is the runtime backstop for someone who runs",
        "// `qs -c vshell` by hand rather than the script.",
        "//   qs -c vshell",
    ], [3]),
    # Accept the sanctioned continuation but reject another instruction in that file.
    (".coderabbit.yaml", [
        "        `qs -p quickshell/vshell`. Each starts a second full shell in the live",
        "        Validate QML with `qs -c vshell`.",
    ], [2]),
    # Append an instruction to each accepted line to verify occurrence-only exemption.
    (".coderabbit.yaml", [
        "        `qs -p quickshell/vshell`. Each starts a second full shell in the live",
        "        `qs -p quickshell/vshell`. Each starts a second full shell in the live; to validate, run qs -c vshell",
    ], [2]),
    ("backend/internal/runner/runner.go", [
        "\t// QSArgs are extra args appended after `qs -c vshell`.",
        "\t// QSArgs are extra args appended after `qs -c vshell`. To try it: qs -c vshell",
    ], [2]),

    ("scripts/check-vshell-helper.py", [
        "        # Config-path matching covers `qs -c vshell` vs `qs -p quickshell/vshell`.",
        "        # Config-path matching covers `qs -c vshell` vs `qs -p quickshell/vshell`. Try qs -c vshell.",
    ], [2]),
]

# Test valid exemptions and an invalid span lacking a command so validation must reject one.
DEFECT_FIXTURES = [
    ("`qs -p quickshell/vshell`. Each starts a second full shell", True),
    ("extra args appended after `qs -c vshell`", True),
    ("`qs -c vshell` vs `qs -p quickshell/vshell`", True),
    ("VGS_BACKEND_LISTEN_FD", False),
    ("the sanctioned smoke is scripts/validate qml", False),
]

if os.environ.get("SELF_TEST") == "true":
    failed = False
    for path, lines, expected in FIXTURES:
        actual = scan(path, lines)
        if actual != expected:
            failed = True
            print(f"self-test: {path} {lines!r}: expected {expected}, got {actual}", file=sys.stderr)
    for span, spans_a_command in DEFECT_FIXTURES:
        if bool(LAUNCH.search(span)) != spans_a_command:
            failed = True
            print(f"self-test: exemption span {span!r}: expected spans_a_command={spans_a_command}", file=sys.stderr)
    for path, span in exemption_defects():
        failed = True
        print(f"self-test: exemption for {path} names no command: {span!r}", file=sys.stderr)
    if failed:
        sys.exit(1)
    print(f"self-test: instruction detector passed ({len(FIXTURES)} fixtures, {len(DEFECT_FIXTURES)} exemption spans)")
    sys.exit(0)

# Report an exemption missing its command as a broken entry before it creates a misleading scan finding.
defects = exemption_defects()
for path, span in defects:
    print(f"exemption for {path} names no launch command: {span!r}", file=sys.stderr)
if defects:
    sys.exit(3)

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
# Status 2 means policy findings. Other nonzero statuses mean scanner failure, not a clean scan or violation.
sys.exit(2 if violations else 0)
PY
# Inside an if ! branch, $? is the negated status. Capture the original status before branching.
if [[ "$detector_rc" == 2 ]]; then
  fail "unsafe direct shell launch instructions found (use scripts/qml-smoke.sh)"
elif [[ "$detector_rc" == 3 ]]; then
  fail "an exemption names no launch command, so it exempts nothing (see above)"
elif [[ "$detector_rc" != 0 ]]; then
  fail "the instruction detector could not run (exit $detector_rc)"
fi

if [[ "$self_test" == true ]]; then
  # The surface comparison must tolerate the live shell's normal popup churn
  # while still catching a duplicated or orphaned surface.
  self_before="$(printf 'DP-1\tvshell:bar\nDP-1\tvshell:vgs-menu\nDP-2\tvshell:bar')"
  if ! vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:bar\nDP-2\tvshell:bar')"; then
    fail "self-test: a closed popup must not read as damage"
  fi
  if vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:bar\nDP-1\tvshell:bar\nDP-2\tvshell:bar')" 1 2>/dev/null; then
    fail "self-test: a second surface with one live shell must be caught"
  fi
  # The live shell can raise its own lock surface when the seat idles.
  if ! vgs_layers_regressed "$self_before" "$(printf 'DP-1\tvshell:bar\nDP-1\tvshell:fade-to-lock\nDP-2\tvshell:bar')" 1 2>/dev/null; then
    fail "self-test: one shell's own overlay must not read as damage"
  fi
  # Duplicate lock surfaces must fail even if the process count is unchanged.
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

# More lock overlays than monitors can indicate orphaned surfaces.
overlays="$(printf '%s\n' "$layers_after" | grep -c 'vshell:fade-to-lock' || true)"
if [[ "$overlays" -gt 0 ]]; then
  monitors="$(hyprctl monitors -j 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
  if [[ "$monitors" -gt 0 ]]; then
    if [[ "$overlays" -gt "$monitors" ]]; then
      fail "orphaned fade-to-lock surfaces: $overlays across $monitors monitors"
    fi
  else
    # A skipped comparison cannot establish whether preexisting overlays remain.
    note "could not count monitors; the orphaned-overlay check did not run"
  fi
fi

if [[ "$status" -eq 0 ]]; then
  note "ok"
fi
exit "$status"
