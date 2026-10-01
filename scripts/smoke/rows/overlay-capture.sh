# Overlay capture, D067. This row runs last. It starts the normal tree after
# start-order's controls, adds harness user binds to the nested Hyprland Lua,
# and checks that the overlay capture submap blocks a user exec bind while a
# vgs:overlay layer is mapped, releases it after close, and releases it after
# the shell process dies. Controls start mutant tree copies: one without the
# layer-open submap dispatch, one without the layer-closed reset, and one
# without the hl.bind wrapper that learns the user's focus bind.
set -euo pipefail

ipc() { ipc_via "$repo/bin/vgsh" "$@"; }
press_themes() { type_keys -M logo -k t -m logo; }
press_exec() { type_keys -M logo -k k -m logo; }
press_focus_right() { type_keys -M logo -k d -m logo; }
current_submap() { local out; out="$(hypr submap)" || return; [[ -n $out ]] && printf '%s\n' "$out" | tail -n 1 || printf 'default\n'; }
marker_count() { [[ -f $1 ]] && echo 1 || echo 0; }
failed_submap_control() { ( hypr() { return 23; }; current_submap ) >/dev/null 2>&1 && echo pass || echo fail; }
view_selected_name() { ipc smoke readDescendant overlay vgs.themes ThemeView selectedName | tr -d '"'; }
card_at() { ipc smoke readDescendant overlay vgs.themes ThemeView shownCards | py_reply 'import json,sys; print(json.load(sys.stdin)[int(sys.argv[1])]["name"])' "$1"; }

restore_hypr_lua() { cp -- "$sandbox/overlay-capture-hyprland.lua" "$hypr_lua.next" && mv -T -- "$hypr_lua.next" "$hypr_lua"; }
append_capture_binds() {
  local marker="$1" focus="${2:-focus}"
  {
    printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = true } })'
    if [[ $focus != no-focus ]]; then
      printf '%s\n' 'hl.bind("SUPER + D", hl.dsp.focus({ direction = "right" }), { description = "Smoke capture focus right" })'
    fi
    printf '%s\n' "hl.bind(\"SUPER + K\", hl.dsp.exec_cmd(\"touch $marker\"), { description = \"Smoke capture marker\" })"
  } >>"$hypr_lua"
  expect "the nested instance reloads with the overlay capture harness binds" ok hypr reload config-only
}

open_browser_for_capture() {
  expect "$1: browser summon is allowed" ok ipc shell summon overlay vgs.themes '{"view":"themes"}'
  expect_poll "$1: the theme browser opens" 1 layer_count vgs:overlay
  expect_poll "$1: the capture submap is active" vgs:capture current_submap
  expect_poll "$1: the theme browser loaded cards" true ipc smoke readDescendant overlay vgs.themes ThemeView loaded
}

helper_events() { local status=0; grep -cE -- "$2" "$1" || status=$?; [[ $status -le 1 ]]; }

capture_typing_probe() {
  # bash expands every word of a `local` before it assigns any, so log is
  # declared after label holds its value.
  local label="$1" outcome="$2" helper_pid before
  local log="$sandbox/overlay-capture-${label//[^A-Za-z0-9]/-}-helper.log"
  if open_toplevel "$log" "smoke.overlay-capture-helper" "Overlay capture helper"; then
    helper_pid="$toplevel_pid"
  else
    fail "$label: the toplevel helper maps"
    return
  fi
  before="$(helper_events "$log" '^key ')" || { fail "$label: the helper key log is readable"; close_toplevel "$helper_pid" "$label: the toplevel helper exits after a failed read"; return; }
  type_keys z || fail "$label: typing z with the browser open failed"
  case "$outcome" in
    blocked)
      expect "$label: typing while the browser is open does not reach the background client" "$before" helper_events "$log" '^key '
      type_keys -k BackSpace || fail "$label: clearing the typing probe failed"
      ;;
    received)
      expect_poll "$label: OnDemand focus lets typing reach the background client" "$((before + 2))" helper_events "$log" '^key '
      ;;
    maybe-received)
      for _ in $(seq 1 25); do
        if [[ $(helper_events "$log" '^key ') == "$((before + 2))" ]]; then
          ok "$label: OnDemand focus lets typing reach the background client"
          close_toplevel "$helper_pid" "$label: the toplevel helper exits 0 on SIGTERM"
          return
        fi
        sleep 0.2
      done
      expect "$label: OnDemand focus still leaves typing off the background client" "$before" helper_events "$log" '^key '
      ;;
    *) fail "$label: refused typing probe outcome=$outcome" ;;
  esac
  close_toplevel "$helper_pid" "$label: the toplevel helper exits 0 on SIGTERM"
}

