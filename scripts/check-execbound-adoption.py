#!/usr/bin/env python3
"""Keep one-shot backend output reads on execbound."""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(os.environ.get("VGS_EXECBOUND_REPO_ROOT", Path(__file__).resolve().parents[1])).resolve()
ANALYZER = Path(__file__).with_suffix(".go")

# Raw os/exec sites that intentionally start a process whose lifecycle outlives
# a single output read. Every entry needs the process reason, because an
# unreasoned raw exec site is exactly what hides a bypass.
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
class Finding:
    rel: str
    line: int
    function: str
    expression: str
    key: str = ""
    receiver: str = ""


def resolve_go() -> str | None:
    go = shutil.which("go")
    if go is None:
        print("check-execbound-adoption: FAIL: go is required to run the Go analyzer", file=sys.stderr)
        return None
    return go


def run_analyzer(go: str) -> dict[str, object] | None:
    if not ANALYZER.is_file():
        print(f"check-execbound-adoption: FAIL: missing Go analyzer: {ANALYZER}", file=sys.stderr)
        return None
    result = subprocess.run([go, "run", str(ANALYZER), str(REPO_ROOT)], text=True, capture_output=True, check=False)
    if result.returncode != 0:
        print("check-execbound-adoption: FAIL: Go analyzer failed:", file=sys.stderr)
        print(result.stdout + result.stderr, file=sys.stderr)
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        print(f"check-execbound-adoption: FAIL: Go analyzer returned invalid JSON: {exc}", file=sys.stderr)
        print(result.stdout + result.stderr, file=sys.stderr)
        return None


def typecheck_backend(go: str) -> bool:
    backend = REPO_ROOT / "backend"
    if not (backend / "go.mod").is_file():
        return True
    result = subprocess.run([go, "test", "./...", "-run", "^$"], cwd=backend, text=True, capture_output=True, check=False)
    if result.returncode == 0:
        return True
    print("check-execbound-adoption: FAIL: could not type-check backend Go package(s):", file=sys.stderr)
    print(result.stdout + result.stderr, file=sys.stderr)
    return False


def findings(report: dict[str, object], key: str) -> list[Finding]:
    rows = report.get(key)
    if not isinstance(rows, list):
        return []
    return [Finding(**row) for row in rows]


def print_parse_errors(errors: object) -> bool:
    if not isinstance(errors, list) or not errors:
        return False
    print("check-execbound-adoption: FAIL: could not parse backend Go file(s):", file=sys.stderr)
    for entry in errors:
        print(f"  {entry}", file=sys.stderr)
    return True


def main() -> int:
    go = resolve_go()
    if go is None:
        return 1
    report = run_analyzer(go)
    if report is None:
        return 1
    if print_parse_errors(report.get("parse_errors")):
        return 1
    if not report.get("files_checked"):
        print(
            "check-execbound-adoption: FAIL: found no Go files under backend/internal, "
            "so no backend exec sites were checked",
            file=sys.stderr,
        )
        return 1

    output_reads = findings(report, "output_reads")
    references = findings(report, "references")
    raw_calls = findings(report, "raw_calls")
    unallowed_raw = [call for call in raw_calls if call.key not in ALLOWED_RAW_EXECS]

    if references:
        print(
            "check-execbound-adoption: FAIL: os/exec command builders must be called directly "
            "so the guard can see the process lifecycle:",
            file=sys.stderr,
        )
        for reference in references:
            print(
                f"  {reference.rel}:{reference.line}: {reference.function}: "
                f"{reference.expression} referenced without a call",
                file=sys.stderr,
            )
    if output_reads:
        print(
            "check-execbound-adoption: FAIL: one-shot os/exec output reads must use "
            "backend/internal/execbound:",
            file=sys.stderr,
        )
        for read in output_reads:
            suffix = f" (receiver {read.receiver})" if read.receiver else ""
            print(f"  {read.rel}:{read.line}: {read.function}: {read.expression}{suffix}", file=sys.stderr)
    if unallowed_raw:
        print(
            "check-execbound-adoption: FAIL: raw os/exec builders outside execbound need "
            "a lifecycle reason:",
            file=sys.stderr,
        )
        for call in unallowed_raw:
            print(f"  {call.rel}:{call.line}: {call.function}: {call.expression}", file=sys.stderr)
            print(f"      allowlist key: {call.key}", file=sys.stderr)

    if references or output_reads or unallowed_raw:
        print(
            "\nUse execbound.Command for one-shot Output or CombinedOutput reads. Call "
            "raw os/exec builders directly only at long-lived process sites, and add an "
            "ALLOWED_RAW_EXECS entry when that lifecycle is owned outside execbound.",
            file=sys.stderr,
        )
        return 1

    if not typecheck_backend(go):
        return 1

    print(f"check-execbound-adoption: ok ({len(raw_calls)} raw os/exec builders checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
