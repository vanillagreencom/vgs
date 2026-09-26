#!/usr/bin/env python3
"""Check supported source patterns in the paste owner and its callers.

The scan covers QML and JS under quickshell/vshell and config/vshell. It checks
resolver-builder ownership, injector assignments and ordering, compositor focus
branches, remembered-focus updates, and the launcher copy-failure return.

Source presence does not establish reachability or data flow. Focus-property
reads need not supply the resolver argument. An argv assignment and process
start need not name the same Process. Caller checks require a source call,
not execution of that call. Runtime queues and watchdogs are outside this check.

The scan does not detect an independent hard-coded injector elsewhere. Builder
extraction covers supported literal function declarations in the named resolver.
The source helpers reject some malformed constructs but are not full parsers.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from qml_scrub import ScrubError  # noqa: E402
from paste_literals import (  # noqa: E402
    COMMAND_ASSIGN_RE,
    OWNERSHIP_CONTROLS,
    argv_builders,
    builder_call_re,
    resolver_aliases,
    IMPORT_RE,
    literal_string_argument,
    matcher_problems,
)
from qml_source import (  # noqa: E402
    enclosing_function_body,
    handler_bodies,
    if_regions,
    in_function,
    live_code,
    occurrences_in,
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

# The argv builder. Only this function is owner-only; the module alias alone is
# a read of the resolver, which any surface may do.
COMMAND_CALL_RE = re.compile(r"\bpasteCommand\s*\(")
INJECT_CALL_RE = re.compile(r"\bPasteService\.injectPaste\s*\(")
RUNNING_TRUE_RE = re.compile(r"\.running\s*=\s*true")

FOCUS_PROPERTIES = ("focusedAppId", "lastFocusedAppId")
LIVENESS_RE = re.compile(r"ToplevelManager\.toplevels")
# Niri's live window list. Both Niri branches read it: the live one for the
# window carrying focus, the fallback to resolve the remembered id — and that
# resolution IS the liveness gate, since the list drops a window when it closes.
NIRI_WINDOWS_RE = re.compile(r"NiriService\.windows\b")
NIRI_FOCUS_FLAG_RE = re.compile(r"\bis_focused\b")
# The boolean compositor pair cannot distinguish pending detection from failure.
FOCUS_SOURCE_RE = re.compile(r"(?<![\w.])(?:\w+\s*\.\s*)*focusSource\b")
COMPOSITOR_BOOLEAN_RE = re.compile(r"(?<![\w.])(?:\w+\s*\.\s*)*is(?:Niri|Hyprland)\b")
NIRI_SOURCE_TEST_RE = re.compile(r"focusSource\s*===?\s*(['\"])niri\1")
PENDING_SOURCE_TEST_RE = re.compile(r"focusSource\s*[!=]==?\s*(['\"])pending\1")
DETECTION_COMPLETE_RE = re.compile(r"\bcompositorDetected\b")
FOCUS_READY_RE = re.compile(r"(?<![\w.])(?:\w+\s*\.\s*)*focusReady\b")
ASSERTED_READY_RE = re.compile(r"(?<![\w.])true\b")
# Require the whole negated readiness test; a positive or extra conjunct can
# return on the wrong condition.
NOT_READY_TEST_RE = re.compile(r"^\s*\(*\s*!\s*\(*\s*(?:\w+\s*\.\s*)*focusReady\s*\)*\s*$")
NIRI_SERVICE_RE = re.compile(r"\bNiriService\s*\.")
PRIVATE_MEMBER_RE = re.compile(r"\b_[A-Za-z][A-Za-z0-9_]*\b")
# Polarity determines whether missing focus or a failed copy stops injection.
ACTIVE_TOPLEVEL_TEST_RE = re.compile(r"(?<![\w.])(?:\w+\s*\.\s*)*activeToplevel\b")
NEGATED_ACTIVE_TOPLEVEL_RE = re.compile(r"!\s*(?:\w+\s*\.\s*)*activeToplevel\b")
# The remembered value's source object, e.g. `focused` in `_id = focused.id`.
# The Niri guard tests that object for existence, so the check has to know which
# object the assignment read before it can ask whether it was tested.
ASSIGNED_FROM_RE = re.compile(r"=(?!=)\s*([A-Za-z_$][A-Za-z0-9_$]*)")
# A substring match would accept a comparison conjoined with false.
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
                rel = str(path.relative_to(REPO))
                files.append((rel, live_code(text, source_name=rel),
                              live_code(text, blank_strings=True, source_name=rel)))
    return sorted(files)


def read_live(rel_path: str) -> str | None:
    path = REPO / rel_path
    if not path.is_file():
        fail(f"missing {rel_path}")
        return None
    return live_code(path.read_text(), blank_strings=True, source_name=rel_path)


def read_live_with_strings(rel_path: str) -> str | None:
    path = REPO / rel_path
    if not path.is_file():
        fail(f"missing {rel_path}")
        return None
    return live_code(path.read_text(), source_name=rel_path)


def check_matchers() -> bool:
    problems = [f"{complaint} — see scripts/lib/paste_literals.py" for complaint in matcher_problems(live_code)]
    for complaint in problems:
        fail(complaint)
    if problems:
        return False
    print("check-paste-injection: rule 3's matchers see every string delimiter, and rule 2's "
          "builder derivation still tells an argv from prose")
    return True


def resolver_argv_builders() -> list[str] | None:
    """Return the detected resolver argv builders, or None if none are declared."""
    source = read_live_with_strings(RESOLVER_LIB)
    blanked = read_live(RESOLVER_LIB)
    if source is None or blanked is None:
        return None
    builders = argv_builders(source, blanked)
    if not builders:
        fail(
            f"{RESOLVER_LIB} declares no function building a wtype argv, so the owner-only rule "
            "would police nothing — the resolver's shape changed under this check"
        )
        return None
    return builders


def check_ownership_controls(builders: list[str]) -> bool:
    for label, fixture, expected in OWNERSHIP_CONTROLS:
        call_re = builder_call_re(builders, resolver_aliases(live_code(fixture)))
        found = call_re is not None and bool(call_re.search(live_code(fixture, blank_strings=True)))
        if found != expected:
            return fail(
                f"rule 2 reads {label} as {'an unauthorised injector' if found else 'allowed'}"
            )
    print(
        "check-paste-injection: rule 2 covers every argv builder the resolver declares "
        f"({', '.join(builders)}), only through the resolver, and still allows the read-only calls"
    )
    return True


def check_single_injector(files: list[tuple[str, str, str]], builders: list[str]) -> bool:
    offenders = []
    for rel_path, with_strings, source in files:
        if rel_path in (OWNER, RESOLVER_LIB):
            continue
        call_re = builder_call_re(builders, resolver_aliases(with_strings))
        if call_re is None:
            continue
        found = call_re.search(source)
        if found:
            offenders.append(f"{rel_path} calls {found.group(0).rstrip('( ')}")
    if offenders:
        return fail(
            "a paste keystroke is built outside its owner, so a second injector exists: "
            + ", ".join(offenders)
        )
    print(
        f"check-paste-injection: {OWNER} is the only file calling the resolver's argv builders "
        f"({', '.join(builders)})"
    )
    return True


def check_owner() -> bool:
    source = read_live(OWNER)
    with_strings = read_live_with_strings(OWNER)
    if source is None or with_strings is None:
        return False
    # Imports need string contents; the line anchor excludes mentions in expressions.
    if not IMPORT_RE.search(with_strings):
        return fail(f"{OWNER} does not import PasteTarget.js")

    if not COMMAND_CALL_RE.search(source):
        return fail(f"{OWNER} does not build the wtype argv through the resolver's command function")
    calls = list(COMMAND_ASSIGN_RE.finditer(source))
    if not calls:
        return fail(
            f"{OWNER} calls the resolver's command function without assigning the result to the "
            "injector's command property, so the resolved argv never reaches the process and paste "
            "runs whatever argv was set last"
        )
    for call in calls:
        if not check_argv_assignment(source, call):
            return False
    print(f"check-paste-injection: {OWNER} resolves a target, then assigns the argv, then starts")
    return True


def check_argv_assignment(source: str, call: re.Match) -> bool:
    """One `command = pasteCommand(...)` and the function that runs it."""
    if literal_string_argument(source, call.end()):
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
    missing = [
        name for name in FOCUS_PROPERTIES
        if not occurrences_in(source, re.compile(r"\bCompositorService\." + name + r"\b"), body_start, body)
    ]
    if missing:
        return fail(
            f"{OWNER} builds the argv without reading, in the same function: " + ", ".join(missing)
            + " — the live value is routinely empty at the moment a paste fires, so both are needed"
        )

    # Empty focus resolves to Ctrl+V. Readiness must return before argv construction
    # in the same function, outside any nested conditional or callback.
    ahead = [
        (test, region_start, region_end) for test, region_start, region_end in if_regions(source)
        if body_start <= region_start and region_end <= call.start()
        and FOCUS_READY_RE.search(test)
        and in_function(source, region_start, body_start)
    ]
    pending = [(start, end) for test, start, end in ahead if NOT_READY_TEST_RE.match(test)]
    if ahead and not pending:
        return fail(
            f"{OWNER} branches on focusReady ahead of the argv but not on its NEGATION, so the "
            "returning branch runs when the focus source CAN answer — injection would be allowed "
            "only while it cannot, which is the behaviour inverted rather than guarded"
        )
    if not pending:
        return fail(
            f"{OWNER} builds the argv with no branch ahead of it testing "
            "CompositorService.focusReady, so a paste requested while the focus source cannot answer "
            "resolves an empty target and sends Ctrl+V — into a terminal, that is the stray input this "
            "whole path exists to prevent"
        )
    if not any(returns_unconditionally(source, *span) for span in pending):
        return fail(
            f"{OWNER} tests focusReady but does not leave the function from that branch, so a paste "
            "requested while the source cannot answer still reaches the argv it was meant to wait for"
        )

    starts = occurrences_in(source, RUNNING_TRUE_RE, body_start, body)
    if not starts:
        return fail(f"{OWNER} never starts the injector in the function that builds its argv")
    if starts[0].start() < call.start():
        return fail(
            f"{OWNER} starts the injector before assigning its command; Quickshell ignores a command "
            "change on a live Process, so it would run the previous injection's argv"
        )
    return True


def declaration_binding(source: str, name: str, kind: str = "string") -> str | None:
    """The binding expression of `name`, across QML's continuation lines.

    A binding routinely spans lines, and reading only the declaration's own line
    would let the whole Niri branch sit unexamined one line below every rule
    here. Continuation is indentation: the lines that follow and are indented
    further belong to the declaration, and a blank line or a dedent ends it.
    """
    declaration = re.search(
        r"^([ \t]*)(?:readonly[ \t]+)?property[ \t]+" + kind + r"[ \t]+" + name + r"\b[ \t]*:(.*)$",
        source,
        re.MULTILINE,
    )
    if not declaration:
        return None
    indent = len(declaration.group(1).expandtabs())
    parts = [declaration.group(2)]
    for line in source[declaration.end():].split("\n")[1:]:
        if not line.strip():
            break
        if len(line.expandtabs()) - len(line.expandtabs().lstrip()) <= indent:
            break
        parts.append(line)
    return "\n".join(parts)


def conditional_branches(expression: str) -> tuple[str, str] | None:
    """(then, else) of the first conditional at paren depth zero, or None.

    Depth zero is what makes the split mean "the compositor branch": a nested
    conditional lives inside one of the two branches and must stay there rather
    than becoming the split point. `??` and `?.` are not conditionals.
    """
    depth = 0
    question = None
    index = 0
    while index < len(expression):
        char = expression[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "?" and depth == 0:
            if expression[index + 1:index + 2] in ("?", "."):
                index += 2
                continue
            question = index
            break
        index += 1
    if question is None:
        return None

    depth = 0
    nested = 0
    index = question + 1
    while index < len(expression):
        char = expression[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif depth == 0 and char == "?":
            if expression[index + 1:index + 2] in ("?", "."):
                index += 2
                continue
            nested += 1
        elif depth == 0 and char == ":":
            if nested:
                nested -= 1
            else:
                return expression[question + 1:index], expression[index + 1:]
        index += 1
    return None


def focus_branches(source: str, name: str) -> tuple[str, str] | None:
    """(Niri branch, non-Niri branch) of a focus property's binding."""
    binding = declaration_binding(source, name)
    if binding is None:
        fail(f"{FOCUS_SOURCE} does not declare: {name}")
        return None
    if COMPOSITOR_BOOLEAN_RE.search(binding):
        fail(
            f"{FOCUS_SOURCE} resolves {name} from isNiri or isHyprland directly. Both are false before "
            "detection has answered AND when it answered that it could not tell, so those two states "
            "resolve through the Hyprland arm — a guessed target at the first paste of a session. "
            "Branch on the four-state focusSource instead"
        )
        return None
    if not NIRI_SOURCE_TEST_RE.search(binding):
        fail(
            f"{FOCUS_SOURCE} resolves {name} without testing focusSource for Niri, so both compositors "
            "get the Hyprland mechanism — Niri does not populate the active toplevel the same way, so "
            "its windows resolve to no target and every Niri paste falls back to Ctrl+V"
        )
        return None
    branches = conditional_branches(binding)
    if branches is None:
        fail(
            f"{FOCUS_SOURCE} tests focusSource in {name} but resolves it through no conditional, so the "
            "branch cannot be read as a per-compositor path"
        )
        return None
    ungated = [arm for arm, branch in zip(("Niri", "non-Niri"), branches) if not FOCUS_READY_RE.search(branch)]
    if ungated:
        fail(
            f"{FOCUS_SOURCE} resolves {name} on its " + " and ".join(ungated) + " arm without testing "
            "focusReady, so a target is named by a source that has not answered — detection still "
            "running, Niri's snapshot not yet delivered, no toplevel ever reported. Each of those "
            "resolves empty, and empty pastes Ctrl+V into whatever holds focus"
        )
        return None
    return branches


