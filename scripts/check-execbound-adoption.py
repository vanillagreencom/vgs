#!/usr/bin/env python3
"""Keep one-shot backend output reads on execbound.

Raw os/exec command builders under backend/internal are allowed only when they
start a long-lived process with its own lifecycle. A command read through
Output or CombinedOutput must use backend/internal/execbound, whose WaitDelay
keeps inherited pipes from wedging the request past its context deadline.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(os.environ.get("VGS_EXECBOUND_REPO_ROOT", Path(__file__).resolve().parents[1])).resolve()
BACKEND_INTERNAL = REPO_ROOT / "backend" / "internal"
SKIP_TREES = (
    REPO_ROOT / "backend" / "internal" / "execbound",
    REPO_ROOT / "backend" / "vendor",
)

# Raw os/exec sites that intentionally start a process whose lifecycle outlives
# a single output read. Every entry needs the process reason, because an
# unreasoned raw exec site is exactly what hides a new bypass.
ALLOWED_RAW_EXECS = {
    'backend/internal/services/clipboard/wayland.go::wlCopy exec.Command("wl-copy", args...)':
        "wl-copy serves the Wayland clipboard after the RPC returns; wlCopy starts it, "
        "waits only for startup failure, then reaps it in a goroutine.",
    'backend/internal/services/clipboard/wayland.go::watch exec.CommandContext(ctx, "wl-paste", "--watch", "echo")':
        "wl-paste --watch is the single clipboard watcher owned by the backend.",
    'backend/internal/services/cloudsync/rcd.go::start exec.Command(d.binary, "rcd", "--rc-addr", '
    '"127.0.0.1:"+strconv.Itoa(port), "--rc-web-gui=false", "--log-level", "NOTICE")':
        "rclone rcd is the cloudsync control daemon; cloudsync supervises it and owns its endpoint.",
    'backend/internal/services/cloudsync/remotes.go::beginOAuth exec.Command(m.binary, "authorize", '
    'providerType, "--auth-no-open-browser")':
        "rclone authorize runs the browser OAuth flow and streams the token through pipes the service reads.",
    'backend/internal/services/gamma/gamma.go::applyGammaLocked exec.Command(m.binary, "-t", '
    'strconv.Itoa(lowTemp), "-T", strconv.Itoa(highTemp), "-g", strconv.FormatFloat(state.Config.Gamma, '
    "'f', 3, 64))":
        "wlsunset is the Niri gamma adapter process; gamma starts it and watches its exit.",
    'backend/internal/services/gamma/gamma.go::applyGammaLocked exec.Command(m.binary, "--temperature", '
    'strconv.Itoa(state.CurrentTemp), "--gamma", strconv.Itoa(gammaPercent))':
        "hyprsunset is the Hyprland gamma adapter process; gamma starts it and watches its exit.",
    'backend/internal/services/networkmanager/networkmanager.go::monitor exec.CommandContext(ctx, "nmcli", "monitor")':
        "nmcli monitor is the backend-owned NetworkManager watcher.",
    'backend/internal/services/sysupdate/sysupdate.go::handleUpgrade exec.Command(argv[0], argv[1:]...)':
        "the terminal updater is an interactive upgrade process; sysupdate starts it and watches completion.",
    'backend/internal/services/tailscale/watch.go::runWatch exec.CommandContext(ctx, m.tailscale, "debug", '
    '"watch-ipn")':
        "tailscale debug watch-ipn is the backend-owned ipn bus watcher.",
    'backend/internal/runner/runner.go::runQuickshell exec.Command("qs", append(baseArgs, qsArgs...)...)':
        "the runner starts the shell process and waits for its session lifetime.",
    'backend/internal/runner/supervise.go::superviseBackend exec.Command(exe, "serve")':
        "the runner supervises the backend serve child with restart and crash-loop handling.",
}


@dataclass(frozen=True)
class FunctionRange:
    name: str
    start: int
    end: int


@dataclass(frozen=True)
class ExecCall:
    rel: str
    line: int
    function: str
    expression: str
    key: str
    output_reader: str | None


def _blank(chars: list[str], start: int, end: int) -> None:
    for index in range(start, min(end, len(chars))):
        if chars[index] != "\n":
            chars[index] = " "


def mask_go(text: str, *, strings: bool) -> str:
    """Return text with comments, and optionally strings, blanked."""
    out = list(text)
    index = 0
    length = len(text)
    while index < length:
        if text.startswith("//", index):
            end = text.find("\n", index)
            _blank(out, index, length if end == -1 else end)
            index = length if end == -1 else end
            continue
        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = length if end == -1 else end + 2
            _blank(out, index, end)
            index = end
            continue
        if not strings:
            index += 1
            continue
        char = text[index]
        if char == '"':
            end = index + 1
            while end < length:
                if text[end] == "\\":
                    end += 2
                    continue
                if text[end] == '"':
                    end += 1
                    break
                end += 1
            _blank(out, index, end)
            index = end
            continue
        if char == "`":
            end = text.find("`", index + 1)
            end = length if end == -1 else end + 1
            _blank(out, index, end)
            index = end
            continue
        if char == "'":
            end = index + 1
            while end < length:
                if text[end] == "\\":
                    end += 2
                    continue
                if text[end] == "'":
                    end += 1
                    break
                end += 1
            _blank(out, index, end)
            index = end
            continue
        index += 1
    return "".join(out)


def line_at(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def normalize(source: str) -> str:
    return " ".join(source.split())


def matching(mask: str, open_index: int, opener: str, closer: str) -> int | None:
    depth = 0
    for index in range(open_index, len(mask)):
        char = mask[index]
        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return index
    return None


def split_args(source: str, mask: str, start: int, end: int) -> list[str]:
    args: list[str] = []
    depth = {"(": 0, "[": 0, "{": 0}
    openers = {"(": ")", "[": "]", "{": "}"}
    closers = {")": "(", "]": "[", "}": "{"}
    arg_start = start
    for index in range(start, end):
        char = mask[index]
        if char in openers:
            depth[char] += 1
        elif char in closers and depth[closers[char]] > 0:
            depth[closers[char]] -= 1
        elif char == "," and not any(depth.values()):
            args.append(normalize(source[arg_start:index]))
            arg_start = index + 1
    tail = normalize(source[arg_start:end])
    if tail:
        args.append(tail)
    return args


def exec_aliases(text: str) -> set[str]:
    comment_masked = mask_go(text, strings=False)
    aliases: set[str] = set()
    pattern = re.compile(r'(?m)^\s*(?:import\s+)?(?:(?P<alias>[A-Za-z_]\w*|\.)\s+)?["`]os/exec["`]')
    for match in pattern.finditer(comment_masked):
        alias = match.group("alias") or "exec"
        if alias != "_":
            aliases.add(alias)
    return aliases


def function_ranges(mask: str) -> list[FunctionRange]:
    ranges: list[FunctionRange] = []
    pattern = re.compile(r"\bfunc\s+(?:\([^{}]*\)\s*)?(?P<name>[A-Za-z_]\w*)\s*\(")
    for match in pattern.finditer(mask):
        params_open = mask.find("(", match.start())
        if params_open == -1:
            continue
        params_close = matching(mask, params_open, "(", ")")
        if params_close is None:
            continue
        brace = mask.find("{", params_close + 1)
        if brace == -1:
            continue
        end = matching(mask, brace, "{", "}")
        if end is None:
            continue
        ranges.append(FunctionRange(match.group("name"), match.start(), end + 1))
    return ranges


def function_for(functions: list[FunctionRange], offset: int, fallback_end: int) -> FunctionRange:
    for function in functions:
        if function.start <= offset < function.end:
            return function
    return FunctionRange("<top-level>", 0, fallback_end)


def assigned_name(mask: str, call_start: int) -> str | None:
    statement_start = max(mask.rfind("\n", 0, call_start), mask.rfind(";", 0, call_start), mask.rfind("{", 0, call_start))
    prefix = mask[statement_start + 1:call_start]
    match = re.search(r"\b([A-Za-z_]\w*)\s*(?::=|=)\s*$", prefix)
    return match.group(1) if match else None


def direct_reader(mask: str, close_paren: int) -> str | None:
    index = close_paren + 1
    while index < len(mask) and mask[index].isspace():
        index += 1
    match = re.match(r"\.\s*(Output|CombinedOutput)\s*\(", mask[index:])
    return match.group(1) if match else None


def variable_reader(mask: str, name: str, start: int, end: int) -> str | None:
    reader_re = re.compile(rf"\b{re.escape(name)}\s*\.\s*(Output|CombinedOutput)\s*\(")
    assign_re = re.compile(rf"\b{re.escape(name)}\s*(?::=|=)")
    for match in reader_re.finditer(mask, start, end):
        if assign_re.search(mask, start, match.start()):
            return None
        return match.group(1)
    return None


def scan_file(path: Path) -> list[ExecCall]:
    rel = path.relative_to(REPO_ROOT).as_posix()
    text = path.read_text(encoding="utf-8")
    aliases = exec_aliases(text)
    if not aliases:
        return []

    code = mask_go(text, strings=True)
    functions = function_ranges(code)
    calls: list[ExecCall] = []
    for alias in sorted(aliases):
        if alias == ".":
            pattern = re.compile(r"(?<![\w.])(?P<name>Command|CommandContext)\s*\(")
            prefix = ""
        else:
            pattern = re.compile(rf"(?<![\w.]){re.escape(alias)}\s*\.\s*(?P<name>Command|CommandContext)\s*\(")
            prefix = f"{alias}."
        for match in pattern.finditer(code):
            open_paren = code.find("(", match.start())
            close_paren = matching(code, open_paren, "(", ")")
            if close_paren is None:
                continue
            function = function_for(functions, match.start(), len(code))
            args = split_args(text, code, open_paren + 1, close_paren)
            expression = f"{prefix}{match.group('name')}({', '.join(args)})"
            reader = direct_reader(code, close_paren)
            variable = assigned_name(code, match.start())
            if reader is None and variable is not None:
                reader = variable_reader(code, variable, close_paren + 1, function.end)
            key = f"{rel}::{function.name} {expression}"
            calls.append(
                ExecCall(
                    rel=rel,
                    line=line_at(text, match.start()),
                    function=function.name,
                    expression=expression,
                    key=key,
                    output_reader=reader,
                )
            )
    return calls


def go_files() -> list[Path]:
    if not BACKEND_INTERNAL.exists():
        return []
    out: list[Path] = []
    for path in sorted(BACKEND_INTERNAL.rglob("*.go")):
        if any(path.is_relative_to(tree) for tree in SKIP_TREES):
            continue
        out.append(path)
    return out


def main() -> int:
    unreadable: list[str] = []
    calls: list[ExecCall] = []
    files = go_files()
    if not files:
        print(
            "check-execbound-adoption: FAIL: found no Go files under backend/internal, "
            "so no backend exec sites were checked",
            file=sys.stderr,
        )
        return 1
    for path in files:
        try:
            calls.extend(scan_file(path))
        except (OSError, UnicodeDecodeError) as exc:
            unreadable.append(f"{path.relative_to(REPO_ROOT).as_posix()}: {exc}")

    if unreadable:
        print("check-execbound-adoption: FAIL: could not read backend Go file(s):", file=sys.stderr)
        for entry in unreadable:
            print(f"  {entry}", file=sys.stderr)
        return 1

    output_bypasses = [call for call in calls if call.output_reader is not None]
    unallowed_raw = [call for call in calls if call.output_reader is None and call.key not in ALLOWED_RAW_EXECS]

    if output_bypasses:
        print(
            "check-execbound-adoption: FAIL: one-shot os/exec output reads must use "
            "backend/internal/execbound:",
            file=sys.stderr,
        )
        for call in output_bypasses:
            print(
                f"  {call.rel}:{call.line}: {call.function}: {call.expression}.{call.output_reader}()",
                file=sys.stderr,
            )
    if unallowed_raw:
        print(
            "check-execbound-adoption: FAIL: raw os/exec builders outside execbound need "
            "a lifecycle reason:",
            file=sys.stderr,
        )
        for call in unallowed_raw:
            print(f"  {call.rel}:{call.line}: {call.function}: {call.expression}", file=sys.stderr)
            print(f"      allowlist key: {call.key}", file=sys.stderr)

    if output_bypasses or unallowed_raw:
        print(
            "\nUse execbound.Command for one-shot Output or CombinedOutput reads. Add an "
            "ALLOWED_RAW_EXECS entry only for a long-lived process whose lifecycle is "
            "owned outside execbound.",
            file=sys.stderr,
        )
        return 1

    print(f"check-execbound-adoption: ok ({len(calls)} raw os/exec builders checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
