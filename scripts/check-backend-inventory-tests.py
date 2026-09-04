#!/usr/bin/env python3
"""Negative tests for check-backend-inventory.py ownership guards."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "scripts" / "check-backend-inventory.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_fixture() -> Path:
    root = Path(tempfile.mkdtemp(prefix="vgs-inventory-test-"))
    write(
        root / "backend" / "methods.json",
        json.dumps(
            {
                "capabilities": [
                    {"name": "core", "prefixes": ["ping", "getServerInfo", "subscribe"], "phase": 1, "status": "implemented"},
                    {"name": "sysupdate", "prefixes": ["sysupdate."], "phase": 10, "status": "implemented"},
                    {"name": "tailscale", "prefixes": ["tailscale."], "phase": 10, "status": "implemented"},
                ],
                "excluded": [],
                "apiVersionGateBaseline": 0,
            }
        ),
    )
    write(
        root / "quickshell" / "vshell" / "Services" / "VGSBackendService.qml",
        'Singleton { function sendRequest(method, params, callback) {} }',
    )
    write(root / "quickshell" / "vshell" / "VGSIPC.qml", "Item {}")
    write(
        root / "config" / "vshell" / "plugins" / "tailscale" / "TailscaleWidget.qml",
        "PluginComponent { function refresh() { TailscaleService.refresh(null); } }",
    )
    write(
        root / "config" / "vshell" / "plugins" / "sysUpdate" / "SysUpdateWidget.qml",
        "PluginComponent { readonly property bool useBackend: true; Ref { service: SystemUpdateService } Timer { running: !root.useBackend } }",
    )
    return root


def run_checker(root: Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["VGS_INVENTORY_REPO_ROOT"] = str(root)
    return subprocess.run(["python3", str(CHECKER)], text=True, capture_output=True, env=env, check=False)


def assert_passes(root: Path) -> None:
    result = run_checker(root)
    if result.returncode != 0:
        raise AssertionError(result.stdout + result.stderr)


def assert_fails(root: Path, expected: str) -> None:
    result = run_checker(root)
    output = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"checker unexpectedly passed; wanted {expected!r}")
    if expected not in output:
        raise AssertionError(f"checker output missing {expected!r}\n{output}")


def main() -> int:
    cases = [
        (
            "raw tailscale command",
            "config/vshell/plugins/tailscale/TailscaleWidget.qml",
            'PluginComponent { Process { command: ["tailscale", "status", "--json"] } }',
            "bundled Tailscale plugin must use TailscaleService/backend",
        ),
        (
            "missing sysupdate ref",
            "config/vshell/plugins/sysUpdate/SysUpdateWidget.qml",
            "PluginComponent { Timer { running: !root.useBackend } }",
            "bundled sysUpdate plugin must hold a SystemUpdateService ref",
        ),
        (
            "backend-present polling",
            "config/vshell/plugins/sysUpdate/SysUpdateWidget.qml",
            "PluginComponent { Ref { service: SystemUpdateService } Timer { running: true } }",
            "fallback poll timer must be disabled",
        ),
        (
            "bar-widget updater IPC",
            "quickshell/vshell/VGSIPC.qml",
            'Item { property var x: getPreferredBar("systemUpdateButtonRef") }',
            "systemupdater IPC must open through PopoutService",
        ),
        (
            "raw backend frame logging",
            "quickshell/vshell/Services/VGSBackendService.qml",
            'Singleton { function f(line) { log.debug("Request socket <<", line) } }',
            "must not log raw backend frames",
        ),
    ]

    root = make_fixture()
    try:
        assert_passes(root)
        for _, rel, contents, expected in cases:
            case_root = make_fixture()
            try:
                write(case_root / rel, contents)
                assert_fails(case_root, expected)
            finally:
                shutil.rmtree(case_root)
    finally:
        shutil.rmtree(root)
    print("backend inventory guard tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
