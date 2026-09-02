#!/usr/bin/env python3
"""Fixture controls for check-execbound-adoption.py."""

from __future__ import annotations

import importlib.util
import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "scripts" / "check-execbound-adoption.py"


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_backend(root: Path, rel: str, text: str) -> None:
    write(root / "backend" / Path(rel), text)


def run_checker(root: Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["VGS_EXECBOUND_REPO_ROOT"] = str(root)
    return subprocess.run([str(CHECKER)], text=True, capture_output=True, env=env, check=False)


def assert_passes(root: Path) -> None:
    result = run_checker(root)
    if result.returncode != 0:
        raise AssertionError(result.stdout + result.stderr)


def assert_fails(root: Path, *expected: str, absent: tuple[str, ...] = ()) -> None:
    result = run_checker(root)
    output = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"checker unexpectedly passed; wanted {expected!r}")
    for needle in expected:
        if needle not in output:
            raise AssertionError(f"checker output missing {needle!r}\n{output}")
    for needle in absent:
        if needle in output:
            raise AssertionError(f"checker output unexpectedly contained {needle!r}\n{output}")


def make_root() -> Path:
    return Path(tempfile.mkdtemp(prefix="vgs-execbound-test-"))


def checker_module():
    spec = importlib.util.spec_from_file_location("check_execbound_adoption", CHECKER)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load checker module")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def assert_allowlist_entrypoint_controls() -> None:
    checker = checker_module()
    original_allowlist = checker.ALLOWED_RAW_EXECS
    original_run_analyzer = checker.run_analyzer
    original_repo_root = checker.REPO_ROOT
    checker.ALLOWED_RAW_EXECS = {"dup": "reason", "missing": "reason", "empty": ""}
    checker.REPO_ROOT = checker.DEFAULT_REPO_ROOT
    checker.run_analyzer = lambda: {
        "files_checked": 1,
        "parse_errors": [],
        "raw_calls": [
            {"rel": "backend/internal/services/sample/a.go", "line": 1, "function": "a", "expression": 'exec.Command("a")', "key": "dup"},
            {"rel": "backend/internal/services/sample/b.go", "line": 1, "function": "b", "expression": 'exec.Command("b")', "key": "dup"},
        ],
        "output_reads": [],
    }
    stderr = io.StringIO()
    try:
        with contextlib.redirect_stderr(stderr):
            status = checker.main()
    finally:
        checker.ALLOWED_RAW_EXECS = original_allowlist
        checker.run_analyzer = original_run_analyzer
        checker.REPO_ROOT = original_repo_root
    output = stderr.getvalue()
    if status == 0:
        raise AssertionError("checker unexpectedly passed invalid allowlist entrypoint controls")
    for needle in (
        "allowlist entries must match exactly one finding",
        "raw os/exec allowlist key matched 2 finding(s): dup",
        "raw os/exec allowlist key matched 0 finding(s): missing",
        "raw os/exec allowlist key has an empty reason: empty",
    ):
        if needle not in output:
            raise AssertionError(output)


