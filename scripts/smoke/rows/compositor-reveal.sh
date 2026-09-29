# Bringing a window into view: the compositor capability's `reveal`
# (shell/Core/Compositor.qml, shell/Core/Dispatch.js), driven through the
# fixture's `reveal` handle on windows of the toplevel helper: one on
# another workspace, one in a hidden special workspace, one under another
# window's fullscreen, one in a background group tab, one on a second
# monitor, one of several windows of one application, and an application
# that raises its own window while the reveal waits for it. Each case
# starts from the other window focused on workspace 1 and first reads its
# target out of view, so `in view` cannot pass on the state before the
# reveal. Hyprland v0.56.2's focus dispatcher already shows the workspace,
# the special workspace, the group tab and the monitor of the window it
# focuses, and ends a fullscreen over it (docs/architecture/runtime.md
# § Hyprland), so the old path, that dispatcher alone on the first window
# of the application, fails only where the reveal decides something: which
# of several windows, and whether to move at all when the application
# moved first. Those two cases carry the old path as their control. The
# row ends with its windows closed, its monitor removed and workspace 1
# focused.
set -euo pipefail
reveal_events="$sandbox/reveal-events.log"
# Every line of Hyprland's event socket, as it arrives.
spawn "$reveal_events" python3 -u -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
buf = b""
while True:
    data = s.recv(4096)
    if not data: break
    buf += data
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        print(line.decode(errors="replace"), flush=True)
' "$rt_dir/hypr/$signature/.socket2.sock"
reveal_events_pid="$spawn_pid"
event_lines() { wc -l <"$reveal_events"; }
# How many workspace switches Hyprland reported after line N of the log.
switches_since() { tail -n "+$(($1 + 1))" -- "$reveal_events" | grep -c '^workspacev2>>' || true; }
# in_view ADDRESS: `shown` when ADDRESS is the active window, drawn (a
# background group tab is not) and on a workspace its monitor shows, a
# special one or a regular one no special workspace covers; else what
# differs.
in_view() {
  local clients monitors active
  clients="$(hypr -j clients)" && monitors="$(hypr -j monitors)" && active="$(hypr -j activewindow)" || return 1
  python3 -c '
import json, sys
clients, monitors, active = (json.loads(a) for a in sys.argv[1:4])
c = next((c for c in clients if c["address"] == sys.argv[4]), None)
if c is None: print("absent"); sys.exit()
ws = c["workspace"]["name"]
if ws.startswith("special:"): shown = any(m["specialWorkspace"]["name"] == ws for m in monitors)
else: shown = any(m["activeWorkspace"]["id"] == c["workspace"]["id"] and m["specialWorkspace"]["id"] == 0 for m in monitors)
problems = [k for k, bad in (("inactive", active.get("address") != c["address"]), ("undrawn", not c["visible"]), ("workspace-hidden", not shown)) if bad]
print("shown" if not problems else " ".join(problems))' "$clients" "$monitors" "$active" "$1"
}
# `out` for a window in_view does not read as shown, else `shown`.
out_of_view() { local v; v="$(in_view "$1")" || return 1; if [[ $v == shown ]]; then echo shown; else echo out; fi; }
# Whether Hyprland draws the window: False for a background group tab.
drawn() { hypr -j clients | python3 -c 'import json,sys; print(next(c["visible"] for c in json.load(sys.stdin) if c["address"] == sys.argv[1]))' "$1"; }
reveal_other() {
  expect "the other window takes the focus before the $1 case" ok hypr dispatch "hl.dsp.focus({ window = \"address:$reveal_other_window\" })"
  expect_poll "the other window has the focus before the $1 case" '["smoke.other", "Other window"]' active_window
}
# open_reveal NAME: a toplevel helper of class smoke.reveal titled NAME;
# its pid and address are left in reveal_pid and reveal_window.
open_reveal() {
  open_toplevel "$sandbox/toplevel-reveal-$1.log" smoke.reveal "$1" || return 1
  reveal_pid="$toplevel_pid"
  reveal_window="$(toplevel_address "$reveal_pid")" && [[ $reveal_window == 0x* ]]
}
move_to() { hypr dispatch "hl.dsp.window.move({ workspace = \"$2\", window = \"address:$1\", follow = false })"; }

