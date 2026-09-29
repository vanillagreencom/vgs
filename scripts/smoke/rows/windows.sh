# Application windows: the Settings window, vgs.settings' `window` kind,
# is a Hyprland window. The nested instance lists it among its clients
# with the shell's class and the title Settings, floats it and centres it
# through the Hyprland layer's `vgs:window` rule, draws its border at the
# configured size in the active colour while it is focused and in the
# inactive colour while another window is, moves it, tiles it and focuses
# it on a dispatch, and routes the keyboard to whichever window it focused.
# The other window is the harness's toplevel helper, which prints each
# keyboard event it receives. Every reading comes from the nested
# instance: `clients -j`, `activewindow -j`, a pixel of its output and the
# helper's log. The gallery, a panel the host draws as a layer surface, is
# each row's control: it is no client, its edge draws no border and a
# dispatch aimed at it moves nothing. The row enables the Settings plugin
# and leaves it disabled, hyprland.lua as it found it and no window open.
set -euo pipefail
windows_lua="$home/.config/hypr/hyprland.lua"
cp -- "$windows_lua" "$sandbox/hyprland-before-windows.lua"
restore_windows_lua() { cp -- "$sandbox/hyprland-before-windows.lua" "$windows_lua.next" && mv -T -- "$windows_lua.next" "$windows_lua"; }
# The titles of the shell process's clients, sorted.
shell_clients() { hypr -j clients | python3 -c 'import json,sys; print(json.dumps(sorted(c["title"] for c in json.load(sys.stdin) if c["pid"] == int(sys.argv[1]))))' "$shell_pid"; }
# `centred` when the one Settings window's centre lies within 1 px of its
# monitor's work area centre, the monitor's box less its reserved space and
# general:float_gaps, where Hyprland v0.56.2 centres a floating window
# (docs/architecture/runtime.md § Hyprland); else both centres.
window_centred() {
  local clients monitors gaps
  clients="$(hypr -j clients)" && monitors="$(hypr -j monitors)" && gaps="$(hypr -j getoption general:float_gaps)" || return 1
  python3 -c '
import json, sys
clients, monitors, gaps = (json.loads(a) for a in sys.argv[1:4])
cs = [c for c in clients if c["class"] == sys.argv[4] and c["title"] == "Settings" and c["mapped"]]
if len(cs) != 1: print("windows=%d" % len(cs)); sys.exit()
c = cs[0]
m = next(m for m in monitors if m["id"] == c["monitor"])
top, right, bottom, left = (int(v) for v in gaps["css"].split())
rl, rt, rr, rb = m["reserved"]
area_x = (m["x"] + rl + left + m["x"] + m["width"] / m["scale"] - rr - right) / 2
area_y = (m["y"] + rt + top + m["y"] + m["height"] / m["scale"] - rb - bottom) / 2
at_x, at_y = c["at"][0] + c["size"][0] / 2, c["at"][1] + c["size"][1] / 2
print("centred" if abs(at_x - area_x) <= 1 and abs(at_y - area_y) <= 1 else "centre=%g,%g work-area-centre=%g,%g" % (at_x, at_y, area_x, area_y))' "$clients" "$monitors" "$gaps" "$shell_class"
}
settings_address() { window_of Settings address | python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t)[0] if t.startswith("[") else t)'; }
settings_search() { ipc smoke readDescendant window vgs.settings TextField text; }

# The toplevel helper beside Settings, of a class no rule floats. Its log
# holds `mapped`, then its keyboard events.
other_pid=""
other_log="$sandbox/toplevel-windows.log"
open_other() {
  spawn "$other_log" "${shell_env[@]}" "$sandbox/toplevel" smoke.other "Other window"
  other_pid="$spawn_pid"
  for _ in $(seq 1 25); do
    grep -qxF -- "mapped smoke.other" "$other_log" && return 0
    kill -0 -- "$other_pid" 2>/dev/null || break
    sleep 0.2
  done
  cat -- "$other_log" >&2
  return 1
}
close_other() {
  local status=0
  kill -TERM -- "$other_pid" 2>/dev/null || true
  for _ in $(seq 1 25); do kill -0 -- "$other_pid" 2>/dev/null || break; sleep 0.2; done
  if kill -0 -- "$other_pid" 2>/dev/null; then kill -KILL -- "$other_pid" 2>/dev/null || true; fi
  wait "$other_pid" || status=$?
  if [[ $status -eq 0 ]]; then ok "$1"; else fail "$1: exit=$status"; fi
}
other_address() { hypr -j clients | python3 -c 'import json,sys; cs=[c["address"] for c in json.load(sys.stdin) if c["pid"] == int(sys.argv[1])]; print(cs[0] if len(cs) == 1 else "clients=%d" % len(cs))' "$other_pid"; }
# How many lines of the helper's log match PATTERN, a grep -E pattern.
other_events() { local status=0; grep -cE -- "$1" "$other_log" || status=$?; [[ $status -le 1 ]]; }