def check_focus_readiness() -> bool:
    """Check source patterns for per-source readiness and reject literal true."""
    source = read_live_with_strings(FOCUS_SOURCE)
    if source is None:
        return False

    states = declaration_binding(source, "focusSource")
    if states is None:
        return fail(
            f"{FOCUS_SOURCE} declares no focusSource, so nothing distinguishes a compositor VGS has "
            "confirmed from one it has not asked about yet"
        )
    if not DETECTION_COMPLETE_RE.search(states):
        return fail(
            f"{FOCUS_SOURCE} derives focusSource without reading compositorDetected, so it cannot tell "
            "detection-not-answered from detection-answered and the pending state does not exist"
        )

    ready = declaration_binding(source, "focusReady", kind="bool")
    if ready is None:
        return fail(
            f"{FOCUS_SOURCE} declares no focusReady, so there is no single answer to whether the focus "
            "source can answer a query — and every consumer is left assembling one out of flags, which "
            "is what produced three separate variants of this bug"
        )
    if ASSERTED_READY_RE.search(ready):
        return fail(
            f"{FOCUS_SOURCE} asserts readiness as a literal true somewhere in focusReady. A condition "
            "that cannot be observed does not become satisfied by being unobservable — say so in the "
            "comment and derive the arm from what CAN be seen"
        )
    if not PENDING_SOURCE_TEST_RE.search(ready):
        return fail(
            f"{FOCUS_SOURCE} derives focusReady without testing focusSource for the pending state, so "
            "a source VGS has not identified yet reads as able to answer"
        )
    branches = conditional_branches(ready)
    if branches is None or not NIRI_SOURCE_TEST_RE.search(ready):
        return fail(
            f"{FOCUS_SOURCE} derives focusReady without a per-source branch, so one compositor's "
            "conditions stand in for the other's — and Niri's are the ones that arrive late"
        )
    if not NIRI_SERVICE_RE.search(branches[0]):
        return fail(
            f"{FOCUS_SOURCE} derives Niri readiness without reading NiriService, so it cannot know "
            "whether the event stream is up or whether the window snapshot has arrived — the window "
            "between detection completing and that snapshot is exactly where a paste resolved nothing"
        )
    print(f"check-paste-injection: {FOCUS_SOURCE} publishes a focusReady derived per source, never asserted")
    return True


