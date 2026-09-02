"""VGS coding agents and language environments, on top of vshell_mise.

Imported by bin/vshell-helper, never run. configure() forwards the runtime to
vshell_mise so one call wires both.
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import Any, Dict, List

import vshell_mise
from vshell_mise import DevToolsRuntime, dev_tools_catalog, mise_stubs_opted_out, mise_env, mise_install_stub, mise_installed_versions, mise_stub_state

RT: DevToolsRuntime


def configure(runtime: DevToolsRuntime) -> None:
    global RT
    RT = runtime
    vshell_mise.configure(runtime)


def runtime() -> DevToolsRuntime:
    return RT


def agent_entries() -> List[Dict[str, Any]]:
    return [dict(e) for e in dev_tools_catalog().get("agents") or []]


def agent_list() -> Dict[str, Any]:
    versions, versions_error = mise_installed_versions()
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
            # A foreign or shadowed command is the owner's own install of the
            # same agent; it launches without mise.
            "runnable": bool(versions.get(str(entry["package"]))) or stub in {"foreign", "shadowed"},
        })
    return {"ok": True, "mise": RT.command_exists("mise"), "error": versions_error,
            "optedOut": mise_stubs_opted_out(), "agents": agents}


def agent_installed(entry: Dict[str, Any]) -> bool:
    """A mise install of the package, or the owner's own command on PATH."""
    versions, _ = mise_installed_versions()
    if versions.get(str(entry["package"])):
        return True
    return mise_stub_state(RT.home() / ".local" / "bin" / str(entry["command"])) in {"foreign", "shadowed"}


def agent_launch_argv(entry: Dict[str, Any]) -> List[str]:
    """The agent's launch argv, run through `mise x` when mise owns it so it
    resolves without a stub or shim on PATH; the owner's own command otherwise."""
    launch = [str(part) for part in entry.get("launch") or [entry["command"]]]
    versions, _ = mise_installed_versions()
    if versions.get(str(entry["package"])):
        return ["mise", "x", str(entry["package"]), "--", *launch]
    return launch


def agent_install_prompt(entry: Dict[str, Any]) -> bool:
    """Ask in the terminal before the first download; True when installed."""
    if not RT.command_exists("mise"):
        print(f"{entry['name']} installs through mise, which is not installed. Install the mise package and retry.")
        return False
    try:
        answer = input(f"{entry['name']} is not installed. Install it with mise now? [Y/n] ").strip().lower()
    except EOFError:
        answer = "n"
    if answer not in ("", "y", "yes"):
        return False
    command = str(entry["command"])
    mise_install_stub(str(entry["package"]), command, str(entry.get("bin") or command))
    return subprocess.run(["mise", "use", "-g", str(entry["package"])], check=False, env=mise_env(), cwd=str(RT.home())).returncode == 0


def agent_launch(agent_id: str, inline: bool, hold: bool = False) -> int:
    entry = next((e for e in agent_entries() if e["id"] == agent_id), None)
    if entry is None:
        RT.eprint(f"unknown agent {agent_id!r}; one of: " + " ".join(e["id"] for e in agent_entries()))
        return 1
    # Agents refuse to remember trust for $HOME; a work directory keeps the
    # first launch from re-asking every session.
    work = RT.home() / "Work"
    cwd = work if work.is_dir() else RT.home()
    os.chdir(cwd)
    if not inline:
        cli = str(RT.repo_root() / "bin" / "vshell")
        if not agent_installed(entry):
            # The first-run question and download are a one-shot script, so
            # they get the updater's floating TUI window; the agent session
            # that follows gets its own regular window.
            if RT.spawn_terminal([cli, "agent", "install", agent_id], app_id=RT.tui_app_id, wait=True, notify=True, what=f"installing {entry['name']}") != 0:
                return 1
        return RT.spawn_terminal([cli, "agent", "launch", agent_id, "--inline", "--hold"], app_id="vshell-agent", detach=True, notify=True, what=f"{entry['name']}")
    if not agent_installed(entry) and not agent_install_prompt(entry):
        return hold_terminal(1, f"{entry['name']} was not installed.") if hold else 1
    launch = agent_launch_argv(entry)
    env = mise_env()
    if not hold:
        os.execvpe(launch[0], launch, env)
    # The agent replaces this process so it owns the terminal and its
    # signals; the shell around it keeps the window open only on a non-zero
    # exit, which is otherwise a message the owner never sees.
    script = '"$@"; code=$?; if [ "$code" -ne 0 ]; then printf "\\n%s exited with status %s.\\nPress Enter to close. " "$0" "$code"; read -r _; fi; exit "$code"'
    os.execvpe("sh", ["sh", "-c", script, entry["name"], *launch], env)


def hold_terminal(code: int, message: str) -> int:
    """Keep a one-shot terminal readable after a failure."""
    print(f"\n{message}")
    try:
        input("Press Enter to close. ")
    except EOFError:
        pass
    return code


