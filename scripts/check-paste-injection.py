#!/usr/bin/env python3
"""Pin the wiring that makes paste land the right keystroke in the right window.

`scripts/test-paste-target.js` covers the resolver, which is pure JS. Nothing
else covers the code that calls it: `scripts/qml-smoke.sh --nested` proves the
shell parses and starts, but it never opens the clipboard surface or the
launcher's paste path, so the injection site itself has no failing-test control.
Hard-coding the argv again, assuming a target instead of resolving one, or
letting a second surface grow its own injector would pass the entire suite while
terminal pastes misfire — the exact bug VGS-119 fixed.

Pinned, over the QML and JS under `quickshell/vshell/` and `config/vshell/`
(bundled plugins ship both, and a paste feature could be written there):

  1. No hard-coded keystroke. No file builds an argv whose first element is
     wtype, in either quote style and whether bound or assigned — except the
     resolver itself, `PasteTarget.js`, which is where the argv shapes live. The
     keystroke depends on the target, so a literal one is wrong everywhere else.
     `["sh", "-c", "command -v wtype"]` is a probe for the binary, not an
     invocation, and does not match.
  2. One injector. Only PasteService may call the resolver's command function:
     another caller is a second injector, which is how the original Ctrl+V bug
     came to exist in two places at once. Reading the resolver for anything else
     — asking whether a target is a terminal, to show what a keystroke will be —
     is not restricted. The two surfaces that paste must each call into
     PasteService.
  3. The injector resolves a target rather than assuming one: it imports the
     resolver, calls its command function on something other than a literal
     string, and reads both the live focused app id and the sticky fallback in
     the same function or handler as that call — then assigns the argv before
     starting the process. Quickshell ignores a command change on a live Process,
     so the reverse order runs the previous injection's argv.
  4. The sticky fallback empties when its window closes — a liveness test in the
     declaration — and is actually maintained: every assignment to the private
     reference the declaration reads sits behind an activeToplevel guard ahead of
     it in the same function or handler.
  5. The launcher does not paste after a failed copy: its exit handler tests the
     exit code against non-zero and returns before reaching PasteService.

Comments are blanked before any pattern runs, so commented-out code satisfies
nothing.

Deliberately NOT pinned:

  - String literals are not neutralized for rule 1 (it needs their contents), so
    a wtype argv assembled from string fragments would pass it.
  - PasteService's queue latch, its watchdog ladder and the launcher's
    in-flight copy guard. Those are runtime state machines; expressing them as
    patterns would pin a flag's name and a handler's shape rather than a
    behavior, and their behavior needs a live session.
  - Anything outside the two scanned roots, or written in neither QML nor JS: a
    keystroke built in the Go backend or the helper CLI is out of scope here.

Exits non-zero naming the file and what it found.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCAN_ROOTS = ["quickshell/vshell", "config/vshell"]
SCAN_SUFFIXES = ("*.qml", "*.js")

OWNER = "quickshell/vshell/Services/PasteService.qml"
RESOLVER_LIB = "quickshell/vshell/Services/PasteTarget.js"
FOCUS_SOURCE = "quickshell/vshell/Services/CompositorService.qml"
LAUNCHER = "quickshell/vshell/Modules/WorkspaceOverlays/OverviewSearch/Controller.qml"
CALLERS = [
    "quickshell/vshell/Services/ClipboardService.qml",
    LAUNCHER,
]

# An array literal whose first element is wtype, in either quote style. Matching
# the literal rather than a `command:` prefix covers the declarative binding and
# the imperative assignment alike — the imperative form is what the injector
# itself uses, so it is the likelier regression.
LITERAL_ARGV_RE = re.compile(r"\[\s*(['\"])wtype\1")

# The argv builder. Only this function is owner-only; the module alias alone is
# a read of the resolver, which any surface may do.
COMMAND_CALL_RE = re.compile(r"\bpasteCommand\s*\(")
QUOTED_ARG_RE = re.compile(r"\s*['\"]")
IMPORT_RE = re.compile(r"^[ \t]*import\s+\"PasteTarget\.js\"\s+as\s+\w+", re.MULTILINE)
INJECT_CALL_RE = re.compile(r"\bPasteService\.injectPaste\s*\(")
RUNNING_TRUE_RE = re.compile(r"\.running\s*=\s*true")

FOCUS_PROPERTIES = ("focusedAppId", "lastFocusedAppId")
LIVENESS_RE = re.compile(r"ToplevelManager\.toplevels")
PRIVATE_MEMBER_RE = re.compile(r"\b_[A-Za-z][A-Za-z0-9_]*\b")
ACTIVE_TOPLEVEL_GUARD_RE = re.compile(r"if\s*\([^)]*activeToplevel[^)]*\)")
# Polarity matters: a guard that returns when the copy SUCCEEDED pastes only
# after failures, which is the bug inverted rather than fixed.
NONZERO_EXIT_GUARD_RE = re.compile(r"if\s*\([^)]*exitCode\s*!==?\s*0[^)]*\)")


def live_code(text: str, blank_strings: bool = False) -> str:
    """`text` with comments blanked, offsets and line count preserved.

    Matching raw source counts commented-out code as present: a correct line
    left commented above a hard-coded one satisfied an earlier version of this
    check. With `blank_strings`, string CONTENTS are blanked too and only the
    delimiters remain, so a call named inside a log message is not a call — rule
    1 is the one arm that needs contents, and it alone reads the other view.
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
                    out.append("  " if blank_strings else text[i:i + 2])
                    i += 2
                    continue
                consumed = text[i]
                i += 1
                # An unterminated single-line string ends at the newline; QML has
                # no multi-line "" literal, and a template literal has no such end.
                terminator = consumed == quote or (quote != "`" and consumed == "\n")
                if blank_strings and not terminator:
                    out.append("\n" if consumed == "\n" else " ")
                else:
                    out.append(consumed)
                if terminator:
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


