#!/usr/bin/env python3
"""Checks for the mise/agent/dev-env subsystem (bin/vshell_mise.py,
bin/vshell_devtools.py, bin/vshell_update.py) and the catalog they read."""
from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[1]
# Icon and colour spellings the launcher tile can render.
TILE_ICON = re.compile(r"(nerd|brand):[0-9a-f]+")
TILE_COLOR = re.compile(r"#[0-9A-Fa-f]{6}")
# The step that settles the launchers after `mise up`, run as a new process.
REFRESH = [str(REPO_ROOT / "bin" / "vshell"), "mise", "refresh"]
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
    # Three ids whose backend-and-owner order is not their tool-name order.
    payload = ('{"npm:@deepseek-ai/dsh": {"name": "npm:@deepseek-ai/dsh", "current": "0.1.0", "latest": "0.1.1"},'
               ' "github:vercel-labs/fx": {"name": "github:vercel-labs/fx", "current": "0.0.7", "latest": "0.0.8"},'
               ' "claude": {"name": "claude", "current": "2.1.0", "latest": "2.2.0"}}')
    mise.RT.run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 0, stdout=payload, stderr="")
    try:
        rows, error = mise.mise_outdated()
        assert_equal(error, "", "valid JSON must not report an error")
        assert_equal(rows, [
            {"name": "claude", "id": "claude", "current": "2.1.0", "latest": "2.2.0"},
            {"name": "dsh", "id": "npm:@deepseek-ai/dsh", "current": "0.1.0", "latest": "0.1.1"},
            {"name": "fx", "id": "github:vercel-labs/fx", "current": "0.0.7", "latest": "0.0.8"},
        ], "rows carry the tool name and sort by it")
        mise.RT.run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 0, stdout="mise ERROR nope", stderr="")
        rows, error = mise.mise_outdated()
        assert rows == [] and "invalid JSON" in error, (rows, error)
        # A shape mise never prints for these subcommands is named, not walked
        # into: reading a list as a mapping raises AttributeError instead.
        mise.RT.run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 0, stdout="[]", stderr="")
        rows, error = mise.mise_outdated()
        assert rows == [] and "not an object" in error, (rows, error)
        installs, error = mise.mise_installs()
        assert installs == {} and "not an object" in error, (installs, error)

        steps = update.update_steps("all")
        titles = [step["title"] for step in steps]
        assert any("repo" in t for t in titles) and titles[-2].startswith("Updating mise tools"), titles
        assert steps[-2]["env"]["MISE_MINIMUM_RELEASE_AGE"] == "0", "mise up must skip the release cooldown"
        assert_equal([s["argv"] for s in update.update_steps("tools")], [["mise", "up"], REFRESH],
                     "tools mode runs mise up, then the refresh of the release on disk")
        present.discard("mise")
        assert_equal(update.update_steps("tools"), [], "an absent updater yields no step")
    finally:
        mise.RT.run = original_run
        mise.RT.command_exists = original_dev_exists
        update.RT.command_exists = original_upd_exists
        update.RT.eprint = original_eprint


def test_a_mise_id_reduces_to_the_tool_name():
    """mise files a package under its backend and owner for every backend but
    the default registry. An update list showing both spellings prefixes some
    rows and not others."""
    for package_id, want in (
        ("claude", "claude"),
        ("node", "node"),
        ("npm:@deepseek-ai/dsh", "dsh"),
        ("aqua:google-antigravity/antigravity-cli", "antigravity-cli"),
        ("github:can1357/oh-my-pi", "oh-my-pi"),
        ("pipx:hermes-agent", "hermes-agent"),
        ("http:muse", "muse"),
        ("npm:vercel", "vercel"),
        # Nothing follows the owner, so the id is all there is to show.
        ("github:owner/", "github:owner/"),
        ("npm:", "npm:"),
    ):
        assert_equal(mise.tool_name(package_id), want, f"tool name of {package_id}")


def test_update_run_and_count_carry_tools():
    """`update run tools` runs mise up then the stub refresh; a count merges mise rows."""
    calls = []
    original_run = update.subprocess.run
    original_input = update.input if hasattr(update, "input") else None
    original_exists = mise.RT.command_exists
    original_mise_run = mise.RT.run
    mise.RT.command_exists = lambda name: name in {"mise", "pacman", "checkupdates"}
    failing = []
    update.subprocess.run = lambda argv, check=False, env=None, cwd=None, **kw: (calls.append((list(argv), (env or {}).get("MISE_MINIMUM_RELEASE_AGE"), cwd)), subprocess.CompletedProcess(argv, int(argv in failing)))[1]
    update.input = lambda *a: ""
    try:
        assert_equal(update.cmd_update(["run", "tools"]), 0, "tools run must succeed")
        assert_equal(calls, [(["mise", "up"], "0", str(mise.RT.home())), (REFRESH, None, None)],
                     "tools mode runs mise up from $HOME with the cooldown off, then the refresh")
        failing.append(REFRESH)
        assert_equal(update.cmd_update(["run", "tools"]), 1, "a refresh that fails fails the run")

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
    original_settle = mise.mise_settle
    ran = []
    devtools.mise_installed_versions = lambda: ({}, "")
    devtools.mise_stub_state = lambda path: "absent"
    mise.RT.command_exists = lambda name: name == "mise"
    devtools.subprocess.run = lambda argv, **kw: (ran.append(list(argv)), subprocess.CompletedProcess(argv, 0))[1]
    devtools.mise_install_stub = lambda **kw: {"state": "written"}
    mise.mise_settle = lambda entry, installed: (ran.append(["settle", entry["id"], installed]), ("written", ""))[1]
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
        assert_equal(ran, [["mise", "use", "-g", "claude"], ["settle", "claude", True]],
                     "install goes through mise use -g, then settles the entry")
    finally:
        del devtools.input
        devtools.mise_installed_versions = original_versions
        devtools.mise_stub_state = original_state
        mise.RT.command_exists = original_exists
        devtools.subprocess.run = original_run
        devtools.mise_install_stub = original_stub
        mise.mise_settle = original_settle


def test_an_entry_without_this_machines_architecture_is_not_offered():
    """VGS ships aarch64. An entry that publishes only x86_64 assets must not
    reach a list on ARM: the tile would look installable and the first install
    would find no asset to choose."""
    catalog = mise.dev_tools_catalog()
    declared = [e for e in catalog["agents"] + catalog["apps"] + catalog["tools"] if e.get("arch")]
    assert declared, "the guard needs at least one entry declaring an architecture to judge"

    original = mise.platform.machine
    try:
        mise.platform.machine = lambda: "x86_64"
        on_x86 = {e["id"] for e in mise.launchable(catalog)}
        stubs_x86 = {s["command"] for s in mise.mise_catalog_stubs()}
        mise.platform.machine = lambda: "aarch64"
        on_arm = {e["id"] for e in mise.launchable(catalog)}
        stubs_arm = {s["command"] for s in mise.mise_catalog_stubs()}
        listed_arm = mise.mise_list()
    finally:
        mise.platform.machine = original

    for entry in declared:
        if "x86_64" not in entry["arch"]:
            continue
        name = entry.get("id") or entry["command"]
        assert name in on_x86 or entry["command"] in stubs_x86, f"{name} must be offered on x86_64"
        assert name not in on_arm, f"{name} publishes no ARM build and must not be offered there"
        assert entry["command"] not in stubs_arm, f"{name} must not get a stub on ARM"
    arm_ids = {e["id"] for e in listed_arm["agents"] + listed_arm["apps"]}
    assert arm_ids <= on_arm, "the settings list must not show what the launcher filtered out"
    # An entry naming no architecture is offered everywhere, or the filter would
    # have emptied both lists rather than trimmed them.
    assert "claude" in on_arm and "claude" in on_x86, "an entry naming no architecture builds everywhere"


