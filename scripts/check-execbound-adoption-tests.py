#!/usr/bin/env python3
"""Fixture controls for check-execbound-adoption.py."""

from __future__ import annotations

import importlib.util
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


def assert_fails(root: Path, *expected: str) -> None:
    result = run_checker(root)
    output = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"checker unexpectedly passed; wanted {expected!r}")
    for needle in expected:
        if needle not in output:
            raise AssertionError(f"checker output missing {needle!r}\n{output}")


def assert_fails_without(root: Path, expected: tuple[str, ...], unexpected: str) -> None:
    result = run_checker(root)
    output = result.stdout + result.stderr
    if result.returncode == 0:
        raise AssertionError(f"checker unexpectedly passed; wanted {expected!r}")
    for needle in expected:
        if needle not in output:
            raise AssertionError(f"checker output missing {needle!r}\n{output}")
    if unexpected in output:
        raise AssertionError(f"checker output unexpectedly contained {unexpected!r}\n{output}")


def make_root() -> Path:
    return Path(tempfile.mkdtemp(prefix="vgs-execbound-test-"))


def write_go_mod(root: Path) -> None:
    write_backend(root, "go.mod", "\nmodule example.com/backend\n\ngo 1.22\n")


def write_execbound(root: Path) -> None:
    write_backend(root, "internal/execbound/execbound.go",
        """
package execbound
import "os/exec"
type Cmd struct{}
func Command(any, string, ...string) *Cmd { return &Cmd{} }
func CommandWithDelay(any, any, string, ...string) *Cmd { return &Cmd{} }
func (c *Cmd) Exec() *exec.Cmd { return exec.Command("true") }
func (c *Cmd) WithLogger(any) *Cmd { return c }
func (c *Cmd) Output() (int, error) { return 0, nil }
func (c *Cmd) CombinedOutput() (int, error) { return 0, nil }
""",
    )


def assert_allowlist_controls() -> None:
    spec = importlib.util.spec_from_file_location("check_execbound_adoption", CHECKER)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load checker module")
    checker = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = checker
    spec.loader.exec_module(checker)
    rows = [checker.Finding("", 0, "", "", "dup"), checker.Finding("", 0, "", "", "dup")]
    errors = checker.allowlist_match_errors(rows, {"dup": "reason", "missing": "reason"}, "raw")
    if (
        "raw allowlist key matched 2 finding(s): dup" not in errors
        or "raw allowlist key matched 0 finding(s): missing" not in errors
    ):
        raise AssertionError(errors)


