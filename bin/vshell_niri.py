from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, List

from vshell_niri_kdl import (
    kdl_matching_brace as _kdl_matching_brace,
    kdl_nodes_in_block as _kdl_nodes_in_block,
    kdl_unquote as _kdl_unquote,
)


@dataclass(frozen=True)
class NiriRuntime:
    home: Callable[[], Path]
    cfg_dir: Callable[[], Path]
    run: Callable[..., subprocess.CompletedProcess]
    write_file: Callable[[Path, str], None]
    load_settings: Callable[[], Dict[str, Any]]
    coerce_int: Callable[..., int]
    optional_nonnegative_int: Callable[..., int | None]


_runtime: NiriRuntime | None = None


def configure(runtime: NiriRuntime) -> None:
    global _runtime
    _runtime = runtime


def runtime() -> NiriRuntime:
    if _runtime is None:
        raise RuntimeError("vshell_niri runtime is not configured")
    return _runtime

@contextlib.contextmanager
def niri_config_lock():
    lock_path = runtime().cfg_dir() / "niri-config.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _niri_include_paths(config_path: Path, text: str) -> List[Path]:
    """Return normalized paths from direct KDL include nodes in config_path."""
    paths: List[Path] = []
    for match in re.finditer(r'(?m)^\s*include\s+(?:"((?:\\.|[^"])*)"|([^\s;]+))', text):
        raw = match.group(1) if match.group(1) is not None else match.group(2)
        try:
            value = json.loads(f'"{raw}"') if match.group(1) is not None else raw
        except (TypeError, ValueError, json.JSONDecodeError):
            value = raw
        include_path = Path(os.path.expandvars(os.path.expanduser(value)))
        if not include_path.is_absolute():
            include_path = config_path.parent / include_path
        try:
            include_path = include_path.resolve()
        except OSError:
            include_path = Path(os.path.abspath(include_path))
        paths.append(include_path)
    return paths


def niri_include_status(filename: str) -> Dict[str, Any]:
    """Report whether config.kdl directly includes the managed VGS fragment."""
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.kdl", filename or ""):
        return {"ok": False, "error": "invalid Niri fragment filename"}
    main = runtime().home() / ".config" / "niri" / "config.kdl"
    fragment = niri_config_dir() / filename
    text = main.read_text(errors="replace") if main.is_file() else ""
    try:
        target = fragment.resolve()
    except OSError:
        target = Path(os.path.abspath(fragment))
    included = target in _niri_include_paths(main, text)
    return {
        "ok": True,
        "exists": fragment.is_file(),
        "included": included,
        "configFormat": "kdl",
        "readOnly": False,
        "path": str(main),
        "includePath": str(fragment),
        "statusMessage": "" if included else f'Add include "vgs/{filename}" to the Niri config',
    }


def ensure_niri_include(filename: str) -> Dict[str, Any]:
    """Create one managed fragment/include under the shared Niri config lock."""
    if not re.fullmatch(r"[A-Za-z0-9._-]+\.kdl", filename or ""):
        return {"ok": False, "error": "invalid Niri fragment filename"}
    with niri_config_lock():
        main = runtime().home() / ".config" / "niri" / "config.kdl"
        fragment = niri_config_dir() / filename
        if not fragment.exists():
            runtime().write_file(fragment, "")
        if not main.is_file():
            return {
                "ok": False,
                "changed": False,
                "setupRequired": True,
                "config": str(main),
                "fragment": str(fragment),
                "error": "Niri main config does not exist; start Niri or create config.kdl before adding VGS includes",
            }
        original = main.read_text(errors="replace")
        if niri_include_status(filename).get("included"):
            return {
                "ok": True,
                "changed": False,
                "config": str(main),
                "fragment": str(fragment),
            }
        if main.is_file():
            backup = main.with_name(f"{main.name}.vgsbackup{int(time.time())}")
            shutil.copy2(main, backup)
        content = original
        if content and not content.endswith("\n"):
            content += "\n"
        if content:
            content += "\n"
        if "// VGS Include Configs" not in content:
            content += "// VGS Include Configs\n"
        content += f'include "vgs/{filename}"\n'
        runtime().write_file(main, content)
        return {
            "ok": True,
            "changed": True,
            "config": str(main),
            "fragment": str(fragment),
        }


def _niri_action_from_body(body: str) -> str:
    statement = ""
    quote = False
    escaped = False
    depth = 0
    for char in body:
        if quote:
            statement += char
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quote = False
            continue
        if char == '"':
            quote = True
            statement += char
        elif char == "{":
            depth += 1
            statement += char
        elif char == "}":
            depth -= 1
            statement += char
        elif char == ";" and depth == 0:
            break
        elif char == "/" and statement.rstrip().endswith("/"):
            statement = statement.rstrip()[:-1]
            break
        else:
            statement += char
    statement = " ".join(statement.split())
    if not statement:
        return ""
    try:
        tokens = shlex.split(statement)
    except ValueError:
        return statement
    return " ".join(tokens)

def _niri_bind_category(action: str) -> str:
    lower = action.lower()
    if lower.startswith("spawn"):
        return "Execute"
    if "workspace" in lower:
        return "Workspace"
    if any(word in lower for word in ("window", "column", "floating", "fullscreen", "maximize", "focus-")):
        return "Window"
    if any(word in lower for word in ("screenshot", "power-", "quit", "suspend", "overview", "layout")):
        return "System"
    return "Other"