def scanned_files() -> list[tuple[str, str, str]]:
    """(relative path, live code, live code without string contents)."""
    files = []
    for root in SCAN_ROOTS:
        for suffix in SCAN_SUFFIXES:
            for path in (REPO / root).rglob(suffix):
                text = path.read_text()
                files.append((str(path.relative_to(REPO)), live_code(text), live_code(text, blank_strings=True)))
    return sorted(files)


def read_live(rel_path: str) -> str | None:
    path = REPO / rel_path
    if not path.is_file():
        fail(f"missing {rel_path}")
        return None
    return live_code(path.read_text(), blank_strings=True)


def read_live_with_strings(rel_path: str) -> str | None:
    path = REPO / rel_path
    if not path.is_file():
        fail(f"missing {rel_path}")
        return None
    return live_code(path.read_text())


def enclosing_body(source: str, index: int) -> tuple[int, str] | None:
    """The innermost braced block containing `index`, as (start offset, text)."""
    depth = 0
    opening = -1
    for cursor in range(index, -1, -1):
        if source[cursor] == "}":
            depth += 1
        elif source[cursor] == "{":
            if depth == 0:
                opening = cursor
                break
            depth -= 1
    if opening == -1:
        return None
    depth = 0
    for cursor in range(opening, len(source)):
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
            if depth == 0:
                return opening, source[opening:cursor + 1]
    return None


# What a body's preamble looks like when the body is a function or a signal
# handler: `function name(...) {`, `onExited: exitCode => {`, `onTriggered: {`.
FUNCTION_PREAMBLE_RE = re.compile(r"(?:\bfunction\b[^{;]*|=>\s*|\bon[A-Z]\w*\s*:\s*)$")


def enclosing_function_body(source: str, index: int) -> tuple[int, str] | None:
    """The function or handler body containing `index`, walking outward.

    The innermost block alone is too tight — wrapping a statement in a
    conditional inside the same function moves it — and the whole file is too
    loose, since a guard or a read in an unrelated function proves nothing about
    this one. The function that runs the statement is the scope where a textual
    order and a textual guard mean what they say. None when no enclosing block
    reads as a function or handler, which the callers report rather than widen:
    a statement no scope contains is what the widening would hide.
    """
    scope = enclosing_body(source, index)
    while scope is not None:
        start, _ = scope
        if FUNCTION_PREAMBLE_RE.search(source[max(0, start - 120):start]):
            return scope
        if start == 0:
            return None
        scope = enclosing_body(source, start - 1)
    return None


def handler_bodies(source: str, handler: str) -> list[str]:
    """Every braced body of `handler` in `source`, in declaration order."""
    bodies = []
    for match in re.finditer(r"\b" + handler + r"\b", source):
        opening = source.find("{", match.end())
        if opening == -1:
            continue
        depth = 0
        for cursor in range(opening, len(source)):
            if source[cursor] == "{":
                depth += 1
            elif source[cursor] == "}":
                depth -= 1
                if depth == 0:
                    bodies.append(source[opening:cursor + 1])
                    break
    return bodies


def check_no_literal_argv(files: list[tuple[str, str, str]]) -> bool:
    offenders = [
        rel_path for rel_path, source, _ in files
        if rel_path != RESOLVER_LIB and LITERAL_ARGV_RE.search(source)
    ]
    if offenders:
        return fail(
            "a wtype argv is hard-coded, so the keystroke ignores the target: " + ", ".join(offenders)
        )
    print(f"check-paste-injection: no hard-coded wtype argv in {len(files)} files under {', '.join(SCAN_ROOTS)}")
    return True