def check_remembered(source: str, branch: str, arm: str, guarded_regions: list[tuple[int, int]],
                     complaint: str) -> bool:
    """Check the source references and assignments that maintain remembered focus."""
    remembered = sorted(set(PRIVATE_MEMBER_RE.findall(branch)))
    if not remembered:
        return fail(
            f"{FOCUS_SOURCE} derives the {arm} lastFocusedAppId from no private reference, so nothing "
            "can maintain it"
        )
    assignments = {
        name: list(re.finditer(r"\b(?:\w+\.)?" + name + r"\s*=(?!=)", source))
        for name in remembered
    }
    if not any(assignments.values()):
        return fail(
            f"{FOCUS_SOURCE} never assigns {', '.join(remembered)}, so the {arm} lastFocusedAppId stays "
            "empty and the sticky fallback does nothing there"
        )
    # Text order alone does not show that a focus test controls the assignment.
    for name, matches in assignments.items():
        for match in matches:
            if not any(start <= match.start() < end for start, end in guarded_regions):
                return fail(f"{FOCUS_SOURCE} assigns {name} {complaint}")
    return True


def niri_guarded_regions(source: str) -> list[tuple[int, int]]:
    """Regions where a Niri remembered id may be assigned.

    Niri has no activeToplevel to test, so the guard is the object the value is
    read from: `if (focused) _id = focused.id`. Requiring the test to BE that
    identifier is what rules out recording when nothing holds focus — the case
    that would overwrite a live fallback with an id from an empty list.
    """
    regions = []
    for test, start, end in if_regions(source):
        subject = test.strip().strip("()").strip()
        if not re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*", subject):
            continue
        for assigned in ASSIGNED_FROM_RE.finditer(source, start, end):
            if assigned.group(1) == subject:
                regions.append((start, end))
                break
    return regions