def _niri_config_files(path: Path, seen: set[Path] | None = None) -> List[Path]:
    seen = seen or set()
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path
    if resolved in seen or not path.is_file():
        return []
    seen.add(resolved)
    files = [path]
    text = path.read_text(errors="replace")
    for include_path in _niri_include_paths(path, text):
        files.extend(_niri_config_files(include_path, seen))
    return files

def _niri_binds_from_file(path: Path) -> List[Dict[str, Any]]:
    text = path.read_text(errors="replace")
    result: List[Dict[str, Any]] = []
    for match in re.finditer(r"\bbinds\s*\{", text):
        opening = text.find("{", match.start())
        closing = _kdl_matching_brace(text, opening)
        if closing < 0:
            continue
        for header, body, comment in _kdl_nodes_in_block(text[opening + 1:closing]):
            key_match = re.match(r'("(?:\\.|[^"])*"|[^\s]+)', header)
            if not key_match:
                continue
            key = _kdl_unquote(key_match.group(1))
            action = _niri_action_from_body(body)
            if not action:
                continue
            title_match = re.search(r'hotkey-overlay-title\s*=\s*("(?:\\.|[^"])*")', header)
            description = _kdl_unquote(title_match.group(1)) if title_match else comment
            properties = dict(re.findall(r"([\w-]+)\s*=\s*([^\s]+)", header))
            result.append({
                "key": key,
                "desc": description or action,
                "action": action,
                "source": "vgs" if "vgs/binds.kdl" in str(path) else str(path),
                "cooldownMs": int(properties.get("cooldown-ms", "0")) if properties.get("cooldown-ms", "0").isdigit() else 0,
                "allowWhenLocked": properties.get("allow-when-locked") == "true",
                "allowInhibiting": properties.get("allow-inhibiting", "true") != "false",
                "repeat": properties.get("repeat", "true") != "false",
            })
    return result

def niri_binds_json() -> Dict[str, Any]:
    # Heal VGS-generated binds that still name a retired launcher IPC target
    # before reporting them, so Settings never shows a bind VGS knows is dead.
    # A rewrite Niri then refused to load leaves the file and the live
    # compositor disagreeing, so that has to travel with the payload rather
    # than being dropped here.
    #
    # This is a convenience on a read path and must never take the read down
    # with it: an unreadable or unwritable binds.kdl would otherwise abort the
    # whole keybind query and lose Settings every other bind in the config,
    # which are parsed independently below and are still perfectly good.
    try:
        migration = migrate_vgs_niri_binds()
    except OSError as exc:
        migration = {
            "migrated": False,
            "ok": False,
            "error": f"could not migrate retired launcher binds: {exc}",
            "reload": {"attempted": False},
        }
    main = runtime().home() / ".config" / "niri" / "config.kdl"
    managed = niri_config_dir() / "binds.kdl"
    files = _niri_config_files(main)
    if managed.is_file() and managed.resolve() not in {path.resolve() for path in files}:
        files.append(managed)
    binds: Dict[str, List[Dict[str, Any]]] = {}
    for path in files:
        try:
            entries = _niri_binds_from_file(path)
        except OSError:
            continue
        for entry in entries:
            binds.setdefault(_niri_bind_category(entry["action"]), []).append(entry)
    included = bool(niri_include_status("binds.kdl").get("included"))
    payload: Dict[str, Any] = {
        "provider": "niri",
        "modKey": "Super",
        "vgsBindsIncluded": included,
        "vgsStatus": {
            "exists": managed.is_file(),
            "included": included,
            "readOnly": False,
            "configFormat": "kdl",
            "statusMessage": "" if included else 'Add include "vgs/binds.kdl" to the Niri config',
        },
        "binds": binds,
    }
    if migration.get("migrated") or not migration.get("ok"):
        payload["bindMigration"] = migration
    return payload

def _niri_action_kdl(action: str) -> str:
    try:
        tokens = shlex.split(action)
    except ValueError as exc:
        raise ValueError(f"invalid action: {exc}") from exc
    if not tokens:
        raise ValueError("action is empty")
    name, args = tokens[0], tokens[1:]
    if not re.fullmatch(r"[a-z0-9-]+", name):
        raise ValueError(f"invalid Niri action name: {name}")
    if name == "spawn":
        if not args:
            raise ValueError("spawn action needs a command")
        return "spawn " + " ".join(json.dumps(arg) for arg in args)
    return name + ((" " + " ".join(json.dumps(arg) for arg in args)) if args else "")

# VGS-13 retired the grid launcher, the app drawer and the spotlight bar; the
# vgsMenu plugin's "vshell-menu" target is the only launcher IPC left. These
# binds live in a VGS-generated file, so VGS has to rewrite them rather than
# leave a user with a key that spawns against a target that no longer answers.
_RETIRED_LAUNCHER_IPC_TARGETS = ("spotlight-bar", "spotlight", "launcher")
_LAUNCHER_IPC_TARGET = "vshell-menu"
# vshell-menu exposes only open/close/toggle. The retired targets also had
# mode/query verbs; those collapse onto the plain verb rather than being dropped,
# so a bound key keeps opening the launcher.
_RETIRED_LAUNCHER_IPC_VERBS = {
    "close": "close",
    "open": "open",
    "openWith": "open",
    "openQuery": "open",
    "toggle": "toggle",
    "toggleWith": "toggle",
    "toggleQuery": "toggle",
}