def check_single_injector(files: list[tuple[str, str, str]]) -> bool:
    offenders = [
        rel_path for rel_path, _, source in files
        if rel_path not in (OWNER, RESOLVER_LIB) and COMMAND_CALL_RE.search(source)
    ]
    if offenders:
        return fail(
            "a paste keystroke is built outside its owner, so a second injector exists: "
            + ", ".join(offenders)
        )
    print(f"check-paste-injection: {OWNER} is the only file calling the resolver's command function")
    return True


def check_owner() -> bool:
    source = read_live(OWNER)
    with_strings = read_live_with_strings(OWNER)
    if source is None or with_strings is None:
        return False
    # The import names the file in a string literal, so it is the one pattern
    # that reads the view where string contents survive — and the only positive
    # rule a string could otherwise satisfy, hence the line anchor: a statement
    # starts its line, the same text inside an expression does not.
    if not IMPORT_RE.search(with_strings):
        return fail(f"{OWNER} does not import PasteTarget.js")

    call = COMMAND_CALL_RE.search(source)
    if not call:
        return fail(f"{OWNER} does not build the wtype argv through the resolver's command function")
    if QUOTED_ARG_RE.match(source, call.end()):
        return fail(
            f"{OWNER} passes a literal string to the resolver, so every paste would use one target's "
            "keystroke instead of the focused window's"
        )

    scope = enclosing_function_body(source, call.start())
    if scope is None:
        return fail(
            f"{OWNER} builds the argv outside any function or handler, so nothing scopes the target "
            "resolution"
        )
    body_start, body = scope
    missing = [name for name in FOCUS_PROPERTIES if f"CompositorService.{name}" not in body]
    if missing:
        return fail(
            f"{OWNER} builds the argv without reading, in the same function: " + ", ".join(missing)
            + " — the live value is routinely empty at the moment a paste fires, so both are needed"
        )

    run = RUNNING_TRUE_RE.search(body)
    if not run:
        return fail(f"{OWNER} never starts the injector in the function that builds its argv")
    if run.start() < call.start() - body_start:
        return fail(
            f"{OWNER} starts the injector before assigning its command; Quickshell ignores a command "
            "change on a live Process, so it would run the previous injection's argv"
        )

    print(f"check-paste-injection: {OWNER} resolves a target, then assigns the argv, then starts")
    return True


def check_focus_source() -> bool:
    source = read_live(FOCUS_SOURCE)
    if source is None:
        return False

    declarations = {
        name: re.search(
            r"^[ \t]*(?:readonly[ \t]+)?property[ \t]+string[ \t]+" + name + r"\b.*$", source, re.MULTILINE
        )
        for name in FOCUS_PROPERTIES
    }
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
    assignments = {
        name: list(re.finditer(r"\b(?:\w+\.)?" + name + r"\s*=(?!=)", source))
        for name in sorted(remembered)
    }
    if not any(assignments.values()):
        return fail(
            f"{FOCUS_SOURCE} never assigns {', '.join(sorted(remembered))}, so lastFocusedAppId stays "
            "empty and the sticky fallback does nothing"
        )
    # Every assignment, and the guard read in the function that runs it: matched
    # file-wide, an activeToplevel test in an unrelated function would stand in
    # for the missing one, and one unguarded assignment is enough to overwrite
    # the remembered window.
    for name, matches in assignments.items():
        for match in matches:
            scope = enclosing_function_body(source, match.start())
            if scope is None:
                return fail(
                    f"{FOCUS_SOURCE} assigns {name} outside any function or handler, so nothing scopes "
                    "the guard that has to precede it"
                )
            body_start, body = scope
            guard = ACTIVE_TOPLEVEL_GUARD_RE.search(body)
            if not guard or guard.start() > match.start() - body_start:
                return fail(
                    f"{FOCUS_SOURCE} assigns {name} with no activeToplevel guard ahead of it in the "
                    "same function, so the remembered window would be overwritten with nothing every "
                    "time focus leaves a toplevel"
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
        guard = NONZERO_EXIT_GUARD_RE.search(body)
        if not guard or guard.end() > inject.start():
            return fail(
                f"{LAUNCHER} pastes without testing the copy's exit code against non-zero first, so a "
                "failed copy pastes whatever stale content is still on the clipboard"
            )
        if "return" not in body[guard.end():inject.start()]:
            return fail(
                f"{LAUNCHER} tests the copy's exit code but does not return before pasting on failure"
            )

    print(f"check-paste-injection: {LAUNCHER} pastes only after a successful copy")
    return True


def main() -> int:
    files = scanned_files()
    if not files:
        return fail(
            "the scan matched no files under " + ", ".join(SCAN_ROOTS)
            + " — a moved tree would make every rule below pass on nothing"
        ) or 1

    # Deliberately not short-circuiting: report every violation in one run.
    results = [
        check_no_literal_argv(files),
        check_single_injector(files),
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
