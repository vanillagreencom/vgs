# The compositor provider's window, monitor and pointer operations, sent
# through the existing acme.probe dispatch handle. Read each effect from
# Hyprland, not from the queue's `ok`. Before each effect, a hyprctl copy
# answers `ok` without dispatching: the same state assertion must fail
# once. The control logs stay in the sandbox. State polls use the shared
# expect_poll interval of 200 ms; no latency budget is measured here.
# Fullscreen is focused-window-only in both dialects. Move and resize are
# absolute layout coordinates and size, respectively.
set -euo pipefail

dispatch_client() { # ADDRESS FIELD
  hypr -j clients | py_reply 'import json,sys
c = next((c for c in json.load(sys.stdin) if c["address"] == sys.argv[1]), None)
print("absent" if c is None else json.dumps(c[sys.argv[2]]))' "$1" "$2"
}
dispatch_monitor() {
  hypr -j monitors | py_reply 'import json,sys
print(next((m["name"] for m in json.load(sys.stdin) if m["focused"]), "absent"))'
}
dispatch_cursor() {
  hypr -j cursorpos | py_reply 'import json,sys
p = json.load(sys.stdin); print(json.dumps([p["x"], p["y"]]))'
}

cat >"$shim/hyprctl.dispatch-noop" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == dispatch ]]; then
  printf '%s\n' "\$2" >>"$sandbox/dispatch-dropped.log"
  echo ok
else
  exec "$hyprctl_bin" "\$@"
fi
EOF
chmod 755 "$shim/hyprctl.dispatch-noop"
: >"$sandbox/dispatch-dropped.log"
dispatch_drops() { wc -l <"$sandbox/dispatch-dropped.log"; }
# A fake successful transport must fail the effect's real assertion. The
# assertion runs in a subshell so only its controlled failure is counted.
dispatch_noop_control() { # REQUEST WANT READER [ARGS...]
  local request="$1" want="$2" log="$sandbox/dispatch-control-${1%% *}.log" count before
  shift 2
  before="$(dispatch_drops)"
  shim_hyprctl dispatch-noop
  expect "control: the queue accepts $request with a dropped transport" ok probe dispatch "$request"
  expect_poll "control: the transport drops $request" "$((before + 1))" dispatch_drops
  (
    failures=0
    row_class=behaviour
    expect "the dropped dispatch has no requested effect" "$want" "$@"
    printf 'control-failures=%s\n' "$failures"
  ) >"$log"
  count="$(sed -n 's/^control-failures=//p' "$log")"
  expect "control: dropping ${request%% *} fails its readback once" 1 printf '%s' "$count"
  shim_hyprctl real
}

