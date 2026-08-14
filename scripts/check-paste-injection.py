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
     wtype, in any of JavaScript's three string delimiters — single, double or
     a template literal — and whether bound or assigned, except the
     resolver itself, `PasteTarget.js`, which is where the argv shapes live. The
     keystroke depends on the target, so a literal one is wrong everywhere else.
     `["sh", "-c", "command -v wtype"]` is a probe for the binary, not an
     invocation, and does not match. Only an argv that is CODE counts: the same
     characters inside a log message name an argv rather than building one, and
     a rule that cried wolf over prose would be turned off, costing the real
     coverage. Inside a template interpolation is code, and is caught.
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
     Its argument is something other than a literal string in any of the three
     delimiters — a template literal carrying an interpolation is a computed
     value, not a literal, and passes —
     and both the live focused app id and the sticky fallback are read in the
     same function or handler as the assignment, and the assignment precedes the
     start. Same function means the function ITSELF: a read or a start inside a
     callback nested in it runs on the callback's terms and does not count. Quickshell ignores a command change on a live Process, so the reverse
     order runs the previous injection's argv. Ahead of all of it, a branch on
     `CompositorService.focusSource` that returns unconditionally: while
     detection is pending the focus properties are empty by design, and empty
     resolves to Ctrl+V, so an injector that read them and carried on would send
     exactly the keystroke the pending state exists to withhold.
  4. Both supported compositors resolve a target, a compositor nobody has
     confirmed yet resolves none, and the sticky fallback empties when its window
     closes. `focusedAppId` and `lastFocusedAppId` each branch on the four-state
     `focusSource` — never on `isNiri` or `isHyprland`, which is the defect this
     arm exists to catch second: that pair reads false BOTH before detection has
     answered and when it answered that it could not tell, so a property
     branching on it resolves those two states through the Hyprland arm, at the
     first paste of a session. `focusSource` must itself derive from
     `compositorDetected`, or the pending state it is named for does not exist.
     Neither compositor can inherit the other's mechanism either: the non-Niri
     arm reads the seat's active toplevel and gates the fallback on membership in
     `ToplevelManager.toplevels`, while the Niri arm reads Niri's own
     IPC-maintained `NiriService.windows[].is_focused` and gates the fallback by
     resolving the remembered id through that same live list. Niri does not
     populate the active toplevel the way Hyprland does, so an unbranched
     toplevel read leaves every Niri paste falling back to Ctrl+V — the original
     bug, on a supported platform. The non-Niri arm additionally tests the
     pending state, so a target cannot be resolved before detection answers.
     Which compositor the non-Niri arm covers besides Hyprland — that is, what a
     FAILED detection resolves to — is a decision stated in the QML, not
     something this arm dictates. Each fallback is also actually maintained:
     every assignment to the private reference its branch reads sits INSIDE the
     statement a focus test controls (its braced body, or the single statement
     of a braceless form), not merely after such a test in the text — an
     activeToplevel test for Hyprland, and for Niri a test that is exactly the
     object the remembered value is read from, so recording cannot happen when
     nothing is focused.

     A declaration is read as its line plus the following more-indented lines,
     QML's continuation style; a blank line or a dedent ends it. Its branches
     are split at the first conditional at paren depth zero, so a nested
     conditional inside either branch stays with that branch.
  5. The launcher does not paste after a failed copy: its exit handler returns
     from inside a branch whose whole test is the non-zero exit-code comparison,
     and that branch closes before the paste. Branch and paste must both belong
     to the handler itself — a branch nested in a callback returns from the
     callback, and a paste nested in one runs on terms no branch in the handler
     governs. The test must carry no further
     conjunct that could falsify it, and the return must be unconditional within
     the branch — at the branch's own brace depth and inside nothing nested that
     governs whether it runs, which is a branch or a loop alike: a loop that may
     iterate zero times returns no more reliably than an `if` that may not be
     taken.

Comments are blanked before any pattern runs, so commented-out code satisfies
nothing. The structural reading these rules stand on — blanking, brace and paren
matching, which statement an `if` controls, whether a region always returns —
lives in `scripts/lib/qml_source.py`, and the delimiter-level reading a literal
needs — every string form, and code told apart from prose — in
`scripts/lib/paste_literals.py` with its controls beside it. The rules
themselves are here.

Deliberately NOT pinned:

  - A wtype argv assembled from string fragments passes rule 1: the pattern
    matches a literal array, and concatenation is not one.
  - Object identity between the assignment and the start in rule 3: the check
    proves an argv assignment precedes a `.running = true` in the same function,
    not that both name the same Process.
  - PasteService's queue latch, its watchdog ladder and the launcher's
    in-flight copy guard. Those are runtime state machines; expressing them as
    patterns would pin a flag's name and a handler's shape rather than a
    behavior, and their behavior needs a live session.
  - Reachability, and it is the largest gap here. Every rule proves a construct
    exists inside a function of the right shape; none proves anything ever calls
    that function. A whole handler could be unreachable and every rule below
    would still pass. Scoping to the function that runs a statement is as close
    as a source scan gets to "governs the code path", and it stops there.
  - The data flow inside rule 3: it proves both focus properties are read in the
    function that builds the argv, not that the value handed to the resolver
    derives from them. `pasteCommand(other)` beside an unused read would pass.
  - Rule 2's caller arm proves each surface CONTAINS a call to
    PasteService.injectPaste(), not that the call runs.
  - Anything outside the two scanned roots, or written in neither QML nor JS: a
    keystroke built in the Go backend or the helper CLI is out of scope here.