# "ipc call <target>" is VGS syntax, not a reserved word: another program can
# legitimately take those as its own arguments. Only a vshell invocation may be
# rewritten. Compared by basename so an absolute or $HOME-relative path to the
# same CLI still counts (~/dotfiles binds both `vshell ipc call ...` and
# `$HOME/.local/bin/vshell ipc call ...`), and quote-stripped so the first token
# of a `sh -c "..."` command string is recognised too.
_VSHELL_CLI_BASENAMES = frozenset({"vshell"})


def _is_vshell_cli(token: str) -> bool:
    return Path(token.strip("\"'")).name in _VSHELL_CLI_BASENAMES


def _migrated_launcher_action(action: str) -> str:
    """Rewrite a retired launcher IPC action onto vshell-menu. Identity otherwise.

    Deliberately positional: only `spawn <vshell-cli> ipc call ...` is rewritten.
    A retired target buried in a shell wrapper (`spawn sh -c "vshell ipc call
    launcher toggle"`) is left alone rather than rewritten inside a quoted
    command string. KeybindActions.usesRetiredIpcTarget still flags that form in
    Settings, which is the same treatment as any bind VGS does not generate.
    """
    tokens = action.split()
    # spawn <vshell-cli> ipc call <target> <verb> [args...]
    if len(tokens) < 6 or tokens[0] != "spawn" or tokens[2:4] != ["ipc", "call"]:
        return action
    if not _is_vshell_cli(tokens[1]):
        return action
    if tokens[4] not in _RETIRED_LAUNCHER_IPC_TARGETS:
        return action
    verb = _RETIRED_LAUNCHER_IPC_VERBS.get(tokens[5])
    if verb is None:
        return action
    return " ".join(tokens[:4] + [_LAUNCHER_IPC_TARGET, verb])


def _migrate_retired_bind_actions(binds: List[Dict[str, Any]]) -> tuple[List[Dict[str, Any]], bool]:
    changed = False
    migrated: List[Dict[str, Any]] = []
    for bind in binds:
        action = str(bind.get("action") or "")
        new_action = _migrated_launcher_action(action)
        if new_action != action:
            bind = dict(bind)
            bind["action"] = new_action
            changed = True
        migrated.append(bind)
    return migrated, changed


_NO_MIGRATION: Dict[str, Any] = {"migrated": False, "ok": True, "reload": {"attempted": False}}


def migrate_vgs_niri_binds() -> Dict[str, Any]:
    """Rewrite retired launcher IPC targets in the VGS-generated binds file.

    Returns {"migrated", "ok", "reload"}. Safe to call on every read: it only
    touches VGS-owned binds.kdl, never the user's own Niri config, and it
    rewrites (and reloads) only when a retired target is actually present.

    `ok` is false when the rewrite landed but Niri refused to reload it — the
    file then names vshell-menu while the live compositor still holds the
    retired bind, which is exactly the state a caller must not report as
    healthy.
    """
    path = niri_config_dir() / "binds.kdl"
    if not path.is_file():
        return dict(_NO_MIGRATION)
    with niri_config_lock():
        binds, changed = _migrate_retired_bind_actions(_niri_binds_from_file(path))
        if not changed:
            return dict(_NO_MIGRATION)
        _write_vgs_niri_binds(binds)
        reload_result = _reload_niri()
    return {
        "migrated": True,
        "ok": not reload_result.get("attempted") or bool(reload_result.get("ok")),
        "reload": reload_result,
    }


def _load_vgs_niri_binds() -> List[Dict[str, Any]]:
    path = niri_config_dir() / "binds.kdl"
    if not path.is_file():
        return []
    binds, _ = _migrate_retired_bind_actions(_niri_binds_from_file(path))
    return binds

def _write_vgs_niri_binds(binds: List[Dict[str, Any]]) -> None:
    lines = ["// Generated by VGS. Edit through VGS Settings.", "binds {"]
    for bind in binds:
        description = str(bind.get("desc") or "").replace("\n", " ").strip()
        properties = []
        if description:
            properties.append("hotkey-overlay-title=" + json.dumps(description))
        if bind.get("cooldownMs"):
            properties.append("cooldown-ms=" + str(int(bind["cooldownMs"])))
        if bind.get("allowWhenLocked"):
            properties.append("allow-when-locked=true")
        if bind.get("allowInhibiting") is False:
            properties.append("allow-inhibiting=false")
        if bind.get("repeat") is False:
            properties.append("repeat=false")
        header = json.dumps(str(bind["key"]))
        if properties:
            header += " " + " ".join(properties)
        lines.append(f"    {header} {{ {_niri_action_kdl(str(bind['action']))}; }}")
    lines.extend(["}", ""])
    runtime().write_file(niri_config_dir() / "binds.kdl", "\n".join(lines))

def niri_config_dir() -> Path:
    return runtime().home() / ".config" / "niri" / "vgs"

def _kdl_bool(value: bool) -> str:
    return "true" if value else "false"

