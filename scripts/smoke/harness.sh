# Sourced by qml-smoke.sh; owns the sandbox and shared readers.
set -euo pipefail
source "$repo/scripts/smoke/verdict.sh"
source "$repo/scripts/smoke/tree.sh"
missing=()
# fd, fzf and file are the launcher file search helper's, which rows/launcher.sh runs.
for tool in Hyprland qs hyprctl python3 node flock setsid git dbus-daemon gdbus cc wayland-scanner pkg-config wtype fd fzf file; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if command -v pkg-config >/dev/null 2>&1 && ! pkg-config --exists wayland-client; then missing+=("wayland-client.pc"); fi
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
source_repo="$repo"
pgids=()
failures=0
# A row that reads positions, sizes or reserved space from the compositor
# runs under `geometry`; a row whose subject shows only once the shell
# draws a frame runs under `render`; every other failure counts as
# behaviour. Only a run whose failures are all geometry or render can be
# excused by a sandbox fault: the compositor's buffers, or a host that
# withholds frame callbacks from the nested window.
behaviour_failures=0
stalled_render=false
row_class=behaviour
# A mode a row holds on a nested output, as (OUTPUT MODE), empty when no row
# holds one; hold_mode and release_mode alone write it. A row that fails
# after the output left the held mode counts in mode_resets and never as
# behaviour: it measured an output the sandbox reset (held_mode_state).
mode_hold=()
mode_resets=0
fail() {
  failures=$((failures + 1))
  if [[ ${#mode_hold[@]} -gt 0 && $(held_mode_state) == reset ]]; then
    mode_resets=$((mode_resets + 1))
    printf '  FAIL  %s\n' "$*"
    printf '        %s left the held mode %s: not measured\n' "${mode_hold[0]}" "${mode_hold[1]}"
    return
  fi
  [[ $row_class == geometry || $row_class == render ]] || behaviour_failures=$((behaviour_failures + 1))
  printf '  FAIL  %s\n' "$*"
}
geometry() { local previous="$row_class"; row_class=geometry; "$@"; row_class="$previous"; }
# A render row that fails while the bar windows swapped no frame measured
# the sandbox, not the shell.
render() {
  local previous="$row_class" before after failed_before="$failures"
  before="$(ipc smoke frames)" || before=""
  row_class=render; "$@"; row_class="$previous"
  [[ $failures -eq $failed_before ]] && return
  after="$(ipc smoke frames)" || after=""
  if [[ -z $before || -z $after || $before == "$after" ]]; then
    stalled_render=true
    printf '        no frame was drawn during the row (frames=%s)\n' "${after:-unreadable}"
  fi
}
# Error lines a row provokes on purpose, as extended regexes; the log check
# leaves out a line matching one of them.
expected_errors=()
ok() { printf '  ok    %s\n' "$*"; }
error_pattern=' ERROR |WARN qml: |WARN scene:|WARN quickshell\.hyprland|TypeError|ReferenceError|is not defined|Cannot read|Cannot assign'
unexpected_log_errors() { # LOG
  python3 - "$1" "$error_pattern" "${expected_errors[@]}" <<'PY'
import re, sys
path, pattern, expected = sys.argv[1], re.compile(sys.argv[2]), [re.compile(e) for e in sys.argv[3:]]
for line in open(path, errors="replace"):
    if pattern.search(line) and not any(e.search(line) for e in expected):
        print(line.rstrip())
PY
}
check_unexpected_log() { # LABEL LOG
  local label="$1" log="$2" log_errors
  if ! log_errors="$(unexpected_log_errors "$log")"; then
    fail "$label unreadable: $log"
  elif [[ -n $log_errors ]]; then
    fail "$label holds errors:"
    head -n 20 <<<"$log_errors"
  else
    ok "$label holds no unexpected error ($log)"
  fi
}

# The teardown runs on every exit, so it is armed before either directory
# exists and removes only what was made.
source "$repo/scripts/smoke/teardown.sh"

sandbox="$(mktemp -d "${TMPDIR:-/tmp}/vgsh-smoke.XXXXXX")"
# Keep the runtime path short to leave room for Hyprland's IPC socket names.
rt_dir="$(mktemp -d "$XDG_RUNTIME_DIR/vs.XXXXXX")"
home="$sandbox/home"; mkdir -p "$home/.config/hypr"

# Add the observer to a copy; the live checkout never imports test code.
# A caller may set source_tree to another export of the shell, bin, config
# and themes, such as scripts/sandbox-shots.sh --rev; the scripts, the probe
# and the fixtures come from this checkout, except the runtime helpers an
# older revision's export carries under scripts/, which its bin/ loads.
tree_harness_copy "$repo" "$sandbox/repo" "${source_tree:-$repo}"
python3 - "$repo" "$sandbox/repo" <<'PY'
import pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
# The copy ships no target: each would detect the host's own application on
# PATH, and its reload hook would signal that application in the live
# session. The rows add the fixture targets they read. A tree older than the
# targets has none to remove.
if (target / "themes/targets").exists():
    shutil.rmtree(target / "themes/targets")
(target / "themes/targets").mkdir()
shutil.copyfile(source / "scripts/smoke/Probe.qml", target / "shell/Probe.qml")
path = target / "shell/shell.qml"
text = path.read_text()
needle = "ShellRoot {\n"
assert text.count(needle) == 1, "smoke root insertion must match once"
path.write_text(text.replace(needle, needle + "    Probe {}\n"))
path = target / "shell/Core/Config.qml"
text = path.read_text()
needle = "    id: root\n"
assert text.count(needle) == 1, "smoke Config alias insertion must match once"
path.write_text(text.replace(needle, needle + "    property alias smokeUserView: userView\n"))
path = target / "shell/Hosts/BackgroundHost.qml"
text = path.read_text()
needle = "    id: host\n"
assert text.count(needle) == 1, "smoke background observer insertion must match once"
path.write_text(text.replace(needle, needle + '    onBrokenKeysChanged: console.info("smoke: backgroundFailures=" + Object.keys(brokenKeys).length)\n'))
PY
[[ -z ${source_tree:-} ]] || tree_overlay_helpers "$source_tree" "$sandbox/repo"
repo="$sandbox/repo"

cat >"$home/.config/hypr/hyprland.lua" <<'LUA'
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
hl.monitor({ output = "SMOKE-HIDPI", mode = "1280x720", position = "auto", scale = 2 })
hl.config({
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true, disable_autoreload = true },
    animations = { enabled = false },
})
-- Empty workspaces the compositor keeps alive, so the bar draws more than
-- one workspace pill and one whose label is wider than the pill's floor.
hl.workspace_rule({ workspace = "2", persistent = true })
hl.workspace_rule({ workspace = "100", persistent = true })
LUA
# The shell's first run wires this file (rows/hyprland.sh), so the rows
# compare it with the harness's own text.
cp -- "$home/.config/hypr/hyprland.lua" "$sandbox/hyprland-harness.lua"

# node on PATH may be a version-manager shim that reads the developer's own
# configuration and fails under the sandbox HOME; the sandbox PATH leads with
# the directory of the binary it resolves to. VGS_TEST_RUN, the test-run
# marker, keeps the theme judge from running a reload hook through the
# host's PATH or session: docs/architecture/validation.md.
if ! node_bin="$(node -e 'process.stdout.write(process.execPath)')"; then
  printf 'qml-smoke: status=not-measured missing=node-binary\n'
  exit 77
fi
sandbox_env=(env -i
  HOME="$home" PATH="$(dirname -- "$node_bin"):$PATH" USER="${USER:-$(id -un)}" TERM=dumb LANG=C.UTF-8
  XDG_RUNTIME_DIR="$rt_dir" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share"
  XDG_STATE_HOME="$home/.local/state" XDG_CACHE_HOME="$home/.cache" TMUX_TMPDIR="$rt_dir" VGS_TEST_RUN=1)

# The shell alone resolves hyprctl through this directory, so a row can
# stand a command in for it without touching what the rows themselves run.
# The stand-in execs the real binary; a row that needs a start failure
# swaps in a file whose interpreter does not exist, which exec refuses.
shim="$sandbox/shim"; mkdir -p "$shim"
if ! hyprctl_bin="$(command -v hyprctl)"; then
  printf 'qml-smoke: status=not-measured missing=hyprctl-binary\n'
  exit 77
fi
printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$hyprctl_bin" >"$shim/hyprctl.real"
printf '#!/nonexistent/interpreter\n' >"$shim/hyprctl.unstartable"
chmod 755 "$shim/hyprctl.real" "$shim/hyprctl.unstartable"
cp -- "$shim/hyprctl.real" "$shim/hyprctl"
# Rows swap the stand-in whole, so the shell never sees a half-written file.
shim_hyprctl() { cp -- "$shim/hyprctl.$1" "$shim/hyprctl.next" && mv -T -- "$shim/hyprctl.next" "$shim/hyprctl"; }

# The test helpers, built from the repository into the sandbox, each with
# the client code wayland-scanner generates from the one protocol file
# vendored beside it. Each is only ever run with the nested socket in its
# environment. click: one click through the nested compositor's virtual
# pointer protocol. toplevel: one xdg toplevel with a given app-id, so a
# row reads back how the nested compositor places a window of that class.
# build_helper NAME KEY SOURCE PROTOCOL_XML; a failed build exits 77 as
# missing=KEY-helper-build.
build_helper() {
  local protocol
  protocol="$(basename -- "$4" .xml)"
  if ! (cd "$sandbox" \
        && wayland-scanner client-header "$4" "$protocol-client-protocol.h" \
        && wayland-scanner private-code "$4" "$protocol-protocol.c" \
        && cc -o "$1" "$3" "$protocol-protocol.c" -I. $(pkg-config --cflags --libs wayland-client)) >"$sandbox/$1-build.log" 2>&1; then
    printf 'qml-smoke: status=not-measured missing=%s-helper-build\n' "$2"
    cat "$sandbox/$1-build.log"
    exit 77
  fi
}
build_helper click pointer "$repo/scripts/smoke/pointer/click.c" "$repo/scripts/smoke/pointer/wlr-virtual-pointer-unstable-v1.xml"
build_helper toplevel toplevel "$repo/scripts/smoke/toplevel/toplevel.c" "$repo/scripts/smoke/toplevel/xdg-shell.xml"

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

# The nested output can take a moment to appear. The shell starts once the
# compositor lists monitors and every one has a size, so no bar is built
# for the placeholder screen Qt invents when a compositor has no output
# yet, nor for the 0x0 FALLBACK monitor Hyprland lists when no output is
# ready two seconds after launch, as when the host is slow to configure
# the nested window. Hyprland configures no layer surface on a monitor
# with no size, so a bar there would never lay out or reserve space.
# sized_monitors prints the monitor count, or 0 while any listed monitor
# has no size, then each monitor as NAME:WxH.
sized_monitors() {
  hypr -j monitors | python3 -c 'import json,sys; ms=json.load(sys.stdin); print(len(ms) if ms and all(m["width"] > 0 and m["height"] > 0 for m in ms) else 0, ",".join("%s:%dx%d" % (m["name"], m["width"], m["height"]) for m in ms))'
}
monitors=-1
monitors_seen=""
for _ in $(seq 1 50); do
  if read -r monitors monitors_seen < <(sized_monitors 2>/dev/null) && [[ $monitors -gt 0 ]]; then break; fi
  sleep 0.2
done
if [[ $monitors -gt 0 ]]; then ok "nested compositor lists $monitors monitor(s): $monitors_seen"
elif [[ -n $monitors_seen ]]; then
  printf 'qml-smoke: status=not-measured nested-monitor=unsized monitors=%s\n' "$monitors_seen"
  echo "the nested compositor listed a monitor with no size for 10 s, so it would configure no bar; FALLBACK is Hyprland's placeholder while the host has not configured the nested window. Run the smoke again"
  exit 77
else
  printf 'qml-smoke: status=not-measured missing=nested-monitor\n'; exit 77
fi
# The shipped bar carries its clock and workspaces as built-ins, so the
# widget rows use a third-party widget placed in the user file before the
# shell starts. The launcher and the notifications, first-party and so
# enabled by default, start disabled here: their shortcuts, IPC targets,
# notification subscriber and server would sit in every lending record the
# capability rows read back. rows/launcher.sh and rows/notifications.sh
# enable them. vgs.settings starts disabled for the same reason, and its
# service would be one more build in the bar rows' count;
# rows/manager.sh enables it and rows/settings.sh disables it again. vgs.themes stays enabled, its background built on every
# screen: it maps no surface while the sandbox holds no backgrounds.json,
# so the host rows see only their fixture's background surface.
tick="$home/.config/vgs/plugins/acme.tick"
mkdir -p "$tick"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.tick/." "$tick/"
cat >"$home/.config/vgs/shell.json" <<'JSON'
{ "version": 1, "bar": { "id": "vgs.bar", "layout": { "left": [], "center": [{ "id": "acme.tick", "format": "ddd d MMM  HH:mm" }], "right": [] } }, "disabledPlugins": ["vgs.launcher", "vgs.notifications", "vgs.settings"] }
JSON

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
start_ms="$(now_ms)"
spawn "$sandbox/qs.log" "${shell_env[@]}" PATH="$shim:$(dirname -- "$node_bin"):$PATH" VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR="$shim" "$repo/bin/vgsh" run
shell_pid="$spawn_pid"
# click X Y: one left click at that layout position on the nested seat.
# click_centre HOST_KEY ID: the same on the centre of a built instance.
# hover X Y: the pointer moved there with no press. drag X Y X2 Y2: a
# press at (X, Y), moved to (X2, Y2) and released. type_keys ARGS...:
# keys typed on the nested seat through wtype, so a row can reach a
# focused input; wtype's own arguments, such as -k Escape, pass through.
# Each prints nothing on success; a row reads its status.
click() { "${shell_env[@]}" "$sandbox/click" "$1" "$2" "$mon_w" "$mon_h" >/dev/null; }
hover() { "${shell_env[@]}" "$sandbox/click" "$1" "$2" "$mon_w" "$mon_h" move >/dev/null; }
drag() { "${shell_env[@]}" "$sandbox/click" "$1" "$2" "$mon_w" "$mon_h" drag "$3" "$4" >/dev/null; }
type_keys() { "${shell_env[@]}" wtype "$@"; }
click_centre() {
  local rect
  rect="$(ipc smoke instanceGeometry "$1" "$2")" || return
  read -r cx cy < <(python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); print(int(x+w/2), int(y+h/2))' "$rect")
  click "$cx" "$cy"
}
# click_item HOST_KEY ID TYPE TEXT [X Y]: one click on the first visible,
# enabled control TYPE reading TEXT under an instance, at its centre or at
# (X, Y), once the control reports the pointer over that point. The
# compositor routes a click by where it has placed the surface, which can
# trail the layout the probe reads after the surface resizes, so a click
# at the probe's coordinates alone can land on a neighbour. The pointer
# moves there every 100 ms, one pixel apart so each move is a motion, for
# up to 5 s, and the click follows two readings in a row, so a reading
# taken before the move reached the shell never decides it. Returns 1,
# with no click, when the control is absent or never reports the pointer.
click_item() { # HOST_KEY ID TYPE TEXT [X Y]
  local rect x y px hovered="" held=0 i
  rect="$(ipc smoke itemGeometry "$1" "$2" "$3" "$4")" && [[ $rect != absent ]] || return 1
  if [[ $# -ge 6 ]]; then x="$5"; y="$6"
  else read -r x y < <(python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); print(int(x+w/2), int(y+h/2))' "$rect") || return 1
  fi
  for i in $(seq 1 50); do
    px=$((x + i % 2))
    hover "$px" "$y" || return 1
    hovered="$(ipc smoke itemHovered "$1" "$2" "$3" "$4")" || return 1
    if [[ $hovered == true ]]; then held=$((held + 1)); else held=0; fi
    if [[ $held -ge 2 ]]; then click "$px" "$y"; return; fi
    sleep 0.1
  done
  return 1
}

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
ipc() {
  "${shell_env[@]}" "$repo/bin/vgsh" ipc call "$@" 2>>"$sandbox/ipc.log" | tail -n 1
}

# The theme runner's jobs as [verb, name, waiters] rows, from the lending
# record of the shell IPC_FN reaches (default ipc).
theme_jobs() { # [IPC_FN]
  "${1:-ipc}" shell lent | python3 -c 'import json,sys; print(json.dumps([[j["verb"], j["name"], j["waiters"]] for j in json.load(sys.stdin)["theme"]["jobs"]]))'
}
# Whether the shell holds the theme lock, read once: `idle` when its first
# plugin scan has ended and its theme runner then holds no job in its
# queue or its download lane; `scan=pending` before that scan ends; else
# those jobs as theme_jobs rows, the download last. Registry.qml marks a
# scan done and emits scanFinished in one handler, and shell.qml queues
# the follow on that signal, so no reply lands between the two; the
# runner is the shell's one theme-lock holder, so `idle` means no follow,
# apply or download runs or waits. The scan is read first; a scan ending
# between the two reads shows its follow as a job. A later scan in flight
# shows no job, so a row that rescans reads the rescan's own effect before
# it asks.
theme_state() { # [IPC_FN]
  local via="${1:-ipc}" scanned held
  scanned="$("$via" shell listPlugins | python3 -c 'import json,sys; print(json.load(sys.stdin)["scanned"])')" || return
  if [[ $scanned != True ]]; then echo "scan=pending"; return; fi
  held="$("$via" shell lent | python3 -c 'import json,sys; t=json.load(sys.stdin)["theme"]; print(json.dumps([[j["verb"], j["name"], j["waiters"]] for j in t["jobs"] + ([] if t["download"] is None else [t["download"]])]))')" || return
  if [[ $held == '[]' ]]; then echo idle; else printf '%s\n' "$held"; fi
}
# theme_state polled every 200 ms until `idle`, for up to 20 s, since an
# apply lasts past expect_poll's 5 s when a target's hook runs; the last
# answer otherwise. A row runs a `vgsh theme` command only once the shell
# is idle: a command started under the shell's follow is refused
# reason=busy, the product's answer, which a retry would hide.
theme_idle() { # [IPC_FN]
  local state=""
  for _ in $(seq 1 100); do
    state="$(theme_state "$@")" || return
    [[ $state == idle ]] && { echo idle; return; }
    sleep 0.2
  done
  printf '%s\n' "$state"
}

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


# Live bar surfaces the nested compositor lists. A layer whose client is
# gone stays in the list with pid -1 until the compositor drops it, so only
# a layer with a client counts. Space every monitor reserves for layers is
# read beside it: a bar that is gone reserves nothing.
bar_count() { hypr -j layers | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for m in d.values() for lv in m["levels"].values() for l in lv if l["namespace"]=="vgs:bar" and l["pid"]!=-1))'; }
reserved_total() { hypr -j monitors | python3 -c 'import json,sys; print(sum(sum(m["reserved"]) for m in json.load(sys.stdin)))'; }
# Live layers with a namespace as [[x, y, w, h], ...], sorted.
layers_of() { hypr -j layers | python3 -c 'import json,sys; print(json.dumps(sorted([l["x"],l["y"],l["w"],l["h"]] for m in json.load(sys.stdin).values() for lv in m["levels"].values() for l in lv if l["namespace"]==sys.argv[1] and l["pid"]!=-1)))' "$1"; }
layer_count() { layers_of "$1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
# output_mode NAME MODE: the nested compositor gives output NAME the mode
# MODE, such as 480x720, at scale 1 and the layout's origin, through a Lua
# monitor rule; the reply is hyprctl's. The nested output takes any mode,
# which the rows use for a monitor narrower than a window; a headless
# output the rows could add instead stays 0x0 in the sandbox, its buffers
# failing to allocate. A row restores the mode it read first.
output_mode() { hypr eval "hl.monitor({ output = \"$1\", mode = \"$2\", position = \"0x0\", scale = 1 })"; }
# mode_of NAME: output NAME's mode as WxH; returns 1 when no monitor has
# that name.
mode_of() { hypr -j monitors | python3 -c 'import json,sys; m=[m for m in json.load(sys.stdin) if m["name"]==sys.argv[1]]; print("%dx%d" % (m[0]["width"], m[0]["height"])) if len(m)==1 else sys.exit(1)' "$1"; }
# hold_mode LABEL NAME MODE: output NAME takes MODE and the rows after it
# hold that mode until release_mode. The hold begins once the monitor reads
# MODE; a mode never taken is a failure and holds nothing.
hold_mode() {
  local label="$1" output="$2" mode="$3" failed_before="$failures"
  [[ ${#mode_hold[@]} -eq 0 ]] || { fail "$label: ${mode_hold[0]} already holds ${mode_hold[1]}; hold_mode does not nest"; return; }
  expect "$label" ok output_mode "$output" "$mode"
  expect_poll "$output reads the mode $mode" "$mode" mode_of "$output"
  [[ $failures -eq $failed_before ]] && mode_hold=("$output" "$mode")
  return 0
}
# held_mode_state: what became of the held mode, as one word. `held`: the
# output reads it. `reset`: the output reads another mode. Once the hold
# began, two writers move a nested output off it, and neither is what a
# held row measures. Hyprland gives a Wayland-backend output the size of
# every configure the host sends the nested window that differs from its
# rule's mode (src/output/Monitor.cpp, the output's state listener,
# Hyprland v0.56.2), and the host sends one whenever it resizes the window
# or changes its state, focus included. A configuration reload, which the
# shell runs when its Hyprland layer changes, drops the monitor rule
# output_mode added through `hyprctl eval` (src/config/lua/ConfigManager.cpp,
# CConfigManager::reload). The shell writes no monitor rule of its own.
# `unreadable`: the monitor cannot be read, which excuses nothing.
held_mode_state() {
  local mode
  mode="$(mode_of "${mode_hold[0]}")" || { echo unreadable; return; }
  if [[ $mode == "${mode_hold[1]}" ]]; then echo held; else echo reset; fi
}
# release_mode LABEL NAME MODE: any hold ends and output NAME takes MODE
# again, whether or not hold_mode's mode was taken.
release_mode() {
  mode_hold=()
  expect "$1" ok output_mode "$2" "$3"
}
# The first monitor's mode as WxH, and its logical width.
first_mode() { hypr -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print("%dx%d" % (m["width"], m["height"]))'; }
first_width() { hypr -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print(round(m["width"] / m["scale"]))'; }
# The one live layer with a namespace as [x, y, w, h], or layers=<n>.
one_layer() { layers_of "$1" | python3 -c 'import json,sys; l=json.load(sys.stdin); print(json.dumps(l[0]) if len(l) == 1 else "layers=%d" % len(l))'; }
# at_centre NAMESPACE RECT_JSON: the layout position of the centre of a box
# given in the coordinates of that namespace's one layer window, the
# layer's position added: a layer the compositor centres knows no place of
# its own, so the probe answers boxes in window coordinates.
at_centre() {
  local layer
  layer="$(one_layer "$1")" || return 1
  python3 -c 'import json,sys; l=json.loads(sys.argv[1]); r=json.loads(sys.argv[2]); print(int(l[0] + r[0] + r[2] / 2), int(l[1] + r[1] + r[3] / 2))' "$layer" "$2"
}
# click_in NAMESPACE HOST_KEY ID TYPE TEXT: one click on the centre of the
# first shown item of TYPE whose text or label is TEXT in that instance,
# drawn in the namespace's one layer.
click_in() {
  local rect x y
  rect="$(ipc smoke windowGeometry "$2" "$3" "$4" "$5")" || return 1
  [[ $rect == \[* ]] || { echo "click_in: no $4 $5: $rect" >&2; return 1; }
  read -r x y < <(at_centre "$1" "$rect") || return 1
  click "$x" "$y"
}

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

# The first bar host's key, for reading a widget instance back.
bar_key() { ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(k for k in d if k.startswith("bar:"))[0])'; }

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

# A rebuild counter: the core counts every instance it builds. Rows below
# assert that an unrelated write and a rescan that changes nothing build
# nothing, and what a rescan that adds a disabled plugin builds.
builds() { ipc smoke buildCount; }

# One plugin's row in the registry listing: `plugin_known ID` prints True or
# False, `plugin_enabled ID` its enabled flag or `absent`. `record_exists ID`
# prints True when any build record under any host names ID.
plugin_known() { ipc shell listPlugins | python3 -c 'import json,sys; print(any(p["id"]==sys.argv[1] for p in json.load(sys.stdin)["plugins"]))' "$1"; }
plugin_enabled() { ipc shell listPlugins | python3 -c 'import json,sys; rows=[p["enabled"] for p in json.load(sys.stdin)["plugins"] if p["id"]==sys.argv[1]]; print(rows[0] if rows else "absent")' "$1"; }
record_exists() { ipc shell built | python3 -c 'import json,sys; print(any(r["id"]==sys.argv[1] for rows in json.load(sys.stdin).values() for r in rows))' "$1"; }

smoke_finish() {
if [[ $failures -gt 0 ]]; then
  echo "--- instance log tail"; tail -n 40 "${instance_log:-$sandbox/qs.log}" 2>/dev/null || true
  echo "--- nested compositor log tail"; tail -n 40 "$rt_dir"/hypr/*/hyprland.log 2>/dev/null || true
fi
local status=0
smoke_verdict "$failures" "$behaviour_failures" "$stalled_render" "$mode_resets" "$rt_dir"/hypr/*/hyprland.log || status=$?
[[ $status -eq 0 ]] || exit "$status"
}
