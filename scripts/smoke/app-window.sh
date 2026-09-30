# Sourced by harness.sh. The readings every application window passes, the
# summon host's `window` kind (D044): rows/windows.sh runs them on
# Settings, rows/devtools.sh on Dev Tools and rows/gallery.sh on the
# Gallery. Every reading comes from the nested instance: `clients -j`,
# `activewindow -j`, a pixel of its output and the toplevel helper's
# keyboard log.

# open_toplevel LOG APP_ID TITLE: the toplevel helper mapped as a window
# of class APP_ID, its pid left in toplevel_pid; 1, with its log on
# stderr, when it does not map within 5 s. Its log holds `mapped`, then
# each keyboard event it receives. close_toplevel PID LABEL: that helper
# stopped, LABEL passing when it exits 0 on SIGTERM.
toplevel_pid=""
open_toplevel() { # LOG APP_ID TITLE
  spawn "$1" "${shell_env[@]}" "$sandbox/toplevel" "$2" "$3"
  toplevel_pid="$spawn_pid"
  for _ in $(seq 1 25); do
    grep -qxF -- "mapped $2" "$1" && return 0
    kill -0 -- "$toplevel_pid" 2>/dev/null || break
    sleep 0.2
  done
  cat -- "$1" >&2
  return 1
}
close_toplevel() { # PID LABEL
  local status=0
  kill -TERM -- "$1" 2>/dev/null || true
  for _ in $(seq 1 25); do kill -0 -- "$1" 2>/dev/null || break; sleep 0.2; done
  if kill -0 -- "$1" 2>/dev/null; then kill -KILL -- "$1" 2>/dev/null || true; fi
  wait "$1" || status=$?
  if [[ $status -eq 0 ]]; then ok "$2"; else fail "$2: exit=$status"; fi
}

# The toplevel helper beside a window, of a class no rule floats, so it
# tiles under the floating window.
other_pid=""
other_log=""
open_other() { # LOG
  other_log="$1"
  open_toplevel "$other_log" smoke.other "Other window" || return 1
  other_pid="$toplevel_pid"
}
close_other() { close_toplevel "$other_pid" "$1"; } # LABEL
# toplevel_address PID: the address of the one window PID maps, or
# clients=<n>.
toplevel_address() { hypr -j clients | python3 -c 'import json,sys; cs=[c["address"] for c in json.load(sys.stdin) if c["pid"] == int(sys.argv[1])]; print(cs[0] if len(cs) == 1 else "clients=%d" % len(cs))' "$1"; }
other_address() { toplevel_address "$other_pid"; }
# How many lines of the helper's log match PATTERN, a grep -E pattern.
other_events() { local status=0; grep -cE -- "$1" "$other_log" || status=$?; [[ $status -le 1 ]]; }

# The address of the one shell window titled TITLE, or windows=<n>.
window_address() { window_of "$1" address | python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t)[0] if t.startswith("[") else t)'; }
# `centred` when the one shell window titled TITLE has its centre within
# 1 px of its monitor's work area centre, the monitor's box less its
# reserved space and general:float_gaps, where Hyprland v0.56.2 centres a
# floating window (docs/architecture/runtime-hyprland.md); else both
# centres.
window_centred() { # TITLE
  local clients monitors gaps
  clients="$(hypr -j clients)" && monitors="$(hypr -j monitors)" && gaps="$(hypr -j getoption general:float_gaps)" || return 1
  python3 -c '
import json, sys
clients, monitors, gaps = (json.loads(a) for a in sys.argv[1:4])
cs = [c for c in clients if c["class"] == sys.argv[4] and c["title"] == sys.argv[5] and c["mapped"]]
if len(cs) != 1: print("windows=%d" % len(cs)); sys.exit()
c = cs[0]
m = next(m for m in monitors if m["id"] == c["monitor"])
top, right, bottom, left = (int(v) for v in gaps["css"].split())
rl, rt, rr, rb = m["reserved"]
area_x = (m["x"] + rl + left + m["x"] + m["width"] / m["scale"] - rr - right) / 2
area_y = (m["y"] + rt + top + m["y"] + m["height"] / m["scale"] - rb - bottom) / 2
at_x, at_y = c["at"][0] + c["size"][0] / 2, c["at"][1] + c["size"][1] / 2
print("centred" if abs(at_x - area_x) <= 1 and abs(at_y - area_y) <= 1 else "centre=%g,%g work-area-centre=%g,%g" % (at_x, at_y, area_x, area_y))' "$clients" "$monitors" "$gaps" "$shell_class" "$1"
}

