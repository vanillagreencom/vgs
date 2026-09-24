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
# error; one bar surface maps per monitor with the shipped widgets; a widget
# can be disabled and re-enabled with its placement and settings kept;
# disabling the bar names the widgets it hides, unloads it and unmaps its
# surface; an unrelated write and a no-op rescan build nothing; a user
# plugin is discovered, built as a service and a widget, receives exactly
# the capabilities it named, and takes a settings change without a rebuild;
# the shared clock ticks seconds once a format shows them;
# a bare `qs` started beside the runner refuses to draw and to write, and
# the runner's CLI still reaches the guarded instance; the log holds no QML
# error; resident memory stays under the ceiling.
#
# Exit 0 when every check passed. Exit 77 when a prerequisite is missing,
# naming it; that is not a pass. Exit 1 when a check failed.
#
# VGSH_SMOKE_RSS_CEILING_KIB: resident-size ceiling for the shell process at
# the end of the run. It catches a startup allocation blow-up and nothing
# else: a run this short cannot see the slow growth docs/architecture/memory.md
# describes, and the reading carries the machine's graphics stack. The
# default is twice the rss_kib this script printed on the owner's machine on
# 2026-09-21 with the three bundled plugins on one nested monitor. The
# high-water mark is printed beside it as the reproducible reading.
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
rss_ceiling_kib="${VGSH_SMOKE_RSS_CEILING_KIB:-576968}"

missing=()
for tool in Hyprland qs hyprctl python3 node flock setsid; do
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

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vgsh-smoke.XXXXXX")"
# The runtime dir holds Unix sockets, whose paths are limited to 107 bytes,
# and Hyprland's socket path adds a 63-character signature under hypr/. A
# sandbox under a long TMPDIR made Hyprland refuse IPC, so the runtime dir
# is a short name beside the host's own runtime files.
rt_dir="$(mktemp -d "$XDG_RUNTIME_DIR/vs.XXXXXX")"
home="$sandbox/home"; mkdir -p "$home/.config/hypr"
pgids=()
failures=0
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }

cleanup() {
  local pg
  for pg in "${pgids[@]}"; do kill -TERM -- "-$pg" 2>/dev/null || true; done
  sleep 0.5
  for pg in "${pgids[@]}"; do kill -KILL -- "-$pg" 2>/dev/null || true; done
  if [[ $keep == true ]]; then
    echo "qml-smoke: sandbox kept at $sandbox (runtime dir $rt_dir)"
  else
    rm -rf -- "${sandbox:?}" "${rt_dir:?}"
  fi
}
trap cleanup EXIT

cat >"$home/.config/hypr/hyprland.lua" <<'LUA'
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.config({
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true, disable_autoreload = true },
    animations = { enabled = false },
})
LUA

