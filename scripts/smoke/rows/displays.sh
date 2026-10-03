# vgs.displays over the sandbox's device fakes
# (docs/architecture/validation-smoke-devices.md): the HID fake's Pro
# Display XDR, hidraw0, and two Studio Displays with one serial, hidraw1
# and hidraw2, which only their HID devices' directories tell apart. No
# sandbox output has an Apple model, so the helper places none of them.
# The row adds a headless output, SMOKE-DISPLAYS, beside the main one and
# enables vgs.displays and the System window.
#
# Rows: the service lists the three displays and places none, so neither
# bar shows the widget; on the keyboard alone, in System → Displays, Up
# raises the XDR, its slider follows a level set elsewhere so the next Up
# steps from that level, and Down on its Screen choice puts it on the
# main output; the pane's IPC puts Studio A on SMOKE-DISPLAYS, so each
# bar's widget controls its own display, and a burst of 10 scroll notches
# from 1 % on the SMOKE-DISPLAYS widget makes at most 2 helper runs,
# leaves the burst's summed level, 51 %, in the fake and changes neither
# other display; the on-screen display maps on that screen alone; a
# brightness key acts on the focused output, first the main one, then
# SMOKE-DISPLAYS; the flyout lists its screen's display first; Identify
# shows every screen's name and flashes the display, then puts it back,
# also after a second press during the first, and keeps a level set while
# it runs; a closed hidraw2 reads no-access after a plugin scan, the Apple
# access entry offers Allow, the pane's access row reads it through
# `status.rows`, and the pane's Allow, through `status.act`, hands the
# stand-in terminal `vgsh system apply apple-displays`; the choices
# persist in the assignments file and come back after the service is
# rebuilt, and the second Studio Display still waits for its own.
#
# Control: the same 10 notches from 1 %, each sent once the run before it
# ended, make 10 helper runs and reach the same 51 %, so the burst's
# reading is the coalescing's and not a counter that cannot see more, and
# a lost or repeated notch shows in the level, which stays under the 100 %
# ceiling. The helper runs and their levels are
# read from the HID fake's log, every feature report it served. Every
# reading is expect_poll's: 25 reads 0.2 s apart. The row puts back the
# user file, so vgs.system and vgs.displays are as it found them, and
# removes the output and the assignments file and gives hidraw2 its mode
# back.
set -euo pipefail
devices_ready displays || return 0
# The core probes the system steps once vgs.displays holds `system`, and
# the fakes' tree keeps that probe off the host's /sys and /dev.
disp_tree="$(devices_system_tree)" || { fail "displays: the fakes' system tree: $disp_tree"; return 0; }
disp_output=SMOKE-DISPLAYS
disp_file="$home/.local/state/vgs/plugins/vgs.displays/assignments.json"
disp_xdr=hidraw:class/hidraw/hidraw0/device
disp_a=hidraw:class/hidraw/hidraw1/device
disp_b=hidraw:class/hidraw/hidraw2/device
disp_a_key="usb:class/hidraw/hidraw1/device#VGSSMOKESTUDIO"
disp_xdr_key="usb:class/hidraw/hidraw0/device#VGSSMOKEXDR01"
disp_hidraw2="$devices_dev_root/hidraw2"
disp_user="$home/.config/vgs/shell.json"
disp_user_saved="$sandbox/shell-before-displays.json"
cp -- "$disp_user" "$disp_user_saved"
rm -f -- "${disp_file:?}"

