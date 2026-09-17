#!/usr/bin/env python3
"""Drive scripts/attribute-heap-profile.py against hand-written jemalloc dumps.

Every case writes a heap_v2 dump pair, runs the script and pins output keys,
values and the exit status. Symbolization runs against a stub eu-addr2line placed
first on PATH, so no case needs debug info, a network or a real profile.
"""

from __future__ import annotations

import math
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "attribute-heap-profile.py"
PERIOD = 524288

MAPS = """MAPPED_LIBRARIES:
7f0000000000-7f0000100000 r-xp 00000000 00:23 1 /usr/lib/libjemalloc.so.2
7f0000100000-7f0000200000 r-xp 00000000 00:23 2 /usr/lib/libstdc++.so.6.0.36
7f0000200000-7f0000300000 r-xp 00000000 00:23 3 /usr/lib/libwayland-client.so.0.26.0
7f0000300000-7f0000400000 r-xp 00000000 00:23 4 /usr/lib/libQt6WaylandClient.so.6.11.2
7f0000400000-7f0000500000 r-xp 00000000 00:23 5 /usr/bin/quickshell
7f0000600000-7f0000700000 r-xp 00000000 00:23 6 /usr/lib/libc.so.6
7f0000500000-7f0000600000 rw-p 00000000 00:00 0
"""

# Stacks as jemalloc prints them: allocator frames first, return addresses after.
WAYLAND = "@ 0x7f0000000010 0x7f0000200020 0x7f0000300030"
QT_VIA_NEW = "@ 0x7f0000000010 0x7f0000100040 0x7f0000300050"
MAIN = "@ 0x7f0000000010 0x7f0000400060"
VIA_LIBC = "@ 0x7f0000000010 0x7f0000600070 0x7f0000400080"

# Two threads share the selected name, as the two Wayland event threads do.
HEADER = "  t0: 0: 0 [0: 0] qs\n  t1: 0: 0 [0: 0] WaylandEventThr\n  t2: 0: 0 [0: 0] WaylandEventThr\n"

STUB = """#!/bin/sh
# Answers nothing unless the -M file holds the fixture's mappings, as eu-addr2line
# resolves nothing without them. Otherwise answers each address with one inlined
# pair and one plain pair, except $STUB_PLAIN with one pair, $STUB_UNRESOLVED with a
# name and no location, and $STUB_DROP not at all.
while [ "$#" -gt 0 ]; do
  case "$1" in
    -M) grep -q ' /usr/lib/libwayland-client.so.0.26.0$' "$2" || exit 1; shift 2 ;;
    -*) shift ;;
    *) a=$(printf '0x%016x' "$1")
       if [ "$1" = "$STUB_DROP" ]; then :
       elif [ "$1" = "$STUB_PLAIN" ]; then printf '%s\\nplain_%s\\nplain.cpp:3\\n' "$a" "$1"
       elif [ "$1" = "$STUB_UNRESOLVED" ]; then printf '%s\\nexported_%s\\n??:0\\n' "$a" "$1"
       else printf '%s\\ninner_%s inlined at a.cpp:1 in outer\\ninner.h:2\\nouter_%s\\na.cpp:1\\n' "$a" "$1" "$1"
       fi
       shift ;;
  esac
done
exit 1
"""

failures = 0


def fail(case: str, message: str) -> None:
    global failures
    failures += 1
    print(f"FAIL [{case}]: {message}", file=sys.stderr)


def scaled(objects: int, size: int) -> float:
    return size / (1 - math.exp(-(size / objects) / PERIOD))


def dump(path: Path, blocks: list[tuple[str, dict[int, tuple[int, int]]]], header: str = HEADER, period: int = PERIOD, maps: str = MAPS) -> Path:
    body = [f"heap_v2/{period}", header.rstrip("\n")]
    for stack, threads in blocks:
        body.append(stack)
        body.extend(f"  t{uid}: {objects}: {size} [0: 0]" for uid, (objects, size) in threads.items())
    path.write_text("\n".join(body) + "\n\n" + maps, encoding="utf-8")
    return path


