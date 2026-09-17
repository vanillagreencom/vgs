#!/usr/bin/env python3
"""Attribute net heap growth between two jemalloc heap profile dumps to threads.

Usage: attribute-heap-profile.py BASE HEAD [--thread NAME] [--top N] [--no-symbols]

BASE and HEAD are `.heap` dumps from one process, written by jemalloc with
`prof:true,prof_sys_thread_name:true` and named `<prefix>.<pid>.<seq>.<kind><seq>.heap`.
docs/architecture/memory.md § What sampling cannot attribute says why an
in-process profile is needed.

Byte and object counts are jemalloc samples scaled to estimates the way jeprof
scales them: a stack whose samples average X bytes at sample period P is
multiplied by 1 / (1 - exp(-X / P)). `samples=` is the raw sampled object count
behind each estimate, so a small count marks a wide error.

Output is keyed lines, one record per line, in this order:
  profile base=PATH head=PATH pid=N sample_period=BYTES
  thread uid=N name=NAME base_bytes=N head_bytes=N delta_bytes=N samples=N
  share thread=NAME delta_bytes=N total_delta_bytes=N share_pct=F | status=no-growth
  library thread=NAME file=PATH delta_bytes=N
  stack rank=N thread=NAME delta_bytes=N head_bytes=N samples=N caller=PATH
    frame addr=0x... file=PATH function=NAME location=FILE:LINE [inlined_into=NAME] [resolution=symbol-table-only]
`thread` rows cover every thread, largest growth first. `library` and `stack`
rows cover only the threads named by --thread. A stack's caller is its innermost
frame outside the allocation wrappers in ALLOCATION_WRAPPERS; `library` sums
stacks by caller, and `frame` rows start at the caller. With --no-symbols, `frame`
rows are omitted. `resolution=symbol-table-only` marks a frame eu-addr2line named
without a source location: with no debug info, a local function takes the name of
the nearest exported symbol, so that name may be wrong.

Refusals print `attribute-heap-profile: <key>=<value>` on the first line and exit 1.
"""

from __future__ import annotations

import argparse
import math
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import NamedTuple

DUMP_NAME = re.compile(r"\.(\d+)\.\d+\.[fimu]\d+\.heap$")
COUNTS = re.compile(r"^\s+t(\*|\d+): (\d+): (\d+) \[\d+: \d+\](?: (.*))?$")
MAP_LINE = re.compile(r"^([0-9a-f]+)-([0-9a-f]+) \S+ [0-9a-f]+ \S+ \d+\s*(.*)$")
ADDRESS_LINE = re.compile(r"^0x[0-9a-f]{16}$")

# Library basenames whose frames allocate on a caller's behalf rather than own the
# allocation: the allocator itself, operator new, and libc's allocating helpers.
ALLOCATION_WRAPPERS = ("libjemalloc.so", "libstdc++.so", "libc.so")
# Frames printed per stack, counted from the caller outward.
FRAME_LIMIT = 16


class Growth(NamedTuple):
    delta: float
    head: float
    samples: int
    # Frames from the caller outward, and the file that maps the first of them.
    callers: list[int]
    caller: str


class Refusal(Exception):
    def __init__(self, key: str, value: object, detail: str) -> None:
        super().__init__(f"{key}={value}")
        self.detail = detail


@dataclass
class Dump:
    path: Path
    pid: int
    period: int
    names: dict[str, str] = field(default_factory=dict)
    # stack -> thread uid -> (objects, bytes), raw samples.
    stacks: dict[tuple[int, ...], dict[str, tuple[int, int]]] = field(default_factory=dict)
    maps: list[tuple[int, int, str]] = field(default_factory=list)
    # The section verbatim: eu-addr2line needs each mapping's file offset.
    maps_text: list[str] = field(default_factory=list)