def _niri_layout_payload(settings: Dict[str, Any]) -> tuple[str, Dict[str, Any]]:
    shell_radius = runtime().coerce_int(settings.get("cornerRadius"), 12, 0, 64)
    shell_border = runtime().coerce_int(settings.get("surfaceBorderWidth"), 1, 0, 32)
    radius_override = runtime().optional_nonnegative_int(settings.get("niriLayoutRadiusOverride"), 0, 64)
    border_override = runtime().optional_nonnegative_int(settings.get("niriLayoutBorderSize"), 0, 32)
    target = str(settings.get("surfaceGeometryTarget") or "sync")
    if target == "hyprland":
        target = "compositor"
    if target not in {"sync", "quickshell", "compositor"}:
        target = "sync"
    manage_niri_shape = target != "quickshell"
    radius = shell_radius if target == "sync" else (
        radius_override if radius_override is not None else shell_radius)
    border = shell_border if target == "sync" else (
        border_override if border_override is not None else shell_border)
    raw_gaps = settings.get("niriLayoutGapsOverride", -1)
    try:
        gap_mode = int(raw_gaps)
    except (TypeError, ValueError):
        gap_mode = -1
    gaps = runtime().optional_nonnegative_int(gap_mode, 0, 128)
    if gap_mode != -2 and gaps is None:
        bar_configs = settings.get("barConfigs") or [{}]
        gaps = runtime().coerce_int((bar_configs[0] or {}).get("spacing"), 4, 0, 128)
    lines = [
        "// Generated by VGS. Do not edit.",
        "// Surface geometry is stored in VGS settings; themes only own colors and wallpapers.",
        "layout {",
    ]
    if gaps is not None:
        lines.append(f"    gaps {gaps}")
    if manage_niri_shape:
        lines.extend([
            "    focus-ring {",
            "        off",
            f"        width {border}",
            "    }",
            "    border {",
            "        " + ("on" if border > 0 else "off"),
            f"        width {border}",
            "    }",
        ])
    lines.extend(["}", ""])
    if manage_niri_shape:
        lines.extend([
            "window-rule {",
            f"    geometry-corner-radius {radius}",
            "    clip-to-geometry true",
            "    tiled-state true",
            "    draw-border-with-background false",
            "}",
            "",
        ])
    return "\n".join(lines), {
        "target": target,
        "manageNiriShape": manage_niri_shape,
        "radius": radius if manage_niri_shape else None,
        "gaps": gaps,
        "border": border if manage_niri_shape else None,
    }

def _reload_niri() -> Dict[str, Any]:
    if not shutil.which("niri") or not os.environ.get("NIRI_SOCKET"):
        return {"attempted": False}
    proc = runtime().run(["niri", "msg", "action", "load-config-file"])
    return {
        "attempted": True,
        "ok": proc.returncode == 0,
        "stdout": proc.stdout.strip(),
        "stderr": proc.stderr.strip(),
    }

def apply_niri_layout() -> Dict[str, Any]:
    with niri_config_lock():
        content, meta = _niri_layout_payload(runtime().load_settings())
        path = niri_config_dir() / "layout.kdl"
        runtime().write_file(path, content)
        reload_result = _reload_niri()
    return {
        "ok": not reload_result.get("attempted") or bool(reload_result.get("ok")),
        "path": str(path),
        "layout": meta,
        "reload": reload_result,
    }

def apply_niri_cursor() -> Dict[str, Any]:
    with niri_config_lock():
        settings = runtime().load_settings()
        cursor = settings.get("cursorSettings") or {}
        theme = cursor.get("theme") or ""
        if theme == "System Default":
            theme = settings.get("systemDefaultCursorTheme") or ""
        size = runtime().coerce_int(cursor.get("size"), 24, 1, 256)
        lines = ["// Generated by VGS. Do not edit.", "cursor {"]
        if theme:
            lines.append(f"    xcursor-theme {json.dumps(str(theme))}")
        lines.extend([f"    xcursor-size {size}", "}", ""])
        path = niri_config_dir() / "cursor.kdl"
        runtime().write_file(path, "\n".join(lines))
        reload_result = _reload_niri()
    return {
        "ok": not reload_result.get("attempted") or bool(reload_result.get("ok")),
        "path": str(path),
        "reload": reload_result,
    }

def apply_niri_output(output_name: str, config: Dict[str, Any]) -> Dict[str, Any]:
    if not output_name or not isinstance(config, dict):
        return {"ok": False, "error": "invalid output config"}
    if not shutil.which("niri") or not os.environ.get("NIRI_SOCKET"):
        return {"ok": False, "error": "niri session unavailable"}

    commands: List[List[str]] = []
    prefix = ["niri", "msg", "output", output_name]
    if "disabled" in config:
        commands.append(prefix + ["off" if config["disabled"] else "on"])
        if config["disabled"]:
            config = {"disabled": True}
    if not config.get("disabled"):
        position = config.get("position")
        if isinstance(position, dict) and "x" in position and "y" in position:
            commands.append(prefix + ["position", "set", str(position["x"]), str(position["y"])])
        if config.get("mode") is not None:
            commands.append(prefix + ["mode", str(config["mode"])])
        if "vrrOnDemand" in config:
            commands.append(prefix + ["vrr", "--on-demand", "on" if config["vrrOnDemand"] else "off"])
        elif "vrr" in config:
            commands.append(prefix + ["vrr", "on" if config["vrr"] else "off"])
        if config.get("scale") is not None:
            commands.append(prefix + ["scale", str(config["scale"])])
        if config.get("transform") is not None:
            commands.append(prefix + ["transform", str(config["transform"])])

    results = []
    for command in commands:
        proc = runtime().run(command)
        results.append({
            "argv": command,
            "ok": proc.returncode == 0,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
        })
        if proc.returncode != 0:
            return {"ok": False, "commands": results, "error": proc.stderr.strip() or proc.stdout.strip()}
    return {"ok": True, "commands": results}

