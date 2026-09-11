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
    """The mise spec that installs one entry from the channel in force. An
    `exec` path adds an empty `bin_path=`, which keeps the package off PATH;
    the row keeps the plain spec, from which a release that cannot run `exec`
    writes a working launcher (D016)."""
    spec = package_with_options(str(entry["package"]),
                                entry_channels(entry).get(entry_channel(entry, chosen), ""))
    return package_with_options(spec, "bin_path=" if entry.get("exec") else "")


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

    `exec_path` names a file under the install root to run directly (D016)."""
    build_env = build_env or {}
    requires = requires or []
    lines = ["#!/bin/bash", MISE_STUB_MARKER]
    lines += [f"export {name}={shlex.quote(value)}"
              for name, value in sorted(mise_build_env(build_env).items())]
    install = [" ".join(shlex.quote(part) for part in step) + " || exit 1"
               for step in mise_install_steps(package, requires, present)]
    if present:
        probe = f'"$(mise where {shlex.quote(package)} 2>/dev/null)"/{present}'
        install = [f"if ! [ -e {probe} ]; then", *(f"  {line}" for line in install), "fi"]
    drop = "".join(f" -u {shlex.quote(name)}" for name in sorted(build_env))
    prefix = f"env{drop} " if drop else ""
    if exec_path:
        # `mise where` can exit 0 with nothing to say; an exec of /<exec_path>
        # from the filesystem root would name neither the tool nor the cause.
        no_root = shlex.quote(f"{command}: mise reported no install root for {package}")
        lines += install
        lines.append(f"root=$(mise where {shlex.quote(package)}) || exit 1")
        lines.append(f'[ -n "$root" ] || {{ echo {no_root} >&2; exit 1; }}')
        lines.append(f'exec {prefix}"$root"/{shlex.quote(exec_path)} "$@"')
    else:
        # An install holding no `bin_name` sends `mise x` through PATH to this
        # stub, in the same process. Keying the guard to that process lets a
        # tool still start its own command through the stub as a new one.
        guard = f'"$$"{shlex.quote(":" + command)}'
        repair = f"mise install --force {shlex.quote(package)}"
        missing = shlex.quote(f"{command}: {package} installed no {bin_name} executable; repair: {repair}")
        lines += ['case "${VSHELL_MISE_STUB-}" in',
                  f"  {guard}:forced) echo {missing} >&2; exit 1 ;;",
                  f"  {guard}) export VSHELL_MISE_STUB={guard}:forced; {repair} --quiet || exit 1 ;;",
                  f"  *) export VSHELL_MISE_STUB={guard}", *(f"    {line}" for line in install), "    ;;",
                  "esac"]
        lines.append(f"exec {prefix}mise x {shlex.quote(package)} -- {shlex.quote(bin_name)} \"$@\"")
    return "\n".join(lines) + "\n"


def command_on_path_elsewhere(command: str, local_bin: Path, same: frozenset[Path] = frozenset(), replaced: bool = False) -> str:
    """Where `command` resolves on PATH outside ~/.local/bin, or "", each
    directory at its first place, as a shell finds it. Hits resolving to a file
    in `same`, the install under another name, are passed over. With `replaced`
    so is every hit before the first of them, which an install does not
    replace; a launcher in ~/.local/bin answers ahead of every copy (D016)."""
    dirs = [d for d in dict.fromkeys(Path(p) for p in os.environ.get("PATH", "").split(os.pathsep) if p) if d != local_bin]
    hits = [hit for hit in (shutil.which(command, path=str(d)) for d in dirs) if hit]
    first = next((i for i, hit in enumerate(hits) if Path(hit).resolve() in same), 0) if replaced else 0
    return next((hit for hit in hits[first:] if Path(hit).resolve() not in same), "")


def entry_commands(entry: Dict[str, Any]) -> set:
    """The executable names one catalog entry declares: its command, the file
    its `exec` path names, and its launch argv's executable (D016)."""
    exec_path = str(entry.get("exec") or "")
    inside = Path(exec_path).name if exec_path else str(entry.get("bin") or entry["command"])
    launch = [str(part) for part in entry.get("launch") or []]
    return {str(entry["command"]), inside, *launch[:1]}