sandbox_env=(env -i
  HOME="$home" PATH="$PATH" USER="${USER:-$(id -un)}" TERM=dumb LANG=C.UTF-8
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

echo "qml-smoke: sandbox $sandbox"
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

shell_env=("${sandbox_env[@]}" WAYLAND_DISPLAY="$nested_socket" HYPRLAND_INSTANCE_SIGNATURE="$signature")
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
spawn "$sandbox/qs.log" "${shell_env[@]}" "$repo/bin/vgsh" run
shell_pid="$spawn_pid"

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

# expect LABEL WANT CMD...: the command's last stdout line must equal WANT.
# A command that fails is a failure, never an empty string that happens to
# compare unequal.
expect() {
  local label="$1" want="$2" got
  shift 2
  if ! got="$("$@")"; then fail "$label: command failed: $*"; return; fi
  if [[ $got == "$want" ]]; then ok "$label"; else fail "$label: got $got"; fi
}

expect "instance guard accepts the runner's shell" true ipc shell guarded

# Plugins scan asynchronously; wait for the bundled three.
plugins_json=""
for _ in $(seq 1 100); do
  if plugins_json="$(ipc shell listPlugins)" && python3 -c 'import json,sys; d=json.load(sys.stdin); ids={p["id"] for p in d["plugins"]}; sys.exit(0 if {"vgs.bar","vgs.clock","vgs.workspaces"} <= ids else 1)' <<<"$plugins_json"; then break; fi
  sleep 0.2
done
if python3 - "$plugins_json" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
by = {p["id"]: p for p in d["plugins"]}
missing = [i for i in ("vgs.bar", "vgs.clock", "vgs.workspaces") if i not in by]
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
expect_widgets "every bar built the workspaces and clock widgets" '["vgs.workspaces","vgs.clock"]'

# A rebuild counter: the core counts every instance it builds. Rows below
# assert that an unrelated write and a no-op rescan build nothing.
builds() { ipc shell buildCount; }
expect "the core built the bar and its two widgets per screen" "$((3 * monitors))" builds

# Disable only lists the id: the layout entry and its settings stay, so
# re-enabling restores the exact screen. The effective configuration is
# read back for the entry, the user file for what the manager wrote.
expect "disabling a widget is allowed" ok ipc shell setPluginEnabled vgs.clock false
clock_state() { ipc shell listPlugins | python3 -c 'import json,sys; d=json.load(sys.stdin); print([p["enabled"] for p in d["plugins"] if p["id"]=="vgs.clock"][0])'; }
clock_entry() { ipc shell listShellConfig | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([e for e in d["bar"]["layout"]["center"] if e["id"]=="vgs.clock"]))'; }
user_keys() { python3 -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1])).keys())))' "$home/.config/vgs/shell.json"; }
expect_widgets "the bar dropped the disabled widget" '["vgs.workspaces"]'
expect "widget reads disabled after the user file changed" False clock_state
expect "the disabled widget keeps its layout entry and settings" '[{"id": "vgs.clock", "format": "ddd d MMM  HH:mm"}]' clock_entry
expect "disable wrote only the disabled list" "disabledPlugins,version" user_keys
expect "re-enabling the widget is allowed" ok ipc shell setPluginEnabled vgs.clock true
expect_widgets "the bar rebuilt the re-enabled widget" '["vgs.workspaces","vgs.clock"]'
expect "re-enable wrote only the disabled list" "disabledPlugins,version" user_keys

expect "disabling the bar names the widgets it hides" "ok hidden=vgs.clock,vgs.workspaces" ipc shell setPluginEnabled vgs.bar false
expect_widgets "the bar host unloaded the disabled bar" '[]'
bars_now=-1
for _ in $(seq 1 50); do
  if bars_now="$(bar_count)" && [[ $bars_now == 0 ]]; then break; fi
  sleep 0.2
done
if [[ $bars_now == 0 ]]; then ok "the bar host destroyed its surface with no bar"; else fail "bar surfaces with the bar disabled: $bars_now"; fi
expect "no bar reserves no screen space" 0 reserved_total
expect "re-enabling the bar is allowed" ok ipc shell setPluginEnabled vgs.bar true
expect_widgets "the bar host rebuilt the re-enabled bar" '["vgs.workspaces","vgs.clock"]'
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
if [[ $reserved -gt 0 ]]; then ok "the re-enabled bar reserves screen space again"; else fail "reserved space after re-enable: $reserved"; fi
if [[ -f "$home/.config/vgs/shell.json" ]]; then ok "manager wrote the user file"; else fail "user file missing"; fi

# An unrelated key in the user file and a no-op rescan build nothing.
if before="$(builds)"; then
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["unrelated"] = 1
json.dump(d, open(p, "w"), indent=2)
PY
  sleep 1
  expect "an unrelated configuration write rebuilds nothing" "$before" builds
  expect "a no-op rescan answers ok" ok ipc shell rescanPlugins
  sleep 1
  expect "a no-op rescan rebuilds nothing" "$before" builds
else
  fail "buildCount unreadable"
fi

# A fixture plugin in the sandbox user directory: kind service plus a bar
# widget with the compositor capability. Proves user-directory discovery,
# the service host, that each instance receives exactly the capabilities
# its manifest names, and that a settings change reaches a running
# instance without a rebuild. The rows read the fixture's own properties
# back through readInstance, never the build records.
fixture="$home/.config/vgs/plugins/acme.probe"
mkdir -p "$fixture"
cat >"$fixture/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.probe", "name": "Probe", "version": "0.1.0", "author": "acme", "description": "smoke fixture",
  "kinds": ["service", "bar-widget"], "entryPoints": { "service": "Service.qml", "bar-widget": "Widget.qml" },
  "defaultSection": "right", "settings": { "label": "probe", "tags": ["a", "b"] },
  "capabilities": ["compositor"] }
