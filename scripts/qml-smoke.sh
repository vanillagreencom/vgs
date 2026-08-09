#!/usr/bin/env bash
# Canonical VGS QML smoke.
#
# Never launches a VGS shell into the live session. A second full VGS instance
# competes with the session shell for session-global resources (WlSessionLock,
# the fade-to-lock overlay, idle/DPMS tiers) and leaves orphaned full-screen
# layer surfaces behind, which is how a validation run can black out a working
# Hyprland session.
#
#   scripts/qml-smoke.sh                 static QML parse check (always safe)
#   scripts/qml-smoke.sh --nested        + run the real shell inside an isolated
#                                          nested compositor sandbox
#   scripts/qml-smoke.sh --require-nested fail instead of skipping when the
#                                          sandbox cannot be built
#   scripts/qml-smoke.sh --require-static fail instead of skipping when qmllint
#                                          is unavailable
#
# The default mode is a *parse* check: it catches syntax errors across the QML
# tree, not runtime faults. Unresolved qs.* imports and missing properties only
# surface when the shell actually runs, which is what --nested is for.
#
# --nested loads bundled plugins from config/vshell/plugins and waits for EVERY
# one of them to report loaded before it stops observing, so plugin-owned QML is
# inside the checked window. It fails if any of them never loads.
#
# It then drives two things that loading alone never reaches (VGS-81):
#
#   * a plugin POPOUT is opened through `widget toggle`, because everything
#     inside popoutContent is only instantiated when the popout opens — the
#     extracted meter delegates and the in-surface pager had never been executed
#     by anything. A ReferenceError in that content passes a full nested run
#     with the popout closed.
#   * a user OVERRIDE of a bundled id is planted in the sandbox's own HOME and
#     put through scan, rescan, reload and removal, asserting on markers only
#     the override's own component can emit. "The load succeeded" is not
#     evidence here: the VGS-75 defect reported PLUGIN_RELOAD_SUCCESS and logged
#     a clean "Plugin loaded" for what was really the bundled copy.
#
# Both modes assert that they leave the live session byte-for-byte alone: same
# VGS Quickshell instances, same VGS layer surfaces. Cleanup is process-group
# scoped and runs on success, failure, timeout, and interrupt. This script never
# uses a broad `pkill quickshell` — other Quickshell applications on the seat
# are legitimate.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
qml_roots=("$repo_root/quickshell/vshell" "$repo_root/config/vshell/plugins")

nested=false
require_nested=false
require_static=false
static_ran=false
nested_timeout=40
compositor_timeout=15
# Bundled plugins are scanned asynchronously after the core tree loads, so they
# appear well after the first core IPC target does. Waiting for them is what
# makes plugin-owned QML part of the observed window.
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

# --- live-session snapshots -------------------------------------------------

# shellcheck source=scripts/lib/session-snapshot.sh
source "$repo_root/scripts/lib/session-snapshot.sh"
vgs_snapshot_prefix="qml-smoke: "

instances_before="$(vgs_snapshot_instances)" && instances_before_status=0 || instances_before_status=$?
layers_before="$(vgs_snapshot_layers)" && layers_before_status=0 || layers_before_status=$?

# --- deterministic cleanup --------------------------------------------------

declare -a tracked_pgids=()
declare -a scratch_dirs=()
spawn_launcher_pid=""
spawn_pgid=""

track_pgid() { tracked_pgids+=("$1"); }
track_dir() { scratch_dirs+=("$1"); }