if open_toplevel "$sandbox/dispatch-target.log" smoke.dispatch target; then
  dispatch_target_pid="$toplevel_pid"
  dispatch_target="$(toplevel_address "$dispatch_target_pid")"
  if open_toplevel "$sandbox/dispatch-other.log" smoke.dispatch other; then
    dispatch_other_pid="$toplevel_pid"
    dispatch_other="$(toplevel_address "$dispatch_other_pid")"
    expect_poll "the other window is focused before addressed operations" '["smoke.dispatch", "other"]' active_window
    expect_poll "the target starts tiled" false dispatch_client "$dispatch_target" floating
    dispatch_noop_control "floatWindow $dispatch_target set" true dispatch_client "$dispatch_target" floating
    expect "float addresses the target, not the active window" ok probe dispatch "floatWindow $dispatch_target set"
    expect_poll "float makes the addressed window floating" true dispatch_client "$dispatch_target" floating
    expect "float leaves the active window tiled" false dispatch_client "$dispatch_other" floating
    expect "a repeated float set is accepted" ok probe dispatch "floatWindow $dispatch_target set"
    expect_poll "a repeated float set keeps it floating" true dispatch_client "$dispatch_target" floating
    expect "float unset is accepted" ok probe dispatch "floatWindow $dispatch_target unset"
    expect_poll "float unset tiles the target" false dispatch_client "$dispatch_target" floating
    expect "float toggle is accepted" ok probe dispatch "floatWindow $dispatch_target toggle"
    expect_poll "float toggle floats the target again" true dispatch_client "$dispatch_target" floating

    expect "the target gets a known starting position" ok probe dispatch "moveWindow $dispatch_target 100 100"
    geometry expect_poll "the starting position is read back" '[100, 100]' dispatch_client "$dispatch_target" at
    dispatch_noop_control "moveWindow $dispatch_target 140 130" '[140, 130]' dispatch_client "$dispatch_target" at
    expect "an absolute move is accepted" ok probe dispatch "moveWindow $dispatch_target 140 130"
    geometry expect_poll "move puts the addressed window at the requested position" '[140, 130]' dispatch_client "$dispatch_target" at
    expect "the target gets a known starting size" ok probe dispatch "resizeWindow $dispatch_target 420 280"
    geometry expect_poll "the starting size is read back" '[420, 280]' dispatch_client "$dispatch_target" size
    dispatch_noop_control "resizeWindow $dispatch_target 460 310" '[460, 310]' dispatch_client "$dispatch_target" size
    expect "an absolute resize is accepted" ok probe dispatch "resizeWindow $dispatch_target 460 310"
    geometry expect_poll "resize gives the addressed window the requested size" '[460, 310]' dispatch_client "$dispatch_target" size
    expect "move and resize leave the other window focused" '["smoke.dispatch", "other"]' active_window

    expect "the target is focused for fullscreen" ok probe dispatch "focusWindow $dispatch_target"
    expect_poll "the target has the focus for fullscreen" '["smoke.dispatch", "target"]' active_window
    expect "the target starts without fullscreen" 0 dispatch_client "$dispatch_target" fullscreen
    dispatch_noop_control "fullscreenWindow fullscreen set" 2 dispatch_client "$dispatch_target" fullscreen
    expect "fullscreen set is accepted" ok probe dispatch "fullscreenWindow fullscreen set"
    expect_poll "fullscreen sets the focused window's state" 2 dispatch_client "$dispatch_target" fullscreen
    expect "a repeated fullscreen set is accepted" ok probe dispatch "fullscreenWindow fullscreen set"
    expect_poll "a repeated fullscreen set keeps it fullscreen" 2 dispatch_client "$dispatch_target" fullscreen
    expect "fullscreen unset is accepted" ok probe dispatch "fullscreenWindow fullscreen unset"
    expect_poll "fullscreen unset restores the window" 0 dispatch_client "$dispatch_target" fullscreen
    expect "maximized toggle is accepted" ok probe dispatch "fullscreenWindow maximized toggle"
    expect_poll "maximized mode is distinct from fullscreen" 1 dispatch_client "$dispatch_target" fullscreen
    expect "maximized unset is accepted" ok probe dispatch "fullscreenWindow maximized unset"
    expect_poll "maximized unset restores the window" 0 dispatch_client "$dispatch_target" fullscreen
    expect "fullscreen leaves the other window unchanged" 0 dispatch_client "$dispatch_other" fullscreen

    expect "the pointer gets a known starting position" ok probe dispatch "moveCursor 100 100"
    geometry expect_poll "the starting pointer position is read back" '[100, 100]' dispatch_cursor
    dispatch_noop_control "moveCursor 180 160" '[180, 160]' dispatch_cursor
    expect "cursor move is accepted" ok probe dispatch "moveCursor 180 160"
    geometry expect_poll "cursor move changes the compositor's pointer position" '[180, 160]' dispatch_cursor

    # The headless output has no usable size on NVIDIA. Suppress mouse
    # focus and warps in this nested configuration alone so the pointer's
    # monitor cannot immediately take focus back from that output.
    dispatch_config="$home/.config/hypr/hyprland.lua"
    cp -- "$dispatch_config" "$sandbox/hyprland-before-dispatch.lua"
    printf '%s\n' 'hl.config({ input = { follow_mouse = 0 }, cursor = { no_warps = true }, misc = { mouse_move_focuses_monitor = false } })' >>"$dispatch_config"
    expect "the nested configuration holds explicit monitor focus" ok hypr reload config-only
    dispatch_first_monitor="$(dispatch_monitor)"
    dispatch_output=SMOKE-DISPATCH
    expect "the nested compositor adds the focus target monitor" ok hypr output create headless "$dispatch_output"
    dispatch_noop_control "focusMonitor $dispatch_output" "$dispatch_output" dispatch_monitor
    expect "monitor focus is accepted" ok probe dispatch "focusMonitor $dispatch_output"
    expect_poll "monitor focus changes Hyprland's focused monitor" "$dispatch_output" dispatch_monitor
    expect "monitor focus returns to the original monitor" ok probe dispatch "focusMonitor $dispatch_first_monitor"
    expect_poll "the original monitor has the focus again" "$dispatch_first_monitor" dispatch_monitor
    expect "the nested compositor removes the focus target monitor" ok hypr output remove "$dispatch_output"
    cp -- "$sandbox/hyprland-before-dispatch.lua" "$dispatch_config.next"
    mv -T -- "$dispatch_config.next" "$dispatch_config"
    expect "the nested configuration restores its mouse focus settings" ok hypr reload config-only

    close_toplevel "$dispatch_other_pid" "the other dispatch window exits"
  else
    fail "the other dispatch window maps"
  fi
  close_toplevel "$dispatch_target_pid" "the target dispatch window exits"
else
  fail "the target dispatch window maps"
fi
expect "the dispatch row returns to workspace 1" ok probe dispatch "focusWorkspace 1"
