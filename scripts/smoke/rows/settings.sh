# Settings edits and the dispatch queue. A manager write is published
# once: its own file notification is read and found identical. An
# unrelated change keeps an edit in progress: the same drawn field, its
# focus, its text and its cursor. Dispatches asked for back to back run in
# order behind one process, the queue has a bound, and a process that
# cannot start does not stop the queue.
set -euo pipefail
expect "the manager button opens the manager panel for the edit rows" ok ipc shell invokeInstance "$(bar_key)" vgs.bar/right-manager toggle ''
expect_poll "the manager panel draws the fixture's label field again" '[1, 1, 0]' manager_drawn
expect "an edit begins in the fixture's label field" held ipc shell invokeInstance panel vgs.bar holdField '{"id":"acme.probe","key":"label","text":"draft"}'
expect "the manager toggles the bare fixture off around the edit" ok ipc shell invokeInstance panel vgs.bar toggle acme.bare
expect_poll "the manager panel shows the bare fixture disabled" '{"acme.bare": false, "acme.probe": true, "vgs.bar": true}' manager_rows
expect "the edit in progress survives the unrelated change" '{"same":true,"focus":true,"text":"draft","cursor":1}' ipc shell invokeInstance panel vgs.bar heldFieldState ''
expect "the manager toggles the bare fixture back on" ok ipc shell invokeInstance panel vgs.bar toggle acme.bare
expect_poll "the manager panel shows the bare fixture enabled" '{"acme.bare": true, "acme.probe": true, "vgs.bar": true}' manager_rows
expect "the edit in progress survives the second unrelated change" '{"same":true,"focus":true,"text":"draft","cursor":1}' ipc shell invokeInstance panel vgs.bar heldFieldState ''

config_changes() { ipc shell configChanges; }
user_loads() { ipc shell configUserLoads; }
config_settled() { ipc shell configSettled; }
user_label() { python3 -c 'import json,sys; print([e.get("label") for e in json.load(open(sys.argv[1])).get("plugins", []) if e["id"]=="acme.probe"][0])' "$home/.config/vgs/shell.json"; }
if changes_before="$(config_changes)" && loads_before="$(user_loads)"; then
  expect "the manager form writes the fixture's setting" ok ipc shell invokeInstance panel vgs.bar applySetting '{"id":"acme.probe","key":"label","value":"published-once"}'
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
  expect "the first of two rapid writes is accepted" ok ipc shell invokeInstance panel vgs.bar applySetting '{"id":"acme.probe","key":"label","value":"rapid-first"}'
  expect "the second of two rapid writes is accepted" ok ipc shell invokeInstance panel vgs.bar applySetting '{"id":"acme.probe","key":"label","value":"rapid-second"}'
  expect_poll "the user file holds the later of two rapid writes" rapid-second user_label
  expect_poll "the rapid writes settled" true config_settled
  expect "each rapid write is published once" "$((changes_before + 2))" config_changes
  expect "the running service holds the later rapid write" '"rapid-second"' read_service label
else
  fail "configuration counters unreadable before the rapid write rows"
fi
expect "the manager button closes the manager panel after the edit rows" ok ipc shell invokeInstance "$(bar_key)" vgs.bar/right-manager toggle ''
expect_poll "the manager panel is gone after the edit rows" 0 layer_count vgs:panel

# The dispatch queue, driven through the fixture's compositor capability.
expect "two workspace requests are accepted back to back" "ok,ok" probe batch "focusWorkspace 2;focusWorkspace 1"
expect_poll "the compositor ends on the later of two queued requests" 1 active_ws
expect "two workspace requests in the other order are accepted" "ok,ok" probe batch "focusWorkspace 1;focusWorkspace 2"
expect_poll "the compositor ends on the later request in that order too" 2 active_ws
expect "the compositor returns to the first workspace" ok probe dispatch "focusWorkspace 1"
expect_poll "the compositor moved back to the first workspace after the queue rows" 1 active_ws
if queue_limit="$(node -e 'process.stdout.write(String(require("./scripts/qml-library.js").load("shell/Core/Dispatch.js").QUEUE_LIMIT))')"; then
  expected_errors+=('compositor: refused: dispatch-queue=full ')
  overflow() { probe flood "$((queue_limit + 2)) focusWorkspace 1" | sed 's/ request=.*//'; }
  expect "the request past the queue bound is refused" "refused: dispatch-queue=full limit=$queue_limit" overflow
  expect "a request after the overflow is accepted" ok probe dispatch "focusWorkspace 2"
  expect_poll "the queue drains after the overflow" 2 active_ws
  expect "the compositor returns to the first workspace after the overflow" ok probe dispatch "focusWorkspace 1"
  expect_poll "the compositor moved back after the overflow rows" 1 active_ws
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
expect "the compositor returns to the first workspace after the failed start rows" ok probe dispatch "focusWorkspace 1"
expect_poll "the compositor moved back after the failed start rows" 1 active_ws
