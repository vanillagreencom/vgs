# Automations, vgs.automations. The harness starts it disabled; this row
# enables it over the harness's automations_stand_ins in the shell's own
# PATH directory: a systemctl that logs every verb, a systemd-run that logs
# its argv and runs the argv after `--`, a notify-send that logs its argv
# and prints an id; the harness's loginctl sentinel, which answers
# show-user with lingering off, and its crontab stand-in serve the whole
# run. No call can reach the
# host's systemd user manager or the user's crontab: the sandbox's runtime
# directory and session bus are its own, and every command the plugin runs
# resolves to a stand-in first. The row drives the engine, bin/automations,
# as the shell's service runs it, with the shell's environment.
#
# Rows: the service publishes its declared status, and its start with no
# automation runs no systemctl verb but show-environment; crontab resolves
# to the stand-in, with a control reading the host's PATH; an automation the
# engine adds writes its timer and service under the sandbox home, enables
# the timer and reaches only the stand-in crontab; the service counts it
# scheduled from the store change alone; a failed sync stays the Engine
# status after a list succeeds and clears once a sync succeeds; a
# failing Run now goes through systemd-run, sends the error notification
# with the VGS hints and reaches the Last runs status through the service's
# runs listing; the linger TUI opens through the stand-in terminal, from
# the IPC and from the Settings page's Enable while logged out, whose run's
# end lists lingering again and withdraws the action; the Automations
# window creates, edits, pauses, runs, removes and clears through the
# nested seat's pointer and keyboard alone, the CLI only reading each
# result back; and the control, a copy of the plugin whose service lists
# neither after a run file lands nor after the store changes and whose
# window's engine door drops every write and skips the transcript TUI,
# leaves the count as it was after the engine pauses the automation, Last
# runs as it was after the next failing run, and the store, the history
# and the TUI record as they were after the same clicks and keys. The row
# ends with the plugin disabled, its stand-ins removed and the shim files
# they covered restored.
set -euo pipefail
auto_stub="$sandbox/automations-stub"
# The systemctl stand-in fails daemon-reload while $auto_stub/fail-reload
# exists, so a row can make a sync fail.
automations_stand_ins "$auto_stub"
terminal_stand_in

auto_engine="$repo/shell/plugins/vgs.automations/bin/automations"
shell_path="$(tr '\0' '\n' <"/proc/$shell_qs_pid/environ" | sed -n 's/^PATH=//p')"
[[ -n $shell_path ]] || fail "the shell's PATH is unreadable"
automations() { "${shell_env[@]}" PATH="$shell_path" "$auto_engine" --tree "$repo" "$@" 2>>"$sandbox/automations.err"; }
# The last line a verb prints: a verb that syncs prints sync's line first.
auto_last() { local out; out="$(automations "$@")" || return; printf '%s\n' "${out##*$'\n'}"; }
auto_status() { ipc vgs.automations invoke status "" | py_reply 'import json,sys; v=json.load(sys.stdin); print(json.dumps(v.get(sys.argv[1], "unset")))' "$1"; }
auto_lent() { ipc shell lent | py_reply 'import json,sys; d=json.load(sys.stdin); r=d["status"].get("vgs.automations"); print(json.dumps([sorted(r["keys"]) if r else None, "vgs.automations" in d["ipcTargets"]]))'; }
# The systemctl verbs logged since the row began, show-environment left out.
auto_verbs() { if [[ -f $auto_stub/systemctl.calls ]]; then py_reply 'import json,sys; print(json.dumps([c[1] for c in map(json.loads, sys.stdin) if c[1] != "show-environment"]))' <"$auto_stub/systemctl.calls"; else echo '[]'; fi; }
auto_units() {
  if [[ ! -d $home/.config/systemd/user ]]; then echo '[]'; return; fi
  local names
  names="$(cd -- "$home/.config/systemd/user" && ls)" || return
  if [[ -z $names ]]; then echo '[]'; else py_reply 'import json,sys; print(json.dumps(sys.stdin.read().split()))' <<<"$names"; fi
}
# The VGS hints of the last notification, as its x-vgs names and values.
auto_hints() { if [[ -f $auto_stub/notify-send.calls ]]; then tail -n 1 -- "$auto_stub/notify-send.calls" | py_reply 'import json,sys; a=json.load(sys.stdin); print(json.dumps([h.split(":", 2)[1] + "=" + ("<path>" if h.split(":", 2)[1] == "x-vgs-open" else h.split(":", 2)[2]) for h in a if h.startswith("--hint=string:x-vgs-")]))'; else echo absent; fi; }
# resolved COMMAND PATH_LIST: the file COMMAND runs from on PATH_LIST, or
# none. The harness's crontab stand-in stays for the whole run, since
# crontab picks the caller's own table by user, not by HOME.
resolved() { PATH="$2" bash -c 'command -v "$1" || echo none' _ "$1"; }
crontab_calls() { if [[ -f $sandbox/crontab.calls ]]; then py_reply 'import json,sys; print(json.dumps(sys.stdin.read().splitlines()))' <"$sandbox/crontab.calls"; else echo '[]'; fi; }
last_systemd_run_prefix() { tail -n 1 -- "$auto_stub/systemd-run.calls" | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)[:3]))'; }
: >"$sandbox/crontab.calls"
# auto_problem: the Engine status as `<tone> <operation>` and the exit word,
# or `ok None`.
auto_problem() { auto_status problem | py_reply 'import json,sys; v=json.load(sys.stdin); print(" ".join([v["tone"]] + v["text"].split(" ")[:2]))'; }
failing='{"name": "Nightly", "command": "echo nope >&2; exit 3", "schedule": {"frequency": "weekly", "interval": 2, "weekdays": ["mon"], "times": ["03:00"], "start": "2026-01-05", "end": {"type": "never"}}}'

