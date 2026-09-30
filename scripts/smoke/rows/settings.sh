# Settings edits and the dispatch queue. The Settings window opens from a
# real click on the gear, so the compositor gives its window the keyboard,
# and a click on a text field gives that field keyboard focus. A write is
# published once: its own file notification is read and found identical.
# An unrelated change keeps an edit in progress: the same drawn field, its
# focus, its text and its cursor. The plugin is disabled again at the end,
# so the later rows' lending records hold no Settings shortcut or IPC
# target. Dispatches asked for back to back run in order behind one
# process, the queue has a bound, and a process that cannot start does not
# stop the queue.
set -euo pipefail
click_centre "$(bar_key)" vgs.settings || fail "the click on the gear failed"
expect_poll "the gear's click opens the Settings window" open settings_open
expect "the window opens the fixture's page" ok ipc smoke invokeInstance window vgs.settings openPlugin acme.probe
expect_poll "the page draws the fixture's fields again" '[9, 0]' page_fields
held_rect="$(ipc smoke invokeInstance window vgs.settings holdField '{"id":"acme.probe","key":"label","text":"draft"}')" || fail "holdField failed"
if [[ $held_rect == \[* ]]; then ok "an edit begins in the fixture's label field"; else fail "an edit begins in the fixture's label field: got $held_rect"; fi
read -r field_cx field_cy < <(at_centre window:Settings "$held_rect")
click "$field_cx" "$field_cy" || fail "the click on the held field failed"
held_state() { ipc smoke invokeInstance window vgs.settings heldFieldState ''; }
# The click also puts the cursor where it landed; the state read after it
# is what the unrelated changes must preserve.
held_focused() { held_state | py_reply 'import json,sys; d=json.load(sys.stdin); print(d["same"] and d["focus"] and d["activeFocus"] and d["text"] == "draft")'; }
expect_poll "the clicked field holds keyboard focus with its draft" True held_focused
held_before="$(held_state)" || fail "held field state unreadable"
expect "the window toggles the bare fixture off around the edit" ok ipc smoke invokeInstance window vgs.settings toggle acme.bare
expect_poll "the window shows the bare fixture disabled" '{"acme.bare": false, "acme.probe": true, "vgs.bar": true}' manager_rows
expect "the edit in progress survives the unrelated change" "$held_before" held_state
expect "the window toggles the bare fixture back on" ok ipc smoke invokeInstance window vgs.settings toggle acme.bare
expect_poll "the window shows the bare fixture enabled" '{"acme.bare": true, "acme.probe": true, "vgs.bar": true}' manager_rows
expect "the edit in progress survives the second unrelated change" "$held_before" held_state

config_changes() { ipc smoke configChanges; }
user_loads() { ipc smoke configUserLoads; }
config_settled() { ipc smoke configSettled; }
user_label() { python3 -c 'import json,sys; print([e.get("label") for e in json.load(open(sys.argv[1])).get("plugins", []) if e["id"]=="acme.probe"][0])' "$home/.config/vgs/shell.json"; }
if changes_before="$(config_changes)" && loads_before="$(user_loads)"; then
  expect "the window writes the fixture's setting" ok ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"published-once"}'
  expect_poll "the write's own file notification was read" "$((loads_before + 1))" user_loads
  expect_poll "the save settled" true config_settled
  expect "the user file holds the written setting" published-once user_label
  expect "one write is published once" "$((changes_before + 1))" config_changes
  expect_poll "the running service received the written setting" '"published-once"' read_service label
else
  fail "configuration counters unreadable before the write rows"
fi
# Two writes back to back: the second waits for the first save and wins.
if changes_before="$(config_changes)"; then
  expect "the first of two rapid writes is accepted" ok ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"rapid-first"}'
  expect "the second of two rapid writes is accepted" ok ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"rapid-second"}'
  expect_poll "the user file holds the later of two rapid writes" rapid-second user_label
  expect_poll "the rapid writes settled" true config_settled
  expect "each rapid write is published once" "$((changes_before + 2))" config_changes
  expect "the running service holds the later rapid write" '"rapid-second"' read_service label
else
  fail "configuration counters unreadable before the rapid write rows"
