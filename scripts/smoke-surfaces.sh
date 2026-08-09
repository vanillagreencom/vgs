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
  local listing verdict diag err_file qs_bin="" candidate rc=0
  local class_err class_diag=""

  # Both names, in the order `bin/vshell-helper`'s QS_BINARIES lists them. A
  # system providing only `quickshell` reads the same registry, and probing for
  # `qs` alone turned that into a skip — a false green of exactly the kind this
  # precondition exists to prevent.
  for candidate in qs quickshell; do
    if command -v "$candidate" >/dev/null 2>&1; then
      qs_bin="$candidate"
      break
    fi
  done
  if [[ -z "$qs_bin" ]]; then
    echo "surface smoke skipped: no Quickshell CLI (qs, quickshell) on PATH, no instance registry to consult"
    exit 0
  fi

  # stdout and stderr are captured SEPARATELY on purpose. Folding them together
  # ("2>&1") feeds any warning the CLI writes to stderr — a deprecation notice,
  # a protocol grumble — into the JSON parser and turns a perfectly good listing
  # into a hard failure. stdout is the document; stderr is only ever the
  # diagnostic printed when something actually went wrong.
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
    if fields[0] == "Z":  # exited, not yet reaped: owns no surfaces
        return False
    try:
        executable = os.path.basename(os.path.realpath(proc / "exe"))
    except OSError:
        executable = ""
    if executable in QS_BINARIES:
        return True
    # /proc/<pid>/exe is readable only for our own processes; comm is not, and
    # is enough to reject a process that merely inherited the number.
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

# Three outcomes, and they must stay distinct. An entry the registry schema
# says nothing sensible about is MALFORMED and fails: silently skipping it
# recreates the false green this precondition exists to prevent, one layer in.
# An entry that is well formed but is not a VGS tree is SKIPPED — other
# Quickshell apps share the seat and are none of this script's business. An
# entry that is well formed and is VGS but whose process is gone is skipped
# too — the registry simply outlived it.
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
    # A VGS runtime tree, in any checkout: <root>/quickshell/vshell. Unrelated
    # Quickshell shells on the same seat are none of this script's business.
    if path.parts[-2:] != ("quickshell", "vshell"):
        continue
    # A registry entry outliving its process must not fail the run.
    if not peer_alive(pid):
        continue
    if path == want:
        mine = True
        continue
    foreign.append((pid, str(path.parent.parent)))

# Decision order: MALFORMED, then FOREIGN, then MINE, then skip. Both of the
# first two beat a confirmed own shell, for the same underlying reason — the
# assertions cannot tell whose surfaces they are reading.
#
# Malformed first: an entry this script cannot read might BE a foreign shell,
# so "some of the registry was understood" is not an answer worth acting on.
#
# Foreign before mine, which is not a tie-break but the whole point: `hyprctl
# layers` aggregates every Quickshell instance on the seat. With this checkout's
# shell AND another's both live, a foreign shell's surfaces can satisfy every
# assertion and the smoke reports success on evidence from somebody else's
# shell. Returning success there is worse than the silent death this
# precondition replaced, because a false pass is acted on.
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
      exit 0
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
        # The classifier's own stderr belongs INSIDE this report, indented with
        # everything else. Letting it escape from the command substitution put
        # multi-line errors above the header, where they read as unrelated.
        if [[ -n "$class_diag" ]]; then
          while IFS= read -r line; do echo "  $line"; done <<<"$class_diag"
        fi
        if [[ -n "$diag" ]]; then
          # Indent every line, not just the first: the CLI's stderr is routinely
          # multi-line, and a single echo leaves continuation lines flush against
          # the margin where they read as separate findings.
          echo "  $qs_bin list also wrote to stderr:"
          while IFS= read -r line; do echo "    $line"; done <<<"$diag"
        fi
      } >&2
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