expect "the automations start disabled in the sandbox" False plugin_enabled vgs.automations
expect "enabling the automations is allowed" ok ipc shell setPluginEnabled vgs.automations true
expect_poll "the service holds its status record and IPC target" '[["active", "lastRuns", "linger", "nextRun", "problem", "scheduler"], true]' auto_lent
expect_poll "the scheduler reads the stand-in's systemd user manager" '{"tone": "ok", "text": "systemd user timers"}' auto_status scheduler
expect_poll "lingering reads off, offering its action" '{"tone": "warning", "text": "Automations run only while you are logged in", "action": true}' auto_status linger
expect "a start with no automation runs no systemctl verb" '[]' auto_verbs
expect "no unit is written with no automation" '[]' auto_units
expect "the shell's PATH resolves crontab to the harness's stand-in" "$shim/crontab" resolved crontab "$shell_path"
# The reader's control: the host's PATH alone resolves no stand-in, so the
# reading above is the shell's PATH and not the reader.
expect "the host's PATH alone resolves no stand-in crontab" True python3 -c 'import sys; print(sys.argv[1] != sys.argv[2])' "$(resolved crontab "$PATH")" "$shim/crontab"

expect "the engine adds an automation" added=nightly auto_last add --definition "$failing"
expect "its timer and service are under the sandbox home" '["vgs-automation-nightly.service", "vgs-automation-nightly.timer"]' auto_units
expect "the add reloads the manager and enables the timer" '["daemon-reload", "enable"]' auto_verbs
expect "the add's sync looked for a fallback block in the stand-in crontab alone" '["-l"]' crontab_calls
expect_poll "the service lists the engine's store change with no IPC call" 1 auto_status active
expect_poll "no run has failed yet" '{"tone": "ok", "text": "No failures"}' auto_status lastRuns

# A sync that fails stays the Engine status after the list that follows
# it succeeds, until a sync succeeds. The missing timer gives sync work.
: >"$auto_stub/fail-reload"
expected_errors+=('automations: sync exit=1 automations: refused: systemctl=failed args=daemon-reload exit=1')
unlink -- "$home/.config/systemd/user/vgs-automation-nightly.timer"
expect "the service syncs on request" ok ipc vgs.automations invoke sync ""
expect_poll "a failed sync is the Engine status after the list succeeds" "danger sync exit=1" auto_problem
expect_poll "the list after the failed sync still counts it" 1 auto_status active
unlink -- "$auto_stub/fail-reload"
expect "the service syncs again" ok ipc vgs.automations invoke sync ""
expect_poll "a sync that succeeds clears the Engine status" "ok None" auto_problem
expect "the timer is written again" '["vgs-automation-nightly.service", "vgs-automation-nightly.timer"]' auto_units