# Launches a command in its own session/process group and records the group so
# cleanup can signal exactly what this script started. The inner shell reports
# its own pid (== the new process group id) before exec'ing the real command.
spawn_group() {
  local pidfile="$1" launcher waited
  shift
  rm -f -- "$pidfile"
  setsid --wait sh -c 'echo $$ >"$1"; shift; exec "$@"' _ "$pidfile" "$@" &
  launcher=$!
  spawn_launcher_pid="$launcher"
  spawn_pgid=""
  for waited in $(seq 1 100); do
    if [[ -s "$pidfile" ]]; then
      spawn_pgid="$(tr -d '[:space:]' <"$pidfile")"
      break
    fi
    kill -0 "$launcher" 2>/dev/null || break
    sleep 0.05
  done
  if [[ -z "$spawn_pgid" ]]; then
    # The pid file never appeared, but the command may be running anyway.
    # Nothing may be left behind unsupervised, so adopt whatever setsid forked
    # (parent-scoped, never a name match) before reporting the failure.
    local child
    for child in $(pgrep -P "$launcher" 2>/dev/null || true); do
      track_pgid "$child"
    done
    kill "$launcher" 2>/dev/null || true
    return 1
  fi
  track_pgid "$spawn_pgid"
}

# Signals the process group we created and nothing else. Every pid here came
# from a setsid launch in this script, so the group can never contain a
# pre-existing shell or an unrelated Quickshell application.
kill_pgid() {
  local pgid="$1" waited
  kill -0 -- "-$pgid" 2>/dev/null || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for waited in $(seq 1 40); do
    kill -0 -- "-$pgid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

# A signal handler inherits $? from whatever finished last, which is usually 0,
# so an interrupted run would otherwise report success to CI.
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

# --- static QML parse check -------------------------------------------------

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
  # The linter's own exit status has to be inspected separately: piping into
  # grep would let a linter that cannot run at all (missing library, wrong
  # architecture) look identical to a clean scan.
  rc=0
  output="$("$linter" "${files[@]}" 2>&1)" || rc=$?
  # qmllint exits 0 when nothing is reported and 255 when it reports something,
  # including the semantic warnings this check deliberately ignores. Any other
  # status means the linter itself failed.
  if [[ "$rc" != 0 && "$rc" != 255 ]]; then
    printf '%s\n' "$output" | tail -n 20 >&2
    fail "qmllint could not run (exit $rc)"
    return
  fi

  # Semantic warnings (unqualified access, uncreatable types, unresolved
  # qs.* module imports) are expected outside a Quickshell engine, so only
  # parse-level findings are treated as failures. syntax.duplicate-ids is
  # dropped as well: qmllint keeps one id table per document, but two inline
  # delegates are separate component scopes and may legally reuse an id.
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

# --- isolated nested runtime check ------------------------------------------

nested_unavailable() {
  local reason="$1"
  if [[ "$require_nested" == true ]]; then
    fail "isolated runtime check unavailable: $reason"
  else
    note "isolated runtime check skipped: $reason"
  fi
  cat >&2 <<EOF
qml-smoke: a runtime check must run inside its own compositor. Safe options:
qml-smoke:   1. install a nested compositor (Hyprland is enough) and re-run with --nested
qml-smoke:   2. validate on a spare TTY/VM session that has no live VGS shell
qml-smoke:   3. read the live shell's own QML errors: vshell logs -n 200
qml-smoke: never run 'qs -c vshell' or 'qs -p quickshell/vshell' in a live session.
EOF
}

host_wayland_socket() {
  local display="${WAYLAND_DISPLAY:-}"
  [[ -n "$display" ]] || return 1
  [[ "$display" == /* ]] && { printf '%s\n' "$display"; return 0; }
  printf '%s/%s\n' "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set}" "$display"
}

# --- plugin phases run inside the sandbox -----------------------------------
# Both read `sandbox_env`, `repo_root`, `sandbox`, `log` and `qs_group` from
# nested_check; bash scopes dynamically, so they are visible here.

# The plugin popout is a real layer-shell window whose size comes from its
# content, so the compositor is the honest witness for BOTH questions: that the
# popout opened, and that its content instantiated. A popoutContent that failed
# to build gives a degenerate surface, not a content-sized one.
popout_namespace="vshell:plugins:plugin"
# aiUsage, because its popoutContent is the code with no coverage at all: the
# extracted MeterRow/MeterCard delegates and the in-surface pager (VGS-72/73)
# live entirely inside it, and it is only instantiated when the popout opens.
popout_plugin="aiUsage"
# A different bundled id for the override phase, so the two cannot mask each
# other. It has to be one the shipped bar layout hosts — a plugin no bar hosts
# never instantiates its component, and the marker below would never fire.
override_plugin="tailscale"

sandbox_ipc() {
  "${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" --any-display call "$@" 2>&1 || true
}

# `hyprctl -i 0` resolves to the NESTED compositor: sandbox_env is built with
# `env -i`, so no HYPRLAND_INSTANCE_SIGNATURE from the live session leaks in and
# XDG_RUNTIME_DIR points at the sandbox's own runtime dir.
sandbox_layers() {
  "${sandbox_env[@]}" hyprctl -i 0 layers -j 2>/dev/null || true
}

# 0 = a content-sized surface with that namespace exists, 1 = absent,
# 2 = present but degenerate (zero, or as large as the screen).
sandbox_layer_state() {
  local namespace="$1" layers
  layers="$(sandbox_layers)"
  LAYERS_JSON="$layers" python3 - "$namespace" <<'PY'
import json
import os
import sys

namespace = sys.argv[1]
try:
    data = json.loads(os.environ["LAYERS_JSON"] or "{}")
except json.JSONDecodeError:
    raise SystemExit(1)

found = False
for monitor in (data.values() if isinstance(data, dict) else []):
    layers = []
    for level in (monitor.get("levels") or {}).values():
        layers.extend(level)
    # The screen, inferred from the largest surface on it — the same heuristic
    # scripts/smoke-surfaces.sh uses, and for the same reason: a popout that
    # covers the whole screen is a layout failure, not an open popout.
    screen_w = max((int(layer.get("w") or 0) for layer in layers), default=0)
    screen_h = max((int(layer.get("h") or 0) for layer in layers), default=0)
    for layer in layers:
        if layer.get("namespace") != namespace:
            continue
        found = True
        w = int(layer.get("w") or 0)
        h = int(layer.get("h") or 0)
        if w <= 0 or h <= 0:
            raise SystemExit(2)
        if screen_w > 0 and screen_h > 0 and w >= screen_w and h >= screen_h:
            raise SystemExit(2)
raise SystemExit(0 if found else 1)
PY
}

wait_layer_state() {
  local namespace="$1" want="$2" waited state=1
  for waited in $(seq 1 30); do
    state=0
    sandbox_layer_state "$namespace" || state=$?
    [[ "$state" == "$want" ]] && return 0
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.2
  done
  return 1
}

# Opening a widget-surface plugin popout DOES have a reachable entry point:
# `widget toggle` reaches BarWidgetService.triggerWidgetPopout, which calls
# PluginComponent.triggerPopout on the instance the focused screen's bar hosts.
# Everything inside popoutContent had never been executed by anything before
# this (VGS-81).
popout_check() {
  local reply

  # Polled, not sampled once. A plugin widget is registered with
  # BarWidgetService by the bar's WidgetHost, which mounts it some time after
  # the plugin itself reports loaded — a single read here failed about one run
  # in eight, reporting a missing bar entry that simply had not been mounted
  # yet.
  local waited
  reply=""
  for waited in $(seq 1 60); do
    reply="$(sandbox_ipc widget list)"
    printf '%s\n' "$reply" | grep -q "^${popout_plugin}\b" && break
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.25
  done
  if ! printf '%s\n' "$reply" | grep -q "^${popout_plugin}\b"; then
    printf 'qml-smoke: `widget list` reported:\n%s\n' "$reply" >&2
    fail "the sandbox bar never registered '$popout_plugin', so its popout could not be opened — the seeded settings.default.json is supposed to host it"
    return 1
  fi

  if ! wait_layer_state "$popout_namespace" 1; then
    fail "a plugin popout surface was already open before '$popout_plugin' was toggled"
    return 1
  fi

  reply="$(sandbox_ipc widget toggle "$popout_plugin")"
  if [[ "$reply" != "WIDGET_TOGGLE_SUCCESS: $popout_plugin" ]]; then
    fail "widget toggle $popout_plugin answered '$reply'"
    return 1
  fi

  # NOT "the call returned success". The call returning success is what the
  # old coverage would have been; this waits for the compositor to show a
  # content-sized surface, which is the part that proves popoutContent built.
  local state=0
  wait_layer_state "$popout_namespace" 0 || state=$?
  if [[ "$state" -ne 0 ]]; then
    sandbox_layer_state "$popout_namespace" || state=$?
    if [[ "$state" -eq 2 ]]; then
      sandbox_layers >&2
      fail "'$popout_plugin' opened a degenerate popout surface (zero-sized or full-screen) — its content did not instantiate"
    else
      fail "'$popout_plugin' popout never produced a '$popout_namespace' surface"
    fi
    return 1
  fi

  reply="$(sandbox_ipc widget toggle "$popout_plugin")"
  if [[ "$reply" != "WIDGET_TOGGLE_SUCCESS: $popout_plugin" ]]; then
    fail "closing the $popout_plugin popout answered '$reply'"
    return 1
  fi
  if ! wait_layer_state "$popout_namespace" 1; then
    sandbox_layers >&2
    fail "the '$popout_plugin' popout surface outlived its close"
    return 1
  fi
  note "plugin popout check passed ($popout_plugin opened a content-sized $popout_namespace surface and closed cleanly)"
  return 0
}

# How many times the override fixture's OWN component has been instantiated.
# This is the assertion the original VGS-75 defect defeats: it reported
# PLUGIN_RELOAD_SUCCESS and logged a clean "Plugin loaded" for what was really
# the bundled copy, so anything checking that a load *succeeded* passed
# throughout. Only the override's own QML can emit this.
override_marker_count() {
  grep -c "VGS81-OVERRIDE-LOADED-$override_nonce" "$log" 2>/dev/null || true
}

override_unloaded_count() {
  grep -c "VGS81-OVERRIDE-UNLOADED-$override_nonce" "$log" 2>/dev/null || true
}

wait_marker() {
  local counter="$1" want="$2" waited seen=0
  for waited in $(seq 1 60); do
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

  dir="$sandbox/home/.config/vshell/plugins/$override_plugin"
  mkdir -p "$dir"
  # A fixture, not a copy of the bundled component: the marker has to come from
  # QML that only the override has, and authoring it here keeps a test-only
  # hook out of the shipped tree entirely. `overrides` is the opt-in that lets
  # a user package take a bundled id (VGS-26); requires_shell is satisfied, so
  # the version gate is not what is under test here.
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

  # A rescan re-reads every manifest claiming the id. It deliberately does NOT
  # assert a reload: when the record re-read for a path is the one already
  # installed, _relinkLoadedRecord hands it the registration and reloading
  # would be pointless work. Whether a reload happens depends on which manifest
  # the rescan reaches first, so counting loads here asserts an artefact — it
  # was observed failing about one run in five before this was corrected. What
  # must hold is the invariant: exactly one live instance of the override, and
  # the id owned.
  reply="$(sandbox_ipc plugin-scan rescan "$override_plugin")"
  if [[ "$reply" != RESCAN_TRIGGERED:* ]]; then
    fail "plugin-scan rescan answered '$reply'"
    return 1
  fi
  sleep 2
  if ! override_state_settles 1; then
    return 1
  fi

  # A reload IS a defined contract: unload, then load. This is the step VGS-75
  # was reproduced on — after a rescan, `unloadPlugin` cleared the flag on the
  # record in `loadedPlugins` while `loadPlugin` read the other record, which
  # still claimed `loaded`, and early-returned true having installed nothing.
  # Live, that produced two "Plugin unloaded" lines and no matching load while
  # `plugin-scan status` still answered "loaded".
  loads_before="$(override_marker_count)"
  teardowns_before="$(override_unloaded_count)"
  reply="$(sandbox_ipc plugins reload "$override_plugin")"
  if [[ "$reply" != "PLUGIN_RELOAD_SUCCESS: $override_plugin" ]]; then
    fail "plugins reload answered '$reply'"
    return 1
  fi
  # PLUGIN_RELOAD_SUCCESS is exactly what the defect reported while installing
  # nothing, so the reply is not evidence. Only the override's own component
  # saying it was torn down and instantiated again is.
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

  # Removing the override must hand the id back to the shipped package rather
  # than leaving a package that no longer exists on disk installed under it.
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
  # `plugins list` saying "[loaded]" is NOT evidence that the shipped package
  # took the id back: it is exactly what the id reported while the wrong
  # package's components were installed. The evidence is that the id is loaded
  # AND no instance of the override survives, which leaves only the shipped
  # package. Reverting VGS-75 ends this run with one override instance still
  # live after its manifest was deleted.
  if ! override_state_settles 0; then
    return 1
  fi
  loads="$(override_marker_count)"
  teardowns="$(override_unloaded_count)"
  note "plugin override check passed ($override_plugin: the override loaded its own component, kept exactly one live instance across a rescan and a reload, and left none behind when its manifest was removed — own-component loads $loads, teardowns $teardowns)"
  return 0
}

# The two things that must hold after every step: the id is owned by something,
# and the override has exactly `want` live instances (loads minus teardowns).
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
  local host_socket sandbox rt_dir conf log nested_socket candidate waited exit_code findings
  local compositor_pgid qs_launcher qs_group loaded targets plugins_loaded plugin_report candidate
  local -a expected_plugins=() missing_plugins=()
  local -a sandbox_env=() dbus_wrapper=()
  # Per-run, so a stale log from an earlier invocation can never satisfy a
  # marker assertion in this one.
  override_nonce="$$-${RANDOM}"

  command -v Hyprland >/dev/null 2>&1 || { nested_unavailable "Hyprland not installed"; return; }
  command -v qs >/dev/null 2>&1 || { nested_unavailable "quickshell (qs) not installed"; return; }
  if ! host_socket="$(host_wayland_socket)" || [[ ! -S "$host_socket" ]]; then
    # Without a host Wayland socket a nested compositor would fall back to DRM
    # and fight the real session for the GPU/VT. Refuse rather than risk it.
    nested_unavailable "no host Wayland socket to nest inside (WAYLAND_DISPLAY unset)"
    return
  fi

  sandbox="$(mktemp -d -t vshell-smoke.XXXXXX)"
  track_dir "$sandbox"
  # Hyprland's IPC socket path is XDG_RUNTIME_DIR + a 60-char instance
  # signature; keep the runtime dir short or it exceeds sun_path.
  rt_dir="${XDG_RUNTIME_DIR:?}/vs.$$"
  rm -rf -- "$rt_dir"
  mkdir -p -- "$rt_dir"
  chmod 700 -- "$rt_dir"
  track_dir "$rt_dir"

  mkdir -p "$sandbox/home/.config" "$sandbox/home/.local/share" "$sandbox/home/.local/state" "$sandbox/home/.cache"
  # Seed a realistic (but throwaway) copy of user state so the smoke exercises
  # the real theme/settings paths without any chance of writing to live state.
  if [[ -d "$HOME/.config/vshell" ]]; then
    cp -a -- "$HOME/.config/vshell" "$sandbox/home/.config/vshell"
  fi
  # ...but settings.json is seeded from the SHIPPED DEFAULT rather than
  # inherited. The live file is commonly a symlink into a dotfiles repo, which
  # `cp -a` preserves and which then dangles inside the sandbox — so what the
  # sandbox actually ran with was "whatever the operator's bar happens to be",
  # or nothing at all, decided by an accident of how their config is stored.
  # The plugin phases below open a plugin popout and override a bundled id, and
  # both need a bar layout this script controls: a widget is only registered
  # with BarWidgetService, and its component only instantiated, when a bar
  # actually hosts it. config/vshell/settings.default.json already places every
  # bundled plugin widget, so the shipped seed is both the deterministic choice
  # and the honest one.
  mkdir -p "$sandbox/home/.config/vshell"
  rm -f "$sandbox/home/.config/vshell/settings.json"
  cp -- "$repo_root/config/vshell/settings.default.json" "$sandbox/home/.config/vshell/settings.json"

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

  # env -i: nothing from the live session leaks in. No VGS_SOCKET (the
  # sandboxed shell must not reach the live backend daemon), no
  # HYPRLAND_INSTANCE_SIGNATURE (hyprctl resolves to the nested compositor in
  # $rt_dir, never the live one), no DBUS_SESSION_BUS_ADDRESS (a private bus is
  # provided below instead of the live one).
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
  for waited in $(seq 1 $((compositor_timeout * 10))); do
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
    fail "sandboxed shell failed to launch"
    return
  fi
  qs_launcher="$spawn_launcher_pid"
  qs_group="$spawn_pgid"

  # A live IPC target list is the proof that VGS itself came up: those handlers
  # only exist once the shell tree loaded. Waiting on the timeout instead would
  # also "pass" for a shell that exited immediately.
  loaded=false
  targets=""
  for waited in $(seq 1 $((nested_timeout * 2))); do
    targets="$("${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" --any-display show 2>/dev/null || true)"
    if printf '%s\n' "$targets" | grep -q '^target '; then
      loaded=true
      break
    fi
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.5
  done

  # Bundled plugins load asynchronously, several seconds after the core targets
  # answer. Stopping at the first core target ends observation before any plugin
  # QML has run, so plugin load failures, duplicate IpcHandler registrations and
  # broken entry points were invisible here — and passed as full coverage.
  #
  # EVERY bundled plugin, not one of them. Waiting on a single plugin's IPC
  # target proved only that plugin loaded: the seven load through independent
  # asynchronous FileViews with no ordering guarantee, so six could still be
  # pending when the shell was killed, and their QML was never observed while
  # the run reported full plugin coverage. That is the original VGS-19 defect
  # wearing a different hat.
  #
  # The expected set is derived from the tree rather than hardcoded, so adding a
  # bundled plugin extends this check automatically instead of silently not
  # covering the new one.
  mapfile -t expected_plugins < <(
    find "$repo_root/config/vshell/plugins" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
  )
  if [[ ${#expected_plugins[@]} -eq 0 ]]; then
    fail "no bundled plugins found under config/vshell/plugins"
    return
  fi

  plugins_loaded=false
  plugin_report=""
  if [[ "$loaded" == true ]]; then
    for waited in $(seq 1 $((plugin_timeout * 2))); do
      # The `plugins` IPC target, NOT `plugin-scan`. Both expose a `list`, and
      # they format differently: this one emits "<id> [loaded|disabled]"
      # (VGSIPC.qml), while PluginService's own `plugin-scan list` emits
      # tab-separated "<id>\tloaded\t<type>\t<name>". Matching the wrong
      # emitter's shape would make every row miss, which reads as "no plugin
      # ever loaded" — so the target and the pattern have to be quoted together.
      # This one is used because it is the view that distinguishes "not scanned
      # yet" (absent) from "scanned and failed to load" (present, [disabled]).
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

  # Both phases drive the shell that is still running, so they come before the
  # teardown. They stop at the first failure, and `fail` has already set the
  # exit status by then; the log scan below still runs, because a phase that
  # failed usually left its explanation there.
  if [[ "$plugins_loaded" == true ]]; then
    if popout_check; then
      override_check || true
    fi
  fi

  kill_pgid "$qs_group"
  exit_code=0
  wait "$qs_launcher" || exit_code=$?

  if grep -q "refusing to start a duplicate shell" "$log"; then
    fail "the duplicate-instance guard misfired inside the sandbox"
    return
  fi
  if [[ "$loaded" != true ]]; then
    tail -n 40 "$log" >&2 || true
    fail "sandboxed shell never exposed its IPC targets (exit code $exit_code)"
    return
  fi
  if [[ "$plugins_loaded" != true ]]; then
    # Say WHICH failure this is. "Discovered but not loaded" and "never
    # appeared at all" have different causes, and a timeout that lists names
    # without distinguishing them sends the reader to the wrong place — a
    # legitimately disabled plugin would be indistinguishable from a broken
    # one.
    local -a not_loaded=() never_seen=()
    for candidate in "${missing_plugins[@]}"; do
      if printf '%s\n' "$plugin_report" | grep -q "^${candidate} \["; then
        not_loaded+=("$candidate")
      else
        never_seen+=("$candidate")
      fi
    done
    printf 'qml-smoke: `plugins list` reported after ${plugin_timeout}s:\n%s\n' \
      "${plugin_report:-<no response from the plugins IPC target>}" >&2
    if [[ ${#not_loaded[@]} -gt 0 ]]; then
      # Every bundled plugin is force-enabled by PluginService (a bundled id
      # backs product UI, so it loads whether or not a user setting names it)
      # and none declares a startupCheck, so there is no legitimate way for one
      # to sit here disabled. If that ever changes, this is where the expected
      # set has to learn about it — a deliberately-disabled plugin must not
      # look like a broken one.
      fail "bundled plugin(s) scanned but NOT loaded: ${not_loaded[*]} — a bundled id is force-enabled and declares no startup gate, so this is a load failure, not a disabled plugin"
      return
    fi
    fail "bundled plugin(s) never appeared in the sandbox within ${plugin_timeout}s: ${never_seen[*]} (of ${#expected_plugins[@]} under config/vshell/plugins) — the scan never reached them"
    return
  fi

  # Services the sandbox deliberately cannot reach (the live PipeWire socket
  # lives in the session's runtime dir, and the private bus has no peers) are
  # environment gaps, not QML defects.
  local sandbox_noise='quickshell\.service\.pipewire|Failed to connect pipewire'
  # Error classes, each verified against a paired positive/negative control:
  #   ReferenceError  undefined identifier in a binding or handler body
  #   TypeError       property/method access on undefined, calling a non-function
  #   SyntaxError     JS parse failure inside a .js import or a handler body
  # These are prefixed by the QML file path, not by 'ERROR', so the leading
  # anchor below never saw them.
  #
  # Deliberately NOT matched:
  #   'Binding loop detected'  a warning, benign in several existing surfaces,
  #                            and it would make the gate noisy rather than
  #                            catching a class of defect the shell cannot run
  #                            through.
  #   bare 'Error:'            over-matches process output and third-party
  #                            library chatter (ffmpeg, dbus) piped into the log.
  local error_classes='ReferenceError|TypeError|SyntaxError'
  # `|| true` here would treat a MISSING or unreadable log exactly like a clean
  # one: grep exits 1 for "no match" and 2 for "could not read the file", and
  # collapsing both into an empty result reports success over a log that was
  # never scanned. Distinguish them.
  local grep_rc=0
  findings="$(grep -nE "^[[:space:]]*ERROR|is not a type|Cannot assign|Unable to assign|Failed to start process|Type .* unavailable|$error_classes" "$log")" || grep_rc=$?
  if [[ "$grep_rc" -gt 1 ]]; then
    fail "could not scan the sandbox log for runtime errors (grep exit $grep_rc, log '$log')"
    return
  fi
  findings="$(printf '%s\n' "$findings" | grep -vE "$sandbox_noise")" || grep_rc=$?
  if [[ "$grep_rc" -gt 1 ]]; then
    fail "could not filter sandbox noise out of the runtime findings (grep exit $grep_rc)"
    return
  fi
  if [[ -n "$findings" ]]; then
    printf '%s\n' "$findings" >&2
    fail "QML/runtime errors in the sandboxed shell"
    return
  fi
  note "isolated runtime check passed (shell loaded, all ${#expected_plugins[@]} bundled plugins loaded, answered IPC in the sandbox)"
}

# --- run --------------------------------------------------------------------

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