def cmd_agent(argv: List[str]) -> int:
    usage = "Usage: vshell agent list [--json] | launch <id> [--inline] | install <id> | pick"
    if not argv:
        RT.eprint(usage)
        return 2
    sub, rest = argv[0], argv[1:]
    if sub == "list":
        data = agent_list()
        if "--json" in rest:
            print(json.dumps(data))
        else:
            for agent in data["agents"]:
                print(f"{agent['id']:<10} {agent['name']:<18} {agent['installed'] or ('yours' if agent['stub'] in {'foreign', 'shadowed'} else '-')}")
        return 0
    if sub == "pick":
        # The launcher's Dev tools section lists every agent; a keybind lands here.
        cli = str(RT.repo_root() / "bin" / "vshell")
        proc = RT.run([cli, "ipc", "call", "vshell-menu", "openCategory", "dev"], timeout=5)
        return 0 if proc.returncode == 0 else 1
    if sub == "install":
        entry = next((e for e in agent_entries() if e["id"] == (rest[0] if rest else "")), None)
        if entry is None:
            RT.eprint(usage)
            return 2
        if agent_installed(entry):
            return 0
        return 0 if agent_install_prompt(entry) else hold_terminal(1, f"{entry['name']} was not installed.")
    if sub == "launch":
        ids = [a for a in rest if not a.startswith("--")]
        if len(ids) != 1:
            RT.eprint(usage)
            return 2
        return agent_launch(ids[0], inline="--inline" in rest, hold="--hold" in rest)
    RT.eprint(usage)
    return 2


def dev_env_entries() -> List[Dict[str, Any]]:
    return [dict(e) for e in dev_tools_catalog().get("envs") or []]


def dev_env_present(entry: Dict[str, Any]) -> bool:
    present = str(entry.get("present") or "")
    return bool(present) and Path(os.path.expanduser(present)).exists()


def dev_env_distro_owned(entry: Dict[str, Any]) -> str:
    """Path of the distribution's copy of `managedBy`, or "" when VGS may
    install and remove this environment itself."""
    command = str(entry.get("managedBy") or "")
    if not command:
        return ""
    found = shutil.which(command) or ""
    return found if found.startswith(("/usr/bin/", "/usr/local/bin/", "/bin/")) else ""


def dev_env_list() -> Dict[str, Any]:
    envs = []
    for e in dev_env_entries():
        owner = dev_env_distro_owned(e)
        envs.append({"id": e["id"], "name": e["name"], "installed": dev_env_present(e) or bool(owner), "distroPath": owner})
    return {"ok": True, "mise": RT.command_exists("mise"), "envs": envs}


def os_release_ids(path: Path = Path("/etc/os-release")) -> List[str]:
    """ID followed by each ID_LIKE token, so cachyos resolves to arch and
    ubuntu to debian. Empty when the file is unreadable."""
    values: Dict[str, str] = {}
    try:
        for line in path.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key.strip()] = value.strip().strip('"')
    except OSError:
        return []
    ids = [values.get("ID", "")] + values.get("ID_LIKE", "").split()
    return [i for i in ids if i]


PACKAGE_INSTALLERS = {
    "arch": ["sudo", "pacman", "-S", "--needed"],
    "debian": ["sudo", "apt-get", "install"],
    "fedora": ["sudo", "dnf", "install"],
}


def dev_env_install_packages(packages: Dict[str, List[str]]) -> int:
    """Install the catalog's distribution packages for this host, interactively.
    A host no catalog key matches fails loudly rather than letting the mise
    build fail later with the wrong name on it."""
    if not packages:
        return 0
    ids = os_release_ids()
    for distro in ids:
        names = [str(p) for p in packages.get(distro) or []]
        argv = PACKAGE_INSTALLERS.get(distro)
        if names and argv:
            print(f":: Installing {' '.join(names)}")
            return subprocess.run([*argv, *names], check=False).returncode
    wanted = "; ".join(f"{k}: {' '.join(v)}" for k, v in packages.items())
    RT.eprint(f"no package list for this distribution ({' '.join(ids) or 'unreadable /etc/os-release'}); "
              f"install the equivalent of one of these first, then retry: {wanted}")
    return 1


def dev_env_run(argv: List[str]) -> int:
    print(":: " + " ".join(shlex.quote(a) for a in argv))
    return subprocess.run(argv, check=False, env=mise_env()).returncode


def dev_env_install(entry: Dict[str, Any]) -> int:
    owner = dev_env_distro_owned(entry)
    if owner:
        RT.eprint(f"{entry['name']} is managed by your package manager ({owner}); nothing to install")
        return 1
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
    owner = dev_env_distro_owned(entry)
    if owner:
        RT.eprint(f"{entry['name']} is managed by your package manager ({owner}); remove it there")
        return 1
    print(f"Removing {entry['name']}...\n")
    if entry.get("installer") == "rustup":
        return dev_env_run(["rustup", "self", "uninstall", "-y"])
    if not RT.command_exists("mise"):
        RT.eprint("mise not found")
        return 1
    shared = {str(t) for other in dev_env_entries() if other["id"] != entry["id"] for t in other.get("tools") or []}
    failures = 0
    for tool in entry.get("tools") or []:
        if str(tool) in shared:
            print(f":: keeping {tool}: another environment lists it")
            continue
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