def test_a_package_is_looked_up_under_the_id_mise_files_it_by():
    """mise drops inline backend options and the requested version from the id
    it reports, so a spec carrying either must be reduced before every lookup."""
    cases = [
        ("claude", "claude"),
        # The `@` in a scoped npm name is part of the name, never a version.
        ("npm:@xai-official/grok", "npm:@xai-official/grok"),
        ("github:pingdotgg/t3code[matching_regex=AppImage$,rename_exe=t3code]", "github:pingdotgg/t3code"),
        ("github:manaflow-ai/cmux-v2[matching_regex=linux-x64.zip]@nightly", "github:manaflow-ai/cmux-v2"),
        ("npm:@scope/name@1.2.3", "npm:@scope/name"),
    ]
    for package, expected in cases:
        assert_equal(mise.package_key(package), expected, f"{package} is filed under")

    # Every catalog entry has to resolve, or the entry is unreachable from the
    # moment it lands: the guard reads the catalog rather than a second list.
    catalog = mise.dev_tools_catalog()
    for entry in mise.launchable(catalog) + catalog["tools"]:
        key = mise.package_key(str(entry["package"]))
        assert key and "[" not in key and not key.endswith("@"), f"{entry['package']} reduces to {key!r}"

    # A tool mise reports as installed must read as installed here, which is
    # what the option-carrying specs got wrong.
    original = devtools.mise_installed_versions
    original_machine = mise.platform.machine
    devtools.mise_installed_versions = lambda: ({"github:pingdotgg/t3code": "0.0.40"}, "")
    # T3 Code is x86-only, so the entry this case is about is absent on an ARM
    # host. Pin the architecture rather than let the host pick the subject.
    mise.platform.machine = lambda: "x86_64"
    try:
        t3code = next(e for e in devtools.agent_entries() if e["id"] == "t3code")
        assert devtools.agent_installed(t3code), "an installed tool must not read as absent"
        assert_equal(devtools.agent_launch_argv(t3code)[:2], ["mise", "x"],
                     "and it must launch through mise x rather than being reinstalled")
    finally:
        devtools.mise_installed_versions = original
        mise.platform.machine = original_machine


def test_an_owner_installed_app_launches_its_public_command():
    """`launch` names the executable inside the package. An install VGS does not
    own has only the public command on PATH, and `orca.AppImage` is not it."""
    original = devtools.mise_installed_versions
    devtools.mise_installed_versions = lambda: ({}, "")
    try:
        orca = next(e for e in devtools.agent_entries() if e["id"] == "orca")
        assert_equal(orca["launch"], ["orca.AppImage"], "the entry launches the package's own file")
        assert_equal(devtools.agent_launch_argv(orca), ["orca-ide"],
                     "but an install mise does not own answers to the public command")
        dsh = next(e for e in devtools.agent_entries() if e["id"] == "dsh")
        assert_equal(devtools.agent_launch_argv(dsh), ["dsh", "web"],
                     "and the entry's own arguments survive the substitution")
    finally:
        devtools.mise_installed_versions = original


def test_an_interpreter_pin_reaches_the_build_and_no_further():
    """Hermes pins its interpreter for its own build. Exported past the install
    it would resolve that version in the owner's projects too, and `mise up`
    rebuilds without it, so the pin needs a probe as well as an export."""
    hermes = next(e for e in devtools.agent_entries() if e["id"] == "hermes")
    stub = mise.mise_stub_text(str(hermes["package"]), "hermes", "hermes",
                               dict(hermes["buildEnv"]), list(hermes["requires"]),
                               str(hermes["present"]))
    assert "export UV_PYTHON=3.13" in stub, stub
    assert "exec env -u UV_PYTHON mise x" in stub, \
        "the pin must not reach the agent or anything it shells out to: " + stub
    assert "mise use -g --quiet uv || exit 1" in stub, \
        "mise's pipx backend shells out to uv, which is not on every machine: " + stub
    assert "--force" in stub and "hermes-agent/lib/python3.13" in stub, \
        "a rebuild without the pin has to be noticed and redone: " + stub
    assert stub.index("uv || exit 1") < stub.index("--force"), \
        "uv has to be there before the build that needs it"

    # An entry with no pin keeps the plain stub: no probe, no force, no env -u.
    plain = mise.mise_stub_text("claude", "claude", "claude")
    assert "mise use -g --quiet claude || exit 1" in plain, plain
    for absent in ("--force", "mise where", "env -u"):
        assert absent not in plain, f"an entry with no build environment must not carry {absent}: {plain}"

    # The prompt installs the same way, loudly, because the owner is watching.
    steps = mise.mise_install_steps(str(hermes["package"]), list(hermes["requires"]),
                                    str(hermes["present"]), quiet=False)
    assert_equal(steps[0], ["mise", "use", "-g", "uv"], "the prompt installs the requirement first")
    assert_equal(steps[-1], ["mise", "use", "-g", "--force", str(hermes["package"])],
                 "and forces the pinned build")
    assert_equal(mise.mise_build_env(dict(hermes["buildEnv"]))["UV_PYTHON"], "3.13",
                 "with the same environment the stub exports")


def test_a_windowed_app_launches_without_a_terminal():
    """A GUI app draws its own window; a terminal wrapped around it would sit
    empty on the bar for as long as the app ran. A TUI agent still gets one."""
    terminals = []
    apps = []
    original_versions = devtools.mise_installed_versions
    original_state = devtools.mise_stub_state
    original_terminal = mise.RT.spawn_terminal
    original_app = mise.RT.spawn_app
    original_chdir = devtools.os.chdir
    devtools.mise_installed_versions = lambda: ({"github:stablyai/orca": "1.4.198", "claude": "2.2.0"}, "")
    devtools.mise_stub_state = lambda path: "ours"
    mise.RT.spawn_terminal = lambda argv, **kw: (terminals.append(list(argv)), 0)[1]
    mise.RT.spawn_app = lambda argv, **kw: (apps.append(list(argv)), 0)[1]
    devtools.os.chdir = lambda path: None
    try:
        assert_equal(devtools.agent_launch("orca", inline=False), 0, "the app launches")
        assert_equal(terminals, [], "a windowed app opens no terminal")
        assert_equal(apps, [["mise", "x", "github:stablyai/orca", "--", "orca.AppImage"]],
                     "the app runs its package's own executable through mise x")
        # The must-fail side: without the kind check every entry would take this
        # path, so a TUI agent has to still reach the terminal and not spawn_app.
        assert_equal(devtools.agent_launch("claude", inline=False), 0, "the agent launches")
        assert_equal(len(apps), 1, "a TUI agent must not be started as a windowed app")
        assert_equal(len(terminals), 1, "a TUI agent opens a terminal")
    finally:
        devtools.mise_installed_versions = original_versions
        devtools.mise_stub_state = original_state
        mise.RT.spawn_terminal = original_terminal
        mise.RT.spawn_app = original_app
        devtools.os.chdir = original_chdir


