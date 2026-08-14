#!/usr/bin/env python3
"""Pin the wiring that makes paste land the right keystroke in the right window.

`scripts/test-paste-target.js` covers the resolver, which is pure JS. Nothing
else covers the QML that calls it: `scripts/qml-smoke.sh --nested` proves the
shell parses and starts, but it never opens the clipboard surface or the
launcher's paste path, so the injection site itself has no failing-test control.
Hard-coding the argv again, or letting a second surface grow its own injector,
would pass the entire suite while terminal pastes misfire — the exact bug
VGS-119 fixed.

Pinned, over the QML under `quickshell/vshell/` and `config/vshell/` (bundled
plugins ship QML too, and a paste feature could be written there):

  1. No hard-coded keystroke. No QML file builds an argv whose first element is
     wtype, in either quote style and whether bound or assigned. The keystroke
     depends on the target, so a literal one is wrong wherever it appears.
     `["sh", "-c", "command -v wtype"]` is a probe for the binary, not an
     invocation, and does not match.
  2. One owner. Only PasteService may reach for the resolver: any other file
     naming PasteTarget or its command function is a second injector, which is
     how the original Ctrl+V bug came to exist in two places at once. The two
     surfaces that paste must each call into PasteService.
  3. The owner resolves a target rather than assuming one: it imports the
     resolver, calls its command function, and reads both the live focused app
     id and the sticky fallback.
  4. The sticky fallback empties when its window closes — a liveness test in the
     declaration — and is actually maintained, by a guarded assignment to the
     private reference the declaration reads.
  5. The launcher does not paste after a failed copy: its exit handler takes the
     exit code and returns on a non-zero one before reaching PasteService.

Matching runs against live code — comments are blanked first — so text that
cannot execute satisfies nothing.

Deliberately NOT pinned, because any expression of them would pin an
identifier or a handler's shape rather than a behavior: PasteService's queue
latch, its watchdog, and the launcher's in-flight copy guard. Those are runtime
state machines; their behavior needs a live session, not a source scan.

Exits non-zero naming the file and what it found.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCAN_ROOTS = ["quickshell/vshell", "config/vshell"]

OWNER = "quickshell/vshell/Services/PasteService.qml"
FOCUS_SOURCE = "quickshell/vshell/Services/CompositorService.qml"
LAUNCHER = "quickshell/vshell/Modules/WorkspaceOverlays/OverviewSearch/Controller.qml"
CALLERS = [
    "quickshell/vshell/Services/ClipboardService.qml",
    LAUNCHER,
]

# An array literal whose first element is wtype, in either quote style. Matching
# the literal rather than a `command:` prefix covers the declarative binding and
# the imperative assignment alike — the imperative form is what the owner itself
# uses, so it is the likelier regression.
LITERAL_ARGV_RE = re.compile(r"\[\s*(['\"])wtype\1")

# The resolver, by module alias and by function. Either name outside the owner
# means something else is building paste keystrokes.
RESOLVER_RE = re.compile(r"\bPasteTarget\b|\bpasteCommand\s*\(")

IMPORT_RE = re.compile(r"import\s+\"PasteTarget\.js\"\s+as\s+\w+")
COMMAND_CALL_RE = re.compile(r"\bpasteCommand\s*\(")
INJECT_CALL_RE = re.compile(r"\bPasteService\.injectPaste\s*\(")

FOCUS_PROPERTIES = ("focusedAppId", "lastFocusedAppId")
LIVENESS_RE = re.compile(r"ToplevelManager\.toplevels")
PRIVATE_MEMBER_RE = re.compile(r"\b_[A-Za-z][A-Za-z0-9_]*\b")
ACTIVE_TOPLEVEL_GUARD_RE = re.compile(r"if\s*\([^)]*activeToplevel[^)]*\)")
EXIT_CODE_GUARD_RE = re.compile(r"if\s*\([^)]*exitCode[^)]*\)")


def live_code(text: str) -> str:
    """`text` with every comment blanked out, offsets and line count preserved.

    Matching raw source counts commented-out code as present: a correct line
    left commented above a hard-coded one satisfied every arm of the earlier
    version of this check.
    """
    out: list[str] = []
    i, end = 0, len(text)
    while i < end:
        char = text[i]
        if char in "\"'`":
            quote = char
            out.append(char)
            i += 1
            while i < end:
                if text[i] == "\\" and i + 1 < end:
                    out.append(text[i:i + 2])
                    i += 2
                    continue
                out.append(text[i])
                i += 1
                # An unterminated single-line string ends at the newline; QML has
                # no multi-line "" literal, and a template literal has no such end.
                if text[i - 1] == quote or (quote != "`" and text[i - 1] == "\n"):
                    break
            continue
        if char == "/" and i + 1 < end and text[i + 1] == "/":
            while i < end and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if char == "/" and i + 1 < end and text[i + 1] == "*":
            while i < end and not (text[i] == "*" and i + 1 < end and text[i + 1] == "/"):
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            out.append("  ")
            i += 2
            continue
        out.append(char)
        i += 1
    return "".join(out)


def fail(message: str) -> bool:
    print(f"check-paste-injection: FAIL: {message}", file=sys.stderr)
    return False


def scanned_files() -> list[tuple[str, str]]:
    """(relative path, live code) for every QML file under the scanned roots."""
    files = []
    for root in SCAN_ROOTS:
        for path in sorted((REPO / root).rglob("*.qml")):
            files.append((str(path.relative_to(REPO)), live_code(path.read_text())))
    return files


def read_live(rel_path: str) -> str | None:
    path = REPO / rel_path
    if not path.is_file():
        fail(f"missing {rel_path}")
        return None
    return live_code(path.read_text())


def handler_bodies(source: str, handler: str) -> list[str]:
    """Every braced body of `handler` in `source`, in declaration order."""
    bodies = []
    for match in re.finditer(r"\b" + handler + r"\b", source):
        opening = source.find("{", match.end())
        if opening == -1:
            continue
        depth = 0
        for index in range(opening, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    bodies.append(source[opening:index + 1])
                    break
    return bodies


def check_no_literal_argv(files: list[tuple[str, str]]) -> bool:
    offenders = [rel_path for rel_path, source in files if LITERAL_ARGV_RE.search(source)]
    if offenders:
        return fail(
            "a wtype argv is hard-coded, so the keystroke ignores the target: " + ", ".join(offenders)
        )
    print(f"check-paste-injection: no hard-coded wtype argv in {len(files)} QML files under {', '.join(SCAN_ROOTS)}")
    return True


def check_single_owner(files: list[tuple[str, str]]) -> bool:
    offenders = [
        rel_path for rel_path, source in files if rel_path != OWNER and RESOLVER_RE.search(source)
    ]
    if offenders:
        return fail(
            "the paste resolver is reached outside its owner, so a second injector exists: "
            + ", ".join(offenders)
        )
    print(f"check-paste-injection: {OWNER} is the only file building paste keystrokes")
    return True


def check_owner() -> bool:
    source = read_live(OWNER)
    if source is None:
        return False
    if not IMPORT_RE.search(source):
        return fail(f"{OWNER} does not import PasteTarget.js")
    if not COMMAND_CALL_RE.search(source):
        return fail(f"{OWNER} does not build the wtype argv through the resolver's command function")
    missing = [name for name in FOCUS_PROPERTIES if f"CompositorService.{name}" not in source]
    if missing:
        return fail(
            f"{OWNER} resolves its target without reading: " + ", ".join(missing)
            + " — the live value is routinely empty at the moment a paste fires, so both are needed"
        )
    print(f"check-paste-injection: {OWNER} resolves its target from the live and sticky focus values")
    return True


def check_focus_source() -> bool:
    source = read_live(FOCUS_SOURCE)
    if source is None:
        return False

    declarations = {}
    for name in FOCUS_PROPERTIES:
        match = re.search(r"^[ \t]*(?:readonly[ \t]+)?property[ \t]+string[ \t]+" + name + r"\b.*$", source, re.MULTILINE)
        declarations[name] = match
    missing = [name for name, match in declarations.items() if not match]
    if missing:
        return fail(f"{FOCUS_SOURCE} does not declare: " + ", ".join(missing))

    sticky = declarations["lastFocusedAppId"].group(0)
    if not LIVENESS_RE.search(sticky):
        return fail(
            f"{FOCUS_SOURCE} declares lastFocusedAppId without testing the remembered window against "
            "ToplevelManager.toplevels, so it would keep naming a window after it closed"
        )

    # A declaration alone leaves the fallback permanently empty, which silently
    # collapses target resolution back to the live value and its restore race.
    remembered = set(PRIVATE_MEMBER_RE.findall(sticky))
    if not remembered:
        return fail(
            f"{FOCUS_SOURCE} derives lastFocusedAppId from no private reference, so nothing can "
            "maintain it"
        )
    assigned = [
        name for name in sorted(remembered)
        if re.search(r"\b(?:\w+\.)?" + name + r"\s*=(?!=)", source)
    ]
    if not assigned:
        return fail(
            f"{FOCUS_SOURCE} never assigns {', '.join(sorted(remembered))}, so lastFocusedAppId stays "
            "empty and the sticky fallback does nothing"
        )
    if not ACTIVE_TOPLEVEL_GUARD_RE.search(source):
        return fail(
            f"{FOCUS_SOURCE} assigns {', '.join(assigned)} without an activeToplevel guard, so the "
            "remembered window would be overwritten with nothing every time focus leaves a toplevel"
        )

    print(f"check-paste-injection: {FOCUS_SOURCE} publishes a liveness-gated lastFocusedAppId and maintains it")
    return True


def check_callers() -> bool:
    ok = True
    for rel_path in CALLERS:
        source = read_live(rel_path)
        if source is None:
            ok = False
            continue
        if not INJECT_CALL_RE.search(source):
            ok = fail(f"{rel_path} does not paste through PasteService.injectPaste()")
            continue
        print(f"check-paste-injection: {rel_path} pastes through PasteService")
    return ok


def check_launcher_copy_result() -> bool:
    source = read_live(LAUNCHER)
    if source is None:
        return False

    # Every exit handler that pastes, not one located by position: a handler
    # added above this one must not be able to take the check's attention.
    pasting = [
        (body, INJECT_CALL_RE.search(body))
        for body in handler_bodies(source, "onExited")
        if INJECT_CALL_RE.search(body)
    ]
    if not pasting:
        return fail(f"{LAUNCHER} pastes from no process exit handler, so the copy's result is not what gates it")

    for body, inject in pasting:
        guard = EXIT_CODE_GUARD_RE.search(body)
        if not guard or guard.end() > inject.start():
            return fail(
                f"{LAUNCHER} pastes without checking that the copy succeeded, so a failed copy pastes "
                "whatever stale content is still on the clipboard"
            )
        if "return" not in body[guard.end():inject.start()]:
            return fail(
                f"{LAUNCHER} checks the copy's exit code but does not return before pasting on failure"
            )

    print(f"check-paste-injection: {LAUNCHER} pastes only after a successful copy")
    return True


def main() -> int:
    files = scanned_files()
    if not files:
        return fail(
            "the scan matched no QML files under " + ", ".join(SCAN_ROOTS)
            + " — a moved tree would make every rule below pass on nothing"
        ) or 1

    # Deliberately not short-circuiting: report every violation in one run.
    results = [
        check_no_literal_argv(files),
        check_single_owner(files),
        check_owner(),
        check_focus_source(),
        check_callers(),
        check_launcher_copy_result(),
    ]
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
