# vgs.agent-warden, D041. The service is the one reader of the warden's
# status file. The row writes vsys's own fixture documents into the
# sandbox's runtime dir, $rt_dir/agent-warden/status.json, each replaced by
# rename as the warden replaces it, with its time and its events' set to
# now, so it is fresh, or ten minutes back, so it is stale. It reads each
# state back through the plugin's `status` IPC function, which answers the
# record the core holds, and reads the plugin's Settings rows back from the
# Settings window. An older warden's state.json alone reads as Update the
# warden, and the empty directory as Not set up. `vsys` reads absent or
# present from the scan as a stub on the sandbox PATH comes and goes; the
# host's PATH sets its first answer. A status written 85 s back and left
# unchanged turns stale on the service's own timer, with no file change.
# The shield in the bar and its panel are read back as drawn for each
# state: the icon, tone, count and tooltip, and every text the panel draws,
# none of which names a scope unit or a process id. Set up and Open vsys
# hand the stand-in terminal their TUI's argv, Start it hands a stand-in
# systemctl its arguments, and, on a host without vsys, Get vsys raises the
# core's notice, which the scan that finds vsys closes. Each open runs the
# stand-in vsys's summary once, and a summary that fails when the open
# panel is summoned again leaves no earlier line.
# A stand-in notify-send records every notice. The service touches the
# warden's heartbeat while a status reads, and again at once when one
# reads after an unreadable one. It sends one notice per episode across
# ticks, and again after the episode clears, as Agent Warden with its
# urgency and Open vsys, sends nothing under notify: off, shows a move as
# a toast under notify: everything, and a press on Open vsys hands the
# stand-in terminal the vsys TUI's argv. A notice whose run fails, or
# cannot start, goes out again on the next status; runs waiting for a
# press stop at eight, the rest going without the button; and a run that
# ends gives its place back.
# Eight controls are copies of the plugin installed over the bundled one:
# a logic copy that ignores staleness reads the stale document as calm, a
# service copy whose timer derives nothing keeps the ageing status calm
# past its stale moment, a logic copy that hands the view each lane's
# scope unit draws it in the panel, a panel copy that keeps its last
# summary line when a new run starts still draws it after a failed run, a
# notices copy without episode memory sends a lane's notice again on its
# next tick, a service copy that keeps a failed run's episodes sends them
# once only, one that never counts a waiting run offers the button on
# every run, and one that never gives a place back sends later notices
# without the button.
# The harness starts the plugin disabled; the row ends with it disabled,
# its runtime files gone and no stub on PATH.
set -euo pipefail
warden_dir="$rt_dir/agent-warden"
warden_fixtures="$repo/scripts/smoke/fixtures/agent-warden"
warden_copy="$home/.config/vgs/plugins/vgs.agent-warden"
rm -rf -- "$warden_dir"
# warden_put NAME AGE [KIND]: status-NAME.json with its time and every
# event's set AGE seconds before now, and every event's kind set to KIND
# when given, replaced into place by rename; prints the time.
warden_put() {
  python3 - "$warden_fixtures/status-$1.json" "$warden_dir" "$2" "${3:-}" <<'PY'
import json, os, sys, time
source, target, age, kind = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
doc = json.load(open(source))
moment = int(time.time()) - age
doc["time"] = moment
for event in doc["events"]:
    event["time"] = moment
    if kind:
        event["kind"] = kind
tmp = os.path.join(target, "status.tmp.%d" % os.getpid())
with open(tmp, "w") as out:
    json.dump(doc, out)
os.replace(tmp, os.path.join(target, "status.json"))
print(moment)
PY
}
# warden_raw TEXT: TEXT as status.json, replaced into place by rename.
warden_raw() { printf '%s' "$1" >"$warden_dir/status.tmp.raw" && mv -T -- "$warden_dir/status.tmp.raw" "$warden_dir/status.json"; }
warden_values() { ipc vgs.agent-warden invoke status ''; }
# warden_value KEY: one published value as JSON, `null` when unpublished.
warden_value() { warden_values | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get(sys.argv[1])))' "$1"; }
# The published detail's state and reason, and each item's kind and level.
warden_state() { warden_values | python3 -c 'import json,sys; d=json.load(sys.stdin).get("detail"); print("unpublished" if d is None else json.dumps([d["state"], d["reason"], d["issues"], [[i["kind"], i["level"]] for i in d["items"]]]))'; }
warden_lent() { ipc shell lent | python3 -c 'import json,sys; r=json.load(sys.stdin)["status"].get("vgs.agent-warden"); print(json.dumps(r if r is None else r["keys"]))'; }
warden_rows() { settings_rows | py_reply 'import json,sys; r=[p for p in json.load(sys.stdin) if p["id"] == "vgs.agent-warden"][0]["status"]; print(json.dumps([[s["label"], s["report"], s["value"], s["tone"], s["command"]] for s in r]))'; }
# The answer the scan gives for vsys on the sandbox PATH.
vsys_on_path() { if "${shell_env[@]}" PATH="$shim:$(dirname -- "$node_bin"):$PATH" bash -c 'command -v vsys' >/dev/null; then echo '"present"'; else echo '"absent"'; fi; }
# A notify-send stand-in in the shell's own PATH directory, written before
# the service first runs, so no notice of the row reaches a notification
# server: it appends each call's argv as one JSON line to $warden_sent;
# fails with exit 1 while $warden_fail exists; for a call offering an
# action, waits while $warden_hold exists, as notify-send waits for the
# notice to close; and prints `open`, as notify-send prints the action
# pressed, while $warden_press exists. The wait ends after 2400 polls,
# 120 s, whatever the file does: a ceiling well past the held rows'
# polls, not a measurement, so an interrupted run leaves no stand-in
# behind.
warden_sent="$sandbox/warden-notify-send"
warden_press="$sandbox/warden-press"
warden_fail="$sandbox/warden-fail"
warden_hold="$sandbox/warden-hold"
cat >"$shim/notify-send" <<EOF
#!/usr/bin/env bash
python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "\$@" >>"$warden_sent"
if [[ -e "$warden_fail" ]]; then echo "notify-send: stand-in failure" >&2; exit 1; fi
for a; do
  if [[ \$a == -A ]]; then
    n=0
    while [[ -e "$warden_hold" && \$n -lt 2400 ]]; do sleep 0.05; n=\$((n + 1)); done
  fi
