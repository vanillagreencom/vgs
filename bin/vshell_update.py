"""VGS system and tool updates: counting and running.

Imported by bin/vshell-helper, never run. `vshell update run <mode>` is the
only implementation of how each source upgrades; the backend daemon supervises
it in a terminal and the bar widget spawns it when the daemon is absent.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List

import vshell_mise as mise
from vshell_mise import DevToolsRuntime

RT: DevToolsRuntime


def configure(runtime: DevToolsRuntime) -> None:
    global RT
    RT = runtime
    mise.configure(runtime)


def tools_rows() -> Dict[str, Any]:
    """The mise part of a count: rows, count, and the probe error if any."""
    if not RT.command_exists("mise"):
        return {"tools": 0, "rows": [], "source": "", "error": ""}
    rows, error = mise.mise_outdated()
    return {"tools": len(rows), "source": "mise outdated", "error": error,
            "rows": [{"name": r["name"], "old": r["current"], "new": r["latest"], "src": "tools"} for r in rows]}


def update_count() -> Dict[str, Any]:
    tools = tools_rows()
    for probe in ("pacman", "checkupdates"):
        if not RT.command_exists(probe):
            # No repo counter, but mise alone is still a count worth showing.
            return {"ok": bool(tools["source"]), "error": f"{probe} not found", "repo": 0, "aur": 0,
                    "tools": tools["tools"], "packages": tools["rows"], "orphanCount": 0, "orphans": [],
                    "source": {"repo": "", "aur": "", "tools": tools["source"]}, "checkedAt": int(time.time()),
                    **({"toolsError": tools["error"]} if tools["error"] else {})}
    lock = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "vshell-update-count.lock"
    script = r'''
set -u
exec 9>"$1"
flock -w 120 9 2>/dev/null || true
repo_lines=""
aur_lines=""
if command -v checkupdates >/dev/null 2>&1; then repo_lines=$(checkupdates 2>/dev/null || true); fi
if command -v paru >/dev/null 2>&1; then aur_lines=$(paru -Qua 2>/dev/null || true); fi
repo=$(printf '%s' "$repo_lines" | grep -c . || true)
aur=$(printf '%s' "$aur_lines" | grep -c . || true)
emit() { src="$1"; while read -r name old arrow new rest; do [ -n "$name" ] || continue; jq -cn --arg name "$name" --arg old "$old" --arg new "$new" --arg src "$src" '{name:$name,old:$old,new:$new,src:$src}'; done; }
pkgs=$( { printf '%s\n' "$repo_lines" | emit repo; printf '%s\n' "$aur_lines" | emit aur; } | jq -s . )
orphan_lines=$(pacman -Qtd 2>/dev/null || true)
orphan=$(printf '%s' "$orphan_lines" | grep -c . || true)
orphans=$(printf '%s\n' "$orphan_lines" | while read -r name ver rest; do [ -n "$name" ] || continue; jq -cn --arg name "$name" --arg ver "$ver" '{name:$name,ver:$ver}'; done | jq -s .)
jq -cn --argjson repo "${repo:-0}" --argjson aur "${aur:-0}" --argjson packages "$pkgs" --argjson orphanCount "${orphan:-0}" --argjson orphans "$orphans" '{ok:true,repo:$repo,aur:$aur,packages:$packages,orphanCount:$orphanCount,orphans:$orphans}'
'''
    proc = subprocess.run(["bash", "-lc", script, "bash", str(lock)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    # Metadata surfaced to the UI so it can show data provenance/freshness without
    # opening code. Backward-compatible additions; existing keys stay unchanged.
    meta = {"source": {"repo": "checkupdates", "aur": "paru -Qua"}, "checkedAt": int(time.time())}
    if proc.returncode != 0:
        return {"ok": False, "error": proc.stderr.strip() or "update count failed", "repo": 0, "aur": 0, "packages": [], "orphanCount": 0, "orphans": [], **meta}
    try:
        data = json.loads(proc.stdout or "{}")
    except Exception:
        return {"ok": False, "error": "parse error", "repo": 0, "aur": 0, "packages": [], "orphanCount": 0, "orphans": [], **meta}
    if isinstance(data, dict):
        data.setdefault("source", meta["source"])
        data.setdefault("checkedAt", meta["checkedAt"])
        data["tools"] = tools["tools"]
        data["packages"] = list(data.get("packages") or []) + tools["rows"]
        data["source"]["tools"] = tools["source"]
        if tools["error"]:
            data["toolsError"] = tools["error"]
    return data


# `vshell update run` is the one place that knows how to upgrade each source.
# The backend daemon supervises it in a terminal; the bar widget and the VGS
# menu spawn it directly when the daemon is absent. Order mirrors the risk:
# system packages first, then AUR, Flatpak, and last the user-level mise
# tools, which need no sudo and never touch the distribution.
UPDATE_MODES = {"system", "aur", "flatpak", "tools", "all"}


def update_steps(mode: str) -> List[Dict[str, Any]]:
    steps: List[Dict[str, Any]] = []
    everything = mode == "all"
    if mode == "system" or everything:
        if RT.command_exists("pacman"):
            steps.append({"title": "Updating repo packages", "argv": ["sudo", "pacman", "-Syu"]})
        elif not everything:
            RT.eprint("pacman not found")
    if mode == "aur" or everything:
        if RT.command_exists("paru"):
            steps.append({"title": "Updating AUR packages", "argv": ["paru", "-Sua"]})
        elif not everything:
            RT.eprint("paru not found")
    if mode == "flatpak" or everything:
        if RT.command_exists("flatpak"):
            steps.append({"title": "Updating Flatpak apps", "argv": ["flatpak", "update", "-y"]})
        elif not everything:
            RT.eprint("flatpak not found")
    if mode == "tools" or everything:
        if RT.command_exists("mise"):
            # Stubs are rewritten after every tools update so a template change
            # reaches machines that already have them, without a migration.
            steps.append({"title": "Updating mise tools (agents, toolchains)", "argv": ["mise", "up"],
                          "env": mise.mise_env(), "cwd": str(RT.home()), "after": [mise.mise_refresh]})
        elif not everything:
            RT.eprint("mise not found")
    return steps


def cmd_update(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(prog="vshell update")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_count = sub.add_parser("count")
    p_count.add_argument("--json", action="store_true")
    p_run = sub.add_parser("run")
    p_run.add_argument("mode", choices=sorted(UPDATE_MODES))
    args = parser.parse_args(argv)
    if args.cmd == "count":
        data = update_count()
        print(json.dumps(data, indent=2) if args.json else str((data.get("repo") or 0) + (data.get("aur") or 0) + (data.get("tools") or 0)))
        if data.get("toolsError"):
            RT.eprint(f"tools count unavailable: {data['toolsError']}")
        return 0 if data.get("ok", True) and not data.get("toolsError") else 1
    if args.cmd == "run":
        steps = update_steps(args.mode)
        if not steps:
            RT.eprint("nothing to update: no supported updater is installed" if args.mode == "all" else f"{args.mode}: updater not installed")
            return 1
        failures = 0
        for step in steps:
            print(f":: {step['title']}")
            failures += 0 if subprocess.run(step["argv"], check=False, env=step.get("env"), cwd=step.get("cwd")).returncode == 0 else 1
            for after in step.get("after") or ():
                try:
                    after()
                except OSError as exc:
                    RT.eprint(f"{step['title']}: follow-up failed: {exc}")
                    failures += 1
        try:
            input(("Failed — press Enter to close…" if failures else "Done — press Enter to close…"))
        except EOFError:
            pass
        return 1 if failures else 0
    return 2