def mise_stub_state(path: Path, same: frozenset[Path] = frozenset()) -> str:
    """absent, ours (written by VGS), foreign (someone else's file at the
    path) or shadowed (absent, but the command is installed elsewhere on
    PATH outside `same` and ~/.local/bin would hide it)."""
    if not path.exists() and not path.is_symlink():
        return "shadowed" if command_on_path_elsewhere(path.name, path.parent, same) else "absent"
    try:
        head = path.read_text(errors="replace").splitlines()[:4]
    except OSError:
        return "foreign"
    return "ours" if MISE_STUB_MARKER in head else "foreign"


LAUNCHER_NOT_OURS_KEY = "mise-launcher-not-ours"


def launcher_refusal(entry: Dict[str, Any]) -> str:
    """Why VGS will not record `entry`'s options, or "". Once they are recorded
    an entry with an `exec` path runs from a shell only through its launcher,
    and the owner's own file there is the one launcher no VGS action rewrites
    (D016)."""
    path = RT.home() / ".local" / "bin" / str(entry["command"])
    if not entry.get("exec") or mise_stub_state(path) != "foreign":
        return ""
    return (f"{LAUNCHER_NOT_OURS_KEY}: {entry['id']} {path}\n"
            f"  Once {entry['package']} is recorded, only this file runs {entry['command']}, and VGS does not own it.\n"
            f"  Make it run the binary by absolute path, then run: mise use -g {shlex.quote(str(entry['package']))}")


LAUNCHER_HELD_KEY = "mise-launcher-held"


def launcher_advice(entry: Dict[str, Any]) -> str:
    """What clears an installed `exec` entry's shadowing when no launcher could
    be written, or "": the owner's own file there, or another copy of the
    command, which a launcher would hide. Each remedy leaves a route (D016)."""
    refusal = launcher_refusal(entry)
    path = RT.home() / ".local" / "bin" / str(entry["command"])
    if refusal or not entry.get("exec") or path.exists():
        return refusal
    where = command_on_path_elsewhere(path.name, path.parent, install_exports(entry)[1])
    return where and (f"{LAUNCHER_HELD_KEY}: {entry['id']} {where}\n"
                      f"  {entry['command']} also answers at {where}, and a launcher in {path.parent} would hide it.\n"
                      f"  Remove that copy and run vshell mise refresh, or keep it and run: mise use -g {shlex.quote(str(entry['package']))}")


def stub_fields(entry: Dict[str, Any]) -> Dict[str, Any]:
    """The stub arguments one catalog entry carries, as `mise_install_stub`
    takes them; every writer of a stub derives them here."""
    return {"package": str(entry["package"]), "command": str(entry["command"]),
            "bin_name": str(entry.get("bin") or entry["command"]),
            "build_env": dict(entry.get("buildEnv") or {}),
            "requires": [str(r) for r in entry.get("requires") or []],
            "present": str(entry.get("present") or ""),
            "exec_path": str(entry.get("exec") or "")}


def mise_install_stub(package: str, command: str, bin_name: str = "",
                      build_env: Dict[str, str] | None = None,
                      requires: List[str] | None = None,
                      present: str = "", exec_path: str = "", same: frozenset[Path] = frozenset()) -> Dict[str, Any]:
    """Write ~/.local/bin/<command>. A file VGS did not write is never replaced:
    the owner's own wrapper for the same command wins, and the result says so."""
    bin_name = bin_name or command
    path = RT.home() / ".local" / "bin" / command
    state = mise_stub_state(path, same)
    result = {"command": command, "package": package, "path": str(path), "state": state}
    if state == "foreign":
        result["error"] = f"{path} exists and was not written by vshell"
        return result
    if state == "shadowed":
        result["error"] = f"{command} is already installed at {command_on_path_elsewhere(command, path.parent, same)}; a stub in {path.parent} would hide it"
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
    tools = [dict(entry, group="tool", package=entry_package(entry, {}), channel="", channels=[])
             for entry in catalog.get("tools") or [] if buildable_here(entry)]
    return launchable(catalog) + tools


