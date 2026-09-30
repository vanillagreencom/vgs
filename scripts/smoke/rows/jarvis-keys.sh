# Physical Jarvis keys against private scripted Session ports. No audio,
# account, provider or network runs. No latency ceiling is measured.
# State/effect reads poll once per nested IPC round trip. Fixture callback
# gates poll at 10 ms; hold barriers use the shell's native marker.
set -euo pipefail

jarvis_key_config="$home/.config/vgs/shell.json"
jarvis_key_lua="$home/.config/hypr/hyprland.lua"
jarvis_key_service="$repo/shell/plugins/vgs.jarvis/Service.qml"
jarvis_key_backend="$repo/shell/plugins/vgs.jarvis/backend/jarvisd.js"
jarvis_key_gates="$sandbox/jarvis-key-gates"
cp -- "$jarvis_key_config" "$sandbox/jarvis-key-config-before.json"
cp -- "$jarvis_key_lua" "$sandbox/jarvis-key-lua-before"
cp -- "$jarvis_key_service" "$sandbox/jarvis-key-service-before"
cp -- "$jarvis_key_backend" "$sandbox/jarvis-key-backend-before"
expect "the key row starts with Jarvis disabled" absent ipc smoke jarvisProcess
"$node_bin" "$source_repo/scripts/fixtures/jarvis/scripted.js" "$jarvis_key_backend" "$jarvis_key_gates"
cp -- "$jarvis_key_backend" "$sandbox/jarvis-key-scripted-before"
jarvis_gate="$sandbox/jarvis-key-startup-gate"
jarvis_seen="$sandbox/jarvis-key-startup-seen"
"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" --gate-daemon "$jarvis_key_backend" "$jarvis_gate" "$jarvis_seen"
jarvis_rescan

jarvis_key_state() { # FIELD
  ipc smoke jarvisProcess | py_reply '
import json,sys
d=json.load(sys.stdin)["status"].get("detail")
if d is None:
    print("pending")
elif sys.argv[1] == "phase":
    print(d["phase"])
elif sys.argv[1] in ("seq", "stale"):
    print(d["seq"] if sys.argv[1] == "seq" else d["state"]["stale"])
elif sys.argv[1] == "mode":
    print(d["state"]["settings"]["mode"])
else:
    print(d["state"][sys.argv[1]]["kind"])
' "$1"
}
jarvis_key_effects() { # KIND
  python3 - "$jarvis_key_gates/effects.jsonl" "$1" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
print(sum(json.loads(line)["kind"] == sys.argv[2] for line in p.read_text().splitlines()) if p.exists() else 0)
PY
}
jarvis_key_gate() { : >"$jarvis_key_gates/$1"; }
jarvis_key_mode() { # MODE
  python3 - "$jarvis_key_config" "$1" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); value=json.loads(p.read_text())
row=next((r for r in value.setdefault("plugins",[]) if r["id"]=="vgs.jarvis"),None)
if row is None:
    row={"id":"vgs.jarvis"}; value["plugins"].append(row)