def parse_dump(path: Path) -> Dump:
    match = DUMP_NAME.search(path.name)
    if not match:
        raise Refusal("unrecognised-dump-name", path, "Expected <prefix>.<pid>.<seq>.<kind><seq>.heap as jemalloc writes it.")
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as error:
        raise Refusal("unreadable-dump", path, str(error)) from error
    if not lines or not lines[0].startswith("heap_v2/"):
        raise Refusal("malformed-dump", f"{path}:1", "The first line must be heap_v2/<sample period>.")
    dump = Dump(path, int(match.group(1)), int(lines[0].split("/", 1)[1]))
    stack: tuple[int, ...] | None = None
    in_maps = False
    for number, line in enumerate(lines[1:], start=2):
        if in_maps:
            dump.maps_text.append(line)
            mapped = MAP_LINE.match(line)
            if mapped and mapped.group(3):
                dump.maps.append((int(mapped.group(1), 16), int(mapped.group(2), 16), mapped.group(3)))
            continue
        if line == "MAPPED_LIBRARIES:":
            in_maps = True
        elif line.startswith("@ "):
            stack = tuple(int(token, 16) for token in line[2:].split())
            dump.stacks[stack] = {}
        elif counts := COUNTS.match(line):
            uid, objects, size, name = counts.groups()
            if stack is None:
                if uid != "*":
                    dump.names[uid] = name or ""
            elif uid != "*":
                dump.stacks[stack][uid] = (int(objects), int(size))
        elif line.strip():
            raise Refusal("malformed-dump", f"{path}:{number}", "The line is neither a count, a stack nor a mapping.")
    if not in_maps:
        raise Refusal("malformed-dump", path, "The dump has no MAPPED_LIBRARIES section; it may be truncated.")
    return dump


def estimate(objects: int, size: int, period: int) -> float:
    if objects == 0:
        return 0.0
    return size / (1 - math.exp(-(size / objects) / period))


def mapped_file(dump: Dump, address: int) -> str:
    for start, end, name in dump.maps:
        if start <= address < end:
            return name
    return "[unmapped]"


def is_wrapper(name: str) -> bool:
    return any(os.path.basename(name).startswith(prefix) for prefix in ALLOCATION_WRAPPERS)


def symbolize(dump: Dump, addresses: list[int]) -> dict[int, list[tuple[str, str]]]:
    """Resolve addresses with eu-addr2line against the dump's own mappings."""
    if not addresses:
        return {}
    with tempfile.NamedTemporaryFile("w", suffix=".maps") as maps:
        maps.write("\n".join(dump.maps_text) + "\n")
        maps.flush()
        command = ["eu-addr2line", "-M", maps.name, "-a", "-f", "-C", "-i", *(f"0x{a:x}" for a in addresses)]
        try:
            result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=1800)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise Refusal("symbolizer-failed", "eu-addr2line", str(error)) from error
    frames: dict[int, list[str]] = {}
    current: list[str] | None = None
    for line in result.stdout.splitlines():
        if ADDRESS_LINE.match(line):
            current = []
            frames[int(line, 16)] = current
        elif current is not None:
            current.append(line)
    if set(frames) != set(addresses):
        # eu-addr2line also exits non-zero when an address is merely unresolved, so
        # completeness of the answer, not the status, is the failure test.
        raise Refusal("symbolizer-failed", f"answered={len(frames)}/{len(addresses)}", result.stderr.strip())
    return {address: list(zip(lines[0::2], lines[1::2])) for address, lines in frames.items()}


