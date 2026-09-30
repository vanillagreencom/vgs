# Sourced by qml-smoke.sh; owns the sandbox and shared readers.
set -euo pipefail
source "$repo/scripts/smoke/verdict.sh"
source "$repo/scripts/smoke/tree.sh"
source "$repo/scripts/smoke/shot.sh"
source "$repo/scripts/smoke/app-window.sh"
source "$repo/bin/lib/ipc-reply.sh"
missing=()
# fd, fzf and file are the launcher file search helper's, which rows/launcher.sh runs;
# grim reads the pixels app-window.sh checks.
for tool in Hyprland qs hyprctl python3 node flock setpriv setsid git dbus-daemon gdbus cc wayland-scanner pkg-config wtype fd fzf file grim; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
# ImageMagick, `magick` or `convert`, converts the Slack custom emoji the
# notifications row and the shots' Slack scene draw; imagemagick is the
# one found, which the shots' theme-browser scene resizes a preview with.
imagemagick="$(command -v magick 2>/dev/null || command -v convert 2>/dev/null)" || missing+=("magick")
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
# geometry and hold_check run a row under that class (row_class in
# scripts/smoke/verdict.sh).
geometry() { local previous="$row_class"; row_class=geometry; "$@"; row_class="$previous"; }
hold_check() { local previous="$row_class"; row_class=hold; "$@"; row_class="$previous"; }
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
# Qt caches a directory's file names when it first loads from it. Prepare
# every layer mask copy before any host or earlier control reads Hosts.
text = (source / "shell/Hosts/OverlaySurface.qml").read_text()
for name, old, new in (
    ("NoLeft", "model: surface.inputItems", "model: surface.inputItems.slice(1)"),
    ("NoRight", "model: surface.inputItems", "model: surface.inputItems.slice(0, 1)"),
    ("NoMask", "mask: inputAll ? null : inputRegion", "mask: inputAll ? null : null"),
):
    assert text.count(old) == 1, f"{name}: mutation must match once"
    changed = text.replace(old, new)
    assert changed != text
    (target / f"shell/Hosts/OverlaySurface{name}.qml").write_text(changed)
# The component module's directory is cached before the frame row runs.
text = (source / "shell/Ui/feedback/VoiceOrb.qml").read_text()
changed = text
for old, new in (
    ("Theme.motion.scale > 0 && Theme.voiceOrb.period > 0", "true"),
    (" / Theme.voiceOrb.period", " / Math.max(1, Theme.voiceOrb.period)"),
):
    assert changed.count(old) == 1, "orb frame control: mutation must match once"
    changed = changed.replace(old, new)
assert changed != text
(target / "shell/Ui/feedback/VoiceOrbFrameControl.qml").write_text(changed)
PY
tree_smoke_observer "$repo" "$sandbox/repo"
[[ -z ${source_tree:-} ]] || tree_overlay_helpers "$source_tree" "$sandbox/repo"
repo="$sandbox/repo"
# The one authentication log: every sentinel below appends `<name> <argv>`
# to it, and rows/auth-sentinel.sh, the last row, requires it empty.
auth_log="$sandbox/auth-sentinel.calls"
# bin/vgsh-browser-policy sets its own PATH to the system directories and
# runs sudo from there, so no PATH sentinel can stand before its sudo. The
# copy's writer is a sentinel for the whole run: a plugin TUI the stand-in
# terminal runs for real, such as vgs.themes's browser-policy, reaches it
# and never the host's sudo. A row that presses that step swaps in its own
# stand-in and puts the sentinel back.
if [[ -e $repo/bin/vgsh-browser-policy ]]; then
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "vgsh-browser-policy $*" >>%q\nexit 1\n' "$auth_log" >"$repo/bin/vgsh-browser-policy"
  chmod 755 "$repo/bin/vgsh-browser-policy"
fi

cat >"$home/.config/hypr/hyprland.lua" <<'LUA'
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })
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
# mode_hold_file: the monitor rule a row holds, which hold_mode writes and
# release_mode removes. The configuration loads it after its default rule,
# on every load, so a reload applies the held rule again.
mode_hold_file="$rt_dir/monitor-hold.lua"
printf 'local hold_file = "%s"\nlocal hold = io.open(hold_file)\nif hold then hold:close(); dofile(hold_file) end\n' "$mode_hold_file" >>"$home/.config/hypr/hyprland.lua"
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
# The Jarvis child always uses J09, including default-set startup. Only the
# disposable Service copy names test infrastructure.
"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" "$source_repo" "$repo" "$sandbox/jarvis-world"
if bash "$source_repo/scripts/lib/jarvis-env.sh" "$sandbox/jarvis-world/standins" -- true; then
  :
else
  jarvis_isolation_status=$?
  if [[ $jarvis_isolation_status == 77 ]]; then
    printf 'qml-smoke: status=not-measured reason=jarvis-isolation\n'
  else
    printf 'qml-smoke: jarvis-isolation=failed exit=%s\n' "$jarvis_isolation_status"
  fi
  exit "$jarvis_isolation_status"
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
# crontab chooses the table it reads and writes by the caller's user, not
# by HOME, so a crontab the shell reached would be the user's own. The
# stand-in keeps the sandbox's table in $sandbox/crontab.table and logs each
# argv, one line of words, in $sandbox/crontab.calls; `crontab -l` without a
# table answers as cronie does. It stays for the whole run, so no row and no
# plugin the default set enables reaches the host's crontab.
cat >"$shim/crontab" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$sandbox/crontab.calls"
case "\${1:-}" in
  -l) if [[ -f "$sandbox/crontab.table" ]]; then cat -- "$sandbox/crontab.table"; else echo "no crontab for \$(id -un)" >&2; exit 1; fi ;;
  -) cat >"$sandbox/crontab.table" ;;
  *) exit 2 ;;
esac
EOF
chmod 755 "$shim/crontab"
# Authentication sentinels. No row may start a PAM conversation, a polkit
# authentication, a sudo, a keyring unlock or any other authentication
# against the host user: the nested sandbox shares the host's PAM, polkit
# and faillock. Every command that asks for one stands in the shell's own
# PATH directory for the whole run, ahead of the host's: sudo, doas, run0,
# pkexec and su log their argv to $auth_log and exit 1, running nothing;
# loginctl answers `show-user` with lingering off, the read the automations
# engine makes, and logs any other verb, such as enable-linger, which
# polkit may ask about; secret-tool answers `search` with nothing stored
# and `lookup` with no secret, the reads a background probe makes without
# unlocking, and logs any other verb, a store, a clear or an unlock. A row
# that needs one of them stands its own stub over the sentinel;
# rows/auth-sentinel.sh reads the log empty at the end of the run.
for sentinel in sudo doas run0 pkexec su; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >>%q\nexit 1\n' "$sentinel" "$auth_log" >"$shim/$sentinel"
  chmod 755 "$shim/$sentinel"