def test_apps_get_stubs_and_their_own_list():
    """Apps are launchable like agents and stubbed like tools, and every surface
    keeps them apart from the coding agents."""
    # An x86-only entry is absent from the stub set on an ARM host, so this case
    # pins the architecture rather than reading whichever one it happens to run
    # on. The architecture filter has its own case.
    original = mise.platform.machine
    mise.platform.machine = lambda: "x86_64"
    try:
        stubs = {s["command"]: s for s in mise.mise_catalog_stubs()}
    finally:
        mise.platform.machine = original
    assert "herdr" in stubs, "an app must get a lazy stub: " + " ".join(sorted(stubs))
    # The vendor calls its binary orca-ide, and so does this entry: a stub at
    # ~/.local/bin/orca would hide the GNOME screen reader of that name.
    assert_equal(stubs["orca-ide"]["bin_name"], "orca.AppImage",
                 "the stub execs the package's own executable, not the command name")
    assert "orca" not in stubs, "the command must not claim the screen reader's name"
    assert "gh" in stubs, "tools keep their stubs"
    # A package carrying mise backend options holds brackets, a backslash and a
    # `$`. Unquoted, the shell would glob the brackets and eat the rest, and the
    # stub would install some other tool or nothing at all.
    bracketed = mise.mise_stub_text(stubs["cmux"]["package"], "cmux", "cmux")
    assert "'" + stubs["cmux"]["package"] + "'" in bracketed, bracketed
    assert "[matching_regex=" in stubs["cmux"]["package"], "cmux names the asset its platform matcher cannot pick"

    original_versions = devtools.mise_installs
    original_state = devtools.mise_stub_state
    devtools.mise_installs = lambda: ({}, "")
    devtools.mise_stub_state = lambda path: "absent"
    mise.platform.machine = lambda: "x86_64"
    try:
        listed = devtools.agent_list()
        catalog = mise.dev_tools_catalog()
        expected_agents = [e["id"] for e in catalog["agents"] if mise.buildable_here(e)]
        expected_apps = [e["id"] for e in catalog["apps"] if mise.buildable_here(e)]
    finally:
        devtools.mise_installs = original_versions
        devtools.mise_stub_state = original_state
        mise.platform.machine = original
    agent_ids = [a["id"] for a in listed["agents"]]
    app_ids = [a["id"] for a in listed["apps"]]
    # Both directions: the lists come from the catalog's own sections, so an
    # entry can neither go missing nor arrive from the wrong one.
    assert_equal(agent_ids, expected_agents, "every agent is listed, in catalog order")
    assert_equal(app_ids, expected_apps, "every app is listed, in catalog order")
    assert "fx" in agent_ids, "a coding agent is listed as one: " + " ".join(agent_ids)
    assert "herdr" in app_ids, "an app is listed as one: " + " ".join(app_ids)
    assert not set(agent_ids) & set(app_ids), "no entry may appear in both lists"
    assert_equal(set(a["group"] for a in listed["apps"]), {"app"}, "each row names its group")


def channelled_entries(catalog):
    """Catalog entries offering a choice of release stream. Read from the
    catalog itself so a new one is judged the moment it lands."""
    return [e for group in ("agents", "apps") for e in catalog[group] if e.get("channels")]


def test_a_channel_picks_the_release_stream_a_tool_installs_from():
    """A channel adds backend options to the entry's own package, inside the
    bracket list mise reads and nowhere else. Outside it, mise installs some
    other tool or none; and the id it files the tool under must not move, or the
    tool reads as never installed and cannot be removed."""
    catalog = mise.dev_tools_catalog()
    declared = channelled_entries(catalog)
    assert declared, "the guard needs at least one entry declaring channels to judge"
    ids = {e["id"] for e in declared}
    assert "herdr" in ids, "herdr publishes a preview stream and must offer it: " + " ".join(sorted(ids))

    original_machine = mise.platform.machine
    original_settings = mise.RT.load_settings
    try:
        for machine in ("x86_64", "aarch64"):
            mise.platform.machine = lambda m=machine: m
            for entry in declared:
                if not mise.buildable_here(entry):
                    continue
                base = str(entry["package"])
                for channel, options in mise.entry_channels(entry).items():
                    mise.RT.load_settings = lambda e=entry, c=channel: {"devToolChannels": {e["id"]: c}}
                    row = next(r for r in mise.launchable(catalog) if r["id"] == entry["id"])
                    where = f"{entry['id']} on {machine} at {channel}"
                    assert_equal(row["channel"], channel, f"{where} installs from")
                    assert_equal(mise.package_key(row["package"]), mise.package_key(base),
                                 f"{where} must stay filed under the same mise id")
                    if not options:
                        assert_equal(row["package"], base, f"{where} adds no options, so the package is unchanged")
                        continue
                    assert row["package"] != base, f"{where} must change the package: {row['package']}"
                    bracket = mise.PACKAGE_OPTIONS.search(row["package"])
                    assert bracket and options in bracket.group(0), \
                        f"{where} must put {options} in the backend option list: {row['package']}"
                    stub = next(s for s in mise.mise_catalog_stubs() if s["command"] == entry["command"])
                    assert_equal(stub["package"], row["package"], f"{where} is what the stub installs")
                    # Quoted whole: the spec holds brackets, a `$` and a comma,
                    # which a bare shell word would glob away.
                    assert "'" + row["package"] + "'" in mise.mise_stub_text(stub["package"], stub["command"], stub["bin_name"]), \
                        f"{where} must reach the stub quoted"
            # The other direction: an entry the catalog gives no channels keeps
            # its package verbatim and offers nothing to pick.
            mise.RT.load_settings = lambda: {}
            plain = next(r for r in mise.launchable(catalog) if not r["channels"])
            raw = next(e for group in ("agents", "apps") for e in catalog[group] if e["id"] == plain["id"])
            assert_equal(plain["package"], str(raw["package"]), f"{plain['id']} publishes one stream and keeps its package")
            assert_equal(plain["channel"], "", f"{plain['id']} has no channel to be in")
    finally:
        mise.platform.machine = original_machine
        mise.RT.load_settings = original_settings


def test_a_settings_row_carries_the_streams_it_can_offer():
    """The Developer tab draws a dropdown from the row alone. Without the ids
    and the current one, a tool with two streams renders as if it had one."""
    original_versions = devtools.mise_installs
    original_state = devtools.mise_stub_state
    original_settings = mise.RT.load_settings
    original_machine = mise.platform.machine
    devtools.mise_installs = lambda: ({}, "")
    devtools.mise_stub_state = lambda path: "absent"
    mise.platform.machine = lambda: "x86_64"
    mise.RT.load_settings = lambda: {"devToolChannels": {"t3code": "nightly"}}
    try:
        listed = devtools.agent_list()
        rows = {r["id"]: r for r in listed["agents"] + listed["apps"]}
        catalog = mise.dev_tools_catalog()
        for entry in channelled_entries(catalog):
            if not mise.buildable_here(entry):
                continue
            expected = list(mise.entry_channels(entry))
            assert_equal(rows[entry["id"]]["channels"], expected, f"{entry['id']} offers")
            assert len(expected) > 1, f"{entry['id']}: a single channel is a dropdown with nothing to pick"
        assert_equal(rows["t3code"]["channel"], "nightly", "the row names the stream in force")
        assert "prerelease=true" in rows["t3code"]["package"], rows["t3code"]["package"]
        # And a row with one stream says so, rather than carrying a stale list.
        assert_equal(rows["claude"]["channels"], [], "an entry with one stream offers no choice")
        assert_equal(rows["claude"]["channel"], "", "and names no channel")
    finally:
        devtools.mise_installs = original_versions
        devtools.mise_stub_state = original_state
        mise.RT.load_settings = original_settings
        mise.platform.machine = original_machine


def test_a_channel_the_catalog_dropped_falls_back_to_the_default():
    """settings.json outlives a catalog edit. A pick the catalog no longer
    offers must not reach mise, which would install from a stream that is gone
    or, for an option mise cannot parse, refuse the install outright."""
    catalog = mise.dev_tools_catalog()
    entry = next(e for e in channelled_entries(catalog) if e["id"] == "herdr")
    default = str(entry["channels"]["default"])
    other = next(c for c in mise.entry_channels(entry) if c != default)
    cases = [
        ({}, default, "no pick at all"),
        ({"devToolChannels": {"herdr": other}}, other, "a pick the catalog offers"),
        ({"devToolChannels": {"herdr": "retired"}}, default, "a pick the catalog dropped"),
        ({"devToolChannels": {"herdr": ""}}, default, "an empty pick"),
        ({"devToolChannels": "nightly"}, default, "a setting of the wrong shape"),
        ({"devToolChannels": {"orca": other}}, default, "a pick belonging to another entry"),
    ]
    original = mise.RT.load_settings
    try:
        for settings, expected, what in cases:
            mise.RT.load_settings = lambda s=settings: s
            assert_equal(mise.entry_channel(entry, mise.dev_tool_channels()), expected, f"{what} resolves to")
    finally:
        mise.RT.load_settings = original

    # A catalog whose default names no option is a defect in the shipped file,
    # and it fails loudly rather than installing from whichever stream is first.
    broken = {"id": "broken", "package": "x", "channels": {"default": "gone", "options": {"stable": ""}}}
    try:
        mise.entry_channel(broken, {})
    except ValueError as exc:
        assert "gone" in str(exc), exc
    else:
        raise AssertionError("a default naming no option must be reported")