def attribute(base: Dump, head: Dump, thread: str, top: int, symbols: bool) -> list[str]:
    if base.pid != head.pid:
        raise Refusal("pid-mismatch", f"{base.pid},{head.pid}", "Both dumps must come from one process.")
    if base.period != head.period:
        raise Refusal("sample-period-mismatch", f"{base.period},{head.period}", "Both dumps must use one lg_prof_sample.")
    for uid, name in base.names.items():
        if uid in head.names and head.names[uid] != name:
            raise Refusal("thread-name-changed", f"t{uid}", f"{name!r} in base, {head.names[uid]!r} in head.")
    names = {**base.names, **head.names}
    selected = {uid for uid, name in names.items() if name == thread}
    if not selected:
        raise Refusal("thread-not-found", thread, "No thread in either dump carries that name.")

    def scaled(dump: Dump, key: tuple[int, ...], uids: set[str] | None) -> tuple[float, int]:
        rows = [v for u, v in dump.stacks.get(key, {}).items() if uids is None or u in uids]
        return sum(estimate(o, s, dump.period) for o, s in rows), sum(o for o, _ in rows)

    out = [f"profile base={base.path} head={head.path} pid={head.pid} sample_period={head.period}"]
    keys = set(base.stacks) | set(head.stacks)
    rows = []
    for uid in names:
        before = sum(scaled(base, k, {uid})[0] for k in base.stacks)
        after, samples = 0.0, 0
        for k in head.stacks:
            b, n = scaled(head, k, {uid})
            after, samples = after + b, samples + n
        rows.append((after - before, uid, before, after, samples))
    rows.sort(key=lambda row: (-row[0], int(row[1])))
    for delta, uid, before, after, samples in rows:
        out.append(f"thread uid={uid} name={names[uid]} base_bytes={before:.0f} head_bytes={after:.0f} delta_bytes={delta:.0f} samples={samples}")
    total = sum(row[0] for row in rows)
    mine = sum(row[0] for row in rows if row[1] in selected)
    if total > 0:
        out.append(f"share thread={thread} delta_bytes={mine:.0f} total_delta_bytes={total:.0f} share_pct={100 * mine / total:.1f}")
    else:
        out.append(f"share thread={thread} delta_bytes={mine:.0f} total_delta_bytes={total:.0f} status=no-growth")

    growth: list[Growth] = []
    for key in sorted(keys):
        before = scaled(base, key, selected)[0]
        after, samples = scaled(head, key, selected)
        if before or after:
            frames = list(key[:1]) + [address - 1 for address in key[1:]]  # return addresses point past the call
            first = next((i for i, a in enumerate(frames) if not is_wrapper(mapped_file(head, a))), len(frames))
            callers = frames[first:]
            caller = mapped_file(head, callers[0]) if callers else "[allocation-wrappers-only]"
            growth.append(Growth(after - before, after, samples, callers, caller))
    by_library: dict[str, float] = {}
    for row in growth:
        by_library[row.caller] = by_library.get(row.caller, 0.0) + row.delta
    for name, delta in sorted(by_library.items(), key=lambda item: (-item[1], item[0])):
        out.append(f"library thread={thread} file={name} delta_bytes={delta:.0f}")

    growth.sort(key=lambda row: (-row.delta, row.callers))
    ranked = growth[:top]
    wanted = sorted({a for row in ranked for a in row.callers[:FRAME_LIMIT]})
    resolved = symbolize(head, wanted) if symbols else {}
    for rank, row in enumerate(ranked, start=1):
        out.append(f"stack rank={rank} thread={thread} delta_bytes={row.delta:.0f} head_bytes={row.head:.0f} samples={row.samples} caller={row.caller}")
        for address in row.callers[:FRAME_LIMIT] if symbols else []:
            chain = resolved[address]
            function, location = chain[0][0].split(" inlined at ", 1)[0], chain[0][1]
            line = f"  frame addr=0x{address:x} file={mapped_file(head, address)} function={function} location={location}"
            if len(chain) > 1:
                line += f" inlined_into={chain[-1][0]}"
            if function != "??" and location.startswith("??"):
                line += " resolution=symbol-table-only"
            out.append(line)
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description="Attribute heap growth between two jemalloc dumps to threads.")
    parser.add_argument("base", type=Path)
    parser.add_argument("head", type=Path)
    parser.add_argument("--thread", default="WaylandEventThr", help="thread name to break down by stack (default WaylandEventThr)")
    parser.add_argument("--top", type=int, default=20, help="stacks to print (default 20)")
    parser.add_argument("--no-symbols", action="store_true", help="skip eu-addr2line and print no frame rows")
    args = parser.parse_args()
    if args.top < 1:
        parser.error("--top must be at least 1")
    try:
        lines = attribute(parse_dump(args.base), parse_dump(args.head), args.thread, args.top, not args.no_symbols)
    except Refusal as refusal:
        print(f"attribute-heap-profile: {refusal}", file=sys.stderr)
        print(f"  {refusal.detail}", file=sys.stderr)
        return 1
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