Exits non-zero naming the file and what it found.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from paste_literals import (  # noqa: E402
    COMMAND_ASSIGN_RE,
    IMPORT_RE,
    LITERAL_ARGV_RE,
    literal_argv_is_code,
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
# The four-state focus source, and the two-state pair it exists to replace. The
# pair reads false BOTH before detection answers and when it answered "cannot
# tell", so a focus path branching on it resolves those two states through the
# Hyprland arm — which is why reading them HERE is the defect, even though they
# are the right thing to read for maintenance and for everything else in QML.
FOCUS_SOURCE_RE = re.compile(r"(?<![\w.])(?:\w+\s*\.\s*)*focusSource\b")
COMPOSITOR_BOOLEAN_RE = re.compile(r"(?<![\w.])(?:\w+\s*\.\s*)*is(?:Niri|Hyprland)\b")
NIRI_SOURCE_TEST_RE = re.compile(r"focusSource\s*===?\s*(['\"])niri\1")
PENDING_SOURCE_TEST_RE = re.compile(r"focusSource\s*===?\s*(['\"])pending\1")
DETECTION_COMPLETE_RE = re.compile(r"\bcompositorDetected\b")
PRIVATE_MEMBER_RE = re.compile(r"\b_[A-Za-z][A-Za-z0-9_]*\b")
# Polarity matters, in both directions: a test on the ABSENCE of an active
# toplevel guards the wrong way, and a guard that returns when the copy SUCCEEDED
# pastes only after failures, which is the bug inverted rather than fixed.
ACTIVE_TOPLEVEL_TEST_RE = re.compile(r"(?<![\w.])(?:\w+\s*\.\s*)*activeToplevel\b")
NEGATED_ACTIVE_TOPLEVEL_RE = re.compile(r"!\s*(?:\w+\s*\.\s*)*activeToplevel\b")
# The remembered value's source object, e.g. `focused` in `_id = focused.id`.
# The Niri guard tests that object for existence, so the check has to know which
# object the assignment read before it can ask whether it was tested.
ASSIGNED_FROM_RE = re.compile(r"=(?!=)\s*([A-Za-z_$][A-Za-z0-9_$]*)")
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


def check_matchers() -> bool:
    problems = [f"{complaint} — see scripts/lib/paste_literals.py" for complaint in matcher_problems(live_code)]
    for complaint in problems:
        fail(complaint)
    if problems:
        return False
    print("check-paste-injection: rules 1 and 3 see every string delimiter and still ignore prose")
    return True


def check_no_literal_argv(files: list[tuple[str, str, str]]) -> bool:
    offenders = [
        rel_path for rel_path, source, blanked in files
        if rel_path != RESOLVER_LIB and any(
            literal_argv_is_code(source, blanked, match.start())
            for match in LITERAL_ARGV_RE.finditer(source)
        )
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
    calls = list(COMMAND_ASSIGN_RE.finditer(source))
    if not calls:
        return fail(
            f"{OWNER} calls the resolver's command function without assigning the result to the "
            "injector's command property, so the resolved argv never reaches the process and paste "
            "runs whatever argv was set last"
        )
    # Every assignment has to hold up, not the first one found: a second built
    # somewhere looser is a second injection path with none of the guarantees.
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

    # Emptying the focus properties while detection is pending only helps if the
    # injector tells empty-because-not-yet-known from empty-because-no-window:
    # "" resolves to Ctrl+V, so a paste that read it and carried on would land
    # the exact keystroke the pending state exists to withhold. The branch has to
    # belong to this function, close before the argv is built, and return —
    # unconditionally, at its own brace depth and inside nothing that governs
    # whether it runs.
    pending = [
        (region_start, region_end) for test, region_start, region_end in if_regions(source)
        if body_start <= region_start and region_end <= call.start()
        and FOCUS_SOURCE_RE.search(test)
        and in_function(source, region_start, body_start)
    ]
    if not pending:
        return fail(
            f"{OWNER} builds the argv with no branch ahead of it testing CompositorService.focusSource, "
            "so a paste requested before compositor detection answers resolves an empty target and "
            "sends Ctrl+V — into a terminal, that is the stray input this whole path exists to prevent"
        )
    if not any(returns_unconditionally(source, *span) for span in pending):
        return fail(
            f"{OWNER} tests focusSource but does not leave the function from that branch, so a paste "
            "requested before detection answers still reaches the argv it was meant to wait for"
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


def declaration_binding(source: str, name: str) -> str | None:
    """The binding expression of `name`, across QML's continuation lines.

    A binding routinely spans lines, and reading only the declaration's own line
    would let the whole Niri branch sit unexamined one line below every rule
    here. Continuation is indentation: the lines that follow and are indented
    further belong to the declaration, and a blank line or a dedent ends it.
    """
    declaration = re.search(
        r"^([ \t]*)(?:readonly[ \t]+)?property[ \t]+string[ \t]+" + name + r"\b[ \t]*:(.*)$",
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
    if not PENDING_SOURCE_TEST_RE.search(branches[1]):
        fail(
            f"{FOCUS_SOURCE} resolves {name} without testing focusSource for the pending state, so a "
            "paste requested before detection answers is resolved through the Hyprland arm by default "
            "— which is a guess, and the wrong guess types stray input into a terminal"
        )
        return None
    return branches


def check_focus_source_states() -> bool:
    """That focusSource can express pending at all.

    Every rule below branches on it, and a two-state stand-in named focusSource
    would satisfy each of them while collapsing pending back into a compositor.
    """
    source = read_live_with_strings(FOCUS_SOURCE)
    if source is None:
        return False
    binding = declaration_binding(source, "focusSource")
    if binding is None:
        return fail(
            f"{FOCUS_SOURCE} declares no focusSource, so nothing distinguishes a compositor VGS has "
            "confirmed from one it has not asked about yet"
        )
    if not DETECTION_COMPLETE_RE.search(binding):
        return fail(
            f"{FOCUS_SOURCE} derives focusSource without reading compositorDetected, so it cannot tell "
            "detection-not-answered from detection-answered and the pending state does not exist"
        )
    if not PENDING_SOURCE_TEST_RE.search(source):
        return fail(
            f"{FOCUS_SOURCE} never resolves anything on the pending state, so declaring it changes "
            "nothing"
        )
    print(f"check-paste-injection: {FOCUS_SOURCE} publishes a focusSource that can express pending")
    return True


def check_remembered(source: str, branch: str, arm: str, guarded_regions: list[tuple[int, int]],
                     complaint: str) -> bool:
    """The private reference an arm of lastFocusedAppId reads, and its upkeep.

    A declaration alone leaves the fallback permanently empty, which silently
    collapses target resolution back to the live value and its restore race.
    """
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
    # Every assignment, and containment rather than order: a focus test that
    # merely precedes the assignment guards nothing — moving the assignment below
    # the branch, or leaving an unrelated test above it, overwrites the remembered
    # window with nothing, and one such assignment is enough.
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
    # The declarations name their states as string literals, so the branch rules
    # read the view where string contents survive. The structural rules below
    # keep the blanked view, which is what the shared brace and paren scanning
    # expects: a brace inside a string elsewhere in the file would otherwise be
    # counted as code. The two views are read for different questions and their
    # offsets are never mixed.
    declared = read_live_with_strings(FOCUS_SOURCE)
    if source is None or declared is None:
        return False

    live = focus_branches(declared, "focusedAppId")
    sticky = focus_branches(declared, "lastFocusedAppId")
    if live is None or sticky is None:
        return False
    # The second arm is not "Hyprland": it is every state that is not Niri, which
    # is Hyprland plus the deliberate decision about what a failed detection
    # resolves to. Both are checked here as the toplevel mechanism, because that
    # is what the arm reads on either.
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

    # Every exit handler that pastes, not one located by position: a handler
    # added above this one must not be able to take the check's attention.
    regions = if_regions(source)
    pasting = []
    for start, end in handler_bodies(source, "onExited"):
        # Every paste in the handler: checking only the first would let a second
        # one, added below the guarded one, paste ungated.
        for inject in INJECT_CALL_RE.finditer(source, start, end):
            pasting.append((start, end, inject))
    if not pasting:
        return fail(f"{LAUNCHER} pastes from no process exit handler, so the copy's result is not what gates it")

    for start, end, inject in pasting:
        # Both the paste and the branch that guards it have to belong to the
        # handler itself. A branch inside a callback nested in the handler
        # returns from the callback, so its return cannot stop the handler from
        # reaching the paste — and a paste inside one runs on the callback's
        # terms, which no branch in the handler governs.
        if not in_function(source, inject.start(), start):
            return fail(
                f"{LAUNCHER} pastes from inside a function nested in its exit handler, where no branch in "
                "the handler can gate it, so a failed copy would paste stale clipboard content"
            )
        # The branch has to close before the paste and the paste has to be
        # outside it, so entering the branch means never reaching the paste.
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
    files = scanned_files()
    if not files:
        return fail(
            "the scan matched no files under " + ", ".join(SCAN_ROOTS)
            + " — a moved tree would make every rule below pass on nothing"
        ) or 1
    # Before rules 1 and 3 mean anything, their matchers have to still see
    # every delimiter — so this short-circuits, like the empty-scan guard.
    if not check_matchers():
        return 1

    # Deliberately not short-circuiting: report every violation in one run.
    results = [
        check_no_literal_argv(files),
        check_single_injector(files),
        check_owner(),
        check_focus_source_states(),
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