row["mode"]=sys.argv[2]
p.write_text(json.dumps(value))
PY
  expect "deliver the Jarvis talk mode" ok ipc shell reloadConfig
  expect_poll "the running daemon receives its mode" "$1" jarvis_key_state mode
}
jarvis_key_talk_down() { hold_send "down 133" "down 108"; }
jarvis_key_talk_up() { hold_send "up 108" "up 133"; }
jarvis_key_mute() { hold_send "down 133" "down 50" "down 108" "up 108" "up 50" "up 133"; }
jarvis_key_stop() { hold_send "down 133" "down 64" "down 60" "up 60" "up 64" "up 133"; }
jarvis_key_commit() { expect_poll "release commits the scripted utterance" thinking jarvis_key_state phase; }
jarvis_key_commit_control() {
  (failures=0 behaviour_failures=0
   jarvis_key_commit >"$sandbox/jarvis-key-release-control.log"
   echo "$failures")
}
jarvis_key_muted() {
  expect_poll "startup Mute is delivered and keeps capture closed" on jarvis_key_state mute
  expect "startup Mute does not acquire capture" closed jarvis_key_state capture
}
jarvis_key_mute_control() {
  (failures=0 behaviour_failures=0
   jarvis_key_muted >"$sandbox/jarvis-key-startup-control.log"
   echo "$failures")
}
jarvis_key_pending() { ipc smoke readInstance service vgs.jarvis lifetime; }
jarvis_key_refusals() { # CAUSE
  ipc smoke jarvisMuteNotices "Jarvis mute not saved" "$1"
}
jarvis_key_refusal_assertion() { expect "unavailable Mute reports its actual cause" "$1" jarvis_key_refusals "$2"; }
jarvis_key_refusal_control() {
  (failures=0 behaviour_failures=0
   jarvis_key_refusal_assertion "$1" "$2" >"$sandbox/jarvis-key-refusal-control.log"
   echo "$failures")
}
jarvis_key_stopped() {
  ipc smoke jarvisProcess | py_reply '
import json,sys
d=json.load(sys.stdin)["status"].get("detail")
s=d["state"] if d is not None else None
ok=s is not None and d["phase"]=="idle" and all(s[k]["kind"]==v for k,v in
    {"conversation":"ended","capture":"closed","playback":"idle","brain":"closed","turn":"none"}.items())
print("stopped" if ok else "pending")
'
}
jarvis_key_stop_assertion() { expect_poll "active physical Stop ends the turn and idles playback" stopped jarvis_key_stopped; }
jarvis_key_stop_control() {
  (failures=0 behaviour_failures=0
   jarvis_key_stop_assertion >"$sandbox/jarvis-key-stop-$1-control.log"
   echo "$failures")
}
jarvis_key_turn() { # PHASE
  jarvis_key_talk_down
  expect_poll "the physical Stop case starts capture" listening jarvis_key_state phase
  jarvis_key_talk_up
  jarvis_key_commit
  if [[ $1 == speaking ]]; then
    local starts
    starts="$(jarvis_key_effects playback-start)"
    jarvis_key_gate brain
    expect_poll "the physical Stop case starts speaking" speaking jarvis_key_state phase
    expect_poll "the scripted playback actually starts" "$((starts + 1))" jarvis_key_effects playback-start
  fi
}
jarvis_key_active_stop() { # PHASE
  local effect late stale before starts
  jarvis_key_turn "$1"
  if [[ $1 == thinking ]]; then effect=brain-cancel; late=late-brain; else effect=playback-flush; late=late-played; fi
  before="$(jarvis_key_effects "$effect")"
  starts="$(jarvis_key_effects playback-start)"
  jarvis_key_stop
  jarvis_key_stop_assertion
  expect "active physical Stop delivers $effect" "$((before + 1))" jarvis_key_effects "$effect"
  stale="$(jarvis_key_state stale)"
  jarvis_key_gate "$late"
  if [[ $1 == thinking ]]; then stale=$((stale + 2)); else stale=$((stale + 1)); fi
  expect_poll "the prior turn's callback is received and discarded" "$stale" jarvis_key_state stale
  jarvis_key_stop_assertion
  expect "a stale callback starts no new playback" "$starts" jarvis_key_effects playback-start
}
jarvis_key_startup() {
  rm -f -- "$jarvis_gate" "$jarvis_seen"
  expect "the gated key service enables" ok ipc shell setPluginEnabled vgs.jarvis true
  expect_poll "the startup daemon consumes hello before the physical key" seen jarvis_seen_hello
  jarvis_key_mute
  jarvis_key_mute
  jarvis_key_talk_down
  jarvis_key_talk_up
  jarvis_key_stop
  hold_barrier
  expect "unavailable repeated Mute keeps one pending privacy request" '{"kind":"starting","pendingMute":"waiting"}' jarvis_key_pending
}

printf '%s\n' \
  'hl.config({ input = { resolve_binds_by_sym = false } })' \
  'hl.bind("code:67", hl.dsp.global("smoke:hold-marker"), { description = "smoke:hold-marker", ignore_mods = true })' >>"$jarvis_key_lua"
