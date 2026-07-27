#!/usr/bin/env python3
"""VGS backend method inventory + apiVersion-gate guard.

Enforces the boundary between the QML backend client (VGSBackendService and its
callers) and the Go backend daemon, using docs/architecture/backend-methods.json
as the source of truth.

Fails (exit 1) when:
  - QML references a backend method that maps to no documented capability prefix
    and no 'excluded' prefix (an undocumented method with no plan);
  - the number of raw numeric `.apiVersion <op> N` gates in QML exceeds the
    manifest baseline (gates must only shrink as they convert to capability /
    method predicates);
  - (when backend/ exists) a Go handler registers a method that maps to no
    documented capability and is not excluded.

Reports (non-fatal):
  - 'excluded' methods still referenced from QML (dead surface to remove);
  - documented capabilities with no QML caller and no Go handler yet.

This runs with no third-party dependencies and works before backend/ exists.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(os.environ.get("VGS_INVENTORY_REPO_ROOT", Path(__file__).resolve().parents[1]))
QML_ROOT = REPO_ROOT / "quickshell" / "vshell"
BACKEND_ROOT = REPO_ROOT / "backend"
MANIFEST = REPO_ROOT / "docs" / "architecture" / "backend-methods.json"

# Callsites are scoped to the VGS backend daemon only. Other singletons (e.g.
# CalendarBackend's separate dcal socket) also have a sendRequest(), so outside
# VGSBackendService.qml we require the explicit VGSBackendService. receiver.
BACKEND_SINGLETON = "Services/VGSBackendService.qml"
CALLSITE_INTERNAL_RE = re.compile(r'\bsendRequest\(\s*"([a-zA-Z0-9._]+)"')
CALLSITE_EXTERNAL_RE = re.compile(r'VGSBackendService\.sendRequest\(\s*"([a-zA-Z0-9._]+)"')
# raw numeric apiVersion gate, e.g. .apiVersion >= 7  (named constants excluded)
APIGATE_RE = re.compile(r'\.apiVersion\s*(?:>=|>|<=|<|===|!==|==)\s*[0-9]+')
# Best-effort Go route registration, e.g. Register("network", "network.getState", ...)
# or Handle("cups.getPrinters", ...).
GO_SERVER_REGISTER_RE = re.compile(r'\.Register\(\s*"[^"]+"\s*,\s*"([a-zA-Z0-9._]+)"')
GO_ROUTE_RE = re.compile(r'(?:register|Register|Handle|handle|route|Route)\(\s*"([a-zA-Z0-9._]+)"')
# Loop registrations: handler maps (`map[string]server.HandlerFunc{ "m": h, ... }`)
# and method-name slices (`methods = []string{ "m", ... }`) whose entries are
# passed to Register via a variable, invisible to the literal-argument regexes.
GO_METHOD_BLOCK_RE = re.compile(r'map\[string\][\w.]*HandlerFunc\s*\{|methods\s*=\s*\[\]string\s*\{')
GO_METHOD_ENTRY_RE = re.compile(r'^\s*"([a-zA-Z0-9._]+)"\s*[:,]')


def load_manifest() -> dict:
    with MANIFEST.open() as f:
        return json.load(f)


def qml_files() -> list[Path]:
    return sorted(QML_ROOT.rglob("*.qml"))


def collect_qml_methods() -> dict[str, list[str]]:
    methods: dict[str, list[str]] = {}
    for path in qml_files():
        rel = str(path.relative_to(REPO_ROOT))
        text = path.read_text(encoding="utf-8", errors="replace")
        regex = CALLSITE_INTERNAL_RE if rel.endswith(BACKEND_SINGLETON) else CALLSITE_EXTERNAL_RE
        for m in regex.findall(text):
            methods.setdefault(m, [])
            if rel not in methods[m]:
                methods[m].append(rel)
    return methods


def collect_apiversion_gates() -> list[tuple[str, int]]:
    hits: list[tuple[str, int]] = []
    for path in qml_files():
        rel = str(path.relative_to(REPO_ROOT))
        for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if APIGATE_RE.search(line):
                hits.append((rel, i))
    return hits


def collect_go_methods() -> dict[str, list[str]]:
    methods: dict[str, list[str]] = {}
    if not BACKEND_ROOT.is_dir():
        return methods
    for path in sorted(BACKEND_ROOT.rglob("*.go")):
        rel = str(path.relative_to(REPO_ROOT))
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in GO_SERVER_REGISTER_RE.findall(text):
            methods.setdefault(m, [])
            if rel not in methods[m]:
                methods[m].append(rel)
        for m in GO_ROUTE_RE.findall(text):
            if "." not in m and m not in {"ping", "subscribe", "getServerInfo"}:
                continue
            methods.setdefault(m, [])
            if rel not in methods[m]:
                methods[m].append(rel)
        for m in collect_block_methods(text):
            methods.setdefault(m, [])
            if rel not in methods[m]:
                methods[m].append(rel)
    return methods


def collect_block_methods(text: str) -> list[str]:
    out: list[str] = []
    in_block = False
    for line in text.splitlines():
        if not in_block:
            if GO_METHOD_BLOCK_RE.search(line):
                in_block = True
            continue
        if line.strip().startswith("}"):
            in_block = False
            continue
        m = GO_METHOD_ENTRY_RE.match(line)
        if m and "." in m.group(1):
            out.append(m.group(1))
    return out


def qml_text(rel: str) -> str:
    return (REPO_ROOT / rel).read_text(encoding="utf-8", errors="replace")


def match_prefix(method: str, prefixes: list[str]) -> bool:
    for p in prefixes:
        # prefixes ending in '.' are namespace matches; others are exact/prefix
        if p.endswith(".") and method.startswith(p):
            return True
        if method == p or method.startswith(p):
            return True
    return False


def capability_for(method: str, caps: list[dict]) -> dict | None:
    best = None
    best_len = -1
    for cap in caps:
        for p in cap["prefixes"]:
            if (p.endswith(".") and method.startswith(p)) or method == p or method.startswith(p):
                if len(p) > best_len:
                    best, best_len = cap, len(p)
    return best


def excluded_for(method: str, excluded: list[dict]) -> dict | None:
    for ex in excluded:
        if match_prefix(method, ex["prefixes"]):
            return ex
    return None


def main() -> int:
    manifest = load_manifest()
    caps = manifest["capabilities"]
    excluded = manifest["excluded"]
    baseline = int(manifest["apiVersionGateBaseline"])

    qml_methods = collect_qml_methods()
    go_methods = collect_go_methods()
    gates = collect_apiversion_gates()

    errors: list[str] = []
    warnings: list[str] = []

    # 1. Every QML-referenced method must be documented or explicitly excluded.
    dead_referenced: list[str] = []
    for method, files in sorted(qml_methods.items()):
        ex = excluded_for(method, excluded)
        if ex is not None:
            dead_referenced.append(method)
            continue
        if capability_for(method, caps) is None:
            errors.append(
                f"UNDOCUMENTED backend method '{method}' referenced in "
                f"{', '.join(files)} — add it to a capability prefix in "
                f"backend-methods.json or mark it excluded with a removal action."
            )

    # 2. apiVersion gate ceiling.
    if len(gates) > baseline:
        errors.append(
            f"raw apiVersion numeric gates increased to {len(gates)} "
            f"(baseline {baseline}). Gates must only shrink — convert to "
            f"capabilities.includes(...) / methods.includes(...) predicates. "
            f"New gate sites:\n    "
            + "\n    ".join(f"{f}:{ln}" for f, ln in gates[baseline:])
        )

    # 3. Go handlers (when present) must map to a documented capability.
    for method, files in sorted(go_methods.items()):
        if excluded_for(method, excluded) is not None:
            errors.append(
                f"Go backend registers EXCLUDED method '{method}' in "
                f"{', '.join(files)} — excluded methods must not be implemented."
            )
        elif capability_for(method, caps) is None:
            errors.append(
                f"Go backend registers UNDOCUMENTED method '{method}' in "
                f"{', '.join(files)} — add its capability to backend-methods.json."
            )

    # 4. Ownership contracts that have regressed before.
    tailscale_plugin = qml_text("config/vshell/plugins/tailscale/TailscaleWidget.qml")
    forbidden_tailscale = [
        'command: ["tailscale"',
        'Quickshell.execDetached(["tailscale"',
        'tailscale status',
        'tailscale debug',
    ]
    for needle in forbidden_tailscale:
        if needle in tailscale_plugin:
            errors.append(
                "bundled Tailscale plugin must use TailscaleService/backend, "
                f"but still contains {needle!r}."
            )

    sysupdate_plugin = qml_text("config/vshell/plugins/sysUpdate/SysUpdateWidget.qml")
    if "Ref {" not in sysupdate_plugin or "service: SystemUpdateService" not in sysupdate_plugin:
        errors.append("bundled sysUpdate plugin must hold a SystemUpdateService ref.")
    if "running: !root.useBackend" not in sysupdate_plugin:
        errors.append("bundled sysUpdate plugin fallback poll timer must be disabled when backend is present.")

    vgsipc = qml_text("quickshell/vshell/VGSIPC.qml")
    if 'getPreferredBar("systemUpdateButtonRef")' in vgsipc:
        errors.append("systemupdater IPC must open through PopoutService, not a preferred bar widget ref.")

    backend_qml = qml_text("quickshell/vshell/Services/VGSBackendService.qml")
    if 'log.debug("Request socket <<", line)' in backend_qml or 'log.debug("Subscribe socket <<", line)' in backend_qml:
        errors.append("VGSBackendService must not log raw backend frames.")

    # Non-fatal: excluded surface still referenced from QML.
    for method in dead_referenced:
        ex = excluded_for(method, excluded)
        warnings.append(f"excluded method still referenced from QML: '{method}' — {ex['action']}")

    # Non-fatal: documented capabilities with no caller and no handler.
    called_prefixes = set()
    for method in list(qml_methods) + list(go_methods):
        cap = capability_for(method, caps)
        if cap:
            called_prefixes.add(cap["name"])
    for cap in caps:
        if cap["name"] not in called_prefixes:
            warnings.append(
                f"capability '{cap['name']}' (phase {cap['phase']}) has no QML caller "
                f"or Go handler yet — expected until its phase lands."
            )

    print(f"backend inventory: {len(qml_methods)} distinct QML backend methods, "
          f"{len(go_methods)} Go handler methods, {len(gates)} apiVersion gates "
          f"(baseline {baseline}).")
    for w in warnings:
        print(f"  note: {w}")
    if errors:
        print("\nbackend inventory FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print("backend inventory checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
