#!/usr/bin/env python3
"""Checks for the mise/agent/dev-env subsystem (bin/vshell_mise.py,
bin/vshell_devtools.py, bin/vshell_update.py) and the catalog they read."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import os
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
        original_path = os.environ.get("PATH", "")
        mise.RT.home = lambda: Path(tmp)
        mise.RT.state_dir = lambda: Path(tmp) / ".local" / "state" / "vshell"
        # The host's own PATH must not decide the verdict: only the temp dirs count.
        os.environ["PATH"] = str(Path(tmp) / ".local" / "bin")
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

            # A command installed elsewhere on PATH never gets a stub: ~/.local/bin
            # comes first and the stub would hide the distro binary.
            elsewhere = Path(tmp) / "usr-bin"
            elsewhere.mkdir()
            (elsewhere / "gh").write_text("#!/bin/sh\nexit 0\n")
            (elsewhere / "gh").chmod(0o755)
            os.environ["PATH"] = f"{elsewhere}:{Path(tmp) / '.local' / 'bin'}"
            try:
                shadowed = mise.mise_install_stub("gh", "gh")
                assert_equal(shadowed["state"], "shadowed", "a command on PATH outside ~/.local/bin must not get a stub")
                assert not (Path(tmp) / ".local" / "bin" / "gh").exists(), "shadowed stub must not be written"
                refreshed = mise.mise_refresh()
                assert "gh" in refreshed["shadowed"], refreshed
            finally:
                os.environ["PATH"] = str(Path(tmp) / ".local" / "bin")
            stale = Path(tmp) / ".local" / "bin" / "retired-tool"
            stale.write_text(mise.mise_stub_text("npm:retired", "retired-tool", "retired-tool"))
            refreshed = mise.mise_refresh()
            assert "retired-tool" in refreshed["retired"] and not stale.exists(), "a VGS stub for a command the catalog dropped is retired"
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
            os.environ["PATH"] = original_path


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


def test_update_run_and_count_carry_tools():
    """`update run tools` runs mise up then the stub refresh; a count merges mise rows."""
    calls = []
    original_run = update.subprocess.run
    original_input = update.input if hasattr(update, "input") else None
    original_exists = mise.RT.command_exists
    original_refresh = mise.mise_refresh
    original_mise_run = mise.RT.run
    mise.RT.command_exists = lambda name: name in {"mise", "pacman", "checkupdates"}
    refreshed = []
    mise.mise_refresh = lambda: refreshed.append(True)
    update.subprocess.run = lambda argv, check=False, env=None, cwd=None, **kw: (calls.append((list(argv), (env or {}).get("MISE_MINIMUM_RELEASE_AGE"), cwd)), subprocess.CompletedProcess(argv, 0))[1]
    update.input = lambda *a: ""
    try:
        assert_equal(update.cmd_update(["run", "tools"]), 0, "tools run must succeed")
        assert_equal(calls, [(["mise", "up"], "0", str(mise.RT.home()))], "tools mode runs mise up from $HOME with the cooldown off")
        assert_equal(len(refreshed), 1, "stubs are refreshed after the tools step")
        calls.clear()
        refreshed.clear()
        def boom():
            raise OSError("disk full")
        mise.mise_refresh = boom
        assert_equal(update.cmd_update(["run", "tools"]), 1, "a failing after-hook is a failed run, not a traceback")

        payload = '{"claude": {"name": "claude", "requested": "latest", "current": "2.1.0", "latest": "2.2.0"}}'
        mise.RT.run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 0, stdout=payload, stderr="")
        count_json = '{"ok":true,"repo":1,"aur":0,"packages":[{"name":"go","old":"1","new":"2","src":"repo"}],"orphanCount":0,"orphans":[]}'
        update.subprocess.run = lambda argv, **kw: subprocess.CompletedProcess(argv, 0, stdout=count_json, stderr="")
        data = update.update_count()
        assert_equal(data["tools"], 1, "count carries the mise rows")
        assert_equal(data["packages"][-1], {"name": "claude", "old": "2.1.0", "new": "2.2.0", "src": "tools"}, "tools row appended")
        assert_equal(data["source"]["tools"], "mise outdated", "tools source named")
        assert "toolsError" not in data, data
        mise.RT.run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 1, stdout="", stderr="mise ERROR nope")
        data = update.update_count()
        assert data.get("toolsError") and data["tools"] == 0, "a failed probe is reported, not a clean zero"
        mise.RT.command_exists = lambda name: name == "mise"
        mise.RT.run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 0, stdout=payload, stderr="")
        data = update.update_count()
        assert data["ok"] and data["tools"] == 1 and data["packages"][0]["src"] == "tools", data
    finally:
        update.subprocess.run = original_run
        if original_input is None:
            del update.input
        else:
            update.input = original_input
        mise.RT.command_exists = original_exists
        mise.mise_refresh = original_refresh
        mise.RT.run = original_mise_run


def test_os_release_resolves_through_id_like():
    """cachyos resolves to arch, ubuntu to debian; an unknown host fails loudly."""
    with tempfile.TemporaryDirectory() as tmp:
        rel = Path(tmp) / "os-release"
        rel.write_text('NAME="CachyOS"\nID=cachyos\nID_LIKE=arch\n')
        assert_equal(devtools.os_release_ids(rel), ["cachyos", "arch"], "ID then ID_LIKE tokens")
        rel.write_text('ID=ubuntu\nID_LIKE="debian"\n')
        assert_equal(devtools.os_release_ids(rel), ["ubuntu", "debian"], "quoted ID_LIKE")
        assert_equal(devtools.os_release_ids(Path(tmp) / "missing"), [], "unreadable file is empty, not a crash")
    original_ids = devtools.os_release_ids
    original_eprint = devtools.RT.eprint
    said = []
    devtools.RT.eprint = lambda *a: said.append(" ".join(str(x) for x in a))
    devtools.os_release_ids = lambda path=None: ["gentoo"]
    try:
        assert_equal(devtools.dev_env_install_packages({"arch": ["libyaml"]}), 1, "no matching key must fail")
        assert said and "libyaml" in said[-1] and "gentoo" in said[-1], said
        assert_equal(devtools.dev_env_install_packages({}), 0, "no packages needed is not a failure")
    finally:
        devtools.os_release_ids = original_ids
        devtools.RT.eprint = original_eprint


def test_first_launch_asks_before_installing():
    """An agent with nothing installed is offered for install; no answer means no download."""
    claude = next(e for e in devtools.agent_entries() if e["id"] == "claude")
    original_versions = devtools.mise_installed_versions
    original_state = devtools.mise_stub_state
    original_exists = mise.RT.command_exists
    original_run = devtools.subprocess.run
    original_stub = devtools.mise_install_stub
    ran = []
    devtools.mise_installed_versions = lambda: ({}, "")
    devtools.mise_stub_state = lambda path: "absent"
    mise.RT.command_exists = lambda name: name == "mise"
    devtools.subprocess.run = lambda argv, **kw: (ran.append(list(argv)), subprocess.CompletedProcess(argv, 0))[1]
    devtools.mise_install_stub = lambda *a: {"state": "written"}
    try:
        assert_equal(devtools.agent_installed(claude), False, "nothing installed")
        assert_equal(devtools.agent_launch_argv(claude)[0], "claude", "an owner-installed command runs bare")
        devtools.mise_installed_versions = lambda: ({"claude": "2.2.0"}, "")
        assert_equal(devtools.agent_launch_argv(claude)[:4], ["mise", "x", "claude", "--"], "a mise install runs through mise x, no stub needed")
        devtools.mise_installed_versions = lambda: ({}, "")
        devtools.input = lambda prompt: "n"
        assert_equal(devtools.agent_install_prompt(claude), False, "a refusal installs nothing")
        assert_equal(devtools.hold_terminal(3, "x"), 3, "hold keeps the failing status")
        assert_equal(ran, [], "no mise call after a refusal")
        devtools.input = lambda prompt: ""
        assert_equal(devtools.agent_install_prompt(claude), True, "Enter accepts the default yes")
        assert_equal(ran, [["mise", "use", "-g", "claude"]], "install goes through mise use -g")
    finally:
        del devtools.input
        devtools.mise_installed_versions = original_versions
        devtools.mise_stub_state = original_state
        mise.RT.command_exists = original_exists
        devtools.subprocess.run = original_run
        devtools.mise_install_stub = original_stub


def test_env_remove_keeps_shared_tools():
    """Removing Scala must not uninstall the Java the Java env also owns."""
    ran = []
    original = devtools.dev_env_run
    devtools.dev_env_run = lambda argv: (ran.append(list(argv)), 0)[1]
    original_exists = mise.RT.command_exists
    mise.RT.command_exists = lambda name: True
    try:
        scala = next(e for e in devtools.dev_env_entries() if e["id"] == "scala")
        assert_equal(devtools.dev_env_remove(scala), 0, "remove succeeds")
        touched = {argv[-1] for argv in ran}
        assert "java" not in touched and "scala" in touched, ran
    finally:
        devtools.dev_env_run = original
        mise.RT.command_exists = original_exists


def test_distro_owned_env_is_hands_off():
    """A pacman rustup means Rust is installed and VGS neither installs nor removes it."""
    original_which = devtools.shutil.which
    original_eprint = devtools.RT.eprint
    devtools.RT.eprint = lambda *a: None
    rust = next(e for e in devtools.dev_env_entries() if e["id"] == "rust")
    try:
        devtools.shutil.which = lambda name: "/usr/bin/rustup" if name == "rustup" else None
        row = next(e for e in devtools.dev_env_list()["envs"] if e["id"] == "rust")
        assert row["installed"] and row["distroPath"] == "/usr/bin/rustup", row
        assert_equal(devtools.dev_env_install(rust), 1, "install refuses a distro-owned env")
        assert_equal(devtools.dev_env_remove(rust), 1, "remove refuses a distro-owned env")
        devtools.shutil.which = lambda name: str(Path.home() / ".cargo" / "bin" / "rustup") if name == "rustup" else None
        row = next(e for e in devtools.dev_env_list()["envs"] if e["id"] == "rust")
        assert_equal(row["distroPath"], "", "a rustup under $HOME is the user's own, not the distro's")
    finally:
        devtools.shutil.which = original_which
        devtools.RT.eprint = original_eprint


def test_catalog_is_consistent():
    """One catalog feeds stubs, agents and envs; ids and commands must be unique."""
    catalog = mise.dev_tools_catalog()
    for section in ("agents", "tools", "envs"):
        assert catalog.get(section), f"catalog section {section} must not be empty"
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
    """Check that the wrapper and helper dispatcher expose the development commands."""
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
    test_update_run_and_count_carry_tools()
    test_os_release_resolves_through_id_like()
    test_first_launch_asks_before_installing()
    test_env_remove_keeps_shared_tools()
    test_distro_owned_env_is_hands_off()
    test_catalog_is_consistent()
    test_cli_wrapper_routes_the_commands()
    print("check-dev-tools: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
