# Core hold shortcuts on physical keycodes, not global dispatch proxies.
# One persistent virtual keyboard lets a row change configuration while a
# key stays down. The client records actual evdev edges. No latency budget:
# fixture and client readings poll through IPC or the harness's 200 ms log
# reader. The unit runner controls registration, guards and teardown.
set -euo pipefail

hold_dir="$home/.config/vgs/plugins/acme.hold"
hold_config="$home/.config/vgs/shell.json"
hold_lua="$home/.config/hypr/hyprland.lua"
hold_layer="$home/.local/state/vgs/hypr/vgs.lua"
cp -- "$hold_config" "$sandbox/hold-before.json"
cp -- "$hold_lua" "$sandbox/hold-before.lua"
mkdir -p "$hold_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.hold/." "$hold_dir/"
expect "rescan discovers the hold fixture" ok ipc shell rescanPlugins
expect_poll "the hold fixture is known" True plugin_known acme.hold
expect "enable the hold fixture" ok ipc shell setPluginEnabled acme.hold true
expect_poll "the hold fixture builds" True record_exists acme.hold
expect_poll "both physical hold keys reach the provider" '"{\"talk\":\"SUPER+code:108\",\"other\":\"CTRL+code:108\"}"' ipc smoke readInstance service acme.hold keys

# wtype's symbol-resolution setting does not model physical keycodes.
printf '%s\n' 'hl.config({ input = { resolve_binds_by_sym = false } })' >>"$hold_lua"
expect "physical keycodes use the virtual keyboard's evdev map" ok hypr reload config-only
expect "the hold layer has no configuration errors" '[]' config_errors
hold_client_log="$sandbox/hold-client.log"
open_toplevel "$hold_client_log" smoke.hold-client "Hold client"
hold_client_pid="$toplevel_pid"
expect_poll "the hold client has keyboard focus" '["smoke.hold-client", "Hold client"]' active_window

hold_read() { ipc smoke readInstance service acme.hold edges; }
hold_reset() { expect "clear the hold fixture's edge record" ok ipc acme.hold invoke reset ""; }
hold_client_events() { log_lines "$1" "$hold_client_log"; }
hold_native() { hypr globalshortcuts | py_reply 'import sys; print(sum("acme.hold:" in line for line in sys.stdin))'; }
hold_start_keyboard() { # LABEL EXECUTABLE LAYOUT OPTIONS
  hold_keyboard_log="$sandbox/hold-keyboard-$1.log"
  hold_fifo="$sandbox/hold-keyboard-$1.fifo"
  mkfifo "$hold_fifo"
  exec {hold_fd}<>"$hold_fifo"
  spawn "$hold_keyboard_log" "${shell_env[@]}" "$2" "$hold_fifo" "$3" "$4"
  hold_keyboard_pid="$spawn_pid"
  expect_poll "the $1 keyboard connects only to the nested seat" 1 log_lines '^ready$' "$hold_keyboard_log"
  grep -qxF ready "$hold_keyboard_log" || return 1
}
hold_send() { printf '%s\n' "$@" >&"$hold_fd"; }
hold_stop_keyboard() {
  hold_send quit
  exec {hold_fd}>&-
  local status=0
  wait "$hold_keyboard_pid" || status=$?
  expect "the physical keyboard exits with all keys released" 0 printf '%s\n' "$status"
}
hold_pair() { # ORDER
  hold_reset
  hold_send "down 133" "down 108"
  expect_poll "$1: physical down reaches the fixture once" '["talk-down"]' hold_read
  case "$1" in
    key-first) hold_send "up 108" "up 133" ;;
    modifier-first) hold_send "up 133" "up 108" ;;
  esac
  expect_poll "$1: physical up completes the hold once" '["talk-down","talk-up"]' hold_read
}

for mode in us altgr swapped; do
  case "$mode" in
    us) layout=us; options="" ;;
    altgr) layout=de; options="" ;;
    swapped) layout=us; options=ctrl:swap_ralt_rctl ;;
  esac
  hold_start_keyboard "$mode" "$sandbox/keyboard" "$layout" "$options"
  hold_pair key-first
  hold_pair modifier-first
  hold_reset
  client_down="$(hold_client_events '^key 100 pressed$')"
  client_up="$(hold_client_events '^key 100 released$')"
  marker_up="$(hold_client_events '^key 30 released$')"
  hold_send "down 108" "up 108" "down 38" "up 38"
  expect_poll "$mode: the client processes the key after plain Right Alt" "$((marker_up + 1))" hold_client_events '^key 30 released$'
  expect "$mode: plain Right Alt down reaches the client" "$((client_down + 1))" hold_client_events '^key 100 pressed$'
  expect "$mode: plain Right Alt up reaches the client" "$((client_up + 1))" hold_client_events '^key 100 released$'
  expect "$mode: plain Right Alt calls no hold handler" '[]' hold_read
  hold_stop_keyboard
done

hold_start_keyboard lifecycle "$sandbox/keyboard" us ""
hold_reset
hold_send "down 133" "down 108" "down 108"
expect_poll "repeated physical down starts only one hold" '["talk-down"]' hold_read
hold_send "up 133" "up 108"
expect_poll "repeat still completes only one hold" '["talk-down","talk-up"]' hold_read
hold_reset
hold_send "down 37" "down 108"
expect_poll "the other chord starts only its own hold" '["other-down"]' hold_read
hold_send "up 37" "up 108"
expect_poll "the shared terminal key calls no unrelated release" '["other-down","other-up"]' hold_read