def run(tmp: Path, *args: str, drop: str = "", plain: str = "", unresolved: str = "") -> tuple[int, list[str], str]:
    env = {"PATH": f"{tmp / 'bin'}:/usr/bin:/bin", "STUB_DROP": drop, "STUB_PLAIN": plain, "STUB_UNRESOLVED": unresolved, "LC_ALL": "C.UTF-8"}
    result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=env, check=False)
    return result.returncode, result.stdout.splitlines(), result.stderr


def expect_line(case: str, lines: list[str], line: str) -> None:
    if line not in lines:
        fail(case, f"missing line {line!r} in {lines!r}")


def main() -> int:
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        (tmp / "bin").mkdir()
        stub = tmp / "bin" / "eu-addr2line"
        stub.write_text(STUB, encoding="utf-8")
        stub.chmod(0o755)

        base = dump(tmp / "p.100.0.i0.heap", [(WAYLAND, {1: (2, 8192)}), (MAIN, {0: (1, 4096)})])
        head = dump(
            tmp / "p.100.1.i1.heap",
            [
                (WAYLAND, {1: (6, 24576), 2: (4, 16384)}),
                (QT_VIA_NEW, {1: (1, 65536), 0: (3, 3072)}),
                (MAIN, {0: (2, 8192)}),
                (VIA_LIBC, {2: (1, 64)}),
            ],
        )
        wayland_delta = scaled(6, 24576) + scaled(4, 16384) - scaled(2, 8192)
        qt_delta = scaled(1, 65536)
        libc_delta = scaled(1, 64)
        main_delta = scaled(3, 3072) + scaled(2, 8192) - scaled(1, 4096)
        selected_delta = wayland_delta + qt_delta + libc_delta
        total = selected_delta + main_delta

        code, lines, err = run(tmp, str(base), str(head), "--no-symbols")
        case = "attribution"
        if code != 0:
            fail(case, f"exit {code}: {err}")
        # Thread and library rows run largest growth first; no fixture order, uid order
        # or name order gives these sequences.
        rows = [
            f"thread uid=1 name=WaylandEventThr base_bytes={scaled(2, 8192):.0f} head_bytes={scaled(6, 24576) + qt_delta:.0f} delta_bytes={scaled(6, 24576) - scaled(2, 8192) + qt_delta:.0f} samples=7",
            f"thread uid=2 name=WaylandEventThr base_bytes=0 head_bytes={scaled(4, 16384) + libc_delta:.0f} delta_bytes={scaled(4, 16384) + libc_delta:.0f} samples=5",
            f"thread uid=0 name=qs base_bytes={scaled(1, 4096):.0f} head_bytes={scaled(3, 3072) + scaled(2, 8192):.0f} delta_bytes={main_delta:.0f} samples=5",
            f"share thread=WaylandEventThr delta_bytes={selected_delta:.0f} total_delta_bytes={total:.0f} share_pct={100 * selected_delta / total:.1f}",
            # The caller skips libjemalloc, libstdc++ on the operator-new stack and libc.
            f"library thread=WaylandEventThr file=/usr/lib/libwayland-client.so.0.26.0 delta_bytes={wayland_delta:.0f}",
            f"library thread=WaylandEventThr file=/usr/lib/libQt6WaylandClient.so.6.11.2 delta_bytes={qt_delta:.0f}",
            f"library thread=WaylandEventThr file=/usr/bin/quickshell delta_bytes={libc_delta:.0f}",
            # Both selected threads' bytes on one stack are summed.
            f"stack rank=1 thread=WaylandEventThr delta_bytes={wayland_delta:.0f} head_bytes={scaled(6, 24576) + scaled(4, 16384):.0f} samples=10 caller=/usr/lib/libwayland-client.so.0.26.0",
            # The shared stack counts only the selected threads' bytes, not t0's.
            f"stack rank=2 thread=WaylandEventThr delta_bytes={qt_delta:.0f} head_bytes={qt_delta:.0f} samples=1 caller=/usr/lib/libQt6WaylandClient.so.6.11.2",
            f"stack rank=3 thread=WaylandEventThr delta_bytes={libc_delta:.0f} head_bytes={libc_delta:.0f} samples=1 caller=/usr/bin/quickshell",
        ]
        if lines[1:] != rows:
            fail(case, f"expected the rows in order {rows!r}, got {lines[1:]!r}")

        plain, unresolved = 0x7F0000300050 - 1, 0x7F0000400080 - 1
        code, lines, err = run(tmp, str(base), str(head), "--top", "3", plain=f"{plain:#x}", unresolved=f"{unresolved:#x}")
        case = "frames"
        if code != 0:
            fail(case, f"exit {code}: {err}")
        # Frames start at the caller, and every frame after the first is a return
        # address less one. Only a named frame with no location is marked.
        frames = [
            f"  frame addr=0x{address:x} file={file} function=inner_0x{address:x} location=inner.h:2 inlined_into=outer_0x{address:x}"
            for address, file in ((0x7F0000200020 - 1, "/usr/lib/libwayland-client.so.0.26.0"), (0x7F0000300030 - 1, "/usr/lib/libQt6WaylandClient.so.6.11.2"))
        ] + [
            f"  frame addr=0x{plain:x} file=/usr/lib/libQt6WaylandClient.so.6.11.2 function=plain_0x{plain:x} location=plain.cpp:3",
            f"  frame addr=0x{unresolved:x} file=/usr/bin/quickshell function=exported_0x{unresolved:x} location=??:0 resolution=symbol-table-only",
        ]
        if [line for line in lines if line.startswith("  frame ")] != frames:
            fail(case, f"expected frame rows {frames!r}, got {lines!r}")

        code, _, err = run(tmp, str(base), str(head), "--top", "1", drop=f"{0x7F0000200020 - 1:#x}")
        if code != 1 or not err.startswith("attribute-heap-profile: symbolizer-failed=answered=1/2\n"):
            fail("symbolizer-incomplete", f"exit {code}: {err!r}")

        refusals = [
            ("pid-mismatch", [str(base), str(dump(tmp / "p.200.1.i1.heap", []))], "pid-mismatch=100,200"),
            ("sample-period-mismatch", [str(base), str(dump(tmp / "p.100.2.i2.heap", [], period=PERIOD * 2))], f"sample-period-mismatch={PERIOD},{PERIOD * 2}"),
            ("thread-name-changed", [str(base), str(dump(tmp / "p.100.3.i3.heap", [], header="  t1: 0: 0 [0: 0] QThread\n"))], "thread-name-changed=t1"),
            ("thread-not-found", [str(base), str(head), "--thread", "QSGRenderThread"], "thread-not-found=QSGRenderThread"),
            ("truncated", [str(base), str(dump(tmp / "p.100.4.i4.heap", [], maps=""))], f"malformed-dump={tmp / 'p.100.4.i4.heap'}"),
            ("dump-name", [str(base), str(dump(tmp / "head.heap", []))], f"unrecognised-dump-name={tmp / 'head.heap'}"),
        ]
        for case, args, key in refusals:
            code, lines, err = run(tmp, *args, "--no-symbols")
            if code != 1 or err.splitlines()[:1] != [f"attribute-heap-profile: {key}"] or lines:
                fail(case, f"expected exit 1 and {key!r}, got exit {code}, stderr {err!r}, stdout {lines!r}")

        shrink = dump(tmp / "p.100.5.i5.heap", [(WAYLAND, {1: (1, 4096)})])
        code, lines, err = run(tmp, str(base), str(shrink), "--no-symbols")
        delta = scaled(1, 4096) - scaled(2, 8192) - scaled(1, 4096)
        expect_line("no-growth", lines, f"share thread=WaylandEventThr delta_bytes={scaled(1, 4096) - scaled(2, 8192):.0f} total_delta_bytes={delta:.0f} status=no-growth")
        if code != 0:
            fail("no-growth", f"exit {code}: {err}")

    if failures:
        print(f"test-attribute-heap-profile: failures={failures}", file=sys.stderr)
        return 1
    print("test-attribute-heap-profile: ok")
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(main())
