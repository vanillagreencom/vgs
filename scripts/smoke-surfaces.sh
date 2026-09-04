#!/usr/bin/env bash
# Exercise live Hyprland surfaces. Exit 77 means prerequisites were absent and no assertions ran.
# A shell owned by another checkout fails because this checkout cannot safely address it.
# Branch coverage: scripts/test-smoke-surfaces.sh.
set -euo pipefail


readonly SKIP_STATUS=77

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
vshell_bin="$repo_root/bin/vshell"

if ! command -v hyprctl >/dev/null 2>&1 || [[ -z ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  echo "surface smoke skipped: Hyprland session not available"
  exit "$SKIP_STATUS"
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

# vshell ipc filters by this checkout, so inspect the registry directly to distinguish
# a missing shell from a foreign checkout's shell. Skip only the missing-shell case.
require_own_shell() {
  local listing verdict diag err_file qs_bin="" candidate rc=0
  local class_err class_diag=""

  # Accept both CLI names recognized by the helper so a quickshell-only system is not skipped.
  for candidate in qs quickshell; do
    if command -v "$candidate" >/dev/null 2>&1; then
      qs_bin="$candidate"
      break
    fi
  done
  if [[ -z "$qs_bin" ]]; then
    echo "surface smoke skipped: no Quickshell CLI (qs, quickshell) on PATH, no instance registry to consult"
    exit "$SKIP_STATUS"
  fi

  # Parse stdout only. CLI warnings on stderr are diagnostics, not part of the JSON document.
  err_file="$(mktemp)"
  listing="$("$qs_bin" list --all --json 2>"$err_file")" || rc=$?
  diag="$(cat "$err_file")"
  rm -f "$err_file"

  if [[ "$rc" -ne 0 ]]; then
    {
      echo "surface smoke FAILED: could not read the Quickshell instance registry ($qs_bin list exited $rc)"
      if [[ -n "$diag" ]]; then printf '%s\n' "$diag"; fi
    } >&2
    exit 1
  fi

  rc=0
  class_err="$(mktemp)"
  verdict="$(QS_LISTING="$listing" python3 - "$repo_root/quickshell/vshell" 2>"$class_err" <<'PY'
import json
import os
import sys
from pathlib import Path

PROC = Path(os.environ.get("VSHELL_PROC_ROOT", "/proc"))
QS_BINARIES = ("qs", "quickshell")


def resolve(value):
    try:
        return Path(value).resolve()
    except OSError:
        return Path(value)


def peer_alive(pid):
    """True when `pid` is a live Quickshell process *right now*.

    Faithful mirror of `bin/vshell-helper::_vgs_peer_alive` — keep the two in
    step. `/proc/<pid>` merely existing is not liveness: a zombie keeps a
    readable entry while owning no surfaces, and after PID reuse the number
    belongs to something unrelated. Either would let a stale foreign entry fail
    this smoke instead of taking the documented no-shell skip, which is the
    false failure the precondition exists to prevent, inverted.
    """
    if pid <= 0:
        return False
    proc = PROC / str(pid)
    try:
        stat_text = (proc / "stat").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    # comm (field 2) is parenthesised and may contain spaces, so everything
    # after the final ')' is parsed positionally: index 0 is field 3 (state).
    fields = stat_text.rpartition(")")[2].split()
    if not fields:
        return False
    if fields[0] == "Z":  # A zombie owns no surfaces.
        return False
    try:
        executable = os.path.basename(os.path.realpath(proc / "exe"))
    except OSError:
        executable = ""
    if executable in QS_BINARIES:
        return True
    # An exe link can be unreadable for foreign processes; comm still helps reject an unrelated reused PID.
    try:
        comm = (proc / "comm").read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return False
    return comm in QS_BINARIES


want = resolve(sys.argv[1])
try:
    data = json.loads(os.environ["QS_LISTING"] or "[]")
except json.JSONDecodeError as exc:
    print(f"unparsable qs list output: {exc}", file=sys.stderr)
    raise SystemExit(2)
if not isinstance(data, list):
    print("unexpected qs list output", file=sys.stderr)
    raise SystemExit(2)

# Malformed entries fail because they cannot be classified. Well-formed unrelated apps
# and vanished processes are skipped without claiming an owned live shell.
malformed = []
foreign = []
mine = False


def read_pid(value):
    """The entry's pid as a positive int, or a reason it is not one."""
    if isinstance(value, bool) or value is None:
        return None, f"pid is not an integer ({value!r})"
    if isinstance(value, int):
        pid = value
    elif isinstance(value, str) and value.strip().lstrip("+-").isdigit():
        pid = int(value)
    else:
        return None, f"pid is not an integer ({value!r})"
    if pid <= 0:
        return None, f"pid is not a positive integer ({value!r})"
    return pid, None


for index, entry in enumerate(data):
    if not isinstance(entry, dict):
        malformed.append(f"entry {index}: expected an object, got {type(entry).__name__}")
        continue
    raw = entry.get("config_path")
    if not isinstance(raw, str) or not raw.strip():
        malformed.append(f"entry {index}: no usable config_path ({raw!r})")
        continue
    pid, why = read_pid(entry.get("pid"))
    if pid is None:
        malformed.append(f"entry {index}: {why}")
        continue
    path = resolve(raw)
    if path.name == "shell.qml":
        path = path.parent
    # Match the VGS runtime-tree suffix across checkouts; unrelated Quickshell apps remain outside scope.
    if path.parts[-2:] != ("quickshell", "vshell"):
        continue

    if not peer_alive(pid):
        continue
    if path == want:
        mine = True
        continue
    foreign.append((pid, str(path.parent.parent)))

# Reject malformed entries before ownership results because an unreadable entry could be foreign.
# Reject foreign shells before accepting an owned shell because compositor layers aggregate both.
if malformed:
    print("registry entries this script does not understand:", file=sys.stderr)
    for line in malformed:
        print(f"  {line}", file=sys.stderr)
    raise SystemExit(2)
if foreign:
    for pid, root in sorted(foreign):
        print(f"{root} (pid {pid})")
    raise SystemExit(11)
if mine:
    raise SystemExit(0)
raise SystemExit(10)
PY
  )" || rc=$?
  class_diag="$(cat "$class_err")"
  rm -f "$class_err"

  case "$rc" in
    0) return 0 ;;
    10)
      echo "surface smoke skipped: no live VGS shell on this session"
      exit "$SKIP_STATUS"
      ;;
    11)
      {
        echo "surface smoke FAILED: a live VGS shell belongs to a different checkout"
        while IFS= read -r line; do
          [[ -n "$line" ]] && echo "  running shell: $line"
        done <<<"$verdict"
        echo "  this run:      $repo_root"
        echo "  vshell ipc resolves instances by this checkout's config path, so none of the"
        echo "  surface assertions can reach that shell. Run the smoke from the checkout above."
        echo "  This fails even when this checkout's own shell is ALSO live: hyprctl layers"
        echo "  aggregates every Quickshell instance on the seat, so the assertions cannot"
        echo "  tell whose surfaces they are reading, and a pass would prove nothing."
      } >&2
      exit 1
      ;;
    *)
      {
        echo "surface smoke FAILED: could not classify the instance registry (classifier exit $rc)"
        # Capture classifier stderr so the report can group it with the failed precondition.
        if [[ -n "$class_diag" ]]; then
          while IFS= read -r line; do echo "  $line"; done <<<"$class_diag"
        fi
        if [[ -n "$diag" ]]; then
          # Indent multiline diagnostics so continuation lines stay attached to their cause.
          echo "  $qs_bin list also wrote to stderr:"
          while IFS= read -r line; do echo "    $line"; done <<<"$diag"
        fi
      } >&2
      exit 1
      ;;
  esac
}

# Check prerequisites before installing cleanup that can act on the live session.
require_own_shell

# Preserve IPC stderr and report the failed action status.
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
