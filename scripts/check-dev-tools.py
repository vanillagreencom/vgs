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
    assert_equal(stubs["orca-ide"]["bin"], "orca.AppImage",
                 "the stub execs the package's own executable, not the command name")
    assert "orca" not in stubs, "the command must not claim the screen reader's name"
    assert "gh" in stubs, "tools keep their stubs"
    # A package carrying mise backend options holds brackets, a backslash and a
    # `$`. Unquoted, the shell would glob the brackets and eat the rest, and the
    # stub would install some other tool or nothing at all.
    bracketed = mise.mise_stub_text(stubs["cmux"]["package"], "cmux", "cmux")
    assert "'" + stubs["cmux"]["package"] + "'" in bracketed, bracketed
    assert "[matching_regex=" in stubs["cmux"]["package"], "cmux names the asset its platform matcher cannot pick"

    original_versions = devtools.mise_installed_versions
    original_state = devtools.mise_stub_state
    devtools.mise_installed_versions = lambda: ({}, "")
    devtools.mise_stub_state = lambda path: "absent"
    mise.platform.machine = lambda: "x86_64"
    try:
        listed = devtools.agent_list()
        catalog = mise.dev_tools_catalog()
        expected_agents = [e["id"] for e in catalog["agents"] if mise.buildable_here(e)]
        expected_apps = [e["id"] for e in catalog["apps"] if mise.buildable_here(e)]
    finally:
        devtools.mise_installed_versions = original_versions
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
                    assert "'" + row["package"] + "'" in mise.mise_stub_text(stub["package"], stub["command"], stub["bin"]), \
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
    original_versions = devtools.mise_installed_versions
    original_state = devtools.mise_stub_state
    original_settings = mise.RT.load_settings
    original_machine = mise.platform.machine
    devtools.mise_installed_versions = lambda: ({}, "")
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
        devtools.mise_installed_versions = original_versions
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
    assert "root.setChannel(agentRow.modelData.id," in tab, \
        "the pick must run the channel command for the row it came from"
    assert "options: agentRow.modelData.channels" in tab, "the dropdown lists the row's own streams"
    assert "currentValue: agentRow.modelData.channel" in tab, "and shows the one in force"
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
    test_catalog_is_consistent()
    test_cli_wrapper_routes_the_commands()
    print("check-dev-tools: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
