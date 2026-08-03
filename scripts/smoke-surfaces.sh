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

cleanup() {
  "$vshell_bin" ipc call capture close >/dev/null 2>&1 || true
  "$vshell_bin" ipc call powermenu close >/dev/null 2>&1 || true
  "$vshell_bin" ipc call vshell-menu close >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$vshell_bin" ipc call capture open >/dev/null
sleep 0.35
assert_content_sized_layer "vshell:capture"
assert_layer_present "vshell:capture:clickcatcher"
"$vshell_bin" ipc call capture close >/dev/null

"$vshell_bin" ipc call powermenu open >/dev/null
sleep 0.35
assert_content_sized_layer "vshell:power-menu"
assert_layer_present "vshell:power-menu:clickcatcher"
"$vshell_bin" ipc call powermenu close >/dev/null

"$vshell_bin" ipc call vshell-menu open >/dev/null
sleep 0.35
assert_content_sized_layer "vshell:vgs-menu"
assert_layer_present "vshell:vgs-menu:clickcatcher"
"$vshell_bin" ipc call vshell-menu close >/dev/null

echo "surface smoke passed"