def _niri_output_identifier(output: Dict[str, Any], name: str, display_name_mode: str) -> str:
    if output.get("explicitIdentifier"):
        return name
    if display_name_mode == "model" and output.get("make") and output.get("model"):
        return f"{output['make']} {output['model']} {output.get('serial') or 'Unknown'}"
    return name

def _niri_output_settings(
    output: Dict[str, Any],
    name: str,
    settings: Dict[str, Any],
    display_name_mode: str,
) -> Dict[str, Any]:
    identifier = _niri_output_identifier(output, name, display_name_mode)
    value = settings.get(identifier, settings.get(name, {}))
    return value if isinstance(value, dict) else {}

def _niri_transform_name(value: Any) -> str:
    transforms = {
        "Normal": "normal",
        "90": "90",
        "180": "180",
        "270": "270",
        "Flipped": "flipped",
        "Flipped90": "flipped-90",
        "Flipped180": "flipped-180",
        "Flipped270": "flipped-270",
    }
    return transforms.get(str(value), "normal")

def _niri_outputs_payload(payload: Dict[str, Any]) -> str:
    outputs = payload.get("outputs") or {}
    settings = payload.get("settings") or {}
    display_name_mode = str(payload.get("displayNameMode") or "")
    if not isinstance(outputs, dict) or not isinstance(settings, dict):
        raise ValueError("Niri outputs and settings must be objects")
    lines = ["// Auto-generated by VGS - do not edit manually", ""]

    def output_sort(item: tuple[str, Any]) -> tuple[float, float, str]:
        name, output = item
        logical = output.get("logical") if isinstance(output, dict) else {}
        logical = logical if isinstance(logical, dict) else {}
        return (
            float(logical.get("x", 0) or 0),
            float(logical.get("y", 0) or 0),
            name,
        )

    for name, raw_output in sorted(outputs.items(), key=output_sort):
        if not isinstance(raw_output, dict):
            raise ValueError(f"invalid output entry: {name}")
        output = raw_output
        output_settings = _niri_output_settings(output, name, settings, display_name_mode)
        identifier = _niri_output_identifier(output, name, display_name_mode)
        lines.append(f"output {json.dumps(identifier)} {{")
        if output_settings.get("disabled"):
            lines.extend(["    off", "}", ""])
            continue
        if output.get("configured_mode"):
            lines.append(f"    mode {json.dumps(str(output['configured_mode']))}")
        else:
            current_mode = output.get("current_mode")
            modes = output.get("modes") or []
            if isinstance(current_mode, int) and 0 <= current_mode < len(modes):
                mode = modes[current_mode]
                if isinstance(mode, dict):
                    refresh = float(mode.get("refresh_rate", 0) or 0) / 1000
                    value = f"{int(mode.get('width', 0))}x{int(mode.get('height', 0))}@{refresh:.3f}"
                    lines.append(f"    mode {json.dumps(value)}")
        logical = output.get("logical")
        if isinstance(logical, dict):
            scale = float(logical.get("scale", 1) or 1)
            if not math.isfinite(scale) or scale <= 0:
                raise ValueError(f"invalid scale for output {name}")
            lines.append(f"    scale {scale:g}")
            transform = logical.get("transform")
            if transform and transform != "Normal":
                lines.append(f"    transform {json.dumps(_niri_transform_name(transform))}")
            if logical.get("x") is not None and logical.get("y") is not None:
                lines.append(f"    position x={int(logical['x'])} y={int(logical['y'])}")
        if output.get("vrr_enabled") or output_settings.get("vrrOnDemand"):
            lines.append("    variable-refresh-rate on-demand=true"
                         if output_settings.get("vrrOnDemand") else "    variable-refresh-rate")
        if output_settings.get("focusAtStartup"):
            lines.append("    focus-at-startup")
        backdrop = output_settings.get("backdropColor")
        if backdrop:
            lines.append(f"    backdrop-color {json.dumps(str(backdrop))}")
        hot_corners = output_settings.get("hotCorners")
        if isinstance(hot_corners, dict):
            if hot_corners.get("off"):
                lines.extend(["    hot-corners {", "        off", "    }"])
            else:
                corners = hot_corners.get("corners") or []
                allowed_corners = {"top-left", "top-right", "bottom-left", "bottom-right"}
                rendered = [str(corner) for corner in corners if str(corner) in allowed_corners]
                if rendered:
                    lines.append("    hot-corners {")
                    lines.extend(f"        {corner}" for corner in rendered)
                    lines.append("    }")
        layout = output_settings.get("layout")
        if isinstance(layout, dict):
            lines.append("    layout {")
            if layout.get("gaps") is not None:
                gaps = runtime().coerce_int(layout["gaps"], 0, 0, 128)
                lines.append(f"        gaps {gaps}")
            default_width = layout.get("defaultColumnWidth")
            if isinstance(default_width, dict) and default_width.get("type") == "proportion":
                value = float(default_width.get("value", 0))
                if not 0 < value <= 1:
                    raise ValueError(f"invalid default column width for output {name}")
                lines.append(f"        default-column-width {{ proportion {value:g}; }}")
            presets = layout.get("presetColumnWidths") or []
            proportions = []
            for preset in presets:
                if not isinstance(preset, dict) or preset.get("type") != "proportion":
                    continue
                value = float(preset.get("value", 0))
                if not 0 < value <= 1:
                    raise ValueError(f"invalid preset column width for output {name}")
                proportions.append(value)
            if proportions:
                lines.append("        preset-column-widths {")
                lines.extend(f"            proportion {value:g}" for value in proportions)
                lines.append("        }")
            if layout.get("alwaysCenterSingleColumn") is not None:
                lines.append("        always-center-single-column"
                             if layout["alwaysCenterSingleColumn"]
                             else "        always-center-single-column false")
            lines.append("    }")
        lines.extend(["}", ""])
    return "\n".join(lines)

