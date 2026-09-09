"""VGS mise stubs: the catalog, lazy launchers in ~/.local/bin, and mise JSON.

Imported by bin/vshell-helper, never run. The helper hands over its runtime
(paths, process helpers, settings access, terminal spawning) through
configure(), so this module stays free of the helper's globals.
"""
from __future__ import annotations

import json
import os
import platform
import re
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
    spawn_app: Callable[..., int]
    notify_user: Callable[[str, str], None]
    # App id of the floating TUI window the updater uses; one-shot scripts
    # (installs, prompts) share its styling.
    tui_app_id: str


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
# Disable mise release cooldown so tool requests can use newly published releases.
MISE_RELEASE_AGE_ENV = {"MISE_MINIMUM_RELEASE_AGE": "0"}


PACKAGE_OPTIONS = re.compile(r"\[[^\]]*\]")

# Settings key holding the release stream chosen per catalog entry: entry id ->
# channel id. Absent or unknown means the entry's own default.
DEV_TOOL_CHANNELS_SETTING = "devToolChannels"


def version_cut(spec: str) -> int:
    """Where a mise spec's requested version begins, or its length when it names
    none. `npm:@scope/name` carries an `@` that belongs to the name; only one
    after the last `/` separates a version."""
    at = spec.rfind("@")
    return at if at > spec.rfind("/") else len(spec)


def package_key(package: str) -> str:
    """The id mise files a package under. `mise ls --json` and the global config
    both drop inline backend options and the requested version, so a spec
    carrying either matches nothing when it is looked up verbatim: the tool
    reads as never installed, is offered for install on every launch, and
    cannot be removed."""
    stripped = PACKAGE_OPTIONS.sub("", package)
    return stripped[:version_cut(stripped)]


def tool_name(package_id: str) -> str:
    """The tool's own name inside a mise id. mise files a package under its
    backend and owner (`npm:@deepseek-ai/dsh`, `aqua:google-antigravity/
    antigravity-cli`) for every backend but the default registry, which files it
    bare (`claude`). An update list showing both spellings puts a prefix on some
    rows and not others, for no difference the reader can act on."""
    name = package_id
    if "/" in name:
        name = name.rsplit("/", 1)[1]
    elif ":" in name:
        name = name.split(":", 1)[1]
    # A backend and owner with nothing after them is not a name; the id itself
    # is the only thing left to show.
    return name or package_id


def package_with_options(package: str, options: str) -> str:
    """`package` with `options` added to its mise backend option list, keeping
    any options it already carries and staying ahead of a requested version:
    mise reads `name[opts]@version` and nothing else."""
    if not options:
        return package
    bracket = PACKAGE_OPTIONS.search(package)
    if bracket:
        return package[:bracket.end() - 1] + "," + options + package[bracket.end() - 1:]
    cut = version_cut(package)
    return package[:cut] + "[" + options + "]" + package[cut:]


def entry_channels(entry: Dict[str, Any]) -> Dict[str, str]:
    """Channel id -> the backend options that select that release stream, in the
    order the catalog lists them. An entry publishing one stream returns none,
    and nothing downstream offers a choice."""
    options = (entry.get("channels") or {}).get("options")
    return {str(k): str(v) for k, v in options.items()} if isinstance(options, dict) else {}


def entry_channel(entry: Dict[str, Any], chosen: Dict[str, str]) -> str:
    """The channel one entry installs from: the owner's pick while the catalog
    still offers it, the entry's default otherwise. A pick the catalog has since
    dropped must not install from a stream that no longer exists."""
    channels = entry_channels(entry)
    if not channels:
        return ""
    pick = chosen.get(str(entry.get("id") or ""), "")
    if pick in channels:
        return pick
    default = str((entry.get("channels") or {}).get("default") or "")
    if default not in channels:
        raise ValueError(f"{entry.get('id')}: channels.default {default!r} names none of "
                         + " ".join(sorted(channels)))
    return default