done
if [[ -e "$warden_press" ]]; then echo open; fi
EOF
chmod 755 "$shim/notify-send"
# The calls the stand-in recorded.
warden_sent_count() { if [[ -f $warden_sent ]]; then wc -l <"$warden_sent"; else echo 0; fi; }
# warden_notices_since N: each call after the first N as [urgency, title,
# whether it offers Open vsys], sorted, one JSON list. The runs one status
# starts write in any order.
warden_notices_since() {
  python3 - "$warden_sent" "$1" <<'PY'
import json, os, sys
path, skip = sys.argv[1], int(sys.argv[2])
calls = [json.loads(l) for l in open(path)][skip:] if os.path.exists(path) else []
print(json.dumps(sorted([a[a.index("-u") + 1], a[a.index("--") + 1], "-A" in a] for a in calls)))
PY
}
# warden_call N TITLE: the argv of the first call after the first N whose
# title is TITLE, as one JSON line, or `absent`.
warden_call() { python3 -c '
import json, os, sys
calls = [json.loads(l) for l in open(sys.argv[1])][int(sys.argv[2]):] if os.path.exists(sys.argv[1]) else []
found = [a for a in calls if a[a.index("--") + 1] == sys.argv[3]]
print(json.dumps(found[0]) if found else "absent")' "$warden_sent" "$1" "$2"; }
# The heartbeat as the warden reads it: `fresh` when the file holds a time
# in milliseconds and was written in the last 10 s, `stale` otherwise, or
# `absent`.
warden_heartbeat() {
  python3 - "$warden_dir/notifier" <<'PY'
import os, sys, time
path = sys.argv[1]
if not os.path.exists(path):
    print("absent"); sys.exit()
text, now = open(path).read().strip(), time.time()
print("fresh" if text.isdigit() and abs(int(text) / 1000 - now) < 10 and now - os.stat(path).st_mtime < 10 else "stale")
PY
}
# The scan's answer for one of the plugin's requirement commands.
warden_requirement() { ipc shell listPlugins | python3 -c 'import json,sys; p=[p for p in json.load(sys.stdin)["plugins"] if p["id"]=="vgs.agent-warden"][0]; print([r["state"] for r in p["requirements"] if r["command"]==sys.argv[1]][0])' "$1"; }
expected_errors+=('agent-warden: status=unreadable cause=json ' 'agent-warden: status=schema schema=2\.0 ' 'agent-warden: summary=failed ' 'plugins: hidden by a higher-precedence plugin with the same id: vgs\.agent-warden' 'agent-warden: notice=(tasks|memory) failed=')

expect "a rescan after the notify-send stand-in arrives starts" ok ipc shell rescanPlugins
expect_poll "the scan finds notify-send" present warden_requirement notify-send
expect "enabling the agent warden is allowed" ok ipc shell setPluginEnabled vgs.agent-warden true
expect_poll "the agent warden's service is built" True record_exists vgs.agent-warden
expect_poll "no warden directory reads as not set up" '["not-set-up", null, 0, []]' warden_state
expect "no status leaves the heartbeat alone" absent warden_heartbeat
expect "an absent status logs nothing" 0 log_lines 'agent-warden: status='
expect "the warden row says it is not set up" '{"tone": "info", "text": "Not set up"}' warden_value warden
expect "no agent count is published before a status" null warden_value agents
expect "the lending record holds the published keys" '["detail", "vsys", "warden"]' warden_lent
vsys_first="$(vsys_on_path)"
expect "vsys reads as the scan finds it on the sandbox PATH" "$vsys_first" warden_value vsys

cp -- "$warden_fixtures/state.json" "$warden_dir/state.json"
expect_poll "an older warden's state.json alone reads as update the warden" '["update-warden", null, 0, []]' warden_state
expect "the warden row asks for an update" '{"tone": "warning", "text": "Update the warden"}' warden_value warden

calm_time="$(warden_put calm 0)"
expect_poll "a fresh calm status reads as calm" '["calm", null, 0, []]' warden_state
expect_poll "a status that reads starts the heartbeat" fresh warden_heartbeat
expect "the warden row says it checks" '{"tone": "ok", "text": "Checking"}' warden_value warden
expect "one agent runs in the calm status" 1 warden_value agents
expect "the last check is the status time" "$((calm_time * 1000))" warden_value lastCheck
expect "the lending record holds every declared key" '["agents", "detail", "lastCheck", "vsys", "warden"]' warden_lent

# Each document replaces the last by rename, as the warden writes it.
warden_put near-limit 0 >/dev/null
expect_poll "a lane near its limits needs a look" '["look", null, 1, [["near", "look"]]]' warden_state
warden_put holding-off 0 >/dev/null
expect_poll "held-off moves above the slowdown point are a problem" '["problem", null, 2, [["headroom", "problem"], ["slowdown", "look"]]]' warden_state
warden_put partial 0 >/dev/null
expect_poll "a partial move is a problem" '["problem", null, 1, [["partial", "problem"]]]' warden_state
warden_put reaped 0 >/dev/null
expect_poll "a cleanup is a problem" '["problem", null, 1, [["reaped", "problem"]]]' warden_state
warden_put reaped 600 >/dev/null
expect_poll "a status ten minutes old reads as not checking" '["not-checking", "stale", 0, []]' warden_state
expect "the warden row says it stopped checking" '{"tone": "warning", "text": "Stopped checking"}' warden_value warden
# A fresh status the warden stops rewriting: the file stays as it is and
# the service's timer turns it stale at its time plus 90 s, which is about
# 5 s after the write. The poll allows 15 s.
warden_stamp() { stat -c '%i %Y' -- "$warden_dir/status.json"; }
# warden_ages LABEL: polls for up to 15 s until the unchanged status reads
# as stale, then checks the file was not replaced meanwhile.
warden_ages() {
  local stamp got="" i
  stamp="$(warden_stamp)" || { fail "$1: the status file is unreadable"; return; }
  for i in $(seq 1 75); do
    got="$(warden_state)" || got=""
    [[ $got == '["not-checking", "stale", 0, []]' ]] && break
    sleep 0.2
  done
  if [[ $got != '["not-checking", "stale", 0, []]' ]]; then fail "$1: got $got"; return; fi
  if [[ $(warden_stamp) == "$stamp" ]]; then ok "$1"; else fail "$1: the status file changed during the wait"; fi
}
warden_put calm 85 >/dev/null
expect_poll "a status 85 s old reads as calm" '["calm", null, 0, []]' warden_state
warden_ages "the unchanged status turns stale at its moment"
warden_raw '{'
expect_poll "a status that is not JSON reads as not checking" '["not-checking", "unreadable", 0, []]' warden_state
expect "the warden row says the status is unreadable" '{"tone": "danger", "text": "Status unreadable"}' warden_value warden
expect_log "the unreadable status is logged" 1 'agent-warden: status=unreadable cause=json '
# The heartbeat stops while no status reads. The file goes now, so the
# write that starts it again is told apart from the next minute's.
rm -f -- "$warden_dir/notifier"
warden_raw '{"schema": "2.0"}'
expect_poll "a newer major reads as not checking" '["not-checking", "schema", 0, []]' warden_state
expect_log "the unsupported major is logged" 1 'agent-warden: status=schema schema=2\.0 '
calm_time="$(warden_put calm 0)"
expect_poll "a fresh status after the refusals reads as calm again" '["calm", null, 0, []]' warden_state
expect_poll "a status that reads again touches the heartbeat at once" fresh warden_heartbeat

# The Settings page draws the four rows, never `detail`.
expect "enabling the Settings plugin for the warden's rows is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "the Settings service is built" True record_exists vgs.settings
expect "the Settings window is summoned" ok ipc shell summon window vgs.settings '{}'
expect_poll "the Settings rows show the warden, the agents, the last check and vsys" "$(python3 -c 'import json,sys; print(json.dumps([["Warden", "reported", {"tone": "ok", "text": "Checking"}, "success", "vsys warden install"], ["Agents running", "reported", 1, "", ""], ["Last check", "reported", int(sys.argv[1]) * 1000, "", ""], ["vsys", "reported", json.loads(sys.argv[2]), {"present": "success", "absent": "warning"}[json.loads(sys.argv[2])], "curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vsys/main/install.sh | bash"]]))' "$calm_time" "$vsys_first")" warden_rows
expect "the Settings window is hidden" ok ipc shell hide window vgs.settings
expect "disabling the Settings plugin after the rows is allowed" ok ipc shell setPluginEnabled vgs.settings false

# vsys follows the scan: a stub on the sandbox PATH is present after a
# rescan and gone after the next, and the service is not rebuilt.
printf '#!/bin/sh\nexit 0\n' >"$shim/vsys"; chmod 755 "$shim/vsys"
expect "a rescan after vsys arrives starts" ok ipc shell rescanPlugins
expect_poll "vsys reads as present" '"present"' warden_value vsys
rm -f -- "$shim/vsys"
expect "a rescan after vsys goes starts" ok ipc shell rescanPlugins
expect_poll "vsys reads as the host PATH gives it again" "$vsys_first" warden_value vsys

rm -f -- "$warden_dir/status.json"
expect_poll "state.json left alone reads as update the warden again" '["update-warden", null, 0, []]' warden_state
rm -f -- "$warden_dir/state.json"
expect_poll "an empty directory reads as not set up again" '["not-set-up", null, 0, []]' warden_state

# The shield and its panel, read back as drawn. Enabling placed the widget
# in its default section. The shield is read as its icon, the
# Theme.badge.tone group whose foreground it draws in, its count and its
# tooltip; the panel as every text it draws, with the check time's number
# written N. Stand-ins in the shell's own PATH directory: a vsys that
# records each call's arguments and answers `--once --summary` with one
# warning, and a systemctl that records its arguments, so Start it never
# reaches a user manager. The terminal is harness.sh's recording stand-in,
# written again over the one rows/updates.sh left.
warden_key="$(bar_key)"
warden_vsys_log="$sandbox/warden-vsys-calls"
warden_systemctl_log="$sandbox/warden-systemctl-argv"
# While this file exists the stand-in vsys fails its summary.
warden_vsys_fails="$sandbox/warden-vsys-fails"
warden_summary='{"schema": "vsys.summary.v1", "time": 1, "verdict": [{"cause": "memory-high", "level": "warn", "subject": "/agents.slice"}, {"cause": "scratch", "level": null, "subject": null}], "meters": [], "errors": []}'
warden_vsys_stub() {
  cat >"$shim/vsys" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$warden_vsys_log"
if [[ "\$*" == "--once --summary" ]]; then
  if [[ -e "$warden_vsys_fails" ]]; then echo "vsys: stand-in summary failed" >&2; exit 1; fi
  printf '%s\n' '$warden_summary'
fi
EOF
  chmod 755 "$shim/vsys"
}
warden_systemctl_stub() {
  cat >"$shim/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$warden_systemctl_log"
EOF
  chmod 755 "$shim/systemctl"
}
warden_section() { ipc shell listShellConfig | python3 -c 'import json,sys; l=json.load(sys.stdin)["bar"]["layout"]; print(([s for s in ("left","center","right") if any(e["id"]==sys.argv[1] for e in l.get(s,[]))] + ["none"])[0])' vgs.agent-warden; }
warden_tones="$(python3 -c 'import json,sys; print(json.dumps(dict(zip(["neutral", "accent", "warning", "danger"], [json.loads(v).lower() for v in sys.argv[1:]]))))' \
  "$(ipc smoke themeValue badge.tone.neutral.foreground)" "$(ipc smoke themeValue badge.tone.accent.foreground)" \
  "$(ipc smoke themeValue badge.tone.warning.foreground)" "$(ipc smoke themeValue badge.tone.danger.foreground)")" || fail "the badge tones are unreadable"
# The shield as [icon, tone, count, tooltip], or `absent`.
warden_shield() {
  local icon colours tip texts
  icon="$(ipc smoke readDescendant "$warden_key" vgs.agent-warden Icon name)" && colours="$(ipc smoke itemColours "$warden_key" vgs.agent-warden Widget Icon)" \
    && tip="$(ipc smoke readDescendant "$warden_key" vgs.agent-warden Tooltip text)" && texts="$(ipc smoke itemTexts "$warden_key" vgs.agent-warden Widget)" || return
  python3 - "$icon" "$colours" "$tip" "$texts" "$warden_tones" <<'PY'
import json, sys
icon, colours, tip, texts, tones = sys.argv[1:6]
if "absent" in (icon, colours, tip, texts):
    print("absent"); sys.exit()
colour = json.loads(colours)[0][0]
names = [name for name, value in json.loads(tones).items() if "#" + value[3:9] + value[1:3] == colour]
print(json.dumps([json.loads(icon), names[0] if len(names) == 1 else "colour=" + colour, (json.loads(texts)[0] + [""])[0], json.loads(tip)]))
PY
}
warden_panel_shown() { [[ $(ipc smoke readInstance panel vgs.agent-warden detail) != absent ]] && echo shown || echo hidden; }
# Every text the panel draws, or `absent`.
warden_panel() { ipc smoke itemTexts panel vgs.agent-warden Panel | py_reply '
import json, re, sys
t = sys.stdin.read().strip()
rows = [] if t == "absent" else json.loads(t)
print(json.dumps([re.sub(r"^Checked \d+ (s|min) ago$", "Checked N ago", x) for x in rows[0]]) if rows else "absent")'; }
# warden_names_nothing FIXTURE: the first scope unit or process id of
# status-FIXTURE.json the panel or the tooltip draws, `clean` for none, or
# `absent` with no panel to read.
warden_names_nothing() {
  local texts tip
  texts="$(ipc smoke itemTexts panel vgs.agent-warden Panel)" && tip="$(ipc smoke readDescendant "$warden_key" vgs.agent-warden Tooltip text)" || return
  python3 - "$warden_fixtures/status-$1.json" "$texts" "$tip" <<'PY'
import json, sys
doc, texts, tip = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
rows = [] if texts == "absent" else json.loads(texts)
if not rows or tip == "absent":
    print("absent"); sys.exit()
found = []
def visit(value):
    if isinstance(value, list):
        for inner in value: visit(inner)
    elif isinstance(value, dict):
        for key, inner in value.items():
            if key == "scope" and isinstance(inner, str): found.append(inner)
            elif key == "pid" and isinstance(inner, int): found.append(str(inner))
            else: visit(inner)
visit(doc)
drawn = "\n".join(rows[0] + [json.loads(tip)])
hits = [s for s in found if s in drawn]
print(hits[0] if hits else "clean")
PY
}
warden_summary_runs() { [[ -f $warden_vsys_log ]] || { echo 0; return; }; python3 -c 'import sys; print(sum(1 for l in open(sys.argv[1]) if l == "--once --summary\n"))' "$warden_vsys_log"; }
warden_last_vsys() { [[ -f $warden_vsys_log ]] && tail -n 1 -- "$warden_vsys_log" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))' || echo absent; }
warden_systemctl_argv() { [[ -f $warden_systemctl_log ]] && cat -- "$warden_systemctl_log" || echo absent; }
# The notice the core shows as [plugin, commands], or null.
warden_notice() { notice_shown | python3 -c 'import json,sys; s=json.load(sys.stdin); print(json.dumps(None if s is None else s[:2]))'; }
# warden_open LABEL: a click on the shield opens the panel, which runs the
# summary once while vsys is present and never without it.
warden_open() {
  local runs
  runs="$(warden_summary_runs)"
  click_centre "$warden_key" vgs.agent-warden || fail "$1: the click on the shield failed"
  expect_poll "$1: a click on the shield opens the panel" shown warden_panel_shown
  if [[ "$(warden_value vsys)" == '"present"' ]]; then
    expect_poll "$1: the open runs vsys --once --summary once" "$((runs + 1))" warden_summary_runs
  else
    expect "$1: an open without vsys runs no summary" "$runs" warden_summary_runs
  fi
}
warden_line='vsys sees one thing worth a look on this computer.'
# Whether the panel draws the stand-in summary's line: True or False.
warden_panel_has_line() { warden_panel | py_reply 'import json,sys; t=sys.stdin.read().strip(); print(t != "absent" and sys.argv[1] in json.loads(t))' "$warden_line"; }
# warden_resummon LABEL: the open panel summoned again runs the summary
# once more, as the core calls open() on a panel already shown.
warden_resummon() {
  local runs
  runs="$(warden_summary_runs)"
  expect "$1: the open panel is summoned again" ok ipc shell summon panel vgs.agent-warden '{}'
  expect_poll "$1: the summon runs the summary once more" "$((runs + 1))" warden_summary_runs
}

expect "enabling placed the shield in the bar's right section" right warden_section
expect_poll "the shield is built on the bar" '"vgs.agent-warden"' ipc smoke readInstance "$warden_key" vgs.agent-warden moduleName
terminal_stand_in
warden_vsys_stub
expect "a rescan after the stand-in vsys arrives starts" ok ipc shell rescanPlugins
expect_poll "the stand-in vsys reads as present" '"present"' warden_value vsys

expect_poll "the shield reads not set up" '["shield-question-mark", "neutral", "", "Agent Warden isn'"'"'t set up"]' warden_shield
warden_open "not set up"
expect_poll "the not-set-up panel offers Set up and the link" "$(words Agents "Agent Warden isn't set up." "$warden_line" "Set up" "Open vsys")" warden_panel
click_item panel vgs.agent-warden Button "Set up" || fail "the click on Set up failed"
expect_poll "Set up hands the terminal the setup TUI" "$(words vgs.agent-warden/setup tui/setup.sh)" recorded_tail
expect_poll "the Set up hand-off closes the panel" hidden warden_panel_shown
expect_run_end "the setup run ends" vgs.agent-warden/setup

cp -- "$warden_fixtures/state.json" "$warden_dir/state.json"
expect_poll "the shield reads an older warden" '["shield-alert", "warning", "", "Agent Warden needs an update"]' warden_shield
warden_open "an older warden"
expect_poll "an older warden's panel offers Update" "$(words Agents "Agent Warden needs an update." "$warden_line" Update "Open vsys")" warden_panel
expect "the older warden's panel is hidden" ok ipc shell hide panel vgs.agent-warden
rm -f -- "$warden_dir/state.json"

# Fresh states, the panel open throughout.
warden_put calm 0 >/dev/null
expect_poll "the shield reads calm with one agent" '["shield-check", "neutral", "1", "1 agent running within its limits"]' warden_shield
warden_open "calm"
expect_poll "the calm panel says so, with the meter, the summary and the link" \
  "$(words Agents "All good. 1 agent is running within its limits." "Agent memory: 38 of 64 GB before slowdown" "$warden_line" "Checked N ago" "Open vsys")" warden_panel
# A summary that fails on a later open leaves no earlier verdict behind.
touch -- "$warden_vsys_fails"
warden_resummon "a failing summary"
expect_poll "a failed summary on a later open draws no summary line" \
  "$(words Agents "All good. 1 agent is running within its limits." "Agent memory: 38 of 64 GB before slowdown" "Checked N ago" "Open vsys")" warden_panel
expect_log "the failed summary is logged" 1 'agent-warden: summary=failed '
rm -f -- "$warden_vsys_fails"
warden_resummon "a summary that answers again"
expect_poll "the next summary that answers draws its line again" \
  "$(words Agents "All good. 1 agent is running within its limits." "Agent memory: 38 of 64 GB before slowdown" "$warden_line" "Checked N ago" "Open vsys")" warden_panel
warden_put near-limit 0 >/dev/null
expect_poll "the shield reads a look" '["shield-alert", "warning", "1", "claude in vsy-52 is using a lot of memory"]' warden_shield
expect_poll "the look panel draws the lane without its scope" \
  "$(words Agents "One thing needs a look." "claude in vsy-52 is using a lot of memory" "50 GB, slowed at 64 GB" "Agent memory: 38 of 64 GB before slowdown" "$warden_line" "Checked N ago" "Open vsys")" warden_panel
expect "the look panel and tooltip name no scope or process id" clean warden_names_nothing near-limit
warden_put holding-off 0 >/dev/null
expect_poll "the shield reads a problem with two issues" '["shield-x", "danger", "2", "Agents are close to their memory limit"]' warden_shield
expect_poll "the problem panel draws both items and the meter past its point" \
  "$(words Agents "2 things need your attention." "Agents are close to their memory limit" "Holding off limiting claude until memory frees up" "Agents are slowed down to save memory" "73 GB in use, slowed from 64 GB" "Agent memory: 73 GB, past the 64 GB slowdown point" "$warden_line" "Checked N ago" "Open vsys")" warden_panel
expect "the problem panel and tooltip name no scope or process id" clean warden_names_nothing holding-off
warden_put reaped 0 >/dev/null
expect_poll "the cleanup panel draws its count" \
  "$(words Agents "Something needs your attention." "Cleaned up after a finished agent" "Stopped 42 leftover processes" "Agent memory: 38 of 64 GB before slowdown" "$warden_line" "Checked N ago" "Open vsys")" warden_panel
expect "the cleanup panel and tooltip name no scope or process id" clean warden_names_nothing reaped
click_item panel vgs.agent-warden Button "Open vsys" || fail "the click on Open vsys failed"
expect_poll "Open vsys hands the terminal the vsys TUI" "$(words vgs.agent-warden/vsys tui/vsys.sh)" recorded_tail
expect_poll "the Open vsys hand-off closes the panel" hidden warden_panel_shown
expect_run_end "the vsys run ends" vgs.agent-warden/vsys
expect "the vsys TUI runs vsys with no arguments" '""' warden_last_vsys

# Notices, with the stand-in vsys present. A calm status first clears every
# episode the rows above opened. warden_ticks: a lane near both ceilings,
# the same lane a tick later, then held-off moves, each read before the
# next is written; the row then reads what the stand-in notify-send was
# handed since MARK.
warden_ticks() {
  local at
  at="$(warden_put near-limit 10)" || { fail "warden_ticks: the first status was not written"; return; }
  expect_poll "a lane near its limits is read" "$((at * 1000))" warden_value lastCheck
  at="$(warden_put near-limit 5)" || { fail "warden_ticks: the next tick was not written"; return; }
  expect_poll "the next tick of the same lane is read" "$((at * 1000))" warden_value lastCheck
  warden_put holding-off 0 >/dev/null
  expect_poll "held-off moves are read" '["problem", null, 2, [["headroom", "problem"], ["slowdown", "look"]]]' warden_state
}
# warden_notify MODE: the plugin's `notify` setting written into its
# plugins row, or taken out of it for an empty MODE; then the service reads
# it.
warden_notify() {
  python3 - "$home/.config/vgs/shell.json" "$1" <<'PY'
import json, os, sys
path, mode = sys.argv[1], sys.argv[2]
data = json.load(open(path))
rows = data.setdefault("plugins", [])
at = [i for i, r in enumerate(rows) if r == "vgs.agent-warden" or (isinstance(r, dict) and r.get("id") == "vgs.agent-warden")]
if not at:
    rows.append({"id": "vgs.agent-warden"})
    at = [len(rows) - 1]
row = rows[at[0]] if isinstance(rows[at[0]], dict) else {"id": "vgs.agent-warden"}
if mode:
    row["notify"] = mode
else:
    row.pop("notify", None)
rows[at[0]] = row
json.dump(data, open(path + ".tmp", "w"), indent=2)
os.replace(path + ".tmp", path)
PY
  expect_poll "the service reads notify: ${1:-problems}" "\"${1:-problems}\"" ipc smoke readInstance service vgs.agent-warden mode
}
# The toasts the plugin shows, as the lending record holds them.
warden_toasts() { ipc shell lent | python3 -c 'import json,sys; print(json.dumps([t for t in json.load(sys.stdin)["toasts"]["visible"] if t["plugin"] == "vgs.agent-warden"]))'; }
warden_near_notices='[["normal", "An agent is starting a lot of processes", true], ["normal", "An agent is using a lot of memory", true]]'
warden_held_notice='["critical", "Agents are close to their memory limit", true]'

warden_put calm 0 >/dev/null
expect_poll "a calm status clears the episodes" '["calm", null, 0, []]' warden_state
warden_mark="$(warden_sent_count)"
warden_ticks
expect_poll "one notice per episode across ticks: the lane's two, then the held-off moves' one" \
  "$(python3 -c 'import json,sys; print(json.dumps(sorted([json.loads(sys.argv[2])] + json.loads(sys.argv[1]))))' "$warden_near_notices" "$warden_held_notice")" warden_notices_since "$warden_mark"
expect "the lane's first notice is sent as Agent Warden with Open vsys" \
  '["-a", "Agent Warden", "-u", "normal", "-A", "open=Open vsys", "--", "An agent is starting a lot of processes", "claude in vsy-52 is at 6,200 of its 8,192 limit. If it'"'"'s a big build, you can let it finish. If not, open vsys to stop it."]' \
  warden_call "$warden_mark" "An agent is starting a lot of processes"
warden_mark="$(warden_sent_count)"
warden_put near-limit 0 >/dev/null
expect_poll "the lane near its limits again, after they cleared, sends its two again" "$warden_near_notices" warden_notices_since "$warden_mark"
warden_put partial 0 >/dev/null
expect_poll "a partial move sends one notice" '[["normal", "Couldn'"'"'t fully move an agent", true]]' warden_notices_since "$((warden_mark + 2))"
warden_put reaped 0 >/dev/null
expect_poll "a cleanup sends one quiet notice without the button" '[["low", "Cleaned up after a finished agent", false], ["normal", "Couldn'"'"'t fully move an agent", true]]' warden_notices_since "$((warden_mark + 2))"

# A press on Open vsys opens the vsys TUI.
forget_record
touch -- "$warden_press"
warden_put holding-off 0 >/dev/null
expect_poll "a press on the held-off notice's Open vsys hands the terminal the vsys TUI" "$(words vgs.agent-warden/vsys tui/vsys.sh)" recorded_tail
rm -f -- "$warden_press"
expect_run_end "the vsys run from the notice ends" vgs.agent-warden/vsys

# A notice whose run fails, or does not start, goes out again on the next
# status; runs waiting for a press stop at the ceiling Notices.offers
# allows, and a run that ends gives its place back.
# warden_put_lanes N AGE: status-near-limit.json with N agent lanes near
# both ceilings, dated AGE seconds back; prints the time.
warden_put_lanes() {
  python3 - "$warden_fixtures/status-near-limit.json" "$warden_dir" "$1" "$2" <<'PY'
import copy, json, os, sys, time
source, target, n, age = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
doc = json.load(open(source))
moment = int(time.time()) - age
lane = doc["lanes"][0]
doc["lanes"] = []
for i in range(n):
    extra = copy.deepcopy(lane)
    extra["scope"] = "agent-warden-%d-1.scope" % (900 + i)
    doc["lanes"].append(extra)
doc["time"] = moment
doc["events"] = []
tmp = os.path.join(target, "status.tmp.%d" % os.getpid())
with open(tmp, "w") as out:
    json.dump(doc, out)
os.replace(tmp, os.path.join(target, "status.json"))
print(moment)
PY
}
# warden_offers_since N: the calls after the first N that offer Open vsys
# and those that do not, as [with, without].
warden_offers_since() { warden_notices_since "$1" | python3 -c 'import json,sys; c=json.load(sys.stdin); print(json.dumps([sum(1 for n in c if n[2]), sum(1 for n in c if not n[2])]))'; }
warden_waiting() { ipc smoke readInstance service vgs.agent-warden waiting; }
warden_failed_lines() { log_lines 'agent-warden: notice=(tasks|memory) failed='; }
# warden_failed_send: two failed runs for a lane near both ceilings, then
# the next tick of the lane read with the stand-in answering again.
warden_failed_send() {
  local at failed
  failed="$(warden_failed_lines)" || { fail "warden_failed_send: the instance log is unreadable"; return; }
  touch -- "$warden_fail"
  at="$(warden_put near-limit 10)" || { fail "warden_failed_send: the status was not written"; return; }
  expect_poll "the failing lane is read" "$((at * 1000))" warden_value lastCheck
  expect_log "both failed runs are logged" "$((failed + 2))" 'agent-warden: notice=(tasks|memory) failed='
  rm -f -- "$warden_fail"
  at="$(warden_put near-limit 5)" || { fail "warden_failed_send: the next tick was not written"; return; }
  expect_poll "the next tick of the failing lane is read" "$((at * 1000))" warden_value lastCheck
  warden_put holding-off 0 >/dev/null
  expect_poll "held-off moves after the failed runs are read" '["problem", null, 2, [["headroom", "problem"], ["slowdown", "look"]]]' warden_state
}
warden_twice='[["critical", "Agents are close to their memory limit", true], ["normal", "An agent is starting a lot of processes", true], ["normal", "An agent is starting a lot of processes", true], ["normal", "An agent is using a lot of memory", true], ["normal", "An agent is using a lot of memory", true]]'
warden_once='[["critical", "Agents are close to their memory limit", true], ["normal", "An agent is starting a lot of processes", true], ["normal", "An agent is using a lot of memory", true]]'

warden_put calm 0 >/dev/null
expect_poll "a calm status clears the episodes before the failures" '["calm", null, 0, []]' warden_state
warden_mark="$(warden_sent_count)"
warden_failed_send
expect_poll "a failed run's notice goes out again on the next status" "$warden_twice" warden_notices_since "$warden_mark"

# A run that cannot start: the stand-in, swapped whole for a file whose
# interpreter does not exist, fails the exec, as rows use for hyprctl. A
# file that is not executable would not do: the PATH lookup skips it.
printf '#!/nonexistent/interpreter\n' >"$shim/notify-send.unstartable"
chmod 755 -- "$shim/notify-send.unstartable"
warden_put calm 0 >/dev/null
expect_poll "a calm status clears the episodes before the failed start" '["calm", null, 0, []]' warden_state
warden_failed="$(log_lines 'agent-warden: notice=(tasks|memory) failed=null')" || fail "the instance log is unreadable before the failed start"
warden_mark="$(warden_sent_count)"
mv -T -- "$shim/notify-send" "$shim/notify-send.real"
mv -T -- "$shim/notify-send.unstartable" "$shim/notify-send"
warden_at="$(warden_put near-limit 10)"
expect_poll "the lane is read while notify-send cannot start" "$((warden_at * 1000))" warden_value lastCheck
expect_log "both runs that did not start are logged" "$((warden_failed + 2))" 'agent-warden: notice=(tasks|memory) failed=null'
mv -T -- "$shim/notify-send.real" "$shim/notify-send"
warden_put near-limit 5 >/dev/null
expect_poll "a notice whose run did not start goes out on the next status" "$warden_near_notices" warden_notices_since "$warden_mark"

# Five lanes near both ceilings open ten notices while every run offering
# Open vsys waits: the first eight offer it, the last two go without.
warden_put calm 0 >/dev/null
expect_poll "a calm status clears the episodes before the waiting runs" '["calm", null, 0, []]' warden_state
warden_mark="$(warden_sent_count)"
touch -- "$warden_hold"
warden_put_lanes 5 0 >/dev/null
expect_poll "runs waiting for a press stop at eight; the rest go without the button" '[8, 2]' warden_offers_since "$warden_mark"
expect_poll "the service counts eight waiting runs" 8 warden_waiting
rm -f -- "$warden_hold"
expect_poll "the runs that end give their places back" 0 warden_waiting
warden_put calm 0 >/dev/null
expect_poll "a calm status clears the lanes" '["calm", null, 0, []]' warden_state
warden_mark="$(warden_sent_count)"
warden_put near-limit 0 >/dev/null
expect_poll "after the waiting runs end, new notices offer the button again" "$warden_near_notices" warden_notices_since "$warden_mark"

# notify: off sends nothing, and an episode that opened meanwhile stays
# unsent when notices come back on; the next one that opens goes out.
warden_notify off
warden_mark="$(warden_sent_count)"
warden_put calm 0 >/dev/null
expect_poll "a calm status clears the episodes while notices are off" '["calm", null, 0, []]' warden_state
warden_ticks
warden_notify ""
warden_put near-limit 0 >/dev/null
expect_poll "notify: off sent nothing, and back on only the lane that opened again goes out" "$warden_near_notices" warden_notices_since "$warden_mark"

# notify: everything shows a move back into limits as a toast.
warden_notify everything
warden_put partial 0 moved >/dev/null
expect_poll "under notify: everything a move shows as a toast" '[{"plugin": "vgs.agent-warden", "title": "Moved an agent back into its limits", "tone": "accent"}]' warden_toasts
warden_notify ""

# A warden that stopped: Start it runs the timer through the stand-in,
# pressed only once the stand-in comes first on the shell's PATH.
warden_systemctl_stub
warden_put calm 600 >/dev/null
expect_poll "the shield reads not checking" '["shield-off", "neutral", "", "Agent Warden hasn'"'"'t checked in 10 min"]' warden_shield
warden_open "stopped"
expect_poll "the stopped panel offers Start it" "$(words Agents "Agent Warden has stopped checking." "$warden_line" "Start it" "Checked N ago" "Open vsys")" warden_panel
if [[ "$("${shell_env[@]}" PATH="$shim:$PATH" bash -c 'command -v systemctl')" == "$shim/systemctl" ]]; then
  click_item panel vgs.agent-warden Button "Start it" || fail "the click on Start it failed"
  expect_poll "Start it runs the warden's timer through systemctl --user" "--user start agent-warden.timer" warden_systemctl_argv
  expect_poll "the Start it hand-off closes the panel" hidden warden_panel_shown
else
  fail "the stand-in systemctl does not come first on the shell's PATH, so Start it was not pressed"
  ipc shell hide panel vgs.agent-warden >/dev/null
fi
rm -f -- "$shim/systemctl"

# Without vsys the panel offers it through the core's notice, and a scan
# that finds it closes the notice with no rest. A host whose PATH holds
# vsys cannot reach the offer; its panel offers Set up, read above.
rm -f -- "$shim/vsys" "$warden_dir/status.json"
expect "a rescan after the stand-in vsys goes starts" ok ipc shell rescanPlugins
expect_poll "vsys reads as the host PATH gives it" "$vsys_first" warden_value vsys
if [[ $vsys_first == '"absent"' ]]; then
  warden_open "without vsys"
  expect_poll "the panel without vsys offers Get vsys once" "$(words Agents "Agent Warden comes with vsys, which isn't installed." "Get vsys")" warden_panel
  click_item panel vgs.agent-warden Button "Get vsys" || fail "the click on Get vsys failed"
  expect_poll "Get vsys raises the notice for vsys" '["vgs.agent-warden", ["vsys"]]' warden_notice
  expect_poll "the Get vsys hand-off closes the panel" hidden warden_panel_shown
  warden_vsys_stub
  expect "a rescan after vsys arrives starts" ok ipc shell rescanPlugins
  expect_poll "the scan that finds vsys closes the notice" null warden_notice
  expect_poll "the closed notice leaves no surface" 0 layer_count vgs:notice
else
  warden_vsys_stub
  expect "a rescan after the stand-in vsys returns starts" ok ipc shell rescanPlugins
fi
expect_poll "the stand-in vsys reads as present again" '"present"' warden_value vsys

expect "disabling the agent warden is allowed" ok ipc shell setPluginEnabled vgs.agent-warden false
expect_poll "the disabled plugin holds no status record" null warden_lent

# warden_control FILE NEEDLE REPLACEMENT: the plugin copied over the
# bundled one with NEEDLE, which must occur once in FILE, replaced; then a
# rescan and the copy enabled. warden_uncontrol: the copy disabled and
# removed with the runtime files, and the bundled plugin back.
warden_control() {
  local scans
  mkdir -p -- "$warden_copy"
  cp -R -- "$repo/shell/plugins/vgs.agent-warden/." "$warden_copy/"
  if python3 -c '
import sys
path, needle, replacement = sys.argv[1:]
text = open(path).read()
if text.count(needle) != 1:
    sys.exit("the rule occurs %d times" % text.count(needle))
open(path, "w").write(text.replace(needle, replacement))' "$warden_copy/$1" "$2" "$3"; then ok "the control copy of $1 drops its rule"; else fail "the control copy of $1 could not be made"; fi
  scans="$(log_lines 'plugins: scan complete changed=true')" || fail "the instance log is unreadable before the control copy"
  expect "a rescan after installing the control copy starts" ok ipc shell rescanPlugins
  expect_log "the rescan publishes the control copy" "$((scans + 1))" 'plugins: scan complete changed=true'
  expect "enabling the control copy is allowed" ok ipc shell setPluginEnabled vgs.agent-warden true
  expect_poll "the control copy made the warden directory and reads no warden" '["not-set-up", null, 0, []]' warden_state
}
warden_uncontrol() {
  local scans
  expect "disabling the control copy is allowed" ok ipc shell setPluginEnabled vgs.agent-warden false
  rm -rf -- "$warden_copy" "$warden_dir"
  scans="$(log_lines 'plugins: scan complete changed=true')" || fail "the instance log is unreadable after the control copy"
  expect "a rescan after removing the control copy starts" ok ipc shell rescanPlugins
  expect_log "the rescan brings the bundled plugin back" "$((scans + 1))" 'plugins: scan complete changed=true'
  expect_poll "the bundled agent warden is known again" True plugin_known vgs.agent-warden
}

# Control: a logic copy that ignores staleness reads the stale document as
# calm, so the stale rows above turn red on it.
warden_control WardenLogic.js "if (Math.abs(now - checkedAt) > STALE_AFTER_MS) {" "if (false) {"
warden_put calm 600 >/dev/null
expect_poll "the staleness control reads the stale document as calm" '["calm", null, 0, []]' warden_state
warden_uncontrol

# Control: a service copy whose timer derives nothing keeps an unchanged
# status calm past its stale moment, so the ageing row above turns red on
# it. The sleep waits out that moment, about 5 s after the write, with 5 s
# more for a derivation that would come late.
warden_control Service.qml "onTriggered: root.derive()" "onTriggered: {}"
warden_put calm 85 >/dev/null
expect_poll "the timer control reads the fresh status as calm" '["calm", null, 0, []]' warden_state
sleep 10
expect "the timer control keeps the unchanged status calm past its stale moment" '["calm", null, 0, []]' warden_state
warden_uncontrol

# Control: a logic copy that hands the view each lane's scope unit as its
# worktree draws the scope name in the panel and the tooltip, so the rows
# above that read them naming nothing turn red on it.
warden_control WardenLogic.js "worktree: lane.label.worktree" "worktree: lane.scope"
warden_put near-limit 0 >/dev/null
expect_poll "the scope control reads the lane near its limits" '["look", null, 1, [["near", "look"]]]' warden_state
expect "the scope control's panel is summoned" ok ipc shell summon panel vgs.agent-warden '{}'
expect_poll "the scope control's panel names the lane's scope" agent-warden-100-200.scope warden_names_nothing near-limit
expect "the scope control's panel is hidden" ok ipc shell hide panel vgs.agent-warden
warden_uncontrol

# Control: a panel copy that keeps the last line when a new summary run
# starts still draws the earlier verdict after a failed run, so the
# failed-summary row above turns red on it.
warden_control Panel.qml "            summary = null;
" ""
warden_put calm 0 >/dev/null
expect_poll "the summary control reads calm" '["calm", null, 0, []]' warden_state
expect "the summary control's panel is summoned" ok ipc shell summon panel vgs.agent-warden '{}'
expect_poll "the summary control's panel draws the summary line" True warden_panel_has_line
touch -- "$warden_vsys_fails"
warden_resummon "the summary control"
expect_poll "the summary control keeps the earlier verdict after a failed run" True warden_panel_has_line
rm -f -- "$warden_vsys_fails"
expect "the summary control's panel is hidden" ok ipc shell hide panel vgs.agent-warden
warden_uncontrol

# Control: a notices copy without episode memory sends the lane's notices
# again on its next tick, so the once-per-episode row above turns red on
# it.
warden_control Notices.js "        if (next.indexOf(e.key) !== -1) return;
" ""
# Whether the lane's first notice went out more than once since MARK.
warden_repeated() { warden_notices_since "$1" | python3 -c 'import json,sys; print(sum(1 for n in json.load(sys.stdin) if n[1] == "An agent is starting a lot of processes") >= 2)'; }
warden_mark="$(warden_sent_count)"
warden_ticks
expect_poll "the memory control sends the lane's first notice again on the next tick" True warden_repeated "$warden_mark"
warden_uncontrol

# Control: a service copy that keeps a failed run's episodes sends their
# notices once only, so the rows above that a failed or unstarted run's
# notice goes out again turn red on it.
warden_control Service.qml "            episodes = Notices.forget(episodes, run.keys);
" ""
warden_mark="$(warden_sent_count)"
warden_failed_send
expect_poll "the forget control sends the failed notices once only" "$warden_once" warden_notices_since "$warden_mark"
warden_uncontrol

# Control: a service copy that never counts a waiting run offers the
# button on every run, so the ceiling row above turns red on it.
warden_control Service.qml "        if (run.offers) waiting += 1;
" ""
warden_mark="$(warden_sent_count)"
touch -- "$warden_hold"
warden_put_lanes 5 0 >/dev/null
expect_poll "the counting control offers the button on all ten runs" '[10, 0]' warden_offers_since "$warden_mark"
rm -f -- "$warden_hold"
warden_uncontrol

# Control: a service copy that never gives a waiting run's place back
# sends later notices without the button, so the row above that a run
# that ends gives its place back turns red on it.
warden_control Service.qml "        if (run.offers) waiting -= 1;
" ""
warden_mark="$(warden_sent_count)"
touch -- "$warden_hold"
warden_put_lanes 5 0 >/dev/null
expect_poll "the release control's runs stop at eight" '[8, 2]' warden_offers_since "$warden_mark"
rm -f -- "$warden_hold"
warden_put calm 0 >/dev/null
expect_poll "the release control reads calm" '["calm", null, 0, []]' warden_state
warden_mark="$(warden_sent_count)"
warden_put near-limit 0 >/dev/null
expect_poll "the release control sends the next notices without the button" '[["normal", "An agent is starting a lot of processes", false], ["normal", "An agent is using a lot of memory", false]]' warden_notices_since "$warden_mark"
warden_uncontrol
rm -f -- "$shim/vsys" "$shim/notify-send"
