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
     resolver, and the resolved argv is assigned to the injector's `command`
     property — the call is matched as the right-hand side of that assignment,
     not as a free-standing occurrence, since a call whose result goes nowhere
     leaves injection broken. That means the resolved argv has to reach the
     property in ONE statement: routing it through a local first is behavior the
     rule cannot tell apart from dropping it, so this arm rejects that too.
     Its argument is something other than a literal
     string, both the live focused app id and the sticky fallback are read in the
     same function or handler as the assignment, and the assignment precedes the
     start. Quickshell ignores a command change on a live Process, so the reverse
     order runs the previous injection's argv.
  4. The sticky fallback empties when its window closes — a liveness test in the
     declaration — and is actually maintained: every assignment to the private
     reference the declaration reads sits INSIDE the statement an activeToplevel
     test controls (its braced body, or the single statement of a braceless
     form), not merely after such a test in the text.
  5. The launcher does not paste after a failed copy: its exit handler returns
     from inside a branch whose whole test is the non-zero exit-code comparison,
     and that branch closes before the paste. The test must carry no further
     conjunct that could falsify it, and the return must be unconditional within
     the branch — at the branch's own brace depth and inside nothing nested that
     governs whether it runs, which is a branch or a loop alike: a loop that may
     iterate zero times returns no more reliably than an `if` that may not be
     taken.

Comments are blanked before any pattern runs, so commented-out code satisfies
nothing. The structural reading these rules stand on — blanking, brace and paren
matching, which statement an `if` controls, whether a region always returns —
lives in `scripts/lib/qml_source.py`; the rules themselves are here.

Deliberately NOT pinned:

  - String literals are not neutralized for rule 1 (it needs their contents), so
    a wtype argv assembled from string fragments would pass it.
  - Object identity between the assignment and the start in rule 3: the check
    proves an argv assignment precedes a `.running = true` in the same function,
    not that both name the same Process.
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

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from qml_source import (  # noqa: E402
    enclosing_function_body,
    handler_bodies,
    if_regions,
    live_code,
    returns_unconditionally,
)

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
# The call as the right-hand side of the injector's `command` assignment. A bare
# call proves nothing: its result has to reach the Process, and `command` is
# Quickshell's own property name, so this is insensitive to how the process, the
# module alias and the whitespace are spelled without being insensitive to the
# behavior.
COMMAND_ASSIGN_RE = re.compile(r"\bcommand\s*=(?!=)\s*(?:\w+\s*\.\s*)*pasteCommand\s*\(")
QUOTED_ARG_RE = re.compile(r"\s*['\"]")
IMPORT_RE = re.compile(r"^[ \t]*import\s+\"PasteTarget\.js\"\s+as\s+\w+", re.MULTILINE)
INJECT_CALL_RE = re.compile(r"\bPasteService\.injectPaste\s*\(")
RUNNING_TRUE_RE = re.compile(r"\.running\s*=\s*true")

FOCUS_PROPERTIES = ("focusedAppId", "lastFocusedAppId")
LIVENESS_RE = re.compile(r"ToplevelManager\.toplevels")
PRIVATE_MEMBER_RE = re.compile(r"\b_[A-Za-z][A-Za-z0-9_]*\b")
# Polarity matters, in both directions: a test on the ABSENCE of an active
# toplevel guards the wrong way, and a guard that returns when the copy SUCCEEDED
# pastes only after failures, which is the bug inverted rather than fixed.
ACTIVE_TOPLEVEL_TEST_RE = re.compile(r"(?<![\w.])(?:\w+\s*\.\s*)*activeToplevel\b")
NEGATED_ACTIVE_TOPLEVEL_RE = re.compile(r"!\s*(?:\w+\s*\.\s*)*activeToplevel\b")
# The WHOLE test, anchored: `exitCode !== 0 && false` is a non-zero comparison
# that never holds, and satisfied a substring match while pasting on failure.
NONZERO_EXIT_TEST_RE = re.compile(r"^\s*\(*\s*(?:\w+\s*\.\s*)*exitCode\s*!==?\s*0\s*\)*\s*$")


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

    if not COMMAND_CALL_RE.search(source):
        return fail(f"{OWNER} does not build the wtype argv through the resolver's command function")
    call = COMMAND_ASSIGN_RE.search(source)
    if not call:
        return fail(
            f"{OWNER} calls the resolver's command function without assigning the result to the "
            "injector's command property, so the resolved argv never reaches the process and paste "
            "runs whatever argv was set last"
        )
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
    # Every assignment, and containment rather than order: an activeToplevel test
    # that merely precedes the assignment guards nothing — moving the assignment
    # below the branch, or leaving an unrelated test above it, overwrites the
    # remembered window with nothing, and one such assignment is enough.
    guarded_regions = [
        (start, end) for test, start, end in if_regions(source)
        if ACTIVE_TOPLEVEL_TEST_RE.search(test) and not NEGATED_ACTIVE_TOPLEVEL_RE.search(test)
    ]
    for name, matches in assignments.items():
        for match in matches:
            if not any(start <= match.start() < end for start, end in guarded_regions):
                return fail(
                    f"{FOCUS_SOURCE} assigns {name} outside the branch any activeToplevel test "
                    "controls, so the remembered window would be overwritten with nothing every time "
                    "focus leaves a toplevel"
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
    regions = if_regions(source)
    pasting = []
    for start, end in handler_bodies(source, "onExited"):
        inject = INJECT_CALL_RE.search(source, start, end)
        if inject:
            pasting.append((start, end, inject))
    if not pasting:
        return fail(f"{LAUNCHER} pastes from no process exit handler, so the copy's result is not what gates it")

    for start, end, inject in pasting:
        # The branch has to close before the paste and the paste has to be
        # outside it, so entering the branch means never reaching the paste.
        failing = [
            (region_start, region_end) for test, region_start, region_end in regions
            if start <= region_start and region_end <= end
            and region_end <= inject.start() and NONZERO_EXIT_TEST_RE.match(test)
        ]
        if not failing:
            return fail(
                f"{LAUNCHER} pastes with no branch ahead of it whose whole test is the copy's exit code "
                "against non-zero — an extra conjunct does not count, since it can falsify the test and "
                "paste whatever stale content is still on the clipboard"
            )
        if not any(returns_unconditionally(source, *span) for span in failing):
            return fail(
                f"{LAUNCHER} tests the copy's exit code but does not unconditionally return from that "
                "branch, so a failed copy still reaches the paste"
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
