#!/usr/bin/env python3
"""Sample how long the shell takes to rebuild its toplevel view after a Hyprland event.

Usage: scripts/qml-smoke.sh --require-nested --shell-env VSHELL_EVENT_PROBE=1 \\
         --driver scripts/bench-shell-events.py

The script is a qml-smoke driver: it runs inside the nested sandbox, dispatches workspace
switches to the nested Hyprland, and drains the samples quickshell/vshell/Modules/EventProbe.qml
records. It refuses to run without VSHELL_SANDBOX_DRIVER=1, which only that launch sets,
because its dispatches would otherwise move the live session's workspaces.

Two series are sampled per switch, in whole milliseconds:
  dispatch_to_view: from just before hyprctl starts to the end of the rebuild
  receipt_to_view: from the shell reading the event to the end of the rebuild
The rebuild ends on the callLater turn after every toplevelsChanged consumer returned.

Output is keyed lines:
  series name=NAME n=N p50=MS p95=MS p99=MS max=MS budget_p95=MS
  verdict=pass | verdict=over-budget series=NAME p95=MS budget_p95=MS
Refusals print `bench-shell-events: <key>=<value>` on the first line and exit 1.
Exit 0 means every series is within budget, 1 means one is over or the run failed, and
2 means the script was started outside a sandbox.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import NamedTuple

REPO_ROOT = Path(__file__).resolve().parents[1]
SHELL_PATH = REPO_ROOT / "quickshell" / "vshell"

WARMUP = 20
SAMPLES = 200
# Spacing between dispatches, long enough that one switch's rebuild never coalesces with the next.
DISPATCH_GAP_S = 0.05
# How long the last rebuild gets to land before the samples are drained.
SETTLE_S = 0.5
IPC_TIMEOUT_S = 15
# Workspace names are numbers from these bases, so each switch creates a workspace no other
# switch in the run names and its event pairs with exactly one dispatch.
WARMUP_BASE = 1000
SAMPLE_BASE = 2000

# p95 budgets in milliseconds; docs/architecture/shell.md § Invariants records the measurement
# they were set from.
BUDGET_P95_MS = {
    "dispatch_to_view": 15,
    "receipt_to_view": 4,
}


class Refusal(Exception):
    def __init__(self, key: str, value: object, detail: str):
        super().__init__(f"{key}={value}")
        self.detail = detail


class Summary(NamedTuple):
    name: str
    n: int
    p50: int
    p95: int
    p99: int
    max: int


def percentile(values: list[int], pct: int) -> int:
    """Nearest-rank percentile: the smallest value at or above pct percent of the sorted values."""
    if not values:
        raise Refusal("empty-series", 0, "A percentile of no samples is not a measurement.")
    ordered = sorted(values)
    rank = -(-pct * len(ordered) // 100)
    return ordered[max(rank, 1) - 1]


def summarize(name: str, values: list[int]) -> Summary:
    return Summary(name, len(values), percentile(values, 50), percentile(values, 95), percentile(values, 99), max(values))


def pair(dispatched: dict[str, float], samples: list[dict]) -> dict[str, list[int]]:
    """Match each dispatched workspace to the one probe sample its workspacev2 event produced.

    dispatched maps a workspace name to the wall-clock millisecond its dispatch started.
    A switch with no sample, or with more than one, refuses: either would make a percentile
    describe something other than one rebuild per switch.
    """
    by_name: dict[str, dict] = {}
    for sample in samples:
        if sample.get("event") != "workspacev2":
            continue
        name = str(sample.get("data", "")).split(",", 1)[-1]
        if name not in dispatched:
            continue
        if name in by_name:
            raise Refusal("duplicate-sample", name, "Two rebuilds were recorded for one workspace switch.")
        by_name[name] = sample
    missing = sorted(set(dispatched) - set(by_name), key=int)
    if missing:
        raise Refusal("missing-samples", len(missing),
                      f"No workspacev2 rebuild was recorded for workspaces {', '.join(missing[:10])}.")
    series: dict[str, list[int]] = {"dispatch_to_view": [], "receipt_to_view": []}
    for name, started in dispatched.items():
        sample = by_name[name]
        series["dispatch_to_view"].append(round(sample["doneMs"] - started))
        series["receipt_to_view"].append(sample["doneMs"] - sample["receivedMs"])
    return series


def verdict(summaries: list[Summary], budgets: dict[str, int]) -> list[str]:
    """Return the verdict lines; the first over-budget series, in summary order, is named."""
    for summary in summaries:
        if summary.p95 > budgets[summary.name]:
            return [f"verdict=over-budget series={summary.name} p95={summary.p95} budget_p95={budgets[summary.name]}"]
    return ["verdict=pass"]


def run(argv: list[str], what: str) -> str:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=IPC_TIMEOUT_S, check=False)
    except subprocess.TimeoutExpired:
        raise Refusal("timeout", what, f"{argv[0]} did not answer within {IPC_TIMEOUT_S}s.") from None
    if done.returncode != 0:
        raise Refusal("command-failed", what, f"exit {done.returncode}: {(done.stderr or done.stdout).strip()}")
    return done.stdout.strip()


def drain() -> list[dict]:
    reply = run(["qs", "ipc", "-p", str(SHELL_PATH), "--any-display", "call", "event-probe", "drain"], "event-probe drain")
    try:
        samples = json.loads(reply)
    except json.JSONDecodeError:
        raise Refusal("probe-reply", "not-json", f"event-probe drain answered: {reply[:200]}") from None
    if not isinstance(samples, list):
        raise Refusal("probe-reply", type(samples).__name__, "event-probe drain must answer a JSON array.")
    return samples


def switch_all(base: int, count: int) -> dict[str, float]:
    dispatched: dict[str, float] = {}
    for index in range(count):
        name = str(base + index)
        started = time.time_ns() / 1_000_000
        reply = run(["hyprctl", "dispatch", f"hl.dsp.focus({{ workspace = {name} }})"], f"switch to {name}")
        if reply != "ok":
            raise Refusal("dispatch-reply", name, f"hyprctl answered: {reply}")
        dispatched[name] = started
        time.sleep(DISPATCH_GAP_S)
    time.sleep(SETTLE_S)
    return dispatched


def main() -> int:
    if os.environ.get("VSHELL_SANDBOX_DRIVER") != "1":
        print("bench-shell-events: not-in-sandbox=VSHELL_SANDBOX_DRIVER", file=sys.stderr)
        print("  Run it as a scripts/qml-smoke.sh --driver; its dispatches would move live workspaces.", file=sys.stderr)
        return 2
    try:
        drain()
        switch_all(WARMUP_BASE, WARMUP)
        drain()
        dispatched = switch_all(SAMPLE_BASE, SAMPLES)
        series = pair(dispatched, drain())
        summaries = [summarize(name, values) for name, values in series.items()]
    except Refusal as refusal:
        print(f"bench-shell-events: {refusal}", file=sys.stderr)
        print(f"  {refusal.detail}", file=sys.stderr)
        return 1
    for s in summaries:
        print(f"series name={s.name} n={s.n} p50={s.p50} p95={s.p95} p99={s.p99} max={s.max} budget_p95={BUDGET_P95_MS[s.name]}")
    lines = verdict(summaries, BUDGET_P95_MS)
    print("\n".join(lines))
    return 0 if lines == ["verdict=pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