def entry_package(entry: Dict[str, Any], chosen: Dict[str, str]) -> str:
    """The mise spec that installs one entry from the channel in force."""
    return package_with_options(str(entry["package"]),
                                entry_channels(entry).get(entry_channel(entry, chosen), ""))


def dev_tool_channels() -> Dict[str, str]:
    """The owner's channel picks, entry id -> channel id."""
    chosen = RT.load_settings().get(DEV_TOOL_CHANNELS_SETTING)
    return {str(k): str(v) for k, v in chosen.items()} if isinstance(chosen, dict) else {}


def dev_tools_catalog() -> Dict[str, Any]:
    return RT.load_required_json_file(RT.repo_root() / "config" / "vshell" / "dev-tools.json")


def mise_env() -> Dict[str, str]:
    env = dict(os.environ)
    env.update(MISE_RELEASE_AGE_ENV)
    return env


def mise_stubs_opted_out() -> bool:
    return (RT.state_dir() / MISE_STUBS_REMOVED).exists()


def mise_install_steps(package: str, requires: List[str], present: str,
                       quiet: bool = True) -> List[List[str]]:
    """The mise calls that install one entry, in order. `requires` are packages
    the backend itself needs before it can build this one. A tool with a
    `present` path is re-forced rather than merely used: `mise use` accepts an
    install that is already there, and `mise up` rebuilds one without the
    environment it was pinned with. The stub installs quietly behind a command
    the owner asked for; the first-launch prompt does not, because the owner is
    watching a download that can take minutes."""
    flags = ["--quiet"] if quiet else []
    steps = [["mise", "use", "-g", *flags, req] for req in requires]
    force = ["--force"] if present else []
    return steps + [["mise", "use", "-g", *flags, *force, package]]


def mise_build_env(build_env: Dict[str, str]) -> Dict[str, str]:
    """The environment an install needs, on top of the release-age opt-out."""
    return {**MISE_RELEASE_AGE_ENV, **{k: str(v) for k, v in build_env.items()}}


def mise_stub_text(package: str, command: str, bin_name: str,
                   build_env: Dict[str, str] | None = None,
                   requires: List[str] | None = None,
                   present: str = "") -> str:
    """The lazy launcher for one tool.

    `build_env` holds variables the install needs and the tool must not inherit:
    a pin like `UV_PYTHON` reaches every command the tool later shells out to,
    where it would resolve the wrong interpreter for the user's own project, so
    the exec drops it again. `requires` are mise packages the backend itself
    needs before it can build this one. `present` is a path under the install
    that proves the build honoured the environment: `mise use` alone accepts an
    install that is already there, and `mise up` rebuilds without the pin, so a
    tool that needs one is re-forced when that path is gone."""
    build_env = build_env or {}
    requires = requires or []
    lines = ["#!/bin/bash", MISE_STUB_MARKER]
    lines += [f"export {name}={shlex.quote(value)}"
              for name, value in sorted(mise_build_env(build_env).items())]
    install = [" ".join(shlex.quote(part) for part in step) + " || exit 1"
               for step in mise_install_steps(package, requires, present)]
    if present:
        probe = f'"$(mise where {shlex.quote(package)} 2>/dev/null)"/{present}'
        lines.append(f"if ! [ -e {probe} ]; then")
        lines += [f"  {line}" for line in install]
        lines.append("fi")
    else:
        lines += install
    drop = "".join(f" -u {shlex.quote(name)}" for name in sorted(build_env))
    prefix = f"env{drop} " if drop else ""
    lines.append(f"exec {prefix}mise x {shlex.quote(package)} -- {shlex.quote(bin_name)} \"$@\"")
    return "\n".join(lines) + "\n"


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


def mise_install_stub(package: str, command: str, bin_name: str = "",
                      build_env: Dict[str, str] | None = None,
                      requires: List[str] | None = None,
                      present: str = "") -> Dict[str, Any]:
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
        handle.write(mise_stub_text(package, command, bin_name, build_env, requires, present))
    tmp.chmod(0o755)
    tmp.replace(path)
    result["state"] = "written"
    return result