fi
# Status rows, D037: a page draws each status entry its manifest does not
# keep from Settings, read-only, with its label, its value in the tone of
# its type, its hint and, behind Show command, the command it names, the
# entries without a group first; `data` and hidden entries are not drawn,
# an entry nothing published says so, and a disabled plugin's rows all say
# so. The status fixture,
# which rows/status.sh left disabled, publishes; the notifications, which
# the harness starts disabled, have published nothing.
fixture_command="secret-tool store --label='acme token' service acme account token"
# The drawn texts of the Token row, the Sync group's first.
token_drawn() { drawn_status | py_reply 'import json,sys; r=[r for r in json.load(sys.stdin) if r and r[0] == "Token"]; print(json.dumps(r[0] if len(r) == 1 else "rows=%d" % len(r)))'; }
status_of() { settings_rows | py_reply 'import json,sys; r=[p for p in json.load(sys.stdin) if p["id"] == sys.argv[1]][0]["status"]; print(json.dumps([[s["label"], s["report"], s["value"], s["tone"], s["command"]] for s in r]))' "$1"; }
drawn_status() { ipc smoke itemTexts window vgs.settings StatusRow | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
page_fields_of() { ipc smoke drawnFields window vgs.settings | py_reply 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d[sys.argv[1]], sum(v for k, v in d.items() if k != sys.argv[1])]))' "$1"; }
# The drawn rows with the `Last check` value replaced by `time` when it
# draws the fixture's moment as a local date and time: it names that
# moment's hour and minute, in the 24-hour or the 12-hour form, and not the
# raw milliseconds. A row then compares the rows whatever the locale's date
# order, and a page that draws the number itself fails.
fixture_time=1790650695194
drawn_status_timeless() { drawn_status | py_reply '
import datetime, json, sys
moment = datetime.datetime.fromtimestamp(int(sys.argv[1]) / 1000)
clocks = ("%02d:%02d" % (moment.hour, moment.minute), "%d:%02d" % ((moment.hour - 1) % 12 + 1, moment.minute))
def shown(t): return "time" if sys.argv[1][:10] not in t and any(c in t for c in clocks) else t
print(json.dumps([[shown(t) for t in r] if r[0] == "Last check" else r for r in json.load(sys.stdin)]))' "$fixture_time"; }
expect "enabling the status fixture for its Status rows is allowed" ok ipc shell setPluginEnabled acme.status true
expect_poll "the status fixture's service published its first value" '"ok"' ipc smoke readInstance service acme.status startReply
expect "the fixture publishes a state" ok ipc acme.status invoke set 'check={"tone":"warning","text":"Two sources failed"}'
expect "the fixture publishes a count" ok ipc acme.status invoke set 'pending=3'
expect "the fixture publishes a time" ok ipc acme.status invoke set "lastCheck=$fixture_time"
expect "the fixture publishes data" ok ipc acme.status invoke detail ''
expect "the window opens the status fixture's page" ok ipc smoke invokeInstance window vgs.settings openPlugin acme.status
expect_poll "the manager row lists each drawn entry in manifest order, with its value and tone" "$(python3 -c 'import json,sys; print(json.dumps([["Token", "reported", "present", "success", sys.argv[1]], ["Check", "reported", {"tone": "warning", "text": "Two sources failed"}, "warning", ""], ["Pending", "reported", 3, "", ""], ["Last check", "reported", int(sys.argv[2]), "", ""], ["Note", "unreported", None, "", ""]]))' "$fixture_command" "$fixture_time")" status_of acme.status
expect_poll "the page draws the ungrouped entries, then each group's, read-only, the command behind Show command" '[["Check", "Two sources failed"], ["Last check", "time"], ["Note", "Not reported"], ["Token", "Present", "Needed for the fixture'"'"'s sync", "Show command"], ["Pending", "3"]]' drawn_status_timeless
expect_poll "the page heads the status sections before any other" '["Status", "Sync", "Requirements", "Settings"]' section_names
expect "no Status row takes an edit" '[[],[],[],[],[]]' ipc smoke statusRowInputs window vgs.settings
expect "the page draws the choices setting only" '[1, 0]' page_fields_of acme.status
# Show command: its click shows the entry's command in a CodeLine, and a
# second hides it.
settings_press "Show command" || fail "the click on Show command failed"
expect_poll "the Token row draws its command" "$(python3 -c 'import json,sys; print(json.dumps(["Token", "Present", "Needed for the fixture'"'"'s sync", "Hide command", sys.argv[1]]))' "$fixture_command")" token_drawn
settings_press "Hide command" || fail "the click on Hide command failed"
expect_poll "the Token row hides its command" '["Token", "Present", "Needed for the fixture'"'"'s sync", "Show command"]' token_drawn

