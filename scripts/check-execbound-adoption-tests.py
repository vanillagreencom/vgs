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


def make_root() -> Path:
    return Path(tempfile.mkdtemp(prefix="vgs-execbound-test-"))


def write_go_mod(root: Path) -> None:
    write_backend(root, "go.mod", "\nmodule example.com/backend\n\ngo 1.22\n")


def write_execbound(root: Path) -> None:
    write_backend(root, "internal/execbound/execbound.go",
        """
package execbound
type Cmd struct{}
func Command(any, string, ...string) *Cmd { return &Cmd{} }
func CommandWithDelay(any, any, string, ...string) *Cmd { return &Cmd{} }
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
            "backend output reads must be directly chained",
            "bad-tool",
            ".Output()",
            "other-tool",
            ".CombinedOutput()",
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
        assert_fails(raw_root, "raw os/exec builders outside execbound need a lifecycle reason", "raw-tool", "allowlist key:")
    finally:
        shutil.rmtree(raw_root)

    assigned_root = make_root()
    try:
        write_go_mod(assigned_root)
        write_backend(assigned_root, "internal/services/sample/assigned.go",
            """
package sample
import (
    "context"
    "example.com/backend/internal/execbound"
)
func assignedBound(ctx context.Context) error {
    cmd := execbound.Command(ctx, "assigned-tool")
    _, err := cmd.Output()
    return err
}
""",
        )
        assert_fails(assigned_root, "could not type-check", "could not import example.com/backend/internal/execbound")
        write_execbound(assigned_root)
        write_backend(assigned_root, "internal/services/shared/shared.go",
            """
package shared
import "example.com/backend/internal/execbound"
type Runner = execbound.Cmd
func Factory(ctx any, name string) *Runner { return execbound.Command(ctx, name) }
""",
        )
        write_backend(assigned_root, "internal/services/sample/assigned.go",
            """
package sample
import (
    "context"
    "example.com/backend/internal/execbound"
    "example.com/backend/internal/services/shared"
)
func assignedBound(ctx context.Context) error {
    cmd := execbound.Command(ctx, "assigned-tool")
    _, err := cmd.Output()
    return err
}
func localPackageParam(cmd *shared.Runner) error {
    _, err := cmd.Output()
    return err
}
func aliasedFactory(ctx context.Context) error {
    makeCmd := shared.Factory
    _, err := makeCmd(ctx, "factory-tool").CombinedOutput()
    return err
}
""",
        )
        assert_fails(
            assigned_root,
            "backend output reads must be directly chained",
            "assignedBound: cmd.Output()",
            "localPackageParam: cmd.Output()",
            "aliasedFactory: makeCmd(ctx, \"factory-tool\").CombinedOutput()",
        )
    finally:
        shutil.rmtree(assigned_root)

    method_value_root = make_root()
    try:
        write_backend(method_value_root, "internal/services/sample/method_value.go",
            """
package sample
import "os/exec"
func methodValue() error {
    methodValueCmd := &exec.Cmd{Path: "method-value-tool"}
    read := methodValueCmd.Output
    _, err := read()
    return err
}
""",
        )
        assert_fails(method_value_root, "backend output reads must be directly chained", "methodValue: methodValueCmd.Output")
    finally:
        shutil.rmtree(method_value_root)

    alias_root = make_root()
    try:
        write_backend(alias_root, "internal/services/sample/alias.go",
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
        assert_fails(alias_root, "os/exec command builders must be called directly", "ex.CommandContext referenced without a call")
    finally:
        shutil.rmtree(alias_root)

    structural_root = make_root()
    try:
        write_backend(structural_root, "internal/services/sample/structural.go",
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
func methodExpression(cmd *éxec.Cmd) error {
    read := (*éxec.Cmd).CombinedOutput
    _, err := read(cmd)
    return err
}
type wrapped struct {
    *éxec.Cmd
}
func embedded(ctx context.Context) error {
    wrappedCmd := wrapped{Cmd: éxec.CommandContext(ctx, "embedded-tool")}
    _, err := wrappedCmd.Output()
    return err
}

type outputRunner interface {
    Output() ([]byte, error)
}
func interfaceRead(ctx context.Context) error {
    var runner outputRunner = éxec.CommandContext(ctx, "interface-tool")
    _, err := runner.Output()
    return err
}
""",
        )
        assert_fails(
            structural_root,
            "backend output reads must be directly chained",
            "unicode-tool",
            ".Output()",
            "cmd.CombinedOutput()",
            "cmd.Output()",
            "helperRead",
            "(*éxec.Cmd).CombinedOutput",
            "wrappedCmd.Output()",
            "runner.Output()",
            "unverified selector",
        )
    finally:
        shutil.rmtree(structural_root)

    print("execbound adoption guard tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
