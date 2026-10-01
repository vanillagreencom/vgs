# No latency budget. Poll once per nested IPC round trip.
# Only J09's process double and the allow-listed TUI fixture run here.
set -euo pipefail
local_reader="$repo/shell/plugins/vgs.jarvis/LocalRuntime.qml"
local_tui="$repo/shell/plugins/vgs.jarvis/tui/setup-local.sh"
cp -- "$local_reader" "$sandbox/local-reader-original"
cp -- "$local_tui" "$sandbox/local-tui-original"
cp -- "$source_repo/scripts/smoke/fixtures/tui/vgs.jarvis/tui/setup-local.sh" "$local_tui"
terminal_stand_in
terminal_ready "Jarvis local setup"
jarvis_rescan
jarvis_enable
settings_page_open vgs.jarvis

local_value() {
  status_row vgs.jarvis localRuntime | py_reply '
import json,sys
r=json.load(sys.stdin)
expected={"absent":{"tone":"warning","text":"Not set up","action":True},
          "ready":{"tone":"ok","text":"Ready: small","action":False},
          "failed":{"tone":"warning","text":"Setup check failed","action":True},
          "invalid":{"tone":"warning","text":"Setup check returned invalid status","action":True}}[sys.argv[1]]
print("matched" if r["value"]==expected and r["action"]["offered"]==expected["action"] else "pending")
' "$1"
}
local_open() { # manager action or listed launcher entry
  local revision snapshot
  revision="$(jarvis_revision)" || return 1
  snapshot="$rt_dir/vgsh-sources-$shell_qs_pid/$revision"
  forget_record
  if [[ $1 == status ]]; then
    expect "Settings starts its declared local setup action" ok settings_act vgs.jarvis localRuntime
  else
    expect "the launcher starts its listed local setup" ok ipc shell openTui vgs.jarvis/setup-local
  fi
  expect_poll "setup receives the private plugin snapshot and declared argv" \
    "$(words --app-id=org.vgs.tui "--title=VGS · Set up Jarvis local voice" -- "$tui_self" present --presentation full \
      --plugin vgs.jarvis --dir "$snapshot" --record vgs.jarvis/setup-local --run RUN --record-dir "$rt_dir/vgs/tui" \
      --app-id org.vgs.tui --window-title "VGS · Set up Jarvis local voice" -- tui/setup-local.sh)" recorded
  expect_run_end "the fixture local setup terminal ends" vgs.jarvis/setup-local
}
expect_poll "local setup is offered before verification" matched local_value absent
ipc shell listTuis | py_reply '
import json,sys
rows=json.load(sys.stdin)
assert any(row["key"]=="vgs.jarvis/setup-local" and row["group"]=="Jarvis" for row in rows)
'
printf 'ready\n' >"$sandbox/jarvis-world/local-mode"
local_open status
expect_poll "the service rereads readiness after the Settings action ends" matched local_value ready
printf 'failed\n' >"$sandbox/jarvis-world/local-mode"
local_open launcher
expect_poll "exit 77 replaces a previous ready status" matched local_value failed
printf 'invalid\n' >"$sandbox/jarvis-world/local-mode"
local_open launcher
expect_poll "invalid output cannot retain ready" matched local_value invalid

# Preserve the handler text and drop its effect on a disposable copy.
python3 - "$local_reader" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
assert not p.is_symlink()
s=p.read_text()
needle="onEndedAtChanged: if (endedAt !== null) refresh()"
assert s.count(needle)==1
changed=s.replace(needle,"onEndedAtChanged: if (false && endedAt !== null) refresh()")
assert changed != s
p.write_text(changed)
PY
printf 'ready\n' >"$sandbox/jarvis-world/local-mode"
jarvis_rescan
expect_poll "the refresh control first reads ready" matched local_value ready
printf 'failed\n' >"$sandbox/jarvis-world/local-mode"
local_open launcher
local_refresh_control() {
  (failures=0 behaviour_failures=0
   expect_poll "the completed TUI must replace ready" matched local_value failed
   echo "$failures")
}
local_control_count() {
  local output
  output="$("$@")" || return 1
  printf '%s\n' "${output##*$'\n'}"
}
expect "removing end refresh breaks its consumer read" 1 local_control_count local_refresh_control
cp -- "$sandbox/local-reader-original" "$local_reader"
printf 'absent\n' >"$sandbox/jarvis-world/local-mode"
jarvis_rescan
expect_poll "the restored reader offers setup" matched local_value absent

python3 - "$local_reader" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
needle='if (code === 0) value = JSON.parse(output);'
assert s.count(needle)==1
changed=s.replace(needle, 'if (code !== 0) return;\n            ' + needle)
assert changed != s
p.write_text(changed)
PY
printf 'ready\n' >"$sandbox/jarvis-world/local-mode"
jarvis_rescan
expect_poll "the failed-probe control first reads ready" matched local_value ready
printf 'failed\n' >"$sandbox/jarvis-world/local-mode"
local_open launcher
local_failure_control() {
  (failures=0 behaviour_failures=0
   expect_poll "a failed check must clear ready" matched local_value failed
   echo "$failures")
}
expect "retaining ready after probe failure breaks its consumer read" 1 local_control_count local_failure_control
cp -- "$sandbox/local-reader-original" "$local_reader"
cp -- "$sandbox/local-tui-original" "$local_tui"
printf 'absent\n' >"$sandbox/jarvis-world/local-mode"
jarvis_rescan
expect_poll "the restored setup action is offered" matched local_value absent
settings_page_close vgs.jarvis
jarvis_disable
