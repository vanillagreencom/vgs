"""VGS coding agents and language environments, on top of vshell_mise.

Imported by bin/vshell-helper, never run. configure() forwards the runtime to
vshell_mise so one call wires both.
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
from pathlib import Path
from typing import Any, Dict, List

import vshell_mise
from vshell_mise import DevToolsRuntime, dev_tools_catalog, mise_env, mise_install_stub, mise_installed_versions, mise_stub_state

RT: DevToolsRuntime


def configure(runtime: DevToolsRuntime) -> None:
    global RT
    RT = runtime
    vshell_mise.configure(runtime)


def agent_entries() -> List[Dict[str, Any]]:
    return [dict(e) for e in dev_tools_catalog().get("agents") or []]


def agent_default_id() -> str:
    return str(RT.load_settings().get("defaultCodingAgent") or "").strip()


def agent_list() -> Dict[str, Any]:
    versions, _ = mise_installed_versions()
    default = agent_default_id()
    agents = []
    for entry in agent_entries():
        command = str(entry["command"])
        stub = mise_stub_state(RT.home() / ".local" / "bin" / command)
        agents.append({
            "id": entry["id"],
            "name": entry["name"],
            "command": command,
            "package": entry["package"],
            "stub": stub,
            "installed": versions.get(str(entry["package"]), ""),
            # A foreign command is the owner's own install of the same agent;
            # it launches without mise.
            "runnable": bool(versions.get(str(entry["package"]))) or stub == "foreign" or (stub == "absent" and RT.command_exists(command)),
            "default": entry["id"] == default,
        })
    return {"ok": True, "default": default, "mise": RT.command_exists("mise"), "agents": agents}


def agent_launch(pick: bool, inline: bool) -> int:
    agent_id = agent_default_id()
    entries = {e["id"]: e for e in agent_entries()}
    entry = entries.get(agent_id)
    if entry is None:
        if pick or not agent_id:
            cli = str(RT.repo_root() / "bin" / "vshell")
            RT.run([cli, "ipc", "call", "settings", "openWith", "developer"], timeout=5)
            if agent_id:
                RT.eprint(f"default coding agent {agent_id!r} is not in the catalog")
            return 0 if not agent_id else 1
        RT.eprint(f"default coding agent {agent_id!r} is not in the catalog")
        return 1
    command = str(entry["command"])
    stub_path = RT.home() / ".local" / "bin" / command
    if mise_stub_state(stub_path) == "absent" and not RT.command_exists(command):
        if not RT.command_exists("mise"):
            RT.notify_user("mise is not installed", f"{entry['name']} installs through mise; install mise and retry.")
            return 1
        mise_install_stub(str(entry["package"]), command, str(entry.get("bin") or command))
    launch = [str(part) for part in entry.get("launch") or [command]]
    # Agents refuse to remember trust for $HOME; a work directory keeps the
    # first launch from re-asking every session.
    work = RT.home() / "Work"
    cwd = work if work.is_dir() else RT.home()
    if inline:
        os.chdir(cwd)
        os.execvp(launch[0], launch)
    os.chdir(cwd)
    return RT.spawn_terminal(launch, app_id="vshell-agent", detach=True, notify=True, what=f"{entry['name']}")


def cmd_agent(argv: List[str]) -> int:
    usage = "Usage: vshell agent list [--json] | default [<id>|--clear] [--json] | launch [--pick] [--inline]"
    if not argv:
        RT.eprint(usage)
        return 2
    sub, rest = argv[0], argv[1:]
    want_json = "--json" in rest
    if sub == "list":
        data = agent_list()
        if want_json:
            print(json.dumps(data))
        else:
            for agent in data["agents"]:
                mark = "*" if agent["default"] else " "
                print(f"{mark} {agent['id']:<10} {agent['name']:<18} {agent['installed'] or ('foreign' if agent['stub'] == 'foreign' else '-')}")
        return 0
    if sub == "default":
        args = [a for a in rest if a != "--json"]
        if not args:
            current = agent_default_id()
            print(json.dumps({"default": current}) if want_json else current)
            return 0
        if args[0] == "--clear":
            RT.set_settings_value("defaultCodingAgent", "")
            print(json.dumps({"default": ""}) if want_json else "cleared")
            return 0
        ids = {e["id"] for e in agent_entries()}
        if args[0] not in ids:
            RT.eprint(f"unknown agent {args[0]!r}; one of: " + " ".join(sorted(ids)))
            return 1
        RT.set_settings_value("defaultCodingAgent", args[0])
        print(json.dumps({"default": args[0]}) if want_json else args[0])
        return 0
    if sub == "launch":
        return agent_launch(pick="--pick" in rest, inline="--inline" in rest)
    RT.eprint(usage)
    return 2


def dev_env_entries() -> List[Dict[str, Any]]:
    return [dict(e) for e in dev_tools_catalog().get("envs") or []]


def dev_env_present(entry: Dict[str, Any]) -> bool:
    present = str(entry.get("present") or "")
    return bool(present) and Path(os.path.expanduser(present)).exists()


def dev_env_list() -> Dict[str, Any]:
    return {
        "ok": True,
        "mise": RT.command_exists("mise"),
        "envs": [{"id": e["id"], "name": e["name"], "installed": dev_env_present(e)} for e in dev_env_entries()],
    }


def os_release_id() -> str:
    try:
        for line in Path("/etc/os-release").read_text().splitlines():
            if line.startswith("ID="):
                return line[3:].strip().strip('"')
    except OSError:
        pass
    return ""


def dev_env_install_packages(packages: Dict[str, List[str]]) -> int:
    distro = os_release_id()
    names = [str(p) for p in packages.get(distro) or []]
    if not names:
        return 0
    installers = {
        "arch": ["sudo", "pacman", "-S", "--needed", "--noconfirm"],
        "debian": ["sudo", "apt-get", "install", "-y"],
        "ubuntu": ["sudo", "apt-get", "install", "-y"],
        "fedora": ["sudo", "dnf", "install", "-y"],
    }
    argv = installers.get(distro)
    if argv is None:
        RT.eprint(f"install these packages first: {' '.join(names)}")
        return 1
    print(f":: Installing {' '.join(names)}")
    return subprocess.run([*argv, *names], check=False).returncode


def dev_env_run(argv: List[str]) -> int:
    print(":: " + " ".join(shlex.quote(a) for a in argv))
    return subprocess.run(argv, check=False, env=mise_env()).returncode


def dev_env_install(entry: Dict[str, Any]) -> int:
    print(f"Installing {entry['name']}...\n")
    if entry.get("installer") == "rustup":
        return dev_env_run(["sh", "-c", "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"])
    if not RT.command_exists("mise"):
        RT.eprint("mise not found")
        return 1
    if dev_env_install_packages(entry.get("packages") or {}) != 0:
        return 1
    for key, value in (entry.get("settings") or {}).items():
        values = value if isinstance(value, list) else [value]
        verb = "add" if isinstance(value, list) else "set"
        for item in values:
            if dev_env_run(["mise", "settings", verb, str(key), str(item)]) != 0:
                return 1
    for tool in entry.get("tools") or []:
        if dev_env_run(["mise", "use", "-g", f"{tool}@latest"]) != 0:
            return 1
    for post in entry.get("post") or []:
        if dev_env_run([str(p) for p in post]) != 0:
            return 1
    print(f"\n{entry['name']} installed.")
    return 0


def dev_env_remove(entry: Dict[str, Any]) -> int:
    print(f"Removing {entry['name']}...\n")
    if entry.get("installer") == "rustup":
        return dev_env_run(["rustup", "self", "uninstall", "-y"])
    if not RT.command_exists("mise"):
        RT.eprint("mise not found")
        return 1
    failures = 0
    for tool in entry.get("tools") or []:
        failures += dev_env_run(["mise", "uninstall", "--all", str(tool)]) != 0
        failures += dev_env_run(["mise", "unuse", "-g", str(tool)]) != 0
    return 1 if failures else 0


def cmd_dev_env(argv: List[str]) -> int:
    usage = "Usage: vshell dev-env list [--json] | install <id> | remove <id>"
    if not argv:
        RT.eprint(usage)
        return 2
    sub, rest = argv[0], argv[1:]
    if sub == "list":
        data = dev_env_list()
        if "--json" in rest:
            print(json.dumps(data))
        else:
            for env in data["envs"]:
                print(f"{'*' if env['installed'] else ' '} {env['id']:<10} {env['name']}")
        return 0
    if sub in {"install", "remove"}:
        if len(rest) != 1:
            RT.eprint(usage)
            return 2
        entry = next((e for e in dev_env_entries() if e["id"] == rest[0]), None)
        if entry is None:
            RT.eprint(f"unknown environment {rest[0]!r}; one of: " + " ".join(e["id"] for e in dev_env_entries()))
            return 1
        return dev_env_install(entry) if sub == "install" else dev_env_remove(entry)
    RT.eprint(usage)
    return 2
