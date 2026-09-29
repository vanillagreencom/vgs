# Sourced by qml-smoke.sh; owns the sandbox and shared readers.
set -euo pipefail
source "$repo/scripts/smoke/verdict.sh"
source "$repo/scripts/smoke/tree.sh"
source "$repo/scripts/smoke/shot.sh"
source "$repo/scripts/smoke/app-window.sh"
missing=()
# fd, fzf and file are the launcher file search helper's, which rows/launcher.sh runs;
# grim reads the pixels app-window.sh checks.
for tool in Hyprland qs hyprctl python3 node flock setsid git dbus-daemon gdbus cc wayland-scanner pkg-config wtype fd fzf file grim; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
# ImageMagick, `magick` or `convert`, converts the Slack custom emoji the
# notifications row and the shots' Slack scene draw.
command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1 || missing+=("magick")
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
-- Logs stay off while the startup latencies are read, since logging every
-- surface slows the first bar; compositor_logs_on creates this file and
-- reloads, and the cursor rows then read each cursor shape the compositor
-- takes from the shell through `hyprctl rollinglog`.
local logs = io.open(os.getenv("XDG_RUNTIME_DIR") .. "/compositor-logs")
if logs then logs:close() end
hl.config({
    misc = { disable_hyprland_logo = true, disable_splash_rendering = true, disable_autoreload = true },
    animations = { enabled = false },
    debug = { disable_logs = logs == nil },
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
# rows/manager.sh enables it and rows/settings.sh disables it again.
# vgs.agent-warden starts disabled for the same reason; rows/agent-warden.sh
# enables it and disables it again. vgs.devtools starts disabled too: its
# service's IPC target and status record would sit in the capability rows'
# lending records, and its queries would run the host's mise;
# rows/devtools.sh enables it over stub commands. vgs.themes stays enabled, its background built on every
# screen: it maps no surface while the sandbox holds no backgrounds.json,
# so the host rows see only their fixture's background surface.
#
# plugin_set, which scripts/qml-smoke.sh sets, picks the set the shell
# starts with: `smoke`, the rows' own set above, or `default`, the shipped
# configuration's, with every first-party plugin enabled as in a live
# session, which rows/start-order.sh and the default-set first-bar
# readings start (docs/architecture/validation-latency.md).
plugin_set="${plugin_set:-smoke}"

# devtools_stand_ins: vgs.devtools's host commands in the shell's own PATH
# directory: a mise whose installs are one key per line of
# $dev_state/installed, with one global tool no row declares, a docker and
# a podman that hold no container, and a pacman that owns no file. The
# mise answers what list, launchers and pkg check ask: its version,
# `ls --json` and `ls --global --json` from the installed keys, `which`
# for no command and `outdated --json` with no update. Writing them again
# resets the installs.
dev_state="$sandbox/devtools-mise"
devtools_stand_ins() {
  mkdir -p "$dev_state"
  echo "github:acme/extra" >"$dev_state/installed"
  cat >"$shim/mise" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo "2026.9.9 linux-x64 (stub)" ;;
  ls)
    first=1
    printf '{'
    while IFS= read -r key; do
      [[ -n \$key ]] || continue
      [[ \$first == 1 ]] || printf ','
      first=0
      printf '"%s":[{"version":"1.0.0","installed":true,"active":true}]' "\$key"
    done <"$dev_state/installed"
    printf '}\n' ;;
  which) printf 'mise ERROR %s is not a mise bin. Perhaps you need to install it first.\n' "\$2" >&2; exit 1 ;;
  outdated) echo '{}' ;;
  *) exit 0 ;;
esac
EOF
  printf '#!/bin/sh\nexit 0\n' >"$shim/docker"
  printf '#!/bin/sh\nexit 0\n' >"$shim/podman"
  printf '#!/bin/sh\necho "error: No package owns $2" >&2\nexit 1\n' >"$shim/pacman"
  chmod 755 "$shim/mise" "$shim/docker" "$shim/podman" "$shim/pacman"
}

# The libsecret stand-in vgs.notifications reads its Slack tokens
# through, in the directory the harness hands the shell as
# VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR. $shim/secret-tool.states
# holds `<account> <state>` lines, and an account holds its token while its
# state reads `present`, none for `absent` or an account the file does not
# list, and holds it in a locked collection for `locked`. `lookup` answers
# as the photo helper reads it; `search` answers as libsecret's secret-tool
# does, the item and an unlocked secret on stdout and the attributes and a
# lock on stderr, for the token probe. Every token starts xoxp-smoke-.
# slack_states STATES: the states file rewritten from STATES, lines joined
# by `;`. secret_tool_stand_in STATES: the stand-in written, with STATES.
slack_states() { tr ';' '\n' <<<"$1" >"$shim/secret-tool.states"; }
secret_tool_stand_in() { # STATES
  slack_states "$1"
  cat >"$shim/secret-tool" <<SH
#!/usr/bin/env bash
[[ \${2:-} == service && \${3:-} == vgs-notifications && \${4:-} == account && \$# -eq 5 ]] || exit 1
account="\$5" state=absent
while read -r name answer; do [[ \$name == "\$account" ]] && state="\$answer"; done <"$shim/secret-tool.states"
token="xoxp-smoke-\$(tr : - <<<"\$account")"
case "\${1:-}:\$state" in
  lookup:present) printf '%s\\n' "\$token" ;;
  search:present) printf '[/1]\\nlabel = VGS notifications Slack token\\nsecret = %s\\n' "\$token"; printf 'attribute.service = vgs-notifications\\nattribute.account = %s\\n' "\$account" >&2 ;;
  search:locked) printf '[/1]\\nlabel = VGS notifications Slack token\\n'; printf 'secret-tool: Cannot get secret of a locked object\\nattribute.service = vgs-notifications\\nattribute.account = %s\\n' "\$account" >&2 ;;
  search:absent) ;;
  *) exit 1 ;;