JSON
cat >"$fixture/Service.qml" <<'QML'
import QtQuick
Item {
    property var shell: null
    readonly property string label: shell === null ? "" : String(shell.settings.label)
    readonly property string shellKeys: shell === null ? "" : Object.keys(shell).sort().join(",")
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
}
QML
expect "rescan after adding a user plugin answers ok" ok ipc shell rescanPlugins
probe_state() { ipc shell listPlugins | python3 -c 'import json,sys; d=json.load(sys.stdin); print([p["enabled"] for p in d["plugins"] if p["id"]=="acme.probe"][0])' 2>/dev/null || echo absent; }
found=""
for _ in $(seq 1 25); do if found="$(probe_state)" && [[ $found == False ]]; then break; fi; sleep 0.2; done
if [[ $found == False ]]; then ok "user-directory plugin discovered and disabled until enabled"; else fail "fixture after rescan: $found"; fi
expect "enabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
service_built() { ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(r["id"]=="acme.probe" and r["kind"]=="service" for r in d.get("service",[])))'; }
# The first bar host's key, for reading a widget instance back.
bar_key() { ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(k for k in d if k.startswith("bar:"))[0])'; }
read_widget() { ipc shell readInstance "$(bar_key)" acme.probe "$1"; }
read_service() { ipc shell readInstance service acme.probe "$1"; }
read_clock() { ipc shell readInstance "$(bar_key)" vgs.clock "$1"; }
got=""
for _ in $(seq 1 25); do if got="$(service_built)" && [[ $got == True ]]; then break; fi; sleep 0.2; done
if [[ $got == True ]]; then ok "the service host built the fixture service"; else fail "service host: built=$got"; fi
expect_widgets "the fixture widget joined the right section" '["vgs.workspaces","vgs.clock","acme.probe"]'
expect "the fixture widget can call its compositor capability" true read_widget hasCompositor
expect "the fixture widget's settings array stayed an array" true read_widget tagsAreArray
expect "the fixture widget's shell holds exactly what it named" '"compositor,manifest,settings"' read_widget shellKeys
expect "the fixture service's shell holds exactly what it named" '"compositor,manifest,settings"' read_service shellKeys
expect "the fixture service reads the manifest default" '"probe"' read_service label
expect "the clock widget reads its layout entry" '"ddd d MMM  HH:mm"' read_clock format

# A settings change reaches the running instance and builds nothing: the
# service's plugins[] row, then the clock's layout entry.
if before="$(builds)"; then
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["plugins"] = [{"id": "acme.probe", "label": "changed-service-setting"}]
json.dump(d, open(p, "w"), indent=2)
PY
  expect_poll() { # LABEL WANT CMD...
    local label="$1" want="$2" got=""
    shift 2
    for _ in $(seq 1 25); do
      if got="$("$@")" && [[ $got == "$want" ]]; then ok "$label"; return; fi
      sleep 0.2
    done
    fail "$label: got $got want $want"
  }
  expect_poll "the running service received its changed setting" '"changed-service-setting"' read_service label
  expect "the fixture widget keeps the manifest default its entry does not override" '"probe"' read_widget label
  expect "a service settings change rebuilds nothing" "$before" builds
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
center = d["bar"]["layout"]["center"]
[e for e in center if e["id"] == "vgs.clock"][0]["format"] = "HH:mm:ss"
json.dump(d, open(p, "w"), indent=2)
PY
  expect_poll "the running clock received its changed layout entry" '"HH:mm:ss"' read_clock format
  # The shared clock ticks seconds only while a format shows them: three
  # readings across 2.2 s change at least twice at second precision and at
  # most once at minute precision.
  clock_changes=0; clock_last=""
  for _ in 1 2 3; do
    if clock_now="$(read_clock displayed)"; then
      [[ -n $clock_last && $clock_now != "$clock_last" ]] && clock_changes=$((clock_changes + 1))
      clock_last="$clock_now"
    fi
    sleep 1.1
  done
  if [[ $clock_changes -ge 2 ]]; then ok "the shared clock ticks seconds for a seconds format"; else fail "clock text changed $clock_changes times in 2.2 s"; fi
  expect "a widget settings change rebuilds nothing" "$before" builds