def niri_outputs_write(payload: Dict[str, Any]) -> Dict[str, Any]:
    content = _niri_outputs_payload(payload)
    path = niri_config_dir() / "outputs.kdl"
    with niri_config_lock():
        runtime().write_file(path, content)
    return {"ok": True, "path": str(path)}

def niri_outputs_current() -> Dict[str, Any]:
    if not shutil.which("niri") or not os.environ.get("NIRI_SOCKET"):
        return {"ok": False, "error": "niri session unavailable", "outputs": {}}
    proc = runtime().run(["niri", "msg", "-j", "outputs"], timeout=3)
    if proc.returncode != 0:
        return {
            "ok": False,
            "error": (proc.stderr or proc.stdout or "failed to fetch Niri outputs").strip(),
            "outputs": {},
        }
    try:
        outputs = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return {"ok": False, "error": f"invalid Niri outputs response: {exc}", "outputs": {}}
    return {"ok": True, "outputs": outputs}

def niri_validate_config() -> Dict[str, Any]:
    if not shutil.which("niri"):
        return {"ok": False, "error": "niri not found"}
    proc = runtime().run(["niri", "validate"], timeout=10)
    return {
        "ok": proc.returncode == 0,
        "error": (proc.stderr or proc.stdout).strip() if proc.returncode != 0 else "",
    }

def niri_reload_config() -> Dict[str, Any]:
    result = _reload_niri()
    if not result.get("attempted"):
        return {"ok": False, "error": "niri session unavailable"}
    return {
        "ok": bool(result.get("ok")),
        "error": (result.get("stderr") or result.get("stdout") or "").strip(),
    }

def niri_outputs_validate(payload: Dict[str, Any]) -> Dict[str, Any]:
    if not shutil.which("niri"):
        return {"ok": False, "error": "niri not found"}
    content = _niri_outputs_payload(payload)
    directory = niri_config_dir()
    directory.mkdir(parents=True, exist_ok=True)
    path = ""
    try:
        with tempfile.NamedTemporaryFile("w", prefix=".outputs-validate-", suffix=".kdl",
                                         dir=directory, delete=False) as handle:
            handle.write(content)
            path = handle.name
        proc = runtime().run(["niri", "validate", "-c", path], timeout=10)
        return {
            "ok": proc.returncode == 0,
            "error": (proc.stderr or proc.stdout).strip() if proc.returncode != 0 else "",
        }
    finally:
        if path:
            with contextlib.suppress(OSError):
                Path(path).unlink()

def niri_windowrules_state_path() -> Path:
    return runtime().cfg_dir() / "niri-windowrules.json"

def niri_windowrules_path() -> Path:
    return niri_config_dir() / "windowrules.kdl"

def _load_niri_windowrules_state() -> List[Dict[str, Any]]:
    path = niri_windowrules_state_path()
    if not path.is_file():
        managed = niri_windowrules_path()
        if managed.is_file():
            return _parse_simple_niri_rule_nodes(managed)
        return []
    try:
        value = json.loads(path.read_text())
    except Exception as exc:
        raise ValueError(f"cannot read managed Niri window-rule state {path}: {exc}") from exc
    if not isinstance(value, list):
        raise ValueError(f"managed Niri window-rule state is not a list: {path}")
    return value

def _niri_rule_id(rule: Dict[str, Any]) -> str:
    value = str(rule.get("id") or "").strip()
    if re.fullmatch(r"[A-Za-z0-9._-]{1,128}", value):
        return value
    seed = json.dumps(rule, sort_keys=True) + str(time.time_ns())
    return hashlib.sha256(seed.encode()).hexdigest()[:16]

def _niri_match_line(match: Dict[str, Any]) -> str:
    mapping = {
        "appId": "app-id",
        "title": "title",
        "isFloating": "is-floating",
        "isActive": "is-active",
        "isFocused": "is-focused",
        "isActiveInColumn": "is-active-in-column",
        "isWindowCastTarget": "is-window-cast-target",
        "isUrgent": "is-urgent",
        "atStartup": "at-startup",
    }
    parts = []
    for source, target in mapping.items():
        if source not in match:
            continue
        value = match[source]
        if isinstance(value, bool):
            parts.append(f"{target}={_kdl_bool(value)}")
        elif value is not None and str(value) != "":
            parts.append(f"{target}={json.dumps(str(value))}")
    return "    match " + " ".join(parts) if parts else ""

def _niri_size_rule(name: str, value: Any) -> str:
    raw = str(value).strip()
    match = re.fullmatch(r"(fixed|proportion)\s+(-?(?:\d+(?:\.\d*)?|\.\d+))", raw)
    if match:
        kind, numeric = match.group(1), float(match.group(2))
        if (kind == "fixed" and numeric >= 0) or (kind == "proportion" and 0 < numeric <= 1):
            return f"    {name} {{ {kind} {match.group(2)}; }}"
    if re.fullmatch(r"\d+", raw):
        return f"    {name} {{ fixed {raw}; }}"
    raise ValueError(f"invalid {name}: {value}")

