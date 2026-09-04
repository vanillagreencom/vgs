#!/usr/bin/env bash
# Parse QML source and optionally exercise an isolated shell sandbox.
#
# Usage: scripts/qml-smoke.sh [options]
#
# Without options, run static QML parsing.
# --nested: also run the shell inside a nested compositor.
# --require-nested: enable nesting and fail if its prerequisites are absent.
# --require-static: fail if the QML parser is unavailable.
# --timeout SECONDS: set the sandbox shell lifetime.
# -h, --help: print this help.
#
# Nested mode needs Hyprland, qs, Python, and a host Wayland socket.
# Sandbox settings come from repository defaults.
# Theme loading is outside this smoke's coverage.
# The runtime check waits for bundled plugins and exercises user overrides.
# Popouts and switchers are checked for mapping and dismissal.
# wtype enables Escape-key dismissal checks.
# Live-session snapshots check process instances and excess layer surfaces; cleanup targets only process groups this run created.
# Never launches into the live session and never runs pkill quickshell; other Quickshell apps on the seat are legitimate.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
qml_roots=("$repo_root/quickshell/vshell" "$repo_root/config/vshell/plugins")

nested=false
require_nested=false
require_static=false
static_ran=false
nested_timeout=40
compositor_timeout=15
# Plugin discovery is asynchronous. Core IPC readiness alone does not establish plugin loading.
plugin_timeout=30

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nested) nested=true ;;
    --require-nested) nested=true; require_nested=true ;;
    --require-static) require_static=true ;;
    --timeout) shift; nested_timeout="${1:?--timeout needs a value}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "qml-smoke: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

status=0
note() { printf 'qml-smoke: %s\n' "$*"; }
fail() { printf 'qml-smoke: FAIL: %s\n' "$*" >&2; status=1; }

# shellcheck source=scripts/lib/session-snapshot.sh
source "$repo_root/scripts/lib/session-snapshot.sh"
vgs_snapshot_prefix="qml-smoke: "

instances_before="$(vgs_snapshot_instances)" && instances_before_status=0 || instances_before_status=$?
layers_before="$(vgs_snapshot_layers)" && layers_before_status=0 || layers_before_status=$?

declare -a tracked_pgids=()
declare -a scratch_dirs=()
spawn_launcher_pid=""
spawn_pgid=""

track_pgid() { tracked_pgids+=("$1"); }
track_dir() { scratch_dirs+=("$1"); }

# Start a command in its own process group and record the inner shell PID before exec.
spawn_group() {
  local pidfile="$1" launcher
  shift
  rm -f -- "$pidfile"
  # shellcheck disable=SC2016  # $$ and "$@" must expand in the inner sh, not here
  setsid --wait sh -c 'echo $$ >"$1"; shift; exec "$@"' _ "$pidfile" "$@" &
  launcher=$!
  spawn_launcher_pid="$launcher"
  spawn_pgid=""
  for _ in $(seq 1 100); do
    if [[ -s "$pidfile" ]]; then
      spawn_pgid="$(tr -d '[:space:]' <"$pidfile")"
      break
    fi
    kill -0 "$launcher" 2>/dev/null || break
    sleep 0.05
  done
  if [[ -z "$spawn_pgid" ]]; then
    # A missing PID file does not prove launch failure. Adopt children of this setsid process for cleanup.
    local child
    for child in $(pgrep -P "$launcher" 2>/dev/null || true); do
      track_pgid "$child"
    done
    kill "$launcher" 2>/dev/null || true
    return 1
  fi
  track_pgid "$spawn_pgid"
}