else
  fail "buildCount unreadable before the settings rows"
fi
expect "disabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe false
expect_widgets "the fixture widget left the bar" '["vgs.workspaces","vgs.clock"]'
got=""
for _ in $(seq 1 25); do if got="$(service_built)" && [[ $got == False ]]; then break; fi; sleep 0.2; done
if [[ $got == False ]]; then ok "the service host destroyed the disabled service"; else fail "service still built: $got"; fi

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
expect "the bare qs refuses to write configuration" "refused: guard=unowned pid=$bare_pid" bare_ipc shell setPluginEnabled vgs.clock false
expect "the bare qs refuses to reload configuration" "refused: guard=unowned pid=$bare_pid" bare_ipc shell reloadConfig
expect "the bare qs refuses to rescan" "refused: guard=unowned pid=$bare_pid" bare_ipc shell rescanPlugins
expect "the bare qs refuses to summon" "refused: guard=unowned pid=$bare_pid" bare_ipc shell summon panel acme.probe '{}'
if [[ "$(cat "$home/.config/vgs/shell.json")" == "$user_before" ]]; then ok "the refused write left the user file alone"; else fail "the bare qs changed the user file"; fi
expect "the runner's CLI still reaches the guarded instance beside a bare one" true ipc shell guarded
kill -TERM "$bare_pid" 2>/dev/null || true

# qs buffers stdout when redirected, so the shell's own per-instance log
# file is the record: it is line-flushed and holds every QML warning.
# The runner execs qs, so the shell's pid is the runner's unless setsid forked.
shell_qs_pid="$shell_pid"
if child="$(pgrep -P "$shell_pid" -x qs)"; then shell_qs_pid="$child"; fi
instance_log=""
if instance_id="$("${shell_env[@]}" qs list -p "$repo/shell" -j 2>/dev/null | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin) if i["pid"]==int(sys.argv[1])][0]["id"])' "$shell_qs_pid")"; then
  instance_log="$rt_dir/quickshell/by-id/$instance_id/log.log"
fi
error_pattern=' ERROR |WARN scene:|WARN quickshell\.hyprland|TypeError|ReferenceError|is not defined|Cannot read|Cannot assign|qml: (config|compositor|plugins|bar host|bar|shell): '
if [[ -z $instance_log || ! -f $instance_log ]]; then
  fail "instance log not found for pid $shell_qs_pid"
elif grep -E -q "$error_pattern" "$instance_log"; then
  fail "shell log holds errors:"
  grep -E "$error_pattern" "$instance_log" | head -n 20
else
  ok "shell log holds no error ($instance_log)"
fi

rss_kib=0; hwm_kib=0
if ! rss_kib="$(awk '/^VmRSS:/ { print $2 }' "/proc/$shell_qs_pid/status")"; then fail "resident size unreadable for pid $shell_qs_pid"; fi
if ! hwm_kib="$(awk '/^VmHWM:/ { print $2 }' "/proc/$shell_qs_pid/status")"; then fail "high-water mark unreadable for pid $shell_qs_pid"; fi
echo "  rss_kib=$rss_kib hwm_kib=$hwm_kib ceiling_kib=$rss_ceiling_kib"
if [[ $rss_kib -gt 0 && $rss_kib -le $rss_ceiling_kib ]]; then ok "resident size under the ceiling"; else fail "resident size $rss_kib KiB over ceiling $rss_ceiling_kib KiB"; fi

if [[ $failures -gt 0 ]]; then
  echo "qml-smoke: failed=$failures"
  echo "--- instance log tail"; tail -n 40 "${instance_log:-$sandbox/qs.log}" 2>/dev/null || true
  exit 1
fi
echo "qml-smoke: ok"
