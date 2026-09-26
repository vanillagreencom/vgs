#!/usr/bin/env bash
# Run the shell inside a nested Hyprland sandbox and check it end to end.
#
# Usage: scripts/qml-smoke.sh [--timeout SECONDS] [--keep]
#
# The sandbox is built from the repository alone: its own HOME, XDG dirs and
# runtime dir, a minimal compositor config, no user state. It never touches
# the live session: the nested compositor gets its own runtime dir, the
# shell is addressed through that runtime dir, and teardown kills only the
# process groups this run created.
#
# Checks, in order: the runner starts the shell and it answers IPC; the
# instance guard reports true; every bundled plugin loads with no manifest
# error; one bar surface maps per monitor, registers its built-in
# workspaces and clock and mounts a placed plugin widget; a widget
# can be disabled and re-enabled with its placement and settings kept;
# disabling the bar names the widgets it hides, unloads it and unmaps its
# surface; an unrelated write and a rescan that changes nothing build
# nothing, and a rescan that adds a disabled plugin rebuilds each screen's
# bar and its placed widget and builds nothing for the new plugin; a user
# plugin installed with `vgsh plugin add` from a local repository is
# discovered, built as a service and a widget, receives exactly the
# capabilities it named, and takes a settings change without a rebuild;
# the shared clock ticks seconds once a format shows them; every capability
# delivers its object to the plugin that named it, none to one that named
# none, and releases it on disable, read back from the fixture, the core's
# lending record, the compositor and a private D-Bus; a panel, an overlay
# and a menu open on summon, take their placement and close on hide, and a
# background is drawn on the bottom layer of every screen; the bar's
# manager button opens a panel that lists, toggles and configures plugins,
# and the bar's settings hide it on every screen; a built-in listed twice
# in one section is drawn once; a plugin refused an
# exclusive capability builds once the holder lets go; a plugin that cannot
# take what the core assigns keeps nothing; a removed monitor takes its bar
# and its build records with it; an unreadable user file keeps the bar and
# refuses writes; a theme file recolours the bar and one that does not parse,
# is not an object or holds a role that is not a colour is logged and keeps
# the last good palette;
# a bare `qs` started beside the runner refuses to draw and to write, and
# the runner's CLI still reaches the guarded instance; the log holds no QML
# error; resident memory stays under the ceiling.
#
# Exit 0 when every check passed. Exit 77 when a prerequisite is missing,
# naming it, or when the nested compositor failed to allocate its output
# buffers during a run whose only failures are geometry rows; that is not
# a pass. Exit 1 when a
# check failed.
#
# VGSH_SMOKE_RSS_CEILING_KIB: resident-size ceiling for the shell process at
# the end of the run. It catches a startup allocation blow-up and nothing
# else: a run this short cannot see the slow growth docs/architecture/memory.md
# describes, and the reading carries the machine's graphics stack. The
# default is twice the rss_kib this script printed on the owner's machine
# (host cachy, AMD Ryzen 9 9950X) on 2026-09-25 with the one bundled plugin,
# the bar, plus the fixtures this run installs, on one nested monitor. The
# high-water mark is printed beside it as the reproducible reading.
#
# VGSH_SMOKE_FIRST_BAR_BUDGET_MS: ceiling on the time from the runner's exec
# to the first bar surface with a client in the compositor's layer list.
# VGSH_SMOKE_RECONCILE_BUDGET_MS: ceiling on the time from a
# setPluginEnabled reply to the build records no longer listing the
# disabled widget, polled with qs ipc. Both defaults are twice the highest
# reading of twelve runs of this script on the owner's machine (host cachy,
# AMD Ryzen 9 9950X) on 2026-09-23, which read 100 to 127 ms and 12 to
# 15 ms, each carrying its poll interval.
set -euo pipefail

timeout_s=60
keep=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) timeout_s="$2"; shift 2 ;;
    --keep) keep=true; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) printf 'qml-smoke: refused: argument=%s\n' "$1" >&2; exit 2 ;;
  esac
done

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
rss_ceiling_kib="${VGSH_SMOKE_RSS_CEILING_KIB:-574064}"
first_bar_budget_ms="${VGSH_SMOKE_FIRST_BAR_BUDGET_MS:-254}"
reconcile_budget_ms="${VGSH_SMOKE_RECONCILE_BUDGET_MS:-30}"