def mise_catalog_stubs() -> List[Dict[str, Any]]:
    return [stub_fields(entry) for entry in manageable(dev_tools_catalog())]


EXPORT_SHADOW_KEY = "mise-export-shadow"
EXPORT_CHECK_FAILED_KEY = "mise-export-check-failed"
DECLARE_FAILED_KEY = "mise-declare-failed"


def installed_entries() -> Tuple[List[Dict[str, Any]], str]:
    """The catalog entries mise holds an install of, and mise's error when it
    could not say. No mise means none, which is an answer and not a failure."""
    if not RT.command_exists("mise"):
        return [], ""
    installs, error = mise_installs()
    return [e for e in manageable(dev_tools_catalog()) if package_key(str(e["package"])) in installs], error


def install_exports(entry: Dict[str, Any]) -> Tuple[Dict[str, Path], frozenset[Path], str]:
    """What mise's install of `entry` exports, name -> the file each runs; the
    files that are that install under any name, which the export check and the
    launcher both pass over; and mise's error when it could not say (D016)."""
    exports, error = mise_json_list(["bin-paths", "--json", package_key(str(entry["package"]))])
    # Resolved: a link, a `latest` directory and a shim name the file they run.
    files = {str(e["name"]): Path(str(e.get("path") or "")).resolve()
             for e in exports if isinstance(e, dict) and e.get("name")}
    # Every mise shim is a link to the mise binary, which runs the install.
    which_mise = shutil.which("mise")
    return files, frozenset({*files.values(), *([Path(which_mise).resolve()] if which_mise else [])}), error


def mise_export_conflicts(entries: List[Dict[str, Any]]) -> Tuple[List[Dict[str, str]], str]:
    """The exports of each install in `entries` that its entry does not declare
    and that shadow another copy on PATH (D016), and the errors of the installs
    mise could not answer for. The walk goes on past such an install, so its
    place in the catalog cannot hide a later conflict."""
    errors: List[str] = []
    conflicts: List[Dict[str, str]] = []
    for entry in entries:
        files, same, error = install_exports(entry)
        if error:
            errors.append(f"{entry['id']}: {error}")
            continue
        declared = entry_commands(entry)
        for name in files:
            # A copy in ~/.local/bin answers ahead of every install, as the stub
            # writer takes it to, so no install replaces it.
            elsewhere = "" if name in declared else command_on_path_elsewhere(name, RT.home() / ".local" / "bin", same, True)
            if elsewhere:
                conflicts.append({"id": str(entry["id"]), "package": str(entry["package"]),
                                  "command": name, "path": elsewhere})
    return conflicts, "; ".join(errors)


def mise_export_check(entries: List[Dict[str, Any]], error: str = "") -> Dict[str, Any]:
    """Whether every install in `entries` exports only what its entry owns, as
    the lines to show and an outcome the caller acts on. `error` says why
    `entries` may be short, and fails the check as a conflict does (D016)."""
    conflicts, failed = mise_export_conflicts(entries)
    error = "; ".join(e for e in (error, failed) if e)
    lines = [f"{EXPORT_CHECK_FAILED_KEY}: {error}"] if error else []
    lines += [f"{EXPORT_SHADOW_KEY}: {c['id']} exports {c['command']}, which also answers at {c['path']}"
              for c in conflicts]
    return {"ok": not lines, "error": "\n".join(lines), "exports": conflicts}


