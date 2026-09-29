# Settings edits and the dispatch queue. The Settings window opens from a
# real click on the gear, so the compositor gives its layer the keyboard,
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
expect "the window opens the fixture's page" ok ipc smoke invokeInstance panel vgs.settings openPlugin acme.probe
expect_poll "the page draws the fixture's fields again" '[9, 0]' page_fields
held_rect="$(ipc smoke invokeInstance panel vgs.settings holdField '{"id":"acme.probe","key":"label","text":"draft"}')" || fail "holdField failed"
if [[ $held_rect == \[* ]]; then ok "an edit begins in the fixture's label field"; else fail "an edit begins in the fixture's label field: got $held_rect"; fi
read -r field_cx field_cy < <(at_centre vgs:panel "$held_rect")
click "$field_cx" "$field_cy" || fail "the click on the held field failed"
held_state() { ipc smoke invokeInstance panel vgs.settings heldFieldState ''; }
# The click also puts the cursor where it landed; the state read after it
# is what the unrelated changes must preserve.
held_focused() { held_state | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["same"] and d["focus"] and d["activeFocus"] and d["text"] == "draft")'; }
expect_poll "the clicked field holds keyboard focus with its draft" True held_focused
held_before="$(held_state)" || fail "held field state unreadable"
expect "the window toggles the bare fixture off around the edit" ok ipc smoke invokeInstance panel vgs.settings toggle acme.bare
expect_poll "the window shows the bare fixture disabled" '{"acme.bare": false, "acme.probe": true, "vgs.bar": true}' manager_rows
expect "the edit in progress survives the unrelated change" "$held_before" held_state
expect "the window toggles the bare fixture back on" ok ipc smoke invokeInstance panel vgs.settings toggle acme.bare
expect_poll "the window shows the bare fixture enabled" '{"acme.bare": true, "acme.probe": true, "vgs.bar": true}' manager_rows
expect "the edit in progress survives the second unrelated change" "$held_before" held_state

config_changes() { ipc smoke configChanges; }
user_loads() { ipc smoke configUserLoads; }
config_settled() { ipc smoke configSettled; }
user_label() { python3 -c 'import json,sys; print([e.get("label") for e in json.load(open(sys.argv[1])).get("plugins", []) if e["id"]=="acme.probe"][0])' "$home/.config/vgs/shell.json"; }
if changes_before="$(config_changes)" && loads_before="$(user_loads)"; then
  expect "the window writes the fixture's setting" ok ipc smoke invokeInstance panel vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"published-once"}'
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
  expect "the first of two rapid writes is accepted" ok ipc smoke invokeInstance panel vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"rapid-first"}'
  expect "the second of two rapid writes is accepted" ok ipc smoke invokeInstance panel vgs.settings applySetting '{"id":"acme.probe","key":"label","value":"rapid-second"}'
  expect_poll "the user file holds the later of two rapid writes" rapid-second user_label
  expect_poll "the rapid writes settled" true config_settled
  expect "each rapid write is published once" "$((changes_before + 2))" config_changes
  expect "the running service holds the later rapid write" '"rapid-second"' read_service label
else
  fail "configuration counters unreadable before the rapid write rows"