expect "Jarvis keys use the physical evdev map" ok hypr reload config-only
expect "the observer provides the key ordering marker" ok ipc smoke holdMarkerStart
hold_markers="$(ipc smoke holdMarkerCount)"
hold_delayed_keyboard=""
hold_start_keyboard jarvis "$sandbox/keyboard" us ""
jarvis_key_startup
expect_poll "Jarvis registers only its implemented shortcuts" 4 hold_native vgs.jarvis:
expect_poll "the service reads the effective default key map" \
  '{"talk":"SUPER+code:108","mute":"SUPER+SHIFT+code:108","stop":"SUPER+ALT+PERIOD"}' \
  ipc smoke readInstance service vgs.jarvis effectiveKeys
: >"$jarvis_gate"
jarvis_key_muted
expect "ready acknowledges the pending Mute" '{"kind":"ready","pendingMute":"none"}' jarvis_key_pending
jarvis_disable
jarvis_key_startup
: >"$jarvis_gate"
jarvis_key_muted
expect "pending startup Mute never toggles restored mute off" 0 jarvis_key_effects capture-open
jarvis_key_mute
expect_poll "a ready explicit Mute can unmute without capture" off jarvis_key_state mute

jarvis_disable
# Keep the real retry timer, with a fixture delay long enough for physical
# input and its ordering barrier to complete before the next start.
python3 - "$jarvis_key_service" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); assert not p.is_symlink()
s=p.read_text(); needle='retry.interval = 250 * Math.pow(2, retries);'
assert s.count(needle)==1
changed=s.replace(needle, 'retry.interval = 4500;')
assert changed!=s
p.write_text(changed)
PY
jarvis_rescan
jarvis_key_startup
jarvis_key_launcher="$(ipc smoke jarvisProcess | jarvis_launcher_pid)"
jarvis_key_pid="$(jarvis_descendants "$jarvis_key_launcher")"
rm -- "$jarvis_seen"
kill -KILL "$jarvis_key_pid"
expect_poll "pending startup Mute remains owned during retry" '{"kind":"retry","pendingMute":"waiting"}' jarvis_key_pending
jarvis_key_mute
jarvis_key_mute
hold_barrier
expect "repeated physical Mute during retry stays one request" '{"kind":"retry","pendingMute":"waiting"}' jarvis_key_pending
expect_poll "the restarted daemon consumes hello" seen jarvis_seen_hello
: >"$jarvis_gate"
jarvis_key_muted
expect "retry uses the existing restart allowance" ready jarvis_wait_ready 1
jarvis_disable
cp -- "$sandbox/jarvis-key-service-before" "$jarvis_key_service"
jarvis_rescan
jarvis_key_startup
expect "the test-only lock holder enables" ok ipc shell setPluginEnabled acme.probe true
expect "the fixture locks before pending Mute delivery" ok probe lock
expect_poll "the nested compositor confirms the fixture lock" true read_service lockSecure
: >"$jarvis_gate"
jarvis_key_muted
expect "the pending request uses the current locked snapshot" '{"kind":"ready","pendingMute":"none"}' jarvis_key_pending
expect "the fixture unlocks without authentication" ok probe unlock
expect_poll "unlock leaves privacy Mute on" on jarvis_key_state mute
jarvis_key_talk_down
jarvis_key_talk_up
hold_barrier
expect "unlock plus Talk cannot acquire muted capture" closed jarvis_key_state capture
jarvis_key_mute
expect_poll "explicit ready unmute clears only privacy state" off jarvis_key_state mute

jarvis_disable
jarvis_key_startup
expect "pending Mute tells the user that disable cancels the request" 1 \
  ipc smoke jarvisMuteNotices "Jarvis mute pending" "disabling Jarvis cancels this request"
expect "disable ends the pending service" ok ipc shell setPluginEnabled vgs.jarvis false
expect_poll "disable drops the pending owner" absent ipc smoke jarvisProcess
expect "a cancelled request never changes the persisted privacy state" False \
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["muted"])' "$home/.local/state/vgs/jarvis/mute.json"
jarvis_key_startup
: >"$jarvis_gate"
jarvis_key_muted
jarvis_key_mute
expect_poll "ready unmute is explicit after the new request" off jarvis_key_state mute