esac
SH
  chmod 755 "$shim/secret-tool"
}

# default_set_prepare PLUGINS_JSON [DISABLED_JSON]: what a start over the
# default set needs before the shell starts. The user file names no bar
# and disables nothing, so the shipped bar and every first-party plugin
# build; it enables the third-party plugins PLUGINS_JSON lists, a JSON
# list of ids, and disables those DISABLED_JSON lists.
# Every host command a default-set service runs at start reaches a
# stand-in or does not run: vgs.devtools's queries reach
# devtools_stand_ins; vgs.updates reads a status cache written as a check
# that ended now and listed nothing, so its service starts no check for
# hours, since each probe of a check runs a host package manager or a git
# fetch, which only rows/updates.sh's copy confines; vgs.agent-warden
# notifies only once the warden's status file exists, which no start
# finds; vgs.notifications reads its token only through
# secret_tool_stand_in, which lists no account for a start over the default set.
default_set_prepare() { # PLUGINS_JSON [DISABLED_JSON]
  devtools_stand_ins
  secret_tool_stand_in ""
  mkdir -p "$home/.local/state/vgs/updates"
  python3 - "$home/.local/state/vgs/updates/status.json" "$home/.config/vgs/shell.json" "$1" "${2:-[]}" <<'PY'
import json, os, sys, time
cache, user, plugins, disabled = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
for path, doc in ((cache, {"checkedAt": int(time.time() * 1000), "sources": []}),
                  (user, {"version": 1, "plugins": [{"id": p} for p in plugins], "disabledPlugins": disabled})):
    with open(path + ".tmp", "w") as out:
        json.dump(doc, out)
    os.replace(path + ".tmp", path)
PY
}

mkdir -p "$home/.config/vgs"
case "$plugin_set" in
  smoke)
    tick="$home/.config/vgs/plugins/acme.tick"
    mkdir -p "$tick"
    cp -R "$repo/scripts/smoke/fixtures/plugins/acme.tick/." "$tick/"
    cat >"$home/.config/vgs/shell.json" <<'JSON'
{ "version": 1, "bar": { "id": "vgs.bar", "layout": { "left": [], "center": [{ "id": "acme.tick", "format": "ddd d MMM  HH:mm" }], "right": [] } }, "disabledPlugins": ["vgs.launcher", "vgs.notifications", "vgs.settings", "vgs.updates", "vgs.agent-warden", "vgs.devtools"] }
JSON
    ;;
  default) default_set_prepare '[]' ;;
  *) printf 'qml-smoke: refused: plugin-set=%s\n' "$plugin_set"; exit 2 ;;
esac