if open_other "$sandbox/toplevel-reveal-other.log"; then
  reveal_other_window="$(other_address)"

  # Another workspace, with the wait for the application, which raises
  # nothing, so the shell reveals once the wait ends.
  if open_reveal elsewhere; then
    expect "the window moves to workspace 3" ok move_to "$reveal_window" 3
    reveal_other "other-workspace"
    expect "a window on another workspace starts out of view" out out_of_view "$reveal_window"
    expect "the reveal of a window on another workspace is accepted" ok probe reveal "$reveal_window sender"
    expect_poll "the reveal shows the other workspace and focuses the window" shown in_view "$reveal_window"
    expect_log "the reveal waited for the application, then focused the window itself" 1 "compositor: reveal=shell address=$reveal_window"
    close_toplevel "$reveal_pid" "the other-workspace window's helper exits 0 on SIGTERM"
  else
    fail "the other-workspace window maps"
  fi

  # A hidden special workspace.
  if open_reveal scratch; then
    expect "the window moves to a special workspace" ok move_to "$reveal_window" special:reveal
    reveal_other "special-workspace"
    expect "a window in a hidden special workspace starts out of view" out out_of_view "$reveal_window"
    expect "the reveal of a window in a special workspace is accepted" ok probe reveal "$reveal_window"
    expect_poll "the reveal shows the special workspace and focuses the window" shown in_view "$reveal_window"
    close_toplevel "$reveal_pid" "the special-workspace window's helper exits 0 on SIGTERM"
  else
    fail "the special-workspace window maps"
  fi

  # A window under another window's fullscreen on another workspace: the
  # focus ends the fullscreen (misc:on_focus_under_fullscreen, 2 by
  # default), so the window shows.
  if open_reveal full && full_pid="$reveal_pid" && full="$reveal_window" && open_reveal under; then
    under_pid="$reveal_pid"
    under="$reveal_window"
    expect "the fullscreen window moves to workspace 3" ok move_to "$full" 3
    expect "the window under it moves to workspace 3" ok move_to "$under" 3
    expect "the first window is focused on workspace 3" ok hypr dispatch "hl.dsp.focus({ window = \"address:$full\" })"
    expect "the first window goes fullscreen" ok hypr dispatch "hl.dsp.window.fullscreen({ window = \"address:$full\" })"
    fullscreen_of() { hypr -j clients | python3 -c 'import json,sys; print(next(c["fullscreen"] for c in json.load(sys.stdin) if c["address"] == sys.argv[1]))' "$1"; }
    expect_poll "the first window is fullscreen" 2 fullscreen_of "$full"
    reveal_other "under-fullscreen"
    expect "a window under a fullscreen one elsewhere starts out of view" out out_of_view "$under"
    expect "the reveal of a window under a fullscreen one is accepted" ok probe reveal "$under"
    expect_poll "the reveal shows the workspace and focuses the window" shown in_view "$under"
    expect_poll "the fullscreen ended" 0 fullscreen_of "$full"
    close_toplevel "$under_pid" "the window under the fullscreen one exits 0 on SIGTERM"
    close_toplevel "$full_pid" "the fullscreen window's helper exits 0 on SIGTERM"
  else
    fail "the fullscreen windows map"
  fi

  # A background group tab: the first window becomes a group while it has
  # the focus, and the second opens into it (group:auto_group, on by
  # default), as its current tab, so the first is the hidden one.
  if open_reveal tab-one && tab_one_pid="$reveal_pid" && tab_one="$reveal_window" &&
    expect "the first window becomes a group" ok hypr dispatch "hl.dsp.group.toggle({ window = \"address:$tab_one\" })" &&
    open_reveal tab-two; then
    tab_two_pid="$reveal_pid"
    tab_two="$reveal_window"
    grouped() { hypr -j clients | python3 -c 'import json,sys; print(next(len(c["grouped"]) for c in json.load(sys.stdin) if c["address"] == sys.argv[1]))' "$tab_one"; }
    expect_poll "the group holds both windows" 2 grouped
    expect "the second window is the group's current tab" ok hypr dispatch "hl.dsp.focus({ window = \"address:$tab_two\" })"
    reveal_other "group-tab"
    expect "a background group tab starts out of view" out out_of_view "$tab_one"
    expect "a background group tab is not drawn" False drawn "$tab_one"
    expect "the reveal of a background group tab is accepted" ok probe reveal "$tab_one"
    expect_poll "the reveal makes the tab current and focuses it" shown in_view "$tab_one"
    close_toplevel "$tab_two_pid" "the second tab's helper exits 0 on SIGTERM"
    close_toplevel "$tab_one_pid" "the first tab's helper exits 0 on SIGTERM"
  else
    fail "the group-tab windows map"
  fi

  # A second monitor. The nested compositor's headless output reports no
  # size, so its pointer cannot move there and Hyprland hands the monitor
  # focus back to the pointer's monitor after the focus (focusedmon events,
  # read on host cachy on 2026-09-29); the window is focused and its
  # workspace shown on its monitor, which the row reads.
  reveal_output=SMOKE-REVEAL
  expect "the nested compositor adds a monitor for the reveal rows" ok hypr output create headless "$reveal_output"
  if open_reveal far; then
    expect "the window moves to the second monitor" ok hypr dispatch "hl.dsp.window.move({ monitor = \"$reveal_output\", window = \"address:$reveal_window\", follow = false })"
    on_monitor() { hypr -j clients | python3 -c 'import json,sys; print(next(c["monitor"] for c in json.load(sys.stdin) if c["address"] == sys.argv[1]))' "$reveal_window"; }
    expect_poll "the window is on the second monitor" 1 on_monitor
    reveal_other "second-monitor"
    expect "a window on the second monitor starts out of the focus" out out_of_view "$reveal_window"
    expect "the reveal of a window on the second monitor is accepted" ok probe reveal "$reveal_window"
    expect_poll "the reveal focuses the window on its monitor's shown workspace" shown in_view "$reveal_window"
    close_toplevel "$reveal_pid" "the second-monitor window's helper exits 0 on SIGTERM"
  else
    fail "the second-monitor window maps"
  fi
  expect "the nested compositor removes the reveal monitor" ok hypr output remove "$reveal_output"

  # Several windows of one application: the one focused last, not the
  # first named. The control is the old path, the focus dispatcher on the
  # first window, which leaves the window focused last out of view.
  if open_reveal many-one && many_one_pid="$reveal_pid" && many_one="$reveal_window" && open_reveal many-two; then
    many_two_pid="$reveal_pid"
    many_two="$reveal_window"
    expect "the first window moves to workspace 3" ok move_to "$many_one" 3
    expect "the second window moves to workspace 4" ok move_to "$many_two" 4
    expect "the second window is focused" ok hypr dispatch "hl.dsp.focus({ window = \"address:$many_two\" })"
    expect "then the first window, the one focused last" ok hypr dispatch "hl.dsp.focus({ window = \"address:$many_one\" })"
    reveal_other "several-windows"
    expect "the reveal of the application's windows, the other named first, is accepted" ok probe reveal "$many_two,$many_one"
    expect_poll "the reveal shows the window focused last" shown in_view "$many_one"
    reveal_other "several-windows control"
    expect "control: the old path focuses the first window named" ok probe dispatch "focusWindow $many_two"
    expect_poll "control: the old path shows the first window named" shown in_view "$many_two"
    expect "control: the old path leaves the window focused last out of view" out out_of_view "$many_one"
    close_toplevel "$many_two_pid" "the second of several windows' helper exits 0 on SIGTERM"
    close_toplevel "$many_one_pid" "the first of several windows' helper exits 0 on SIGTERM"
  else
    fail "the several windows map"
  fi

  # An application that raises its own window while the reveal waits for
  # it: the view switches once, to that window, and the shell moves
  # nothing. The window the user focused last is the other one, on
  # another workspace, so a reveal that did not wait would switch there
  # first. The control is the old path, which does not wait: the focus
  # dispatcher, then the application's raise, switch twice.
  if open_reveal raised && raised_pid="$reveal_pid" && raised="$reveal_window" && open_reveal recent; then
    recent_pid="$reveal_pid"
    recent="$reveal_window"
    expect "the window the application raises moves to workspace 3" ok move_to "$raised" 3
    expect "the window focused last moves to workspace 4" ok move_to "$recent" 4
    expect "the window focused last is focused" ok hypr dispatch "hl.dsp.focus({ window = \"address:$recent\" })"
    reveal_other "self-raise"
    before="$(event_lines)"
    expect "a reveal awaiting the application is accepted" ok probe reveal "$raised,$recent sender"
    expect "the application raises its own window" ok hypr dispatch "hl.dsp.focus({ window = \"address:$raised\" })"
    expect_poll "the application's own window is in view" shown in_view "$raised"
    expect_log "the reveal ended on the application's own focus" 1 "compositor: reveal=sender address=$raised"
    expect "the view switched once" 1 switches_since "$before"
    reveal_other "self-raise control"
    before="$(event_lines)"
    expect "control: the old path focuses the window focused last" ok probe dispatch "focusWindow $recent"
    expect_poll "control: the old path shows the window focused last" shown in_view "$recent"
    expect "control: the application raises its own window" ok hypr dispatch "hl.dsp.focus({ window = \"address:$raised\" })"
    expect_poll "control: the application's own window ends in view" shown in_view "$raised"
    expect_poll "control: the old path switched twice" 2 switches_since "$before"
    close_toplevel "$recent_pid" "the recently focused window's helper exits 0 on SIGTERM"
    close_toplevel "$raised_pid" "the self-raising window's helper exits 0 on SIGTERM"
  else
    fail "the self-raise windows map"
  fi

  close_other "the reveal rows' other window exits 0 on SIGTERM"
else
  fail "the reveal rows' other window maps"
fi
expect "workspace 1 is focused after the reveal rows" ok probe dispatch "focusWorkspace 1"
expect_poll "the compositor is on workspace 1 after the reveal rows" 1 active_ws
kill -TERM -- "$reveal_events_pid" 2>/dev/null || true
