#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
vshell_bin="$repo_root/bin/vshell"

if ! command -v hyprctl >/dev/null 2>&1 || [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  echo "surface smoke skipped: Hyprland session not available"
  exit 0
fi

snapshot_layers() {
  hyprctl layers -j
}

assert_layer_present() {
  local namespace="$1"
  local layers_json
  layers_json="$(snapshot_layers)"
  LAYERS_JSON="$layers_json" python3 - "$namespace" <<'PY'
import json
import os
import sys

namespace = sys.argv[1]
data = json.loads(os.environ["LAYERS_JSON"])
found = False
for monitor in data.values():
    for level in (monitor.get("levels") or {}).values():
        for layer in level:
            if layer.get("namespace") == namespace:
                found = True
if not found:
    raise SystemExit(f"missing layer namespace: {namespace}")
PY
}

assert_layer_absent() {
  local namespace="$1"
  local layers_json
  layers_json="$(snapshot_layers)"
  LAYERS_JSON="$layers_json" python3 - "$namespace" <<'PY'
import json
import os
import sys

namespace = sys.argv[1]
data = json.loads(os.environ["LAYERS_JSON"])
for monitor in data.values():
    for level in (monitor.get("levels") or {}).values():
        for layer in level:
            if layer.get("namespace") == namespace:
                raise SystemExit(f"unexpected layer namespace: {namespace}")
PY
}

assert_content_sized_layer() {
  local namespace="$1"
  local layers_json
  layers_json="$(snapshot_layers)"
  LAYERS_JSON="$layers_json" python3 - "$namespace" <<'PY'
import json
import os
import sys

namespace = sys.argv[1]
data = json.loads(os.environ["LAYERS_JSON"])
matches = []
for monitor_name, monitor in data.items():
    layers = []
    for level in (monitor.get("levels") or {}).values():
        layers.extend(level)
    monitor_w = max((int(layer.get("w") or 0) for layer in layers), default=0)
    monitor_h = max((int(layer.get("h") or 0) for layer in layers), default=0)
    for layer in layers:
        if layer.get("namespace") == namespace:
            matches.append((monitor_name, monitor_w, monitor_h, int(layer.get("w") or 0), int(layer.get("h") or 0)))

if not matches:
    raise SystemExit(f"missing layer namespace: {namespace}")

for monitor_name, monitor_w, monitor_h, layer_w, layer_h in matches:
    if monitor_w > 0 and monitor_h > 0 and layer_w >= monitor_w and layer_h >= monitor_h:
        raise SystemExit(f"{namespace} is fullscreen on {monitor_name}: {layer_w}x{layer_h}")
PY
}

# Every assertion below drives the live shell through `vshell ipc`, which
# resolves instances by *this* checkout's config path. Run from a worktree while
# the session's shell belongs to another checkout, every call fails — and with
# stdout discarded and `set -e` in force, the script used to abort with no
# output whatsoever, which is indistinguishable from a clean pass (VGS-69).
#
# `vshell instances list` cannot tell those cases apart either: it applies the
# same per-checkout filter, so "no VGS shell at all" and "a VGS shell owned by
# somebody else" both come back empty. The registry is read directly and
# classified here instead. No shell is a skip; a foreign shell is a failure,
# because the requested assertions did not run.
require_own_shell() {
  local listing verdict rc=0

  if ! command -v qs >/dev/null 2>&1; then
    echo "surface smoke skipped: quickshell CLI (qs) not found, no instance registry to consult"
    exit 0
  fi
  listing="$(qs list --all --json 2>&1)" || {
    rc=$?
    {
      echo "surface smoke FAILED: could not read the Quickshell instance registry (qs list exited $rc)"
      printf '%s\n' "$listing"
    } >&2
    exit 1
  }

  rc=0
  verdict="$(QS_LISTING="$listing" python3 - "$repo_root/quickshell/vshell" <<'PY'
import json
import os
import sys
from pathlib import Path


def resolve(value):
    try:
        return Path(value).resolve()
    except OSError:
        return Path(value)


want = resolve(sys.argv[1])
try:
    data = json.loads(os.environ["QS_LISTING"] or "[]")
except json.JSONDecodeError as exc:
    print(f"unparsable qs list output: {exc}", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(data, list):
    print("unexpected qs list output", file=sys.stderr)
    raise SystemExit(2)

foreign = []
for entry in data:
    if not isinstance(entry, dict):
        continue
    raw = str(entry.get("config_path") or "")
    if not raw:
        continue
    path = resolve(raw)
    if path.name == "shell.qml":
        path = path.parent
    # A VGS runtime tree, in any checkout: <root>/quickshell/vshell. Unrelated
    # Quickshell shells on the same seat are none of this script's business.
    if path.parts[-2:] != ("quickshell", "vshell"):
        continue
    try:
        pid = int(entry.get("pid") or 0)
    except (TypeError, ValueError):
        continue
    # A registry entry outliving its process must not fail the run.
    if pid <= 0 or not Path(f"/proc/{pid}").exists():
        continue
    if path == want:
        raise SystemExit(0)
    foreign.append((pid, str(path.parent.parent)))

if not foreign:
    raise SystemExit(10)
for pid, root in sorted(foreign):
    print(f"{root} (pid {pid})")
raise SystemExit(11)
PY
  )" || rc=$?

  case "$rc" in
    0) return 0 ;;
    10)
      echo "surface smoke skipped: no live VGS shell on this session"
      exit 0
      ;;
    11)
      {
        echo "surface smoke FAILED: the live VGS shell belongs to a different checkout"
        while IFS= read -r line; do
          [[ -n "$line" ]] && echo "  running shell: $line"
        done <<<"$verdict"
        echo "  this run:      $repo_root"
        echo "  vshell ipc resolves instances by this checkout's config path, so none of the"
        echo "  surface assertions can reach that shell. Run the smoke from the checkout above."
      } >&2
      exit 1
      ;;
    *)
      echo "surface smoke FAILED: could not classify the instance registry (classifier exit $rc)" >&2
      exit 1
      ;;
  esac
}

# Runs before the cleanup trap is installed: a refused precondition must not
# poke the live session on its way out.
require_own_shell

# `vshell ipc` prints its diagnostics on stderr, so the reason survives; what
# used to be lost was this script discarding stdout and never reporting the
# non-zero status at all.
ipc_call() {
  local out rc=0
  out="$("$vshell_bin" ipc call "$@" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    {
      echo "surface smoke FAILED: vshell ipc call $* exited $rc"
      printf '%s\n' "$out"
    } >&2
    exit 1
  fi
}

cleanup() {
  "$vshell_bin" ipc call capture close >/dev/null 2>&1 || true
  "$vshell_bin" ipc call powermenu close >/dev/null 2>&1 || true
  "$vshell_bin" ipc call vshell-menu close >/dev/null 2>&1 || true
}
trap cleanup EXIT

ipc_call capture open
sleep 0.35
assert_content_sized_layer "vshell:capture"
assert_layer_present "vshell:capture:clickcatcher"
ipc_call capture close

ipc_call powermenu open
sleep 0.35
assert_content_sized_layer "vshell:power-menu"
assert_layer_present "vshell:power-menu:clickcatcher"
ipc_call powermenu close

ipc_call vshell-menu open
sleep 0.35
assert_content_sized_layer "vshell:vgs-menu"
assert_layer_present "vshell:vgs-menu:clickcatcher"
ipc_call vshell-menu close

echo "surface smoke passed"
