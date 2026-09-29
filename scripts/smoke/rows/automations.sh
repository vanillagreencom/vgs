# Automations, vgs.automations. The harness starts it disabled; this row
# enables it over stand-ins it writes in the shell's own PATH directory: a
# systemctl that answers show-environment and logs every other verb, a
# systemd-run that logs its argv and runs the argv after `--`, a notify-send
# that logs its argv and prints an id, and a loginctl that answers `no`;
# the harness's crontab stand-in serves the whole run. No call can reach the
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
# runs listing; the linger TUI opens through the stand-in terminal; and the
# control, a copy of the plugin whose service does not list after a run
# file lands, leaves Last runs as it was after the next failing run. The
# row ends with the plugin disabled, its stand-ins removed and the shim
# files they covered restored.
set -euo pipefail
auto_stub="$sandbox/automations-stub"
auto_saved="$sandbox/automations-saved"
mkdir -p "$auto_stub" "$auto_saved"
auto_names=(systemctl systemd-run notify-send loginctl)
for name in "${auto_names[@]}"; do
  if [[ -e $shim/$name ]]; then mv -- "$shim/$name" "$auto_saved/$name"; fi
done
# The systemctl stand-in fails daemon-reload while $auto_stub/fail-reload
# exists, so a row can make a sync fail.
cat >"$shim/systemctl" <<EOF
#!/usr/bin/env bash
python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "\$@" >>"$auto_stub/systemctl.calls"
if [[ \${2:-} == daemon-reload && -e "$auto_stub/fail-reload" ]]; then echo "Failed to reload daemon: stand-in" >&2; exit 1; fi
exit 0
EOF
cat >"$shim/systemd-run" <<EOF
#!/usr/bin/env bash
python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "\$@" >>"$auto_stub/systemd-run.calls"
while [[ \$# -gt 0 && \$1 != -- ]]; do
  case "\$1" in --setenv=*) export "\${1#--setenv=}" ;; esac
  shift
done
shift
"\$@" >>"$auto_stub/systemd-run.out" 2>&1 || true
EOF
cat >"$shim/notify-send" <<EOF
#!/usr/bin/env bash
python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "\$@" >>"$auto_stub/notify-send.calls"
echo 7
EOF
printf '#!/usr/bin/env bash\necho no\n' >"$shim/loginctl"
chmod 755 "$shim/systemctl" "$shim/systemd-run" "$shim/notify-send" "$shim/loginctl"
terminal_stand_in

auto_engine="$repo/shell/plugins/vgs.automations/bin/automations"
shell_path="$(tr '\0' '\n' <"/proc/$shell_qs_pid/environ" | sed -n 's/^PATH=//p')"
[[ -n $shell_path ]] || fail "the shell's PATH is unreadable"
automations() { "${shell_env[@]}" PATH="$shell_path" "$auto_engine" --tree "$repo" "$@" 2>>"$sandbox/automations.err"; }
# The last line a verb prints: a verb that syncs prints sync's line first.
auto_last() { local out; out="$(automations "$@")" || return; printf '%s\n' "${out##*$'\n'}"; }
auto_status() { ipc vgs.automations invoke status "" | py_reply 'import json,sys; v=json.load(sys.stdin); print(json.dumps(v.get(sys.argv[1], "unset")))' "$1"; }
auto_lent() { ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["status"].get("vgs.automations"); print(json.dumps([sorted(r["keys"]) if r else None, "vgs.automations" in d["ipcTargets"]]))'; }
# The systemctl verbs logged since the row began, show-environment left out.
auto_verbs() { if [[ -f $auto_stub/systemctl.calls ]]; then python3 -c 'import json,sys; print(json.dumps([c[1] for c in map(json.loads, open(sys.argv[1])) if c[1] != "show-environment"]))' "$auto_stub/systemctl.calls"; else echo '[]'; fi; }
auto_units() { if [[ -d $home/.config/systemd/user ]]; then (cd -- "$home/.config/systemd/user" && ls | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().split()))'); else echo '[]'; fi; }
# The VGS hints of the last notification, as its x-vgs names and values.
auto_hints() { if [[ -f $auto_stub/notify-send.calls ]]; then tail -n 1 -- "$auto_stub/notify-send.calls" | python3 -c 'import json,sys; a=json.load(sys.stdin); print(json.dumps([h.split(":", 2)[1] + "=" + ("<path>" if h.split(":", 2)[1] == "x-vgs-open" else h.split(":", 2)[2]) for h in a if h.startswith("--hint=string:x-vgs-")]))'; else echo absent; fi; }
# resolved COMMAND PATH_LIST: the file COMMAND runs from on PATH_LIST, or
# none. The harness's crontab stand-in stays for the whole run, since
# crontab picks the caller's own table by user, not by HOME.
resolved() { PATH="$2" bash -c 'command -v "$1" || echo none' _ "$1"; }
crontab_calls() { if [[ -f $sandbox/crontab.calls ]]; then python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read().splitlines()))' "$sandbox/crontab.calls"; else echo '[]'; fi; }
: >"$sandbox/crontab.calls"
# auto_problem: the Engine status as `<tone> <operation>` and the exit word,
# or `ok None`.
auto_problem() { auto_status problem | py_reply 'import json,sys; v=json.load(sys.stdin); print(" ".join([v["tone"]] + v["text"].split(" ")[:2]))'; }
failing='{"name": "Nightly", "command": "echo nope >&2; exit 3", "schedule": {"frequency": "weekly", "interval": 2, "weekdays": ["mon"], "times": ["03:00"], "start": "2026-01-05", "end": {"type": "never"}}}'

expect "the automations start disabled in the sandbox" False plugin_enabled vgs.automations
expect "enabling the automations is allowed" ok ipc shell setPluginEnabled vgs.automations true
expect_poll "the service holds its status record and IPC target" '[["active", "lastRuns", "linger", "nextRun", "problem", "scheduler"], true]' auto_lent
expect_poll "the scheduler reads the stand-in's systemd user manager" '{"tone": "ok", "text": "systemd user timers"}' auto_status scheduler
expect_poll "lingering reads off" '{"tone": "warning", "text": "Automations run only while you are logged in"}' auto_status linger
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
unlink -- "$home/.config/systemd/user/vgs-automation-nightly.timer"
expect "the service syncs on request" ok ipc vgs.automations invoke sync ""
expect_poll "a failed sync is the Engine status after the list succeeds" "danger sync exit=1" auto_problem
expect_poll "the list after the failed sync still counts it" 1 auto_status active
unlink -- "$auto_stub/fail-reload"
expect "the service syncs again" ok ipc vgs.automations invoke sync ""
expect_poll "a sync that succeeds clears the Engine status" "ok None" auto_problem
expect "the timer is written again" '["vgs-automation-nightly.service", "vgs-automation-nightly.timer"]' auto_units

expect "Run now starts" started=nightly automations run-now nightly
expect "Run now goes through systemd-run" '["--user", "--collect", "--quiet"]' python3 -c 'import json,sys; print(json.dumps(json.loads(open(sys.argv[1]).readline())[:3]))' "$auto_stub/systemd-run.calls"
expect "the failure sends the error notification with its hints" '["x-vgs-icon=circle-x", "x-vgs-tone=danger", "x-vgs-click=open", "x-vgs-open=<path>"]' auto_hints
expect_poll "the run's records reach Last runs" '{"tone": "danger", "text": "Failing: Nightly"}' auto_status lastRuns

forget_record
expect "the linger IPC opens its TUI" ok ipc vgs.automations invoke linger ""
expect_poll "the terminal is handed the linger TUI" "$(words vgs.automations/linger tui/linger.sh)" recorded_tail

# The control: a copy whose service does not list after a run file lands.
# The engine clears the history first, so the copy's own start reads no
# failure, and the next failing run leaves Last runs as it was.
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
assert text.count(needle) == 1, "the settle timer's list must occur once"
open(path, "w").write(text.replace(needle, "        onTriggered: {}\n    }\n\n    Timer {\n        id: refresh", 1))
PY
expect "the control copy is scanned" ok ipc shell rescanPlugins
expect_poll "the control copy's start reads no failure" '{"tone": "ok", "text": "No failures"}' auto_status lastRuns
expect "Run now starts under the control" started=nightly automations run-now nightly
# The shipped service lists 250 ms after a run file lands, then waits on
# one engine call; two seconds is past both, so the reading below is the
# copy's settled answer and not a race.
sleep 2
expect "the control's Last runs misses the run" '{"tone": "ok", "text": "No failures"}' auto_status lastRuns
rm -r -- "$auto_copy"
expect "the shipped plugin is scanned again" ok ipc shell rescanPlugins

expect "the engine removes the automation" removed=nightly auto_last remove nightly
expect "its units are gone" '[]' auto_units
expect "disabling the automations is allowed" ok ipc shell setPluginEnabled vgs.automations false
expect_poll "the disabled service holds no status record or IPC target" '[null, false]' auto_lent
for name in "${auto_names[@]}"; do
  if [[ -e $auto_saved/$name ]]; then mv -f -- "$auto_saved/$name" "$shim/$name"; else rm -f -- "$shim/$name"; fi
done