# Remove only modifier-independent release behavior from the generated copy.
# The same acceptance assertion must reject the result.
cp -- "$hold_layer" "$sandbox/hold-layer-good.lua"
python3 - "$hold_layer" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = 'description = "acme.hold:talk.release", release = true, non_consuming = true, transparent = true, ignore_mods = true'
assert s.count(needle) == 2, "hold control: expected default and capture companions"
changed = s.replace(needle, needle.replace("ignore_mods = true", "ignore_mods = false"))
assert changed != s
p.write_text(changed)
PY
expect "control: reload the modifier-sensitive release" ok hypr reload config-only
hold_reset
hold_send "down 133" "down 108"
expect_poll "control: the press still reaches the real registry" '["talk-down"]' hold_read
hold_send "up 133" "up 108"
hold_acceptance() { local got; got="$(hold_read)" || return; [[ $got == '["talk-down","talk-up"]' ]] && echo ok || echo violation; }
expect "control: losing modifier-independent release breaks acceptance" violation hold_acceptance
cp -- "$sandbox/hold-layer-good.lua" "$hold_layer"
expect "restore the generated release bind" ok hypr reload config-only
# A key change cancels the control's pending hold through the real provider.
set_keys '{"acme.hold":{"talk":null}}'
expect "reload after unbinding the held key" ok ipc shell reloadConfig
expect_poll "unbinding completes the pending hold" '["talk-down","talk-up"]' hold_read
expect_poll "the effective talk key is unbound" '"{\"talk\":null,\"other\":\"CTRL+code:108\"}"' ipc smoke readInstance service acme.hold keys
hold_reset
hold_send "down 133" "down 108" "up 133" "up 108"
expect "an unbound hold calls no handler" '[]' hold_read
set_keys '{"acme.hold":{}}'
expect "restore the hold's default key" ok ipc shell reloadConfig
expect_poll "the default physical key is back" '"{\"talk\":\"SUPER+code:108\",\"other\":\"CTRL+code:108\"}"' ipc smoke readInstance service acme.hold keys
hold_reset
hold_send "down 133" "down 108"
expect_poll "a physical hold starts before a live unbind" '["talk-down"]' hold_read
set_keys '{"acme.hold":{"talk":null}}'
expect "unbind while the physical key is still down" ok ipc shell reloadConfig
expect_poll "a live unbind completes the held registration" '["talk-down","talk-up"]' hold_read
hold_send "up 133" "up 108"
expect "the old physical up cannot complete the hold twice" '["talk-down","talk-up"]' hold_read
set_keys '{"acme.hold":{}}'
expect "restore the key after the live unbind" ok ipc shell reloadConfig
expect_poll "the live unbind leaves no stale effective key" '"{\"talk\":\"SUPER+code:108\",\"other\":\"CTRL+code:108\"}"' ipc smoke readInstance service acme.hold keys

# A silent sender retains its command acknowledgments but drops key events.
python3 - "$repo/scripts/smoke/keyboard/keyboard.c" "$sandbox/keyboard-silent.c" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
needle = 'zwp_virtual_keyboard_v1_key(keyboard, ms, code - 8, pressed ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);'
assert s.count(needle) == 1
changed = s.replace(needle, '(void)ms;')
assert changed != s
pathlib.Path(sys.argv[2]).write_text(changed)
PY
build_helper keyboard-silent keyboard-control "$sandbox/keyboard-silent.c" "$repo/scripts/smoke/keyboard/virtual-keyboard-unstable-v1.xml" xkbcommon
hold_stop_keyboard
hold_start_keyboard silent "$sandbox/keyboard-silent" us ""
hold_reset
hold_send "down 133" "down 108" "up 108" "up 133" sync
expect_poll "control: the silent sender still acknowledges commands" 1 log_lines '^sync$' "$hold_keyboard_log"
expect "control: dropped physical delivery breaks acceptance" violation hold_acceptance
hold_stop_keyboard
hold_start_keyboard dispose "$sandbox/keyboard" us ""
hold_reset
hold_send "down 37" "down 108"
expect_poll "the disposable registration is held" '["other-down"]' hold_read
expect "early disposal releases the hold" ok ipc acme.hold invoke release-other ""
expect_poll "early disposal delivers the matching up once" '["other-down","other-up"]' hold_read
expect_poll "early disposal releases both native registrations" 2 hold_native
hold_send "up 37" "up 108"
expect "late key-up cannot call the disposed registration" '["other-down","other-up"]' hold_read
hold_reset
hold_send "down 133" "down 108"
expect_poll "the remaining hold is active before disable" '["talk-down"]' hold_read
up_before="$(log_lines 'hold-fixture: edge=talk-up$')"
expect "disable the fixture while its key is held" ok ipc shell setPluginEnabled acme.hold false
expect_poll "disable completes the hold before destroying the instance" "$((up_before + 1))" log_lines 'hold-fixture: edge=talk-up$'
expect_poll "disable releases every native hold registration" 0 hold_native
hold_send "up 133" "up 108"
hold_stop_keyboard
expect "late key-up after disable calls no release handler" "$((up_before + 1))" log_lines 'hold-fixture: edge=talk-up$'
close_toplevel "$hold_client_pid" "the hold client exits"
cp -- "$sandbox/hold-before.json" "$hold_config"
cp -- "$sandbox/hold-before.lua" "$hold_lua"
expect "restore the hold row's configuration" ok ipc shell reloadConfig
expect "restore the nested compositor's input settings" ok hypr reload config-only
expect_poll "the hold fixture remains disabled" False record_exists acme.hold
expect "the restored nested configuration has no errors" '[]' config_errors