def test_setting_a_channel_records_it_and_rewrites_the_stub():
    """The setting alone changes nothing: the stub carries the package spec, so
    a recorded channel that never reaches ~/.local/bin still installs the old
    stream on the next launch."""
    catalog = mise.dev_tools_catalog()
    entry = next(e for e in channelled_entries(catalog) if e["id"] == "herdr")
    default = str(entry["channels"]["default"])
    other = next(c for c in mise.entry_channels(entry) if c != default)
    options = mise.entry_channels(entry)[other]

    with tempfile.TemporaryDirectory() as tmp:
        stored = {}
        original_home = mise.RT.home
        original_state = mise.RT.state_dir
        original_settings = mise.RT.load_settings
        original_set = mise.RT.set_settings_value
        original_eprint = mise.RT.eprint
        original_path = os.environ.get("PATH", "")
        mise.RT.home = lambda: Path(tmp)
        mise.RT.state_dir = lambda: Path(tmp) / ".local" / "state" / "vshell"
        mise.RT.load_settings = lambda: dict(stored)
        mise.RT.set_settings_value = lambda key, value: stored.__setitem__(key, value) or dict(stored)
        mise.RT.eprint = lambda *a: None
        os.environ["PATH"] = str(Path(tmp) / ".local" / "bin")
        stub = Path(tmp) / ".local" / "bin" / str(entry["command"])
        try:
            # Seed the stubs at the default, so what follows is judged on the
            # rewrite rather than on the file appearing for the first time.
            mise.mise_refresh()
            assert options not in stub.read_text(), "the seeded stub starts on the default stream"

            result = mise.mise_set_channel("herdr", other)
            assert result["ok"], result
            assert_equal(stored["devToolChannels"], {"herdr": other}, "the pick is recorded under")
            assert_equal(result["channel"], other, "and reported back as")
            assert options in stub.read_text(), \
                f"the rewritten stub must install from {other}: " + stub.read_text()

            # And back again, so the change is not one-way.
            assert mise.mise_set_channel("herdr", default)["ok"]
            assert_equal(stored["devToolChannels"], {"herdr": default}, "the second pick replaces the first")
            assert options not in stub.read_text(), \
                f"the stub must return to {default}: " + stub.read_text()

            # Refusals: each leaves the recorded pick and the stub alone.
            before = stub.read_text()
            for entry_id, channel, why in [
                ("herdr", "retired", "a channel the entry does not offer"),
                ("claude", default, "an entry with one release stream"),
                ("nosuch", default, "an entry the catalog does not carry"),
            ]:
                refused = mise.mise_set_channel(entry_id, channel)
                assert not refused["ok"], f"{why} must be refused: {refused}"
                assert refused["error"], f"{why} must say why: {refused}"
                assert_equal(stored["devToolChannels"], {"herdr": default}, f"{why} must record nothing")
                assert_equal(stub.read_text(), before, f"{why} must not rewrite the stub")
                assert_equal(mise.cmd_mise(["channel", entry_id, channel, "--json"]), 1, f"{why} exits non-zero")
            assert_equal(mise.cmd_mise(["channel", "herdr"]), 2, "a missing argument is a usage error")
            assert_equal(mise.cmd_mise(["channel", "herdr", default, "extra"]), 2, "so is a surplus one")
        finally:
            mise.RT.home = original_home
            mise.RT.state_dir = original_state
            mise.RT.load_settings = original_settings
            mise.RT.set_settings_value = original_set
            mise.RT.eprint = original_eprint
            os.environ["PATH"] = original_path


def test_the_settings_tab_runs_the_channel_command():
    """The dropdown is the only way a channel gets picked. A tab that draws it
    without running the command leaves every pick silently undone."""
    tab = (REPO_ROOT / "quickshell" / "vshell" / "Modules" / "Settings" / "DeveloperTab.qml").read_text()
    assert '"mise", "channel"' in tab, "the Developer tab must run vshell mise channel"
    # The command has to be reached from the pick, not merely defined: a handler
    # that only writes back to the row leaves the shell showing a stream nothing
    # installs from.
    assert "onValueChanged" in tab, "the dropdown must handle a pick"
    assert "root.setChannel(row.modelData.id," in tab, \
        "the pick must run the channel command for the row it came from"
    assert "options: row.modelData.channels" in tab, "the dropdown lists the row's own streams"
    assert "currentValue: row.modelData.channel" in tab, "and shows the one in force"
    assert "vshell mise channel" in (REPO_ROOT / "bin" / "vshell").read_text(), \
        "bin/vshell must document the channel command"

    # A failed pick reports into a property `refresh` rewrites, so an error left
    # in `loadError` is cleared by the re-read that follows within the second:
    # the owner is left with a reverted dropdown and no reason for it.
    body = tab[tab.index("function setChannel("):]
    body = body[:body.index("\n    }") + 6]
    assert "root.loadError" not in body, \
        "setChannel must not report into loadError, which its own refresh clears"
    assert "root.channelError =" in body, "setChannel must report into a property refresh keeps"
    assert "root.channelError" not in tab[tab.index("function refresh("):tab.index("function setChannel(")], \
        "refresh must leave the channel error alone"
    assert "root.channelError" in tab[tab.index("readonly property string shownError"):tab.index("function refresh(")], \
        "the error the tab shows must include the channel error"
    assert "text: root.shownError" in tab, "the error banner must draw it"


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


def test_mise_installs_reads_declaration_and_active_version():
    """`declared` and the version come from raw `mise ls --json`. A parser that
    marks every install declared makes an untracked tool read as tracked and
    removes the only prompt to fix it; one that takes the wrong row reports a
    version the shell is not running."""
    payload = json.dumps({
        # Declared: a config asked for it, so `mise outdated` reports it.
        "claude": [
            {"version": "2.1.0", "installed": True, "active": False},
            {"version": "2.2.0", "installed": True, "active": True,
             "source": {"type": "mise.toml", "path": "/home/u/.config/mise/config.toml"}},
        ],
        # Installed, declared nowhere: no source on any row.
        "daytona": [{"version": "0.190.0", "installed": True, "active": True}],
        # An install that never finished is not a version to report.
        "ghost": [{"version": "9.9.9", "installed": False, "active": True}],
        # Nothing active: the first installed row is the one to show.
        "sesh": [{"version": "2.29.0", "installed": True, "active": False}],
        # A shape mise does not emit must not crash the read.
        "junk": "not-a-list",
    })
    original_run = mise.RT.run
    original_exists = mise.RT.command_exists
    try:
        mise.RT.command_exists = lambda name: True
        mise.RT.run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 0, stdout=payload, stderr="")
        installs, error = mise.mise_installs()
        assert_equal(error, "", "valid JSON must not report an error")
        assert_equal(installs, {
            "claude": {"version": "2.2.0", "declared": True},
            "daytona": {"version": "0.190.0", "declared": False},
            "sesh": {"version": "2.29.0", "declared": False},
        }, "declaration and active version come from the raw rows")
        # The narrower reader is the same parse, so the two cannot disagree.
        versions, _ = mise.mise_installed_versions()
        assert_equal(versions, {"claude": "2.2.0", "daytona": "0.190.0", "sesh": "2.29.0"},
                     "the version map is the same read")
    finally:
        mise.RT.run = original_run
        mise.RT.command_exists = original_exists


