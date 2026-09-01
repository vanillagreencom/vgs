#!/usr/bin/env python3
"""Fixture controls for check-execbound-adoption.py."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "scripts" / "check-execbound-adoption.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def run_checker(root: Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["VGS_EXECBOUND_REPO_ROOT"] = str(root)
    return subprocess.run([str(CHECKER)], text=True, capture_output=True, env=env, check=False)


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


def make_root() -> Path:
    return Path(tempfile.mkdtemp(prefix="vgs-execbound-test-"))


def main() -> int:
    empty = make_root()
    try:
        assert_fails(empty, "found no Go files")
    finally:
        shutil.rmtree(empty)

    root = make_root()
    try:
        write(
            root / "backend" / "internal" / "services" / "sample" / "clean.go",
            """
package sample

import (
    "context"
    "os/exec"
)

func mentions(ctx context.Context) {
    _ = "exec.CommandContext(ctx, \\"bad-tool\\").Output()"
    // _, _ = exec.CommandContext(ctx, "bad-tool").CombinedOutput()
}
""",
        )
        write(
            root / "backend" / "vendor" / "example" / "bad.go",
            """
package example

import "os/exec"

func vendorBypass() error {
    _, err := exec.Command("vendor-tool").Output()
    return err
}
""",
        )
        write(
            root / "backend" / "internal" / "execbound" / "execbound.go",
            """
package execbound

import "os/exec"

func Command() error {
    _, err := exec.Command("true").Output()
    return err
}
""",
        )
        assert_passes(root)

        write(
            root / "backend" / "internal" / "services" / "sample" / "bad.go",
            """
package sample

import (
    "context"
    "os/exec"
)

func direct(ctx context.Context) error {
    _, err := exec.CommandContext(ctx, "bad-tool").Output()
    return err
}

func viaVariable(ctx context.Context) error {
    cmd := exec.CommandContext(ctx, "other-tool")
    _, err := cmd.CombinedOutput()
    return err
}
""",
        )
        assert_fails(root, "bad-tool")
        assert_fails(root, "other-tool")
    finally:
        shutil.rmtree(root)

    print("execbound adoption guard tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
