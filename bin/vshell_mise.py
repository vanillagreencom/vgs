"""VGS mise stubs: the catalog, lazy launchers in ~/.local/bin, and mise JSON.

Imported by bin/vshell-helper, never run. The helper hands over its runtime
(paths, process helpers, settings access, terminal spawning) through
configure(), so this module stays free of the helper's globals.
"""
from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List, Tuple


@dataclass
class DevToolsRuntime:
    home: Callable[[], Path]
    state_dir: Callable[[], Path]
    repo_root: Callable[[], Path]
    run: Callable[..., subprocess.CompletedProcess[str]]
    command_exists: Callable[[str], bool]
    load_settings: Callable[[], Dict[str, Any]]
    set_settings_value: Callable[[str, Any], Dict[str, Any]]
    load_required_json_file: Callable[[Path], Dict[str, Any]]
    eprint: Callable[..., None]
    spawn_terminal: Callable[..., int]
    notify_user: Callable[[str, str], None]


RT: DevToolsRuntime


def configure(runtime: DevToolsRuntime) -> None:
    global RT
    RT = runtime


# `config/vshell/dev-tools.json` is the single catalog. Harnesses and language
# toolchains are user-level mise installs under ~/.local/share/mise; the
# distribution package manager never sees them. A stub in ~/.local/bin installs
# its tool on first run, so nothing downloads until a tool is used.

MISE_STUB_MARKER = "# vshell mise stub"
MISE_STUBS_REMOVED = "mise-stubs-removed"
# mise withholds releases younger than its cooldown. A harness that ships a
# fix today would otherwise wait days; every mise call VGS makes opts out.
MISE_RELEASE_AGE_ENV = {"MISE_MINIMUM_RELEASE_AGE": "0"}


def dev_tools_catalog() -> Dict[str, Any]:
    return RT.load_required_json_file(RT.repo_root() / "config" / "vshell" / "dev-tools.json")


def mise_env() -> Dict[str, str]:
    env = dict(os.environ)
    env.update(MISE_RELEASE_AGE_ENV)
    return env


def mise_stubs_opted_out() -> bool:
    return (RT.state_dir() / MISE_STUBS_REMOVED).exists()


def mise_stub_text(package: str, command: str, bin_name: str) -> str:
    return (
        "#!/bin/bash\n"
        f"{MISE_STUB_MARKER}\n"
        "export MISE_MINIMUM_RELEASE_AGE=0\n"
        f"mise use -g --quiet {shlex.quote(package)} || exit 1\n"
        f"exec mise x {shlex.quote(package)} -- {shlex.quote(bin_name)} \"$@\"\n"
    )


def command_on_path_elsewhere(command: str, local_bin: Path) -> str:
    """Where `command` resolves on PATH outside ~/.local/bin, or ""."""
    dirs = [d for d in os.environ.get("PATH", "").split(os.pathsep) if d and Path(d) != local_bin]
    found = shutil.which(command, path=os.pathsep.join(dirs))
    return found or ""


def mise_stub_state(path: Path) -> str:
    """absent, ours (written by VGS), foreign (someone else's file at the
    path) or shadowed (absent, but the command is installed elsewhere on
    PATH and ~/.local/bin would hide it)."""
    if not path.exists() and not path.is_symlink():
        return "shadowed" if command_on_path_elsewhere(path.name, path.parent) else "absent"
    try:
        head = path.read_text(errors="replace").splitlines()[:4]
    except OSError:
        return "foreign"
    return "ours" if MISE_STUB_MARKER in head else "foreign"


def mise_install_stub(package: str, command: str, bin_name: str = "") -> Dict[str, Any]:
    """Write ~/.local/bin/<command>. A file VGS did not write is never replaced:
    the owner's own wrapper for the same command wins, and the result says so."""
    bin_name = bin_name or command
    path = RT.home() / ".local" / "bin" / command
    state = mise_stub_state(path)
    result = {"command": command, "package": package, "path": str(path), "state": state}
    if state == "foreign":
        result["error"] = f"{path} exists and was not written by vshell"
        return result
    if state == "shadowed":
        result["error"] = f"{command} is already installed at {command_on_path_elsewhere(command, path.parent)}; a stub in {path.parent} would hide it"
        return result
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{command}.", dir=path.parent)
    tmp = Path(tmp_name)
    with os.fdopen(fd, "w") as handle:
        handle.write(mise_stub_text(package, command, bin_name))
    tmp.chmod(0o755)
    tmp.replace(path)
    result["state"] = "written"
    return result


def mise_catalog_stubs() -> List[Dict[str, str]]:
    catalog = dev_tools_catalog()
    stubs: List[Dict[str, str]] = []
    for entry in list(catalog.get("agents") or []) + list(catalog.get("tools") or []):
        stubs.append({
            "package": str(entry["package"]),
            "command": str(entry["command"]),
            "bin": str(entry.get("bin") or entry["command"]),
        })
    return stubs


def mise_refresh() -> Dict[str, Any]:
    """Rewrite every catalog stub from the current template. Idempotent; a
    machine whose owner removed the stubs stays that way."""
    if mise_stubs_opted_out():
        return {"ok": True, "optedOut": True, "written": [], "foreign": []}
    written: List[str] = []
    foreign: List[str] = []
    shadowed: List[str] = []
    for stub in mise_catalog_stubs():
        result = mise_install_stub(stub["package"], stub["command"], stub["bin"])
        state = result["state"]
        (written if state == "written" else shadowed if state == "shadowed" else foreign).append(stub["command"])
    return {"ok": True, "optedOut": False, "written": written, "foreign": foreign, "shadowed": shadowed}