def test_install_origin_names_what_provides_a_command():
    """A row's whole vocabulary comes from this. `mise outdated` reports only
    what a config declares, so an install nothing declares never reaches an
    update count: that case has to read differently from a tracked one, and
    from a distribution package holding the same command."""
    original_installs = mise.mise_installs
    original_owner = devtools.distro_package_owning
    original_which = mise.command_on_path_elsewhere
    try:
        entry = {"id": "t", "name": "T", "command": "toolcmd", "package": "npm:@scope/toolcmd"}

        # Declared in a config: mise tracks it and an update moves it.
        installs = {"npm:@scope/toolcmd": {"version": "1.2.3", "declared": True}}
        assert_equal(devtools.install_origin(entry, installs),
                     {"origin": "mise", "path": "", "owner": "", "version": "1.2.3"},
                     "a declared install is tracked")

        # Installed, declared nowhere: invisible to every update count.
        installs = {"npm:@scope/toolcmd": {"version": "1.2.3", "declared": False}}
        assert_equal(devtools.install_origin(entry, installs)["origin"], "untracked",
                     "an install no config declares must not read as tracked")

        # Not in mise: what holds the command on PATH decides the row.
        mise.command_on_path_elsewhere = lambda command, local_bin: "/usr/bin/toolcmd"
        devtools.distro_package_owning = lambda path: "toolcmd-bin"
        assert_equal(devtools.install_origin(entry, {}),
                     {"origin": "system", "path": "/usr/bin/toolcmd", "owner": "toolcmd-bin", "version": ""},
                     "a package-owned path names the package")
        devtools.distro_package_owning = lambda path: ""
        assert_equal(devtools.install_origin(entry, {})["origin"], "external",
                     "a path no package owns is the owner's own file, not a system package")
        mise.command_on_path_elsewhere = lambda command, local_bin: ""
        assert_equal(devtools.install_origin(entry, {})["origin"], "absent",
                     "nothing on PATH and nothing in mise is absent")
    finally:
        mise.mise_installs = original_installs
        devtools.distro_package_owning = original_owner
        mise.command_on_path_elsewhere = original_which


def test_row_actions_run_and_refuse():
    """`track` and `replace` are the two actions that change a machine, and
    `replace` removes a distribution package with elevation before it installs
    anything. Each has to act on the right entry, refuse the state it cannot
    handle, and stop rather than continue when a step fails."""
    original_installs = devtools.mise_installs
    original_owner = devtools.distro_package_owning
    original_which = mise.command_on_path_elsewhere
    original_ids = devtools.os_release_ids
    original_run = devtools.subprocess.run
    original_dev_run = devtools.dev_env_run
    original_stub = devtools.mise_install_stub
    original_hold = devtools.hold_terminal
    original_state = mise.mise_stub_state
    original_settle = mise.mise_settle
    calls = []
    said = []
    try:
        # The real one waits on stdin to keep a one-shot terminal readable.
        devtools.hold_terminal = lambda code, message: (said.append(message), code)[1]
        devtools.os_release_ids = lambda: ["arch"]
        devtools.mise_install_stub = lambda **kw: calls.append(("stub", kw["command"]))
        devtools.dev_env_run = lambda argv: (calls.append(("mise", argv)), 0)[1]
        mise.mise_settle = lambda entry, installed: (calls.append(("settle", entry["command"])), ("written", ""))[1]

        # track: declares an install mise already holds, then settles it.
        devtools.mise_installs = lambda: ({"daytona": {"version": "0.190.0", "declared": False}}, "")
        entry = next(e for e in devtools.catalog_entries() if e["id"] == "daytona")
        assert_equal(devtools.entry_track(entry), 0, "tracking an undeclared install succeeds")
        assert_equal(calls, [("mise", ["mise", "use", "-g", "daytona"]), ("settle", "daytona")],
                     "track declares the entry's package, then settles the entry")

        # track: refuses what it cannot help, and changes nothing either way.
        calls.clear()
        devtools.mise_installs = lambda: ({"daytona": {"version": "0.190.0", "declared": True}}, "")
        assert_equal(devtools.entry_track(entry), 0, "an already-tracked install is not an error")
        devtools.mise_installs = lambda: ({}, "")
        assert_equal(devtools.entry_track(entry), 1, "an install mise does not hold is refused")
        assert_equal(calls, [], "a refusal runs no mise command")

        # replace: refuses when no distribution package owns the command.
        mise.command_on_path_elsewhere = lambda command, local_bin: ""
        assert_equal(devtools.entry_replace(entry), 1, "nothing to replace is refused")
        assert_equal(calls, [], "and removes nothing")

        # replace: removes the owner, then installs. Elevation is the first step
        # and the install must not run when it fails.
        mise.command_on_path_elsewhere = lambda command, local_bin: "/usr/bin/gh"
        devtools.distro_package_owning = lambda path: "github-cli"
        gh = next(e for e in devtools.catalog_entries() if e["id"] == "gh")

        def failing_run(argv, **kw):
            calls.append(("run", list(argv)))
            return subprocess.CompletedProcess(argv, 1)

        devtools.subprocess.run = failing_run
        assert_equal(devtools.entry_replace(gh), 1, "a failed removal fails the action")
        assert_equal(calls, [("run", ["sudo", "pacman", "-Rns", "github-cli"])],
                     "and stops before installing anything")

        calls.clear()

        def ok_run(argv, **kw):
            calls.append(("run", list(argv)))
            return subprocess.CompletedProcess(argv, 0)

        devtools.subprocess.run = ok_run
        assert_equal(devtools.entry_replace(gh), 0, "removal then install succeeds")
        assert_equal(calls[0], ("run", ["sudo", "pacman", "-Rns", "github-cli"]),
                     "the distribution package goes first")
        assert any(step[0] == "run" and step[1][:3] == ["mise", "use", "-g"] for step in calls[1:]), \
            f"then the mise install runs: {calls}"
        assert ("stub", "gh") in calls, f"and the launcher stub is written: {calls}"
        assert_equal(calls[-1], ("settle", "gh"), "and the install ends by settling the entry")

        # Track and Replace record the Cursor row's options, which take its
        # package off PATH. Behind the owner's own launcher, each refuses before
        # any mise command, and Replace before it removes anything.
        cursor = next(e for e in devtools.catalog_entries() if e["id"] == "cursor")
        mise.mise_stub_state = lambda path: "foreign"
        for label, installs, act in (("Track", {"cursor-agent": {"version": "1", "declared": False}}, devtools.entry_track),
                                     ("Replace with mise", {}, devtools.entry_replace)):
            calls.clear()
            devtools.mise_installs = lambda: (installs, "")
            assert_equal((act(cursor), calls), (1, []), f"{label} refuses and runs nothing")
            assert said[-1].startswith("mise-launcher-not-ours: cursor ") and said[-1].endswith(
                "run: mise use -g 'cursor-agent[bin_path=]'"), said[-1]

        # cmd_agent routes each verb to the entry the id names, tools included.
        routed = []
        for verb in ("track", "replace", "update", "remove"):
            devtools.ENTRY_ACTIONS[verb] = (lambda v: lambda e: (routed.append((v, e["id"])), 0)[1])(verb)
        for verb in ("track", "replace", "update", "remove"):
            assert_equal(devtools.cmd_agent([verb, "daytona"]), 0, f"{verb} routes a tool id")
        assert_equal(routed, [("track", "daytona"), ("replace", "daytona"),
                              ("update", "daytona"), ("remove", "daytona")],
                     "each verb reaches its own action with the entry it named")
        assert_equal(devtools.cmd_agent(["track", "nosuch"]), 2, "an unknown id is a usage error")
    finally:
        devtools.mise_installs = original_installs
        devtools.distro_package_owning = original_owner
        mise.command_on_path_elsewhere = original_which
        devtools.os_release_ids = original_ids
        devtools.subprocess.run = original_run
        devtools.dev_env_run = original_dev_run
        devtools.mise_install_stub = original_stub
        devtools.hold_terminal = original_hold
        mise.mise_stub_state = original_state
        mise.mise_settle = original_settle


