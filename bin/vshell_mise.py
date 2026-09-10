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
                   present: str = "", exec_path: str = "") -> str:
    """The lazy launcher for one tool.

    `build_env` holds variables the install needs and the tool must not inherit:
    a pin like `UV_PYTHON` reaches every command the tool later shells out to,
    where it would resolve the wrong interpreter for the user's own project, so
    the exec drops it again. `requires` are mise packages the backend itself
    needs before it can build this one. `present` is a path under the install
    that proves the build honoured the environment: `mise use` alone accepts an
    install that is already there, and `mise up` rebuilds without the pin, so a
    tool that needs one is re-forced when that path is gone.

    `exec_path` names a file under the install root to run directly, for a
    package installed with mise `bin_path=`. That option moves the exported
    directory to the install root, so the package's own directory never joins
    PATH. `mise x` then finds no executable of that name inside the package and
    falls through to the ambient PATH, where this stub itself answers, so the
    absolute path is the only way in."""
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
    if exec_path:
        # `mise where` can exit 0 with nothing to say. Without this the exec
        # would run /<exec_path> from the filesystem root, naming neither the
        # tool nor the cause; the Python launcher refuses the same state.
        no_root = shlex.quote(f"{command}: mise reported no install root for {package}")
        lines.append(f"root=$(mise where {shlex.quote(package)}) || exit 1")
        lines.append(f'[ -n "$root" ] || {{ echo {no_root} >&2; exit 1; }}')
        lines.append(f'exec {prefix}"$root"/{shlex.quote(exec_path)} "$@"')
    else:
        lines.append(f"exec {prefix}mise x {shlex.quote(package)} -- {shlex.quote(bin_name)} \"$@\"")
    return "\n".join(lines) + "\n"


def command_on_path_elsewhere(command: str, *skip: Path, skip_mise_shims: bool = False) -> str:
    """Where `command` resolves on PATH outside every directory in `skip`, or
    "". Directories are compared resolved, because mise exports an install
    through a `latest` symlink whose target is the versioned directory.

    `skip_mise_shims` passes over mise's own shim directory as well. Every shim
    is a symlink to the mise binary, so a hit there is a second spelling of the
    install being asked about and not a second copy of the command."""
    excluded = {p.resolve() for p in skip}
    which_mise = shutil.which("mise") if skip_mise_shims else ""
    mise_bin = Path(which_mise).resolve() if which_mise else None
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not directory or Path(directory).resolve() in excluded:
            continue
        found = shutil.which(command, path=directory)
        if not found or (mise_bin and Path(found).resolve() == mise_bin):
            continue
        return found
    return ""


def entry_commands(entry: Dict[str, Any]) -> set:
    """The executable names one catalog entry's install owns: the stub's
    command, the file inside the package that stub runs, and the executable its
    launcher names. Every other executable the same install exports belongs to
    some other project, and mise's bin path sits ahead of the distribution's, so
    letting one through replaces a system command for every process the session
    starts."""
    exec_path = str(entry.get("exec") or "")
    inside = Path(exec_path).name if exec_path else str(entry.get("bin") or entry["command"])
    launch = [str(part) for part in entry.get("launch") or []]
    return {str(entry["command"]), inside, *launch[:1]}


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


def stub_fields(entry: Dict[str, Any]) -> Dict[str, Any]:
    """The stub arguments one catalog entry carries, as `mise_install_stub`
    takes them. Every writer of a stub derives them here, so a field the
    template gains reaches the refresh, the install prompt and the replace
    action together instead of two of the three."""
    return {"package": str(entry["package"]), "command": str(entry["command"]),
            "bin_name": str(entry.get("bin") or entry["command"]),
            "build_env": dict(entry.get("buildEnv") or {}),
            "requires": [str(r) for r in entry.get("requires") or []],
            "present": str(entry.get("present") or ""),
            "exec_path": str(entry.get("exec") or "")}


def mise_install_stub(package: str, command: str, bin_name: str = "",
                      build_env: Dict[str, str] | None = None,
                      requires: List[str] | None = None,
                      present: str = "", exec_path: str = "") -> Dict[str, Any]:
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
        handle.write(mise_stub_text(package, command, bin_name, build_env, requires, present, exec_path))
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