def _format_niri_windowrule(rule: Dict[str, Any]) -> str:
    rule_id = _niri_rule_id(rule)
    name = str(rule.get("name") or "Rule").replace("\n", " ")
    lines = [f"// @id={rule_id} @name={name}", "window-rule {"]
    matches = rule.get("matches") or [rule.get("matchCriteria") or {}]
    for match in matches:
        if isinstance(match, dict):
            line = _niri_match_line(match)
            if line:
                lines.append(line)
    actions = rule.get("actions") or {}
    scalar = {
        "opacity": "opacity",
        "openFloating": "open-floating",
        "openMaximized": "open-maximized",
        "openMaximizedToEdges": "open-maximized-to-edges",
        "openFullscreen": "open-fullscreen",
        "openFocused": "open-focused",
        "openOnOutput": "open-on-output",
        "openOnWorkspace": "open-on-workspace",
        "variableRefreshRate": "variable-refresh-rate",
        "blockOutFrom": "block-out-from",
        "defaultColumnDisplay": "default-column-display",
        "scrollFactor": "scroll-factor",
        "cornerRadius": "geometry-corner-radius",
        "clipToGeometry": "clip-to-geometry",
        "tiledState": "tiled-state",
        "minWidth": "min-width",
        "maxWidth": "max-width",
        "minHeight": "min-height",
        "maxHeight": "max-height",
        "drawBorderWithBackground": "draw-border-with-background",
    }
    for source, target in scalar.items():
        if source not in actions:
            continue
        value = actions[source]
        if isinstance(value, bool):
            rendered = _kdl_bool(value)
        elif isinstance(value, (int, float)):
            rendered = str(value)
        else:
            rendered = json.dumps(str(value))
        lines.append(f"    {target} {rendered}")
    if actions.get("defaultColumnWidth"):
        lines.append(_niri_size_rule("default-column-width", actions["defaultColumnWidth"]))
    if actions.get("defaultWindowHeight"):
        lines.append(_niri_size_rule("default-window-height", actions["defaultWindowHeight"]))
    if "defaultFloatingX" in actions and "defaultFloatingY" in actions:
        line = f"    default-floating-position x={int(actions['defaultFloatingX'])} y={int(actions['defaultFloatingY'])}"
        if actions.get("defaultFloatingRelativeTo"):
            line += " relative-to=" + json.dumps(str(actions["defaultFloatingRelativeTo"]))
        lines.append(line)
    lines.append("}")
    return "\n".join(lines)

def _save_niri_windowrules(rules: List[Dict[str, Any]]) -> Dict[str, Any]:
    normalized = []
    for item in rules:
        if not isinstance(item, dict):
            continue
        rule = json.loads(json.dumps(item))
        rule["id"] = _niri_rule_id(rule)
        rule["source"] = str(niri_windowrules_path())
        normalized.append(rule)
    state_path = niri_windowrules_state_path()
    runtime().write_file(state_path, json.dumps(normalized, indent=2) + "\n")
    content = "\n".join([
        "// VGS Window Rules - managed by VGS Settings.",
        "// Do not edit manually; use the Settings window-rules editor.",
        "",
        *[formatted for rule in normalized for formatted in (_format_niri_windowrule(rule), "")],
    ])
    runtime().write_file(niri_windowrules_path(), content)
    reload_result = _reload_niri()
    return {
        "ok": not reload_result.get("attempted") or bool(reload_result.get("ok")),
        "rules": normalized,
        "reload": reload_result,
    }