auto_rows_json() { automations list --json | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["automations"]))'; }
auto_row_value() { auto_rows_json | py_reply 'import json,sys; rows=json.load(sys.stdin); found=[r for r in rows if r["name"] == sys.argv[1] or r["id"] == sys.argv[1]];
if not found:
    print("absent"); raise SystemExit
row=found[0]; value=row;
for part in sys.argv[2].split("."): value=value[part]
print(json.dumps(value))' "$1" "$2"; }
auto_id_by_name() { auto_rows_json | py_reply 'import json,sys; rows=[r for r in json.load(sys.stdin) if r["name"] == sys.argv[1]]; print(rows[0]["id"] if rows else "")' "$1"; }
auto_preview_first() { auto_rows_json | py_reply 'import json,subprocess,sys; rows=json.load(sys.stdin); row=[r for r in rows if r["id"] == sys.argv[1]][0]; out=subprocess.check_output([sys.argv[2],"--tree",sys.argv[3],"preview","--schedule",json.dumps(row["schedule"]),"--count","1"], text=True); print(str(json.loads(out)["occurrences"][0]))' "$1" "$auto_engine" "$repo"; }
auto_row_exists() { auto_rows_json | py_reply 'import json,sys; print("present" if any(r["id"] == sys.argv[1] for r in json.load(sys.stdin)) else "absent")' "$1"; }
auto_history_count() { automations history --json | py_reply 'import json,sys; print(len([r for r in json.load(sys.stdin)["rows"] if r["automation"] == sys.argv[1]]))' "$1"; }
# The window's rows drive it through the nested seat alone: every store,
# unit and history change below comes from a click or a key in the
# window, and the engine is only read back. Each helper fails when its
# control is not drawn or its input does not reach the seat.
# ui_reveal TYPE TEXT: the item's scroll area moved, as a wheel would, so
# the item lies in view before a click; an item in view does not move it.
ui_reveal() { [[ $(ipc smoke revealItem window vgs.automations "$1" "$2") == \[* ]]; }
# ui_field_in LABEL TYPE TEXT NEW: the same inside the Field labelled LABEL.
ui_field_in() {
  [[ $(ipc smoke revealScopedItem window vgs.automations Field "$1" "$2" "$3") == \[* ]] || return
  click_scoped_in window:Automations window vgs.automations Field "$1" "$2" "$3" || return
  type_keys -M ctrl -k a -m ctrl "$4" && echo ok
}
ui_click() { ui_reveal "$1" "$2" && click_in window:Automations window vgs.automations "$1" "$2" && echo ok; }
ui_click_in_row() { click_scoped_in window:Automations window vgs.automations AutomationRow "$1" "$2" "$3" && echo ok; }
ui_confirm() { ipc smoke readInstance window vgs.automations confirmAction; }
ui_keys() { type_keys "$@" && echo ok; }
ui_field_type() { # TYPE TEXT NEW: click the field of TYPE reading TEXT, select all, type NEW
  ui_click "$1" "$2" >/dev/null || return
  type_keys -M ctrl -k a -m ctrl "$3" && echo ok
}
ui_row_names() { ipc smoke readInstance window vgs.automations automations | py_reply 'import json,sys; print(json.dumps([r["name"] for r in json.load(sys.stdin)]))'; }
ui_editor_open() { ipc smoke readInstance window vgs.automations editorOpen; }
ui_draft() { ipc smoke readInstance window vgs.automations draft | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)[sys.argv[1]]))' "$1"; }
ui_preview_first() { ipc smoke readInstance window vgs.automations previewFirst | py_reply 'import json,sys; print(json.load(sys.stdin))'; }
ui_history_opens_transcript() { # NAME
  click_in window:Automations window vgs.automations HistoryRow "$1" || return
  recorded_tail | py_reply 'import json,sys; t=sys.stdin.read().strip(); print(json.dumps(json.loads(t)[:2]) if t.startswith("[") else t)'

}
ui_create() { # NAME COMMAND: New, the name, the command and Save, by the pointer and typed text
  ui_click Button New >/dev/null || return
  ui_field_type TextField "New automation" "$1" >/dev/null || return
  ui_click TextArea "" >/dev/null || return
  type_keys "$2" || return
  ui_click Button Save
}
ui_focus_type() { ipc smoke activeFocusItem window vgs.automations | py_reply 'import json,sys; r=json.load(sys.stdin); print(r[0] if isinstance(r, list) else r)'; }
# keyboard_create WHERE NAME COMMAND: Ctrl+N, the name, Tab to the
# command and Ctrl+S, each key sent once its field holds the focus; no
# pointer event.
keyboard_create() {
  expect "Ctrl+N opens a new editor $1" ok ui_keys -M ctrl -k n -m ctrl
  expect_poll "the name field holds the keys $1" TextField ui_focus_type
  expect "the name is typed and Tab moves on $1" ok ui_keys -M ctrl -k a -m ctrl "$2" -k Tab
  expect_poll "Tab reaches the command $1" TextArea ui_focus_type
  expect "the command is typed and Ctrl+S saves $1" ok ui_keys "$3" -M ctrl -k s -m ctrl
}

expect "the automations window summons over IPC" ok ipc shell summon window vgs.automations '{}'
expect_poll "the automations window maps one window" 1 window_count Automations
expect_poll "the window takes the keyboard when it opens" true ipc smoke activeFocusIn window vgs.automations

# Create: New, typed fields and Save reach the engine's store.
expect "the pointer creates Smoke UI through the editor" ok ui_create "Smoke UI" "echo smoke-ui"
expect_poll "the CLI reads the automation the window created" '"echo smoke-ui"' auto_row_value smoke-ui command
expect "the window's draft is the saved automation" '"smoke-ui"' ui_draft id

# Edit the recurrence: the preset menu to Custom by its typed letter, the
# interval to 2, Save; the engine stores it and the drawn preview's first
# occurrence is the engine's own for the stored rule.
expect "the preset menu opens" ok ui_click Select "Every weekday"
# Custom is the menu's last entry; the list stops there.
expect "Down to the last entry and Return choose Custom" ok ui_keys -k Down -k Down -k Down -k Down -k Down -k Down -k Down -k Down -k Down -k Down -k Return
expect_poll "the editor shows the custom rule" '"custom"' ui_draft preset
expect "the interval takes 2" ok ui_field_in Every TextField 1 2
expect_poll "the draft holds the interval" 2 ui_draft interval
expect "Save stores the edited recurrence" ok ui_click Button Save
expect_poll "the CLI reads the edited recurrence interval" 2 auto_row_value smoke-ui 'schedule.interval'
expect_poll "the drawn preview's first occurrence is the engine's" "$(auto_preview_first smoke-ui)" ui_preview_first

# Toggle: the row's switch pauses and resumes the automation.
expect "Escape returns to the list" ok ui_keys -k Escape
expect_poll "the list is shown" false ui_editor_open
expect "a click on the row's switch pauses it" ok ui_click_in_row "Smoke UI" Switch ""
expect_poll "the CLI reads the disabled state" false auto_row_value smoke-ui enabled
expect "a second click resumes it" ok ui_click_in_row "Smoke UI" Switch ""
expect_poll "the CLI reads the enabled state" true auto_row_value smoke-ui enabled

# Run now from the row, then the History tab opens the run's transcript
# in the transcript TUI, which the stand-in terminal records only.
expect "the row's Run now starts a run" ok ui_click_in_row "Smoke UI" IconButton "Run now"
expect_poll "the run reaches the history rows" 1 auto_history_count smoke-ui
expect "the History tab opens" ok ui_click Label History
forget_record
expect_poll "a click on the history row opens its transcript TUI" "$(words vgs.automations/transcript tui/transcript.sh)" ui_history_opens_transcript "Smoke UI"

# Clear history: the button asks, Escape keeps the runs, Return clears.
expect "Clear history asks first" ok ui_click Button "Clear history"
expect_poll "the question shows" '"clear"' ui_confirm
expect "Escape dismisses the question" ok ui_keys -k Escape
expect_poll "the question is gone" '""' ui_confirm
expect "the dismissed question clears nothing" 1 auto_history_count smoke-ui
expect "Clear history asks again" ok ui_click Button "Clear history"
expect "Return confirms" ok ui_keys -k Return
expect_poll "the CLI reads history cleared by the window" 0 auto_history_count smoke-ui

# The keyboard alone: back to the Automations tab, then Ctrl+N, typing,
# Tab and Ctrl+S create an automation with no pointer event; the arrows
# reach its row, Delete asks, Escape keeps it and Delete, Return remove it.
expect "the Automations tab opens" ok ui_click Label Automations
keyboard_create "(keyboard)" "Smoke keyboard" "printf keyboard"
expect_poll "the CLI reads the keyboard-created automation" '"printf keyboard"' auto_row_value smoke-keyboard command
expect "Escape leaves the editor" ok ui_keys -k Escape
expect_poll "the list is shown again" false ui_editor_open
keyboard_row_index() { auto_rows_json | py_reply 'import json,sys; print([r["id"] for r in json.load(sys.stdin)].index(sys.argv[1]))' smoke-keyboard; }
list_current() { ipc smoke readInstance window vgs.automations listCurrent; }
select_keyboard_row() {
  local want i
  want="$(keyboard_row_index)" || return
  type_keys -k Home || return
  for ((i = 0; i < want; i++)); do type_keys -k Down || return; done
  list_current
}
expect_poll "the arrows select the keyboard row" "$(keyboard_row_index)" select_keyboard_row
expect "Delete asks to remove it" ok ui_keys -k Delete
expect_poll "the remove question shows" '"remove"' ui_confirm
expect "Escape keeps it" ok ui_keys -k Escape
expect_poll "the remove question is gone" '""' ui_confirm
expect "the kept automation remains" present auto_row_exists smoke-keyboard
expect "Delete asks again" ok ui_keys -k Delete
expect_poll "the remove question shows again" '"remove"' ui_confirm
expect "Return removes it" ok ui_keys -k Return
expect_poll "the CLI reads the keyboard-created automation removed" absent auto_row_exists smoke-keyboard

# The row menu removes the pointer-created automation.
expect "the row's menu opens" ok ui_click_in_row "Smoke UI" IconButton "More actions"
expect "a typed R and Return choose the menu's Remove" ok ui_keys r -k Return
expect_poll "the menu's remove question shows" '"remove"' ui_confirm
expect "Return removes it" ok ui_keys -k Return
expect_poll "the UI-created automation is gone before the controls" absent auto_row_exists smoke-ui

expect "Run now starts" started=nightly automations run-now nightly
expect "Run now goes through systemd-run" '["--user", "--collect", "--quiet"]' last_systemd_run_prefix
expect "the failure sends the error notification with its hints" '["x-vgs-icon=circle-x", "x-vgs-tone=danger", "x-vgs-click=open", "x-vgs-open=<path>"]' auto_hints
expect_poll "the run's records reach Last runs" '{"tone": "danger", "text": "Failing: Nightly"}' auto_status lastRuns

forget_record
expect "the linger IPC opens its TUI" ok ipc vgs.automations invoke linger ""
expect_poll "the terminal is handed the linger TUI" "$(words vgs.automations/linger tui/linger.sh)" recorded_tail
expect_run_end "the linger IPC's run ends" vgs.automations/linger

# Enable while logged out, D061: while lingering reads off, the Settings
# page offers the manifest's action, and its button opens the linger TUI.
# The run's end lists again, whoever opened it, and a loginctl that now
# answers yes withdraws the action. The control: the manager refuses the
# act once lingering is on, and starts nothing.
expected_errors+=('settings: vgs\.automations/linger refused: action=linger reason=not-offered')
settings_page_open vgs.automations
expect_poll "lingering off offers Enable while logged out" '[["linger", "Enable while logged out", true]]' offered_actions vgs.automations
forget_record
# The stand-in terminal runs no linger TUI, so the row itself turns
# lingering on: a loginctl that answers show-user with yes stands over the
# harness's sentinel before the press, and the service reads it when the
# run ends. Any other verb it logs as the sentinel does, and the sentinel
# comes back after.
printf '#!/usr/bin/env bash\nif [[ ${1:-} == show-user ]]; then echo yes; exit 0; fi\nprintf "%%s\\n" "loginctl $*" >>%q\nexit 1\n' "$auth_log" | sentinel_stand_over "$shim/loginctl"
expect "loginctl resolves to the row's stand-in on the shell's PATH" "$shim/loginctl" shell_resolves loginctl
settings_press "Enable while logged out" || fail "the click on Enable while logged out failed"
expect_poll "Enable while logged out hands the terminal the linger TUI" "$(words vgs.automations/linger tui/linger.sh)" recorded_tail
expect_run_end "the button's linger run ends" vgs.automations/linger
expect_poll "the run's end lists again and lingering reads on" '{"tone": "ok", "text": "Automations run while you are logged out"}' auto_status linger
expect_poll "lingering on offers no action" '[["linger", "Enable while logged out", false]]' offered_actions vgs.automations
forget_record
expect "the manager refuses the act while lingering is on" "refused: action=linger reason=not-offered" settings_act vgs.automations linger
expect "the refused act started no terminal" absent recorded
settings_page_close vgs.automations
sentinel_restore "$shim/loginctl"

# The control: a copy whose service lists neither after a run file lands
# nor after the store changes, the one timer both watchers restart. It
# carries a marker the row waits on, so every reading is the copy's. The
# engine clears the history first, so the copy's own start reads no
# failure; an engine change to the store and the next failing run then
# leave its status as it was.
expect "the history is cleared before the control" cleared=1 automations clear --all
auto_copy="$home/.config/vgs/plugins/vgs.automations"
mkdir -p "$auto_copy"
cp -R "$repo/shell/plugins/vgs.automations/." "$auto_copy/"
expected_errors+=('plugins: hidden by a higher-precedence plugin with the same id: vgs\.automations')
python3 - "$auto_copy/Service.qml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
needle = "        onTriggered: root.request([\"list\", \"--json\"])\n    }\n\n    Timer {\n        id: refresh"
assert text.count(needle) == 1, "the listSoon timer's list must occur once"
text = text.replace(needle, "        onTriggered: {}\n    }\n\n    Timer {\n        id: refresh", 1)
marker = "    id: root\n"
assert text.count(marker) == 1, "the root id must occur once"
open(path, "w").write(text.replace(marker, marker + "    property bool smokeControl: true\n", 1))
PY
# The same copy's window reaches the engine for no change and opens no
# transcript TUI: its engine door drops every write, and its transcript
# open returns before the core's TUI. The UI steps above, run against it,
# must leave the store, the history and the TUI record as they were.
python3 - "$auto_copy/Window.qml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
for old, new in (
    ("    function run(args, done) {\n", "    function run(args, done) {\n        return;\n"),
    ('shell.tui.run("transcript", [path])', '"ok"'),
):
    assert text.count(old) == 1, old
    text = text.replace(old, new, 1)
open(path, "w").write(text)
PY
expect "the control copy is scanned" ok ipc shell rescanPlugins
expect_poll "the control copy's service is built" true ipc smoke readInstance service vgs.automations smokeControl
expect_poll "the control copy's start reads no failure" '{"tone": "ok", "text": "No failures"}' auto_status lastRuns
expect_poll "the control copy's start counts the automation" 1 auto_status active
expect "the engine pauses the automation under the control" disabled=nightly auto_last disable nightly
expect "Run now starts under the control" started=nightly automations run-now nightly
# The shipped service lists 250 ms after a run file lands or the store
# changes, then waits on one engine call; two seconds is past both, so the
# readings below are the copy's settled answer and not a race.
sleep 2
expect "the control's count misses the store change" 1 auto_status active
expect "the control's Last runs misses the run" '{"tone": "ok", "text": "No failures"}' auto_status lastRuns
expect "the control copy's window summons" ok ipc shell summon window vgs.automations '{}'
expect_poll "the control copy's window maps" 1 window_count Automations
expect_poll "the control copy's window lists the automation" '["Nightly"]' ui_row_names
expect "the pointer create runs under the control" ok ui_create "Smoke control" "echo control"
sleep 2
expect "the control's pointer create reaches no store" absent auto_row_exists smoke-control
expect "Escape leaves the control's editor" ok ui_keys -k Escape
expect "a click on the control's switch runs" ok ui_click_in_row Nightly Switch ""
sleep 2
expect "the control's switch reaches no store" false auto_row_value nightly enabled
keyboard_create "(control)" "Smoke control keys" "printf control"
sleep 2
expect "the control's keyboard create reaches no store" absent auto_row_exists smoke-control-keys
expect "Escape leaves the control's editor again" ok ui_keys -k Escape
expect "the control's History tab opens" ok ui_click Label History
forget_record
expect "a click on the control's history row runs" ok ui_click HistoryRow Nightly
sleep 2
expect "the control's history click opens no TUI" absent recorded
expect "the control's Clear history asks" ok ui_click Button "Clear history"
expect "Return confirms under the control" ok ui_keys -k Return
sleep 2
expect "the control's clear removes no run" 1 auto_history_count nightly
rm -r -- "$auto_copy"
expect "the shipped plugin is scanned again" ok ipc shell rescanPlugins
expect_poll "the shipped service lists the paused automation" 0 auto_status active

expect "the engine removes the automation" removed=nightly auto_last remove nightly
expect "its units are gone" '[]' auto_units
expect "disabling the automations is allowed" ok ipc shell setPluginEnabled vgs.automations false
expect_poll "the disabled service holds no status record or IPC target" '[null, false]' auto_lent
automations_stand_ins_restore "$auto_stub"
