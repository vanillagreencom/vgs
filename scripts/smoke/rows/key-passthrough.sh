# Key capture pass-through, D086, after rows/key-capture.sh, whose harness
# binds and Settings window it keeps. Every way a capture ends leaves the
# nested Hyprland's vgs:passthrough submap, read through `hyprctl submap`
# of the nested instance alone: a commit, Escape (the submap's own bind),
# a focus loss to a toplevel helper that maps over the window, the window's
# close, the 10 s timeout (still held at 5 s, gone by 14 s, polled every
# 200 ms) and a SIGKILL of the shell, whose window then closes. Each path
# has a control: a tree copy with that exit removed holds the submap past
# the same reading, and the row resets it by hand. The commit control drops
# the owner's leave on commit, the Escape control binds Escape to a no-op,
# the focus control drops the field's focus-loss cancel, the close control
# drops every leave but commit and cancel and the layer's window close
# hook, the timeout control drops the timer's leave, and the SIGKILL
# control drops the close hook. Keys go to the nested seat alone.
set -euo pipefail

kp_hypr_lua="$home/.config/hypr/hyprland.lua"
kp_settings_open() { [[ $(ipc smoke instanceGeometry window vgs.settings) != absent ]] && echo open || echo closed; }

# ARM LABEL: the Settings window on its own page, its Keys row's field
# focused, Return pressed and the submap entered.
kp_arm() {
  expect "$1: Settings is summoned on its own page" ok ipc shell summon window vgs.settings '{"plugin":"vgs.settings"}'
  expect_poll "$1: the Settings window has the keyboard" "[\"$shell_class\", \"Settings\"]" active_window
  expect_poll "$1: the field takes the focus" focused ipc smoke invokeInstance window vgs.settings focusKeyField "$key_field_arg"
  type_keys -k Return || fail "$1: Return on the field failed"
  expect_poll "$1: Return starts a capture" true key_field capturing
  expect_poll "$1: the capture enters the pass-through submap" vgs:passthrough key_submap
}
# HELD LABEL: a control's reading, the submap still held a second after
# its exit, then reset by hand.
kp_held() {
  sleep 1 # the exit's own leave lands within a few ms of it; a second covers a loaded host.
  expect "$1: the submap stays vgs:passthrough without that exit" vgs:passthrough key_submap
  expect "$1: resetting the submap for cleanup is allowed" ok hypr dispatch 'hl.dsp.submap("reset")'
  expect_poll "$1: the cleanup reset reaches the default map" default key_submap
}
# A commit of the key in effect, SUPER+M, which leaves the layer's text
# as it was: a key that changes it reloads Hyprland, and the layer's run
# leaves the submap too.
kp_commit() {
  kp_arm "$1"
  type_keys -M logo -k m -m logo || fail "$1: typing SUPER+M failed"
  expect_poll "$1: the captured key is stored" '"SUPER+M"' settings_key
}
kp_escape() {
  kp_arm "$1"
  type_keys -k Escape || fail "$1: Escape failed"
}
kp_focus() {
  local log="$sandbox/key-passthrough-${1//[^A-Za-z0-9]/-}-helper.log"
  kp_arm "$1"
  if open_toplevel "$log" smoke.key-passthrough-helper "Key passthrough helper"; then
    kp_helper_pid="$toplevel_pid"
    expect_poll "$1: the helper takes the keyboard" '["smoke.key-passthrough-helper", "Key passthrough helper"]' active_window
  else
    fail "$1: the toplevel helper maps"
    kp_helper_pid=""
  fi
}
kp_focus_done() {
  [[ -z $kp_helper_pid ]] || close_toplevel "$kp_helper_pid" "$1: the toplevel helper exits 0 on SIGTERM"
}
kp_close() {
  kp_arm "$1"
  expect "$1: the Settings window is hidden" ok ipc shell hide window vgs.settings
  expect_poll "$1: the Settings window closes" closed kp_settings_open
}
kp_timeout() {
  kp_arm "$1"
  sleep 5 # the 10 s timer has not fired yet.
  expect "$1: the submap is held 5 s into the capture" vgs:passthrough key_submap
}
kp_kill() {
  kp_arm "$1"
  kp_killed="$shell_qs_pid"
  kill -KILL -- "$kp_killed" 2>/dev/null || fail "$1: killing the recorded shell pid failed"
  expect_poll "$1: the Settings window is gone with its shell" 0 window_count Settings
}
# CONTROL NAME LABEL: start the tree copy NAME, whose edits are made.
kp_control_start() {
  stop_shell
  start_shell "$sandbox/tree-$1" "$sandbox/key-passthrough-$1.log" || fail "$2: the control shell starts"
  expect_poll "$2: the Settings service is built" True record_exists vgs.settings
}