# Status actions, D061: an entry's action is offered while its published
# value calls for it, a presence while absent and a state while it says so,
# and its button runs the step through the manager: the fixture's own TUI
# in a floating terminal, or the requirement notice for its own command.
# The control comes first: a value that does not call for the action draws
# no button, and the manager refuses the act and starts nothing. The
# presses after it succeed, which clears each refusal from its line.
expected_errors+=('settings: acme\.status/(token|check) refused: action=(token|check) reason=not-offered')
terminal_stand_in
terminal_ready "the status actions"
expect_poll "values that do not call for them offer no action" '[["token", "Set up token", false], ["check", "Install the tool", false]]' offered_actions acme.status
expect_poll "the Token row draws no button but Show command" '["Token", "Present", "Needed for the fixture'"'"'s sync", "Show command"]' token_drawn
forget_record
expect "the manager refuses an act the token does not call for" "refused: action=token reason=not-offered" settings_act acme.status token
expect "the manager refuses an act the check does not call for" "refused: action=check reason=not-offered" settings_act acme.status check
expect "the refused acts started no terminal" absent recorded
expect "the refused acts raised no notice" null notice_shown
expect_poll "the refusal reads under the Token line" '["Token", "Present", "refused: action=token reason=not-offered", "Show command"]' token_drawn
expect "the fixture publishes its token absent" ok ipc acme.status invoke set 'token="absent"'
expect_poll "an absent token offers Set up token and the check offers nothing" '[["token", "Set up token", true], ["check", "Install the tool", false]]' offered_actions acme.status
expect_poll "the Token row draws its Set up token button" '["Token", "Absent", "refused: action=token reason=not-offered", "Set up token", "Show command"]' token_drawn
settings_press "Set up token" || fail "the click on Set up token failed"
expect_poll "Set up token hands the terminal the fixture's setup TUI" "$(words acme.status/setup tui/setup.sh)" recorded_tail
expect_poll "the step that ran clears the Token line's refusal" '["Token", "Absent", "Needed for the fixture'"'"'s sync", "Set up token", "Show command"]' token_drawn
expect_run_end "the setup TUI's run ends" acme.status/setup
expect_poll "the setup TUI's terminal closes" 0 tui_windows
expect "the check publishes that its tool is missing" ok ipc acme.status invoke set 'check={"tone":"warning","text":"Tool missing","action":true}'
expect_poll "the check offers Install the tool" '[["token", "Set up token", true], ["check", "Install the tool", true]]' offered_actions acme.status
# The press scans before it raises: the last scan found the command, from a
# stand-in since removed with no rescan, so only a scan the press starts
# finds it missing, as the plugin's value says. A notice raised from the
# last scan would answer satisfied and show nothing.
fixture_requirement() { ipc smoke readInstance window vgs.settings plugins | py_reply 'import json,sys; r=[q["state"] for p in json.load(sys.stdin) if p["id"] == "acme.status" for q in p["requirements"] if q["command"] == "vgs-smoke-absent"]; print(r[0] if r else "unlisted")'; }
printf '#!/bin/sh\nexit 0\n' >"$shim/vgs-smoke-absent"
chmod 755 "$shim/vgs-smoke-absent"
expect "a rescan with the fixture's command stood in starts" ok ipc shell rescanPlugins
expect_poll "the scan finds the fixture's command present" present fixture_requirement
rm -f -- "${shim:?}/vgs-smoke-absent"
expect "with the stand-in gone and no rescan the last scan still reads it present" present fixture_requirement
settings_press "Install the tool" || fail "the click on Install the tool failed"
expect_poll "Install the tool shows the requirement notice for its own command" '["acme.status", ["vgs-smoke-absent"], ["vgs-smoke-absent"], false]' notice_shown
expect "Install the tool leaves the Settings window open under the notice" 1 window_count Settings
expect_poll "the action's notice holds the keyboard" true ipc smoke noticeFocused
type_keys -k Escape || fail "sending Escape to the action's notice failed"
expect_poll "Escape closes the action's notice" null notice_shown