# Signal only process groups recorded by this script's launches.
kill_pgid() {
  local pgid="$1"
  kill -0 -- "-$pgid" 2>/dev/null || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 -- "-$pgid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

# An interrupt can inherit a successful status. Set failure explicitly.
# shellcheck disable=SC2329  # invoked via the trap registrations below
cleanup() {
  local code=$? signal="${1:-}" pgid dir index
  trap - EXIT INT TERM HUP
  case "$signal" in
    INT) code=130 ;;
    TERM) code=143 ;;
    HUP) code=129 ;;
  esac
  for ((index = ${#tracked_pgids[@]} - 1; index >= 0; index--)); do
    pgid="${tracked_pgids[index]}"
    kill_pgid "$pgid"
    if kill -0 -- "-$pgid" 2>/dev/null; then
      printf 'qml-smoke: FAIL: process group %s survived cleanup\n' "$pgid" >&2
      code=1
    fi
  done
  for dir in "${scratch_dirs[@]:-}"; do
    [[ -n "$dir" && -d "$dir" ]] && rm -rf -- "$dir"
  done
  assert_live_session_untouched || code=1
  exit "$code"
}

# shellcheck disable=SC2329  # called from cleanup(), which only the traps reach
assert_live_session_untouched() {
  local ok=0 instances_after layers_after instances_after_status layers_after_status
  instances_after="$(vgs_snapshot_instances)" && instances_after_status=0 || instances_after_status=$?
  layers_after="$(vgs_snapshot_layers)" && layers_after_status=0 || layers_after_status=$?

  if ! vgs_compare_snapshots "live VGS instances" \
    "$instances_before" "$instances_before_status" \
    "$instances_after" "$instances_after_status" exact; then
    ok=1
  fi
  if ! vgs_compare_snapshots "live VGS layer surfaces" \
    "$layers_before" "$layers_before_status" \
    "$layers_after" "$layers_after_status" growth \
  "$(printf '%s' "$instances_after" | grep -c . || true)"; then
    ok=1
  fi
  return "$ok"
}

trap 'cleanup' EXIT
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM
trap 'cleanup HUP' HUP

find_qmllint() {
  local candidate bindir
  for candidate in qmllint qmllint-qt6 /usr/lib/qt6/bin/qmllint /usr/lib/qt/bin/qmllint; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  if command -v qtpaths6 >/dev/null 2>&1; then
    bindir="$(qtpaths6 --query QT_INSTALL_BINS 2>/dev/null || true)"
    if [[ -n "$bindir" && -x "$bindir/qmllint" ]]; then
      printf '%s\n' "$bindir/qmllint"
      return 0
    fi
  fi
  return 1
}

static_check() {
  local linter files=() findings output rc
  mapfile -t files < <(find "${qml_roots[@]}" -name '*.qml' -type f 2>/dev/null | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    fail "no QML files found under ${qml_roots[*]}"
    return
  fi
  if ! linter="$(find_qmllint)"; then
    if [[ "$require_static" == true ]]; then
      fail "qmllint not installed (pacman -S qt6-declarative)"
    else
      note "static parse check skipped: qmllint not installed (pacman -S qt6-declarative)"
    fi
    return
  fi
  # Inspect linter status separately so a failed executable cannot appear as an empty clean scan.
  rc=0
  output="$("$linter" "${files[@]}" 2>&1)" || rc=$?
  # qmllint uses 255 for findings, including ignored semantic warnings. Other nonzero statuses fail the tool check.
  if [[ "$rc" != 0 && "$rc" != 255 ]]; then
    printf '%s\n' "$output" | tail -n 20 >&2
    fail "qmllint could not run (exit $rc)"
    return
  fi

  # Outside Quickshell, semantic import and property warnings are expected. Check parse findings only.
  # Inline component delegates can reuse IDs, so the document-wide duplicate-ID warning is excluded.
  findings="$(printf '%s\n' "$output" |
    grep -E '\[syntax(\.[a-z-]+)?\]' |
    grep -v '\[syntax\.duplicate-ids\]' || true)"
  if [[ -n "$findings" ]]; then
    printf '%s\n' "$findings" >&2
    fail "QML parse errors in ${#files[@]} scanned files"
    return
  fi
  static_ran=true
  note "static parse check passed (${#files[@]} QML files)"
}

# Report unavailable nesting. Pass no-host-socket only for that specific failed prerequisite,
# so missing binaries cannot produce irrelevant socket advice.
nested_unavailable() {
  local reason="$1" cause="${2:-}"
  if [[ "$require_nested" == true ]]; then
    fail "isolated runtime check unavailable: $reason"
  else
    note "isolated runtime check skipped: $reason"
  fi
  # Socket advice also requires WAYLAND_DISPLAY to be unset.
  local nest_remedy=""
  if [[ "$cause" == no-host-socket && -z "${WAYLAND_DISPLAY:-}" ]]; then
    nest_remedy="qml-smoke:   4. point the sandbox at the session's own socket (it keeps its own runtime
qml-smoke:      dir, HOME and bus, so the live session is untouched). Use the value
qml-smoke:      a session shell reports for WAYLAND_DISPLAY — the basename is
qml-smoke:      session-dependent, so this cannot name it for you (VGS-70 will make
qml-smoke:      --nested discover it). Export WAYLAND_DISPLAY to that value and
qml-smoke:      XDG_RUNTIME_DIR to /run/user/\$(id -u), then re-run scripts/validate qml"
  fi
  cat >&2 <<EOF
qml-smoke: a runtime check must run inside its own compositor. Safe options:
qml-smoke:   1. install a nested compositor (Hyprland is enough) and re-run with --nested
qml-smoke:   2. validate on a spare TTY/VM session that has no live VGS shell
qml-smoke:   3. read the live shell's own QML errors: vshell logs -n 200
${nest_remedy:+$nest_remedy
}qml-smoke: never run 'qs -c vshell' or 'qs -p quickshell/vshell' in a live session.
EOF
}

host_wayland_socket() {
  local display="${WAYLAND_DISPLAY:-}"
  [[ -n "$display" ]] || return 1
  [[ "$display" == /* ]] && { printf '%s\n' "$display"; return 0; }
  printf '%s/%s\n' "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set}" "$display"
}

# Plugin phases use dynamically scoped sandbox variables from nested_check.

sandbox_ipc() {
  "${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" --any-display call "$@" 2>&1 || true
}

# env -i and the sandbox runtime directory keep hyprctl on the nested compositor.
# Propagate query errors so they cannot be interpreted as an absent surface.
sandbox_layers() {
  "${sandbox_env[@]}" hyprctl -i 0 layers -j 2>/dev/null
}

# Read monitor geometry from the nested compositor and propagate query failure.
sandbox_monitors() {
  "${sandbox_env[@]}" hyprctl -i 0 monitors -j 2>/dev/null
}

# Read layer geometry against its own output. Convert physical mode pixels to logical pixels
# using scale and quarter-turn transforms; another layer's size is not an output measurement.
# Return one geometry line: <w>x<h> <screen_w>x<screen_h>.
# Status 0 means nondegenerate, 1 absent, 2 degenerate or output-sized, and 3 unreadable.
# The layer payload traversal can still raise an unhandled error that exits 1 and appears absent.
sandbox_layer_state() {
  local namespace="$1" layers monitors rc=0
  layers="$(sandbox_layers)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return 3
  fi
  monitors="$(sandbox_monitors)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return 3
  fi
  MONITORS_JSON="$monitors" LAYERS_JSON="$layers" python3 - "$namespace" <<'PY'
import json
import os
import sys

namespace = sys.argv[1]


def parsed(name):
    raw = os.environ[name]
    if not raw.strip():
        raise SystemExit(3)
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        raise SystemExit(3)


data = parsed("LAYERS_JSON")
if not isinstance(data, dict):
    raise SystemExit(3)
monitors = parsed("MONITORS_JSON")
if not isinstance(monitors, list):
    raise SystemExit(3)

# Guard the entire physical-to-logical conversion. Even numeric NaN can fail when converted
# to an integer; an uncaught exception exits with the status reserved for surface absence.
# Omit invalid outputs rather than inventing zero dimensions.
outputs = {}
for monitor in monitors:
    try:
        if monitor.get("disabled"):
            continue
        name = monitor.get("name")
        mode_w = int(monitor.get("width") or 0)
        mode_h = int(monitor.get("height") or 0)
        scale = float(monitor.get("scale") or 0)
        transform = int(monitor.get("transform") or 0)
        # Require a string name before using it as a map key. A truthy list or dict is not hashable.
        if not isinstance(name, str) or not name:
            continue
        if mode_w <= 0 or mode_h <= 0 or not scale > 0:
            continue
        # Only known transform values establish whether axes swap.
        if transform not in range(8):
            continue
        logical_w = int(round(mode_w / scale))
        logical_h = int(round(mode_h / scale))
    except (AttributeError, TypeError, ValueError, OverflowError, ZeroDivisionError):
        continue
    if transform in (1, 3, 5, 7):
        logical_w, logical_h = logical_h, logical_w
    if logical_w > 0 and logical_h > 0:
        outputs[name] = (logical_w, logical_h)

matches = []
for monitor_name, monitor in data.items():
    layers = []
    for level in (monitor.get("levels") or {}).values():
        layers.extend(level)
    for layer in layers:
        if layer.get("namespace") != namespace:
            continue
        matches.append((monitor_name, int(layer.get("w") or 0), int(layer.get("h") or 0)))

if not matches:
    raise SystemExit(1)

# A popout or modal binds one screen. Multiple mappings are an invalid measurement,
# not readings to select or average.
if len(matches) > 1:
    sys.stderr.write(
        "sandbox_layer_state: %s is mapped %d times (%s), but a popout or modal surface "
        "binds to exactly one screen - that is a duplicate-mapping defect, not a geometry "
        "reading\n"
        % (namespace, len(matches), ", ".join(entry[0] for entry in matches))
    )
    raise SystemExit(3)

monitor_name, w, h = matches[0]
if monitor_name not in outputs:
    sys.stderr.write(
        "sandbox_layer_state: %s is mapped on monitor %s, but `hyprctl monitors` reports "
        "no usable size for it, so there is nothing to measure it against - that is not "
        "evidence about its geometry\n" % (namespace, monitor_name)
    )
    raise SystemExit(3)

screen_w, screen_h = outputs[monitor_name]
print("%dx%d %dx%d" % (w, h, screen_w, screen_h))
if w <= 0 or h <= 0:
    raise SystemExit(2)
# Status 2 includes both collapsed and output-sized surfaces. Switcher callers must inspect
# positive dimensions against the output; they cannot treat the status alone as success.
if w >= screen_w and h >= screen_h:
    raise SystemExit(2)
raise SystemExit(0)
PY
}

# Wait for the requested layer state. Report a failed query separately from timeout.
wait_layer_state() {
  local namespace="$1" want="$2" state=1
  for _ in $(seq 1 30); do
    state=0
    sandbox_layer_state "$namespace" >/dev/null || state=$?
    if [[ "$state" -eq 3 ]]; then
      fail "could not read the sandbox compositor's layer list (hyprctl query failed, or its output could not be measured) - that is not evidence '$namespace' is absent"
      return 2
    fi
    [[ "$state" == "$want" ]] && return 0
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.2
  done
  return 1
}

# A mapped surface verifies creation and dismissal, not correct content layout.
# Opening the popout exposes content ReferenceErrors to the log scan. The surface size
# does not measure content, and this harness cannot click through the pager.
popout_namespace="vshell:plugins:plugin"
# Opening aiUsage instantiates its meter delegates and pager.
popout_plugin="aiUsage"
# Use a separate override plugin that the shipped bar hosts; unhosted components never emit the marker.
override_plugin="tailscale"

# Read sentinels from the running shell. They must differ from both repository values and fallbacks.
# The selected carriers remain inert during smoke: custom animation duration requires Custom speed,
# and the update command requires a user update request.
settings_sentinel_key="customAnimationDuration"
settings_sentinel_value=4242
plugin_sentinel_plugin="sysUpdate"
plugin_sentinel_key="aurUpdateCommand"
plugin_sentinel_value="{vshell} update run aur --vgs92-seed-sentinel"

# Match the exact value in its expected section; substring matches can accept unrelated values.
# shellcheck disable=SC2329  # invoked by name through await_sentinel's $matcher
sentinel_is_exactly() { [[ "$1" == "$2" ]]; }

# Match a plugin key and value. An unparsable reply remains a miss during polling.
# shellcheck disable=SC2329  # invoked by name through await_sentinel's $matcher
sentinel_at_path() {
  python3 -c 'import json, sys
try: data = json.loads(sys.argv[1])
except ValueError: sys.exit(1)
section = data.get(sys.argv[2])
sys.exit(0 if isinstance(section, dict) and section.get(sys.argv[3]) == sys.argv[4] else 1)' "$@"
}

# Poll an asynchronous settings value with a bounded wait and retain the last reply.
# Status 1 means a rejected value, 2 means no answer or dead shell, and 3 means an absent key.
# A missing SettingsData key can return undefined with a successful IPC status.
await_sentinel() {
  local key="$1" matcher="$2"
  shift 2
  local reply="" last_good="" answered=false gone=false
  for _ in $(seq 1 40); do
    # Keep transport errors separate from replies; sandbox_ipc merges them and swallows status.
    if reply="$("${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" \
        --any-display call settings get "$key" 2>/dev/null)"; then
      answered=true
      last_good="$reply"
      "$matcher" "$reply" "$@" && { printf '%s' "$reply"; return 0; }
    fi
    # A missed final poll cannot erase earlier answers and turn a wrong seed into a dead-shell diagnosis.
    if ! kill -0 -- "-$qs_group" 2>/dev/null; then
      gone=true
      break
    fi
    sleep 0.25
  done
  printf '%s' "$last_good"
  { [[ "$gone" == true ]] || [[ "$answered" != true ]]; } && return 2
  { [[ -z "$last_good" ]] || [[ "$last_good" == "undefined" ]]; } && return 3
  return 1
}

# Probe one IPC key with an exact matcher and a failure description of the same expected value.
seed_probe() {
  local key="$1" want="$2" reply state=0
  shift 2
  reply="$(await_sentinel "$key" "$@")" || state=$?
  case "$state" in
    0) return 0 ;;
    2)
      # Retain the last reply as evidence if the shell exits.
      # shellcheck disable=SC2016  # the quotes inside ${reply:+...} are literal text; $reply does expand
      fail "the sandboxed shell stopped answering \`settings get $key\` - the shell or its IPC is gone, so nothing was learned about the seed${reply:+ (last reply: '$reply')}" ;;
    3)
      if [[ "$reply" == "undefined" ]]; then
        fail "'$key' is not a SettingsData property any more - the SENTINEL needs repointing, and this says nothing about the seed"
      else
        fail "\`settings get $key\` answered nothing - VGSIPC returns JSON for any live property, so this is a change in the IPC itself, not a seed failure"
      fi ;;
    *)
      fail "the sandboxed shell is NOT running on the state it seeded: \`settings get $key\` answered '$reply', and the sandbox stamped $want (VGS-92, D008)" ;;
  esac
  return 1
}

seeded_settings_check() {
  seed_probe "$settings_sentinel_key" "$settings_sentinel_value" \
    sentinel_is_exactly "$settings_sentinel_value" || return 1
  seed_probe pluginSettings "$plugin_sentinel_plugin.$plugin_sentinel_key=$plugin_sentinel_value" \
    sentinel_at_path "$plugin_sentinel_plugin" "$plugin_sentinel_key" "$plugin_sentinel_value" || return 1

  note "seeded settings check passed (the running shell reports both sandbox sentinels: $settings_sentinel_key and $plugin_sentinel_plugin.$plugin_sentinel_key)"
  return 0
}

# Bar registration follows plugin loading asynchronously, so widget readiness needs its own wait.
wait_widget_registered() {
  local widget="$1" reply=""
  for _ in $(seq 1 60); do
    reply="$(sandbox_ipc widget list)"
    printf '%s\n' "$reply" | grep -q "^${widget}\b" && return 0
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.25
  done
  # shellcheck disable=SC2016  # the backticks are literal quoting in the message
  printf 'qml-smoke: `widget list` reported:\n%s\n' "$reply" >&2
  return 1
}

# Require one geometry record for a surface already reported present.
# Missing or multiple records cannot establish output-height coverage.
assert_popout_geometry() {
  local geometry="$1" label="$2" surface_size screen_size
  if [[ -z "${geometry//[[:space:]]/}" ]]; then
    fail "no layer geometry to check for '$label', though its surface was reported present - refusing to pass on no evidence"
    return 1
  fi
  # Validate both fields before splitting. Without a space, shell prefix and suffix expansion
  # return the same field and can produce a false equality.
  if [[ ! "$geometry" =~ ^[0-9]+x[0-9]+\ [0-9]+x[0-9]+$ ]]; then
    fail "could not parse the '$label' layer geometry: '$geometry'"
    return 1
  fi
  surface_size="${geometry%% *}"
  screen_size="${geometry##* }"
  if [[ "${surface_size#*x}" != "${screen_size#*x}" ]]; then
    fail "'$label' popout surface is '$surface_size' on a '$screen_size' output - it must span the output height (VGS-133)"
    return 1
  fi
  return 0
}

# Send Escape through virtual-keyboard input because window-targeted shortcuts cannot reach layers.
# Status 0 means sent, 2 means wtype absent, and 1 means an invocation failure already reported.
send_escape() {
  local what="$1" rc=0
  command -v wtype >/dev/null 2>&1 || return 2
  # Focus is deferred after mapping; immediate keyboard input can arrive before content is listening.
  sleep 1.5
  "${sandbox_env[@]}" WAYLAND_DISPLAY="$nested_socket" wtype -k Escape >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail "could not send Escape to $what - wtype exited $rc, so nothing was proven about its key handling"
    return 1
  fi
  return 0
}

popout_check() {
  local reply state=0 geometry geo_rc esc_rc

  wait_widget_registered "$popout_plugin" || {
    fail "the sandbox bar never registered '$popout_plugin', so its popout could not be opened - the seeded settings.default.json is supposed to host it"
    return 1
  }

  # Require initial absence so an unrelated open popout cannot satisfy the mapping assertion.
  if ! wait_layer_state "$popout_namespace" 1; then
    fail "a plugin popout surface was already open before '$popout_plugin' was toggled"
    return 1
  fi

  reply="$(sandbox_ipc widget toggle "$popout_plugin")"
  if [[ "$reply" != "WIDGET_TOGGLE_SUCCESS: $popout_plugin" ]]; then
    fail "widget toggle $popout_plugin answered '$reply'"
    return 1
  fi

  # Wait for compositor evidence; a successful IPC reply alone does not prove mapping.
  wait_layer_state "$popout_namespace" 0 || state=$?
  if [[ "$state" -ne 0 ]]; then
    sandbox_layer_state "$popout_namespace" >&2 || true
    if [[ "$state" -eq 2 ]]; then
      fail "'$popout_plugin' opened a degenerate popout surface (zero-sized or full-screen)"
    else
      fail "'$popout_plugin' popout never produced a '$popout_namespace' surface"
    fi
    return 1
  fi

  # Output-height surfaces avoid committing resized window geometry during content animation.
  # Classify query and presence failures before comparing height.
  geometry="$(sandbox_layer_state "$popout_namespace")" && geo_rc=0 || geo_rc=$?
  case "$geo_rc" in
    3) fail "could not take a geometry reading for '$popout_plugin' - hyprctl failed, or its output has no reported size, or it is mapped more than once. That is not evidence about the popout's height"; return 1 ;;
    1) fail "the '$popout_plugin' popout surface disappeared before its height could be read"; return 1 ;;
    2) fail "'$popout_plugin' opened a degenerate popout surface ($geometry) - that is not a height mismatch"; return 1 ;;
  esac
  assert_popout_geometry "$geometry" "$popout_plugin" || return 1

  esc_rc=0
  send_escape "the '$popout_plugin' popout" || esc_rc=$?
  case "$esc_rc" in
    0)
      if ! wait_layer_state "$popout_namespace" 1; then
        sandbox_layer_state "$popout_namespace" >&2 || true
        fail "Escape did not close the '$popout_plugin' popout"
        return 1
      fi
      note "plugin popout check passed ($popout_plugin opened a $popout_namespace surface and Escape closed it)"
      ;;
    2)

      note "NOT CHECKED: Escape-to-close - wtype is not installed"
      reply="$(sandbox_ipc widget toggle "$popout_plugin")"
      if [[ "$reply" != "WIDGET_TOGGLE_SUCCESS: $popout_plugin" ]]; then
        fail "closing the $popout_plugin popout answered '$reply'"
        return 1
      fi
      if ! wait_layer_state "$popout_namespace" 1; then
        fail "the '$popout_plugin' popout surface outlived its close"
        return 1
      fi
      note "plugin popout check passed ($popout_plugin opened a $popout_namespace surface and closed cleanly)"
      ;;
    *) return 1 ;;
  esac
  return 0
}

# Opening switchers instantiates content that startup and static parsing do not reach.
# Measure positive dimensions against the output: status 2 alone can also mean a collapsed surface.
# Exercise toggle and Escape in both backdrop states. With background disabled, a mapped window
# that never renders can stall the animation timer responsible for closing it.
# Restore the sandbox setting on every exit. Discover target/namespace pairs from QML source.
switcher_records=()

# Discover FullScreenSwitcher root elements, independent of filenames.
# Reject an unexpected directory or unreadable target/namespace instead of omitting it.
# Capture grep status directly; process substitution can hide a partial listing after read failure.
switcher_roots() {
  local root_dir="$1" out status
  out="$(grep -rlE '^[[:space:]]*FullScreenSwitcher[[:space:]]*(\{|$)' "$root_dir/quickshell/vshell" --include='*.qml')"
  status=$?
  if (( status > 1 )); then
    fail "could not scan quickshell/vshell for switcher root elements (grep exit $status) - a partial list would silently under-cover"
    return 1
  fi
  [[ -n $out ]] && printf '%s\n' "$out" | sort
  return 0
}

discover_switchers() {
  switcher_records=()
  local file name namespace target found_any=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    found_any=1
    name="$(basename "$file")"
    if [[ "$(dirname "$file")" != "$repo_root/quickshell/vshell/Modals/Switcher" ]]; then
      fail "$name declares FullScreenSwitcher as its root element but lives outside quickshell/vshell/Modals/Switcher - switcher_check only looks there, so it would be covered by nothing"
      return 1
    fi
    namespace="$(sed -n 's/^[[:space:]]*layerNamespace:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -n 1)"
    if [[ -z "$namespace" ]]; then
      fail "$name overrides no layerNamespace, so it maps onto the shared 'vshell:modal' surface and switcher_check cannot tell it apart from any other modal"
      return 1
    fi
    if [[ "$namespace" != vshell:* ]]; then
      fail "$name declares layerNamespace '$namespace', which does not carry the 'vshell:' prefix its IPC target is derived from"
      return 1
    fi
    target="${namespace#vshell:}"
    # Require the discovered target to have an IPC handler before driving it.
    if ! grep -q "target: \"$target\"" "$repo_root/quickshell/vshell/VGSIPC.qml"; then
      fail "$name's namespace '$namespace' implies IPC target '$target', which VGSIPC.qml does not register - switcher_check cannot drive it"
      return 1
    fi
    switcher_records+=("$target|$namespace")
  # Allow indentation and a brace on the following line. This broad match can include a nested use;
  # directory and namespace checks then fail instead of silently dropping a real switcher.
  done < <(switcher_roots "$repo_root")
  if [[ $found_any -eq 0 || ${#switcher_records[@]} -eq 0 ]]; then
    fail "no file in quickshell/vshell declares FullScreenSwitcher as its root element - switcher_check would measure nothing and still pass"
    return 1
  fi
  return 0
}

switcher_reply() {
  local target="${1//-/_}" verb="$2"
  printf '%s_%s_SUCCESS\n' "${target^^}" "${verb^^}"
}

# Keep the last geometry reading for failure diagnostics.
switcher_last_geometry=""

# Wait for positive full-output geometry and store the last reading in switcher_last_geometry.
# Return 0 on success, 1 on timeout, 3 on query failure, or 4 if the shell exits.
wait_switcher_mapped() {
  local namespace="$1" geometry rc surface screen
  switcher_last_geometry=""
  for _ in $(seq 1 30); do
    rc=0
    geometry="$(sandbox_layer_state "$namespace")" || rc=$?
    [[ "$rc" -eq 3 ]] && return 3
    # Validate field structure before splitting. Retain negative readings so diagnostics show collapse.
    if [[ "$geometry" =~ ^-?[0-9]+x-?[0-9]+\ -?[0-9]+x-?[0-9]+$ ]]; then
      switcher_last_geometry="$geometry"
      surface="${geometry%% *}"
      screen="${geometry##* }"
      if ((${surface%x*} > 0 && ${surface#*x} > 0 && ${surface%x*} >= ${screen%x*} && ${surface#*x} >= ${screen#*x})); then
        return 0
      fi
    fi
    kill -0 -- "-$qs_group" 2>/dev/null || return 4
    sleep 0.2
  done
  return 1
}

# Describe the cause represented by the wait status.
fail_switcher_mapped() {
  local rc="$1" what="$2" surface
  case "$rc" in
    3) fail "could not take a geometry reading for $what - hyprctl failed, or its output has no reported size, or the surface is mapped more than once. That is not evidence about the switcher" ;;
    4) fail "the sandbox shell exited while waiting for $what to map, so nothing was proven about the switcher" ;;
    *)
      if [[ -z "$switcher_last_geometry" ]]; then
        fail "$what never produced a surface at all"
      else
        # Distinguish collapsed dimensions from a mapped surface smaller than the output.
        surface="${switcher_last_geometry%% *}"
        if ((${surface%x*} <= 0 || ${surface#*x} <= 0)); then
          fail "$what mapped at '$switcher_last_geometry' (surface then output) - a zero or negative dimension is the layout collapse this checks for"
        else
          fail "$what mapped at '$switcher_last_geometry' (surface then output) - a switcher must cover the whole output, and this surface came up smaller than the output it is on"
        fi
      fi
      ;;
  esac
}

# Wait for absence without relabeling a query failure as failed dismissal.
wait_switcher_unmapped() {
  local namespace="$1" what="$2" state=0
  wait_layer_state "$namespace" 1 || state=$?
  [[ "$state" -eq 0 ]] && return 0
  if [[ "$state" -ne 2 ]]; then
    sandbox_layer_state "$namespace" >&2 || true
    fail "$what"
  fi
  return 1
}

# Wait for a settings write to become observable so each backdrop pass tests the requested state.
# Return 1 on nonconvergence or 2 if the shell exits.
await_darken_setting() {
  local want="$1" reply
  for _ in $(seq 1 20); do
    reply="$(sandbox_ipc settings get modalDarkenBackground)"
    [[ "$reply" == "$want" ]] && return 0
    kill -0 -- "-$qs_group" 2>/dev/null || return 2
    sleep 0.2
  done
  return 1
}

set_darken_setting() {
  local want="$1" reply rc=0
  reply="$(sandbox_ipc settings set modalDarkenBackground "$want")"
  if [[ "$reply" != "SETTINGS_SET_SUCCESS" ]]; then
    fail "could not set modalDarkenBackground=$want (answered '$reply')"
    return 1
  fi
  await_darken_setting "$want" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    fail "the sandbox shell exited while waiting for modalDarkenBackground=$want"
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    fail "modalDarkenBackground never read back as $want, though the settings set call reported success"
    return 1
  fi
  return 0
}

# Open a switcher through the requested verb and require compositor geometry evidence.
switcher_open_and_map() {
  local target="$1" verb="$2" namespace="$3" darken="$4" open_want="$5" what="$6" reply rc=0

  reply="$(sandbox_ipc "$target" "$verb")"
  if [[ "$reply" != "$open_want" ]]; then
    fail "$target $verb answered '$reply', wanted '$open_want' - $what (modalDarkenBackground=$darken)"
    return 1
  fi

  wait_switcher_mapped "$namespace" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    fail_switcher_mapped "$rc" "$what (modalDarkenBackground=$darken)"
    return 1
  fi
  return 0
}

# Run an open/close cycle for one target and backdrop value.
switcher_cycle() {
  local target="$1" namespace="$2" darken="$3"
  local open_want close_want toggle_want reply state=0

  open_want="$(switcher_reply "$target" open)"
  close_want="$(switcher_reply "$target" close)"
  toggle_want="$(switcher_reply "$target" toggle)"

  # Initial absence prevents a previously mapped surface from satisfying this cycle.
  wait_layer_state "$namespace" 1 || state=$?
  if [[ "$state" -ne 0 ]]; then

    [[ "$state" -ne 2 ]] && fail "'$namespace' was already mapped before '$target open' was called (modalDarkenBackground=$darken)"
    return 1
  fi

  switcher_open_and_map "$target" open "$namespace" "$darken" "$open_want" "'$target open'" || return 1

  # Check the close reply as well as absence; sandbox_ipc does not propagate transport status.
  reply="$(sandbox_ipc "$target" close)"
  if [[ "$reply" != "$close_want" ]]; then
    fail "$target close answered '$reply', wanted '$close_want' (modalDarkenBackground=$darken)"
    return 1
  fi
  wait_switcher_unmapped "$namespace" "'$target close' reported success but the '$namespace' surface outlived it (modalDarkenBackground=$darken)" || return 1

  # Toggle in both directions because a stale shouldBeVisible can still return success.
  switcher_open_and_map "$target" toggle "$namespace" "$darken" "$open_want" "'$target toggle' (to open)" || return 1

  reply="$(sandbox_ipc "$target" toggle)"
  if [[ "$reply" != "$toggle_want" ]]; then
    fail "$target toggle (to close) answered '$reply', wanted '$toggle_want' - it took the open branch, so shouldBeVisible does not track the mapped surface (modalDarkenBackground=$darken)"
    return 1
  fi
  wait_switcher_unmapped "$namespace" "'$target toggle' did not unmap the '$namespace' surface (modalDarkenBackground=$darken)" || return 1

  switcher_escape_cycle "$target" "$namespace" "$darken" "$open_want" || return 1
  return 0
}

# Track skipped Escape tests so the phase cannot claim keyboard coverage without wtype.
switcher_escape_checked=true

# Escape dismissal tests focus handling that IPC close cannot exercise.
# The full-output switcher disables background-click dismissal.
switcher_escape_cycle() {
  local target="$1" namespace="$2" darken="$3" open_want="$4" esc_rc=0

  if ! command -v wtype >/dev/null 2>&1; then

    note "NOT CHECKED: $target Escape-to-dismiss - wtype is not installed"
    switcher_escape_checked=false
    return 0
  fi

  switcher_open_and_map "$target" open "$namespace" "$darken" "$open_want" "'$target open' before the Escape check" || return 1

  send_escape "the '$target' switcher" || esc_rc=$?
  if [[ "$esc_rc" -ne 0 ]]; then
    # The availability check excludes status 2; remaining errors come from a failed wtype invocation.
    switcher_escape_checked=false
    return 1
  fi
  wait_switcher_unmapped "$namespace" "Escape did not dismiss the '$target' switcher, which is the only way out of it (modalDarkenBackground=$darken)" || return 1
  return 0
}

switcher_check() {
  local original rc=0
  # Read the prior setting before mutation and restore it after the phase so sandbox state does not leak.
  original="$(sandbox_ipc settings get modalDarkenBackground)"
  if [[ "$original" != "true" && "$original" != "false" ]]; then
    fail "could not read modalDarkenBackground before the switcher check (answered '$original'), so it could not be restored afterwards"
    return 1
  fi

  switcher_check_body || rc=$?

  if ! set_darken_setting "$original"; then
    fail "modalDarkenBackground was left at the switcher check's value instead of the sandbox's own '$original'"
    rc=1
  fi
  return "$rc"
}

switcher_check_body() {
  local darken record escape_note

  discover_switchers || return 1

  for darken in true false; do
    set_darken_setting "$darken" || return 1

    for record in "${switcher_records[@]}"; do
      switcher_cycle "${record%%|*}" "${record##*|}" "$darken" || return 1
    done
  done

  if [[ "$switcher_escape_checked" == "true" ]]; then
    escape_note="unmapped on close, on toggle and on Escape"
  else
    escape_note="unmapped on close and on toggle; Escape NOT CHECKED (wtype missing)"
  fi
  note "switcher check passed (${#switcher_records[@]} full-screen switchers measured full-output on open and on toggle, $escape_note, with the modal backdrop on and off)"
  return 0
}

# Count markers emitted only by the override component. A load-success reply cannot identify its source.
override_marker_count() {
  grep -c "VGS81-OVERRIDE-LOADED-$override_nonce" "$log" 2>/dev/null || true
}

override_unloaded_count() {
  grep -c "VGS81-OVERRIDE-UNLOADED-$override_nonce" "$log" 2>/dev/null || true
}

wait_marker() {
  local counter="$1" want="$2" seen=0
  for _ in $(seq 1 60); do
    seen="$($counter)"
    [[ "$seen" -ge "$want" ]] && return 0
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.25
  done
  return 1
}

plugin_is_loaded() {
  sandbox_ipc plugins list | grep -q "^$1 \[loaded\]\$"
}

override_check() {
  local dir reply live loads teardowns loads_before teardowns_before
  local strays strays_dir strays_rc=0

  # Check for packages after the sandbox has run, when it can have created them.
  # A second package with this ID makes ownership ambiguous. Distinguish an absent directory
  # from an unreadable directory, and avoid GNU-only find options.
  strays_dir="$sandbox/home/.config/vshell/plugins"
  if [[ -d "$strays_dir" ]]; then
    strays="$(find "$strays_dir" -mindepth 1 -maxdepth 1 -type d)" || strays_rc=$?
    if [[ "${strays_rc:-0}" -ne 0 ]]; then
      fail "could not enumerate '$strays_dir' (find exit $strays_rc) — 'I could not look' is not 'nothing is there'"
      return 1
    fi
    if [[ -n "$strays" ]]; then
      fail "user plugin package(s) already in the sandbox before the override fixture was planted:"$'\n'"$strays"
      return 1
    fi
  fi

  dir="$sandbox/home/.config/vshell/plugins/$override_plugin"
  mkdir -p "$dir"
  # Only the fixture override can emit its marker. Its manifest opts into overriding the bundled ID
  # and satisfies the shell-version gate, which is outside this test's purpose.
  cat >"$dir/plugin.json" <<EOF
{
    "id": "$override_plugin",
    "name": "VGS-81 override fixture",
    "description": "Throwaway override planted by scripts/qml-smoke.sh inside its sandbox.",
    "version": "9.9.9",
    "license": "MIT",
    "author": "qml-smoke",
    "icon": "science",
    "component": "./Component.qml",
    "overrides": "$override_plugin",
    "requires_shell": ">=0.0.1"
}
EOF
  cat >"$dir/Component.qml" <<EOF
import QtQuick
import qs.Modules.Plugins

PluginComponent {
    id: root

    // Deliberately minimal, but with a pill of its own so a bar genuinely
    // hosts and instantiates it rather than merely compiling it.
    horizontalBarPill: Component {
        Rectangle {
            implicitWidth: 8
            implicitHeight: 8
            color: "transparent"
        }
    }
    Component.onCompleted: console.info("VGS81-OVERRIDE-LOADED-$override_nonce")
    Component.onDestruction: console.info("VGS81-OVERRIDE-UNLOADED-$override_nonce")
}
EOF

  reply="$(sandbox_ipc plugin-scan scan)"
  if [[ "$reply" != SCAN_TRIGGERED:* ]]; then
    fail "plugin-scan scan answered '$reply'"
    return 1
  fi
  if ! wait_marker override_marker_count 1; then
    fail "the planted override of '$override_plugin' never loaded its own component — a scan that reports success while the bundled copy stays installed is exactly the VGS-75 defect"
    return 1
  fi
  if ! override_state_settles 1; then
    return 1
  fi

  # Rescan can relink an existing record without reloading. Load counts depend on discovery order;
  # assert one live override instance and retained ID ownership instead.
  reply="$(sandbox_ipc plugin-scan rescan "$override_plugin")"
  if [[ "$reply" != RESCAN_TRIGGERED:* ]]; then
    fail "plugin-scan rescan answered '$reply'"
    return 1
  fi
  sleep 2
  if ! override_state_settles 1; then
    return 1
  fi

  # Reload must unload and instantiate again, including after records were relinked by rescan.
  loads_before="$(override_marker_count)"
  teardowns_before="$(override_unloaded_count)"
  reply="$(sandbox_ipc plugins reload "$override_plugin")"
  if [[ "$reply" != "PLUGIN_RELOAD_SUCCESS: $override_plugin" ]]; then
    fail "plugins reload answered '$reply'"
    return 1
  fi
  # Require component teardown and creation markers; a success reply alone cannot prove either.
  if ! wait_marker override_marker_count $((loads_before + 1)); then
    loads="$(override_marker_count)"
    fail "plugins reload reported success but the override's own component was never re-instantiated (own-component loads $loads, expected $((loads_before + 1)))"
    return 1
  fi
  sleep 1
  loads="$(override_marker_count)"
  teardowns="$(override_unloaded_count)"
  if [[ "$loads" -ne $((loads_before + 1)) || "$teardowns" -ne $((teardowns_before + 1)) ]]; then
    fail "the reload was not exactly one unload followed by one load (loads $loads_before -> $loads, teardowns $teardowns_before -> $teardowns)"
    return 1
  fi
  if ! override_state_settles 1; then
    return 1
  fi

  # Removing the override must return its ID to the bundled package.
  rm -rf -- "$dir"
  reply="$(sandbox_ipc plugin-scan rescan "$override_plugin")"
  if [[ "$reply" != RESCAN_TRIGGERED:* ]]; then
    fail "plugin-scan rescan after removing the override answered '$reply'"
    return 1
  fi
  if ! wait_marker override_unloaded_count $((teardowns + 1)); then
    fail "the override's component was never torn down after its manifest was removed — it is still the package installed under '$override_plugin' while its files no longer exist"
    return 1
  fi
  sleep 1
  # Require the ID to remain loaded with no override instance alive. A loaded label alone cannot identify ownership.
  if ! override_state_settles 0; then
    return 1
  fi
  loads="$(override_marker_count)"
  teardowns="$(override_unloaded_count)"
  note "plugin override check passed ($override_plugin: the override loaded its own component, kept exactly one live instance across a rescan and a reload, and left none behind when its manifest was removed — own-component loads $loads, teardowns $teardowns)"
  return 0
}

# Check ownership and the expected live override count from loads minus teardowns.
override_state_settles() {
  local want="$1" loads teardowns live
  loads="$(override_marker_count)"
  teardowns="$(override_unloaded_count)"
  live=$((loads - teardowns))
  if [[ "$live" -ne "$want" ]]; then
    fail "'$override_plugin' has $live live override instance(s), expected $want (own-component loads $loads, teardowns $teardowns)"
    return 1
  fi
  if ! plugin_is_loaded "$override_plugin"; then
    fail "'$override_plugin' is owned by nobody — no package is installed under the id"
    return 1
  fi
  return 0
}

nested_check() {
  local host_socket sandbox rt_dir conf log nested_socket candidate exit_code findings
  local compositor_pgid qs_launcher qs_group loaded targets plugins_loaded plugin_report candidate
  local seeded
  local -a expected_plugins=() missing_plugins=()
  local -a sandbox_env=() dbus_wrapper=()
  # Each run needs its own log so old markers cannot satisfy fixture assertions.
  override_nonce="$$-${RANDOM}"

  command -v Hyprland >/dev/null 2>&1 || { nested_unavailable "Hyprland not installed"; return; }
  command -v qs >/dev/null 2>&1 || { nested_unavailable "quickshell (qs) not installed"; return; }
  # Require the JSON parser before geometry queries so a missing interpreter cannot look like absence.
  command -v python3 >/dev/null 2>&1 || { nested_unavailable "python3 not installed (needed to read the compositor's layer list)"; return; }
  if ! host_socket="$(host_wayland_socket)" || [[ ! -S "$host_socket" ]]; then
    # A host Wayland socket prevents the nested compositor from falling back to the live GPU and VT.
    nested_unavailable "no host Wayland socket to nest inside (WAYLAND_DISPLAY unset)" no-host-socket
    return
  fi

  sandbox="$(mktemp -d -t vshell-smoke.XXXXXX)"
  track_dir "$sandbox"
  # Keep the runtime directory short enough for Hyprland's IPC socket path.
  rt_dir="${XDG_RUNTIME_DIR:?}/vs.$$"
  rm -rf -- "$rt_dir"
  mkdir -p -- "$rt_dir"
  chmod 700 -- "$rt_dir"
  track_dir "$rt_dir"

  mkdir -p "$sandbox/home/.config" "$sandbox/home/.local/share" "$sandbox/home/.local/state" "$sandbox/home/.cache"
  # Seed sandbox state from repository files and leave plugins/ absent for the override fixture.
  # Theme state is not seeded: the smoke uses the fallback palette and cannot verify theme loading.
  # See D008 § Scope.
  # Report each preparation failure before using the resulting sandbox.
  prep_fail() {
    fail "sandbox preparation failed at: $1"
    return 1
  }

  mkdir -p "$sandbox/home/.config/vshell" || { prep_fail "creating the sandbox config directory"; return; }
  cp -- "$repo_root/config/vshell/settings.default.json" \
        "$sandbox/home/.config/vshell/settings.json" || { prep_fail "seeding settings.json from the shipped default"; return; }
  cp -- "$repo_root/config/vshell/plugin_settings.default.json" \
        "$sandbox/home/.config/vshell/plugin_settings.json" || { prep_fail "seeding plugin_settings.json from the shipped default"; return; }

  # Sentinel keys must exist in shipped defaults. Inventing a renamed key would test a setting the shell ignores.
  python3 - "$sandbox/home/.config/vshell" \
            "$settings_sentinel_key" "$settings_sentinel_value" \
            "$plugin_sentinel_plugin" "$plugin_sentinel_key" "$plugin_sentinel_value" \
            <<'PY' || { prep_fail "stamping the seed sentinels into the seeded settings"; return; }
import json
import sys

root, skey, svalue, pplugin, pkey, pvalue = sys.argv[1:7]


def stamp(name, path, value):
    full = f"{root}/{name}"
    with open(full) as fh:
        data = json.load(fh)
    node = data
    for key in path[:-1]:
        if key not in node:
            sys.exit(f"{name}: no {key!r} section in the shipped default")
        node = node[key]
    if path[-1] not in node:
        sys.exit(f"{name}: {path[-1]!r} is not in the shipped default")
    # A sentinel matching the repository fallback cannot distinguish applied seed from fallback state.
    if node[path[-1]] == value:
        sys.exit(f"{name}: the sentinel for {'.'.join(path)} equals the shipped value {value!r}")
    node[path[-1]] = value
    with open(full, "w") as fh:
        json.dump(data, fh, indent=2)


stamp("settings.json", (skey,), int(svalue))
stamp("plugin_settings.json", (pplugin, pkey), pvalue)
PY

  conf="$sandbox/hyprland.conf"
  cat >"$conf" <<'EOF'
# Minimal throwaway config: no autostart, no user includes, no keybinds.
monitor = , preferred, auto, 1
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    force_default_wallpaper = 0
    disable_autoreload = true
}
animations {
    enabled = false
}
EOF

  log="$sandbox/qs.log"

  # Clear inherited environment, then provide isolated backend, compositor, and session-bus endpoints.
  sandbox_env=(
    env -i
    HOME="$sandbox/home"
    PATH="$PATH"
    USER="${USER:-$(id -un)}"
    LOGNAME="${LOGNAME:-${USER:-$(id -un)}}"
    TERM="${TERM:-dumb}"
    XDG_RUNTIME_DIR="$rt_dir"
    XDG_CONFIG_HOME="$sandbox/home/.config"
    XDG_DATA_HOME="$sandbox/home/.local/share"
    XDG_STATE_HOME="$sandbox/home/.local/state"
    XDG_CACHE_HOME="$sandbox/home/.cache"
  )
  if command -v dbus-run-session >/dev/null 2>&1; then
    dbus_wrapper=(dbus-run-session --)
  else
    dbus_wrapper=()
    sandbox_env+=(DBUS_SESSION_BUS_ADDRESS="unix:path=$rt_dir/absent-bus")
  fi

  note "starting nested compositor sandbox (runtime dir $rt_dir)"
  if ! spawn_group "$sandbox/hyprland.pgid" \
    "${sandbox_env[@]}" WAYLAND_DISPLAY="$host_socket" \
    Hyprland --config "$conf" >"$sandbox/hyprland.log" 2>&1; then
    nested_unavailable "nested compositor failed to launch"
    return
  fi
  compositor_pgid="$spawn_pgid"

  nested_socket=""
  for _ in $(seq 1 $((compositor_timeout * 10))); do
    for candidate in "$rt_dir"/wayland-*; do
      [[ -S "$candidate" ]] || continue
      nested_socket="${candidate##*/}"
      break
    done
    [[ -n "$nested_socket" ]] && break
    kill -0 -- "-$compositor_pgid" 2>/dev/null || break
    sleep 0.1
  done

  if [[ -z "$nested_socket" ]]; then
    tail -n 20 "$sandbox/hyprland.log" >&2 || true
    nested_unavailable "nested compositor did not come up"
    return
  fi

  note "running the shell inside the sandbox (timeout ${nested_timeout}s)"
  if ! spawn_group "$sandbox/qs.pgid" \
    "${sandbox_env[@]}" \
    WAYLAND_DISPLAY="$nested_socket" \
    VSHELL_ROOT="$repo_root" \
    VSHELL_DISABLE_HOT_RELOAD=1 \
    "${dbus_wrapper[@]}" \
    timeout --signal=TERM --kill-after=5 "$nested_timeout" \
    qs --no-color -p "$repo_root/quickshell/vshell" >"$log" 2>&1; then
    # Launch output already reaches the log, so include it when reporting early failure.
    tail -n 40 "$log" >&2 || true
    fail "sandboxed shell failed to launch"
    return
  fi
  qs_launcher="$spawn_launcher_pid"
  qs_group="$spawn_pgid"

  # Wait for VGS IPC targets; surviving until a timeout alone does not prove the shell loaded.
  loaded=false
  targets=""
  for _ in $(seq 1 $((nested_timeout * 2))); do
    targets="$("${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" --any-display show 2>/dev/null || true)"
    if printf '%s\n' "$targets" | grep -q '^target '; then
      loaded=true
      break
    fi
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.5
  done

  # Wait for every bundled plugin discovered from the repository. Their independent asynchronous
  # loads can remain pending after core readiness or another plugin's readiness.
  mapfile -t expected_plugins < <(
    find "$repo_root/config/vshell/plugins" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
  )
  if [[ ${#expected_plugins[@]} -eq 0 ]]; then
    fail "no bundled plugins found under config/vshell/plugins"
    return
  fi

  # Verify sentinels before state-dependent phases. Bundled plugins can load on fallback settings,
  # so plugin readiness alone cannot prove the seed was applied.
  seeded=false
  if [[ "$loaded" == true ]] && seeded_settings_check; then
    seeded=true
  fi

  plugins_loaded=false
  plugin_report=""
  # Plugin readiness is independent of seeded settings.
  if [[ "$loaded" == true ]]; then
    for _ in $(seq 1 $((plugin_timeout * 2))); do
      # Match plugins list output, which uses [loaded|disabled]. plugin-scan list uses tab-separated fields.
      # This view distinguishes an undiscovered ID from a discovered ID that failed to load.
      plugin_report="$("${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" \
        --any-display call plugins list 2>/dev/null || true)"
      missing_plugins=()
      for candidate in "${expected_plugins[@]}"; do
        printf '%s\n' "$plugin_report" | grep -q "^${candidate} \[loaded\]\$" || missing_plugins+=("$candidate")
      done
      if [[ ${#missing_plugins[@]} -eq 0 ]]; then
        plugins_loaded=true
        break
      fi
      kill -0 -- "-$qs_group" 2>/dev/null || break
      sleep 0.5
    done
  fi

  # Run state-dependent phases only after seed verification and before teardown.
  if [[ "$seeded" == true && "$plugins_loaded" == true ]]; then
    if popout_check; then
      override_check || true
    fi
  fi

  # Switchers can run once the shell loads. Run them after seed-dependent phases because they write settings.
  # Their failure has already set exit status; keep teardown reachable.
  if [[ "$loaded" == true ]]; then
    switcher_check || true
  fi

  kill_pgid "$qs_group"
  exit_code=0
  wait "$qs_launcher" || exit_code=$?

  # Emit available diagnostics before verdicts so one failure does not hide another's evidence.
  # Missing live PipeWire and bus peers are expected sandbox environment gaps.
  local sandbox_noise='quickshell\.service\.pipewire|Failed to connect pipewire'
  # Match ReferenceError, TypeError, and SyntaxError even when prefixed by QML paths.
  # Binding-loop warnings are benign in existing surfaces; bare Error lines match third-party output. Both are excluded.
  local error_classes='ReferenceError|TypeError|SyntaxError'
  # grep status 1 means no match; status 2 means the log was not read. Preserve that distinction.
  local grep_rc=0 scan_error=""
  findings="$(grep -nE "^[[:space:]]*ERROR|is not a type|Cannot assign|Unable to assign|Failed to start process|Type .* unavailable|$error_classes" "$log")" || grep_rc=$?
  if [[ "$grep_rc" -gt 1 ]]; then
    scan_error="could not scan the sandbox log for runtime errors (grep exit $grep_rc, log '$log')"
    findings=""
  else
    findings="$(printf '%s\n' "$findings" | grep -vE "$sandbox_noise")" || grep_rc=$?
    if [[ "$grep_rc" -gt 1 ]]; then
      scan_error="could not filter sandbox noise out of the runtime findings (grep exit $grep_rc)"
      findings=""
    fi
  fi
  [[ -n "$findings" ]] && printf '%s\n' "$findings" >&2
  # A shell can exit without a recognized error class; include the raw tail for that case.
  [[ "$loaded" != true ]] && { tail -n 40 "$log" >&2 || true; }

  local -a not_loaded=() never_seen=()
  if [[ "$loaded" == true && "$plugins_loaded" != true ]]; then
    # Distinguish plugins never discovered from plugins discovered but not loaded.
    for candidate in "${missing_plugins[@]}"; do
      if printf '%s\n' "$plugin_report" | grep -q "^${candidate} \["; then
        not_loaded+=("$candidate")
      else
        never_seen+=("$candidate")
      fi
    done
    # shellcheck disable=SC2016  # the backticks are literal quoting in the message
    printf 'qml-smoke: `plugins list` reported after %ss:\n%s\n' "$plugin_timeout" \
      "${plugin_report:-<no response from the plugins IPC target>}" >&2
  fi


  if grep -q "refusing to start a duplicate shell" "$log"; then
    fail "the duplicate-instance guard misfired inside the sandbox"
    return
  fi
  if [[ -n "$scan_error" ]]; then
    fail "$scan_error"
    return
  fi
  if [[ "$loaded" != true ]]; then
    fail "sandboxed shell never exposed its IPC targets (exit code $exit_code)"
    return
  fi
  if [[ -n "$findings" ]]; then
    # Report QML errors before plugin failure when both conditions hold.
    fail "QML/runtime errors in the sandboxed shell"
    return
  fi
  if [[ "$seeded" != true ]]; then

    return
  fi
  if [[ "$plugins_loaded" != true ]]; then
    if [[ ${#not_loaded[@]} -gt 0 ]]; then
      # Bundled plugins are force-enabled and declare no startupCheck. If that contract changes,
      # expected readiness must account for intentionally disabled plugins.
      fail "bundled plugin(s) scanned but NOT loaded: ${not_loaded[*]} — a bundled id is force-enabled and declares no startup gate, so this is a load failure, not a disabled plugin"
      return
    fi
    fail "bundled plugin(s) never appeared in the sandbox within ${plugin_timeout}s: ${never_seen[*]} (of ${#expected_plugins[@]} under config/vshell/plugins) — the scan never reached them"
    return
  fi

  # fail sets status without stopping the run. Print success only while status remains successful.
  [[ "$status" -eq 0 ]] || return
  note "isolated runtime check passed (shell loaded, all ${#expected_plugins[@]} bundled plugins loaded, answered IPC in the sandbox)"
}

static_check
if [[ "$nested" == true ]]; then
  nested_check
else
  note "runtime check not requested (pass --nested for the sandboxed shell run)"
fi

if [[ "$status" -eq 0 ]]; then
  if [[ "$static_ran" == false && "$nested" == false ]]; then
    note "nothing was checked (no qmllint, and --nested was not requested)"
  else
    note "ok"
  fi
fi
exit "$status"