def mise_settle(entry: Dict[str, Any], installed: bool) -> Tuple[str, str]:
    """Keep one entry's launcher current: its state afterwards, and the error
    of the re-declaration (D016). A stub VGS wrote is rewritten from the current
    template, auto-install on or off, and a missing one is written while it is
    on. An installed entry with an `exec` path runs from a shell only through
    its launcher, so a missing one is written whatever the setting, unless
    another copy of the command answers, which it would hide; the install's own
    files and its shims are no other copy. Only behind a launcher just written
    is the entry's spec re-declared: mise records a spec's options once, so an
    option the catalog changed reaches an earlier install no other way."""
    stub = stub_fields(entry)
    route = installed and bool(stub["exec_path"])
    if mise_stubs_opted_out() and not route and mise_stub_state(RT.home() / ".local" / "bin" / stub["command"]) != "ours":
        return "opted-out", ""
    _, same, error = install_exports(entry) if route else ({}, frozenset(), "")
    state = mise_install_stub(**stub, same=same)["state"]
    declared = mise_run(mise_install_steps(stub["package"], [], "")[0][1:], mise_build_env(stub["build_env"]),
                        timeout=300)[1] if route and state == "written" else ""
    return state, "; ".join(filter(None, (error, declared)))


def mise_sync() -> Dict[str, Any]:
    """What `vshell mise refresh` runs (D016): every launcher settled, then the
    export check, as one outcome that passes only when both do, with the
    advice that clears a shadowing install whose launcher could not be
    written. Opt-in and a channel pick run it too, and report its outcome."""
    entries, error = installed_entries()
    stubs = mise_refresh(entries)
    exports = mise_export_check(entries, error)
    shadowing = {c["id"] for c in exports["exports"]}
    advice = [launcher_advice(e) for e in entries if e["id"] in shadowing]
    return {"ok": stubs["ok"] and exports["ok"], "error": "\n".join(filter(None, (stubs["error"], exports["error"], *advice))),
            "stubs": stubs, "exports": exports["exports"]}


def outcome_status(result: Dict[str, Any]) -> int:
    """The exit status of an {ok, error} outcome, its error on stderr."""
    if result["error"]:
        RT.eprint(result["error"])
    return 0 if result["ok"] else 1