# Keep the key registration and pending request. Remove only its delivery.
jarvis_disable
python3 - "$jarvis_key_service" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); assert not p.is_symlink()
s=p.read_text(); needle='sendIntent("mute");'
assert s.count(needle)==1
changed=s.replace(needle, 'if (false) ' + needle)
assert changed!=s
p.write_text(changed)
PY
jarvis_rescan
jarvis_key_startup
: >"$jarvis_gate"
expect "dropping pending delivery breaks the same startup Mute assertion" 1 jarvis_key_mute_control
jarvis_disable
cp -- "$sandbox/jarvis-key-service-before" "$jarvis_key_service"
cp -- "$sandbox/jarvis-key-backend-before" "$jarvis_key_backend"
"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" --floor-daemon "$jarvis_key_backend"
jarvis_rescan
expect "the permanent-problem key service enables" ok ipc shell setPluginEnabled vgs.jarvis true
expect_poll "the real service reports its permanent cause" permanent jarvis_permanent
jarvis_key_refused="$(jarvis_key_refusals 'jarvis: node=21.0.0 need=22')"
jarvis_key_mute
hold_barrier
jarvis_key_refusal_assertion "$((jarvis_key_refused + 1))" 'jarvis: node=21.0.0 need=22'
expect "the permanent-problem service disables" ok ipc shell setPluginEnabled vgs.jarvis false
python3 - "$jarvis_key_service" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); assert not p.is_symlink()
s=p.read_text(); needle='function refuseMute(reason) {'
assert s.count(needle)==1
changed=s.replace(needle, needle + '\n        return;')
assert changed!=s
p.write_text(changed)
PY
jarvis_rescan
expect "the refusal control enables without changing the key trigger" ok ipc shell setPluginEnabled vgs.jarvis true
expect_poll "the refusal control reaches the same permanent cause" permanent jarvis_permanent
jarvis_key_refused="$(jarvis_key_refusals 'jarvis: node=21.0.0 need=22')"
jarvis_key_mute
hold_barrier
expect "dropping refusal breaks its same cause assertion" 1 jarvis_key_refusal_control "$((jarvis_key_refused + 1))" 'jarvis: node=21.0.0 need=22'
expect "the refusal control disables" ok ipc shell setPluginEnabled vgs.jarvis false
cp -- "$sandbox/jarvis-key-service-before" "$jarvis_key_service"
cp -- "$sandbox/jarvis-key-scripted-before" "$jarvis_key_backend"
jarvis_rescan
jarvis_enable
jarvis_key_mode hold
jarvis_key_active_stop thinking
jarvis_key_active_stop speaking
jarvis_key_initial_opens="$(jarvis_key_effects capture-open)"
jarvis_key_talk_down
expect_poll "the physical talk key starts listening" listening jarvis_key_state phase
expect "one key press opens one scripted capture" "$((jarvis_key_initial_opens + 1))" jarvis_key_effects capture-open
jarvis_key_seq="$(jarvis_key_state seq)"
hold_send "down 108" "down 108"
hold_barrier
expect "physical repeat sends no extra intent" "$jarvis_key_seq" jarvis_key_state seq
expect "physical repeat opens no second capture" "$((jarvis_key_initial_opens + 1))" jarvis_key_effects capture-open
jarvis_key_talk_up
jarvis_key_commit
jarvis_key_gate brain
expect_poll "the scripted brain starts speaking" speaking jarvis_key_state phase
jarvis_key_gate played
expect_poll "scripted playback returns to idle" idle jarvis_key_state phase

