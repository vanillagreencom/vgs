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


def assert_fails(root: Path, *expected: str) -> None:
    result = run_checker(root)
    output = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"checker unexpectedly passed; wanted {expected!r}")
    for needle in expected:
        if needle not in output:
            raise AssertionError(f"checker output missing {needle!r}\n{output}")


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
        assert_fails(
            root,
            "one-shot os/exec output reads must use",
            "bad-tool",
            ".Output()",
            "other-tool",
            ".CombinedOutput()",
        )
    finally:
        shutil.rmtree(root)

    raw_root = make_root()
    try:
        write(
            raw_root / "backend" / "internal" / "services" / "sample" / "raw.go",
            """
package sample

import (
    "context"
    "os/exec"
)

func rawStart(ctx context.Context) error {
    cmd := exec.CommandContext(ctx, "raw-tool")
    return cmd.Start()
}
""",
        )
        assert_fails(
            raw_root,
            "raw os/exec builders outside execbound need a lifecycle reason",
            "raw-tool",
            "allowlist key:",
        )
    finally:
        shutil.rmtree(raw_root)

    alias_root = make_root()
    try:
        write(
            alias_root / "backend" / "internal" / "services" / "sample" / "alias.go",
            """
package sample

import (
    "context"
    ex "os/exec"
)

func factoryAlias(ctx context.Context) error {
    makeCmd := ex.CommandContext
    cmd := makeCmd(ctx, "bad-tool")
    _, err := cmd.Output()
    return err
}

func chainedAlias(ctx context.Context) error {
    run := ex.CommandContext
    _, err := run(ctx, "security-tool").Output()
    return err
}
""",
        )
        assert_fails(
            alias_root,
            "os/exec command builders must be called directly",
            "ex.CommandContext referenced without a call",
        )
    finally:
        shutil.rmtree(alias_root)

    structural_root = make_root()
    try:
        write(
            structural_root / "backend" / "internal" / "services" / "sample" / "structural.go",
            """
package sample

import (
    "context"
    éxec "os/exec"
)

func unicodeAlias(ctx context.Context) error {
    _, err := éxec.CommandContext(ctx, "unicode-tool").Output()
    return err
}

func rawLiteral() error {
    cmd := &éxec.Cmd{Path: "literal-tool"}
    _, err := cmd.CombinedOutput()
    return err
}

func rawNew() error {
    cmd := new(éxec.Cmd)
    _, err := cmd.Output()
    return err
}

func helperRead(cmd *éxec.Cmd) error {
    _, err := cmd.Output()
    return err
}

func helperCaller(ctx context.Context) error {
    return helperRead(éxec.CommandContext(ctx, "helper-tool"))
}
""",
        )
        assert_fails(
            structural_root,
            "one-shot os/exec output reads must use",
            "unicode-tool",
            ".Output()",
            "cmd.CombinedOutput()",
            "cmd.Output()",
            "helperRead",
            "*os/exec.Cmd",
        )
    finally:
        shutil.rmtree(structural_root)

    print("execbound adoption guard tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