def _parse_simple_niri_rule_nodes(path: Path) -> List[Dict[str, Any]]:
    if not path.is_file():
        return []
    text = path.read_text(errors="replace")
    rules = []
    pending_id = ""
    pending_name = ""
    cursor = 0
    rule_index = 0
    pattern = re.compile(r"(?m)(?://\s*@id=([^\s]+)\s+@name=([^\n]+)\s*)?window-rule\s*\{")
    while True:
        match = pattern.search(text, cursor)
        if not match:
            break
        opening = text.find("{", match.start())
        closing = _kdl_matching_brace(text, opening)
        if closing < 0:
            break
        pending_id = match.group(1) or hashlib.sha256(f"{path}:{rule_index}".encode()).hexdigest()[:16]
        pending_name = (match.group(2) or f"Rule {rule_index + 1}").strip()
        body = text[opening + 1:closing]
        matches = []
        for match_node in re.finditer(r"(?m)^\s*match\s+([^\n;{}]+)", body):
            props = {}
            reverse = {
                "app-id": "appId", "title": "title", "is-floating": "isFloating",
                "is-active": "isActive", "is-focused": "isFocused",
                "is-active-in-column": "isActiveInColumn",
                "is-window-cast-target": "isWindowCastTarget",
                "is-urgent": "isUrgent", "at-startup": "atStartup",
            }
            for prop in re.finditer(r'([\w-]+)=("(?:\\.|[^"])*"|[^\s]+)', match_node.group(1)):
                if prop.group(1) not in reverse:
                    continue
                raw = prop.group(2)
                value: Any = raw == "true" if raw in {"true", "false"} else _kdl_unquote(raw)
                props[reverse[prop.group(1)]] = value
            if props:
                matches.append(props)
        actions: Dict[str, Any] = {}
        reverse_actions = {
            "opacity": "opacity", "open-floating": "openFloating",
            "open-maximized": "openMaximized", "open-maximized-to-edges": "openMaximizedToEdges",
            "open-fullscreen": "openFullscreen", "open-focused": "openFocused",
            "open-on-output": "openOnOutput", "open-on-workspace": "openOnWorkspace",
            "variable-refresh-rate": "variableRefreshRate", "block-out-from": "blockOutFrom",
            "default-column-display": "defaultColumnDisplay", "scroll-factor": "scrollFactor",
            "geometry-corner-radius": "cornerRadius", "clip-to-geometry": "clipToGeometry",
            "tiled-state": "tiledState", "min-width": "minWidth", "max-width": "maxWidth",
            "min-height": "minHeight", "max-height": "maxHeight",
            "draw-border-with-background": "drawBorderWithBackground",
        }
        for action_match in re.finditer(r"(?m)^\s*([\w-]+)\s+([^\n;{}]+)", body):
            key = reverse_actions.get(action_match.group(1))
            if not key:
                continue
            raw = action_match.group(2).strip()
            if raw in {"true", "false"}:
                value = raw == "true"
            elif re.fullmatch(r"-?\d+", raw):
                value = int(raw)
            elif re.fullmatch(r"-?(?:\d+\.\d*|\d*\.\d+)", raw):
                value = float(raw)
            else:
                value = _kdl_unquote(raw)
            actions[key] = value
        for header, nested_body, _comment in _kdl_nodes_in_block(body):
            node_name = header.split(None, 1)[0] if header else ""
            if node_name not in {"default-column-width", "default-window-height"}:
                continue
            size_match = re.search(r"\b(fixed|proportion)\s+(-?(?:\d+(?:\.\d*)?|\.\d+))", nested_body)
            if size_match:
                target = "defaultColumnWidth" if node_name == "default-column-width" else "defaultWindowHeight"
                actions[target] = size_match.group(1) + " " + size_match.group(2)
        floating = re.search(r"(?m)^\s*default-floating-position\s+([^\n;{}]+)", body)
        if floating:
            properties = dict(re.findall(r'([\w-]+)=("(?:\\.|[^"])*"|[^\s]+)', floating.group(1)))
            try:
                if "x" in properties and "y" in properties:
                    actions["defaultFloatingX"] = int(properties["x"])
                    actions["defaultFloatingY"] = int(properties["y"])
            except ValueError:
                pass
            if "relative-to" in properties:
                actions["defaultFloatingRelativeTo"] = _kdl_unquote(properties["relative-to"])
        rule = {
            "id": pending_id,
            "name": pending_name,
            "matchCriteria": matches[0] if matches else {},
            "matches": matches,
            "actions": actions,
            "enabled": True,
            "source": str(path),
        }
        rules.append(rule)
        rule_index += 1
        cursor = closing + 1
    return rules

def niri_windowrules_json() -> Dict[str, Any]:
    main = runtime().home() / ".config" / "niri" / "config.kdl"
    managed = niri_windowrules_path()
    files = _niri_config_files(main)
    if managed.is_file() and managed.resolve() not in {path.resolve() for path in files}:
        files.append(managed)
    rules = []
    for path in files:
        if path.resolve() == managed.resolve():
            managed_rules = _load_niri_windowrules_state()
            for rule in managed_rules:
                item = json.loads(json.dumps(rule))
                item["source"] = str(managed)
                rules.append(item)
        else:
            rules.extend(_parse_simple_niri_rule_nodes(path))
    included = bool(niri_include_status("windowrules.kdl").get("included"))
    return {
        "rules": rules,
        "vgsStatus": {
            "exists": managed.is_file(),
            "included": included,
            "configFormat": "kdl",
            "readOnly": False,
        },
    }

def niri_windowrule_add(rule: Dict[str, Any]) -> Dict[str, Any]:
    with niri_config_lock():
        rules = _load_niri_windowrules_state()
        rule = dict(rule)
        rule["id"] = _niri_rule_id(rule)
        rules.append(rule)
        return _save_niri_windowrules(rules)

def niri_windowrule_update(rule_id: str, replacement: Dict[str, Any]) -> Dict[str, Any]:
    with niri_config_lock():
        rules = _load_niri_windowrules_state()
        found = False
        for index, rule in enumerate(rules):
            if str(rule.get("id")) == rule_id:
                replacement = dict(replacement)
                replacement["id"] = rule_id
                rules[index] = replacement
                found = True
                break
        if not found:
            return {"ok": False, "error": "rule not found"}
        return _save_niri_windowrules(rules)

def niri_windowrule_remove(rule_id: str) -> Dict[str, Any]:
    with niri_config_lock():
        rules = _load_niri_windowrules_state()
        filtered = [rule for rule in rules if str(rule.get("id")) != rule_id]
        if len(filtered) == len(rules):
            return {"ok": False, "error": "rule not found"}
        return _save_niri_windowrules(filtered)

def niri_windowrule_reorder(rule_ids: List[Any]) -> Dict[str, Any]:
    with niri_config_lock():
        rules = _load_niri_windowrules_state()
        by_id = {str(rule.get("id")): rule for rule in rules}
        ordered = [by_id.pop(str(rule_id)) for rule_id in rule_ids if str(rule_id) in by_id]
        ordered.extend(rule for rule in rules if str(rule.get("id")) in by_id)
        return _save_niri_windowrules(ordered)

def niri_greeter_config(qs_cmd: str) -> str:
    command = qs_cmd + "; niri msg action quit --skip-confirmation"
    return (
        "// Generated transiently by VGS for greetd.\n"
        "hotkey-overlay { skip-at-startup; }\n"
        "prefer-no-csd\n"
        "spawn-at-startup \"sh\" \"-lc\" " + json.dumps(command) + "\n"
    )
