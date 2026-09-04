#!/usr/bin/env python3
"""Keep backend one-shot raw exec output reads on execbound."""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_REPO_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(os.environ.get("VGS_EXECBOUND_REPO_ROOT", DEFAULT_REPO_ROOT)).resolve()
ANALYZER = Path(__file__).with_suffix(".go")

# These processes must outlive a single output read; each entry names why.
ALLOWED_RAW_EXECS = {
    'backend/internal/services/clipboard/wayland.go::wlCopy exec.Command("wl-copy", args...)': "wl-copy serves the clipboard after the copy RPC returns.",
    'backend/internal/services/clipboard/wayland.go::watch exec.CommandContext(ctx, "wl-paste", "--watch", "echo")': "wl-paste --watch is the backend clipboard watcher.",
    'backend/internal/services/cloudsync/rcd.go::start exec.Command(d.binary, "rcd", "--rc-addr", "127.0.0.1:"+strconv.Itoa(port), "--rc-web-gui=false", "--log-level", "NOTICE")': "rclone rcd is the cloudsync control daemon.",
    'backend/internal/services/cloudsync/remotes.go::beginOAuth exec.Command(m.binary, "authorize", providerType, "--auth-no-open-browser")': "rclone authorize owns the browser OAuth flow.",
    'backend/internal/services/gamma/gamma.go::applyGammaLocked exec.Command(m.binary, "-t", strconv.Itoa(lowTemp), "-T", strconv.Itoa(highTemp), "-g", strconv.FormatFloat(state.Config.Gamma, \'f\', 3, 64))': "wlsunset is the Niri gamma adapter process.",
    'backend/internal/services/gamma/gamma.go::applyGammaLocked exec.Command(m.binary, "--temperature", strconv.Itoa(state.CurrentTemp), "--gamma", strconv.Itoa(gammaPercent))': "hyprsunset is the Hyprland gamma adapter process.",
    'backend/internal/services/networkmanager/networkmanager.go::monitor exec.CommandContext(ctx, "nmcli", "monitor")': "nmcli monitor is the NetworkManager watcher.",
    'backend/internal/services/sysupdate/sysupdate.go::handleUpgrade exec.Command(argv[0], argv[1:]...)': "the terminal updater is an interactive upgrade process.",
    'backend/internal/services/tailscale/watch.go::runWatch exec.CommandContext(ctx, m.tailscale, "debug", "watch-ipn")': "tailscale debug watch-ipn is the ipn bus watcher.",
    'backend/internal/runner/runner.go::runQuickshell exec.Command("qs", append(baseArgs, qsArgs...)...)': "the runner owns the shell process lifetime.",
    'backend/internal/runner/supervise.go::superviseBackend exec.Command(exe, "serve")': "the runner supervises the backend serve child.",
}


@dataclass(frozen=True)
class Finding:
    rel: str
    line: int
    function: str
    expression: str
    key: str = ""


def run_analyzer() -> dict[str, object] | None:
    go = shutil.which("go")
    if go is None:
        print("check-execbound-adoption: FAIL: go is required", file=sys.stderr)
        return None
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


def findings(report: dict[str, object], key: str) -> list[Finding]:
    rows = report.get(key)
    return [Finding(**row) for row in rows] if isinstance(rows, list) else []


def allowlist_match_errors(rows: list[Finding], allowlist: dict[str, str], label: str) -> list[str]:
    counts = {key: 0 for key in allowlist}
    for row in rows:
        if row.key in counts:
            counts[row.key] += 1
    errors = [
        f"{label} allowlist key matched {count} finding(s): {key}"
        for key, count in counts.items()
        if count != 1
    ]
    errors.extend(f"{label} allowlist key has an empty reason: {key}" for key, reason in allowlist.items() if not reason.strip())
    return errors


def print_parse_errors(errors: object) -> bool:
    if not isinstance(errors, list) or not errors:
        return False
    print("check-execbound-adoption: FAIL: could not parse backend Go file(s):", file=sys.stderr)
    for entry in errors:
        print(f"  {entry}", file=sys.stderr)
    return True


def main() -> int:
    report = run_analyzer()
    if report is None or print_parse_errors(report.get("parse_errors")):
        return 1
    if not report.get("files_checked"):
        print("check-execbound-adoption: FAIL: found no Go files under backend/internal", file=sys.stderr)
        return 1

    raw_calls = findings(report, "raw_calls")
    output_reads = findings(report, "output_reads")
    unallowed_raw = [call for call in raw_calls if call.key not in ALLOWED_RAW_EXECS]
    allowlist_errors = allowlist_match_errors(raw_calls, ALLOWED_RAW_EXECS, "raw os/exec") if REPO_ROOT == DEFAULT_REPO_ROOT else []

    if allowlist_errors:
        print("check-execbound-adoption: FAIL: allowlist entries must match exactly one finding:", file=sys.stderr)
        for error in allowlist_errors:
            print(f"  {error}", file=sys.stderr)
    if output_reads:
        print("check-execbound-adoption: FAIL: raw exec.Command or exec.CommandContext output reads must use execbound:", file=sys.stderr)
        for read in output_reads:
            print(f"  {read.rel}:{read.line}: {read.function}: {read.expression}", file=sys.stderr)
    if unallowed_raw:
        print("check-execbound-adoption: FAIL: raw os/exec builders outside execbound need a lifecycle reason:", file=sys.stderr)
        for call in unallowed_raw:
            print(f"  {call.rel}:{call.line}: {call.function}: {call.expression}", file=sys.stderr)
            print(f"      allowlist key: {call.key}", file=sys.stderr)

    if allowlist_errors or output_reads or unallowed_raw:
        print(
            "\nUse execbound.Command for one-shot Output or CombinedOutput reads. "
            "Keep raw os/exec only for allowlisted long-lived processes.",
            file=sys.stderr,
        )
        return 1

    print(f"check-execbound-adoption: ok ({len(raw_calls)} raw os/exec builders checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