# (a) The window is a client of the shell's class, titled with the
# plugin's name, floating and centred; the gallery beside it is no client.
expect "enabling the Settings plugin for the window rows is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "the Settings service is built for the window rows" True record_exists vgs.settings
expect "the IPC opens the Settings window" ok ipc shell summon window vgs.settings '{}'
expect_poll "Settings is one client of the shell's class titled Settings" 1 window_count Settings
expect_poll "the Settings window floats" '[true]' window_of Settings floating
geometry expect_poll "the Settings window is centred on its monitor's work area" centred window_centred
expect "the gallery, a layer panel, opens beside it" ok ipc shell summon panel vgs.gallery '{}'
expect_poll "the gallery maps one layer surface" 1 layer_count vgs:panel
expect "the shell's only client is the Settings window, not the gallery" '["Settings"]' shell_clients
# The gallery can hold the keyboard, which a newly mapped window then does
# not take, so it is closed until the control rows at the end.
expect "hiding the gallery before the focus rows is allowed" ok ipc shell hide panel vgs.gallery
expect_poll "the gallery's surface is gone before the focus rows" 0 layer_count vgs:panel

# The float comes from the layer's rule: disabled by name after the line,
# the rule floats nothing and a new Settings window tiles.
expect "hiding the Settings window for the rule control is allowed" ok ipc shell hide window vgs.settings
expect_poll "the Settings window is gone" 0 window_count Settings
printf '%s\n' 'hl.window_rule({ name = "vgs:window", enabled = false })' >>"$windows_lua"
expect "the nested instance reloads with vgs:window disabled" ok hypr reload config-only
expect "the IPC opens the Settings window with the rule disabled" ok ipc shell summon window vgs.settings '{}'
expect_poll "with vgs:window disabled the Settings window tiles" '[false]' window_of Settings floating
expect "hiding the tiled Settings window is allowed" ok ipc shell hide window vgs.settings
expect_poll "the tiled Settings window is gone" 0 window_count Settings
restore_windows_lua || fail "hyprland.lua is put back after the rule control"