# The editor reads the service's choices, writes stable values rather than
# labels, and never writes on a status refresh. A missing configured value
# remains visible and stored. Node judge controls pin the shape, distinct
# ids, list and text bounds, empty-string reservation and retained values.
device_field() { ipc smoke invokeInstance window vgs.settings fieldChoice '{"id":"acme.status","key":"device"}'; }
device_state() { device_field | py_reply 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d["index"],d["text"],d["value"],d["enabled"]]))'; }
device_model() { device_field | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["model"]))'; }
choose_device() { ipc smoke invokeInstance window vgs.settings chooseField "{\"id\":\"acme.status\",\"key\":\"device\",\"index\":$1}"; }
user_device() { python3 -c 'import json,sys; print(json.dumps(next(r["device"] for r in json.load(open(sys.argv[1]))["plugins"] if r["id"]=="acme.status")))' "$home/.config/vgs/shell.json"; }
expect_poll "unreported choices draw an automatic Select" '[0, "First offered (none available)", "", true]' device_state
expect "the fixture offers labeled device ids" ok ipc acme.status invoke set 'devices=[{"label":"Alpha","value":"a"},{"label":"Beta","value":"b"}]'
expect_poll "the Select draws the status labels and keeps automatic empty string" '[0, "First offered: Alpha", "", true]' device_state
expect "the Select contains the offered ids" '[{"label": "First offered: Alpha", "value": ""}, {"label": "Alpha", "value": "a"}, {"label": "Beta", "value": "b"}]' device_model
expect "choosing the second offered device is allowed" chosen choose_device 2
expect_poll "the file stores the stable id, not its label" '"b"' user_device
expect_poll "the service receives the chosen id" '"b"' ipc smoke readInstance service acme.status configuredDevice
expect_poll "the choice save settles" true config_settled
choices_changes="$(config_changes)" || fail "configuration counter unreadable before choices refresh"
expect "the fixture removes the chosen id" ok ipc acme.status invoke set 'devices=[{"label":"Alpha","value":"a"}]'
expect_poll "the removed id remains selected and marked unavailable" '[2, "b (unavailable)", "b", true]' device_state
expect "the removed id stays in the user file" '"b"' user_device
expect "removing a choice writes no configuration" "$choices_changes" config_changes
expect "the fixture offers the configured id again, with a new label and order" ok ipc acme.status invoke set 'devices=[{"label":"Beta renamed","value":"b"},{"label":"Alpha","value":"a"}]'
expect_poll "the existing value follows its id rather than its old index" '[1, "Beta renamed", "b", true]' device_state
expect "a label and order refresh writes no configuration" "$choices_changes" config_changes
expect "the fixture publishes an empty choices list" ok ipc acme.status invoke set 'devices=[]'
expect_poll "an empty list also keeps the configured id" '[1, "b (unavailable)", "b", true]' device_state
expect "an empty list writes no configuration" "$choices_changes" config_changes
expect "the user can return to automatic selection" chosen choose_device 0
expect_poll "automatic selection stores empty string, not the first id" '""' user_device
expect "the fixture offers a new first device" ok ipc acme.status invoke set 'devices=[{"label":"Alpha","value":"a"}]'
expect_poll "automatic selection displays the new first offer without storing it" '[0, "First offered: Alpha", "", true]' device_state
expect "the empty string stays in the file" '""' user_device