disp_read() { ipc smoke readInstance service vgs.displays "$1"; }
# The displays the service publishes, by HID node, as [node, state,
# percent, outputs, assigned].
disp_items() { disp_read values | py_reply '
import json, re, sys
items = json.load(sys.stdin)["displays"]["items"]
print(json.dumps([[re.search(r"hidraw\d+", d["id"]).group(0), d["state"], d["percent"], d["outputs"], d["assigned"]] for d in items]))'; }
disp_item() { disp_items | py_reply 'import json,sys; found=[d for d in json.load(sys.stdin) if d[0] == sys.argv[1]]; print(json.dumps(found[0]) if found else "absent")' "$1"; }
disp_value() { disp_read values | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)[sys.argv[1]], sort_keys=True))' "$1"; }
disp_idle() { disp_read runs | py_reply 'import json,sys; r=json.load(sys.stdin); print(r["busy"] is None and r["sets"] == [] and not r["list"])'; }
disp_identifier() { disp_read outputs | py_reply 'import json,sys; print([o["identifier"] for o in json.load(sys.stdin) if o["name"] == sys.argv[1]][0])' "$1"; }
disp_widget() { ipc smoke readInstance "bar:$1" vgs.displays "$2"; }
# The HID fake's set-feature calls for a node: how many, and the last
# report one wrote.
disp_sets() { python3 - "$devices_hid_log" "$1" <<'PY'
import json, os, sys
path, node = sys.argv[1:]
rows = [json.loads(l) for l in open(path)] if os.path.exists(path) else []
print(sum(1 for r in rows if r["request"].get("device") == node and r["request"].get("request", 0) & 0xFF == 0x06))
PY
}
disp_report() { hid_fake_call "$1" 0xC0074807 01000000000000 | py_reply 'import json,sys; print(json.load(sys.stdin)["data"])'; }
# The screens each passive layer of the plugin maps on, in registration
# order: the on-screen display, then Identify.
disp_layers() { ipc smoke layerWindows vgs.displays | py_reply '
import json, sys
rows = json.load(sys.stdin)
half = len(rows) // 2
print(json.dumps([sorted(r["screen"] for r in rows[:half] if r["shown"]), sorted(r["screen"] for r in rows[half:] if r["shown"])]))'; }
disp_keys() { ipc shell lent | py_reply 'import json,sys; s=json.load(sys.stdin)["shortcuts"]; print("vgs.displays:brightness-up" in s and "vgs.displays:brightness-down" in s)'; }
disp_focus() { ipc smoke focused window vgs.system | py_reply 'import json,sys; r=json.load(sys.stdin); print(json.dumps(r[:2]) if isinstance(r, list) else r)'; }
disp_widget_id() { disp_widget "$1" display | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["id"]))'; }
disp_other_sets() { echo "$(disp_sets hidraw0) $(disp_sets hidraw2)"; }
disp_panel_rows() { ipc smoke readInstance panel vgs.displays rows | py_reply 'import json,sys; print(json.dumps([r["id"] for r in json.load(sys.stdin)]))'; }
# The pane's access row for an entry, as `status.rows` lends it: [tone,
# text, action label, offered].
disp_access_row() { ipc smoke readInstance window vgs.displays accessRows | py_reply '
import json, sys
row = [r for r in json.load(sys.stdin) if r["key"] == sys.argv[1]]
print(json.dumps([row[0]["tone"], row[0]["value"]["text"], row[0]["action"]["label"], row[0]["action"]["offered"]]) if row else "absent")' "$1"; }
disp_file_entries() { python3 -c 'import json,sys; print(json.dumps(sorted([e["device"], e["output"]] for e in json.load(open(sys.argv[1]))["assignments"])))' "$disp_file"; }

disp_main="$(hypr -j monitors | py_reply 'import json,sys; print(sorted(json.load(sys.stdin), key=lambda m: m["id"])[0]["name"])')" || { fail "displays: the main output is unreadable"; return 0; }
device_reply_clear ddcutil

expect "enabling the System window for the displays pane is allowed" ok ipc shell setPluginEnabled vgs.system true
expect "enabling vgs.displays is allowed" ok ipc shell setPluginEnabled vgs.displays true
# The default set rows/start-order.sh leaves enables the plugin without
# its widget in the bar.
expect "placing the displays widget is allowed" ok ipc shell setPluginPlaced vgs.displays true
expect_poll "the displays service is built" True record_exists vgs.displays
# rows/device-fakes.sh left the XDR's report at 20000, 40 %.
expect_poll "the service lists the three Apple displays and places none" \
  '[["hidraw0", "ready", 40, [], false], ["hidraw1", "ready", 50, [], false], ["hidraw2", "ready", 70, [], false]]' disp_items
expect_poll "the service registered both brightness keys" True disp_keys
expect "the widget hides while no display lights its screen" false disp_widget "$disp_main" visible
expect "the two Studio Displays wait for a choice, and no choice is saved" '{"entries": [], "error": null}' disp_value assignments

# The keyboard alone, in System → Displays: the pane opens on the XDR's
# slider, Up raises it one step, Tab reaches its Screen choice and Down
# picks the first output, the main one.
read -r mon_w mon_h < <(hypr -j monitors | py_reply 'import json,sys; m=json.load(sys.stdin)[0]; print(m["width"], m["height"])')
rest_pointer || fail "moving the pointer off the bar failed"
expect "the deep link opens the System window on Displays" ok ipc shell summon window vgs.system '{"pane":"vgs.displays"}'
expect_poll "the System window mounts the displays pane" '["vgs.displays"]' window_panes
expect_poll "the pane opens with the keyboard on the XDR's slider" '["Slider", "Apple Pro Display XDR"]' disp_focus
disp_xdr_sets="$(disp_sets hidraw0)"
type_keys -k Up || fail "typing Up on the XDR's slider failed"
expect_poll "Up on the slider raises the XDR to 41" '["hidraw0", "ready", 41, [], false]' disp_item hidraw0
expect_poll "the helper wrote the XDR once" "$((disp_xdr_sets + 1))" disp_sets hidraw0
# A level set elsewhere moves the slider's handle, so the next Up steps
# from it and not from the handle's old place.
expect "the XDR is set to 30 % while the pane is open" ok ipc vgs.displays invoke set "{\"id\":\"$disp_xdr\",\"percent\":30}"
expect_poll "the service shows the XDR at 30 %" '["hidraw0", "ready", 30, [], false]' disp_item hidraw0
type_keys -k Up || fail "typing Up on the XDR's slider again failed"
expect_poll "Up after the outside change raises the XDR to 31" '["hidraw0", "ready", 31, [], false]' disp_item hidraw0
type_keys -k Tab || fail "typing Tab in the pane failed"
expect_poll "Tab reaches the XDR's Screen choice" '["Select", "Screen for Apple Pro Display XDR"]' disp_focus
type_keys -k Down || fail "typing Down on the Screen choice failed"
expect_poll "Down on the Screen choice puts the XDR on the main output" "[\"hidraw0\", \"ready\", 31, [\"$disp_main\"], true]" disp_item hidraw0
expect_poll "the main bar's widget shows for the XDR" true disp_widget "$disp_main" visible
expect "hiding the System window after the keyboard path is allowed" ok ipc shell hide window vgs.system
expect_poll "the System window is gone" 0 window_count System

# A second output, whose bar's widget hides until a display lights it.
expect "the nested compositor adds a monitor for the displays rows" ok hypr output create headless "$disp_output"
expect_poll "the new monitor gets a bar" "$((monitors + 1))" bar_count
expect_poll "the new bar's widget hides while no display lights its screen" false disp_widget "$disp_output" visible

# Studio A on the new output, as the pane's Screen choice asks.
disp_new_id="$(disp_identifier "$disp_output")" || { fail "displays: the new output's identifier is unreadable"; return 0; }
disp_main_id="$(disp_identifier "$disp_main")" || { fail "displays: the main output's identifier is unreadable"; return 0; }
expect "the pane's choice puts Studio A on the new output" ok ipc vgs.displays invoke assign "{\"device\":\"$disp_a_key\",\"output\":\"$disp_new_id\"}"
expect_poll "Studio A lights the new output" "[\"hidraw1\", \"ready\", 50, [\"$disp_output\"], true]" disp_item hidraw1
expect_poll "the new bar's widget controls Studio A" "\"$disp_a\"" disp_widget_id "$disp_output"
expect "the second Studio Display still waits for its own choice" '["hidraw2", "ready", 70, [], false]' disp_item hidraw2
expect "an output no display could take is refused" "refused: assign=$disp_a_key output=DP-404 reason=absent" ipc vgs.displays invoke assign "{\"device\":\"$disp_a_key\",\"output\":\"DP-404\"}"

# A burst of 10 scroll notches up from 1 % on the new bar's widget, in one
# turn as a fast drag lands between two frames: at most two helper runs,
# the last carrying the burst's level, 1 + 10 × 5 = 51 %; neither other
# display changes.
expect "Studio A is set to 1 % for the burst" ok ipc vgs.displays invoke set "{\"id\":\"$disp_a\",\"percent\":1}"
expect_poll "the helper is idle before the burst" True disp_idle
disp_a_sets="$(disp_sets hidraw1)"
disp_xdr_sets="$(disp_sets hidraw0)"
disp_b_sets="$(disp_sets hidraw2)"
expect "the burst's 10 notches each answer ok" "$(python3 -c 'import json; print(json.dumps(["ok"] * 10, separators=(",", ":")))')" ipc smoke invokeBurst "bar:$disp_output" vgs.displays scroll 1 10
expect_poll "the helper is idle after the burst" True disp_idle
disp_burst_runs() { echo "$(( $(disp_sets hidraw1) - disp_a_sets ))"; }
disp_burst_at_most_two() { local runs; runs="$(disp_burst_runs)"; if ((runs >= 1 && runs <= 2)); then echo "1-2"; else echo "$runs"; fi; }
expect "the 10-notch burst made one or two helper runs" "1-2" disp_burst_at_most_two
# The Studio Display's report for 51 %: 400 + 51 % of 400..60000, 30796,
# little-endian after report id 1 (helper/brightness.py raw_from_percent).
expect "the fake holds the burst's summed level, 51 %" 014c7800000000 disp_report hidraw1
expect "the service shows Studio A at 51 %" "[\"hidraw1\", \"ready\", 51, [\"$disp_output\"], true]" disp_item hidraw1
expect "the burst wrote no other display" "$disp_xdr_sets $disp_b_sets" disp_other_sets
expect_poll "the on-screen display maps on the new output alone" "[[\"$disp_output\"], []]" disp_layers
expect_poll "the on-screen display goes after its time" "[[], []]" disp_layers

# Control: the same 10 notches, each once the run before it ended, make
# 10 runs and reach the same level.
expect "Studio A is set to 1 % for the control" ok ipc vgs.displays invoke set "{\"id\":\"$disp_a\",\"percent\":1}"
expect_poll "the helper is idle before the control" True disp_idle
disp_a_sets="$(disp_sets hidraw1)"
for _ in $(seq 1 10); do
  expect "control: one notch answers ok" ok ipc smoke invokeInstance "bar:$disp_output" vgs.displays scroll 1
  expect_poll "control: the helper is idle after the notch" True disp_idle
done
expect "control: 10 paced notches made 10 helper runs" 10 disp_burst_runs
expect "control: the fake holds the paced notches' level, 51 %" 014c7800000000 disp_report hidraw1

# A brightness key acts on the focused output.
expect "the main output takes the focus" ok hypr dispatch "hl.dsp.focus({ monitor = \"$disp_main\" })"
expect_poll "the service reads the main output focused" "\"$disp_main\"" disp_read focusedOutput
expect "the brightness-up key is pressed" ok hypr dispatch 'hl.dsp.global("vgs.displays:brightness-up")'
expect_poll "the key raises the XDR on the focused output" "[\"hidraw0\", \"ready\", 36, [\"$disp_main\"], true]" disp_item hidraw0
expect "the key leaves Studio A" "[\"hidraw1\", \"ready\", 51, [\"$disp_output\"], true]" disp_item hidraw1
expect_poll "the key's on-screen display maps on the main output alone" "[[\"$disp_main\"], []]" disp_layers
expect "the new output takes the focus" ok hypr dispatch "hl.dsp.focus({ monitor = \"$disp_output\" })"
expect_poll "the service reads the new output focused" "\"$disp_output\"" disp_read focusedOutput
expect "the brightness-down key is pressed" ok hypr dispatch 'hl.dsp.global("vgs.displays:brightness-down")'
expect_poll "the key dims Studio A on the focused output" "[\"hidraw1\", \"ready\", 46, [\"$disp_output\"], true]" disp_item hidraw1
expect "the key leaves the XDR" "[\"hidraw0\", \"ready\", 36, [\"$disp_main\"], true]" disp_item hidraw0
expect_poll "the helper is idle after the keys" True disp_idle

# The flyout on the new output lists Studio A first.
expect "the new output takes the focus for the flyout" ok hypr dispatch "hl.dsp.focus({ monitor = \"$disp_output\" })"
expect_poll "the service reads the new output focused for the flyout" "\"$disp_output\"" disp_read focusedOutput
expect "the flyout opens on the focused output" ok ipc shell summon panel vgs.displays '{}'
expect_poll "the flyout is on the new output" "\"$disp_output\"" ipc smoke readInstance panel vgs.displays screenName
expect_poll "the flyout lists its screen's display first" "[\"$disp_a\", \"$disp_xdr\", \"$disp_b\"]" disp_panel_rows
expect "hiding the flyout is allowed" ok ipc shell hide panel vgs.displays

# Identify: every screen shows its name and Studio A shows its other level,
# then goes back.
disp_a_sets="$(disp_sets hidraw1)"
expect "Identify answers ok" ok ipc vgs.displays invoke identify "$disp_a"
expect_poll "Identify shows on every screen" "$(python3 -c 'import json,sys; print(json.dumps([[], sorted(sys.argv[1:])]))' "$disp_main" "$disp_output")" disp_layers
expect_poll "Identify flashes Studio A, below 50 %, at 100 %" "[\"hidraw1\", \"ready\", 100, [\"$disp_output\"], true]" disp_item hidraw1
expect_poll "Identify ends" "[[], []]" disp_layers
expect_poll "Identify puts Studio A back at 46 %" "[\"hidraw1\", \"ready\", 46, [\"$disp_output\"], true]" disp_item hidraw1
expect_poll "the helper is idle after Identify" True disp_idle
expect "Identify wrote Studio A twice" "$((disp_a_sets + 2))" disp_sets hidraw1
# A second press during the first still puts back the user's level, not
# the first press's flash level.
expect "Identify answers ok again" ok ipc vgs.displays invoke identify "$disp_a"
expect "a second Identify during the first answers ok" ok ipc vgs.displays invoke identify "$disp_a"
expect_poll "the second Identify ends" "[[], []]" disp_layers
expect_poll "the helper is idle after the second Identify" True disp_idle
expect "two presses put Studio A back at 46 %" "[\"hidraw1\", \"ready\", 46, [\"$disp_output\"], true]" disp_item hidraw1
# A level set while Identify runs is the one that stays.
expect "Identify answers ok a third time" ok ipc vgs.displays invoke identify "$disp_a"
expect_poll "Identify flashes Studio A again" "[\"hidraw1\", \"ready\", 100, [\"$disp_output\"], true]" disp_item hidraw1
expect "Studio A is set to 60 % during Identify" ok ipc vgs.displays invoke set "{\"id\":\"$disp_a\",\"percent\":60}"
expect_poll "the third Identify ends" "[[], []]" disp_layers
expect_poll "the helper is idle after the third Identify" True disp_idle
expect "Identify keeps the level set while it ran, 60 %" "[\"hidraw1\", \"ready\", 60, [\"$disp_output\"], true]" disp_item hidraw1

# A display the user may not open: after a plugin scan probes the steps
# again, Studio B reads no-access and the Apple entry offers Allow, which
# the pane hands to the core through status.act.
disp_hidraw2_mode="$(stat -c %a -- "$disp_hidraw2")" || { fail "displays: the HID fake planted no hidraw2"; return 0; }
chmod 0000 "$disp_hidraw2"
expect "a rescan with hidraw2 closed answers ok" ok ipc shell rescanPlugins
expect_poll "the Apple access entry offers Allow" '{"action": true, "text": "Needs your permission", "tone": "warning"}' disp_value appleAccess
expect_poll "Studio B reads no-access" '["hidraw2", "no-access", null, [], false]' disp_item hidraw2
terminal_stand_in
terminal_ready "displays"
expect "the deep link opens System → Displays again" ok ipc shell summon window vgs.system '{"pane":"vgs.displays"}'
expect_poll "the System window mounts the displays pane again" '["vgs.displays"]' window_panes
expect_poll "the pane's Apple access row, from status.rows, offers Allow in the warning tone" '["warning", "Needs your permission", "Allow", true]' disp_access_row appleAccess
forget_record
expect "the pane's Allow, through status.act, answers ok" ok ipc smoke invokeInstance window vgs.displays runAction appleAccess
expect_poll "Allow hands the terminal vgsh system apply apple-displays" \
  "$(core_words core/system "System setup" org.vgs.tui system apply apple-displays)" recorded
expect_run_end "the Allow core/system run ends" core/system
forget_record
chmod "$disp_hidraw2_mode" "$disp_hidraw2"
expect "a rescan with hidraw2 open again answers ok" ok ipc shell rescanPlugins
expect_poll "the Apple access entry reads allowed again" '{"action": false, "text": "Allowed", "tone": "ok"}' disp_value appleAccess
expect_poll "Studio B reads ready again" '["hidraw2", "ready", 70, [], false]' disp_item hidraw2
expect "hiding the System window is allowed" ok ipc shell hide window vgs.system

# The choices persist: the file holds both, and a rebuilt service applies
# them again while Studio B still waits.
expect "the assignments file holds both choices" "$(python3 -c 'import json,sys; print(json.dumps(sorted([[sys.argv[1], sys.argv[2]], [sys.argv[3], sys.argv[4]]])))' "$disp_a_key" "$disp_new_id" "$disp_xdr_key" "$disp_main_id")" disp_file_entries
expect "disabling vgs.displays is allowed" ok ipc shell setPluginEnabled vgs.displays false
expect_poll "the displays service is gone" False record_exists vgs.displays
expect "enabling vgs.displays again is allowed" ok ipc shell setPluginEnabled vgs.displays true
expect_poll "the rebuilt service puts Studio A on the new output from the file" "[\"hidraw1\", \"ready\", 60, [\"$disp_output\"], true]" disp_item hidraw1
expect "the rebuilt service puts the XDR on the main output from the file" "[\"hidraw0\", \"ready\", 36, [\"$disp_main\"], true]" disp_item hidraw0
expect "the second Studio Display still waits after the rebuild" '["hidraw2", "ready", 70, [], false]' disp_item hidraw2

expect "disabling vgs.displays at the end is allowed" ok ipc shell setPluginEnabled vgs.displays false
expect_poll "no displays layer is left" '[]' ipc smoke layerWindows vgs.displays
rm -f -- "${disp_file:?}"
cp -- "$disp_user_saved" "$disp_user.tmp" && mv -T -- "$disp_user.tmp" "$disp_user"
expect "the nested compositor removes the displays monitor" ok hypr output remove "$disp_output"
expect_poll "the removed monitor's bar surface is gone" "$monitors" bar_count