now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
# The host's CPU pressure stall total in microseconds: the `total=` field of
# the `some` line of /proc/pressure/cpu, the time in which at least one
# runnable task on the host waited for a CPU. Prints nothing when pressure
# stall information is unreadable.
cpu_some_us() {
  local kind rest
  { while read -r kind rest; do
      if [[ $kind == some && $rest =~ total=([0-9]+) ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
    done </proc/pressure/cpu; } 2>/dev/null || true
}
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
# compositor_logs_on: the nested compositor logs from here to the end of
# the run. The configuration turns its logs on once the flag file exists,
# and a reload reads it again; `hyprctl eval` would set the option without
# the reload that applies it, and a reload drops what eval set. Returns 1
# unless the reload added lines to the rolling log, which holds only the
# lines logged before the configuration first loaded until then.
compositor_logs_on() {
  local before after
  before="$(hypr rollinglog)" || return 1
  : >"$rt_dir/compositor-logs" || return 1
  [[ $(hypr reload config-only) == ok ]] || return 1
  after="$(hypr rollinglog)" || return 1
  [[ $after != "$before" ]]
}
# rest_pointer: the pointer moved to the monitor's bottom-left corner, off
# every surface a row maps, so a surface a later row opens finds the
# pointer over none of its controls. A resting pointer the launcher's list
# opens under takes no row: the launcher row reads that with the pointer
# at the screen's centre.
rest_pointer() { hover 10 "$((mon_h - 10))"; }
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
# trail the layout the probe reads after the surface resizes, and a list
# that grows after it opens can move the control, so a box read once goes
# stale. Every 100 ms, for up to 5 s, the helper reads the control's box
# again, moves the pointer to its point, one pixel apart each time so each
# move is a motion, and reads whether the control reports the pointer. It
# clicks after two such readings in a row at one box, so a reading taken
# before the move reached the shell never decides it, and reads the box
# once more before the press: a box that moved starts the count again.
# Returns 1, with no click, when the control is absent at the first
# reading or never reports the pointer; a control absent at a later
# reading is being laid out again, and the count starts again.
click_item() { # HOST_KEY ID TYPE TEXT [X Y]
  local rect seen="" x="" y="" px hovered held=0 i
  for i in $(seq 1 50); do
    rect="$(ipc smoke itemGeometry "$1" "$2" "$3" "$4")" || return 1
    if [[ $rect == absent ]]; then
      [[ $i -gt 1 ]] || return 1
      held=0; seen=""; sleep 0.1; continue
    fi
    if [[ $rect != "$seen" ]]; then
      held=0; seen="$rect"
      if [[ $# -ge 6 ]]; then x="$5"; y="$6"
      else read -r x y < <(python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); print(int(x+w/2), int(y+h/2))' "$rect") || return 1
      fi
    fi
    px=$((x + i % 2))
    hover "$px" "$y" || return 1
    hovered="$(ipc smoke itemHovered "$1" "$2" "$3" "$4")" || return 1
    if [[ $hovered == true ]]; then held=$((held + 1)); else held=0; fi
    if [[ $held -ge 2 && $(ipc smoke itemGeometry "$1" "$2" "$3" "$4") == "$seen" ]]; then click "$px" "$y"; return; fi
    sleep 0.1
  done
  return 1
}

# expect_cursor_at LABEL SHAPE X Y: the pointer moved to the layout
# position (X, Y), the nested compositor's cursor is SHAPE: `pointer` for
# the hand, `default` for the arrow, `text` for the I-beam. The reading is the last
# shape Hyprland took from the client under the pointer through
# wp_cursor_shape, which it logs as `cursorImage request: shape <n> ->
# <name>` (CInputManager in src/managers/input/InputManager.cpp, v0.56.2),
# read through `hyprctl rollinglog`. Qt sends a shape only when it changes,
# so a last line that already names SHAPE before the move proves nothing:
# the helper fails then, and a row expects another shape between two
# readings of one. The pointer moves every 100 ms, one pixel apart so each
# move is a motion, for up to 5 s. expect_cursor LABEL SHAPE SURFACE
# RECT_JSON does the same at the centre of RECT_JSON, a box in the
# coordinates of SURFACE's window, a surface_box name.
cursor_shape() { hypr rollinglog | sed -n 's/.*cursorImage request: shape [0-9]* -> //p' | tail -n 1; }
expect_cursor() { # LABEL SHAPE SURFACE RECT_JSON
  local x y
  [[ $4 == \[* ]] || { fail "$1: no box: $4"; return; }
  read -r x y < <(at_centre "$3" "$4") || { fail "$1: no surface $3"; return; }
  expect_cursor_at "$1" "$2" "$x" "$y"
}
expect_cursor_at() { # LABEL SHAPE X Y
  local label="$1" want="$2" x="$3" y="$4" got="" seen="" i
  got="$(cursor_shape)" || { fail "$label: the compositor's log is unreadable"; return; }
  if [[ $got == "$want" ]]; then fail "$label: the compositor already shows $want before the move; expect another shape first"; return; fi
  for i in $(seq 1 50); do
    hover "$((x + i % 2))" "$y" || { fail "$label: moving the pointer failed"; return; }
    got="$(cursor_shape)" || { fail "$label: the compositor's log is unreadable"; return; }
    if [[ $got == "$want" ]]; then ok "$label"; return; fi
    # The rolling log drops old lines as the moves add new ones, so the
    # last shape read is the one the failure names.
    [[ -z $got ]] || seen="$got"
    sleep 0.1
  done
  fail "$label: got ${seen:-no shape} want $want"
}

# qs prints its own log lines on stdout ahead of the reply; the reply is the last line.
ipc() {
  "${shell_env[@]}" "$repo/bin/vgsh" ipc call "$@" 2>>"$sandbox/ipc.log" | tail -n 1
}
# py_reply PROGRAM [ARG...]: python3 -c PROGRAM ARG... over the reply on
# stdin, or the reply itself when it is a state word such as `absent`,
# which the smoke probe answers in place of JSON while the instance,
# surface or item it reads is not built, and `recorded` before the
# terminal stand-in writes its record, or a count word such as `areas=0`
# that an upstream reader answers. A poll over such a reply reads
# through this, so it retries on the word rather than raising on it. A
# word is lower-case letters joined by hyphens, with an optional `=N`;
# true, false and null are JSON and parsed. An empty reply, what a failed
# ipc call prints, is a failed read.
py_reply() { # PROGRAM [ARG...]
  local reply
  reply="$(cat)" || return
  [[ -n $reply ]] || return 1
  if [[ $reply =~ ^[a-z]+(-[a-z]+)*(=[0-9]+)?$ && $reply != true && $reply != false && $reply != null ]]; then
    printf '%s\n' "$reply"
    return 0
  fi
  python3 -c "$1" "${@:2}" <<<"$reply"
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

# The PATH every sandbox shell starts with: the shell's stand-in directory,
# then node's, then the host's. A row that stands in more commands puts
# its own directory ahead of it.
shell_start_path="$shim:$(dirname -- "$node_bin"):$PATH"
# start_shell TREE LOG [BAR [NAME=VALUE...]]: start the runner of TREE, a
# product tree holding its own bin/vgsh, as the sandbox's shell, its
# output in LOG, and wait for it through the ipc function, which a row
# that starts another tree's runner redefines first. The NAME=VALUE words
# go to env after the harness's own, so a row's PATH wins over
# shell_start_path. Sets shell_pid, the first-bar reading, shell_qs_pid
# and instance_log, which it clears first, so a failed start leaves no
# earlier shell's log in its place. BAR `no-bar` takes no first-bar
# reading, for a start that maps no bar. Returns 1, with the row failed,
# when the shell does not answer ping within timeout_s or names no
# instance log. The instance is found by pid among every instance in the
# sandbox's runtime dir, so an installed prefix, whose shell is not
# TREE/shell, is found as a checkout is.
#
# The first-bar reading is the latency from the runner's exec to the first
# bar surface with a client, polled every 10 ms from the compositor's
# layer list, which answers in a few milliseconds; the reading carries at
# most one poll interval. first_bar_cpu_some_pct records beside it the
# percent of that window in which some runnable task on the host waited
# for a CPU, from the host-wide pressure stall `some` totals read before
# the spawn and at the reading, with one decimal; `unmeasured` when either
# total is unreadable. It is a record for reading a slow start, not a
# gate. The load average is no measure of this: it counts tasks running on
# a CPU and tasks in uninterruptible sleep, so on a host with many CPUs a
# high load can mean no task waited at all.
#
# qs buffers stdout when redirected, so the shell's own per-instance log
# file is the record: it is line-flushed and holds every QML warning. The
# runner execs qs, so the shell's pid is the runner's unless setsid forked.
start_shell() { # TREE LOG [BAR [NAME=VALUE...]]
  local tree="$1" log="$2" bar="${3:-bar}" start_cpu_some_us start_ms bar_cpu_some_us layers_text tenths pong up=false child instance_id
  shift $(( $# < 3 ? $# : 3 ))
  [[ $bar == bar || $bar == no-bar ]] || { fail "start_shell: refused: bar=$bar want=bar|no-bar"; return 1; }
  instance_log=""
  start_cpu_some_us="$(cpu_some_us)"
  start_ms="$(now_ms)"
  spawn "$log" "${shell_env[@]}" PATH="$shell_start_path" VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR="$shim" "$@" "$tree/bin/vgsh" run
  shell_pid="$spawn_pid"
  shell_qs_pid="$shell_pid"
  first_bar_ms=""
  first_bar_cpu_some_pct=unmeasured
  if [[ $bar == bar ]]; then
    for _ in $(seq 1 $((timeout_s * 100))); do
      if layers_text="$(hypr layers 2>/dev/null)" && [[ $layers_text =~ namespace:\ vgs:bar,\ pid:\ [1-9] ]]; then
        first_bar_ms=$(( $(now_ms) - start_ms ))
        bar_cpu_some_us="$(cpu_some_us)"
        if [[ -n $start_cpu_some_us && -n $bar_cpu_some_us && $first_bar_ms -gt 0 ]]; then
          # Stalled microseconds over the window's milliseconds is the
          # percent in tenths.
          tenths=$(( (bar_cpu_some_us - start_cpu_some_us) / first_bar_ms ))
          first_bar_cpu_some_pct="$((tenths / 10)).$((tenths % 10))"
        fi
        break
      fi
      kill -0 "$shell_pid" 2>/dev/null || break
      sleep 0.01
    done
  fi
  for _ in $(seq 1 $((timeout_s * 5))); do
    if pong="$(ipc shell ping 2>/dev/null)" && [[ $pong == ok ]]; then up=true; break; fi
    kill -0 "$shell_pid" 2>/dev/null || break
    sleep 0.2
  done
  if [[ $up != true ]]; then
    fail "shell did not answer ping within ${timeout_s}s"
    tail -n 40 "$log"
    return 1
  fi
  ok "shell answers ping"
  if child="$(pgrep -P "$shell_pid" -x qs)"; then shell_qs_pid="$child"; fi
  for _ in $(seq 1 50); do
    if instance_id="$("${shell_env[@]}" qs list --all -j 2>/dev/null | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin) if i["pid"]==int(sys.argv[1])][0]["id"])' "$shell_qs_pid" 2>/dev/null)"; then
      instance_log="$rt_dir/quickshell/by-id/$instance_id/log.log"
      break
    fi
    sleep 0.2
  done
  if [[ -n $instance_log && -f $instance_log ]]; then ok "the shell's instance log is at $instance_log"; else fail "instance log not found for pid $shell_qs_pid"; instance_log=""; return 1; fi
}
# stop_shell: TERM to the runner start_shell started, waited on for up to
# 5 s, before a row starts another.
stop_shell() {
  kill -TERM "$shell_pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$shell_pid" 2>/dev/null || break
    sleep 0.1
  done
  wait "$shell_pid" 2>/dev/null || true
}
start_shell "$repo" "$sandbox/qs.log" || exit 1
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

# service_release: the release ServiceGate logged in the instance log, as
# `<reason> <waited_ms>`, polled every 0.2 s for up to 5 s; `unreleased -`
# when it logged none. waited_ms is the time from the gate's first
# judgement that found a bar unpresented to the release.
service_release() {
  local line
  for _ in $(seq 1 25); do
    if line="$(grep -o -E -m 1 -e 'plugins: services released reason=[a-z-]+ waited_ms=[0-9]+' -- "$instance_log")" \
      && [[ $line =~ reason=([a-z-]+)\ waited_ms=([0-9]+) ]]; then
      printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
      return 0
    fi
    sleep 0.2
  done
  echo "unreleased -"
}

# A reader answers a state word for every state it can meet, such as
# `absent` before a record exists, so a Python traceback on its stderr is
# a reader defect, never a state to retry past. reader_stderr LABEL
# ERR_FILE: when ERR_FILE, a reader's stderr, holds a traceback, the row
# LABEL fails with the traceback printed under it, and it returns 1;
# otherwise the file's text goes on to stderr and it returns 0. The pollers below send each read's stderr to a
# file named for the process that reads, since a row can nest a poller
# inside another's command substitution.
reader_stderr() { # LABEL ERR_FILE
  local label="$1" err="$2" status=0
  # The common read writes no stderr and costs no fork here; its empty
  # file stays for the next read to truncate.
  [[ -s $err ]] || return 0
  if grep -q -F -e 'Traceback (most recent call last):' -- "$err"; then
    fail "$label: the reader raised a Python traceback"
    sed 's/^/        /' -- "$err"
    status=1
  else
    cat -- "$err" >&2
  fi
  rm -f -- "$err"
  return "$status"
}
# expect LABEL WANT CMD...: the command's last stdout line must equal WANT.
# A command that fails is a failure, never an empty string that happens to
# compare unequal; one that raised a traceback fails as reader_stderr says.
expect() {
  local label="$1" want="$2" got status=0 err="$sandbox/reader-$BASHPID.stderr"
  shift 2
  got="$("$@" 2>"$err")" || status=$?
  reader_stderr "$label" "$err" || return 0
  if [[ $status -ne 0 ]]; then fail "$label: command failed: $*"; return; fi
  if [[ $got == "$want" ]]; then ok "$label"; else fail "$label: got $got"; fi
}
# expect_poll LABEL WANT CMD...: as expect, retried for up to 5 s, for a
# state that follows a write through the watcher, the merge and a rebuild.
# A failed read is retried; a traceback fails the row at once.
expect_poll() { # LABEL WANT CMD...
  local label="$1" want="$2" got="" matched err="$sandbox/reader-$BASHPID.stderr"
  shift 2
  for _ in $(seq 1 25); do
    matched=false
    if got="$("$@" 2>"$err")" && [[ $got == "$want" ]]; then matched=true; fi
    reader_stderr "$label" "$err" || return 0
    if [[ $matched == true ]]; then ok "$label"; return; fi
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
# The acme.layers fixture's passive layer, which rows/toasts.sh,
# rows/layers.sh and rows/notices.sh put under other surfaces: layered
# VERB [ARG] runs one of its IPC verbs, read_layers PROPERTY reads its
# service, such as `presses`, the count of presses that reached it.
layered() { ipc acme.layers invoke "$1" "${2:-}"; }
read_layers() { ipc smoke readInstance service acme.layers "$1"; }
# layer_bar_geometry NAMESPACE TOKEN: the one live layer of NAMESPACE, the
# first bar and the theme's length TOKEN, the gap the layer keeps from the
# free area's edges, as `layer=x,y,w,h bar=x,y,w,h margin=n`, or `absent`
# while either layer is missing. layer_bar_contract_value reads that line
# on stdin: `ok` when the layer overlaps no bar and keeps at least the
# margin from a bar it shares a column with, else `violation` and the
# broken rules, or the line itself when it is no measurement.
# layer_bar_clear NAMESPACE TOKEN: the two in one.
layer_bar_geometry() { # NAMESPACE TOKEN
  local layers bars margin
  layers="$(layers_of "$1")" || return
  bars="$(layers_of vgs:bar)" || return
  margin="$(ipc smoke themeValue "$2")" || return
  python3 - "$layers" "$bars" "$margin" <<'PY'
import json, sys
layers, bars, margin = json.loads(sys.argv[1]), json.loads(sys.argv[2]), int(json.loads(sys.argv[3]))
if not layers or not bars:
    print("absent")
    sys.exit()
print("layer=%d,%d,%d,%d bar=%d,%d,%d,%d margin=%d" % (*layers[0], *bars[0], margin))
PY
}
layer_bar_contract_value() {
  python3 -c 'import re,sys
t = sys.stdin.read().strip()
m = re.fullmatch(r"layer=(\d+),(\d+),(\d+),(\d+) bar=(\d+),(\d+),(\d+),(\d+) margin=(\d+)", t)
if not m: print(t); sys.exit()
tx, ty, tw, th, bx, by, bw, bh, margin = map(int, m.groups())
horizontal = tx < bx + bw and bx < tx + tw
vertical = ty < by + bh and by < ty + th
problems = []
if horizontal and vertical:
    problems.append("overlap")
elif horizontal:
    gap = ty - (by + bh) if by < ty else by - (ty + th)
    if gap < margin:
        problems.append("margin")
print("ok" if not problems else "violation " + ",".join(problems))'
}
layer_bar_clear() { # NAMESPACE TOKEN
  local t
  t="$(layer_bar_geometry "$1" "$2")" || return
  layer_bar_contract_value <<<"$t"
}
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
# The shell's application windows are the nested instance's clients of the
# shell's class, HyprlandLayer.APP_WINDOW.appId, read from the file the
# shell reads it from, each named by its title. A tree older than
# application windows has none, and its class is empty, which no client has.
if ! shell_class="$(node -e 'const w = require(process.argv[1]).load(process.argv[2]).APP_WINDOW; process.stdout.write(w === undefined ? "" : w.appId)' "$repo/bin/lib/qml-library.js" "$repo/shell/Core/HyprlandLayer.js")"; then
  printf 'qml-smoke: status=not-measured missing=app-window-class\n'
  exit 77
fi
# windows_of TITLE: the shell's live windows titled TITLE as
# [[x, y, w, h], ...], sorted; window_count TITLE: how many; one_window
# TITLE: the one such window as [x, y, w, h], or windows=<n>; window_of
# TITLE FIELD...: those fields of the one such window from `clients -j`,
# as one JSON list, or windows=<n>.
windows_of() { hypr -j clients | python3 -c 'import json,sys; print(json.dumps(sorted(c["at"] + c["size"] for c in json.load(sys.stdin) if c["class"] == sys.argv[1] and c["title"] == sys.argv[2] and c["mapped"])))' "$shell_class" "$1"; }
window_count() { windows_of "$1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
one_window() { windows_of "$1" | python3 -c 'import json,sys; w=json.load(sys.stdin); print(json.dumps(w[0]) if len(w) == 1 else "windows=%d" % len(w))'; }
window_of() { local title="$1"; shift; hypr -j clients | python3 -c '
import json, sys
cs = [c for c in json.load(sys.stdin) if c["class"] == sys.argv[1] and c["title"] == sys.argv[2] and c["mapped"]]
print(json.dumps([cs[0][k] for k in sys.argv[3:]]) if len(cs) == 1 else "windows=%d" % len(cs))' "$shell_class" "$title" "$@"; }
# The focused window as [class, title], or [] for none.
active_window() { hypr -j activewindow | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d["class"], d["title"]] if d.get("address") else [], ensure_ascii=False))'; }
# surface_box SURFACE: the box of one drawn surface as [x, y, w, h]: a
# layer by its namespace, `vgs:<name>`, or an application window as
# `window:<title>`.
surface_box() {
  case "$1" in
    window:*) one_window "${1#window:}" ;;
    vgs:*) one_layer "$1" ;;
    *) echo "surface_box: refused: surface=$1 want=vgs:<name>|window:<title>" >&2; return 1 ;;
  esac
}
# at_centre SURFACE RECT_JSON: the layout position of the centre of a box
# given in the coordinates of SURFACE's window, a surface_box name, its
# position added: neither a layer the compositor centres nor a toplevel
# knows its place, so the probe answers boxes in window coordinates.
at_centre() {
  local box
  box="$(surface_box "$1")" || return 1
  python3 -c 'import json,sys; l=json.loads(sys.argv[1]); r=json.loads(sys.argv[2]); print(int(l[0] + r[0] + r[2] / 2), int(l[1] + r[1] + r[3] / 2))' "$box" "$2"
}
# pixel X Y: the colour the nested output shows at layout position (X, Y)
# as rrggbb, through grim given the nested socket alone (shot.sh).
pixel() {
  local socket
  socket="$(shot_socket "$rt_dir" "$nested_socket" "$host_socket")" || return 1
  shot_pixel "$socket" "$rt_dir" "$1" "$2"
}
# click_in SURFACE HOST_KEY ID TYPE TEXT: one click on the centre of the
# first shown item of TYPE whose text or label is TEXT in that instance,
# drawn in SURFACE, a surface_box name.
click_in() {
  local rect x y
  rect="$(ipc smoke windowGeometry "$2" "$3" "$4" "$5")" || return 1
  [[ $rect == \[* ]] || { echo "click_in: no $4 $5: $rect" >&2; return 1; }
  read -r x y < <(at_centre "$1" "$rect") || return 1
  click "$x" "$y"
}
# click_scoped_in SURFACE HOST_KEY ID SCOPE_TYPE SCOPE_TEXT TYPE TEXT: the
# same for the item of TYPE reading TEXT inside the first shown SCOPE_TYPE
# that draws SCOPE_TEXT, such as one row's button among rows that each
# draw one with the same text. The pointer moves there a pixel off first:
# a surface mapped since the last press takes no click until the pointer
# moves (validation-smoke.md).
click_scoped_in() {
  local rect x y
  rect="$(ipc smoke scopedWindowGeometry "$2" "$3" "$4" "$5" "$6" "$7")" || return 1
  [[ $rect == \[* ]] || { echo "click_scoped_in: no $6 $7 in $4 $5: $rect" >&2; return 1; }
  read -r x y < <(at_centre "$1" "$rect") || return 1
  hover "$((x + 1))" "$y" || return 1
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

# Floating TUIs reach a stand-in xdg-terminal-exec in the shell's own PATH
# directory, which terminal_stand_in writes: it records the argv it was
# handed in $tui_record, maps the toplevel helper with the app-id and title
# it was handed as the window, and runs the real presenter with no terminal
# behind it, so the presenter writes its exit records and no terminal
# starts. The argv is written whole and moved into place, so a row never
# reads half a record. The window lives as long as the presenter. The
# presenter runs a plugin's script as it is and any other command as
# `true`, so no core command, such as the sudo grant or a plugin update,
# runs in the sandbox. While the file $sandbox/core-hold exists, a core
# command's `true` waits for it to go, polled every 0.05 s, so a row can
# read the shell while a core run is live. The wait ends after 2400 polls,
# 120 s, whatever the file does: a ceiling well past the longest held
# section's polls, not a measurement, so a run interrupted before its row
# removes the file leaves no presenter behind, since bin/vgsh-tui starts
# the stand-in outside the harness's groups. Writing it again changes
# nothing.
tui_record="$sandbox/tui-argv"
tui_self="$(readlink -f -- "$repo/bin/vgsh-tui")"
terminal_stand_in() {
  cat >"$shim/xdg-terminal-exec" <<EOF
#!/usr/bin/env bash
: >"$tui_record.next"
for a; do printf '%s\n' "\$a" >>"$tui_record.next"; done
mv -f -- "$tui_record.next" "$tui_record"
app_id="" title=""
while [[ \$# -gt 0 && \$1 != -- ]]; do
  case "\$1" in
    --app-id=*) app_id="\${1#*=}" ;;
    --title=*) title="\${1#*=}" ;;
  esac
  shift
done
shift
presenter=() fixture=no
while [[ \$# -gt 0 && \$1 != -- ]]; do
  [[ \$1 == --plugin ]] && fixture=yes
  presenter+=("\$1")
  shift
done
if [[ \$fixture != yes ]]; then
  if [[ -e "$sandbox/core-hold" ]]; then set -- -- sh -c 'n=0; while [ -e "\$1" ] && [ "\$n" -lt 2400 ]; do sleep 0.05; n=\$((n + 1)); done' sh "$sandbox/core-hold"; else set -- -- true; fi
fi
"$sandbox/toplevel" "\$app_id" "\$title" >/dev/null 2>&1 &
window=\$!
"\${presenter[@]}" "\$@" </dev/null >/dev/null 2>&1
kill "\$window" 2>/dev/null
wait "\$window"
EOF
  chmod 755 "$shim/xdg-terminal-exec"
}
# Hold a core TUI stand-in open while a row checks a busy key.
hold_core() { : >"$sandbox/core-hold"; }
release_core() { rm -f -- "$sandbox/core-hold"; }
# The record, with the run id the core chose as RUN, and a list of words, as
# one JSON line each.
recorded() { python3 -c '
import json, os, sys
if not os.path.exists(sys.argv[1]):
    print("absent"); sys.exit()
words = open(sys.argv[1]).read().split("\n")[:-1]
for i in range(len(words) - 1):
    if words[i] == "--run": words[i + 1] = "RUN"
print(json.dumps(words))' "$tui_record"; }
words() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }
# The key the recorded run carries, then the recorded argv from the script
# on, as JSON; `absent` before a record exists, and `partial` for a record
# with no `--record` or no `--` after it.
recorded_tail() { recorded | py_reply 'import json,sys
w=json.load(sys.stdin)
at=w.index("--record") if "--record" in w else -1
if at < 0 or at + 1 >= len(w) or "--" not in w[at + 1:]: print("partial"); sys.exit()
print(json.dumps([w[at + 1]] + w[w.index("--", at) + 1:]))'; }
forget_record() { rm -f -- "${tui_record:?}"; }
# A core TUI's command is the core's bin/ beside the shell directory,
# whatever the shell's PATH holds. core_words: the words the terminal is
# handed for core TUI KEY titled TITLE in the window of APP_ID, running
# the core's vgsh with ARGS, as recorded reads them.
core_vgsh="$(dirname -- "$(dirname -- "$tui_self")")/shell/../bin/vgsh"
core_words() { # KEY TITLE APP_ID ARGS...
  local key="$1" title="$2" app="$3"
  shift 3
  words "--app-id=$app" "--title=VGS · $title" -- "$tui_self" present --presentation full \
    --record "$key" --run RUN --record-dir "$rt_dir/vgs/tui" --app-id "$app" --window-title "VGS · $title" -- "$core_vgsh" "$@"
}
# The requirement notice the core shows as [plugin, commands, required,
# installing], or null.
notice_shown() { ipc shell lent | python3 -c 'import json,sys; s=json.load(sys.stdin)["notices"]["shown"]; print(json.dumps(None if s is None else [s["plugin"], s["commands"], s["required"], s["installing"]]))'; }
# After terminal_stand_in: the launcher state present, so the next request
# launches. The core probes when it starts, before any row wrote the
# stand-in, so a host without xdg-terminal-exec leaves the state missing;
# one request then answers launcher-missing, starts no launcher and probes
# again, now against the stand-in. LABEL leads each row's name.
terminal_ready() { # LABEL
  expect_poll "$1: the launcher probe has answered" false lent tui.probing
  if [[ "$(lent tui.launcher)" == '"missing"' ]]; then
    expect "$1: a request before the stand-in's probe answers launcher-missing" "refused: tui=core/doctor reason=launcher-missing" ipc shell openTui core/doctor
  fi
  expect_poll "$1: the launcher state is present" '"present"' lent tui.launcher
  expect_poll "$1: no probe is left running" false lent tui.probing
}
# `idle` once the core saw the last run of KEY end and holds no launch of
# it, so the next request for it is not refused busy.
key_idle() { ipc shell lent | python3 -c '
import json, sys
t, key = json.load(sys.stdin)["tui"], sys.argv[1]
r = t["runs"].get(key)
print("idle" if key not in t["pending"] and (r is None or r["running"] is None) else "busy")' "$1"; }

# expect_within LABEL READING WANT CEILING_MS CMD...: as expect_poll, but
# bounded by CEILING_MS of wall time from the call, for a state the core
# reports at the end of a chain whose ceiling was measured. CMD is polled
# every 0.2 s, the last wait cut to the time left, and the time from the
# call to the end of the first read that answers WANT is printed as
# latency_<READING>_ms, a reading that carries one poll interval and one
# CMD. A WANT read after the ceiling fails like none, and a traceback
# fails at once, as in expect_poll. Returns 0 either way, since a row runs
# under set -e.
expect_within() { # LABEL READING WANT CEILING_MS CMD...
  local label="$1" reading="$2" want="$3" ceiling_ms="$4" got="" start elapsed matched pause err="$sandbox/reader-$BASHPID.stderr"
  shift 4
  start="$(now_ms)"
  while :; do
    matched=false
    if got="$("$@" 2>"$err")" && [[ $got == "$want" ]]; then matched=true; fi
    elapsed=$(( $(now_ms) - start ))
    reader_stderr "$label" "$err" || return 0
    if [[ $matched == true && $elapsed -le $ceiling_ms ]]; then
      printf '  latency_%s_ms=%d ceiling_ms=%d\n' "$reading" "$elapsed" "$ceiling_ms"
      ok "$label"
      return 0
    fi
    [[ $matched == false && $elapsed -lt $ceiling_ms ]] || break
    pause=$(( ceiling_ms - elapsed < 200 ? ceiling_ms - elapsed : 200 ))
    sleep "$((pause / 1000)).$(printf '%03d' $((pause % 1000)))"
  done
  if [[ $matched == true ]]; then
    printf '  latency_%s_ms=%d ceiling_ms=%d\n' "$reading" "$elapsed" "$ceiling_ms"
    fail "$label: got $want after $elapsed ms, past the ceiling of $ceiling_ms ms"
  else
    printf '  latency_%s_ms=over ceiling_ms=%d\n' "$reading" "$ceiling_ms"
    fail "$label: got $got want $want after $elapsed ms, ceiling $ceiling_ms ms"
  fi
}
# A run ends in the core through one chain: the presenter exits and moves
# its ended record into $rt_dir/vgs/tui, the core's FolderListModel lists
# the new name, a FileView reads the file, and TuiRunner's runs move, which
# key_idle reads. expect_run_end LABEL KEY waits for KEY to read `idle`
# within run_end_ceiling_ms and prints each reading as
# latency_run_end_ms. A key still busy at the ceiling fails, and the row
# prints what the record directory holds for the key beside the core's
# view, so a run whose ended record is on disk while the core still reports
# it running reads as a listing the core missed, not a slow presenter.
# scripts/smoke/rows/tui.sh holds the controls: a run that never ends
# fails the row at the ceiling, and so does an idle read that ends past it.
# The ceiling is twice the highest of 108 readings,
# 248 ms, from six runs of scripts/qml-smoke.sh on the owner's machine
# (host cachy, AMD Ryzen 9 9950X) on 2026-09-29 at host load 4 to 9; the
# median reading was 22 ms, a first poll that found the run already ended.
run_end_ceiling_ms=500
expect_run_end() { # LABEL KEY
  local failed_before="$failures"
  expect_within "$1" run_end idle "$run_end_ceiling_ms" key_idle "$2"
  [[ $failures -eq $failed_before ]] || run_end_records "$2"
}
run_end_records() { # KEY
  local core
  if ! core="$(ipc shell lent)"; then
    printf '        the lending record is unreadable\n'
    return 0
  fi
  python3 -c '
import json, os, sys
key, folder, tui = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])["tui"]
stem = key.replace("/", "@")
files = sorted(n for n in os.listdir(folder) if n.startswith(stem + "@"))
slot = tui["runs"].get(key)
running = None if slot is None else slot["running"]
ended = None if slot is None or slot["ended"] is None else slot["ended"]["run"]
print("        records on disk: %s" % (", ".join(files) or "none"))
print("        core: pending=%s running=%s ended=%s" % (key in tui["pending"], running, ended))
if running is not None and "%s@%s.ended.json" % (stem, running) in files:
    print("        run %s has its ended record on disk while the core reports it running: the listing missed it" % running)
' "$1" "$rt_dir/vgs/tui" "$core" || printf '        the record directory is unreadable: %s\n' "$rt_dir/vgs/tui"
}

smoke_finish() {
if [[ $failures -gt 0 ]]; then
  echo "--- instance log tail"; tail -n 40 "${instance_log:-$sandbox/qs.log}" 2>/dev/null || true
  # Hyprland ends its log without a newline; sed adds the one the verdict
  # line after it needs.
  echo "--- nested compositor log tail"; tail -n 40 "$rt_dir"/hypr/*/hyprland.log 2>/dev/null | sed '$a\' || true
fi
local status=0
smoke_verdict "$failures" "$behaviour_failures" "$stalled_render" "$mode_resets" "$rt_dir"/hypr/*/hyprland.log || status=$?
[[ $status -eq 0 ]] || exit "$status"
}