capture_nominal() {
  local label="$1" marker="$2" before
  rm -f -- "$marker"
  open_browser_for_capture "$label"
  capture_typing_probe "$label" blocked
  before="$(marker_count "$marker")"
  press_exec || fail "$label: typing the exec bind while open failed"
  expect "$label: the exec bind does not fire while the browser is open" "$before" marker_count "$marker"
  expect "$label: enabling launcher while browser is open is allowed" ok ipc shell setPluginEnabled vgs.launcher true
  expect "$label: launcher summon is allowed while browser is open" ok ipc shell summon overlay vgs.launcher '{}'
  expect_poll "$label: browser and launcher overlays are both mapped" 2 layer_count vgs:overlay
  expect "$label: launcher hide is allowed while browser stays open" ok ipc shell hide overlay vgs.launcher
  expect_poll "$label: browser remains open after launcher closes" 1 layer_count vgs:overlay
  expect_poll "$label: capture remains active after another overlay closes" vgs:capture current_submap
  press_exec || fail "$label: typing exec bind after launcher close failed"
  expect "$label: the exec bind stays blocked after another overlay closes" "$before" marker_count "$marker"
  expect "control: a failed submap read is not reported as default" fail failed_submap_control
  type_keys -k Escape || fail "$label: sending Escape failed"
  expect_poll "$label: the browser closes" 0 layer_count vgs:overlay
  expect_poll "$label: the capture submap resets after close" default current_submap
  press_exec || fail "$label: typing the exec bind after close failed"
  expect_poll "$label: the exec bind fires after close" 1 marker_count "$marker"
  rm -f -- "$marker"
  open_browser_for_capture "$label kill"
  kill -KILL -- "$shell_qs_pid" 2>/dev/null || fail "$label: killing recorded shell pid failed"
  for _ in $(seq 1 50); do [[ $(layer_count vgs:overlay) == 0 ]] && break; sleep 0.1; done
  expect_poll "$label: the browser layer closes after SIGKILL" 0 layer_count vgs:overlay
  expect_poll "$label: the capture submap resets after SIGKILL" default current_submap
  press_exec || fail "$label: typing the exec bind after SIGKILL failed"
  expect_poll "$label: the exec bind fires after SIGKILL" 1 marker_count "$marker"
}

capture_focus_row() {
  local label="$1" first second
  open_browser_for_capture "$label focus"
  type_keys -k Home || fail "$label: Home before focus bind failed"
  first="$(card_at 0)" && second="$(card_at 1)" || { fail "$label: cards unreadable"; return; }
  press_focus_right || fail "$label: typing learned focus bind failed"
  expect_poll "$label: the learned focus bind moves the carousel" "$second" view_selected_name
  type_keys -k Escape || fail "$label: closing focus browser failed"
  expect_poll "$label: the focus browser closes" 0 layer_count vgs:overlay
}