def test_the_settings_tab_can_act_on_every_row():
    """Each state the classifier can report needs a way out of it, or the tab
    shows a problem the reader cannot fix."""
    tab = (REPO_ROOT / "quickshell" / "vshell" / "Modules" / "Settings" / "DeveloperTab.qml").read_text()
    # Every verb a row can offer has to reach the CLI. They go through one
    # runner, so the pin is that the runner passes the verb through rather than
    # naming a fixed one.
    assert '"agent", verb, entry.id' in tab, "the row action must run the verb it was given"
    for verb in ("track", "replace", "update", "remove"):
        assert f'"verb": "{verb}"' in tab, f"a row state must be able to offer {verb}"
    assert 'root.tools' in tab, "the tab must draw the catalog's tools section"
    assert 'I18n.tr("Developer Tools")' in tab, "the tools card must be titled"
    # Uninstall destroys an install; a single click must not do it. The pin is
    # the early return, not the flag: a flag the handler never consults reads
    # the same in the file and removes nothing.
    assert "if (menuItem.modelData.danger && !menuItem.confirming) {" in tab, \
        "the first click on a destructive item must arm, not act"
    assert '"danger": true' in tab, "uninstall must be the item that arms"
    for verb, origin in (("track", "untracked"), ("replace", "system")):
        assert f'"{verb}"' in tab and f'"{origin}"' in tab, \
            f"the {origin} state must offer {verb}"
    # The count on the bulk button is derived from the rows, never typed.
    assert "root.outdatedCount" in tab, "the update button must count the rows it would move"
    assert "e.latest" in tab, "and count them by the release each row is waiting for"
    # Turning auto-install off uninstalls nothing, and the copy has to say so.
    assert "Turn off auto-install" in tab, "the bulk control must say what it does"
    assert "Turning it off uninstalls nothing" in tab, "and must say what it does not do"


def test_a_row_carries_the_release_it_is_waiting_for():
    """The tab shows an update per row and counts them on one button. A row that
    does not carry its own pending release leaves both to a second source."""
    original_installs = devtools.mise_installs
    original_outdated = devtools.mise_outdated
    original_exists = devtools.RT.command_exists
    try:
        devtools.RT.command_exists = lambda name: True
        devtools.mise_installs = lambda: ({"claude": {"version": "2.1.0", "declared": True},
                                           "gh": {"version": "2.0.0", "declared": True}}, "")
        devtools.mise_outdated = lambda: ([{"name": "claude", "id": "claude",
                                            "current": "2.1.0", "latest": "2.2.0"}], "")
        listed = devtools.agent_list()
        rows = {r["id"]: r for g in ("agents", "apps", "tools") for r in listed[g]}
        assert_equal(rows["claude"]["latest"], "2.2.0", "a row mise would move names the release")
        assert_equal(rows["gh"]["latest"], "", "a current row names none")
        assert_equal(rows["playwright"]["latest"], "", "nor does one that is not installed")
    finally:
        devtools.mise_installs = original_installs
        devtools.mise_outdated = original_outdated
        devtools.RT.command_exists = original_exists


def test_a_package_kept_off_path_runs_by_absolute_path():
    """The tile runs the file `exec` names under the root `mise where` names, as
    the stub does. A launch mise names no root for is a refusal the owner
    reads, not an exec from / or a traceback in a window that closes."""
    cursor = next(e for e in devtools.agent_entries() if e["id"] == "cursor")
    asked, held, reply = [], [], [(0, "/i/cursor-agent/1\n", "")]

    def fake_run(cmd, check=False, **kw):
        asked.append((list(cmd), kw["cwd"], kw["kill_group"]))
        return subprocess.CompletedProcess(cmd, reply[0][0], stdout=reply[0][1], stderr=reply[0][2])

    with mock.patch.multiple(devtools, mise_installed_versions=lambda: ({"cursor-agent": "1"}, ""),
                             hold_terminal=lambda code, message: (held.append(message), code)[1]), \
            mock.patch.multiple(mise.RT, run=fake_run, command_exists=lambda name: True), \
            mock.patch.multiple(devtools.os, chdir=lambda path: None, execvpe=lambda *a: 0):
        assert_equal(devtools.agent_launch_argv(cursor), ["/i/cursor-agent/1/dist-package/cursor-agent", "--force"],
                     "the launcher runs the file under the install root, keeping the entry's own arguments")
        assert_equal(asked, [(["mise", "where", "cursor-agent[bin_path=]"], str(mise.RT.home()), True)],
                     "it asks mise the stub's question from $HOME, and a timeout ends its whole group")
        # mise exiting 0 with nothing to say, and mise failing, whose own error is the reason.
        for code, stderr, cause in ((0, "", "mise reported no install root for cursor-agent[bin_path=]"),
                                    (1, "mise ERROR not installed", "mise ERROR not installed")):
            reply[0] = (code, "", stderr)
            assert_equal(devtools.cmd_agent(["launch", "cursor", "--inline", "--hold"]), 1, cause)
            assert held[-1].endswith(": " + cause), held


def test_an_exec_stub_runs_the_file_under_the_install_root():
    """A stub is what a terminal runs. It runs the `exec` file under the root a
    stand-in mise names, and refuses when mise names none rather than exec
    /dist-package/... from the filesystem root."""
    cursor = next(e for e in devtools.catalog_entries() if e["id"] == "cursor")
    with tempfile.TemporaryDirectory() as tmp:
        fake = Path(tmp)
        (fake / "dist-package").mkdir()
        (fake / "cursor-agent").write_text(mise.mise_stub_text(**mise.stub_fields(cursor)))
        (fake / "mise").write_text('#!/bin/sh\n[ "$1" = where ] && printf "%s" "$ROOT"\nexit 0\n')
        (fake / "dist-package" / "cursor-agent").write_text('#!/bin/sh\necho "ran $*"\n')
        for path in (fake / "cursor-agent", fake / "mise", fake / "dist-package" / "cursor-agent"):
            path.chmod(0o755)
        for root, code, first in ((str(fake), 0, "ran --x"), ("", 1, "cursor-agent: mise reported no install root")):
            proc = subprocess.run([str(fake / "cursor-agent"), "--x"], env={"PATH": str(fake), "ROOT": root},
                                  capture_output=True, text=True, timeout=30)
            assert_equal(proc.returncode, code, f"root {root!r}: {proc.stderr}")
            assert (proc.stdout + proc.stderr).startswith(first), proc
    # A release that cannot run `exec` reads this catalog while `vshell update run
    # all` upgrades VGS under it, and writes each stub from the raw row. Its
    # `mise x` must name a spec that leaves the package on PATH, or the stub
    # finds only itself there (D016).
    for raw in (e for group in ("agents", "apps", "tools") for e in mise.dev_tools_catalog()[group] if e.get("exec")):
        old = mise.mise_stub_text(raw["package"], raw["command"], raw.get("bin") or raw["command"])
        run = next(line for line in old.splitlines() if " mise x " in line)
        assert "[" not in run, f"{raw['id']}: a release without `exec` writes {run}"


EXPORT_CASES = (
    # id, exec, launch, the executables mise reports for the install (`a->b` a
    # link inside the package, None an install mise cannot answer for), the
    # undeclared ones that must be reported, and whether its directory is on
    # PATH (None: not installed). The unanswerable one comes first, so a
    # conflict after it has to survive its error.
    ("broken", "", [], None, [], True),
    ("open", "", [], ["node", "opencmd"], ["node"], True),
    # Declared, so owned, though /usr-bin answers to it as well.
    ("own", "", [], ["owncmd"], [], True),
    # Undeclared, but nothing else on PATH answers to it, so it shadows nothing.
    ("solo", "", [], ["solocmd", "unique-helper"], [], True),
    # Undeclared, and only mise's shims for this same install answer elsewhere.
    ("shimmed", "", [], ["shimmedcmd", "extra-helper"], [], True),
    # The file `exec` names and the executable the launch argv names are owned.
    ("closed", "dist/closed-real", [], ["closed-real"], [], True),
    ("named", "", ["named-real", "--flag"], ["named-real"], [], True),
    # Reported through mise's `latest` link to the directory PATH carries.
    ("linked", "", [], ["linked-helper"], [], True),
    # The declared command's link target is undeclared, and replaces /usr-bin's.
    ("alias", "", [], ["aliascmd->alias-real", "alias-real"], ["alias-real"], True),
    # A link to the declared file whose only other copy answers ahead of the
    # package, from a directory PATH lists again behind it: a shell finds the
    # first place, so it is no copy the package replaces.
    ("ahead", "", [], ["aheadcmd", "ahead-real->aheadcmd"], [], True),
    # Off PATH, as under the shell service's PATH: every other copy counts but
    # the one in ~/.local/bin, which answers ahead of any install.
    ("hidden", "", [], ["hiddencmd", "stray", "wrapped"], ["stray"], False),
    # Not installed, so it puts no directory on PATH and is never asked about.
    ("absent", "", [], ["node"], [], None),
)