def main() -> int:
    assert_allowlist_controls()

    empty = make_root()
    try:
        assert_fails(empty, "found no Go files")
    finally:
        shutil.rmtree(empty)

    parse_root = make_root()
    try:
        write_backend(parse_root, "internal/services/sample/valid.go",
            """
package sample
func valid() {}
""",
        )
        write_backend(parse_root, "internal/services/sample/malformed.go",
            """
package sample
func malformed( {
""",
        )
        assert_fails(parse_root, "could not parse backend Go file(s)", "malformed.go")
    finally:
        shutil.rmtree(parse_root)

    root = make_root()
    try:
        write_go_mod(root)
        write_execbound(root)
        write_backend(root, "internal/services/brightnessbridge/brightnessbridge.go",
            """
package brightnessbridge
import (
    "context"
    "example.com/backend/internal/execbound"
)
func mentions(ctx context.Context) {
    _ = "exec.CommandContext(ctx, \\"bad-tool\\").Output()"
    // _, _ = exec.CommandContext(ctx, "bad-tool").CombinedOutput()
}
func directBound(ctx context.Context) error {
    _, err := execbound.Command(ctx, "good-tool").WithLogger(nil).Output()
    return err
}
type Manager struct {
    waitDelay int
    helper string
    log any
}
func (m *Manager) call(ctx context.Context, cmdArgs []string) error {
    _, err := execbound.CommandWithDelay(ctx, m.waitDelay, m.helper, cmdArgs...).WithLogger(m.log).Output()
    return err
}
type report struct{}
func (report) Output() string { return "ok" }
func unrelatedOutput() string { return report{}.Output() }
""",
        )
        write_backend(root, "vendor/example/bad.go",
            """
package example
import "os/exec"
func vendorBypass() error {
    _, err := exec.Command("vendor-tool").Output()
    return err
}
""",
        )
        assert_passes(root)

        write_backend(root, "internal/services/sample/bad.go",
            """
package sample
import (
    "context"
    "os/exec"
    "example.com/backend/internal/execbound"
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
func genericDelay(ctx context.Context) error {
    _, err := execbound.CommandWithDelay(ctx, 1, "generic-delay-tool").Output()
    return err
}
""",
        )
        assert_fails(
            root,
            "raw exec.Command or exec.CommandContext output reads",
            "bad-tool",
            ".Output()",
            "viaVariable: exec.CommandContext(ctx, \"other-tool\")",
            "genericDelay: execbound.CommandWithDelay",
            "allowlist key:",
        )
    finally:
        shutil.rmtree(root)

    raw_root = make_root()
    try:
        write_backend(raw_root, "internal/services/sample/raw.go",
            """
package sample
import ("context"; "os/exec")
type outputRunner interface{ Output() ([]byte, error) }
func rawStart(ctx context.Context) error { cmd := exec.CommandContext(ctx, "raw-tool"); return cmd.Start() }
func rawReturned(ctx context.Context) (error, outputRunner) { return nil, exec.CommandContext(ctx, "multi-raw-tool") }
func appendRaw(ctx context.Context) { var runs []outputRunner; runs = append(runs, exec.CommandContext(ctx, "append-tool")) }
""",
        )
        assert_fails(
            raw_root,
            "raw os/exec builders must start or run in the same function",
            "rawReturned: exec.CommandContext(ctx, \"multi-raw-tool\")",
            "appendRaw: exec.CommandContext(ctx, \"append-tool\")",
            "raw os/exec builders outside execbound need a lifecycle reason",
            "raw-tool",
            "allowlist key:",
        )
    finally:
        shutil.rmtree(raw_root)

    raw_allowed_output_root = make_root()
    try:
        write_backend(raw_allowed_output_root, "internal/services/clipboard/wayland.go",
            """
package clipboard
import "os/exec"
func wlCopy(args []string) error { _, err := exec.Command("wl-copy", args...).Output(); return err }
""",
        )
        assert_fails_without(
            raw_allowed_output_root,
            ("raw exec.Command or exec.CommandContext output reads", "wlCopy: exec.Command(\"wl-copy\", args...).Output()", "raw os/exec builders must start or run"),
            "raw os/exec builders outside execbound need a lifecycle reason",
        )
    finally:
        shutil.rmtree(raw_allowed_output_root)

    raw_allowed_combined_root = make_root()
    try:
        write_backend(raw_allowed_combined_root, "internal/services/clipboard/wayland.go",
            """
package clipboard
import ("context"; "os/exec")
func watch(ctx context.Context) error { _, err := exec.CommandContext(ctx, "wl-paste", "--watch", "echo").CombinedOutput(); return err }
""",
        )
        assert_fails_without(
            raw_allowed_combined_root,
            ("raw exec.Command or exec.CommandContext output reads", "watch: exec.CommandContext(ctx, \"wl-paste\", \"--watch\", \"echo\").CombinedOutput()", "raw os/exec builders must start or run"),
            "raw os/exec builders outside execbound need a lifecycle reason",
        )
    finally:
        shutil.rmtree(raw_allowed_combined_root)

    raw_reassigned_root = make_root()
    try:
        write_backend(raw_reassigned_root, "internal/services/clipboard/wayland.go",
            """
package clipboard
import "os/exec"
func wlCopy(args []string) error { cmd := exec.Command("wl-copy", args...); cmd = nil; return cmd.Start() }
""",
        )
        assert_fails_without(
            raw_reassigned_root,
            ("raw os/exec builders must start or run", "wlCopy: exec.Command(\"wl-copy\", args...)"),
            "raw os/exec builders outside execbound need a lifecycle reason",
        )
    finally:
        shutil.rmtree(raw_reassigned_root)

    assigned_root = make_root()
    try:
        write_go_mod(assigned_root)
        write_execbound(assigned_root)
        write_backend(assigned_root, "internal/services/sample/assigned.go",
            """
package sample
import (
    "context"
    "example.com/backend/internal/execbound"
)
func assignedBound(ctx context.Context) error { cmd := execbound.Command(ctx, "assigned-tool"); _, err := cmd.Output(); return err }
type runner interface{ Output() (int, error) }
func helperPassed(cmd runner) error { return nil }
func callHelper(ctx context.Context) error { return helperPassed(execbound.Command(ctx, "passed-tool")) }
func callDelayHelper(ctx context.Context) error { return helperPassed(execbound.CommandWithDelay(ctx, 1, "passed-delay-tool")) }
func multiValue(ctx context.Context) (error, runner) { return nil, execbound.Command(ctx, "multi-tool") }
func appendBound(ctx context.Context) []runner { var runs []runner; return append(runs, execbound.Command(ctx, "append-tool")) }
func execRun(ctx context.Context) error { return execbound.Command(ctx, "exec-run-tool").Exec().Run() }
""",
        )
        assert_fails(
            assigned_root,
            "execbound command builders must terminate",
            "assignedBound: execbound.Command(ctx, \"assigned-tool\")",
            "callHelper: execbound.Command(ctx, \"passed-tool\")",
            "callDelayHelper: execbound.CommandWithDelay(ctx, 1, \"passed-delay-tool\")",
            "multiValue: execbound.Command(ctx, \"multi-tool\")",
            "appendBound: execbound.Command(ctx, \"append-tool\")",
            "execRun: execbound.Command(ctx, \"exec-run-tool\")",
        )
    finally:
        shutil.rmtree(assigned_root)

    alias_root = make_root()
    try:
        write_backend(alias_root, "internal/services/sample/alias.go",
            """
package sample
import (
    "context"
    ex "os/exec"
)
func factoryAlias(ctx context.Context) error { makeCmd := ex.CommandContext; cmd := makeCmd(ctx, "bad-tool"); _, err := cmd.Output(); return err }
func chainedAlias(ctx context.Context) error { run := ex.CommandContext; _, err := run(ctx, "security-tool").Output(); return err }
""",
        )
        assert_fails(alias_root, "os/exec command builders must be called directly", "ex.CommandContext referenced without a call")
    finally:
        shutil.rmtree(alias_root)

    print("execbound adoption guard tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