missing=()
for tool in Hyprland qs hyprctl python3 node flock setsid git dbus-daemon gdbus; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
[[ -n ${WAYLAND_DISPLAY:-} ]] || missing+=("WAYLAND_DISPLAY")
[[ -n ${XDG_RUNTIME_DIR:-} ]] || missing+=("XDG_RUNTIME_DIR")
if [[ ${#missing[@]} -gt 0 ]]; then
  printf 'qml-smoke: status=not-measured missing=%s\n' "$(IFS=,; echo "${missing[*]}")"
  exit 77
fi
host_socket="$WAYLAND_DISPLAY"
[[ $host_socket == /* ]] || host_socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
if [[ ! -S $host_socket ]]; then
  printf 'qml-smoke: status=not-measured missing=host-wayland-socket path=%s\n' "$host_socket"
  exit 77
fi

sandbox=""
rt_dir=""
pgids=()
failures=0
# A row that reads positions, sizes or reserved space from the compositor
# runs under `geometry`; every other failure counts as behaviour. Only a run
# whose failures are all geometry can be excused by a compositor fault.
behaviour_failures=0
row_class=behaviour
fail() {
  failures=$((failures + 1))
  [[ $row_class == geometry ]] || behaviour_failures=$((behaviour_failures + 1))
  printf '  FAIL  %s\n' "$*"
}
geometry() { local previous="$row_class"; row_class=geometry; "$@"; row_class="$previous"; }
# Error lines a row provokes on purpose, as extended regexes; the log check
# leaves out a line matching one of them.
expected_errors=()
ok() { printf '  ok    %s\n' "$*"; }

# Runs on every exit, so it is armed before either directory exists and
# removes only what was made.
cleanup() {
  local pg
  for pg in "${pgids[@]}"; do kill -TERM -- "-$pg" 2>/dev/null || true; done
  sleep 0.5
  for pg in "${pgids[@]}"; do kill -KILL -- "-$pg" 2>/dev/null || true; done
  if [[ $keep == true ]]; then
    echo "qml-smoke: sandbox kept at $sandbox (runtime dir $rt_dir)"
  else
    [[ -z $sandbox ]] || rm -rf -- "$sandbox"
    [[ -z $rt_dir ]] || rm -rf -- "$rt_dir"
  fi
}
trap cleanup EXIT

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vgsh-smoke.XXXXXX")"
# The runtime dir holds Unix sockets, whose paths are limited to 107 bytes,
# and Hyprland's socket path adds a 63-character signature under hypr/. A
# sandbox under a long TMPDIR made Hyprland refuse IPC, so the runtime dir
# is a short name beside the host's own runtime files.
rt_dir="$(mktemp -d "$XDG_RUNTIME_DIR/vs.XXXXXX")"
home="$sandbox/home"; mkdir -p "$home/.config/hypr"

cat >"$home/.config/hypr/hyprland.lua" <<'LUA'
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.config({
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true, disable_autoreload = true },
    animations = { enabled = false },
})
LUA

# node on PATH may be a version-manager shim that reads the developer's own
# configuration and fails under the sandbox HOME; the sandbox PATH leads with
# the directory of the binary it resolves to.
if ! node_bin="$(node -e 'process.stdout.write(process.execPath)')"; then
  printf 'qml-smoke: status=not-measured missing=node-binary\n'
  exit 77
fi
sandbox_env=(env -i
  HOME="$home" PATH="$(dirname -- "$node_bin"):$PATH" USER="${USER:-$(id -un)}" TERM=dumb LANG=C.UTF-8
  XDG_RUNTIME_DIR="$rt_dir" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share"
  XDG_STATE_HOME="$home/.local/state" XDG_CACHE_HOME="$home/.cache")

# Start a command in its own session and process group; the pid doubles as
# the pgid for teardown and is left in spawn_pid. Not a command substitution,
# because a subshell could not append to pgids.
spawn_pid=""
spawn() { # LOG CMD...
  local log="$1"; shift
  setsid "$@" >"$log" 2>&1 &
  spawn_pid=$!
  pgids+=("$spawn_pid")
}

# Two private D-Bus daemons stand in for the session and system buses, with
# no service directories, so nothing is activated on them and the shell's
# notification server and polkit agent never reach the user's buses.
bus_config() { # SOCKET
  cat <<XML
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$1</listen>
  <auth>EXTERNAL</auth>
  <policy context="default"><allow send_destination="*" eavesdrop="true"/><allow eavesdrop="true"/><allow own="*"/></policy>
</busconfig>
XML
}
bus_config "$rt_dir/bus" >"$sandbox/session-bus.xml"
bus_config "$rt_dir/system-bus" >"$sandbox/system-bus.xml"

echo "qml-smoke: sandbox $sandbox"
spawn "$sandbox/session-bus.log" "${sandbox_env[@]}" dbus-daemon --nofork --config-file="$sandbox/session-bus.xml"
spawn "$sandbox/system-bus.log" "${sandbox_env[@]}" dbus-daemon --nofork --config-file="$sandbox/system-bus.xml"
for _ in $(seq 1 50); do [[ -S $rt_dir/bus && -S $rt_dir/system-bus ]] && break; sleep 0.1; done
if [[ ! -S $rt_dir/bus || ! -S $rt_dir/system-bus ]]; then
  printf 'qml-smoke: status=not-measured missing=sandbox-bus\n'; exit 77
fi
spawn "$sandbox/hyprland.log" "${sandbox_env[@]}" WAYLAND_DISPLAY="$host_socket" Hyprland --config "$home/.config/hypr/hyprland.lua"
compositor_pid="$spawn_pid"

nested_socket=""
for _ in $(seq 1 200); do
  for candidate in "$rt_dir"/wayland-*; do
    [[ -S $candidate ]] && { nested_socket="${candidate##*/}"; break; }
  done
  [[ -n $nested_socket ]] && break
  kill -0 "$compositor_pid" 2>/dev/null || break
  sleep 0.1
done
if [[ -z $nested_socket ]]; then
  printf 'qml-smoke: status=not-measured missing=nested-compositor\n'
  tail -n 20 "$sandbox/hyprland.log"
  exit 77
fi
signature=""
for d in "$rt_dir"/hypr/*/; do [[ -d $d ]] && signature="$(basename "$d")"; done
if [[ -z $signature ]]; then
  printf 'qml-smoke: status=not-measured missing=nested-instance-signature\n'; exit 77
fi
ok "nested compositor up: socket=$nested_socket"

shell_env=("${sandbox_env[@]}" WAYLAND_DISPLAY="$nested_socket" HYPRLAND_INSTANCE_SIGNATURE="$signature"
  DBUS_SESSION_BUS_ADDRESS="unix:path=$rt_dir/bus" DBUS_SYSTEM_BUS_ADDRESS="unix:path=$rt_dir/system-bus")
hypr() { "${shell_env[@]}" hyprctl -i "$signature" "$@"; }

# The nested output can take a moment to appear. The shell starts after it
# does, so no bar is built for the placeholder screen Qt invents when a
# compositor has no output yet.
monitors=-1
for _ in $(seq 1 50); do
  if monitors="$(hypr -j monitors 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)" && [[ $monitors -gt 0 ]]; then break; fi
  sleep 0.2
done
if [[ $monitors -gt 0 ]]; then ok "nested compositor lists $monitors monitor(s)"; else
  printf 'qml-smoke: status=not-measured missing=nested-monitor\n'; exit 77
fi
# The shipped bar carries its clock and workspaces as built-ins, so the
# widget rows use a third-party widget placed in the user file before the
# shell starts.
tick="$home/.config/vgs/plugins/acme.tick"
mkdir -p "$tick"
cat >"$tick/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.tick", "name": "Tick", "version": "0.1.0", "author": "acme", "description": "smoke fixture widget",
  "kinds": ["bar-widget"], "entryPoints": { "bar-widget": "Widget.qml" }, "defaultSection": "center", "settings": { "format": "HH:mm" } }
JSON
cat >"$tick/Widget.qml" <<'QML'
import QtQuick
import qs.Ui
BarWidget {
    readonly property string format: String(setting("format", ""))
    implicitWidth: 20
    implicitHeight: barSize
}
QML
cat >"$home/.config/vgs/shell.json" <<'JSON'
{ "version": 1, "bar": { "id": "vgs.bar", "layout": { "left": [], "center": [{ "id": "acme.tick", "format": "ddd d MMM  HH:mm" }], "right": [] } } }
JSON

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
start_ms="$(now_ms)"
spawn "$sandbox/qs.log" "${shell_env[@]}" "$repo/bin/vgsh" run
shell_pid="$spawn_pid"

# Latency from the runner's exec to the first bar surface with a client,
# polled every 10 ms from the compositor's layer list, which answers in a
# few milliseconds; the reading carries at most one poll interval.
first_bar_ms=""
for _ in $(seq 1 $((timeout_s * 100))); do
  if layers_text="$(hypr layers 2>/dev/null)" && [[ $layers_text =~ namespace:\ vgs:bar,\ pid:\ [1-9] ]]; then
    first_bar_ms=$(( $(now_ms) - start_ms ))
    break
  fi
  kill -0 "$shell_pid" 2>/dev/null || break
  sleep 0.01
done

# qs prints its own log lines on stdout ahead of the reply; the reply is the last line.
ipc() { "${shell_env[@]}" "$repo/bin/vgsh" ipc call "$@" 2>>"$sandbox/ipc.log" | tail -n 1; }

up=false
for _ in $(seq 1 $((timeout_s * 5))); do
  if pong="$(ipc shell ping 2>/dev/null)" && [[ $pong == ok ]]; then up=true; break; fi
  kill -0 "$shell_pid" 2>/dev/null || break
  sleep 0.2
done
if [[ $up != true ]]; then
  fail "shell did not answer ping within ${timeout_s}s"
  tail -n 40 "$sandbox/qs.log"
  exit 1
fi
ok "shell answers ping"

# qs buffers stdout when redirected, so the shell's own per-instance log
# file is the record: it is line-flushed and holds every QML warning. The
# runner execs qs, so the shell's pid is the runner's unless setsid forked.
shell_qs_pid="$shell_pid"
if child="$(pgrep -P "$shell_pid" -x qs)"; then shell_qs_pid="$child"; fi
instance_log=""
for _ in $(seq 1 50); do
  if instance_id="$("${shell_env[@]}" qs list -p "$repo/shell" -j 2>/dev/null | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin) if i["pid"]==int(sys.argv[1])][0]["id"])' "$shell_qs_pid" 2>/dev/null)"; then
    instance_log="$rt_dir/quickshell/by-id/$instance_id/log.log"
    break
  fi
  sleep 0.2
done
if [[ -n $instance_log && -f $instance_log ]]; then ok "the shell's instance log is at $instance_log"; else fail "instance log not found for pid $shell_qs_pid"; exit 1; fi
# Lines of the instance log matching an extended regex, counted. grep exits
# 1 for a count of zero, which is an answer; anything above is a read or
# pattern failure: grep's message goes to stderr and the function returns 1.
# It runs inside a command substitution, so it never calls fail: the caller
# does, in the shell that holds the counters.
log_lines() {
  local count status=0
  count="$(grep -c -E -e "$1" -- "$instance_log")" || status=$?
  if [[ $status -gt 1 ]]; then return 1; fi
  printf '%s\n' "$count"
}
# expect_log LABEL COUNT PATTERN: the log holds at least COUNT matching
# lines within 5 s. A row that asserts something did not happen waits for
# the line the shell writes when it decides not to, then looks.
expect_log() {
  local label="$1" want="$2" pattern="$3" got=0
  for _ in $(seq 1 25); do
    if ! got="$(log_lines "$pattern")"; then
      fail "$label: instance log unreadable or pattern refused: $instance_log ($pattern)"
      return 0
    fi
    if [[ $got -ge $want ]]; then ok "$label"; return; fi
    sleep 0.2
  done
  fail "$label: log lines matching $pattern: $got want at least $want"
}

# expect LABEL WANT CMD...: the command's last stdout line must equal WANT.
# A command that fails is a failure, never an empty string that happens to
# compare unequal.
expect() {
  local label="$1" want="$2" got
  shift 2
  if ! got="$("$@")"; then fail "$label: command failed: $*"; return; fi
  if [[ $got == "$want" ]]; then ok "$label"; else fail "$label: got $got"; fi
}
# expect_poll LABEL WANT CMD...: as expect, retried for up to 5 s, for a
# state that follows a write through the watcher, the merge and a rebuild.
expect_poll() { # LABEL WANT CMD...
  local label="$1" want="$2" got=""
  shift 2
  for _ in $(seq 1 25); do
    if got="$("$@")" && [[ $got == "$want" ]]; then ok "$label"; return; fi
    sleep 0.2
  done
  fail "$label: got $got want $want"
}

expect "instance guard accepts the runner's shell" true ipc shell guarded

# Plugins scan asynchronously; wait for the bundled bar and the placed widget.
plugins_json=""
for _ in $(seq 1 100); do
  if plugins_json="$(ipc shell listPlugins)" && python3 -c 'import json,sys; d=json.load(sys.stdin); ids={p["id"] for p in d["plugins"]}; sys.exit(0 if {"vgs.bar","acme.tick"} <= ids else 1)' <<<"$plugins_json"; then break; fi
  sleep 0.2
done
if python3 - "$plugins_json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
by = {p["id"]: p for p in d["plugins"]}
missing = [i for i in ("vgs.bar", "acme.tick") if i not in by]
disabled = [i for i in by if i.startswith("vgs.") and not by[i]["enabled"]]
if missing or disabled or d["errors"] or d["collisions"]:
    print("missing=%s disabled=%s errors=%s collisions=%s" % (missing, disabled, d["errors"], d["collisions"]))
    sys.exit(1)
PY
then ok "bundled plugins discovered, enabled and error-free"; else fail "bundled plugin state"; fi

# Live bar surfaces the nested compositor lists. A layer whose client is
# gone stays in the list with pid -1 until the compositor drops it, so only
# a layer with a client counts. Space every monitor reserves for layers is
# read beside it: a bar that is gone reserves nothing.
bar_count() { hypr -j layers | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for m in d.values() for lv in m["levels"].values() for l in lv if l["namespace"]=="vgs:bar" and l["pid"]!=-1))'; }
reserved_total() { hypr -j monitors | python3 -c 'import json,sys; print(sum(sum(m["reserved"]) for m in json.load(sys.stdin)))'; }
# Live layers with a namespace as [[x, y, w, h], ...], sorted.
layers_of() { hypr -j layers | python3 -c 'import json,sys; print(json.dumps(sorted([l["x"],l["y"],l["w"],l["h"]] for m in json.load(sys.stdin).values() for lv in m["levels"].values() for l in lv if l["namespace"]==sys.argv[1] and l["pid"]!=-1)))' "$1"; }
layer_count() { layers_of "$1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
bars=-1
for _ in $(seq 1 50); do
  if bars="$(bar_count)" && [[ $bars == "$monitors" ]]; then break; fi
  sleep 0.2
done
if [[ $bars == "$monitors" && $monitors != 0 && $monitors != -1 ]]; then ok "one bar surface per monitor ($bars of $monitors)"; else fail "bar surfaces: $bars for $monitors monitors"; fi

# Widget ids every bar host built, left to right, from the core's own
# build records. Polls up to 5 s: a config write travels through the
# watcher, the merge and a rebuild before the record changes.
# A screen whose bar is unloaded has no record; it reads as an empty list.
bar_widget_ids() {
  ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); bars={k:[r["id"] for r in v if r["kind"]=="bar-widget"] for k,v in d.items() if k.startswith("bar:")}; out=sorted(bars.values()); out+= [[]]*(int(sys.argv[1])-len(out)); print(json.dumps(out))' "$monitors"
}
expect_widgets() { # LABEL EXPECTED_JSON_LIST
  local want got=""
  if ! want="$(python3 -c 'import json,sys; print(json.dumps([json.loads(sys.argv[1])]*int(sys.argv[2])))' "$2" "$monitors")"; then fail "$1: expected list unreadable"; return; fi
  for _ in $(seq 1 25); do
    if got="$(bar_widget_ids)" && [[ $got == "$want" ]]; then ok "$1"; return; fi
    sleep 0.2
  done
  fail "$1: got $got want $want"
}
expect_widgets "every bar mounted the placed plugin widget" '["acme.tick"]'
# Built-in widget ids every bar registered, sorted: the records of origin
# `plugin` under each bar host key.
bar_builtins() {
  ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); bars={k:sorted(r["id"] for r in v if r["origin"]=="plugin") for k,v in d.items() if k.startswith("bar:")}; out=sorted(bars.values()); out+= [[]]*(int(sys.argv[1])-len(out)); print(json.dumps(out))' "$monitors"
}
expect_builtins() { # LABEL EXPECTED_JSON_LIST
  local want got=""
  if ! want="$(python3 -c 'import json,sys; print(json.dumps([json.loads(sys.argv[1])]*int(sys.argv[2])))' "$2" "$monitors")"; then fail "$1: expected list unreadable"; return; fi
  for _ in $(seq 1 25); do
    if got="$(bar_builtins)" && [[ $got == "$want" ]]; then ok "$1"; return; fi
    sleep 0.2
  done
  fail "$1: got $got want $want"
}
expect_builtins "every bar registered its built-in workspaces, clock and plugin manager" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'

# A rebuild counter: the core counts every instance it builds. Rows below
# assert that an unrelated write and a rescan that changes nothing build
# nothing, and what a rescan that adds a disabled plugin builds.
builds() { ipc shell buildCount; }
expect "the core built the bar and its placed widget per screen, and no built-in" "$((2 * monitors))" builds

# Disable only lists the id: the layout entry and its settings stay, so
# re-enabling restores the exact screen. The effective configuration is
# read back for the entry, the user file for what the manager wrote.
# Latency from a setPluginEnabled reply to `built` reflecting it, polled
# with qs ipc against the shell's pid; the reading carries one IPC round trip.
reconcile_ms=""
if disable_reply="$(ipc shell setPluginEnabled acme.tick false)"; then
  replied_ms="$(now_ms)"
  for _ in $(seq 1 500); do
    if built_now="$("${shell_env[@]}" qs ipc --pid "$shell_pid" call shell built 2>>"$sandbox/ipc.log" | tail -n 1)" && [[ -n $built_now && $built_now != *'"id":"acme.tick"'* ]]; then
      reconcile_ms=$(( $(now_ms) - replied_ms ))
      break
    fi
    sleep 0.005
  done
fi
if [[ $disable_reply == ok ]]; then ok "disabling a widget is allowed"; else fail "disabling a widget is allowed: got $disable_reply"; fi
tick_state() { ipc shell listPlugins | python3 -c 'import json,sys; d=json.load(sys.stdin); print([p["enabled"] for p in d["plugins"] if p["id"]=="acme.tick"][0])'; }
tick_entry() { ipc shell listShellConfig | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([e for e in d["bar"]["layout"]["center"] if e["id"]=="acme.tick"]))'; }
user_keys() { python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])).keys())))' "$home/.config/vgs/shell.json"; }
expect_widgets "the bar dropped the disabled widget" '[]'
expect_builtins "the built-ins stay while a plugin widget leaves" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
expect "widget reads disabled after the user file changed" False tick_state
expect "the disabled widget keeps its layout entry and settings" '[{"id": "acme.tick", "format": "ddd d MMM  HH:mm"}]' tick_entry
expect "disable wrote only the disabled list" "bar,disabledPlugins,version" user_keys
expect "re-enabling the widget is allowed" ok ipc shell setPluginEnabled acme.tick true
expect_widgets "the bar rebuilt the re-enabled widget" '["acme.tick"]'
expect "re-enable wrote only the disabled list" "bar,disabledPlugins,version" user_keys

expect "disabling the bar names the widgets it hides" "ok hidden=acme.tick" ipc shell setPluginEnabled vgs.bar false
expect_widgets "the bar host unloaded the disabled bar" '[]'
expect_builtins "the disabled bar's built-ins left the build records" '[]'
bars_now=-1
for _ in $(seq 1 50); do
  if bars_now="$(bar_count)" && [[ $bars_now == 0 ]]; then break; fi
  sleep 0.2
done
if [[ $bars_now == 0 ]]; then ok "the bar host destroyed its surface with no bar"; else fail "bar surfaces with the bar disabled: $bars_now"; fi
expect "no bar reserves no screen space" 0 reserved_total
expect "re-enabling the bar is allowed" ok ipc shell setPluginEnabled vgs.bar true
expect_widgets "the bar host rebuilt the re-enabled bar" '["acme.tick"]'
monitor_size() { hypr -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print(m["width"], m["height"], m["reserved"][1])'; }
expect_builtins "the re-enabled bar registered its built-ins again" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
for _ in $(seq 1 50); do
  if bars_now="$(bar_count)" && [[ $bars_now == "$monitors" ]]; then break; fi
  sleep 0.2
done
if [[ $bars_now == "$monitors" ]]; then ok "the bar host mapped its surface again"; else fail "bar surfaces after re-enable: $bars_now"; fi
reserved=0
for _ in $(seq 1 50); do
  if reserved="$(reserved_total)" && [[ $reserved -gt 0 ]]; then break; fi
  sleep 0.2
done
if [[ $reserved -gt 0 ]]; then ok "the re-enabled bar reserves screen space again"; else geometry fail "reserved space after re-enable: $reserved"; fi
if [[ -f "$home/.config/vgs/shell.json" ]]; then ok "manager wrote the user file"; else fail "user file missing"; fi

# An unrelated key in the user file builds nothing: the shell is seen to
# have read the write (the key is in the effective configuration) before
# the build count is compared. Every write the smoke makes to the user file
# is a rename, so the watching shell never reads half a file.
unrelated_key() { ipc shell listShellConfig | python3 -c 'import json,sys; print(json.load(sys.stdin).get("unrelated"))'; }
if before="$(builds)"; then
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["unrelated"] = 1
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
  expect_poll "the shell read the unrelated key" 1 unrelated_key
  expect "an unrelated configuration write rebuilds nothing" "$before" builds
  # Every completed scan logs whether the plugin set changed. A rescan
  # that changes nothing leaves the generation alone, so it builds
  # nothing; the logged line is the scan's completion.
  if unchanged_scans="$(log_lines 'plugins: scan complete changed=false ')"; then
    expect "a rescan that changes nothing answers ok" ok ipc shell rescanPlugins
    expect_log "the rescan that changes nothing completed" "$((unchanged_scans + 1))" 'plugins: scan complete changed=false '
    expect "a rescan that changes nothing rebuilds nothing" "$before" builds
  else
    fail "instance log unreadable: $instance_log"
  fi
  # A rescan that adds a plugin nothing enables changes the set: it bumps
  # the generation every slot keys on, so each screen's bar and its placed
  # widget are built again, and nothing is built for the new plugin. The
  # new plugin's appearance in the listing is the scan's completion.
  idle="$home/.config/vgs/plugins/acme.idle"
  mkdir -p "$idle"
  cat >"$idle/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.idle", "name": "Idle", "version": "0.1.0", "author": "acme", "description": "smoke fixture nothing enables",
  "kinds": ["service"], "entryPoints": { "service": "Service.qml" } }
JSON
  printf 'import QtQuick\nItem { property var shell: null }\n' >"$idle/Service.qml"
  expect "a rescan after adding a plugin answers ok" ok ipc shell rescanPlugins
  idle_state() { ipc shell listPlugins | python3 -c 'import json,sys; print([p["enabled"] for p in json.load(sys.stdin)["plugins"] if p["id"]=="acme.idle"][0])' 2>/dev/null || echo absent; }
  expect_poll "the rescan discovered the plugin, disabled" False idle_state
  idle_built() { ipc shell built | python3 -c 'import json,sys; print(any(r["id"]=="acme.idle" for rows in json.load(sys.stdin).values() for r in rows))'; }
  expect_poll "a rescan that adds a plugin rebuilds each screen's bar and widget" "$((before + 2 * monitors))" builds
  expect "a rescan that adds a disabled plugin does not build it" False idle_built
  expect "a rescan that adds a disabled plugin builds nothing else" "$((before + 2 * monitors))" builds
else
  fail "buildCount unreadable"
fi

# A fixture plugin in the sandbox user directory: kind service plus a bar
# widget, naming every capability. Proves user-directory discovery, the
# service host, that each instance receives exactly the capabilities its
# manifest names, that a settings change reaches a running instance without
# a rebuild, and that every capability delivers its object and releases it
# on disable. The service registers through its capabilities once and
# answers IPC calls that drive the rest. The rows read the fixture's own
# properties back through readInstance, never the build records.
fixture="$sandbox/src/acme.probe"
mkdir -p "$fixture"
cat >"$fixture/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.probe", "name": "Probe", "version": "0.1.0", "author": "acme", "description": "smoke fixture",
  "kinds": ["service", "bar-widget"], "entryPoints": { "service": "Service.qml", "bar-widget": "Widget.qml" },
  "defaultSection": "right", "settings": { "label": "probe", "tags": ["a", "b"] },
  "schema": { "label": { "type": "string", "label": "Label" } },
  "capabilities": ["compositor", "configure", "ipc", "lock", "notifications", "polkit", "run", "screens", "shortcut"] }
JSON
cat >"$fixture/Service.qml" <<'QML'
import QtQuick
Item {
    id: root
    property var shell: null
    readonly property string label: shell === null ? "" : String(shell.settings.label)
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    property bool registered: false
    property int presses: 0
    property string duplicateShortcut: ""
    property string duplicateIpc: ""
    property int notified: 0
    property string lastSummary: ""
    readonly property bool lockSecure: shell !== null && shell.lock.secure
    readonly property bool hasAgent: shell !== null && shell.polkit.agent !== null
    readonly property bool agentRegistered: shell !== null && shell.polkit.registered
    readonly property int screenCount: shell === null ? -1 : shell.screens.all.length
    readonly property bool noCurrentScreen: shell !== null && shell.screens.current === null

    Component { id: lockContent; Item { property var screen: null } }

    onShellChanged: {
        if (shell === null || registered) return;
        registered = true;
        shell.shortcut.register("ping", "smoke probe", () => root.presses += 1);
        try { shell.shortcut.register("ping", "again", () => {}); } catch (e) { root.duplicateShortcut = e.message; }
        shell.ipc.handle("echo", arg => arg);
        try { shell.ipc.handle("echo", arg => arg); } catch (e) { root.duplicateIpc = e.message; }
        shell.ipc.handle("set", arg => { const at = arg.indexOf("="); return root.shell.configure.set(arg.slice(0, at), JSON.parse(arg.slice(at + 1))); });
        shell.ipc.handle("touch", path => root.shell.run.detached(["touch", path]));
        shell.ipc.handle("lock", () => root.shell.lock.lock(lockContent));
        shell.ipc.handle("unlock", () => root.shell.lock.unlock());
        shell.ipc.handle("dispatch", arg => { const a = arg.split(" "); return root.shell.compositor[a[0]].apply(null, a.slice(1)); });
        shell.notifications.subscribe(n => { root.notified += 1; root.lastSummary = n.summary; });
        // A lock holder rebuilt into a locked session hands its screen over again.
        if (shell.lock.locked) shell.lock.lock(lockContent);
    }
}
QML
cat >"$fixture/Widget.qml" <<'QML'
import QtQuick
import qs.Ui
BarWidget {
    moduleName: "acme.probe"
    implicitWidth: 10
    implicitHeight: barSize
    readonly property bool hasCompositor: shell !== null && shell.compositor !== undefined && typeof shell.compositor.focusWorkspace === "function"
    readonly property bool tagsAreArray: Array.isArray(settings.tags)
    readonly property string label: String(setting("label", ""))
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
    readonly property string currentScreen: shell === null || shell.screens.current === null ? "" : shell.screens.current.name
    function setLabel(value) { return shell.configure.set("label", value); }
}
QML
# A second user plugin naming no capability, beside the fixture.
bare="$home/.config/vgs/plugins/acme.bare"
mkdir -p "$bare"
cat >"$bare/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.bare", "name": "Bare", "version": "0.1.0", "author": "acme", "description": "smoke fixture without capabilities",
  "kinds": ["service"], "entryPoints": { "service": "Service.qml" } }
JSON
cat >"$bare/Service.qml" <<'QML'
import QtQuick
Item {
    property var shell: null
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
}
QML
# The fixture reaches the user directory the way a user's plugin does:
# committed to a repository and installed with `vgsh plugin add`.
fixture_git() { "${sandbox_env[@]}" git -C "$fixture" -c user.name=smoke -c user.email=smoke@invalid "$@" >>"$sandbox/git.log" 2>&1; }
if fixture_git init -q && fixture_git add -A && fixture_git commit -q -m fixture; then ok "fixture committed to a local repository"; else fail "fixture repository: $(tail -n 3 "$sandbox/git.log")"; fi
add_out=""
if add_out="$("${shell_env[@]}" "$repo/bin/vgsh" plugin add "file://$fixture" 2>>"$sandbox/ipc.log")" \
  && [[ $add_out == $'ok added=acme.probe path='"$home/.config/vgs/plugins/acme.probe"$' config=unchanged\nshell=rescan-started' ]]; then
  ok "vgsh plugin add installs the fixture and rescans the shell"
else
  fail "vgsh plugin add: $add_out"
fi
probe_state() { ipc shell listPlugins | python3 -c 'import json,sys; d=json.load(sys.stdin); print([p["enabled"] for p in d["plugins"] if p["id"]=="acme.probe"][0])' 2>/dev/null || echo absent; }
found=""
for _ in $(seq 1 25); do if found="$(probe_state)" && [[ $found == False ]]; then break; fi; sleep 0.2; done
if [[ $found == False ]]; then ok "user-directory plugin discovered and disabled until enabled"; else fail "fixture after rescan: $found"; fi
expect "enabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
expect "enabling the bare fixture is allowed" ok ipc shell setPluginEnabled acme.bare true
service_built() { ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(r["id"]=="acme.probe" and r["kind"]=="service" for r in d.get("service",[])))'; }
# The first bar host's key, for reading a widget instance back.
bar_key() { ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(k for k in d if k.startswith("bar:"))[0])'; }
read_widget() { ipc shell readInstance "$(bar_key)" acme.probe "$1"; }
read_service() { ipc shell readInstance service acme.probe "$1"; }
read_clock() { ipc shell readInstance "$(bar_key)" vgs.bar/center-clock "$1"; }
read_tick() { ipc shell readInstance "$(bar_key)" acme.tick "$1"; }
got=""
for _ in $(seq 1 25); do if got="$(service_built)" && [[ $got == True ]]; then break; fi; sleep 0.2; done
if [[ $got == True ]]; then ok "the service host built the fixture service"; else fail "service host: built=$got"; fi
expect_widgets "the fixture widget joined the right section" '["acme.tick","acme.probe"]'
expect "the fixture widget can call its compositor capability" true read_widget hasCompositor
expect "the fixture widget's settings array stayed an array" true read_widget tagsAreArray
all_caps='"compositor,configure,ipc,lock,manifest,notifications,polkit,run,screens,settings,shortcut"'
expect "the fixture widget's shell holds exactly what it named" "$all_caps" read_widget shellKeys
expect "the fixture service's shell holds exactly what it named" "$all_caps" read_service shellKeys
expect_poll "a plugin naming no capability receives none" '"manifest,settings"' ipc shell readInstance service acme.bare shellKeys
expect "the fixture service reads the manifest default" '"probe"' read_service label
expect "a placed widget reads its layout entry" '"ddd d MMM  HH:mm"' read_tick format
expect "the built-in clock reads the bar's clock format" '"ddd d MMM  HH:mm"' read_clock format

# The built-in workspaces focus through the bar's own compositor capability.
active_ws() { hypr -j activeworkspace | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
expect "the built-in workspaces focus a workspace" ok ipc shell invokeInstance "$(bar_key)" vgs.bar/left-workspaces focusWorkspace 2
expect_poll "the compositor moved to the clicked workspace" 2 active_ws
expect_poll "the built-in workspaces focus the first workspace again" ok ipc shell invokeInstance "$(bar_key)" vgs.bar/left-workspaces focusWorkspace 1
expect_poll "the compositor moved back to the first workspace" 1 active_ws

# A settings change reaches the running instance and builds nothing: the
# service's plugins[] row, then the clock's layout entry.
if before="$(builds)"; then
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["plugins"] = [e for e in d.get("plugins", []) if e["id"] != "acme.probe"] + [{"id": "acme.probe", "label": "changed-service-setting"}]
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
  expect_poll "the running service received its changed setting" '"changed-service-setting"' read_service label
  expect "the fixture widget keeps the manifest default its entry does not override" '"probe"' read_widget label
  expect "a service settings change rebuilds nothing" "$before" builds
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
center = d["bar"]["layout"]["center"]
[e for e in center if e["id"] == "acme.tick"][0]["format"] = "HH:mm:ss"
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
  expect_poll "the running widget received its changed layout entry" '"HH:mm:ss"' read_tick format
  expect "a widget settings change rebuilds nothing" "$before" builds
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["plugins"] = [e for e in d.get("plugins", []) if e["id"] != "vgs.bar"] + [{"id": "vgs.bar", "clockFormat": "HH:mm:ss"}]
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
  expect_poll "the built-in clock received the bar's changed setting" '"HH:mm:ss"' read_clock format
  # The shared clock ticks seconds only while a format shows them: three
  # readings across 2.2 s change at least twice at second precision.
  clock_changes=0; clock_last=""
  for _ in 1 2 3; do
    if clock_now="$(read_clock displayed)"; then
      [[ -n $clock_last && $clock_now != "$clock_last" ]] && clock_changes=$((clock_changes + 1))
      clock_last="$clock_now"
    fi
    sleep 1.1
  done
  if [[ $clock_changes -ge 2 ]]; then ok "the shared clock ticks seconds for a seconds format"; else fail "clock text changed $clock_changes times in 2.2 s"; fi
  expect "a bar settings change rebuilds nothing" "$before" builds
  expect_builtins "the built-ins stay registered across a bar settings change" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
else
  fail "buildCount unreadable before the settings rows"
fi
# Capabilities, each driven through the fixture's own IPC target and read
# back from the fixture, the core's lending record and the compositor or bus
# the capability reaches.
lent() { ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d
for k in sys.argv[1].split("."): v=v.get(k) if isinstance(v, dict) else None
print(json.dumps(v))' "$1"; }
# qs ipc reads a bracketed argument as a list, so no argument here is JSON
# with brackets: `set` takes key=value with a JSON value, `dispatch` a
# dispatcher and its arguments separated by spaces.
probe() { ipc acme.probe invoke "$1" "${2:-}"; }
# The fixture holds every capability and the bare fixture none; another
# plugin may hold a shared capability beside the fixture.
lent_holds() { ipc shell lent | python3 -c 'import json,sys; h=json.load(sys.stdin)["holders"].get(sys.argv[1],[]); print("acme.probe" in h and "acme.bare" not in h)' "$1"; }
for cap in compositor configure ipc lock notifications polkit run screens shortcut; do
  expect "the $cap capability is lent to the fixture and not the bare plugin" True lent_holds "$cap"
done

expect "the fixture's shortcut is registered under its id" '["acme.probe:ping"]' lent shortcuts
count_lines() { python3 -c 'import sys; print(sum(1 for line in sys.stdin if sys.argv[1] in line))' "$1"; }
hypr_shortcuts() { hypr globalshortcuts | count_lines 'acme.probe:ping'; }
expect_poll "the compositor lists the fixture's shortcut" 1 hypr_shortcuts
expect "the compositor triggers the fixture's shortcut" ok hypr dispatch 'hl.dsp.global("acme.probe:ping")'
expect_poll "the fixture's shortcut handler ran" 1 read_service presses
expect "a second shortcut with the same name is refused" '"refused: shortcut=acme.probe:ping held"' read_service duplicateShortcut

ipc_targets() { "${shell_env[@]}" qs ipc --pid "$shell_pid" show 2>>"$sandbox/ipc.log" | count_lines 'target acme.probe'; }
expect "qs lists the fixture's IPC target" 1 ipc_targets
expect "the fixture answers on its IPC target" hello probe echo hello
expect "a second IPC handler with the same name is refused" '"refused: ipc=acme.probe:echo held"' read_service duplicateIpc

expect "configure writes a declared setting" ok probe set 'label="via-configure"'
expect_poll "the running service received the setting it wrote" '"via-configure"' read_service label
expect "configure refuses a value of the wrong type" "refused: setting=label want=string" probe set 'label=3'
expect "configure refuses an undeclared setting" "refused: setting=tags undeclared" probe set 'tags="x"'

# A widget placed twice writes only the layout entry it reads.
right_entries() {
  python3 - "$home/.config/vgs/shell.json" "$1" <<'PY'
import json, os, sys
p, action = sys.argv[1], sys.argv[2]
d = json.load(open(p))
right = d["bar"]["layout"]["right"]
if action == "add":
    right.append({"id": "acme.probe", "label": "second"})
elif action == "drop":
    d["bar"]["layout"]["right"] = [e for e in right if not (e["id"] == "acme.probe" and e.get("label") == "second")]
else:
    print(json.dumps([e.get("label") for e in right if e["id"] == "acme.probe"]))
    sys.exit(0)
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
}
probe_widgets() { ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for r in d[sys.argv[1]] if r["id"]=="acme.probe"))' "$(bar_key)"; }
right_entries add
expect_poll "the fixture widget is placed twice" 2 probe_widgets
expect "a widget's configure writes only its own layout entry" ok ipc shell invokeInstance "$(bar_key)" acme.probe setLabel only-first
labels_now() { right_entries show; }
expect_poll "the other entry keeps its setting" '["only-first", "second"]' labels_now
right_entries drop
expect_poll "the second placement is gone" 1 probe_widgets

expect "run starts a detached process" ok probe touch "$sandbox/touched-by-run"
touched() { [[ -f $sandbox/touched-by-run ]] && echo yes || echo no; }
expect_poll "the detached process ran" yes touched

bus_owner() { "${shell_env[@]}" gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner "$1" 2>>"$sandbox/ipc.log"; }
expect_poll "the core's notification server owns the bus name" "(true,)" bus_owner org.freedesktop.Notifications
notify() { "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.Notify smoke 0 '' probe-summary probe-body '[]' '{}' 5000 >/dev/null 2>>"$sandbox/ipc.log" && echo sent; }
expect "a client sends a notification" sent notify
expect_poll "the fixture's subscriber received it" '"probe-summary"' read_service lastSummary

expect "the polkit agent exists while the fixture holds it" true lent polkitAgent
expect "the fixture reads the lent polkit agent" true read_service hasAgent
expect "the agent reports no registration on a bus without polkitd" false read_service agentRegistered
expect "the lending record reports the registration" false lent polkitRegistered

expect "the fixture locks the session" ok probe lock
expect_poll "the compositor confirms the lock" true read_service lockSecure
# A rebuild while locked keeps the session locked, and the rebuilt holder
# hands its screen over again. A changed manifest makes every slot rebuild.
python3 - "$bare/manifest.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["version"] = "0.1.1"
json.dump(d, open(p + ".tmp", "w"))
os.replace(p + ".tmp", p)
PY
lock_content() { lent lock.content; }
if before="$(builds)"; then
  expect "a rescan while locked answers ok" ok ipc shell rescanPlugins
  rebuilt() { local now; now="$(builds)" && [[ $now -gt $before ]] && echo rebuilt || echo same; }
  expect_poll "the changed manifest rebuilt the plugins" rebuilt rebuilt
  expect_poll "the rebuilt holder handed its screen over again" true lock_content
  expect "the session stayed locked through the rebuild" true read_service lockSecure
  expect "the rebuilt fixture answers on its IPC target" hello probe echo hello
  presses_before="$(read_service presses)"
  expect "the compositor triggers the rebuilt fixture's shortcut" ok hypr dispatch 'hl.dsp.global("acme.probe:ping")'
  expect_poll "the rebuilt fixture's shortcut handler ran" "$((presses_before + 1))" read_service presses
else
  fail "buildCount unreadable before the lock rebuild rows"
fi
expect "the fixture unlocks the session" ok probe unlock
expect_poll "the compositor released the lock" false read_service lockSecure

expect "the fixture service sees every screen" "$monitors" read_service screenCount
expect "a service draws on no screen" true read_service noCurrentScreen
expect "the fixture widget draws on its bar's screen" "\"$(bar_key | sed 's/^bar://')\"" read_widget currentScreen

special_ws() { hypr -j monitors | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["specialWorkspace"]["name"])'; }
expect "the fixture toggles a special workspace" ok probe dispatch 'toggleSpecialWorkspace probe'
expect_poll "the compositor shows the special workspace" "special:probe" special_ws
expect_poll "the fixture closes the special workspace again" ok probe dispatch 'toggleSpecialWorkspace probe'
expect_poll "the compositor hides the special workspace" "" special_ws
expect "the fixture focuses a workspace" ok probe dispatch 'focusWorkspace 2'
expect_poll "the compositor moved to that workspace" 2 active_ws
expect_poll "the fixture focuses the first workspace again" ok probe dispatch 'focusWorkspace 1'
expect_poll "the compositor moved back" 1 active_ws

# The plugin manager: the bar's manager button opens the bar's own panel
# under it, which lists every plugin, toggles one through the core's
# setPluginEnabled path and writes a setting through its form.
read -r mon_w mon_h bar_reserved < <(monitor_size)
expect "the manager button opens the manager panel" ok ipc shell invokeInstance "$(bar_key)" vgs.bar/right-manager toggle ''
panel_top() { layers_of vgs:panel | python3 -c 'import json,sys; print([l[1] for l in json.load(sys.stdin)])'; }
geometry expect_poll "the manager panel sits under the bar" "[$((bar_reserved + 8))]" panel_top
manager_rows() { ipc shell readInstance panel vgs.bar plugins | python3 -c 'import json,sys; rows=json.load(sys.stdin); print(json.dumps({r["id"]: r["enabled"] for r in rows if r["id"] in ("acme.probe", "acme.bare", "vgs.bar")}, sort_keys=True))'; }
expect "the manager panel lists every plugin with its state" '{"acme.bare": true, "acme.probe": true, "vgs.bar": true}' manager_rows
# The panel draws one field per key of each row's schema; the rows it holds
# carry the schema keys the fields come from, and drawnFields counts the
# fields each form's Repeater drew.
manager_fields() { ipc shell readInstance panel vgs.bar plugins | python3 -c 'import json,sys; by={r["id"]: sorted(r["schema"]) for r in json.load(sys.stdin)}; print(json.dumps([by["acme.probe"], by["vgs.bar"], by["acme.bare"]]))'; }
expect "the manager panel holds the schema keys its form draws" '[["label"], ["clockFormat"], []]' manager_fields
manager_drawn() { ipc shell readInstance panel vgs.bar drawnFields | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d.get("acme.probe"), d.get("vgs.bar"), d.get("acme.bare")]))'; }
expect_poll "the manager panel draws one field per schema key" '[1, 1, 0]' manager_drawn
probe_enabled() { ipc shell listPlugins | python3 -c 'import json,sys; print([p["enabled"] for p in json.load(sys.stdin)["plugins"] if p["id"]=="acme.probe"][0])'; }
expect "the manager toggles the fixture off" ok ipc shell invokeInstance panel vgs.bar toggle acme.probe
expect_poll "listPlugins reads the fixture disabled" False probe_enabled
expect_poll "the manager panel shows the fixture disabled" '{"acme.bare": true, "acme.probe": false, "vgs.bar": true}' manager_rows
# The panel logs each refusal it shows on a row.
expected_errors+=('manager panel: acme\.probe refused: disabled=acme\.probe' 'manager panel: acme\.probe refused: setting=tags undeclared')
expect "the manager refuses a setting for a disabled plugin" "refused: disabled=acme.probe" ipc shell invokeInstance panel vgs.bar applySetting '{"id":"acme.probe","key":"label","value":"x"}'
expect "the manager panel shows the refusal on the plugin's row" '{"acme.probe":"refused: disabled=acme.probe"}' ipc shell readInstance panel vgs.bar replies
expect "the manager toggles the fixture back on" ok ipc shell invokeInstance panel vgs.bar toggle acme.probe
expect_poll "listPlugins reads the fixture enabled" True probe_enabled
expect "the manager form writes the fixture's setting" ok ipc shell invokeInstance panel vgs.bar applySetting '{"id":"acme.probe","key":"label","value":"via-manager"}'
expect "a successful write clears the row's refusal" '{}' ipc shell readInstance panel vgs.bar replies
expect_poll "the running service received the manager's setting" '"via-manager"' read_service label
expect_poll "the running widget received the manager's setting" '"via-manager"' read_widget label
# A drawn field's apply, as an edit in the form emits it, writes through
# writeSetting; the manager's rows read the setting back.
manager_label() { ipc shell readInstance panel vgs.bar plugins | python3 -c 'import json,sys; print(json.dumps([r["settings"]["label"] for r in json.load(sys.stdin) if r["id"]=="acme.probe"][0]))'; }
expect "the fixture's drawn label field applies an edit" applied ipc shell invokeInstance panel vgs.bar applyField '{"id":"acme.probe","key":"label","value":"via-field"}'
expect_poll "the manager reads back the setting the field wrote" '"via-field"' manager_label
expect "the manager refuses a setting outside the schema" "refused: setting=tags undeclared" ipc shell invokeInstance panel vgs.bar applySetting '{"id":"acme.probe","key":"tags","value":"x"}'
expect "the manager button closes the manager panel" ok ipc shell invokeInstance "$(bar_key)" vgs.bar/right-manager toggle ''
expect_poll "the manager panel is gone" 0 layer_count vgs:panel
bar_row() { # [SECTION] JSON list of built-ins for that section, right by default
  local section=right
  [[ $# -eq 2 ]] && { section="$1"; shift; }
  python3 - "$home/.config/vgs/shell.json" "$1" "$section" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
rows = d.setdefault("plugins", [])
row = [e for e in rows if e["id"] == "vgs.bar"]
if not row:
    rows.append({"id": "vgs.bar"})
    row = rows[-1:]
row[0][sys.argv[3]] = json.loads(sys.argv[2])
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
}
bar_row '[]'
expect_builtins "hiding the manager in the bar's settings removes it from every screen" '["vgs.bar/center-clock","vgs.bar/left-workspaces"]'
bar_row '["manager"]'
expect_builtins "listing the manager again brings it back on every screen" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
bar_row left '["clock","workspaces"]'
expect_builtins "the same built-in in two sections registers in both" '["vgs.bar/center-clock","vgs.bar/left-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
bar_row center '[]'
expect_builtins "moving and reordering built-ins keeps every one registered" '["vgs.bar/left-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
read_moved_clock() { ipc shell readInstance "$(bar_key)" vgs.bar/left-clock format; }
expect "the moved clock is the registered one" '"HH:mm:ss"' read_moved_clock
bar_row left '["workspaces"]'
bar_row center '["clock"]'
expect_builtins "the built-ins return to their sections" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
# A name listed twice in one section is drawn once and the repeat logged by
# every bar; the logged line proves the bar read the setting.
expected_errors+=('vgs\.bar: setting left lists a built-in twice, drawn once: ')
bar_row left '["workspaces","workspaces"]'
expect_log "a built-in listed twice in one section is logged by every bar" "$monitors" 'vgs\.bar: setting left lists a built-in twice, drawn once: '
expect_builtins "a built-in listed twice in one section registers once" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
bar_row left '["workspaces"]'

locker="$home/.config/vgs/plugins/acme.locker"
mkdir -p "$locker"
cat >"$locker/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.locker", "name": "Locker", "version": "0.1.0", "author": "acme", "description": "smoke fixture holding the lock",
  "kinds": ["service"], "entryPoints": { "service": "Service.qml" }, "capabilities": ["lock"] }
JSON
cat >"$locker/Service.qml" <<'QML'
import QtQuick
Item { property var shell: null }
QML
expect "rescan after adding the lock fixture answers ok" ok ipc shell rescanPlugins
locker_known() { ipc shell listPlugins | python3 -c 'import json,sys; print(any(p["id"]=="acme.locker" for p in json.load(sys.stdin)["plugins"]))'; }
expect_poll "the lock fixture is discovered" True locker_known
expect "enabling a second lock plugin is allowed" ok ipc shell setPluginEnabled acme.locker true
locker_built() { ipc shell built | python3 -c 'import json,sys; print(any(r["id"]=="acme.locker" for r in json.load(sys.stdin).get("service",[])))'; }
expect_poll "the lock stays with its first holder" '["acme.probe"]' lent holders.lock
expect "the second lock plugin is not built while the lock is held" False locker_built

expect "disabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe false
expect_poll "the second lock plugin builds once the holder is disabled" True locker_built
expect_poll "the lock moved to the second plugin" '["acme.locker"]' lent holders.lock
expect "disabling the second lock plugin is allowed" ok ipc shell setPluginEnabled acme.locker false
expect_widgets "the fixture widget left the bar" '["acme.tick"]'
got=""
for _ in $(seq 1 25); do if got="$(service_built)" && [[ $got == False ]]; then break; fi; sleep 0.2; done
if [[ $got == False ]]; then ok "the service host destroyed the disabled service"; else fail "service still built: $got"; fi
fixture_holds() { ipc shell lent | python3 -c 'import json,sys; print(sorted(k for k,v in json.load(sys.stdin)["holders"].items() if "acme.probe" in v))'; }
expect_poll "disable released every capability hold" '[]' fixture_holds
expect "disable released the shortcut" '[]' lent shortcuts
expect "disable released the IPC target" '[]' lent ipcTargets
expect "disable released the notification subscriber" '[]' lent subscribers
expect "disable destroyed the notification server" false lent notificationServer
expect "disable destroyed the polkit agent" false lent polkitAgent
expect_poll "the compositor dropped the fixture's shortcut" 0 hypr_shortcuts
expect "qs lists no IPC target for the disabled fixture" 0 ipc_targets
expect "disabling the bare fixture is allowed" ok ipc shell setPluginEnabled acme.bare false

# Hosts: a fixture of every summonable kind plus a background and a bar
# widget. Each summonable kind opens on demand in its own layer surface and
# is destroyed on hide; the background is drawn on every screen while
# enabled. Geometry is read from the compositor's layer list.
surf="$home/.config/vgs/plugins/acme.surfaces"
mkdir -p "$surf"
cat >"$surf/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.surfaces", "name": "Surfaces", "version": "0.1.0", "author": "acme", "description": "smoke fixture for the hosts",
  "kinds": ["panel", "overlay", "menu", "background", "bar-widget"],
  "entryPoints": { "panel": "Summoned.qml", "overlay": "Summoned.qml", "menu": "Summoned.qml", "background": "Background.qml", "bar-widget": "Widget.qml" },
  "defaultSection": "right", "settings": { "placement": "top-right" }, "capabilities": ["surfaces", "run"] }
JSON
cat >"$surf/Summoned.qml" <<'QML'
import QtQuick
Item {
    property var shell: null
    property int opened: 0
    property string lastPayload: ""
    implicitWidth: 200
    implicitHeight: 120
    // A payload may name a file close() creates, and may ask open() to throw.
    function open(payloadJson) {
        opened += 1;
        lastPayload = payloadJson;
        if (JSON.parse(payloadJson).fail === true) throw new Error("probe open refused");
    }
    function close() {
        const marker = JSON.parse(lastPayload).closeMarker;
        if (marker !== undefined) shell.run.detached(["touch", marker]);
    }
}
QML
cat >"$surf/Background.qml" <<'QML'
import QtQuick
Item {
    property var shell: null
    property var screen: null
    readonly property string screenName: screen === null ? "" : screen.name
}
QML
cat >"$surf/Widget.qml" <<'QML'
import QtQuick
import qs.Ui
BarWidget {
    id: root
    moduleName: "acme.surfaces"
    implicitWidth: 30
    implicitHeight: barSize
    function summonHere() { return shell.surfaces.summon("panel", "{\"from\":\"widget\"}", root); }
    function geometry() { const p = mapToItem(null, 0, 0); return JSON.stringify([p.x, p.y, width, height]); }
}
QML
expect "rescan after adding the hosts fixture answers ok" ok ipc shell rescanPlugins
surfaces_known() { ipc shell listPlugins | python3 -c 'import json,sys; print(any(p["id"]=="acme.surfaces" for p in json.load(sys.stdin)["plugins"]))'; }
expect_poll "the hosts fixture is discovered" True surfaces_known
expect_poll "enabling the hosts fixture is allowed" ok ipc shell setPluginEnabled acme.surfaces true

screen_name="$(bar_key | sed 's/^bar://')"

expect_poll "the background host draws one surface per screen" "$monitors" layer_count vgs:background
expect "the background sits on the bottom layer" True python3 -c 'import json,subprocess,sys; print(any(l["namespace"]=="vgs:background" and l["pid"]!=-1 for m in json.loads(sys.stdin.read()).values() for l in m["levels"]["0"]))' < <(hypr -j layers)
expect "the background receives its screen" "\"$screen_name\"" ipc shell readInstance "background:$screen_name" acme.surfaces screenName

expect "a panel summons over IPC" ok ipc shell summon panel acme.surfaces '{"n":1}'
expect "the panel received its payload" '"{\"n\":1}"' ipc shell readInstance panel acme.surfaces lastPayload
expect_poll "the panel host maps one surface" 1 layer_count vgs:panel
geometry expect_poll "the panel takes its top-right placement below the bar" "[[$((mon_w - 8 - 200)), $((bar_reserved + 8)), 200, 120]]" layers_of vgs:panel
if before="$(builds)"; then
  expect "summoning an open panel is allowed" ok ipc shell summon panel acme.surfaces '{"n":2}'
  expect "the open panel received the new payload" 2 ipc shell readInstance panel acme.surfaces opened
  expect "summoning an open panel builds nothing" "$before" builds
else
  fail "buildCount unreadable before the summon rows"
fi
expect "summoning with a close marker is allowed" ok ipc shell summon panel acme.surfaces "{\"closeMarker\":\"$sandbox/closed-by-hide\"}"
expect "hiding the panel is allowed" ok ipc shell hide panel acme.surfaces
marker() { [[ -f $1 ]] && echo yes || echo no; }
expect_poll "hide called the panel's close()" yes marker "$sandbox/closed-by-hide"
expect "the hidden panel leaves the build records" absent ipc shell readInstance panel acme.surfaces opened
expect_poll "the panel host destroyed its surface" 0 layer_count vgs:panel
expect "toggle opens a closed panel" ok ipc shell toggle panel acme.surfaces '{}'
expect_poll "the toggled panel is mapped" 1 layer_count vgs:panel
expect "toggle closes an open panel" ok ipc shell toggle panel acme.surfaces '{}'
expect_poll "the toggled panel is gone" 0 layer_count vgs:panel

expect "an overlay summons over IPC" ok ipc shell summon overlay acme.surfaces '{}'
geometry expect_poll "the overlay covers its screen" "[[0, 0, $mon_w, $mon_h]]" layers_of vgs:overlay
expect "hiding the overlay is allowed" ok ipc shell hide overlay acme.surfaces
expect_poll "the overlay host destroyed its surface" 0 layer_count vgs:overlay
expected_errors+=('summon host: acme\.surfaces open\(\) failed: probe open refused')
expect "an open() that throws refuses the summon" "refused: open-failed=acme.surfaces" ipc shell summon menu acme.surfaces '{"fail":true}'
expect_poll "the refused summon leaves no surface" 0 layer_count vgs:menu
expect "a menu summons over IPC" ok ipc shell summon menu acme.surfaces '{}'
expect_poll "the menu host maps one surface" 1 layer_count vgs:menu
expect "hiding the menu is allowed" ok ipc shell hide menu acme.surfaces
expect_poll "the menu host destroyed its surface" 0 layer_count vgs:menu

# A panel the plugin summons from its own bar widget sits under the widget,
# centred on it.
expect "the widget summons its panel under itself" ok ipc shell invokeInstance "bar:$screen_name" acme.surfaces summonHere ''
widget_geometry="$(ipc shell invokeInstance "bar:$screen_name" acme.surfaces geometry '')"
widget_rows() { python3 -c 'import json,sys; g=json.loads(sys.argv[1]); print(g[1], g[3])' "$widget_geometry"; }
geometry expect "a mounted widget spans the bar's height" "0 $bar_reserved" widget_rows
anchored_want="$(python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); mw=int(sys.argv[2]); left=max(0, min(round(x + w/2 - 100), mw - 200)); print(json.dumps([[left, int(y + h + 8), 200, 120]]))' "$widget_geometry" "$mon_w")"
geometry expect_poll "the anchored panel sits under its widget" "$anchored_want" layers_of vgs:panel
expect "the anchored panel received the widget's payload" '"{\"from\":\"widget\"}"' ipc shell readInstance panel acme.surfaces lastPayload

expect "a background is not summonable" "refused: not-summonable=background" ipc shell summon background acme.surfaces '{}'
expect "a plugin without the kind is refused" "refused: kind=panel id=acme.tick" ipc shell summon panel acme.tick '{}'
expect "an unknown plugin is refused" "unknown: acme.nope" ipc shell summon panel acme.nope '{}'
expect "re-summoning with a close marker is allowed" ok ipc shell summon panel acme.surfaces "{\"closeMarker\":\"$sandbox/closed-by-disable\"}"
expect "disabling the hosts fixture is allowed" ok ipc shell setPluginEnabled acme.surfaces false
expect_poll "disabling closes its open panel" 0 layer_count vgs:panel
expect_poll "disabling called the panel's close()" yes marker "$sandbox/closed-by-disable"
expect_poll "disabling removes the background surface" 0 layer_count vgs:background
expect "a disabled plugin is not summoned" "refused: disabled=acme.surfaces" ipc shell summon panel acme.surfaces '{}'

# A plugin whose entry points cannot take what the core assigns is not
# built and keeps nothing it was lent: no hold, no background surface.
broken="$home/.config/vgs/plugins/acme.broken"
mkdir -p "$broken"
cat >"$broken/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.broken", "name": "Broken", "version": "0.1.0", "author": "acme", "description": "smoke fixture declaring no shell property",
  "kinds": ["service", "background"], "entryPoints": { "service": "Item.qml", "background": "Item.qml" }, "capabilities": ["lock"] }
JSON
printf 'import QtQuick\nItem {}\n' >"$broken/Item.qml"
expected_errors+=('plugins: acme\.broken (service|background) not built: ')
expect "rescan after adding the broken fixture answers ok" ok ipc shell rescanPlugins
broken_known() { ipc shell listPlugins | python3 -c 'import json,sys; print(any(p["id"]=="acme.broken" for p in json.load(sys.stdin)["plugins"]))'; }
expect_poll "the broken fixture is discovered" True broken_known
expect "enabling the broken fixture is allowed" ok ipc shell setPluginEnabled acme.broken true
broken_built() { ipc shell built | python3 -c 'import json,sys; print(any(r["id"]=="acme.broken" for rows in json.load(sys.stdin).values() for r in rows))'; }
expect_log "the core logged both refused builds of the broken fixture" 2 'plugins: acme\.broken (service|background) not built: '
expect "the broken fixture has no build record" False broken_built
expect "the broken fixture keeps no capability hold" null lent holders.lock
expect_poll "the background host shows no surface for a failed build" 0 layer_count vgs:background
expect "disabling the broken fixture is allowed" ok ipc shell setPluginEnabled acme.broken false

# A bar widget that cannot take what the core assigns is not built, and the
# section's entries stay aligned with the layout: an edit to the entry after
# it reaches that entry's own widget, never a neighbour's settings.
nowidget="$home/.config/vgs/plugins/acme.nowidget"
mkdir -p "$nowidget"
cat >"$nowidget/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.nowidget", "name": "No Widget", "version": "0.1.0", "author": "acme", "description": "smoke fixture widget declaring no BarWidget properties",
  "kinds": ["bar-widget"], "entryPoints": { "bar-widget": "Item.qml" } }
JSON
printf 'import QtQuick\nItem { property var shell: null }\n' >"$nowidget/Item.qml"
expected_errors+=('plugins: acme\.nowidget bar-widget not built: ')
expect "rescan after adding the widget that cannot be built answers ok" ok ipc shell rescanPlugins
nowidget_known() { ipc shell listPlugins | python3 -c 'import json,sys; print(any(p["id"]=="acme.nowidget" for p in json.load(sys.stdin)["plugins"]))'; }
expect_poll "the widget that cannot be built is discovered" True nowidget_known
python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["bar"]["layout"]["center"].insert(0, {"id": "acme.nowidget"})
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
expect_log "the core logged the refused widget build on every bar" "$monitors" 'plugins: acme\.nowidget bar-widget not built: '
expect_widgets "the section shows the widget after the one that failed" '["acme.tick"]'
python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
[e for e in d["bar"]["layout"]["center"] if e["id"] == "acme.tick"][0]["format"] = "aligned"
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
expect_poll "an edit after a failed entry reaches its own widget" '"aligned"' read_tick format
python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["bar"]["layout"]["center"] = [e for e in d["bar"]["layout"]["center"] if e["id"] != "acme.nowidget"]
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
expect_widgets "removing the failed entry leaves the widget in place" '["acme.tick"]'

# A monitor that goes away takes its bar with it, under the key the bar
# was built under, and leaves no build record behind.
extra_output=SMOKE-2
bar_hosts() { ipc shell built | python3 -c 'import json,sys; print(json.dumps(sorted(k for k in json.load(sys.stdin) if k.startswith("bar:"))))'; }
before_hosts="$(bar_hosts)"
expect "the nested compositor adds a monitor" ok hypr output create headless "$extra_output"
expect_poll "the new monitor gets a bar" "$((monitors + 1))" bar_count
extra_listed() { bar_hosts | python3 -c 'import json,sys; print(("bar:" + sys.argv[1]) in json.load(sys.stdin))' "$extra_output"; }
expect_poll "the new bar is in the build records" True extra_listed
expect "the nested compositor removes the monitor" ok hypr output remove "$extra_output"
expect_poll "the removed monitor's bar surface is gone" "$monitors" bar_count
expect_poll "the removed monitor's bar left the build records" "$before_hosts" bar_hosts

# An unreadable user file settles, keeps the bar, and refuses every write
# until it reads again.
config_user_state() { ipc shell listPlugins | python3 -c 'import json,sys; print(json.load(sys.stdin)["config"]["user"])'; }
expected_errors+=('config: user file unreadable at ')
chmod 000 "$home/.config/vgs/shell.json"
expect "reloading an unreadable user file answers ok" ok ipc shell reloadConfig
expect_poll "the user file reads as unreadable" unreadable config_user_state
expect "a write to an unreadable user file is refused" "refused: user-config=unreadable path=$home/.config/vgs/shell.json" ipc shell setPluginEnabled acme.tick false
expect "the bar stays with an unreadable user file" "$monitors" bar_count
chmod 644 "$home/.config/vgs/shell.json"
expect "reloading the readable user file answers ok" ok ipc shell reloadConfig
expect_poll "the user file reads as loaded again" loaded config_user_state

# A user file that parses but fails PluginLogic.configError is malformed: the
# defect is logged, the last good value keeps the bar, and writes are refused
# until the file passes again.
user_good="$(cat "$home/.config/vgs/shell.json")"
expected_errors+=('config: .*/shell\.json malformed: plugins\.0 must be an object with a string id')
printf '{ "version": 1, "plugins": ["acme.tick"] }\n' >"$home/.config/vgs/shell.json.tmp" && mv -T -- "$home/.config/vgs/shell.json.tmp" "$home/.config/vgs/shell.json"
expect_poll "a user file with a malformed plugins row reads as malformed" malformed config_user_state
expect_log "the malformed row is logged with its path in the file" 1 'config: .*/shell\.json malformed: plugins\.0 must be an object with a string id'
expect "a write to a malformed user file is refused" "refused: user-config=malformed path=$home/.config/vgs/shell.json" ipc shell setPluginEnabled acme.tick false
expect "the bar stays with a malformed user file" "$monitors" bar_count
expect_widgets "the placed widget stays with a malformed user file" '["acme.tick"]'
printf '%s\n' "$user_good" >"$home/.config/vgs/shell.json.tmp" && mv -T -- "$home/.config/vgs/shell.json.tmp" "$home/.config/vgs/shell.json"
expect_poll "the user file reads as loaded once the row is fixed" loaded config_user_state

# theme.json recolours every surface through Color; the bar's foreground is
# read back from a built bar instance. A file that does not parse, is not
# an object, or holds a role that is not a colour is logged and the last
# good palette stays.
theme="$home/.config/vgs/theme.json"
# A QML color reads back as its channel object; the row compares its hex.
bar_foreground() { ipc shell readInstance "$(bar_key)" vgs.bar foreground | python3 -c 'import json,sys; c=json.load(sys.stdin); print("#%02x%02x%02x" % tuple(round(c[k] * 255) for k in "rgb"))'; }
expect "the bar draws the default foreground with no theme file" '#cacccc' bar_foreground
printf '{ "foreground": "#123456" }\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_poll "a theme file recolours the bar's foreground" '#123456' bar_foreground
expected_errors+=('theme: .*/theme\.json does not parse: ')
printf '{ nope\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_log "a theme file that does not parse is logged" 1 'theme: .*/theme\.json does not parse: '
expect "an unparseable theme file keeps the last good palette" '#123456' bar_foreground
expected_errors+=('theme: .*/theme\.json malformed: theme must be an object' 'theme: .*/theme\.json malformed: foreground is not a colour: "#12345"')
printf '[ "#654321" ]\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_log "a theme file that is not an object is logged" 1 'theme: .*/theme\.json malformed: theme must be an object'
expect "a theme file that is not an object keeps the last good palette" '#123456' bar_foreground
printf '{ "foreground": "#12345" }\n' >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"
expect_log "a theme role that is not a colour is logged" 1 'theme: .*/theme\.json malformed: foreground is not a colour: "#12345"'
expect "a theme role that is not a colour keeps the last good palette" '#123456' bar_foreground

# Control: a bare qs beside the runner must refuse to draw and to write,
# and the runner's CLI must keep addressing the guarded instance.
spawn "$sandbox/bare.log" "${shell_env[@]}" qs -p "$repo/shell"
bare_pid="$spawn_pid"
instance_count() { "${shell_env[@]}" qs list -p "$repo/shell" -j 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
bare_ipc() { "${shell_env[@]}" qs ipc --pid "$bare_pid" call "$@" 2>/dev/null | tail -n 1; }
bare_guarded=""
for _ in $(seq 1 100); do
  # Wait until the bare instance is registered, then address it by pid.
  if instances="$(instance_count)" && [[ $instances == 2 ]] && bare_guarded="$(bare_ipc shell guarded)" && [[ $bare_guarded == true || $bare_guarded == false ]]; then break; fi
  sleep 0.2
done
if [[ $bare_guarded == false ]]; then ok "a bare qs beside the runner refuses to draw"; else fail "bare qs guarded=$bare_guarded"; fi
sleep 0.5
if bars_after="$(bar_count)" && [[ $bars_after == "$bars" ]]; then ok "the bare qs mapped no bar surface"; else fail "bar surfaces after bare qs: ${bars_after:-unreadable}"; fi
user_before="$(cat "$home/.config/vgs/shell.json")"
expect "the bare qs refuses to write configuration" "refused: guard=unowned pid=$bare_pid" bare_ipc shell setPluginEnabled acme.tick false
expect "the bare qs refuses to reload configuration" "refused: guard=unowned pid=$bare_pid" bare_ipc shell reloadConfig
expect "the bare qs refuses to rescan" "refused: guard=unowned pid=$bare_pid" bare_ipc shell rescanPlugins
expect "the bare qs refuses to summon" "refused: guard=unowned pid=$bare_pid" bare_ipc shell summon panel acme.probe '{}'
if [[ "$(cat "$home/.config/vgs/shell.json")" == "$user_before" ]]; then ok "the refused write left the user file alone"; else fail "the bare qs changed the user file"; fi
expect "the runner's CLI still reaches the guarded instance beside a bare one" true ipc shell guarded
kill -TERM "$bare_pid" 2>/dev/null || true

# Every QML warning and error the shell logged, minus the lines rows
# provoked on purpose, plus the engine's own error classes.
error_pattern=' ERROR |WARN qml: |WARN scene:|WARN quickshell\.hyprland|TypeError|ReferenceError|is not defined|Cannot read|Cannot assign'
unexpected_errors() {
  python3 - "$instance_log" "$error_pattern" "${expected_errors[@]}" <<'PY'
import re, sys
path, pattern, expected = sys.argv[1], re.compile(sys.argv[2]), [re.compile(e) for e in sys.argv[3:]]
for line in open(path, errors="replace"):
    if pattern.search(line) and not any(e.search(line) for e in expected):
        print(line.rstrip())
PY
}
if ! log_errors="$(unexpected_errors)"; then
  fail "shell log unreadable: $instance_log"
elif [[ -n $log_errors ]]; then
  fail "shell log holds errors:"
  head -n 20 <<<"$log_errors"
else
  ok "shell log holds no unexpected error ($instance_log)"
fi

echo "  latency_first_bar_ms=${first_bar_ms:-unmeasured} budget_ms=$first_bar_budget_ms"
if [[ -n $first_bar_ms && $first_bar_ms -le $first_bar_budget_ms ]]; then ok "the first bar maps within its budget"; else fail "first bar latency ${first_bar_ms:-unmeasured} ms over budget $first_bar_budget_ms ms"; fi
echo "  latency_reconcile_ms=${reconcile_ms:-unmeasured} budget_ms=$reconcile_budget_ms"
if [[ -n $reconcile_ms && $reconcile_ms -le $reconcile_budget_ms ]]; then ok "a disable reaches the build records within its budget"; else fail "reconcile latency ${reconcile_ms:-unmeasured} ms over budget $reconcile_budget_ms ms"; fi

# The memory sampler finds the shell `vgsh run` started through the runner's
# lock file and the instance list, and samples it by pid.
sampler_rows() { awk -F'\t' -v pid="$shell_qs_pid" 'NR > 1 && $2 == pid { n++ } END { print n + 0 }' "$sandbox/memory.tsv"; }
if "${shell_env[@]}" "$repo/scripts/sample-shell-memory.sh" --interval 1 --samples 2 --log "$sandbox/memory.tsv" >"$sandbox/sampler.out" 2>"$sandbox/sampler.err"; then
  expect "the memory sampler logged two samples of the runner's shell" 2 sampler_rows
else
  fail "memory sampler exited non-zero: $(head -n 2 "$sandbox/sampler.err")"
fi

rss_kib=0; hwm_kib=0
if ! rss_kib="$(awk '/^VmRSS:/ { print $2 }' "/proc/$shell_qs_pid/status")"; then fail "resident size unreadable for pid $shell_qs_pid"; fi
if ! hwm_kib="$(awk '/^VmHWM:/ { print $2 }' "/proc/$shell_qs_pid/status")"; then fail "high-water mark unreadable for pid $shell_qs_pid"; fi
echo "  rss_kib=$rss_kib hwm_kib=$hwm_kib ceiling_kib=$rss_ceiling_kib"
if [[ $rss_kib -gt 0 && $rss_kib -le $rss_ceiling_kib ]]; then ok "resident size under the ceiling"; else fail "resident size $rss_kib KiB over ceiling $rss_ceiling_kib KiB"; fi

if [[ $failures -gt 0 ]]; then
  echo "--- instance log tail"; tail -n 40 "${instance_log:-$sandbox/qs.log}" 2>/dev/null || true
  echo "--- nested compositor log tail"; tail -n 40 "$rt_dir"/hypr/*/hyprland.log 2>/dev/null || true
fi
# A nested compositor that cannot allocate its output buffers stops laying
# out surfaces, so every geometry row after that reads zeros. A run whose
# failures are all geometry rows and whose compositor logged that fault
# measured the sandbox, not the shell: it reports not-measured, which is
# never a pass, and names the cause. Any behaviour failure is a failure.
if [[ $failures -gt 0 && $behaviour_failures -eq 0 ]] && grep -q -s 'Failed to allocate a GBM buffer' "$rt_dir"/hypr/*/hyprland.log; then
  printf 'qml-smoke: status=not-measured nested-compositor=buffer-allocation-failed failed=%s\n' "$failures"
  exit 77
fi
if [[ $failures -gt 0 ]]; then
  echo "qml-smoke: failed=$failures"
  exit 1
fi
echo "qml-smoke: ok"