def main() -> int:
    assert_allowlist_entrypoint_controls()
    assert_passes(REPO_ROOT)

    parse_root = make_root()
    try:
        write_backend(parse_root, "internal/services/sample/valid.go", "package sample\nfunc valid() {}\n")
        write_backend(parse_root, "internal/services/sample/malformed.go", "package sample\nfunc malformed( {\n")
        assert_fails(parse_root, "could not parse backend Go file(s)", "malformed.go")
    finally:
        shutil.rmtree(parse_root)

    pass_root = make_root()
    try:
        write_backend(pass_root, "internal/services/sample/pass.go", 'package sample\nfunc mentions() { _ = "exec.CommandContext(ctx, \\"bad-tool\\").Output()"; /* exec.CommandContext(ctx, "bad-tool").CombinedOutput() */ }\ntype report struct{}\nfunc (report) Output() string { return "ok" }\nfunc (report) CombinedOutput() string { return "ok" }\nfunc unrelatedOutput() string { return report{}.Output() + report{}.CombinedOutput() }\n')
        write_backend(pass_root, "internal/execbound/execbound.go", 'package execbound\nimport "os/exec"\nfunc ok() { _, _ = exec.Command("internal-tool").Output() }\n')
        write_backend(pass_root, "vendor/example/bad.go", 'package example\nimport "os/exec"\nfunc bypass() { _, _ = exec.Command("vendor-tool").Output() }\n')
        assert_passes(pass_root)
    finally:
        shutil.rmtree(pass_root)

    fail_root = make_root()
    try:
        write_backend(fail_root, "internal/services/sample/bad.go", 'package sample\nimport ("context"; ex "os/exec")\nfunc direct(ctx context.Context) error { _, err := ex.CommandContext(ctx, "bad-tool").Output(); return err }\nfunc viaVariable(ctx context.Context) error { cmd := ex.CommandContext(ctx, "other-tool"); _, err := cmd.CombinedOutput(); return err }\nfunc rawStart(ctx context.Context) error { cmd := ex.CommandContext(ctx, "raw-tool"); return cmd.Start() }\n')
        assert_fails(
            fail_root,
            "raw exec.Command or exec.CommandContext output reads",
            'direct: ex.CommandContext(ctx, "bad-tool").Output()',
            "viaVariable: cmd.CombinedOutput()",
            "raw os/exec builders outside execbound need a lifecycle reason",
            "raw-tool",
            "allowlist key:",
        )
    finally:
        shutil.rmtree(fail_root)

    allowlisted = make_root()
    try:
        write_backend(allowlisted, "internal/services/clipboard/wayland.go", 'package clipboard\nimport "os/exec"\nfunc wlCopy(args []string) error { _, directErr := exec.Command("wl-copy", args...).Output(); var cmd = exec.Command("wl-copy", args...); _, varErr := cmd.Output(); var typed *exec.Cmd = exec.Command("wl-copy", args...); _, combinedErr := typed.CombinedOutput(); var ( blocked = exec.Command("wl-copy", args...) ); _, blockErr := blocked.Output(); if directErr != nil { return directErr }; if varErr != nil { return varErr }; if combinedErr != nil { return combinedErr }; return blockErr }\n')
        assert_fails(
            allowlisted,
            "raw exec.Command or exec.CommandContext output reads",
            'wlCopy: exec.Command("wl-copy", args...).Output()',
            "wlCopy: cmd.Output()",
            "wlCopy: typed.CombinedOutput()",
            "wlCopy: blocked.Output()",
            absent=("raw os/exec builders outside execbound need a lifecycle reason",),
        )
    finally:
        shutil.rmtree(allowlisted)

    conditional_clear = make_root()
    try:
        write_backend(conditional_clear, "internal/services/clipboard/wayland.go", 'package clipboard\nimport "os/exec"\nfunc wlCopy(args []string, skip bool) error { cmd := exec.Command("wl-copy", args...); if skip { cmd = nil }; _, err := cmd.Output(); return err }\n')
        assert_fails(conditional_clear, "raw exec.Command or exec.CommandContext output reads", "wlCopy: cmd.Output()", absent=("raw os/exec builders outside execbound need a lifecycle reason",))
    finally:
        shutil.rmtree(conditional_clear)

    unconditional_clear = make_root()
    try:
        write_backend(unconditional_clear, "internal/services/clipboard/wayland.go", 'package clipboard\nimport "os/exec"\ntype report struct{}\nfunc (report) Output() ([]byte, error) { return nil, nil }\nfunc wlCopy(args []string) error { var cmd interface{ Output() ([]byte, error) } = exec.Command("wl-copy", args...); cmd = report{}; _, err := cmd.Output(); return err }\n')
        assert_passes(unconditional_clear)
    finally:
        shutil.rmtree(unconditional_clear)

    print("execbound adoption guard tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