def mise_refresh(installed: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Settle every catalog entry's launcher (`mise_settle`). Idempotent; with
    auto-install off it writes no new stub but an installed `exec` entry's
    launcher. `installed` is the entries mise holds."""
    ids = {e["id"] for e in installed}
    states: Dict[str, List[str]] = {"written": [], "foreign": [], "shadowed": [], "opted-out": []}
    errors: List[str] = []
    for entry in manageable(dev_tools_catalog()):
        state, error = mise_settle(entry, entry["id"] in ids)
        states[state].append(str(entry["command"]))
        errors += [f"{entry['id']}: {error}"] if error else []
    return {"ok": not errors, "error": f"{DECLARE_FAILED_KEY}: " + "; ".join(errors) if errors else "",
            "optedOut": mise_stubs_opted_out(), "written": states["written"], "foreign": states["foreign"],
            "shadowed": states["shadowed"], "retired": mise_retire_stubs()}


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
    """Record which release stream one entry installs from, then run the
    refresh, whose outcome is this one's. A stub carries the spec its channel
    selects, so the setting alone leaves the next launch on the old stream."""
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
    synced = mise_sync()
    # Re-read rather than predict: the stub just written is what the next launch
    # runs, and it was built from the setting this call has now changed.
    updated = next(e for e in launchable(dev_tools_catalog()) if e.get("id") == entry_id)
    return {"ok": synced["ok"], "error": synced["error"], "id": entry_id, "channel": str(updated["channel"]),
            "package": str(updated["package"]), "optedOut": bool(synced["stubs"]["optedOut"])}


def mise_remove_stubs() -> Dict[str, Any]:
    """Delete the stubs VGS wrote but the launcher of every installed entry
    with an `exec` path, record the opt-out, then settle, which keeps each kept
    launcher current. When mise cannot say what is installed, every `exec`
    entry's stub stays, and the run fails (D016)."""
    entries, error = installed_entries()
    held = {str(e["command"]) for e in (manageable(dev_tools_catalog()) if error else entries) if e.get("exec")}
    removed: List[str] = []
    kept: List[str] = []
    for stub in mise_catalog_stubs():
        path = RT.home() / ".local" / "bin" / stub["command"]
        state = mise_stub_state(path)
        if state == "ours" and stub["command"] not in held:
            path.unlink(missing_ok=True)
            removed.append(stub["command"])
        elif state == "foreign":
            kept.append(stub["command"])
    marker = RT.state_dir() / MISE_STUBS_REMOVED
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.touch()
    settled = mise_refresh(entries)
    return {"ok": not error and settled["ok"], "error": "; ".join(filter(None, (error, settled["error"]))),
            "removed": removed, "kept": kept, "routes": settled["written"]}


def mise_run(args: List[str], env: Dict[str, str] | None = None, timeout: int = 120) -> Tuple[str, str]:
    """Run one mise subcommand, `env` on top of `mise_env()`: (stdout, error),
    the error mise's own stderr when it exits non-zero."""
    if not RT.command_exists("mise"):
        return "", "mise not found"
    # From $HOME, so only the global config is in scope: mise's bare
    # commands otherwise fold in whatever .mise.toml the caller's cwd has.
    try:
        # kill_group: mise runs one `npm view` per npm-backed tool, and those
        # outlive a timeout unless the whole group is signalled.
        proc = RT.run(["mise", *args], env={**mise_env(), **(env or {})}, cwd=str(RT.home()), timeout=timeout, kill_group=True)
    except (OSError, subprocess.SubprocessError) as exc:
        return "", f"mise {args[0]} failed: {exc}"
    if proc.returncode != 0:
        return "", (proc.stderr or "").strip() or f"mise {args[0]} exited {proc.returncode}"
    return proc.stdout or "", ""


def mise_json(args: List[str]) -> Tuple[Any, str]:
    """Run a mise subcommand that prints JSON: (data, error). Callers take
    `mise_json_object` or `mise_json_list`, which state the shape once."""
    stdout, error = mise_run(args)
    if error:
        return {}, error
    try:
        data = json.loads(stdout or "{}")
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


def mise_where(package: str) -> Tuple[str, str]:
    """The install root mise resolves for `package`, and mise's error when it
    could not say; the stub asks mise the same question (D016)."""
    root, error = mise_run(["where", package], timeout=30)
    return root.strip(), error


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
        elif "channel" in result:
            print(f"{result['id']} installs from {result['channel']}: {result['package']}"
                  + (" (launcher stubs are opted out)" if result["optedOut"] else ""))
        return outcome_status(result)
    if sub == "refresh":
        synced = mise_sync()
        result = synced["stubs"]
        if want_json:
            print(json.dumps(synced))
        elif result["optedOut"]:
            print(f"mise stubs are opted out; delete {RT.state_dir() / MISE_STUBS_REMOVED} to opt back in")
        else:
            print(f"wrote {len(result['written'])} stubs"
                  + (", kept foreign: " + " ".join(result["foreign"]) if result["foreign"] else "")
                  + (", already installed elsewhere: " + " ".join(result["shadowed"]) if result["shadowed"] else "")
                  + (", retired: " + " ".join(result["retired"]) if result["retired"] else ""))
        return outcome_status(synced)
    if sub == "opt-in":
        marker = RT.state_dir() / MISE_STUBS_REMOVED
        if marker.exists():
            marker.unlink()
        synced = mise_sync()
        print(json.dumps(synced) if want_json else f"wrote {len(synced['stubs']['written'])} stubs")
        return outcome_status(synced)
    if sub == "remove-stubs":
        result = mise_remove_stubs()
        print(json.dumps(result) if want_json else f"removed {len(result['removed'])} stubs"
              + (", kept foreign: " + " ".join(result["kept"]) if result["kept"] else "")
              + (", kept as the only way to run: " + " ".join(result["routes"]) if result["routes"] else ""))
        return outcome_status(result)
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