def manageable(catalog: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Every catalog entry VGS installs, removes and reports on: the launchable
    ones plus the `tools` CLIs, which have the same package and command but
    nothing to launch. Install, removal and state have one implementation for
    all three groups; only the launcher is narrower."""
    tools = [dict(entry, group="tool", channel="", channels=[])
             for entry in catalog.get("tools") or [] if buildable_here(entry)]
    return launchable(catalog) + tools


def mise_catalog_stubs() -> List[Dict[str, Any]]:
    return [stub_fields(entry) for entry in manageable(dev_tools_catalog())]


EXPORT_SHADOW_KEY = "mise-export-shadow"
EXPORT_CHECK_FAILED_KEY = "mise-export-check-failed"


def mise_export_conflicts() -> Tuple[List[Dict[str, str]], str]:
    """Executables a catalog entry's mise install puts on PATH that the entry
    does not own and that already answer somewhere else on PATH.

    A package is not only the command the catalog asked for: the Cursor Agent
    package ships `node` and `rg` beside its own binary. mise's bin path sits
    ahead of the distribution's, so each of those replaces the system command
    for every process the session starts, and nothing on the machine says why.
    An entry either declares the extra command or keeps its install off PATH
    with mise `bin_path=` and an `exec` path. mise is asked which executables an
    install exports; VGS does not scan the directory itself. The set asked about
    is `manageable()`: the agents, apps and tools this machine can build. An
    `envs` row names distribution packages and other rows, has no package of its
    own, and so exports nothing to ask about.

    An entry mise cannot answer for is recorded and the walk continues: one
    unreadable install must not decide, by its place in the catalog, which
    conflicts the owner is told about."""
    # No mise means no mise bin path and so nothing to shadow. That is an
    # answer, not a failure to report on every refresh.
    if not RT.command_exists("mise"):
        return [], ""
    installs, error = mise_installs()
    errors = [error] if error else []
    conflicts: List[Dict[str, str]] = []
    for entry in manageable(dev_tools_catalog()):
        package = str(entry["package"])
        # An install that does not exist puts no directory on PATH, and asking
        # mise about each of them is the whole cost of this check.
        if package_key(package) not in installs:
            continue
        exports, error = mise_json_list(["bin-paths", "--json", package_key(package)])
        if error:
            errors.append(f"{entry['id']}: {error}")
            continue
        owned = entry_commands(entry)
        for export in exports:
            name = str(export.get("name") or "") if isinstance(export, dict) else ""
            if not name or name in owned:
                continue
            elsewhere = command_on_path_elsewhere(name, Path(str(export.get("path") or "")).parent,
                                                  skip_mise_shims=True)
            if elsewhere:
                conflicts.append({"id": str(entry["id"]), "package": package,
                                  "command": name, "path": elsewhere})
    return conflicts, "; ".join(errors)


def mise_export_check() -> Dict[str, Any]:
    """Whether every catalog install exports only what its entry owns, as the
    lines to show and an outcome the caller acts on.

    Both a conflict and a check that could not run are failures. A package
    answering to a system command is the defect this exists to catch, and one
    that ran and found nothing is the only clean state; a check mise could not
    answer must never read as a clean machine."""
    conflicts, error = mise_export_conflicts()
    lines = [f"{EXPORT_CHECK_FAILED_KEY}: {error}"] if error else []
    lines += [f"{EXPORT_SHADOW_KEY}: {c['id']} exports {c['command']}, which also answers at {c['path']}"
              for c in conflicts]
    return {"ok": not lines, "error": "\n".join(lines), "exports": conflicts, "exportsError": error}


def mise_declare_options() -> Dict[str, Any]:
    """Re-declare every installed catalog entry whose package spec carries
    backend options, so an option the catalog changed reaches a machine that
    installed the row before it.

    mise copies a spec's options into the global config when the tool is first
    used and never revisits them: `mise up` moves the version and leaves the
    options alone. The Cursor Agent row was recorded with `bin_path =
    "dist-package"`, and until it is re-declared that install keeps exporting
    the package directory, with `node` and `rg` ahead of /usr/bin. An entry
    whose spec carries no option records nothing that can drift, and one mise
    has not installed is left alone: its stub declares it on first run."""
    if not RT.command_exists("mise"):
        return {"ok": True, "error": "", "declared": []}
    installs, error = mise_installs()
    errors = [error] if error else []
    declared: List[str] = []
    for entry in manageable(dev_tools_catalog()):
        package = str(entry["package"])
        if not PACKAGE_OPTIONS.search(package) or package_key(package) not in installs:
            continue
        env = {**mise_env(), **mise_build_env(dict(entry.get("buildEnv") or {}))}
        # The install is already there and no path is forced, so this rewrites
        # the config entry and downloads nothing.
        for step in mise_install_steps(package, [], ""):
            try:
                proc = RT.run(step, env=env, cwd=str(RT.home()), timeout=300)
            except (OSError, subprocess.SubprocessError) as exc:
                errors.append(f"{entry['id']}: {exc}")
                continue
            if proc.returncode != 0:
                errors.append(f"{entry['id']}: " + ((proc.stderr or "").strip() or f"mise use exited {proc.returncode}"))
                continue
            declared.append(str(entry["id"]))
    return {"ok": not errors, "error": "; ".join(errors), "declared": declared}


def mise_refresh() -> Dict[str, Any]:
    """Rewrite every catalog stub from the current template. Idempotent; a
    machine whose owner removed the stubs stays that way."""
    if mise_stubs_opted_out():
        return {"ok": True, "error": "", "optedOut": True, "written": [], "foreign": []}
    written: List[str] = []
    foreign: List[str] = []
    shadowed: List[str] = []
    for stub in mise_catalog_stubs():
        state = mise_install_stub(**stub)["state"]
        (written if state == "written" else shadowed if state == "shadowed" else foreign).append(stub["command"])
    return {"ok": True, "error": "", "optedOut": False, "written": written, "foreign": foreign,
            "shadowed": shadowed, "retired": mise_retire_stubs()}


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


def mise_json(args: List[str]) -> Tuple[Any, str]:
    """Run a mise subcommand that prints JSON. (data, error). mise prints an
    object for `ls` and `outdated` and an array for `bin-paths`; callers take
    `mise_json_object` or `mise_json_list` and state that shape once."""
    if not RT.command_exists("mise"):
        return {}, "mise not found"
    # From $HOME, so only the global config is in scope: mise's bare
    # commands otherwise fold in whatever .mise.toml the caller's cwd has.
    try:
        # kill_group: mise runs one `npm view` per npm-backed tool, and those
        # outlive a timeout unless the whole group is signalled.
        proc = RT.run(["mise", *args], env=mise_env(), cwd=str(RT.home()), timeout=120, kill_group=True)
    except (OSError, subprocess.SubprocessError) as exc:
        return {}, f"mise {args[0]} failed: {exc}"
    if proc.returncode != 0:
        return {}, (proc.stderr or "").strip() or f"mise {args[0]} exited {proc.returncode}"
    try:
        data = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError as exc:
        return {}, f"mise {args[0]} printed invalid JSON: {exc}"
    return data, ""


def mise_json_object(args: List[str]) -> Tuple[Dict[str, Any], str]:
    """`mise_json` for a subcommand that prints an object."""
    data, error = mise_json(args)
    if isinstance(data, dict):
        return data, error
    return {}, error or f"mise {args[0]} printed {type(data).__name__}, not an object"


def mise_json_list(args: List[str]) -> Tuple[List[Any], str]:
    """`mise_json` for a subcommand that prints a list."""
    data, error = mise_json(args)
    if isinstance(data, list):
        return data, error
    return [], error or f"mise {args[0]} printed {type(data).__name__}, not a list"


def mise_where(package: str) -> str:
    """The install root mise resolves for `package`, or "". The stub asks mise
    the same question, so the tile and the terminal run one install even where
    several versions are installed and none is active."""
    if not RT.command_exists("mise"):
        return ""
    try:
        proc = RT.run(["mise", "where", package], env=mise_env(), cwd=str(RT.home()), timeout=30)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (proc.stdout or "").strip() if proc.returncode == 0 else ""


def mise_installed_versions() -> Tuple[Dict[str, str], str]:
    """Package key -> installed version, active install preferred."""
    installs, error = mise_installs()
    return {key: str(row["version"]) for key, row in installs.items()}, error


def mise_installs() -> Tuple[Dict[str, Dict[str, Any]], str]:
    """Package key -> {version, declared}. `declared` is whether a mise config
    asks for the tool: `mise outdated` reports only those, so an install nothing
    declares is invisible to every update count and never moves again."""
    data, error = mise_json_object(["ls", "--json"])
    installs: Dict[str, Dict[str, Any]] = {}
    for name, entries in data.items():
        if not isinstance(entries, list):
            continue
        version, declared = "", False
        for install in entries:
            if not isinstance(install, dict) or not install.get("installed"):
                continue
            active = bool(install.get("active"))
            if not version or active:
                version = str(install.get("version") or "")
            if isinstance(install.get("source"), dict):
                declared = True
            if active:
                break
        if version:
            installs[str(name)] = {"version": version, "declared": declared}
    return installs, error


def mise_outdated() -> Tuple[List[Dict[str, str]], str]:
    """Tools `mise up` would move: [{name, id, current, latest}], `name` the
    tool as the reader knows it and `id` the spec mise files it under."""
    data, error = mise_json_object(["outdated", "--json"])
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
        # Two verbs, one command: rewriting the stubs settles nothing about what
        # an install exports, and the owner running a refresh is who acts on it.
        result = {**mise_refresh(), **mise_export_check()}
        if want_json:
            print(json.dumps(result))
        else:
            if result["optedOut"]:
                print(f"mise stubs are opted out; delete {RT.state_dir() / MISE_STUBS_REMOVED} to opt back in")
            else:
                print(f"wrote {len(result['written'])} stubs"
                      + (", kept foreign: " + " ".join(result["foreign"]) if result["foreign"] else "")
                      + (", already installed elsewhere: " + " ".join(result["shadowed"]) if result["shadowed"] else "")
                      + (", retired: " + " ".join(result["retired"]) if result["retired"] else ""))
            if result["error"]:
                print(result["error"])
        return 0 if result["ok"] else 1
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