# (b) The border: a size and two colours the sandbox sets after the line,
# read at the middle of the window's left edge, where rounding reaches
# nothing. Hyprland draws the border outside the window's box.
printf '%s\n' 'hl.config({ general = { border_size = 4, col = { active_border = "rgba(ff0000ff)", inactive_border = "rgba(0000ffff)" } }, decoration = { rounding = 0 } })' >>"$windows_lua"
expect "the nested instance reloads with the row's border" ok hypr reload config-only
border_size() { hypr -j getoption general:border_size | python3 -c 'import json,sys; print(json.load(sys.stdin)["int"])'; }
expect "the row's border size is set" 4 border_size
expect "the IPC opens the Settings window for the border rows" ok ipc shell summon window vgs.settings '{}'
expect_poll "the Settings window is focused" "[\"$shell_class\", \"Settings\"]" active_window
# edge_pixels LEFT_OFFSETS...: the colour at each offset left of the one
# Settings window's box, at the height of its middle.
edge_pixels() {
  local box x y colours=() offset colour
  box="$(one_window Settings)" && [[ $box == \[* ]] || { echo "$box"; return; }
  read -r x y < <(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); print(b[0], b[1] + b[3] // 2)' "$box")
  for offset; do colour="$(pixel "$((x - offset))" "$y")" || { echo "$colour"; return; }; colours+=("$colour"); done
  echo "${colours[*]}"
}
render expect_poll "the focused window's border is 4 px of the active colour" "ff0000 ff0000 ff0000 ff0000" edge_pixels 1 2 3 4
# past_border: `none` when the pixel one past the border's size shows
# neither border colour, else what it shows.
past_border() { edge_pixels 5 | python3 -c 'import sys; c=sys.stdin.read().strip(); print("none" if c not in ("ff0000", "0000ff") else c)'; }
render expect "the border ends at its size" none past_border
if open_other; then
  expect_poll "the new window takes the focus" '["smoke.other", "Other window"]' active_window
  render expect_poll "the unfocused window's border is 4 px of the inactive colour" "0000ff 0000ff 0000ff 0000ff" edge_pixels 1 2 3 4

  # (c) Dispatches act on the window: a move by 40, 30, a float toggle
  # each way and focus, each read back from the nested instance.
  if address="$(settings_address)" && [[ $address == 0x* ]]; then
    at_before="$(window_of Settings at)"
    # moved: how far the window's top-left moved since at_before, as
    # [dx, dy], or what window_of answered.
    moved() {
      local now
      now="$(window_of Settings at)" && [[ $now == \[* ]] || { echo "$now"; return; }
      python3 -c 'import json,sys; a=json.loads(sys.argv[1])[0]; b=json.loads(sys.argv[2])[0]; print(json.dumps([b[0] - a[0], b[1] - a[1]]))' "$at_before" "$now"
    }
    expect "a move dispatch aimed at the window answers ok" ok hypr dispatch "hl.dsp.window.move({ x = 40, y = 30, relative = true, window = \"address:$address\" })"
    geometry expect_poll "the move dispatch moved the window by 40, 30" '[40, 30]' moved
    expect "a float toggle aimed at the window answers ok" ok hypr dispatch "hl.dsp.window.float({ action = \"toggle\", window = \"address:$address\" })"
    expect_poll "the float toggle tiles the window" '[false]' window_of Settings floating
    expect "a second float toggle answers ok" ok hypr dispatch "hl.dsp.window.float({ action = \"toggle\", window = \"address:$address\" })"
    expect_poll "the second float toggle floats it again" '[true]' window_of Settings floating
    other="$(other_address)"
    expect "a focus dispatch aimed at the other window answers ok" ok hypr dispatch "hl.dsp.focus({ window = \"address:$other\" })"
    expect_poll "the focus dispatch focused the other window" '["smoke.other", "Other window"]' active_window
    expect "a focus dispatch aimed at the Settings window answers ok" ok hypr dispatch "hl.dsp.focus({ window = \"address:$address\" })"
    expect_poll "the focus dispatch focused the Settings window" "[\"$shell_class\", \"Settings\"]" active_window

    # (d) The keyboard goes to the focused window alone. With Settings
    # focused, typed letters reach its search field and the helper gets no
    # key; once the helper is focused, the next letter reaches the helper
    # and the field keeps its text.
    expect_poll "the Settings search field takes the keyboard" true ipc smoke activeFocusIn window vgs.settings
    keys_before="$(other_events '^key ')"
    type_keys zz || fail "typing into the Settings window failed"
    expect_poll "keys typed with Settings focused reach its search field" '"zz"' settings_search
    expect "keys typed with Settings focused never reach the other window" "$keys_before" other_events '^key '
    enters_before="$(other_events '^keyboard enter$')"
    expect "a focus dispatch gives the other window the keyboard" ok hypr dispatch "hl.dsp.focus({ window = \"address:$other\" })"
    expect_poll "the other window reports the keyboard entering it" "$((enters_before + 1))" other_events '^keyboard enter$'
    type_keys q || fail "typing into the other window failed"
    expect_poll "a key typed once the other window is focused reaches it" "$((keys_before + 2))" other_events '^key '
    expect "the Settings search field kept its text" '"zz"' settings_search
    expect "a focus dispatch gives Settings the keyboard back" ok hypr dispatch "hl.dsp.focus({ window = \"address:$address\" })"
    expect_poll "Settings is focused again" "[\"$shell_class\", \"Settings\"]" active_window
    type_keys -k BackSpace -k BackSpace || fail "clearing the Settings search failed"
    expect_poll "the Settings search field is empty again" '""' settings_search

    # A close through Hyprland, as its killactive key sends, closes the
    # window and the host drops the instance.
    expect "a close dispatch aimed at the window answers ok" ok hypr dispatch "hl.dsp.window.close({ window = \"address:$address\" })"
    expect_poll "the close dispatch closed the Settings window" 0 window_count Settings
    expect_poll "the host dropped the closed window's instance" absent ipc smoke readInstance window vgs.settings page
  else
    fail "the Settings window's address is unreadable: ${address:-}"
  fi
  close_other "the other window's helper exits 0 on SIGTERM"
else
  fail "the toplevel helper maps the other window"
fi

# Controls: under the same border settings the gallery's layer edge draws
# neither border colour, and a move aimed at the gallery's title reaches no
# window and leaves its layer where it was.
expect "the gallery opens for the control rows" ok ipc shell summon panel vgs.gallery '{}'
expect_poll "the gallery maps one layer surface for the control rows" 1 layer_count vgs:panel
gallery_edge() {
  local box x y
  box="$(one_layer vgs:panel)" && [[ $box == \[* ]] || { echo "$box"; return; }
  read -r x y < <(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); print(b[0] - 2, b[1] + b[3] // 2)' "$box")
  pixel "$x" "$y" | python3 -c 'import sys; c=sys.stdin.read().strip(); print("none" if c not in ("ff0000", "0000ff") else c)'
}
render expect "the gallery's layer edge draws no window border" none gallery_edge
gallery_before="$(layers_of vgs:panel)"
hypr dispatch 'hl.dsp.window.move({ x = 40, y = 30, relative = true, window = "title:^Gallery$" })' >/dev/null || true
geometry expect "a move aimed at the gallery moves no layer" "$gallery_before" layers_of vgs:panel
expect "hiding the gallery after the window rows is allowed" ok ipc shell hide panel vgs.gallery
expect_poll "the gallery's surface is gone after the window rows" 0 layer_count vgs:panel
restore_windows_lua || fail "hyprland.lua is put back after the window rows"
expect "the nested instance reloads hyprland.lua as the row found it" ok hypr reload config-only
expect "disabling the Settings plugin after the window rows is allowed" ok ipc shell setPluginEnabled vgs.settings false