# The border the readings look for: a size and two colours no theme draws,
# set after the Hyprland layer's line, with no rounding, so the middle of
# a window's left edge shows the border alone. Hyprland draws the border
# outside the window's box. window_border_on appends it to the nested
# instance's hyprland.lua and reloads; window_border_off puts the file back
# as window_border_on found it and reloads.
window_border_lua='hl.config({ general = { border_size = 4, col = { active_border = "rgba(ff0000ff)", inactive_border = "rgba(0000ffff)" } }, decoration = { rounding = 0 } })'
window_border_on() {
  cp -- "$home/.config/hypr/hyprland.lua" "$sandbox/hyprland-before-border.lua"
  printf '%s\n' "$window_border_lua" >>"$home/.config/hypr/hyprland.lua"
  expect "the nested instance reloads with the window rows' border" ok hypr reload config-only
  expect "the window rows' border size is set" 4 window_border_size
}
window_border_off() {
  if cp -- "$sandbox/hyprland-before-border.lua" "$home/.config/hypr/hyprland.lua.next" && mv -T -- "$home/.config/hypr/hyprland.lua.next" "$home/.config/hypr/hyprland.lua"; then
    ok "hyprland.lua is put back after the window rows' border"
  else
    fail "hyprland.lua is put back after the window rows' border"
  fi
  expect "the nested instance reloads without the window rows' border" ok hypr reload config-only
}
window_border_size() { hypr -j getoption general:border_size | python3 -c 'import json,sys; print(json.load(sys.stdin)["int"])'; }
# edge_pixels TITLE LEFT_OFFSETS...: the colour at each offset left of the
# one shell window titled TITLE, at the height of its middle.
edge_pixels() {
  local box x y colours=() offset colour
  box="$(one_window "$1")" && [[ $box == \[* ]] || { echo "$box"; return; }
  shift
  read -r x y < <(python3 -c 'import json,sys; b=json.loads(sys.argv[1]); print(b[0], b[1] + b[3] // 2)' "$box")
  for offset; do colour="$(pixel "$((x - offset))" "$y")" || { echo "$colour"; return; }; colours+=("$colour"); done
  echo "${colours[*]}"
}
# no_border_colour COLOUR: `none` when COLOUR is neither border colour,
# else COLOUR.
no_border_colour() { [[ $1 == ff0000 || $1 == 0000ff ]] && echo "$1" || echo none; }
# past_border TITLE: what the pixel one past the border's size shows, read
# as no_border_colour reads it.
past_border() { local c; c="$(edge_pixels "$1" 5)" || return; no_border_colour "$c"; }

# app_window_rows TITLE ID: the one shell window titled TITLE, plugin ID's
# `window`, open and just mapped, is a Hyprland window: one client of the
# shell's class, floating and centred by the `vgs:window` rule and focused;
# its border is 4 px of the active colour while it is focused and of the
# inactive colour while the toplevel helper is; a move dispatch moves it
# and a focus dispatch focuses it; an Escape typed while the helper has the
# keyboard reaches the helper and leaves the window open, and one typed
# while the window has it closes the window through the host. It leaves no
# window open, no helper running and hyprland.lua as it found it.
app_window_rows() {
  local title="$1" id="$2" address at_before keys_before
  expect_poll "$title is one client of the shell's class titled $title" 1 window_count "$title"
  expect_poll "the $title window floats" '[true]' window_of "$title" floating
  geometry expect_poll "the $title window is centred on its monitor's work area" centred window_centred "$title"
  expect_poll "the $title window is focused" "[\"$shell_class\", \"$title\"]" active_window
  window_border_on
  render expect_poll "the focused $title window's border is 4 px of the active colour" "ff0000 ff0000 ff0000 ff0000" edge_pixels "$title" 1 2 3 4
  render expect "the $title window's border ends at its size" none past_border "$title"
  if open_other "$sandbox/toplevel-$id.log"; then
    expect_poll "the helper beside $title takes the focus" '["smoke.other", "Other window"]' active_window
    render expect_poll "the unfocused $title window's border is 4 px of the inactive colour" "0000ff 0000ff 0000ff 0000ff" edge_pixels "$title" 1 2 3 4
    if address="$(window_address "$title")" && [[ $address == 0x* ]]; then
      at_before="$(window_of "$title" at)"
      # moved: how far the window's top-left moved since at_before, as
      # [dx, dy], or what window_of answered.
      moved() {
        local now
        now="$(window_of "$title" at)" && [[ $now == \[* ]] || { echo "$now"; return; }
        python3 -c 'import json,sys; a=json.loads(sys.argv[1])[0]; b=json.loads(sys.argv[2])[0]; print(json.dumps([b[0] - a[0], b[1] - a[1]]))' "$at_before" "$now"
      }
      expect "a move dispatch aimed at the $title window answers ok" ok hypr dispatch "hl.dsp.window.move({ x = 40, y = 30, relative = true, window = \"address:$address\" })"
      geometry expect_poll "the move dispatch moved the $title window by 40, 30" '[40, 30]' moved
      keys_before="$(other_events '^key ')"
      type_keys -k Escape || fail "typing Escape into the helper beside $title failed"
      expect_poll "an Escape typed while the helper is focused reaches the helper" "$((keys_before + 2))" other_events '^key '
      expect "that Escape leaves the $title window open" 1 window_count "$title"
      expect "a focus dispatch aimed at the $title window answers ok" ok hypr dispatch "hl.dsp.focus({ window = \"address:$address\" })"
      expect_poll "the focus dispatch focused the $title window" "[\"$shell_class\", \"$title\"]" active_window
      render expect_poll "the refocused $title window's border is the active colour again" "ff0000 ff0000 ff0000 ff0000" edge_pixels "$title" 1 2 3 4
      type_keys -k Escape || fail "typing Escape into the $title window failed"
      expect_poll "an Escape typed while the $title window is focused closes it" 0 window_count "$title"
      expect_poll "the host dropped the $title window's instance" absent ipc smoke instanceGeometry window "$id"
      expect "that Escape never reached the helper" "$((keys_before + 2))" other_events '^key '
    else
      fail "the $title window's address is unreadable: ${address:-}"
    fi
    close_other "the helper beside $title exits 0 on SIGTERM"
  else
    fail "the toplevel helper maps beside the $title window"
  fi
  # A failed reading above can leave the window open; the rows after these
  # start with none.
  [[ $(window_count "$title") == 0 ]] || ipc shell hide window "$id" >/dev/null || true
  window_border_off
}
