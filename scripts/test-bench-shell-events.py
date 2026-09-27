#!/usr/bin/env python3
"""Drive scripts/bench-shell-events.py's pairing, percentile and budget verdict on recorded samples.

The functions under test are loaded from the shipped script, and the sandbox refusal runs the
script itself, so no case needs a compositor or a shell.
"""

from __future__ import annotations

import contextlib
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "bench-shell-events.py"

spec = importlib.util.spec_from_file_location("bench_shell_events", SCRIPT)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)

failures = 0


def fail(case: str, message: str) -> None:
    global failures
    failures += 1
    print(f"FAIL [{case}]: {message}", file=sys.stderr)


def sample(name: str, received: int, done: int, event: str = "workspacev2") -> dict:
    return {"event": event, "data": f"{name},{name}", "receivedMs": received, "doneMs": done}


def refusal_key(call) -> str:
    try:
        call()
    except bench.Refusal as refusal:
        return str(refusal)
    return "no-refusal"


def main() -> int:
    # values; percentile; expected nearest-rank value.
    percentiles = [
        ([7], 50, 7),
        ([7], 99, 7),
        (list(range(1, 101)), 50, 50),
        (list(range(1, 101)), 95, 95),
        (list(range(1, 101)), 99, 99),
        ([5, 1, 4, 2, 3], 50, 3),
        ([5, 1, 4, 2, 3], 95, 5),
    ]
    for values, pct, want in percentiles:
        got = bench.percentile(values, pct)
        if got != want:
            fail("percentile", f"p{pct} of {values[:5]}... ({len(values)} values): expected {want}, got {got}")
    if refusal_key(lambda: bench.percentile([], 50)) != "empty-series=0":
        fail("percentile", "no samples must refuse rather than report a percentile")

    dispatched = {"2000": 100.4, "2001": 200.0}
    got = bench.pair(dispatched, [
        sample("2000", 103, 104),
        # An event the switch did not dispatch and a non-workspace event are not samples of a switch.
        sample("999", 150, 151),
        sample("2001", 205, 209, event="activewindowv2"),
        sample("2001", 202, 207),
    ])
    if got != {"dispatch_to_view": [4, 7], "receipt_to_view": [1, 5]}:
        fail("pair", f"expected each switch paired with its own workspacev2 sample, got {got}")

    # label; samples; expected refusal.
    pair_refusals = [
        ("a switch with no sample", [sample("2000", 103, 104)], "missing-samples=1"),
        ("a sample under another event name only", [sample("2000", 103, 104), sample("2001", 202, 207, event="activewindowv2")], "missing-samples=1"),
        ("two samples for one switch", [sample("2000", 103, 104), sample("2000", 105, 106), sample("2001", 202, 207)], "duplicate-sample=2000"),
    ]
    for label, samples, want in pair_refusals:
        got_key = refusal_key(lambda: bench.pair(dispatched, samples))
        if got_key != want:
            fail("pair refusal", f"{label}: expected {want}, got {got_key}")

    budgets = {"dispatch_to_view": 20, "receipt_to_view": 4}
    # label; dispatch p95; receipt p95; expected verdict lines.
    verdicts = [
        ("both within budget", 20, 4, ["verdict=pass"]),
        ("dispatch over budget", 21, 4, ["verdict=over-budget series=dispatch_to_view p95=21 budget_p95=20"]),
        ("receipt over budget", 20, 5, ["verdict=over-budget series=receipt_to_view p95=5 budget_p95=4"]),
        ("both over budget names the first", 30, 9, ["verdict=over-budget series=dispatch_to_view p95=30 budget_p95=20"]),
    ]
    for label, dispatch_p95, receipt_p95, want in verdicts:
        summaries = [
            bench.Summary("dispatch_to_view", 200, 1, dispatch_p95, dispatch_p95, dispatch_p95),
            bench.Summary("receipt_to_view", 200, 1, receipt_p95, receipt_p95, receipt_p95),
        ]
        got_lines = bench.verdict(summaries, budgets)
        if got_lines != want:
            fail("verdict", f"{label}: expected {want}, got {got_lines}")

    # Drive main() past the sandbox check with the shell and compositor calls replaced: its exit
    # status is the row's only verdict.
    def run_main(samples_for) -> int:
        saved = (bench.drain, bench.switch_all, bench.os.environ.get("VSHELL_SANDBOX_DRIVER"))
        dispatched: dict[str, float] = {}

        def switch_all(base: int, count: int) -> dict[str, float]:
            dispatched.clear()
            dispatched.update({str(base + i): 1000.0 * i for i in range(count)})
            return dict(dispatched)

        bench.switch_all = switch_all
        bench.drain = lambda: samples_for(dispatched)
        bench.os.environ["VSHELL_SANDBOX_DRIVER"] = "1"
        try:
            with open(os.devnull, "w") as sink, contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
                return bench.main()
        finally:
            bench.drain, bench.switch_all = saved[0], saved[1]
            if saved[2] is None:
                bench.os.environ.pop("VSHELL_SANDBOX_DRIVER", None)
            else:
                bench.os.environ["VSHELL_SANDBOX_DRIVER"] = saved[2]

    def samples_taking(ms: int):
        return lambda dispatched: [sample(name, int(started), int(started) + ms) for name, started in dispatched.items()]

    # label; samples the probe answers per drain; expected exit status.
    mains = [
        ("in-budget samples pass", samples_taking(1), 0),
        ("over-budget samples fail", samples_taking(bench.BUDGET_P95_MS["receipt_to_view"] + 1), 1),
        ("a refusal fails", lambda dispatched: [], 1),
    ]
    for label, samples_for, want in mains:
        got_exit = run_main(samples_for)
        if got_exit != want:
            fail("main exit", f"{label}: expected exit {want}, got {got_exit}")

    # An empty PATH and no compositor variables: if the refusal regressed, the script must find
    # no hyprctl or qs to move a live session's workspaces with.
    with tempfile.TemporaryDirectory() as empty:
        done = subprocess.run([sys.executable, str(SCRIPT)], env={"PATH": empty}, capture_output=True, text=True, timeout=30, check=False)
    if done.returncode != 2 or done.stderr.splitlines()[:1] != ["bench-shell-events: not-in-sandbox=VSHELL_SANDBOX_DRIVER"] or done.stdout:
        fail("sandbox refusal", f"expected exit 2 and not-in-sandbox, got exit {done.returncode}, stderr {done.stderr!r}")

    if failures:
        print(f"test-bench-shell-events: failures={failures}", file=sys.stderr)
        return 1
    print("test-bench-shell-events: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
