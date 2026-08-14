#!/usr/bin/env python3
"""Pin the wiring that makes paste land the right keystroke in the right window.

`scripts/test-paste-target.js` covers the resolver, which is pure JS. Nothing
else covers the QML that calls it: `scripts/qml-smoke.sh --nested` proves the
shell parses and starts, but it never opens the clipboard surface or the
launcher's paste path, so the injection site itself has no failing-test control.
Reverting it to a static `["wtype", "-M", "ctrl", ...]` argv, or leaving it
reading a focus property that no longer exists, would pass the entire suite
while every terminal paste misfires again — the exact bug VGS-119 fixed.

Four properties are pinned:

  1. No QML file runs wtype with a literal argv. The keystroke depends on the
     target, so a hard-coded one is wrong by construction wherever it appears.
  2. `PasteService` resolves the target and builds the argv from it, using the
     live focused app id with the sticky last-focused id as the fallback —
     focus returns asynchronously, so the live value is routinely empty at the
     moment the paste fires.
  3. The command assignment precedes `running = true`. Reversed, the process
     starts on the previous paste's argv.
  4. Neither caller keeps its own wtype process or paste timer. Two copies is
     how the original Ctrl+V bug came to exist in two places at once.

Exits non-zero naming the file and what it found.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
QML_ROOT = REPO / "quickshell" / "vshell"

OWNER = "quickshell/vshell/Services/PasteService.qml"
FOCUS_SOURCE = "quickshell/vshell/Services/CompositorService.qml"
CALLERS = [
    "quickshell/vshell/Services/ClipboardService.qml",
    "quickshell/vshell/Modules/WorkspaceOverlays/OverviewSearch/Controller.qml",
]

# A Process whose argv starts with wtype. `["sh", "-c", "command -v wtype"]` in
# SessionService is a probe for the binary, not an invocation of it, and does
# not match.
LITERAL_ARGV_RE = re.compile(r"command:\s*\[\s*\"wtype\"")

# The argv assignment, capturing the expression handed to the resolver so the
# next pattern can prove it is the resolved target rather than any string.
COMMAND_ASSIGN_RE = re.compile(r"wtypeProcess\.command\s*=\s*PasteTarget\.pasteCommand\(\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\)")
RUNNING_RE = re.compile(r"wtypeProcess\.running\s*=\s*true")
IMPORT_RE = re.compile(r"^import\s+\"PasteTarget\.js\"\s+as\s+PasteTarget\s*$", re.MULTILINE)


def target_expr_re(name: str) -> re.Pattern:
    """`name` bound to the live focused app id, falling back to the sticky one."""
    return re.compile(
        r"\b" + re.escape(name) + r"\s*=\s*CompositorService\.focusedAppId\s*\|\|\s*CompositorService\.lastFocusedAppId\b"
    )


def property_re(name: str) -> re.Pattern:
    return re.compile(r"^\s*(?:readonly\s+)?property\s+string\s+" + re.escape(name) + r"\b", re.MULTILINE)


def fail(message: str) -> bool:
    print(f"check-paste-injection: FAIL: {message}", file=sys.stderr)
    return False


def read(rel_path: str) -> str | None:
    path = REPO / rel_path
    if not path.is_file():
        fail(f"missing {rel_path}")
        return None
    return path.read_text()


def check_no_literal_argv() -> bool:
    offenders = sorted(
        str(path.relative_to(REPO))
        for path in QML_ROOT.rglob("*.qml")
        if LITERAL_ARGV_RE.search(path.read_text())
    )
    if offenders:
        return fail(
            "a wtype argv is hard-coded, so the keystroke ignores the target: "
            + ", ".join(offenders)
        )
    print("check-paste-injection: no QML file runs wtype with a literal argv")
    return True


def check_owner() -> bool:
    source = read(OWNER)
    if source is None:
        return False

    if not IMPORT_RE.search(source):
        return fail(f"{OWNER} does not import PasteTarget.js")

    assignment = COMMAND_ASSIGN_RE.search(source)
    if not assignment:
        return fail(f"{OWNER} does not build the wtype argv with PasteTarget.pasteCommand()")

    target = assignment.group(1)
    if not target_expr_re(target).search(source):
        return fail(
            f"{OWNER} passes '{target}' to PasteTarget.pasteCommand(), but never binds it to "
            "CompositorService.focusedAppId || CompositorService.lastFocusedAppId"
        )

    running = RUNNING_RE.search(source)
    if not running:
        return fail(f"{OWNER} never starts the wtype process")
    if running.start() < assignment.start():
        return fail(
            f"{OWNER} starts the wtype process before assigning its command, so it runs the "
            "previous paste's argv"
        )

    print(f"check-paste-injection: {OWNER} resolves the target, then assigns, then runs")
    return True


def check_focus_source() -> bool:
    source = read(FOCUS_SOURCE)
    if source is None:
        return False

    missing = [name for name in ("focusedAppId", "lastFocusedAppId") if not property_re(name).search(source)]
    if missing:
        return fail(f"{FOCUS_SOURCE} does not declare: " + ", ".join(missing))

    print(f"check-paste-injection: {FOCUS_SOURCE} publishes focusedAppId and lastFocusedAppId")
    return True


def check_callers() -> bool:
    ok = True
    for rel_path in CALLERS:
        source = read(rel_path)
        if source is None:
            ok = False
            continue
        if "PasteService.injectPaste()" not in source:
            ok = fail(f"{rel_path} does not paste through PasteService.injectPaste()")
            continue
        own_machinery = sorted({name for name in ("wtypeProcess", "pasteTimer") if name in source})
        if own_machinery:
            ok = fail(
                f"{rel_path} keeps its own paste machinery ({', '.join(own_machinery)}); "
                "PasteService is the single owner"
            )
            continue
        print(f"check-paste-injection: {rel_path} pastes through PasteService")
    return ok


def main() -> int:
    # Deliberately not short-circuiting: report every violation in one run.
    results = [check_no_literal_argv(), check_owner(), check_focus_source(), check_callers()]
    if all(results):
        print("check-paste-injection: ok")
        return 0

    print(
        "\n"
        "  Paste is injected as a keystroke, and the right keystroke depends on the\n"
        "  window it lands in: terminals read Ctrl+V as quoted-insert and take\n"
        "  Ctrl+Shift+V. Nothing else in the suite exercises this path.\n",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