# The nominal paths, on the shell rows/key-capture.sh left.
kp_commit "commit"
expect_poll "commit: the commit leaves the submap" default key_submap
key_reset "commit"

kp_escape "Escape"
expect_poll "Escape: Hyprland's Escape bind leaves the submap" default key_submap
expect_poll "Escape: the field sees the capture end" false key_field capturing
expect "Escape: no key is stored" absent settings_key

kp_focus "focus loss"
expect_poll "focus loss: the focus loss leaves the submap" default key_submap
kp_focus_done "focus loss"

kp_close "close"
expect_poll "close: the window's close leaves the submap" default key_submap

kp_timeout "timeout"
for _ in $(seq 1 45); do [[ $(key_submap) == default ]] && break; sleep 0.2; done
expect "timeout: the timer leaves the submap by 14 s" default key_submap
expect_poll "timeout: the field sees the capture end" false key_field capturing

kp_kill "SIGKILL"
expect_poll "SIGKILL: the window close hook leaves the submap" default key_submap
adopt_shell "$kp_killed" || fail "SIGKILL: the runner starts the shell again"

# The controls, each a tree copy without that exit.
if copy_tree kp-commit && edit_tree kp-commit shell/Core/KeyCapture.qml 'reason !== "compositor") Compositor.passthrough("leave");' 'reason !== "compositor" && reason !== "commit") Compositor.passthrough("leave");'; then
  kp_control_start kp-commit "control commit"
  kp_commit "control commit"
  kp_held "control commit"
  key_reset "control commit"
fi
if copy_tree kp-escape && edit_tree kp-escape shell/Core/HyprlandLayer.js '", hl.dsp.submap(\"reset\"), { description = \"" + p.description' '", hl.dsp.exec_cmd(\"true\"), { description = \"" + p.description'; then
  kp_control_start kp-escape "control Escape"
  kp_escape "control Escape"
  kp_held "control Escape"
fi
if copy_tree kp-focus && edit_tree kp-focus shell/Ui/controls/ShortcutField.qml 'onActiveFocusChanged: if (!activeFocus) root.stop("focus")' 'onActiveFocusChanged: {}'; then
  kp_control_start kp-focus "control focus loss"
  kp_focus "control focus loss"
  kp_held "control focus loss"
  kp_focus_done "control focus loss"
fi
if copy_tree kp-close && edit_tree kp-close shell/Core/KeyCapture.qml 'reason !== "compositor") Compositor.passthrough("leave");' '(reason === "commit" || reason === "cancel")) Compositor.passthrough("leave");' \
  && edit_tree kp-close shell/Core/HyprlandLayer.js 'then passthrough.leave() end",' 'then local _ = passthrough end",'; then
  kp_control_start kp-close "control close"
  kp_close "control close"
  kp_held "control close"
fi
if copy_tree kp-timeout && edit_tree kp-timeout shell/Core/HyprlandLayer.js $'        "        passthrough.timer:set_enabled(false)",\n        "        passthrough.leave()",' $'        "        passthrough.timer:set_enabled(false)",'; then
  kp_control_start kp-timeout "control timeout"
  kp_timeout "control timeout"
  sleep 9 # past the 10 s timer, as the nominal reading waits.
  kp_held "control timeout"
fi
if copy_tree kp-kill && edit_tree kp-kill shell/Core/HyprlandLayer.js 'then passthrough.leave() end",' 'then local _ = passthrough end",'; then
  kp_control_start kp-kill "control SIGKILL"
  kp_kill "control SIGKILL"
  kp_held "control SIGKILL"
  adopt_shell "$kp_killed" || fail "control SIGKILL: the runner starts the shell again"
fi

stop_shell
cp -- "$sandbox/key-capture-hyprland.lua" "$kp_hypr_lua.next" && mv -T -- "$kp_hypr_lua.next" "$kp_hypr_lua" || fail "key passthrough restores the harness hyprland.lua"
start_shell "$repo" "$sandbox/key-passthrough-final.log" || fail "key passthrough leaves a live shell for the rows after it"
expect "the nested instance reloads the harness hyprland.lua" ok hypr reload config-only
expect "disabling the Settings plugin after the key rows is allowed" ok ipc shell setPluginEnabled vgs.settings false