# A disposable SettingField keeps the same editor and observes apply.
# Each mutation keeps the code it tests and removes one guarantee.
choice_controls="$repo/shell/plugins/vgs.settings"
choice_source_revision() {
  "$repo/bin/vgsh-scan" --require-base "$repo/shell/plugins" |
    py_reply 'import json,sys; print(next(entry["revision"] for entry in json.load(sys.stdin) if entry["dir"] == sys.argv[1]))' "$choice_controls"
}
choice_revision_before="$(choice_source_revision)" || fail "the Settings source revision is unreadable before the controls"
python3 - "$choice_controls" <<'PYEDIT'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
source = (root / "SettingField.qml").read_text()
controls = [
    ("ChoicesGood", None, None),
    ("ChoicesNoModel", "model: dynamic ? root.choices : root.spec.options", "model: dynamic ? [] : root.spec.options"),
    ("ChoicesWriteLabel", "root.choices[index].value", "root.choices[index].label"),
    ("ChoicesNoBinding", "currentIndex = Qt.binding(() => configuredIndex);", "if (false) currentIndex = Qt.binding(() => configuredIndex);"),
]
for name, needle, replacement in controls:
    text = source
    if needle is not None:
        assert text.count(needle) == 1, (name, needle)
        text = text.replace(needle, replacement)
        assert text != source, name
    anchor = "    property var choices: []"
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor + """
    property var smokeApplied: null
    onApply: v => smokeApplied = v
    readonly property int smokeCount: loader.item === null ? -1 : loader.item.count
    readonly property int smokeIndex: loader.item === null ? -1 : loader.item.currentIndex
    function smokeChoose() { loader.item.choose(1); }
""")
    (root / (name + ".qml")).write_text(text)
PYEDIT
choice_props='{"spec":{"type":"string","label":"Device","optionsFrom":"devices"},"value":"","choices":[{"label":"First offered: Alpha","value":""},{"label":"Alpha","value":"a"}]}'
for control in ChoicesGood ChoicesNoModel ChoicesWriteLabel ChoicesNoBinding; do
  expect "the probe builds $control" ok ipc smoke popupLoad "$control" "$choice_controls/$control.qml" window vgs.settings "$choice_props"
done
expect "the unchanged field copy draws the model" 2 ipc smoke popupRead ChoicesGood smokeCount
expect "the control without the status model draws no choices" 0 ipc smoke popupRead ChoicesNoModel smokeCount
expect "the unchanged copy chooses an offered item" ok ipc smoke popupCall ChoicesGood smokeChoose
expect "the unchanged copy applies the stable value" '"a"' ipc smoke popupRead ChoicesGood smokeApplied
expect "the unchanged copy restores the configured index after an unsaved choice" 0 ipc smoke popupRead ChoicesGood smokeIndex
expect "the label-writing control chooses the same item" ok ipc smoke popupCall ChoicesWriteLabel smokeChoose
expect "the label-writing control breaks stable-value readback" '"Alpha"' ipc smoke popupRead ChoicesWriteLabel smokeApplied
expect "the no-binding control chooses the same item" ok ipc smoke popupCall ChoicesNoBinding smokeChoose
expect "the no-binding control leaves an unsaved index selected" 1 ipc smoke popupRead ChoicesNoBinding smokeIndex
choice_revision_with_controls="$(choice_source_revision)" || fail "the Settings source revision is unreadable with the controls"
if [[ $choice_revision_with_controls != "$choice_revision_before" ]]; then
  ok "control: leaving generated copies changes the Settings source revision"
else
  fail "control: generated copies did not change the Settings source revision"
fi
for control in ChoicesGood ChoicesNoModel ChoicesWriteLabel ChoicesNoBinding; do
  expect "the probe drops $control" ok ipc smoke popupDrop "$control"
  rm -- "$choice_controls/$control.qml" || fail "removing the $control source copy failed"