def test_an_install_may_not_export_a_command_the_entry_does_not_own():
    """An executable a package ships beside its own answers ahead of /usr/bin:
    the Cursor Agent package shipped `node` 24.5.0 over the system's 26.8.1."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        distro, ahead, stubs, shims = root / "usr-bin", root / "own-bin", root / ".local" / "bin", root / "shims"
        # /usr-bin holds mise itself, as /usr/bin does on the machine this was
        # filed from, and its `node` links out of every PATH directory, as
        # /usr/bin/npm does there: neither makes a /usr-bin copy the install's.
        for path in [distro / n for n in ("mise", "owncmd", "closed-real", "named-real", "alias-real", "stray")] \
                + [ahead / "ahead-real", stubs / "wrapped", root / "node-real"]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        (distro / "node").symlink_to(root / "node-real")
        # One link to the mise binary per exported executable, `node` included,
        # so passing the shims over must not lose the /usr-bin conflict.
        shims.mkdir()
        for name in ("node", "extra-helper", "shimmedcmd"):
            (shims / name).symlink_to(distro / "mise")
        exports, installed = {}, {}
        for entry_id, _exec, _launch, names, _bad, on_path in EXPORT_CASES:
            bin_dir = root / f"mise-{entry_id}"
            bin_dir.mkdir()
            for name, _, target in (name.partition("->") for name in names or []):
                if target:
                    (bin_dir / name).symlink_to(target)
                else:
                    (bin_dir / name).write_text("#!/bin/sh\nexit 0\n")
                    (bin_dir / name).chmod(0o755)
            reported = root / "latest" if entry_id == "linked" else bin_dir
            if entry_id == "linked":
                reported.symlink_to(bin_dir)
            exports[f"{entry_id}pkg"] = None if names is None else [
                {"name": n.partition("->")[0], "path": str(reported / n.partition("->")[0])} for n in names]
            if on_path is not None:
                installed[f"{entry_id}pkg"] = [{"version": "1", "installed": True, "active": True, "source": {}}]
        catalog = {"agents": [{"id": i, "name": i, "command": f"{i}cmd", "package": f"{i}pkg",
                               **({"exec": e} if e else {}), **({"launch": l} if l else {})}
                              for i, e, l, *_ in EXPORT_CASES], "apps": [], "tools": []}
        # The owner's shells: ~/.local/bin first, then every mise bin path ahead
        # of the distribution's, and both personal directories again at the end.
        path = [stubs, ahead] + [root / f"mise-{row[0]}" for row in EXPORT_CASES if row[-1]] + [shims, distro, ahead, stubs]
        asked = []

        def fake_run(cmd, check=False, **kw):
            asked.append(cmd[-1])
            answer = installed if cmd[1] == "ls" else exports[cmd[-1]]
            return subprocess.CompletedProcess(cmd, int(answer is None), stdout=json.dumps(answer), stderr=f"mise ERROR {cmd[-1]}")

        with mock.patch.multiple(mise, dev_tools_catalog=lambda: catalog), \
                mock.patch.multiple(mise.RT, run=fake_run, command_exists=lambda name: True, load_settings=dict,
                                    home=lambda: root), \
                mock.patch.dict(os.environ, {"PATH": os.pathsep.join(map(str, path))}):
            checked = mise.mise_export_check(*mise.installed_entries())
            for entry_id, _exec, _launch, _names, bad, _on_path in EXPORT_CASES:
                assert_equal([c["command"] for c in checked["exports"] if c["id"] == entry_id], bad,
                             f"{entry_id}: only an undeclared export that replaces another copy is a conflict")
            assert_equal(checked["error"].splitlines()[:2], [
                "mise-export-check-failed: broken: mise ERROR brokenpkg",
                f"mise-export-shadow: open exports node, which also answers at {distro / 'node'}"],
                "an install mise cannot answer for is named, and a conflict names the copy it replaces")
            assert "absentpkg" not in asked and not checked["ok"], (asked, checked)
            # A mise that cannot answer, or answers in a shape it never prints for
            # this, is never read as "no conflicts"; no mise at all is.
            object_run = lambda cmd, check=False, **kw: subprocess.CompletedProcess(
                cmd, 0, stdout=json.dumps(installed) if cmd[1] == "ls" else "{}", stderr="")
            for label, run, exists, want in (
                    ("mise fails", lambda cmd, check=False, **kw: subprocess.CompletedProcess(cmd, 1, stdout="", stderr="mise ERROR nope"),
                     True, (False, "mise-export-check-failed: mise ERROR nope")),
                    ("bin-paths prints an object", object_run, True,
                     (False, "mise-export-check-failed: broken: mise bin-paths printed dict, not a list")),
                    ("no mise", fake_run, False, (True, ""))):
                mise.RT.run, mise.RT.command_exists = run, lambda name: exists
                result = mise.mise_export_check(*mise.installed_entries())
                assert_equal((result["ok"], result["error"].split("; ")[0]), want, label)


def test_every_launcher_is_settled_before_its_option_is_recorded():
    """mise records a spec's options once, so an earlier Cursor Agent install
    keeps its package, and `node`, on PATH until the refresh re-declares it.
    After that only the launcher runs `cursor-agent`: every launcher is kept
    current, auto-install on or off, and the option is recorded only behind
    the stub the refresh has just written."""
    # In `tools`, so the spec `exec` gives an entry is pinned outside the
    # launchable groups too.
    catalog = {"agents": [], "apps": [], "tools": [
        {"id": "cursor", "name": "Cursor", "command": "cursor-agent", "package": "cursor-agent",
         "exec": "dist-package/cursor-agent"},
        {"id": "plain", "name": "Plain", "command": "plaincmd", "package": "plainpkg"}]}
    installed = {"cursor-agent": [{"version": "1", "installed": True, "active": True, "source": {}}]}
    # The spec whose old option mise still holds, and so still exports `node`.
    recorded, refused, ran = {"cursor-agent"}, set(), []

    def fake_run(cmd, check=False, **kw):
        assert kw["kill_group"], f"a mise call that outlives its timeout: {cmd}"
        if cmd[1] == "bin-paths":
            node = [{"name": "node", "path": "/i/cursor-agent/dist-package/node"}] if cmd[-1] in recorded else []
            return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(node), stderr="")
        ran.append(cmd[1:])
        if refused & {cmd[1], cmd[-1]}:
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="mise ERROR nope")
        recorded.discard(mise.package_key(cmd[-1]))
        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(installed), stderr="")

    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        bin_dir, distro, marker = home / ".local" / "bin", home / "usr-bin", home / "state" / mise.MISE_STUBS_REMOVED
        launcher, plain = bin_dir / "cursor-agent", bin_dir / "plaincmd"
        for path in (distro / "node", marker, launcher):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\n")
        (distro / "node").chmod(0o755)

        def state(path, entry_id):
            found = mise.mise_stub_state(path)
            if found != "ours":
                return found
            entry = next(e for e in mise.manageable(catalog) if e["id"] == entry_id)
            return "current" if path.read_text() == mise.mise_stub_text(**mise.stub_fields(entry)) else "stale"

        # What main wrote: its Cursor stub runs `mise x` on the plain spec, and
        # the other stub is one this release never writes.
        main_stubs = lambda: (launcher.write_text(mise.mise_stub_text("cursor-agent", "cursor-agent", "cursor-agent")),
                              plain.write_text(f"#!/bin/bash\n{mise.MISE_STUB_MARKER}\nexec mise x plainpkg -- plaincmd\n"))
        ls, use = ["ls", "--json"], ["use", "-g", "--quiet", "cursor-agent[bin_path=]"]
        with mock.patch.multiple(mise, dev_tools_catalog=lambda: catalog), \
                mock.patch.multiple(mise.RT, run=fake_run, command_exists=lambda name: True, load_settings=dict,
                                    eprint=lambda *a: None, home=lambda: home, state_dir=lambda: home / "state"), \
                mock.patch.dict(os.environ, {"PATH": f"{bin_dir}{os.pathsep}{distro}"}):
            # Auto-install is off throughout. Each row: what changes and the
            # command run, then its exit, every mise call but `bin-paths`, the
            # keys it reports, the launchers it keeps as the only way in, and
            # each stub afterwards.
            for label, prepare, command, want in (
                    ("main's stubs", main_stubs, "refresh", (0, [ls, use], [], None, "current", "current")),
                    ("the owner's own launcher", lambda: (launcher.write_text("#!/bin/sh\n"), recorded.add("cursor-agent")),
                     "refresh", (1, [ls], ["mise-export-shadow", "mise-launcher-not-ours"], None, "foreign", "current")),
                    ("once the owner follows its advice", recorded.clear,
                     "refresh", (0, [ls], [], None, "foreign", "current")),
                    ("an install with no launcher", lambda: (launcher.unlink(), recorded.add("cursor-agent")),
                     "refresh", (0, [ls, use], [], None, "current", "current")),
                    ("mise refuses the option", lambda: refused.add(use[-1]),
                     "refresh", (1, [ls, use], ["mise-declare-failed"], None, "current", "current")),
                    ("turning auto-install off", refused.clear,
                     "remove-stubs", (0, [ls, use], [], ["cursor-agent"], "current", "absent")),
                    ("with mise unable to say what is installed", lambda: refused.add("ls"),
                     "remove-stubs", (1, [ls], ["mise ERROR nope"], ["cursor-agent"], "current", "absent"))):
                prepare()
                ran.clear()
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    code = mise.cmd_mise([command, "--json"])
                result = json.loads(out.getvalue())
                keys = [line.partition(":")[0] for line in result["error"].splitlines() if not line.startswith(" ")]
                assert_equal((code, ran, keys, result.get("routes"), state(launcher, "cursor"), state(plain, "plain")),
                             want, label)


def test_catalog_entries_cover_the_tools_section():
    """`agent launch` is narrower than the catalog on purpose; install, removal
    and reporting are not. A tools entry missing from the wider list gets no
    settings row and no way to be removed."""
    catalog = mise.dev_tools_catalog()
    ids = [e["id"] for e in mise.manageable(catalog)]
    for tool in catalog["tools"]:
        assert tool["id"] in ids, f"{tool['id']}: manageable() must carry the tools section"
    launch_ids = [e["id"] for e in mise.launchable(catalog)]
    for tool in catalog["tools"]:
        assert tool["id"] not in launch_ids, f"{tool['id']}: a tool has nothing to launch"
    for group, entries in (("tool", catalog["tools"]),):
        stamped = [e["group"] for e in mise.manageable(catalog) if e["id"] in {t["id"] for t in entries}]
        assert_equal(set(stamped), {group}, "manageable() must stamp the group each entry came from")


def test_catalog_is_consistent():
    """One catalog feeds stubs, agents, apps and envs; ids and commands must be unique."""
    catalog = mise.dev_tools_catalog()
    for section in ("agents", "apps", "tools", "envs"):
        assert catalog.get(section), f"catalog section {section} must not be empty"
    launchable = mise.launchable(catalog)
    commands = [e["command"] for e in launchable + catalog["tools"]]
    assert_equal(len(commands), len(set(commands)), "stub commands must be unique: " + " ".join(commands))
    ids = [e["id"] for e in launchable]
    assert_equal(len(ids), len(set(ids)), "agent and app ids must be unique across both")
    assert_equal([e["group"] for e in launchable if e["id"] in ("claude", "herdr")], ["agent", "app"],
                 "launchable() must stamp the group each entry came from")
    for entry in launchable:
        # The stub execs the package's own executable, so the launcher has to
        # name that same file: `orca` is the command, `orca.AppImage` the binary.
        binary = entry.get("bin") or entry["command"]
        assert entry["launch"][0] == binary, f"{entry['id']}: launch must start with {binary}"
    # A tile with no colour falls back to the theme grey, so it reads as
    # unbranded beside the rest and nothing else reports the omission. Read the
    # raw sections, not launchable(): that drops what this machine cannot build,
    # so an entry naming only the other architecture would be judged nowhere.
    for entry in catalog["agents"] + catalog["apps"] + catalog["envs"]:
        assert TILE_ICON.fullmatch(str(entry.get("icon") or "")), \
            f"{entry['id']}: icon must be nerd:<hex> or brand:<hex>, not {entry.get('icon')!r}"
        assert TILE_COLOR.fullmatch(str(entry.get("color") or "")), \
            f"{entry['id']}: color must be #RRGGBB, not {entry.get('color')!r}"
    # A tool reaches no tile, so it carries no icon or colour; it does carry the
    # id and name every settings row and every action is addressed by.
    for entry in catalog["tools"]:
        assert entry.get("id") and entry.get("name"), f"tool {entry.get('command')!r}: needs an id and a name"
    all_ids = [e["id"] for e in launchable + catalog["tools"]]
    assert_equal(len(all_ids), len(set(all_ids)),
                 "ids must be unique across agents, apps and tools: " + " ".join(all_ids))
    for entry in channelled_entries(catalog):
        options = mise.entry_channels(entry)
        assert len(options) > 1, f"{entry['id']}: a channel set with one option is a dropdown with nothing to pick"
        default = str(entry["channels"].get("default") or "")
        assert default in options, f"{entry['id']}: channels.default {default!r} names none of " + " ".join(options)
        assert_equal([c for c, o in options.items() if not o], [default],
                     f"{entry['id']}: the unmodified package is the default stream and only that")
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
    test_a_mise_id_reduces_to_the_tool_name()
    test_update_run_and_count_carry_tools()
    test_os_release_resolves_through_id_like()
    test_first_launch_asks_before_installing()
    test_an_entry_without_this_machines_architecture_is_not_offered()
    test_a_package_is_looked_up_under_the_id_mise_files_it_by()
    test_an_owner_installed_app_launches_its_public_command()
    test_an_interpreter_pin_reaches_the_build_and_no_further()
    test_a_windowed_app_launches_without_a_terminal()
    test_apps_get_stubs_and_their_own_list()
    test_a_channel_picks_the_release_stream_a_tool_installs_from()
    test_a_settings_row_carries_the_streams_it_can_offer()
    test_a_channel_the_catalog_dropped_falls_back_to_the_default()
    test_setting_a_channel_records_it_and_rewrites_the_stub()
    test_the_settings_tab_runs_the_channel_command()
    test_env_remove_keeps_shared_tools()
    test_distro_owned_env_is_hands_off()
    test_mise_installs_reads_declaration_and_active_version()
    test_install_origin_names_what_provides_a_command()
    test_row_actions_run_and_refuse()
    test_the_settings_tab_can_act_on_every_row()
    test_a_row_carries_the_release_it_is_waiting_for()
    test_a_package_kept_off_path_runs_by_absolute_path()
    test_an_exec_stub_runs_the_file_under_the_install_root()
    test_an_install_may_not_export_a_command_the_entry_does_not_own()
    test_every_launcher_is_settled_before_its_option_is_recorded()
    test_catalog_entries_cover_the_tools_section()
    test_catalog_is_consistent()
    test_cli_wrapper_routes_the_commands()
    print("check-dev-tools: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