def check_focus_source() -> bool:
    source = read_live(FOCUS_SOURCE)
    # State names need string contents; structural scans need blanked strings.
    # Both views preserve offsets.
    declared = read_live_with_strings(FOCUS_SOURCE)
    if source is None or declared is None:
        return False

    live = focus_branches(declared, "focusedAppId")
    sticky = focus_branches(declared, "lastFocusedAppId")
    if live is None or sticky is None:
        return False
    # The non-Niri arm includes the QML decision for failed detection.
    live_niri, live_toplevel = live
    sticky_niri, sticky_toplevel = sticky

    if not ACTIVE_TOPLEVEL_TEST_RE.search(live_toplevel):
        return fail(
            f"{FOCUS_SOURCE} resolves the non-Niri focusedAppId from something other than the seat's "
            "active toplevel"
        )
    if not (NIRI_WINDOWS_RE.search(live_niri) and NIRI_FOCUS_FLAG_RE.search(live_niri)):
        return fail(
            f"{FOCUS_SOURCE} resolves the Niri focusedAppId from something other than the focused "
            "window in NiriService.windows, which is where Niri's focus state actually lives"
        )

    if not LIVENESS_RE.search(sticky_toplevel):
        return fail(
            f"{FOCUS_SOURCE} declares the non-Niri lastFocusedAppId without testing the remembered "
            "window against ToplevelManager.toplevels, so it would keep naming a window after it closed"
        )
    if not NIRI_WINDOWS_RE.search(sticky_niri):
        return fail(
            f"{FOCUS_SOURCE} declares the Niri lastFocusedAppId without resolving the remembered window "
            "through NiriService.windows, so it would keep naming a window after it closed"
        )

    toplevel_regions = [
        (start, end) for test, start, end in if_regions(source)
        if ACTIVE_TOPLEVEL_TEST_RE.search(test) and not NEGATED_ACTIVE_TOPLEVEL_RE.search(test)
    ]
    if not check_remembered(
        source, sticky_toplevel, "non-Niri", toplevel_regions,
        "outside the branch any activeToplevel test controls, so the remembered window would be "
        "overwritten with nothing every time focus leaves a toplevel",
    ):
        return False
    if not check_remembered(
        source, sticky_niri, "Niri", niri_guarded_regions(source),
        "outside a branch testing the very object it is read from, so the remembered window would be "
        "overwritten with nothing every time Niri reports no focused window",
    ):
        return False

    print(f"check-paste-injection: {FOCUS_SOURCE} resolves focus per compositor, withholds it while pending, and gates both fallbacks on liveness")
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

    regions = if_regions(source)
    pasting = []
    for start, end in handler_bodies(source, "onExited"):
        for inject in INJECT_CALL_RE.finditer(source, start, end):
            pasting.append((start, end, inject))
    if not pasting:
        return fail(f"{LAUNCHER} pastes from no process exit handler, so the copy's result is not what gates it")

    for start, end, inject in pasting:
        # A callback return cannot stop its containing handler from pasting.
        if not in_function(source, inject.start(), start):
            return fail(
                f"{LAUNCHER} pastes from inside a function nested in its exit handler, where no branch in "
                "the handler can gate it, so a failed copy would paste stale clipboard content"
            )
        failing = [
            (region_start, region_end) for test, region_start, region_end in regions
            if start <= region_start and region_end <= end
            and region_end <= inject.start() and NONZERO_EXIT_TEST_RE.match(test)
            and in_function(source, region_start, start)
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
    try:
        return run()
    except ScrubError as error:
        fail(f"the source scanner refused a file, so these rules were NOT checked: {error}")
        return 1


def run() -> int:
    files = scanned_files()
    if not files:
        return fail(
            "the scan matched no files under " + ", ".join(SCAN_ROOTS)
            + " — a moved tree would make every rule below pass on nothing"
        ) or 1
    # Matcher controls must pass before their source checks are used.
    if not check_matchers():
        return 1

    builders = resolver_argv_builders()
    if builders is None or not check_ownership_controls(builders):
        return 1

    results = [
        check_single_injector(files, builders),
        check_owner(),
        check_focus_readiness(),
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