done
cat >"$shim/loginctl" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == show-user ]]; then echo no; exit 0; fi
printf '%s\n' "loginctl \$*" >>"$auth_log"
exit 1
EOF
cat >"$shim/secret-tool" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  search) exit 0 ;;
  lookup) exit 1 ;;
esac
printf '%s\n' "secret-tool \$*" >>"$auth_log"
exit 1
EOF
chmod 755 "$shim/loginctl" "$shim/secret-tool"
auth_sentinels=(sudo doas run0 pkexec su loginctl secret-tool)
# shell_resolves NAME: the file NAME resolves to on the PATH every sandbox
# shell starts with, and so every process it starts, a TUI included.
shell_resolves() { PATH="$shell_start_path" command -v -- "$1" || echo none; }
# The PATH every sandbox shell starts with: the shell's stand-in directory,
# then node's, then the host's. A row that stands in more commands puts
# its own directory ahead of it. shell_start_words are the environment
# words start_shell gives every shell over shell_env's.
shell_start_path="$shim:$(dirname -- "$node_bin"):$PATH"
shell_start_words=(PATH="$shell_start_path" VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR="$shim")

# The test helpers, built from the repository into the sandbox, each with
# the client code wayland-scanner generates from the one protocol file
# vendored beside it. Each is only ever run with the nested socket in its
# environment. click: one click through the nested compositor's virtual
# pointer protocol. toplevel: one xdg toplevel with a given app-id, so a
# row reads back how the nested compositor places a window of that class.
# lock-client: a second session-lock client, which rows/lock.sh starts and
# stops by pid in place of another locker; it runs no authentication.
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
build_helper lock-client lock-client "$repo/scripts/smoke/lock/lock-client.c" "$repo/scripts/smoke/lock/ext-session-lock-v1.xml"

# The authentication helpers under a process tree: pam_unix's unix_chkpwd,
# polkit's polkit-agent-helper-1 (its name cut to 15 bytes in /proc), sudo
# and faillock. No row may authenticate the host's user, so the lock and
# polkit rows read none. `auth_helpers PID` prints the ones running under
# PID now, one `name pid` per line, `none` for none. `auth_watch_start LOG`
# spawns a watcher that scans the harness's own tree, which holds every
# shell it starts, every 50 ms and appends each helper it sees once to LOG,
# so a helper that ran and exited between two reads of a row is on record;
# one shorter than a scan can slip past, which the plugins' own counts
# cover. The watcher's pid is in auth_watch_pid.
auth_scan_program='import os, sys, time
names = {"unix_chkpwd", "polkit-agent-he", "sudo", "faillock"}
def scan(root):
    children = {}
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            stat = open(f"/proc/{pid}/stat").read()
        except OSError:
            continue
        comm, rest = stat[stat.index("(") + 1:stat.rindex(")")], stat[stat.rindex(")") + 2:].split()
        children.setdefault(rest[1], []).append((pid, comm))
    found, todo = [], [root]
    while todo:
        for pid, comm in children.get(todo.pop(), []):
            if comm in names:
                found.append(f"{comm} {pid}")
            todo.append(pid)
    return found
if sys.argv[2] == "once":
    found = scan(sys.argv[1])
    print("\n".join(found) if found else "none")
else:
    seen = set()
    while True:
        for line in scan(sys.argv[1]):
            if line not in seen:
                seen.add(line)
                print(line, flush=True)
        time.sleep(0.05)'
auth_helpers() { python3 -c "$auth_scan_program" "$1" once; }
auth_watch_pid=""
auth_watch_start() { # LOG
  spawn "$1" python3 -c "$auth_scan_program" "$$" watch
  auth_watch_pid="$spawn_pid"
}
# Whether PID is in the harness's own tree, which the watcher scans.
in_harness_tree() { # PID
  local pid="$1"
  while [[ $pid =~ ^[0-9]+$ && $pid -gt 1 ]]; do
    [[ $pid == "$$" ]] && { echo yes; return; }
    pid="$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f2)" || break
  done
  echo no
}

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
# The nested compositor carries the words start_shell gives a shell and
# the sandbox's buses, so a shell `vgsh restart` relaunches through its
# dispatch finds the same stand-ins and reaches no bus of the user's
# (rows/start-order.sh). It sets the Wayland and Hyprland variables of its
# children itself.
spawn "$sandbox/hyprland.log" "${sandbox_env[@]}" "${shell_start_words[@]}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$rt_dir/bus" DBUS_SYSTEM_BUS_ADDRESS="unix:path=$rt_dir/system-bus" \
  WAYLAND_DISPLAY="$host_socket" Hyprland --config "$home/.config/hypr/hyprland.lua"
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
# rows/devtools.sh enables it over stub commands. vgs.automations starts
# disabled for the same reason, and rows/automations.sh enables it over
# stand-in systemctl, systemd-run, notify-send and loginctl. vgs.polkit
# starts disabled, since polkit is exclusive and the capability rows'
# fixture holds it; rows/polkit.sh enables it and disables it again.
# vgs.lock starts disabled for the launcher's reason, and its idle watch
# would lock the session under the rows after five minutes; rows/lock.sh
# enables it and disables it again.
# vgs.themes stays enabled, its background built on every
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