done
expect "dropping the controls restores the Settings source revision" "$choice_revision_before" choice_source_revision
expect "disabling the status fixture from its page is allowed" ok ipc smoke invokeInstance window vgs.settings toggle acme.status
expect_poll "a disabled plugin's dynamic Select is read-only and has no offered choices" '[0, "First offered (none available)", "", false]' device_state
expect_poll "a disabled plugin's rows all read not reported" '[["Check", "Not reported"], ["Last check", "Not reported"], ["Note", "Not reported"], ["Token", "Not reported", "Needed for the fixture'"'"'s sync", "Show command"], ["Pending", "Not reported"]]' drawn_status
expect "the window opens the notifications' page" ok ipc smoke invokeInstance window vgs.settings openPlugin vgs.notifications
slack_tokens_hint="One Slack app user token (xoxp-) per workspace with users:read and team:read, emoji:read optional for custom emoji. Create it at api.slack.com/apps, OAuth & Permissions, User Token Scopes."
# The Slack tokens row belongs to the owner-only Slack photos extra,
# off on a fresh profile: the page lists no row of it
# (docs/decisions/D075-consumer-features-need-no-developer-setup.md).
expect_poll "with the Slack photos extra off the notifications list no Slack tokens row" '[]' status_of vgs.notifications
expect_poll "the page draws no Status row with the extra off" '[]' drawn_status
# The control: the same readers find the row once the plugins row turns
# the extra on.
set_slack_photos on
expect_poll "the disabled notifications list the Slack tokens row unreported" '[["Slack tokens", "unreported", null, "", ""]]' status_of vgs.notifications
expect_poll "the page draws the Slack tokens row with its hint and no line per account" "$(python3 -c 'import json,sys; print(json.dumps([["Slack tokens", "Not reported", sys.argv[1]]]))' "$slack_tokens_hint")" drawn_status
expect "no Slack tokens row takes an edit" '[[]]' ipc smoke statusRowInputs window vgs.settings
set_slack_photos absent
expect_poll "the extra off again takes the Slack tokens row away" '[]' status_of vgs.notifications

expect "the gear closes the Settings window after the edit rows" ok ipc smoke invokeInstance "$(bar_key)" vgs.settings toggle ''
expect_poll "the Settings window is gone after the edit rows" 0 window_count Settings
expect "disabling the Settings plugin after its rows is allowed" ok ipc shell setPluginEnabled vgs.settings false
expect_poll "the Settings service released its shortcut and IPC target" False settings_lent

# The dispatch queue, driven through the fixture's compositor capability.
# Every queue row ends on workspace 2 and is reset to workspace 1 without
# a row of its own; the reset is the same dispatch the row just proved.
reset_workspace() { probe dispatch "focusWorkspace 1" >/dev/null && expect_poll "the compositor is back on the first workspace" 1 active_ws; }
expect "two workspace requests are accepted back to back" "ok,ok" probe batch "focusWorkspace 2;focusWorkspace 1"
expect_poll "the compositor ends on the later of two queued requests" 1 active_ws
expect "two workspace requests in the other order are accepted" "ok,ok" probe batch "focusWorkspace 1;focusWorkspace 2"
expect_poll "the compositor ends on the later request in that order too" 2 active_ws
reset_workspace
if queue_limit="$(node -e 'process.stdout.write(String(require("./bin/lib/qml-library.js").load("shell/Core/Dispatch.js").QUEUE_LIMIT))')"; then
  expected_errors+=('compositor: refused: dispatch-queue=full ')
  overflow() { probe flood "$((queue_limit + 2)) focusWorkspace 1" | sed 's/ request=.*//'; }
  expect "the request past the queue bound is refused" "refused: dispatch-queue=full limit=$queue_limit" overflow
  # The overflow leaves the queue full until the request running at the
  # time finishes, and a request refused as full is not queued, so the
  # request is repeated until one is accepted. Under 40 busy loops on the
  # owner's machine (host cachy, AMD Ryzen 9 9950X, 32 threads) on
  # 2026-09-27, eleven runs of an instrumented copy of this row under
  # scripts/qml-smoke.sh saw acceptance within 187 ms after at most one
  # refusal, and the queue drain behind it within 1693 ms; expect_poll
  # polls both at 0.2 s for up to 5 s.
  expect_poll "a request after the overflow is accepted" ok probe dispatch "focusWorkspace 2"
  expect_poll "the queue drains after the overflow" 2 active_ws
  reset_workspace
else
  fail "Dispatch.QUEUE_LIMIT unreadable"
fi
# A hyprctl that cannot start: the request is logged as a failed start and
# the next request runs.
expected_errors+=('compositor: dispatch-start=failed ')
shim_hyprctl unstartable
expect "a request whose process cannot start is accepted" ok probe dispatch "focusWorkspace 2"
expect_log "the failed start is logged with its request" 1 'compositor: dispatch-start=failed request='
shim_hyprctl real
expect "a request after the failed start is accepted" ok probe dispatch "focusWorkspace 2"
expect_poll "the queue runs again after a failed start" 2 active_ws
reset_workspace