fi
# Status rows, D037: a page draws each status entry its manifest does not
# keep from Settings, read-only, with its label, its value in the tone of
# its type, its hint and the command it names, the entries without a group
# first; `data` and hidden entries are not drawn, an entry nothing published
# says so, and a disabled plugin's rows all say so. The status fixture,
# which rows/status.sh left disabled, publishes; the notifications, which
# the harness starts disabled, have published nothing.
fixture_command="secret-tool store --label='acme token' service acme account token"
status_of() { settings_rows | python3 -c 'import json,sys; r=[p for p in json.load(sys.stdin) if p["id"] == sys.argv[1]][0]["status"]; print(json.dumps([[s["label"], s["report"], s["value"], s["tone"], s["command"]] for s in r]))' "$1"; }
drawn_status() { ipc smoke itemTexts panel vgs.settings StatusRow | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
page_fields_of() { ipc smoke drawnFields panel vgs.settings | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d[sys.argv[1]], sum(v for k, v in d.items() if k != sys.argv[1])]))' "$1"; }
# The drawn rows with each time value replaced by `time` when it is drawn
# as a date, so a row compares the rows whatever the locale's format.
drawn_status_timeless() { drawn_status | python3 -c 'import json,re,sys; print(json.dumps([[("time" if re.search(r"\d", t) and len(t) > 6 else t) for t in r] if r[0] == "Last check" else r for r in json.load(sys.stdin)]))'; }
expect "enabling the status fixture for its Status rows is allowed" ok ipc shell setPluginEnabled acme.status true
expect_poll "the status fixture's service published its first value" '"ok"' ipc smoke readInstance service acme.status startReply
expect "the fixture publishes a state" ok ipc acme.status invoke set 'check={"tone":"warning","text":"Two sources failed"}'
expect "the fixture publishes a count" ok ipc acme.status invoke set 'pending=3'
expect "the fixture publishes a time" ok ipc acme.status invoke set 'lastCheck=1790650695194'
expect "the fixture publishes data" ok ipc acme.status invoke detail ''
expect "the window opens the status fixture's page" ok ipc smoke invokeInstance panel vgs.settings openPlugin acme.status
expect_poll "the manager row lists each drawn entry in manifest order, with its value and tone" "$(python3 -c 'import json,sys; print(json.dumps([["Token", "reported", "present", "success", sys.argv[1]], ["Check", "reported", {"tone": "warning", "text": "Two sources failed"}, "warning", ""], ["Pending", "reported", 3, "", ""], ["Last check", "reported", 1790650695194, "", ""], ["Note", "unreported", None, "", ""]]))' "$fixture_command")" status_of acme.status
expect_poll "the page draws the ungrouped entries, then each group's, read-only" "$(python3 -c 'import json,sys; print(json.dumps([["Check", "Two sources failed"], ["Last check", "time"], ["Note", "Not reported"], ["Token", "Present", "Needed for the fixture'"'"'s sync", sys.argv[1]], ["Pending", "3"]]))' "$fixture_command")" drawn_status_timeless
expect_poll "the page heads the status sections before any other" '["Status", "Sync"]' section_names
expect "no Status row takes an edit" '[[],[],[],[],[]]' ipc smoke statusRowInputs panel vgs.settings
expect "the page draws no settings field for the status fixture" '[0, 0]' page_fields_of acme.status
expect "disabling the status fixture from its page is allowed" ok ipc smoke invokeInstance panel vgs.settings toggle acme.status
expect_poll "a disabled plugin's rows all read not reported" '[["Check", "Not reported"], ["Last check", "Not reported"], ["Note", "Not reported"], ["Token", "Not reported", "Needed for the fixture'"'"'s sync", "'"$fixture_command"'"], ["Pending", "Not reported"]]' drawn_status
expect "the window opens the notifications' page" ok ipc smoke invokeInstance panel vgs.settings openPlugin vgs.notifications
expect_poll "the disabled notifications list the Slack token row unreported" "$(python3 -c 'import json,sys; print(json.dumps([["Slack token", "unreported", None, "", sys.argv[1]]]))' "secret-tool store --label='VGS notifications Slack token' service vgs-notifications account slack")" status_of vgs.notifications
expect_poll "the page draws the Slack token row with its hint and command" "$(python3 -c 'import json,sys; print(json.dumps([["Slack token", "Not reported", "Needed for sender photos in Slack notifications", sys.argv[1]]]))' "secret-tool store --label='VGS notifications Slack token' service vgs-notifications account slack")" drawn_status
expect "no Slack token row takes an edit" '[[]]' ipc smoke statusRowInputs panel vgs.settings

expect "the gear closes the Settings window after the edit rows" ok ipc smoke invokeInstance "$(bar_key)" vgs.settings toggle ''
expect_poll "the Settings window is gone after the edit rows" 0 layer_count vgs:panel
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