# automations_stand_ins STUB: vgs.automations's host commands in the
# shell's own PATH directory, each logging its argv as one JSON line in
# STUB/<name>.calls: a systemctl that answers every verb and fails
# daemon-reload while STUB/fail-reload exists, a systemd-run that runs the
# argv after `--` with its --setenv words exported, a notify-send that
# prints an id, and a loginctl that answers `no`. A shim file one of them
# covers is kept under STUB/saved until automations_stand_ins_restore STUB
# puts it back and removes the stand-ins. rows/automations.sh and the
# Settings scene of scripts/sandbox-shots.sh enable the plugin over them.
automations_stand_in_names=(systemctl systemd-run notify-send loginctl)
automations_stand_ins() { # STUB
  local stub="$1" name
  mkdir -p -- "$stub/saved"
  for name in "${automations_stand_in_names[@]}"; do
    if [[ -e $shim/$name ]]; then mv -- "$shim/$name" "$stub/saved/$name"; fi
  done
  cat >"$shim/systemctl" <<EOF
#!/usr/bin/env bash
python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "\$@" >>"$stub/systemctl.calls"
if [[ \${2:-} == daemon-reload && -e "$stub/fail-reload" ]]; then echo "Failed to reload daemon: stand-in" >&2; exit 1; fi
exit 0
EOF
  cat >"$shim/systemd-run" <<EOF
#!/usr/bin/env bash
python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "\$@" >>"$stub/systemd-run.calls"
while [[ \$# -gt 0 && \$1 != -- ]]; do
  case "\$1" in --setenv=*) export "\${1#--setenv=}" ;; esac
  shift
done
shift
"\$@" >>"$stub/systemd-run.out" 2>&1 || true
EOF
  cat >"$shim/notify-send" <<EOF
#!/usr/bin/env bash
python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "\$@" >>"$stub/notify-send.calls"
echo 7
EOF
  printf '#!/usr/bin/env bash\necho no\n' >"$shim/loginctl"
  chmod 755 "$shim/systemctl" "$shim/systemd-run" "$shim/notify-send" "$shim/loginctl"
}
automations_stand_ins_restore() { # STUB
  local name
  for name in "${automations_stand_in_names[@]}"; do
    if [[ -e $1/saved/$name ]]; then mv -f -- "$1/saved/$name" "$shim/$name"; else rm -f -- "$shim/$name"; fi
  done
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
# `store` and `clear`, as the core's SecretWriter runs them for the
# Settings page's Connect and Disconnect (D059), set the account's state to
# `present` and `absent`, append their argv to $shim/secret-tool.calls, and
# a store keeps its stdin, the secret, byte for byte in
# $shim/secret-tool.stdin.<account>.
# slack_states STATES: the states file rewritten from STATES, lines joined
# by `;`. secret_tool_stand_in STATES: the stand-in written, with STATES.
slack_states() { tr ';' '\n' <<<"$1" >"$shim/secret-tool.states"; }
secret_tool_stand_in() { # STATES
  slack_states "$1"
  cat >"$shim/secret-tool" <<SH
#!/usr/bin/env bash
states="$shim/secret-tool.states"
set_state() { { grep -v -F -x -e "\$1 present" -e "\$1 absent" -e "\$1 locked" "\$states" || true; printf '%s %s\\n' "\$1" "\$2"; } >"\$states.next" && mv -f -- "\$states.next" "\$states"; }
if [[ \${1:-} == store ]]; then
  [[ \${2:-} == --label=* && \${3:-} == service && \${4:-} == vgs-notifications && \${5:-} == account && \$# -eq 6 ]] || exit 1
  printf '%s\\n' "\$*" >>"$shim/secret-tool.calls"
  cat >"$shim/secret-tool.stdin.\$6"
  set_state "\$6" present
  exit 0
fi
if [[ \${1:-} == clear ]]; then
  [[ \${2:-} == service && \${3:-} == vgs-notifications && \${4:-} == account && \$# -eq 5 ]] || exit 1
  printf '%s\\n' "\$*" >>"$shim/secret-tool.calls"
  set_state "\$5" absent
  exit 0
fi
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
{ "version": 1, "bar": { "id": "vgs.bar", "layout": { "left": [], "center": [{ "id": "acme.tick", "format": "ddd d MMM  HH:mm" }], "right": [] } }, "disabledPlugins": ["vgs.launcher", "vgs.notifications", "vgs.settings", "vgs.updates", "vgs.agent-warden", "vgs.devtools", "vgs.automations", "vgs.polkit", "vgs.lock", "vgs.jarvis"] }
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
right_click() { "${shell_env[@]}" "$sandbox/click" "$1" "$2" "$mon_w" "$mon_h" right >/dev/null; }
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
# control_box LOOKUP: a control's box in layout coordinates as
# [x, y, w, h], or absent; control_hovered LOOKUP: true, false or absent
# for whether it reports the pointer over it. LOOKUP is HOST_KEY ID TYPE
# TEXT for the first visible, enabled control TYPE reading TEXT under a
# built instance, or NAMESPACE ID TYPE PROPERTY VALUE, NAMESPACE a
# layer's vgs:<name>, for the first visible, enabled item TYPE whose
# PROPERTY reads VALUE in plugin ID's copies of that layer. The probe
# answers a layer item's box in its window, so the layer's position from
# the compositor is added.
control_box() {
  local rect layer
  if [[ $1 != vgs:* ]]; then ipc smoke itemGeometry "$1" "$2" "$3" "$4"; return; fi
  rect="$(ipc smoke layerItemGeometry "$2" "$3" "$4" "$5")" || return 1
  if [[ $rect == absent ]]; then echo absent; return; fi
  layer="$(surface_box "$1")" || return 1
  python3 -c 'import json,sys; l=json.loads(sys.argv[1]); r=json.loads(sys.argv[2]); print(json.dumps([l[0] + r[0], l[1] + r[1], r[2], r[3]]))' "$layer" "$rect"
}
control_hovered() {
  if [[ $1 == vgs:* ]]; then ipc smoke layerItemHovered "$2" "$3" "$4" "$5"
  else ipc smoke itemHovered "$1" "$2" "$3" "$4"
  fi
}
# point_item LOOKUP [DX DY]: the pointer left resting on a control_box
# LOOKUP, at its centre or at (DX, DY) from its top-left corner, `-` for
# the centre on that axis, once the control reports the pointer over that
# point; prints that point as `X Y`. The compositor routes the pointer by
# where it has placed the surface, which can trail the layout the probe
# reads after the surface resizes, and a list that grows after it opens or
# a card that slides in moves the control, so a box read once goes stale.
# Every 100 ms, for up to 5 s, the helper reads the control's box again,
# moves the pointer to its point, one pixel apart each time so each move
# is a motion, and reads whether the control reports the pointer. It stops
# after two such readings in a row at one box, so a reading taken before
# the move reached the shell never decides it, and reads the box once more
# before it returns: a box that moved starts the count again. Returns 1
# when the control is absent at the first reading or never reports the
# pointer; a control absent at a later reading is being laid out again,
# and the count starts again. notifications.sh rests the pointer through
# it on the cards whose hover pauses a clock or shows actions: the held
# toast, the actionable toast, the hover geometry card and the restored
# toast.
point_item() { # LOOKUP [DX DY]
  local n=4 lookup rect seen="" x="" y="" px hovered held=0 i
  [[ $1 == vgs:* ]] && n=5
  if (( $# != n && $# != n + 2 )); then echo "point_item: refused: arguments=$# lookup=$n" >&2; return 1; fi
  lookup=("${@:1:n}")
  shift "$n"
  for i in $(seq 1 50); do
    rect="$(control_box "${lookup[@]}")" || return 1
    if [[ $rect == absent ]]; then
      [[ $i -gt 1 ]] || return 1
      held=0; seen=""; sleep 0.1; continue
    fi
    if [[ $rect != "$seen" ]]; then
      held=0; seen="$rect"
      read -r x y < <(python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); dx,dy=sys.argv[2:]; print(int(x + (w / 2 if dx == "-" else float(dx))), int(y + (h / 2 if dy == "-" else float(dy))))' "$rect" "${1:--}" "${2:--}") || return 1
    fi
    px=$((x + i % 2))
    hover "$px" "$y" || return 1
    hovered="$(control_hovered "${lookup[@]}")" || return 1
    if [[ $hovered == true ]]; then held=$((held + 1)); else held=0; fi
    if [[ $held -ge 2 && $(control_box "${lookup[@]}") == "$seen" ]]; then printf '%s %s\n' "$px" "$y"; return; fi
    sleep 0.1
  done
  return 1
}
# click_item LOOKUP [DX DY]: point_item, then one click at the point it
# settled on; returns 1, with no click, when point_item does. The rows that
# click through it: agent-warden.sh, updates.sh, themes.sh (its click_row
# and click_button, and the helper's controls) and notifications.sh (the
# Reply pill, a card's default action, Mark read and Clear history).
click_item() { # LOOKUP [DX DY]
  local at x y
  at="$(point_item "$@")" || return 1
  read -r x y <<<"$at" || return 1
  click "$x" "$y"
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

# Probe.qml uses the same bound before it pages a reply.
ipc_reply_chars=32768
ipc_oversize_log="$sandbox/ipc-oversize.log"
ipc_last_reply=""

# ipc_call_last VGSH TARGET FUNCTION [ARG...]: run one IPC call and keep
# the last stdout line in ipc_last_reply.
ipc_call_last() {
  local vgsh="$1" out status
  shift
  ipc_last_reply=""
  out="$("${shell_env[@]}" "$vgsh" ipc call "$@" 2>>"$sandbox/ipc.log")" || status=$?
  status="${status:-0}"
  ipc_last_reply="${out##*$'\n'}"
  return "$status"
}

# bin/lib/ipc-reply.sh, the judge bin/vgsh uses, classifies Quickshell
# 0.3.1 client failures. A judge that cannot classify fails the row and
# reads as a failed call.
ipc_failed() { # TARGET FUNCTION LINE
  local target="$1" fn="$2" line="$3" status=0
  vgs_ipc_reply_failure "$line" >/dev/null || status=$?
  case "$status" in
    0) ;;
    1) return 1 ;;
    *) fail "ipc: $target $fn: bin/lib/ipc-reply.sh exited $status" ;;
  esac
  vgs_ipc_strip_into "$line"
  printf 'ipc: %s %s: %s\n' "$target" "$fn" "$vgs_ipc_stripped" >>"$sandbox/ipc.log"
  return 0
}

ipc_page_failed() { # TEXT
  printf 'ipc: smoke page: %s\n' "$1" >>"$sandbox/ipc.log"
  printf 'ipc-failed\n'
  return 1
}

# ipc_pages VGSH ID: fetch all pages for a paged smoke reply and print the
# concatenated document, or ipc-failed.
ipc_pages() {
  local vgsh="$1" id="$2" index=0 pages="" reply count slice text="" status
  while :; do
    status=0
    ipc_call_last "$vgsh" smoke page "$id" "$index" || status=$?
    if ipc_failed smoke page "$ipc_last_reply"; then
      printf 'ipc-failed\n'
      return 1
    fi
    if ((status)); then
      ipc_page_failed "status=$status reply=${ipc_last_reply:-}"
      return 1
    fi
    reply="$ipc_last_reply"
    if [[ $reply =~ ^([0-9]+)[[:space:]](.*)$ ]]; then
      count="${BASH_REMATCH[1]}"
      slice="${BASH_REMATCH[2]}"
    else
      ipc_page_failed "bad-header reply=$reply"
      return 1
    fi
    if [[ -z $pages ]]; then
      pages="$count"
      if [[ ! $pages =~ ^[1-9][0-9]*$ ]]; then ipc_page_failed "bad-count reply=$reply"; return 1; fi
    elif [[ $count != "$pages" ]]; then
      ipc_page_failed "count-changed first=$pages reply=$reply"
      return 1
    fi
    text+="$slice"
    index=$((index + 1))
    [[ $index -ge $pages ]] && break
  done
  printf '%s\n' "$text"
}

# ipc_via VGSH TARGET FUNCTION [ARG...]: run the smoke IPC transport,
# classify client failure lines, reassemble smoke pages and record
# oversize replies.
ipc_via() {
  local vgsh="$1" target="$2" fn="$3" status=0 reply id
  shift 3
  ipc_call_last "$vgsh" "$target" "$fn" "$@" || status=$?
  if ipc_failed "$target" "$fn" "$ipc_last_reply"; then
    printf 'ipc-failed\n'
    return 1
  fi
  if ((status)); then
    [[ -n $ipc_last_reply ]] && printf '%s\n' "$ipc_last_reply"
    return "$status"
  fi
  reply="$ipc_last_reply"
  if [[ $target == smoke && $reply =~ ^paged=([0-9]+)$ ]]; then
    id="${BASH_REMATCH[1]}"
    ipc_pages "$vgsh" "$id"
    return
  fi
  if ((${#reply} > ipc_reply_chars)); then
    printf '%s %s chars=%d bound=%d\n' "$target" "$fn" "${#reply}" "$ipc_reply_chars" >>"$ipc_oversize_log"
  fi
  printf '%s\n' "$reply"
}

# qs can print log lines before a reply; ipc_via returns one whole reply,
# reassembles probe pages and answers ipc-failed for client failure lines.
ipc() { ipc_via "$repo/bin/vgsh" "$@"; }

ipc_oversize_check() { # ROW
  [[ -s $ipc_oversize_log ]] || return 0
  fail "$1: unpaged IPC replies exceeded $ipc_reply_chars chars"
  sed 's/^/        /' -- "$ipc_oversize_log"
  : >"$ipc_oversize_log"
}
# py_reply PROGRAM [ARG...]: python3 -c PROGRAM ARG... over the reply on
# stdin, or the reply itself when it is a state word such as `absent`,
# which the smoke probe answers in place of JSON while the instance,
# surface or item it reads is not built, `ipc-failed` when the transport
# saw a failed client reply, and `recorded` before the terminal stand-in
# writes its record, or a count word such as `areas=0` that an upstream
# reader answers. A poll over such a reply reads through this, so it
# retries on the word rather than raising on it. A word is lower-case
# letters joined by hyphens, with an optional `=N`; true, false and null
# are JSON and parsed. An empty reply is a failed read that answers the
# word `empty`. On a Python failure, py_reply prints an escaped prefix of
# the raw reply. Every row reader that parses JSON from its stdin runs
# through this: scripts/check-smoke-readers.py refuses one that python3
# runs itself, in the forms its header names.
py_reply() { # PROGRAM [ARG...]
  local reply status
  reply="$(cat)" || return
  if [[ -z $reply ]]; then
    echo empty
    return 1
  fi
  if [[ $reply =~ ^[a-z]+(-[a-z]+)*(=[0-9]+)?$ && $reply != true && $reply != false && $reply != null ]]; then
    printf '%s\n' "$reply"
    return 0
  fi
  if python3 -c "$1" "${@:2}" <<<"$reply"; then
    return 0
  else
    status=$?
  fi
  python3 - "$reply" <<'PY' >&2
import sys
print("py_reply: the reply was: " + repr(sys.argv[1][:200]))
PY
  return "$status"
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

# start_shell TREE LOG [BAR [NAME=VALUE...]]: start the runner of TREE, a
# product tree holding its own bin/vgsh, as the sandbox's shell, its
# output in LOG, and wait for it through the ipc function, which a row
# that starts another tree's runner redefines first. The NAME=VALUE words
# go to env after the harness's own, so a row's PATH wins over
# shell_start_path. Sets shell_pid, the runner's pid, which stop_shell
# signals, the first-bar reading, shell_qs_pid, the shell's pid, which a
# row addresses the shell by, and instance_log, and keeps TREE and LOG
# as shell_tree and shell_log for adopt_shell.
# It clears the last two first, so a failed start leaves no earlier
# shell's pid or log in their place. BAR `no-bar` takes no first-bar
# reading, for a start that maps no bar. Returns 1, with the row failed,
# when the shell does not answer ping within timeout_s, when TREE's
# `vgsh pid` names no qs process or when no instance log names that pid. The
# instance is found by pid among every instance in the sandbox's runtime
# dir, so an installed prefix, whose shell is not TREE/shell, is found as
# a checkout is.
#
# The first-bar reading is the latency from the runner's spawn to the first
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
# shell's pid comes from TREE's own `vgsh pid`, which reads the lock file,
# since the lock file names the shell under both runners a tree may hold:
# the current runner starts qs as its child and waits on it
# (docs/architecture/runtime.md § Process), so the shell's pid is its
# child's; a revision sandbox-shots.sh exports with --rev may hold a
# runner that execs qs in place, so the shell's pid is the runner's.
# spawn's setsid does not fork, as a background job is no process group
# leader, so the runner is spawn_pid itself.
start_shell() { # TREE LOG [BAR [NAME=VALUE...]]
  local tree="$1" log="$2" bar="${3:-bar}" start_cpu_some_us start_ms bar_cpu_some_us layers_text tenths
  shift $(( $# < 3 ? $# : 3 ))
  [[ $bar == bar || $bar == no-bar ]] || { fail "start_shell: refused: bar=$bar want=bar|no-bar"; return 1; }
  instance_log=""
  shell_qs_pid=""
  shell_tree="$tree"
  shell_log="$log"
  start_cpu_some_us="$(cpu_some_us)"
  start_ms="$(now_ms)"
  spawn "$log" "${shell_env[@]}" "${shell_start_words[@]}" "$@" "$tree/bin/vgsh" run
  shell_pid="$spawn_pid"
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
  shell_answers "$tree" "$log"
}
# shell_answers TREE LOG: the tail start_shell and adopt_shell share. It
# waits, every 200 ms for up to timeout_s, for the shell to answer ping
# through the ipc function while the runner shell_pid runs, then sets
# shell_qs_pid from TREE's `vgsh pid` and instance_log from the sandbox's
# instances. Returns 1, with the row failed, as start_shell describes.
shell_answers() { # TREE LOG
  local tree="$1" log="$2" pong up=false qs_pid comm="" instance_id
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
  if ! qs_pid="$("${shell_env[@]}" "$tree/bin/vgsh" pid 2>&1)" || [[ ! $qs_pid =~ ^[0-9]+$ ]] \
    || ! comm="$(cat -- "/proc/$qs_pid/comm" 2>/dev/null)" || [[ $comm != qs ]]; then
    fail "start_shell: $tree/bin/vgsh pid names no qs: pid=[${qs_pid//$'\n'/ }] comm=[${comm:-}]"
    return 1
  fi
  shell_qs_pid="$qs_pid"
  for _ in $(seq 1 50); do
    if instance_id="$("${shell_env[@]}" qs list --all -j 2>/dev/null | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin) if i["pid"]==int(sys.argv[1])][0]["id"])' "$shell_qs_pid" 2>/dev/null)"; then
      instance_log="$rt_dir/quickshell/by-id/$instance_id/log.log"
      break
    fi
    sleep 0.2
  done
  if [[ -n $instance_log && -f $instance_log ]]; then ok "the shell's instance log is at $instance_log"; else fail "instance log not found for pid $shell_qs_pid"; instance_log=""; return 1; fi
}
# relaunched_within KILLED BOUND_MS: `back` once the lock file names a live
# pid other than KILLED while the runner shell_pid runs, `runner-ended` once
# that runner has ended, `none` when neither happened within BOUND_MS. It
# reads every 50 ms. The runner empties the lock file before it waits to
# start a shell again (docs/architecture/runtime.md § Process), so a pid
# the file names after KILLED died is the new shell's.
relaunched_within() { # KILLED BOUND_MS
  local pid stat deadline=$(( $(now_ms) + $2 ))
  while :; do
    if ! stat="$(ps -o stat= -p "$shell_pid")" || [[ $stat == Z* ]]; then echo runner-ended; return; fi
    if IFS= read -r pid 2>/dev/null <"$rt_dir/vgsh.lock" && [[ $pid =~ ^[0-9]+$ && $pid != "$1" && -d /proc/$pid ]]; then echo back; return; fi
    (( $(now_ms) < deadline )) || { echo none; return; }
    sleep 0.05
  done
}
# adopt_shell KILLED: the shell the runner shell_pid started again after
# its shell KILLED died, taken up as start_shell takes up a new one: once
# relaunched_within reads it back within 20 s, shell_answers sets
# shell_qs_pid and instance_log from the tree and the log start_shell
# kept. adopt_ms is the time from the call to the shell answering ping.
# Returns 1, with the row failed, when no shell came back.
adopt_shell() { # KILLED
  local start_ms back
  start_ms="$(now_ms)"
  instance_log=""
  shell_qs_pid=""
  adopt_ms=""
  back="$(relaunched_within "$1" 20000)"
  [[ $back == back ]] || { fail "adopt_shell: no shell replaced pid $1: $back"; return 1; }
  shell_answers "$shell_tree" "$shell_log" || return 1
  adopt_ms=$(( $(now_ms) - start_ms ))
}
# copy_tree NAME: a copy of the tree at $sandbox/tree-NAME, with its own
# bin/ and shell/. edit_tree NAME FILE OLD NEW: in that copy, OLD in FILE,
# a path under it, replaced by NEW; returns 1, with the row failed, unless
# OLD occurs once and the file changed.
copy_tree() { # NAME
  local tree="$sandbox/tree-$1" dir file
  rm -rf -- "${tree:?}"
  mkdir -p -- "$tree"
  cp -R -- "$repo/shell" "$tree/shell"
  cp -R -- "$repo/bin" "$tree/bin"
  for dir in config themes; do ln -s -- "$repo/$dir" "$tree/$dir"; done
  for file in VERSION LICENSE README.md; do cp -- "$repo/$file" "$tree/$file"; done
}
edit_tree() { # NAME FILE OLD NEW
  local path="$sandbox/tree-$1/$2"
  cp -- "$path" "$path.orig"
  if python3 -c '
import sys
path, old, new = sys.argv[1:]
text = open(path).read()
if text.count(old) != 1:
    sys.exit("occurs %d times" % text.count(old))
open(path, "w").write(text.replace(old, new))' "$path" "$3" "$4" && ! cmp -s -- "$path" "$path.orig"; then
    ok "the $1 copy's edit applies once to $2"
  else
    fail "the $1 copy could not edit $2"
    return 1
  fi
}
# stop_shell: TERM to the runner start_shell started, which passes it to
# the shell, then a wait on the instance lock the runner holds, before a
# row starts another. The runner exits after the shell and holds the lock
# until then, and no process the shell starts holds it
# (docs/architecture/runtime.md § Process), so the lock frees when the
# shell has exited, whatever processes the shell left behind; the next
# `vgsh run` refuses until then. The bound is stop_lock_wait_s, the 10 s
# `vgsh restart` gives the same wait. On the bound the row fails, naming
# each process that holds the lock, and it returns 1 with the runner
# unreaped. Once the lock is free it reaps the runner and clears
# shell_pid, so a second stop signals no stale pid. rows/start-order.sh
# holds the controls.
stop_lock_wait_s=10
stop_shell() {
  local lock="$rt_dir/vgsh.lock"
  [[ -z $shell_pid ]] || kill -TERM "$shell_pid" 2>/dev/null || true
  if ! flock -w "$stop_lock_wait_s" "$lock" true; then
    fail "stop_shell: lock=$lock still held ${stop_lock_wait_s}s after the TERM to pid ${shell_pid:-none}"
    lock_holders "$lock"
    return 1
  fi
  [[ -z $shell_pid ]] || wait "$shell_pid" 2>/dev/null || true
  shell_pid=""
}
# lock_holders LOCK: one line per process with a descriptor open on LOCK,
# found through /proc, as its pid, command name and argv.
lock_holders() { # LOCK
  local target fd pid seen=" "
  target="$(readlink -f -- "$1")" || target="$1"
  for fd in /proc/[0-9]*/fd/*; do
    [[ $(readlink -- "$fd" 2>/dev/null) == "$target" ]] || continue
    pid="${fd#/proc/}"; pid="${pid%%/*}"
    [[ $seen != *" $pid "* ]] || continue
    seen+="$pid "
    printf '        holder pid=%s comm=%s cmdline=%s\n' "$pid" "$(cat -- "/proc/$pid/comm" 2>/dev/null)" "$(tr '\0' ' ' 2>/dev/null <"/proc/$pid/cmdline")"
  done
}
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
  if [[ $status -ne 0 ]]; then
    if [[ -n $got ]]; then fail "$label: command failed: $*: got $got"; else fail "$label: command failed: $*"; fi
    return
  fi
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
# monitor_rule NAME MODE [SCALE]: the Lua monitor rule that gives output
# NAME the mode MODE, such as 480x720, at SCALE, 1 by default, and the
# layout's origin. The nested Wayland output takes any mode and an integer
# scale; a headless output stays 0x0 in the sandbox
# (docs/architecture/runtime-hyprland-nested.md).
monitor_rule() { printf 'hl.monitor({ output = "%s", mode = "%s", position = "0x0", scale = %s })\n' "$1" "$2" "${3:-1}"; }
# output_mode NAME MODE [SCALE]: the nested compositor applies
# monitor_rule's rule now through `hyprctl eval`; the reply is hyprctl's.
# A configuration reload drops the rule but leaves the output at its mode
# and scale, unless a rule the configuration loads gives the output
# another (docs/architecture/runtime-hyprland.md). Under a hold it stands
# for a reset, and a reload applies the held rule again from
# mode_hold_file. A row restores the mode it read first.
output_mode() { hypr eval "$(monitor_rule "$@")"; }
# mode_scale_of NAME: output NAME's mode and scale as `WxH scale=S`, such
# as `3510x1866 scale=2`, the mode in device pixels; returns 1 when no
# monitor has that name.
mode_scale_of() { hypr -j monitors | python3 -c 'import json,sys; m=[m for m in json.load(sys.stdin) if m["name"]==sys.argv[1]]; print("%dx%d scale=%g" % (m[0]["width"], m[0]["height"], m[0]["scale"])) if len(m)==1 else sys.exit(1)' "$1"; }
# hold_mode LABEL NAME MODE [SCALE]: output NAME takes MODE at SCALE, 1 by
# default, and the rows after it hold that mode and scale until
# release_mode. The rule goes into mode_hold_file, which every load of the
# configuration runs, and output_mode applies it now. The hold begins once
# the monitor reads both; a mode or a scale never taken is a failure,
# holds nothing and leaves no hold file.
hold_mode() {
  local label="$1" output="$2" want="$3 scale=${4:-1}" failed_before="$failures"
  [[ ${#mode_hold[@]} -eq 0 ]] || { fail "$label: ${mode_hold[0]} already holds ${mode_hold[1]}; hold_mode does not nest"; return; }
  if ! monitor_rule "$output" "$3" "${4:-1}" >"$mode_hold_file.next" || ! mv -T -- "$mode_hold_file.next" "$mode_hold_file"; then
    fail "$label: the hold file $mode_hold_file is not written"
    rm -f -- "$mode_hold_file.next" || fail "$label: the partial hold file $mode_hold_file.next is not removed"
    return 0
  fi
  expect "$label" ok output_mode "$output" "$3" "${4:-1}"
  expect_poll "$output reads $want" "$want" mode_scale_of "$output"
  if [[ $failures -eq $failed_before ]]; then
    mode_hold=("$output" "$want")
  else
    rm -f -- "$mode_hold_file" || fail "$label: the hold file $mode_hold_file of a hold never taken is not removed"
  fi
  return 0
}
# held_mode_state: what became of the held mode, as one word. `held`: the
# output reads its mode and scale. `reset`: the output reads another mode
# or another scale. Once the hold began, a writer the row does not control
# can move a nested output off it, and that is not what a held row
# measures. The host is one. Hyprland gives a Wayland-backend output the
# size of every configure the host sends the nested window that differs
# from its rule's mode (src/output/Monitor.cpp, the output's state
# listener, Hyprland v0.56.2), and the host sends one whenever it resizes
# the window or changes its state, focus included. It changes the size,
# not the scale. A scale-2 run of scripts/sandbox-shots.sh once read the
# output at its own mode and scale 1, from a writer not identified
# (docs/architecture/validation-smoke-faults.md).
# A configuration reload, which the shell runs when its Hyprland layer
# changes, drops every rule `hyprctl eval` added
# (src/config/lua/ConfigManager.cpp, CConfigManager::reload, v0.56.2) and
# applies the rule mode_hold_file names again. The shell writes no monitor
# rule of its own.
# `unreadable`: the monitor cannot be read, which excuses nothing.
held_mode_state() {
  local state
  state="$(mode_scale_of "${mode_hold[0]}")" || { echo unreadable; return; }
  if [[ $state == "${mode_hold[1]}" ]]; then echo held; else echo reset; fi
}
# release_mode LABEL NAME MODE [SCALE]: any hold ends, its file goes, and
# output NAME takes MODE at SCALE, 1 by default, again, whether or not
# hold_mode's mode was taken, and reads both before the rows go on.
release_mode() {
  mode_hold=()
  rm -f -- "$mode_hold_file" || fail "$1: the hold file $mode_hold_file is not removed"
  expect "$1" ok output_mode "$2" "$3" "${4:-1}"
  expect_poll "$2 reads $3 scale=${4:-1}" "$3 scale=${4:-1}" mode_scale_of "$2"
}
# The first monitor's mode as WxH, its logical width, and its name.
first_mode() { hypr -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print("%dx%d" % (m["width"], m["height"]))'; }
first_width() { hypr -j monitors | python3 -c 'import json,sys; m=json.load(sys.stdin)[0]; print(round(m["width"] / m["scale"]))'; }
first_name() { hypr -j monitors | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["name"])'; }
# unscaled_mode_of NAME: output NAME's mode as WxH, its logical size, while
# it reads a sized mode at scale 1. hidpi_mode_of NAME: double that mode,
# which at scale 2 keeps the logical size. Each returns 1, with the reading
# on stderr, for a 0x0 mode or a scale other than 1: an unsized output has
# no mode to double, and a row that doubled it would compare zeros.
unscaled_mode_of() {
  local state
  state="$(mode_scale_of "$1")" || return 1
  if [[ $state =~ ^([1-9][0-9]*x[1-9][0-9]*)\ scale=1$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s reads %s, not a sized mode at scale 1\n' "$1" "$state" >&2
  return 1
}
hidpi_mode_of() {
  local mode
  mode="$(unscaled_mode_of "$1")" || return 1
  echo "$((${mode%x*} * 2))x$((${mode#*x} * 2))"
}
# solid_png PATH WIDTH HEIGHT R G B: a PNG of one colour written to PATH,
# for the images the wallpaper rows draw.
solid_png() {
  python3 - "$@" <<'PY'
import struct, sys, zlib
path, (w, h, r, g, b) = sys.argv[1], map(int, sys.argv[2:])
def chunk(kind, data): return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
rows = zlib.compress(b"".join(b"\x00" + bytes((r, g, b)) * w for _ in range(h)))
with open(path, "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", rows) + chunk(b"IEND", b""))
PY
}
# The vgs.themes background's state directory and readers, which the
# wallpaper rows from rows/themes.sh on share. bg_state_names PATH: the
# state file replaced whole with one naming image PATH as current.
# background_image_on NAME: what the background on screen NAME draws, as
# `<path> <status>`, `-` for no image. background_source_size NAME: the
# sourceSize it requests, as WxH. Each prints `images=<n>` while the
# background draws other than one image.
bg_state="$home/.local/state/vgs"
bg_state_names() { printf '{"schemaVersion":1,"current":"%s","stamp":"row","themes":{}}\n' "$1" >"$bg_state/backgrounds.json.tmp" && mv -T -- "$bg_state/backgrounds.json.tmp" "$bg_state/backgrounds.json"; }
background_image_on() { ipc smoke images "background:$1" vgs.themes | py_reply 'import json,sys; r=json.load(sys.stdin); print(" ".join([r[0][0] or "-", r[0][1]]) if len(r)==1 else "images=%d" % len(r))'; }
background_source_size() { ipc smoke images "background:$1" vgs.themes | py_reply 'import json,sys; r=json.load(sys.stdin); print("%dx%d" % tuple(int(v) for v in r[0][4]) if len(r)==1 else "images=%d" % len(r))'; }

# shell_output_scale, which scripts/sandbox-shots.sh sets for --scale, is
# the first monitor's scale when the first shell starts. 1, the default,
# leaves the monitor as the host sized it. 2 holds it at double its mode
# and scale 2 for the whole run, so the layout keeps its logical size and
# the shell draws in device pixels. The scale is set before the shell
# starts: a shell already running when the scale changes keeps drawing its
# windows at the old ratio (docs/architecture/runtime-qml.md).
# shell_output_mode is the mode the run holds at scale 2, read before the
# shell starts, and empty at scale 1: a row that leaves the hold for its
# own returns to it, never to a mode it reads after a reset.
shell_output_mode=""
case "${shell_output_scale:=1}" in
  1) ;;
  2)
    if ! scaled_output="$(first_name)" || ! shell_output_mode="$(hidpi_mode_of "$scaled_output")"; then
      printf 'qml-smoke: shell-output-scale=2 not-held output=%s reason=mode-unread\n' "${scaled_output:-unread}"
      exit 1
    fi
    hold_mode "the nested compositor holds $scaled_output at double its mode and scale 2 before the shell starts" "$scaled_output" "$shell_output_mode" 2
    if [[ ${#mode_hold[@]} -eq 0 ]]; then
      printf 'qml-smoke: shell-output-scale=2 not-held output=%s reason=hold-not-taken\n' "$scaled_output"
      exit 1
    fi
    ;;
  *) printf 'qml-smoke: refused: shell-output-scale=%s\n' "$shell_output_scale"; exit 2 ;;
esac
# The shader-cost runner uses this sandbox without loading product services.
if [[ ${harness_scene_only:-false} != true ]]; then
  start_shell "$repo" "$sandbox/qs.log" || exit 1
fi
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
# settings_page_open ID: the Settings plugin enabled and its window
# summoned on plugin ID's page. settings_page_close: the window hidden and
# the plugin disabled again, as the rows that open it leave it.
settings_page_open() {
  expect "enabling Settings for $1's steps is allowed" ok ipc shell setPluginEnabled vgs.settings true
  expect_poll "the Settings service is built for $1's steps" True record_exists vgs.settings
  expect "Settings is summoned on $1's page" ok ipc shell summon window vgs.settings "{\"plugin\":\"$1\"}"
  expect_poll "the Settings window shows $1's page" "\"$1\"" ipc smoke readInstance window vgs.settings page
}
settings_page_close() {
  expect "the Settings window is hidden after $1's steps" ok ipc shell hide window vgs.settings
  expect "disabling Settings after $1's steps is allowed" ok ipc shell setPluginEnabled vgs.settings false
  expect_poll "the Settings service is gone after $1's steps" False record_exists vgs.settings
}
# offered_actions ID: each status entry of plugin ID with an action as
# [key, label, offered], from the manager row the Settings window draws.
offered_actions() { ipc smoke readInstance window vgs.settings plugins | py_reply 'import json,sys; r=[p for p in json.load(sys.stdin) if p["id"] == sys.argv[1]][0]["status"]; print(json.dumps([[s["key"], s["action"]["label"], s["action"]["offered"]] for s in r if s["action"] is not None]))' "$1"; }
# settings_act ID KEY: the manager's answer to the step of ID's entry KEY,
# as its button hands it on.
settings_act() { ipc smoke invokeInstance window vgs.settings act "{\"id\":\"$1\",\"key\":\"$2\"}"; }
# settings_press TEXT [SCOPE_TYPE SCOPE_TEXT]: a real click on the Settings
# window's shown, enabled Button TEXT, inside the first shown SCOPE_TYPE
# drawing SCOPE_TEXT when given, the page scrolled first so the button lies
# in view, as a user scrolls to a step below the fold.
settings_press() {
  local shown
  shown="$(ipc smoke revealText window vgs.settings Button "$1")" || return 1
  [[ $shown =~ ^[0-9.]+$ ]] || { echo "settings_press: no Button $1 to reveal: $shown" >&2; return 1; }
  sleep 0.2
  if [[ $# -eq 3 ]]; then click_scoped_in window:Settings window vgs.settings "$2" "$3" Button "$1"
  else click_in window:Settings window vgs.settings Button "$1"
  fi
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
# The agent warden's runtime dir and vsys's own status fixtures, which
# rows/agent-warden.sh and scripts/sandbox-shots.sh write from.
warden_dir="$rt_dir/agent-warden"
warden_fixtures="$repo/scripts/smoke/fixtures/agent-warden"
# warden_put NAME AGE [KIND]: status-NAME.json with its time and every
# event's set AGE seconds before now, and every event's kind set to KIND
# when given, replaced into place by rename; prints the time.
warden_put() {
  python3 - "$warden_fixtures/status-$1.json" "$warden_dir" "$2" "${3:-}" <<'PY'
import json, os, sys, time
source, target, age, kind = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
doc = json.load(open(source))
moment = int(time.time()) - age
doc["time"] = moment
for event in doc["events"]:
    event["time"] = moment
    if kind:
        event["kind"] = kind
tmp = os.path.join(target, "status.tmp.%d" % os.getpid())
with open(tmp, "w") as out:
    json.dump(doc, out)
os.replace(tmp, os.path.join(target, "status.json"))
print(moment)
PY
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

# smoke_row NAME [DIR]: source DIR/NAME.sh, DIR the rows directory by
# default, in this shell, since rows share state, and fail the row once
# when its output holds a Python traceback. A reader can raise outside
# every expect, in a helper or an unchecked pipe, and the traceback then
# sits in the log behind passing checks. The row's stdout and stderr go
# through one filter that prints each line at once, so a row that exits
# still shows its lines, and keeps them in $sandbox/rows/NAME.out. The
# harness does not wait for the filter to end: a process the row started
# can hold the pipe open. The last write of the row is an end marker; the
# filter counts the tracebacks before it into $sandbox/rows/NAME.result,
# never prints the marker, and passes every later line on until its input
# closes. The harness polls for that count, for smoke_row_drain_s at most.
# The locals carry a prefix, since the row runs in their scope.
# rows/updates.sh holds the controls.
smoke_row_drain_s=5
smoke_row() { # NAME [DIR]
  local smoke_row_name="$1" smoke_row_dir="${2:-$repo/scripts/smoke/rows}" smoke_row_marker smoke_row_count=""
  local smoke_row_out="$sandbox/rows/$1.out" smoke_row_result="$sandbox/rows/$1.result"
  smoke_row_marker="qml-smoke: row-end $1 $$ $SRANDOM"
  mkdir -p -- "$sandbox/rows"
  rm -f -- "$smoke_row_out" "$smoke_row_result"
  {
    # The row reads no argument, as when qml-smoke.sh sourced it.
    set --
    source "$smoke_row_dir/$smoke_row_name.sh"
    printf '%s\n' "$smoke_row_marker"
  } > >(awk -v marker="$smoke_row_marker" -v out="$smoke_row_out" -v result="$smoke_row_result" '
    $0 == marker && !ended { printf "%d\n", tracebacks > result; close(result); ended = 1; next }
    { print; fflush(); print > out; fflush(out) }
    !ended && index($0, "Traceback (most recent call last):") { tracebacks++ }
  ') 2>&1
  for _ in $(seq 1 $((smoke_row_drain_s * 10))); do
    if [[ -f $smoke_row_result ]] && read -r smoke_row_count <"$smoke_row_result" && [[ $smoke_row_count =~ ^[0-9]+$ ]]; then break; fi
    smoke_row_count=""
    sleep 0.1
  done
  if [[ -z $smoke_row_count ]]; then
    fail "$smoke_row_name: its output did not drain within ${smoke_row_drain_s}s: $smoke_row_out"
  elif [[ $smoke_row_count -gt 0 ]]; then
    fail "$smoke_row_name: its output holds $smoke_row_count Python traceback(s): $smoke_row_out"
  fi
  ipc_oversize_check "$smoke_row_name"
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
