#!/usr/bin/env python3
"""Checks for the mise/agent/dev-env subsystem (bin/vshell_mise.py,
bin/vshell_devtools.py, bin/vshell_update.py) and the catalog they read."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "bin"))


def load_helper():
    loader = importlib.machinery.SourceFileLoader("vshell_helper_devtools_check", str(REPO_ROOT / "bin" / "vshell-helper"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


helper = load_helper()
devtools = helper._devtools()
mise = devtools.vshell_mise
update = helper._update()


def assert_equal(actual, expected, message):
    if actual != expected:
        raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")


def test_stub_template_and_foreign_files():
    """Stubs install lazily, stay quiet, and never replace a file VGS did not write."""
    with tempfile.TemporaryDirectory() as tmp:
        original_home = mise.RT.home
        original_state = mise.RT.state_dir
        mise.RT.home = lambda: Path(tmp)
        mise.RT.state_dir = lambda: Path(tmp) / ".local" / "state" / "vshell"
        try:
            result = mise.mise_install_stub("npm:@deepseek-ai/dsh", "dsh")
            assert_equal(result["state"], "written", "a fresh stub must be written")
            stub = Path(tmp) / ".local" / "bin" / "dsh"
            text = stub.read_text()
            assert stub.stat().st_mode & 0o111, "stub must be executable"
            assert "mise use -g --quiet npm:@deepseek-ai/dsh || exit 1" in text, text
            assert 'exec mise x npm:@deepseek-ai/dsh -- dsh "$@"' in text, text
            assert "MISE_MINIMUM_RELEASE_AGE=0" in text, "stubs must opt out of the release-age cooldown"
            spaced = mise.mise_stub_text("github:acme/odd tool", "odd", "odd tool")
            assert "mise use -g --quiet 'github:acme/odd tool' || exit 1" in spaced, spaced
            assert "-- 'odd tool' \"$@\"" in spaced, spaced
            assert_equal(mise.mise_stub_state(stub), "ours", "a written stub is ours")

            assert_equal(mise.mise_install_stub("npm:@deepseek-ai/dsh", "dsh")["state"], "written", "our stub may be rewritten")
            foreign = Path(tmp) / ".local" / "bin" / "claude"
            foreign.write_text('#!/bin/bash\nexec /opt/claude/claude "$@"\n')
            before = foreign.read_text()
            result = mise.mise_install_stub("claude", "claude")
            assert_equal(result["state"], "foreign", "a file VGS did not write must be reported, not replaced")
            assert "error" in result, result
            assert_equal(foreign.read_text(), before, "foreign file must be untouched")

            refreshed = mise.mise_refresh()
            assert "claude" in refreshed["foreign"], refreshed
            assert "codex" in refreshed["written"], refreshed
            removed = mise.mise_remove_stubs()
            assert "codex" in removed["removed"] and "claude" in removed["kept"], removed
            assert foreign.exists(), "remove-stubs must keep foreign files"
            assert mise.mise_stubs_opted_out(), "remove-stubs must record the opt-out"
            assert_equal(mise.mise_refresh()["optedOut"], True, "refresh must respect the opt-out")
            assert not (Path(tmp) / ".local" / "bin" / "codex").exists(), "an opted-out refresh must write nothing"
        finally:
            mise.RT.home = original_home
            mise.RT.state_dir = original_state


def test_outdated_parsing_and_update_steps():
    """`mise outdated --json` rows become tools rows; a missing updater is a loud miss."""
    original_run = mise.RT.run
    original_dev_exists = mise.RT.command_exists
    original_upd_exists = update.RT.command_exists
    original_eprint = update.RT.eprint
    update.RT.eprint = lambda *a: None
    present = {"mise", "pacman"}
    mise.RT.command_exists = lambda name: name in present
    update.RT.command_exists = lambda name: name in present
    payload = '{"claude": {"name": "claude", "requested": "latest", "current": "2.1.0", "latest": "2.2.0"}}'
    mise.RT.run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 0, stdout=payload, stderr="")
    try:
        rows, error = mise.mise_outdated()
        assert_equal(error, "", "valid JSON must not report an error")
        assert_equal(rows, [{"name": "claude", "current": "2.1.0", "latest": "2.2.0"}], "outdated rows")
        mise.RT.run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 0, stdout="mise ERROR nope", stderr="")
        rows, error = mise.mise_outdated()
        assert rows == [] and "invalid JSON" in error, (rows, error)

        steps = update.update_steps("all")
        titles = [step["title"] for step in steps]
        assert any("repo" in t for t in titles) and titles[-1].startswith("Updating mise tools"), titles
        assert steps[-1]["env"]["MISE_MINIMUM_RELEASE_AGE"] == "0", "mise up must skip the release cooldown"
        assert mise.mise_refresh in steps[-1]["after"], "stubs must be refreshed after a tools update"
        assert_equal([s["argv"] for s in update.update_steps("tools")], [["mise", "up"]], "tools mode runs mise up only")
        present.discard("mise")
        assert_equal(update.update_steps("tools"), [], "an absent updater yields no step")
    finally:
        mise.RT.run = original_run
        mise.RT.command_exists = original_dev_exists
        update.RT.command_exists = original_upd_exists
        update.RT.eprint = original_eprint


def test_catalog_is_consistent():
    """One catalog feeds stubs, agents and envs; ids and commands must be unique."""
    catalog = mise.dev_tools_catalog()
    commands = [e["command"] for e in catalog["agents"] + catalog["tools"]]
    assert_equal(len(commands), len(set(commands)), "stub commands must be unique: " + " ".join(commands))
    ids = [e["id"] for e in catalog["agents"]]
    assert_equal(len(ids), len(set(ids)), "agent ids must be unique")
    for agent in catalog["agents"]:
        assert agent["launch"][0] == agent["command"], f"{agent['id']}: launch must start with its own command"
    env_ids = [e["id"] for e in catalog["envs"]]
    assert_equal(len(env_ids), len(set(env_ids)), "env ids must be unique")
    for env in catalog["envs"]:
        assert env.get("tools") or env.get("installer"), f"{env['id']}: needs tools or an installer"


def test_cli_wrapper_routes_the_commands():
    """The bash wrapper and the helper's dispatcher both know the three commands."""
    wrapper = (REPO_ROOT / "bin" / "vshell").read_text()
    dispatch_line = next(line for line in wrapper.splitlines() if "|update|" in line and 'exec "$helper"' not in line)
    for name in ("mise", "agent", "dev-env"):
        assert f"|{name}|" in dispatch_line, f"bin/vshell must route {name} to the helper"
    helper_text = (REPO_ROOT / "bin" / "vshell-helper").read_text()
    for name in ("mise", "agent", "dev-env"):
        assert f'if cmd == "{name}": return _devtools().' in helper_text, f"helper must dispatch {name}"


def main() -> int:
    test_stub_template_and_foreign_files()
    test_outdated_parsing_and_update_steps()
    test_catalog_is_consistent()
    test_cli_wrapper_routes_the_commands()
    print("check-dev-tools: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