def buildable_here(entry: Dict[str, Any]) -> bool:
    """Whether this machine's architecture is one the entry publishes for. An
    entry naming none builds everywhere. VGS ships aarch64, and an entry with
    only x86_64 assets would otherwise offer an install with no asset to
    choose."""
    arch = entry.get("arch")
    return not arch or platform.machine() in arch


def launchable(catalog: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Catalog entries with a launcher: coding agents and developer apps. One
    list so install, launch and removal have a single implementation; the
    `group` it stamps is what tells an Agent from an App wherever they show
    apart.

    Each entry leaves here resolved for this machine: `package` is the spec the
    channel in force installs, `channel` names that channel and `channels` the
    ids on offer, replacing the catalog's own object. Resolving once here is
    what keeps a stub, a launch and a removal from disagreeing about which
    release stream a tool came from."""
    chosen = dev_tool_channels()
    return [dict(entry,
                 group=group[:-1],
                 package=entry_package(entry, chosen),
                 channel=entry_channel(entry, chosen),
                 channels=list(entry_channels(entry)))
            for group in ("agents", "apps")
            for entry in catalog.get(group) or []
            if buildable_here(entry)]


def mise_catalog_stubs() -> List[Dict[str, str]]:
    catalog = dev_tools_catalog()
    stubs: List[Dict[str, str]] = []
    for entry in launchable(catalog) + [e for e in catalog.get("tools") or [] if buildable_here(e)]:
        stubs.append({
            "package": str(entry["package"]),
            "command": str(entry["command"]),
            "bin": str(entry.get("bin") or entry["command"]),
            "buildEnv": dict(entry.get("buildEnv") or {}),
            "requires": [str(r) for r in entry.get("requires") or []],
            "present": str(entry.get("present") or ""),
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
        result = mise_install_stub(stub["package"], stub["command"], stub["bin"],
                                   stub["buildEnv"], stub["requires"], stub["present"])
        state = result["state"]
        (written if state == "written" else shadowed if state == "shadowed" else foreign).append(stub["command"])
    return {"ok": True, "optedOut": False, "written": written, "foreign": foreign, "shadowed": shadowed,
            "retired": mise_retire_stubs()}


def mise_retire_stubs() -> List[str]:
    """Delete stubs VGS wrote for commands the catalog no longer lists, so a
    tool dropped from the catalog stops launching after the next refresh.
    Only files carrying the marker go; the owner's own files stay."""
    current = {stub["command"] for stub in mise_catalog_stubs()}
    bin_dir = RT.home() / ".local" / "bin"
    retired: List[str] = []
    if not bin_dir.is_dir():
        return retired
    for path in sorted(bin_dir.iterdir()):
        if path.name in current or not path.is_file() or path.is_symlink():
            continue
        if mise_stub_state(path) == "ours":
            path.unlink(missing_ok=True)
            retired.append(path.name)
    return retired


def mise_set_channel(entry_id: str, channel: str) -> Dict[str, Any]:
    """Record which release stream one entry installs from, then rewrite the
    stubs. A stub carries the package spec its channel selects, so recording the
    setting alone would leave the next launch installing from the old stream."""
    entries = launchable(dev_tools_catalog())
    entry = next((e for e in entries if e.get("id") == entry_id), None)
    if entry is None:
        return {"ok": False,
                "error": f"unknown dev tool {entry_id!r}; one of: " + " ".join(str(e["id"]) for e in entries)}
    offered = [str(c) for c in entry["channels"]]
    if not offered:
        return {"ok": False, "error": f"{entry_id} publishes one release stream; there is no channel to choose"}
    if channel not in offered:
        return {"ok": False, "error": f"{entry_id} has no channel {channel!r}; one of: " + " ".join(offered)}
    RT.set_settings_value(DEV_TOOL_CHANNELS_SETTING, {**dev_tool_channels(), entry_id: channel})
    refresh = mise_refresh()
    # Re-read rather than predict: the stub just written is what the next launch
    # runs, and it was built from the setting this call has now changed.
    updated = next(e for e in launchable(dev_tools_catalog()) if e.get("id") == entry_id)
    return {"ok": True, "id": entry_id, "channel": str(updated["channel"]),
            "package": str(updated["package"]), "optedOut": bool(refresh["optedOut"])}


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
    # From $HOME, so only the global config is in scope: mise's bare
    # commands otherwise fold in whatever .mise.toml the caller's cwd has.
    try:
        proc = RT.run(["mise", *args], env=mise_env(), cwd=str(RT.home()), timeout=120)
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
    """Tools `mise up` would move: [{name, id, current, latest}], `name` the
    tool as the reader knows it and `id` the spec mise files it under."""
    data, error = mise_json(["outdated", "--json"])
    rows: List[Dict[str, str]] = []
    for name, info in data.items():
        if not isinstance(info, dict):
            continue
        rows.append({
            "name": tool_name(str(info.get("name") or name)),
            "id": str(name),
            "current": str(info.get("current") or ""),
            "latest": str(info.get("latest") or ""),
        })
    # The reader sees tool names, so the list is ordered by them; the mise id
    # breaks a tie, since two backends can publish the same tool name.
    rows.sort(key=lambda row: (row["name"], row["id"]))
    return rows, error


def mise_list() -> Dict[str, Any]:
    catalog = dev_tools_catalog()
    versions, versions_error = mise_installed_versions()
    outdated, outdated_error = mise_outdated()
    latest = {row["name"]: row["latest"] for row in outdated}

    entries = launchable(catalog)

    def describe(entry: Dict[str, Any]) -> Dict[str, Any]:
        package = str(entry["package"])
        command = str(entry["command"])
        return {
            **{k: entry[k] for k in ("id", "name") if k in entry},
            "package": package,
            "command": command,
            "stub": mise_stub_state(RT.home() / ".local" / "bin" / command),
            "installed": versions.get(package_key(package), ""),
            "latest": latest.get(package_key(package), ""),
        }

    return {
        "ok": True,
        "mise": RT.command_exists("mise"),
        "optedOut": mise_stubs_opted_out(),
        "error": versions_error or outdated_error,
        "agents": [describe(e) for e in entries if e["group"] == "agent"],
        "apps": [describe(e) for e in entries if e["group"] == "app"],
        "tools": [describe(e) for e in catalog.get("tools") or [] if buildable_here(e)],
        "outdated": outdated,
    }


def cmd_mise(argv: List[str]) -> int:
    usage = "Usage: vshell mise install <package> [command [bin]] | channel <id> <channel> [--json] | refresh [--json] | remove-stubs [--json] | opt-in [--json] | list --json | outdated --json | up"
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
    if sub == "channel":
        args = [a for a in rest if not a.startswith("--")]
        if len(args) != 2:
            RT.eprint(usage)
            return 2
        result = mise_set_channel(args[0], args[1])
        if want_json:
            print(json.dumps(result))
        elif result["ok"]:
            print(f"{result['id']} installs from {result['channel']}: {result['package']}"
                  + (" (launcher stubs are opted out)" if result["optedOut"] else ""))
        else:
            RT.eprint(result["error"])
        return 0 if result["ok"] else 1
    if sub == "refresh":
        result = mise_refresh()
        if want_json:
            print(json.dumps(result))
        elif result["optedOut"]:
            print(f"mise stubs are opted out; delete {RT.state_dir() / MISE_STUBS_REMOVED} to opt back in")
        else:
            print(f"wrote {len(result['written'])} stubs"
                  + (", kept foreign: " + " ".join(result["foreign"]) if result["foreign"] else "")
                  + (", already installed elsewhere: " + " ".join(result["shadowed"]) if result["shadowed"] else "")
                  + (", retired: " + " ".join(result["retired"]) if result["retired"] else ""))
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