jarvis_key_mode toggle
jarvis_key_talk_down
expect_poll "toggle press opens a conversation" listening jarvis_key_state phase
jarvis_key_talk_up
hold_barrier
expect "toggle release leaves capture open" conversation jarvis_key_state input
jarvis_key_gate final
expect_poll "the scripted turn detector commits toggle speech" thinking jarvis_key_state phase
jarvis_key_gate brain
expect_poll "toggle's scripted answer speaks" speaking jarvis_key_state phase
jarvis_key_gate played
expect_poll "toggle resumes listening after its scripted answer" listening jarvis_key_state phase
sleep 0.25 # The next press must be outside Session's toggle-collapse interval.
jarvis_key_talk_down
jarvis_key_talk_up
expect_poll "the next toggle press closes its conversation" ended jarvis_key_state conversation
expect_poll "closing toggle releases capture" closed jarvis_key_state capture
sleep 0.25 # The next conversation uses a separate permitted toggle edge.
jarvis_key_talk_down
jarvis_key_talk_up
expect_poll "a fresh toggle conversation listens" listening jarvis_key_state phase
jarvis_key_gate hold-close
jarvis_key_mute
expect_poll "mute waits for scripted capture teardown" muting jarvis_key_state mute
jarvis_key_opens="$(jarvis_key_effects capture-open)"
jarvis_key_talk_down
jarvis_key_talk_up
jarvis_key_stop
hold_barrier
jarvis_key_gate close
expect_poll "mute completes only after capture closes" on jarvis_key_state mute
expect "muting keys cannot acquire capture" "$jarvis_key_opens" jarvis_key_effects capture-open
rm -- "$jarvis_key_gates/hold-close"
jarvis_disable
jarvis_enable
expect_poll "mute survives a service and daemon restart" on jarvis_key_state mute
jarvis_key_seq="$(jarvis_key_state seq)"
jarvis_key_talk_down
jarvis_key_talk_up
jarvis_key_stop
hold_barrier
expect_poll "the muted daemon consumes talk down, up and stop" "$((jarvis_key_seq + 3))" jarvis_key_state seq
expect "all implemented non-mute keys leave privacy mute on" on jarvis_key_state mute
expect "muted keys after restart acquire no capture" "$jarvis_key_opens" jarvis_key_effects capture-open
jarvis_key_mute
expect_poll "the mute key explicitly unmutes" off jarvis_key_state mute
expect "unmute alone keeps capture closed" closed jarvis_key_state capture

# Preserve both registration and wire dispatch. Misroute only Stop.
jarvis_disable
python3 - "$jarvis_key_service" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); assert not p.is_symlink()
s=p.read_text(); needle='function sendIntent(name) {'
assert s.count(needle)==1
changed=s.replace(needle, needle + '\n        if (name === "stop") name = "talk-up";')
assert changed!=s
p.write_text(changed)
PY
jarvis_rescan
for jarvis_key_phase in thinking speaking; do
  jarvis_enable
  jarvis_key_mode hold
  jarvis_key_turn "$jarvis_key_phase"
  jarvis_key_stop
  hold_barrier
  expect "Stop-to-talk-up fails the same active $jarvis_key_phase assertion" 1 jarvis_key_stop_control "$jarvis_key_phase"
  jarvis_disable
done
cp -- "$sandbox/jarvis-key-service-before" "$jarvis_key_service"

# Preserve the registration and its pressed behavior. Drop only delivery of
# the release callback; the same commit assertion must fail once.
python3 - "$jarvis_key_service" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); needle='() => intent("talk-up")'
assert s.count(needle)==1
changed=s.replace(needle, "() => {}")
assert changed!=s
p.write_text(changed)
PY
jarvis_rescan
jarvis_enable
jarvis_key_mode hold
jarvis_key_talk_down
expect_poll "the release control retains actual key-down delivery" listening jarvis_key_state phase
jarvis_key_talk_up
hold_barrier
expect "dropping release delivery breaks the real phase assertion" 1 jarvis_key_commit_control
jarvis_disable
expect_poll "disable unregisters every Jarvis key" 0 hold_native vgs.jarvis:
hold_barrier
hold_stop_keyboard
expect "the observer releases its ordering marker" ok ipc smoke holdMarkerStop
cp -- "$sandbox/jarvis-key-service-before" "$jarvis_key_service"
cp -- "$sandbox/jarvis-key-backend-before" "$jarvis_key_backend"
rm -- "$repo/shell/plugins/vgs.jarvis/backend/scripted-fixture.js"
rm -- "$home/.local/state/vgs/jarvis/mute.json"
jarvis_rescan
cp -- "$sandbox/jarvis-key-config-before.json" "$jarvis_key_config"
cp -- "$sandbox/jarvis-key-lua-before" "$jarvis_key_lua"
expect "restore the Jarvis key configuration" ok ipc shell reloadConfig
expect "restore the nested keyboard configuration" ok hypr reload config-only
jarvis_enable
expect_poll "the restored stock daemon remains unconfigured" session jarvis_session unconfigured
expect "the restored nested keys have no configuration errors" '[]' config_errors
expect "the scripted control leaves no Jarvis state file" False \
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).exists())' "$home/.local/state/vgs/jarvis/mute.json"
jarvis_disable