def mise_remove_stubs() -> Dict[str, Any]:
    removed: List[str] = []
    kept: List[str] = []
    for stub in mise_catalog_stubs():
        path = RT.home() / ".local" / "bin" / stub["command"]
        state = mise_stub_state(path)
        if state == "ours":
            path.unlink(missing_ok=True)
            removed.append(stub["command"])
        elif state == "foreign":
            kept.append(stub["command"])
    marker = RT.state_dir() / MISE_STUBS_REMOVED
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.touch()
    return {"ok": True, "removed": removed, "kept": kept}


def mise_json(args: List[str]) -> Tuple[Dict[str, Any], str]:
    """Run a mise subcommand that prints JSON. (data, error)."""
    if not RT.command_exists("mise"):
        return {}, "mise not found"
    try:
        proc = RT.run(["mise", *args], env=mise_env(), timeout=120)
    except (OSError, subprocess.SubprocessError) as exc:
        return {}, f"mise {args[0]} failed: {exc}"
    if proc.returncode != 0:
        return {}, (proc.stderr or "").strip() or f"mise {args[0]} exited {proc.returncode}"
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        return {}, f"mise {args[0]} printed invalid JSON: {exc}"
    return (data if isinstance(data, dict) else {}), ""


def mise_installed_versions() -> Tuple[Dict[str, str], str]:
    """Package -> installed version, active install preferred."""
    data, error = mise_json(["ls", "--json"])
    versions: Dict[str, str] = {}
    for name, installs in data.items():
        if not isinstance(installs, list):
            continue
        chosen = ""
        for install in installs:
            if not isinstance(install, dict) or not install.get("installed"):
                continue
            chosen = str(install.get("version") or "")
            if install.get("active"):
                break
        if chosen:
            versions[str(name)] = chosen
    return versions, error


def mise_outdated() -> Tuple[List[Dict[str, str]], str]:
    """Tools `mise up` would move: [{name, current, latest}]."""
    data, error = mise_json(["outdated", "--json"])
    rows: List[Dict[str, str]] = []
    for name, info in data.items():
        if not isinstance(info, dict):
            continue
        rows.append({
            "name": str(info.get("name") or name),
            "current": str(info.get("current") or ""),
            "latest": str(info.get("latest") or ""),
        })
    rows.sort(key=lambda row: row["name"])
    return rows, error


def mise_list() -> Dict[str, Any]:
    catalog = dev_tools_catalog()
    versions, versions_error = mise_installed_versions()
    outdated, outdated_error = mise_outdated()
    latest = {row["name"]: row["latest"] for row in outdated}

    def describe(entry: Dict[str, Any]) -> Dict[str, Any]:
        package = str(entry["package"])
        command = str(entry["command"])
        return {
            **{k: entry[k] for k in ("id", "name") if k in entry},
            "package": package,
            "command": command,
            "stub": mise_stub_state(RT.home() / ".local" / "bin" / command),
            "installed": versions.get(package, ""),
            "latest": latest.get(package, ""),
        }

    return {
        "ok": True,
        "mise": RT.command_exists("mise"),
        "optedOut": mise_stubs_opted_out(),
        "error": versions_error or outdated_error,
        "agents": [describe(e) for e in catalog.get("agents") or []],
        "tools": [describe(e) for e in catalog.get("tools") or []],
        "outdated": outdated,
    }


def cmd_mise(argv: List[str]) -> int:
    usage = "Usage: vshell mise install <package> [command [bin]] | refresh [--json] | remove-stubs [--json] | opt-in [--json] | list --json | outdated --json | up"
    if not argv:
        RT.eprint(usage)
        return 2
    sub, rest = argv[0], argv[1:]
    want_json = "--json" in rest
    if sub == "install":
        args = [a for a in rest if not a.startswith("--")]
        if not args or len(args) > 3:
            RT.eprint(usage)
            return 2
        result = mise_install_stub(args[0], args[1] if len(args) > 1 else args[0], args[2] if len(args) > 2 else "")
        print(json.dumps(result) if want_json else (result.get("error") or f"wrote {result['path']}"))
        return 1 if result.get("error") else 0
    if sub == "refresh":
        result = mise_refresh()
        if want_json:
            print(json.dumps(result))
        elif result["optedOut"]:
            print(f"mise stubs are opted out; delete {RT.state_dir() / MISE_STUBS_REMOVED} to opt back in")
        else:
            print(f"wrote {len(result['written'])} stubs"
                  + (", kept foreign: " + " ".join(result["foreign"]) if result["foreign"] else "")
                  + (", already installed elsewhere: " + " ".join(result["shadowed"]) if result["shadowed"] else ""))
        return 0
    if sub == "opt-in":
        marker = RT.state_dir() / MISE_STUBS_REMOVED
        if marker.exists():
            marker.unlink()
        result = mise_refresh()
        print(json.dumps(result) if want_json else f"wrote {len(result['written'])} stubs")
        return 0
    if sub == "remove-stubs":
        result = mise_remove_stubs()
        print(json.dumps(result) if want_json else f"removed {len(result['removed'])} stubs" + (", kept foreign: " + " ".join(result["kept"]) if result["kept"] else ""))
        return 0
    if sub == "list":
        print(json.dumps(mise_list(), indent=2 if not want_json else None))
        return 0
    if sub == "outdated":
        rows, error = mise_outdated()
        if want_json:
            print(json.dumps({"ok": not error, "error": error, "tools": rows}))
        else:
            for row in rows:
                print(f"{row['name']}  {row['current']} -> {row['latest']}")
            if error:
                RT.eprint(error)
        return 1 if error else 0
    if sub == "up":
        if not RT.command_exists("mise"):
            RT.eprint("mise not found")
            return 1
        os.execvpe("mise", ["mise", "up", *rest], mise_env())
    RT.eprint(usage)
    return 2