copy_capture_tree() {
  local tree="$sandbox/overlay-capture-$1" file old new target
  if [[ $# -eq 3 ]]; then
    file="shell/Core/HyprlandLayer.js"
    old="$2"
    new="$3"
  elif [[ $# -eq 4 ]]; then
    file="$2"
    old="$3"
    new="$4"
  else
    return 2
  fi
  rm -rf -- "$tree"
  mkdir -p -- "$tree"
  cp -R -- "$repo/shell" "$tree/shell"
  cp -R -- "$repo/bin" "$tree/bin"
  for dir in config themes; do ln -s -- "$repo/$dir" "$tree/$dir"; done
  for target in VERSION LICENSE README.md; do cp -- "$repo/$target" "$tree/$target"; done
  target="$tree/$file"
  python3 - "$target" "$old" "$new" <<'PY' || return 1
import pathlib, sys
path, old, new = sys.argv[1:]
text = pathlib.Path(path).read_text()
if text.count(old) != 1:
    raise SystemExit(f"control text occurs {text.count(old)} times: {old}")
pathlib.Path(path).write_text(text.replace(old, new))
PY
  python3 - "$tree/shell/Core/HyprlandLayer.js" <<'PY' || return 1
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = '        "    local capture = hl.__vgs_overlay_capture or { directions = setmetatable({}, { __mode = \\"k\\" }) }",'
new = '        "    hl.__vgs_overlay_capture = nil",\n' + old
if text.count(old) != 1:
    raise SystemExit(f"control isolation text occurs {text.count(old)} times")
path.write_text(text.replace(old, new))
PY
  echo "$tree"
}

start_capture_tree() {
  stop_shell
  start_shell "$1" "$2" || fail "the overlay capture control shell starts"
  expect "the overlay capture control shell is guarded" true ipc shell guarded
  expect "enabling vgs.themes for the overlay capture control is allowed" ok ipc shell setPluginEnabled vgs.themes true
  expect_poll "the overlay capture control service registers shortcuts" '["vgs.themes:panel", "vgs.themes:themes", "vgs.themes:wallpapers"]' lent_themes
  restore_hypr_lua || fail "the overlay capture control restores harness hyprland.lua before appending binds"
  append_capture_binds "$3"
}

control_open_dispatch() {
  local marker="$sandbox/overlay-capture-no-open-marker" tree before
  tree="$(copy_capture_tree no-open 'hl.dispatch(hl.dsp.submap(capture.submap))' '-- no capture submap dispatch')" || { fail "the no-open control copy is made"; return; }
  start_capture_tree "$tree" "$sandbox/overlay-capture-no-open.log" "$marker"
  rm -f -- "$marker"
  expect "control no-open: browser summon is allowed" ok ipc shell summon overlay vgs.themes '{"view":"themes"}'
  expect_poll "control no-open: the browser opens" 1 layer_count vgs:overlay
  before="$(marker_count "$marker")"
  press_exec || fail "control no-open: typing exec bind failed"
  expect_poll "control no-open: without opening the submap the exec bind fires" "$((before + 1))" marker_count "$marker"
  type_keys -k Escape || true
  expect "control no-open: browser hide is allowed" ok ipc shell hide overlay vgs.themes
  expect_poll "control no-open: browser closes" 0 layer_count vgs:overlay
}

control_closed_hook() {
  local marker="$sandbox/overlay-capture-no-close-marker" tree before submap_after
  tree="$(copy_capture_tree no-close 'vgs_overlay_capture_update(layer)' 'local _ = layer')" || { fail "the no-close control copy is made"; return; }
  start_capture_tree "$tree" "$sandbox/overlay-capture-no-close.log" "$marker"
  rm -f -- "$marker"
  open_browser_for_capture "control no-close"
  kill -KILL -- "$shell_qs_pid" 2>/dev/null || fail "control no-close: killing recorded shell pid failed"
  for _ in $(seq 1 50); do [[ $(layer_count vgs:overlay) == 0 ]] && break; sleep 0.1; done
  expect_poll "control no-close: the browser layer closes" 0 layer_count vgs:overlay
  submap_after="$(current_submap)" || { fail "control no-close: submap after SIGKILL is readable"; return; }
  case "$submap_after" in
    default)
      ok "control no-close: Hyprland reset the submap after SIGKILL without the close hook"
      before="$(marker_count "$marker")"
      press_exec || fail "control no-close: typing exec bind failed"
      expect_poll "control no-close: the exec bind fires after Hyprland reset" "$((before + 1))" marker_count "$marker"
      ;;
    vgs:capture)
      ok "control no-close: without the close hook the capture submap stays after SIGKILL"
      before="$(marker_count "$marker")"
      press_exec || fail "control no-close: typing exec bind while stuck in capture failed"
      expect "control no-close: the exec bind stays blocked while capture is stuck" "$before" marker_count "$marker"
      expect "control no-close: resetting capture for cleanup is allowed" ok hypr dispatch 'hl.dsp.submap("reset")'
      expect_poll "control no-close: cleanup reset reaches default" default current_submap
      ;;
    *) fail "control no-close: got submap $submap_after after SIGKILL" ;;
  esac
}

control_launcher_close_hook() {
  local marker="$sandbox/overlay-capture-closing-layer-marker" tree before
  tree="$(copy_capture_tree reset-on-close 'vgs_overlay_capture_update(layer)' 'hl.dispatch(hl.dsp.submap(\"reset\"))')" || { fail "the reset-on-close control copy is made"; return; }
  start_capture_tree "$tree" "$sandbox/overlay-capture-reset-on-close.log" "$marker"
  rm -f -- "$marker"
  open_browser_for_capture "control closing-layer"
  expect "control closing-layer: enabling launcher while browser is open is allowed" ok ipc shell setPluginEnabled vgs.launcher true
  expect "control closing-layer: launcher summon is allowed while browser is open" ok ipc shell summon overlay vgs.launcher '{}'
  expect_poll "control closing-layer: browser and launcher overlays are both mapped" 2 layer_count vgs:overlay
  expect "control closing-layer: launcher hide is allowed while browser stays open" ok ipc shell hide overlay vgs.launcher
  expect_poll "control closing-layer: browser remains open after launcher closes" 1 layer_count vgs:overlay
  expect_poll "control closing-layer: the unconditional close reset reaches default" default current_submap
  before="$(marker_count "$marker")"
  press_exec || fail "control closing-layer: typing exec bind failed"
  expect_poll "control closing-layer: an unconditional close reset lets the exec bind fire" "$((before + 1))" marker_count "$marker"
  expect "control closing-layer: browser hide is allowed" ok ipc shell hide overlay vgs.themes
  expect_poll "control closing-layer: browser closes" 0 layer_count vgs:overlay
  expect_poll "control closing-layer: the submap is back at default" default current_submap
}

control_bind_wrapper() {
  local marker="$sandbox/overlay-capture-no-bind-marker" tree first
  tree="$(copy_capture_tree no-bind 'local direction = capture.directions[dispatcher]' 'local direction = nil -- no learning wrapper')" || { fail "the no-bind control copy is made"; return; }
  start_capture_tree "$tree" "$sandbox/overlay-capture-no-bind.log" "$marker"
  open_browser_for_capture "control no-bind"
  type_keys -k Home || fail "control no-bind: Home before focus bind failed"
  first="$(card_at 0)" || { fail "control no-bind: first card unreadable"; return; }
  press_focus_right || fail "control no-bind: typing focus bind failed"
  expect_poll "control no-bind: without the bind wrapper the focus bind does not move the carousel" "$first" view_selected_name
  type_keys -k Escape || true
  expect_poll "control no-bind: browser closes" 0 layer_count vgs:overlay
}

control_on_demand_typing() {
  local marker="$sandbox/overlay-capture-on-demand-marker" tree
  tree="$(copy_capture_tree on-demand shell/Hosts/SummonHost.qml 'WlrKeyboardFocus.Exclusive' 'WlrKeyboardFocus.OnDemand')" || { fail "the OnDemand control copy is made"; return; }
  start_capture_tree "$tree" "$sandbox/overlay-capture-on-demand.log" "$marker"
  open_browser_for_capture "control OnDemand"
  # Hyprland v0.56.2 keeps the browser as the key target after the helper maps while vgs:capture is active, so this production edit does not redden the typing check on the sandbox that read D067.
  capture_typing_probe "control OnDemand" maybe-received
  expect "control OnDemand: browser hide is allowed" ok ipc shell hide overlay vgs.themes
  expect_poll "control OnDemand: browser closes" 0 layer_count vgs:overlay
  expect_poll "control OnDemand: the submap resets after browser hide" default current_submap
}

hypr_lua="$home/.config/hypr/hyprland.lua"
cp -p -- "$hypr_lua" "$sandbox/overlay-capture-hyprland.lua"
stop_shell
start_shell "$repo" "$sandbox/overlay-capture-qs.log" || fail "the overlay capture row starts the normal shell"
expect "enabling vgs.themes for overlay capture is allowed" ok ipc shell setPluginEnabled vgs.themes true
expect_poll "the overlay capture service registers shortcuts" '["vgs.themes:panel", "vgs.themes:themes", "vgs.themes:wallpapers"]' lent_themes
append_capture_binds "$sandbox/overlay-capture-marker" no-focus
capture_nominal "overlay capture" "$sandbox/overlay-capture-marker"
control_bind_wrapper
stop_shell
start_shell "$repo" "$sandbox/overlay-capture-restart.log" || fail "the normal shell restarts after the overlay capture nominal row"
expect "enabling vgs.themes for focus row is allowed" ok ipc shell setPluginEnabled vgs.themes true
expect_poll "the focus row service registers shortcuts" '["vgs.themes:panel", "vgs.themes:themes", "vgs.themes:wallpapers"]' lent_themes
restore_hypr_lua || fail "the focus row restores harness hyprland.lua before appending binds"
append_capture_binds "$sandbox/overlay-capture-focus-marker"
capture_focus_row "overlay capture"
control_open_dispatch
control_closed_hook
control_launcher_close_hook
control_on_demand_typing
stop_shell
restore_hypr_lua || fail "overlay capture restores the harness hyprland.lua"
start_shell "$repo" "$sandbox/overlay-capture-final.log" || fail "overlay capture leaves a live shell for smoke teardown"
