#!/usr/bin/env bash
# Controls for bin/vgsh-monitor-guard and bin/lib/monitor-preview.js, the
# monitor preview's transaction and the guard that restores the state it
# captured (docs/architecture/hyprland-monitors-preview.md). Every case
# runs the helper against scripts/fixtures/monitor-guard/hyprctl, a
# stand-in first on PATH that answers from a state file and logs each call,
# under a fake HYPRLAND_INSTANCE_SIGNATURE in a runtime directory of its
# own, so no call reaches a live Hyprland. A case reads the helper's keyed
# reply, the outputs the stand-in holds, the eval lines it was sent, the
# record and the guard lock; each reaps every guard it started by the pid
# in that world's guard lock and fails when one was still running.
#
# The stand-in answers an eval `ok` and shows its change only from the
# second `monitors` read after it, as Hyprland applies a rule on its next
# monitor refresh, so a reading that does not poll reads the old state. A
# world's own instance has a socket where hyprctl looks for it; another
# instance's has one only while a case says it runs.
#
# The controls run a case against a copy of the helper's tree with one rule
# removed, and pass when the check the control names turns red: each is
# listed at the end with the check it reddens.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
suite=test-vgsh-monitor-guard

for tool in flock python3 ps; do
  command -v "$tool" >/dev/null || { echo "$suite: status=not-measured missing=$tool"; exit 77; }
done

# The stand-in is first on base_env's PATH, ahead of any hyprctl the host
# has, and every world names a fake instance.
cp -- "$repo/scripts/fixtures/monitor-guard/hyprctl" "$tmp/hyprctl"
sig=fakesig_1790000000_4242
dp1='desc:Dell Inc. DELL U2720Q 8YT0R13'

# Every world's runtime directory, so the exit reaps any guard a case left.
reap_all() {
  local dir
  if [[ -r $tmp/worlds ]]; then
    while IFS= read -r dir; do reap_dir "$dir" >/dev/null || true; done <"$tmp/worlds"
  fi
  rm -rf -- "${tmp:?}"
}
trap reap_all EXIT

# reap_dir DIR: TERM, then KILL, to the guard holding DIR's guard lock, by
# the pid that lock file names, once /proc/<pid>/cmdline names the guard;
# prints the pid it reaped, `unread` or `not-a-guard` for a pid it left
# alone, nothing when no guard held the lock. Never by name.
reap_dir() {
  local lock="$1/vgs/monitors-guard.lock" pid="" cmdline=""
  [[ -e $lock ]] || return 0
  flock -n "$lock" true && return 0
  IFS= read -r pid <"$lock" || true
  [[ $pid =~ ^[1-9][0-9]*$ ]] || { echo "unread"; return 0; }
  cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)" || cmdline=""
  [[ $cmdline == *"/monitor-preview.js guard "* ]] || { echo "not-a-guard"; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do flock -n "$lock" true && break; sleep 0.1; done
  flock -n "$lock" true || kill -KILL "$pid" 2>/dev/null || true
  echo "$pid"
}

# new_world NAME: a runtime directory, the stand-in's state, two outputs
# as `monitors -j all` prints them, and its call log. DP-1 has a serial, so
# its identifier is its description; DP-2 has none.
new_world() {
  world="$tmp/w-$1-$RANDOM"
  rt="$world/rt"
  state="$world/state.json"
  calls="$world/calls"
  mkdir -p "$rt"
  chmod 700 "$rt"
  : >"$calls"
  printf '%s\n' "$rt" >>"$tmp/worlds"
  make_socket "$sig"
  cat >"$state" <<'EOF'
{"outputs": [
 {"id": 0, "name": "DP-1", "description": "Dell Inc. DELL U2720Q 8YT0R13", "make": "Dell Inc.", "model": "DELL U2720Q", "serial": "8YT0R13",
  "width": 3840, "height": 2160, "refreshRate": 59.997, "x": 0, "y": 0, "scale": 1.5, "transform": 0, "vrr": false, "disabled": false,
  "currentFormat": "XRGB8888", "mirrorOf": "none", "availableModes": ["3840x2160@60.00Hz", "1920x1080@60.00Hz"]},
 {"id": 1, "name": "DP-2", "description": "LG HDR 4K", "make": "LG", "model": "HDR 4K", "serial": "",
  "width": 2560, "height": 1440, "refreshRate": 59.951, "x": 2560, "y": 0, "scale": 1, "transform": 0, "vrr": false, "disabled": false,
  "currentFormat": "XRGB8888", "mirrorOf": "none", "availableModes": ["2560x1440@59.95Hz", "1920x1080@60.00Hz"]}
]}
EOF
}

# make_socket SIG: a socket where hyprctl finds instance SIG, so the
# instance reads as running.
make_socket() {
  mkdir -p "$rt/hypr/$1"
  # Bound from inside its directory: a socket path past 107 bytes is refused.
  python3 -c 'import os,socket,sys; os.chdir(sys.argv[1]); s=socket.socket(socket.AF_UNIX); s.bind(".socket.sock"); s.close()' "$rt/hypr/$1"
}

# gv BIN ARGS...: the helper BIN in the world, with gv_env words set last
# and gv_prefix run in front of env. Sets status, out (stdout, trimmed of
# its last newline) and err (the first stderr line).
gv_env=()
gv_prefix=()
gv() {
  local bin="$1"
  shift
  set +e
  out="$("${gv_prefix[@]}" "${base_env[@]}" XDG_RUNTIME_DIR="$rt" HYPRLAND_INSTANCE_SIGNATURE="$sig" STANDIN_STATE="$state" STANDIN_CALLS="$calls" "${gv_env[@]}" "$bin" "$@" 2>"$world/err" </dev/null)"
  status=$?
  set -e
  err=""
  [[ -s $world/err ]] && IFS= read -r err <"$world/err"
  return 0
}
expect_reply() { # NAME WANT_STATUS WANT_OUT WANT_ERR
  if [[ $status == "$2" && $out == "$3" && $err == "$4" ]]; then ok "$1"; else fail "$1: status=$status want=$2 out=[$out] want=[$3] err=[$err] want=[$4]"; fi
}
expect_eq() { # NAME GOT WANT
  if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: got=[$2] want=[$3]"; fi
}

# An output's fields as `WxH@R scale pos transform vrr mirror disabled`,
# read through the stand-in's observing call, which lands every eval
# Hyprland would have applied by now and logs no call.
out_state() {
  local text
  text="$(env -i PATH="$base_path" STANDIN_OBSERVE=1 STANDIN_STATE="$state" "$tmp/hyprctl" --instance "$sig" -j monitors all)" || { echo unread; return 0; }
  python3 -c 'import json,sys
o=[o for o in json.loads(sys.argv[1]) if o["name"]==sys.argv[2]]
print("%dx%d@%s scale=%g pos=%dx%d transform=%d vrr=%s mirror=%s disabled=%s" % (o[0]["width"], o[0]["height"], o[0]["refreshRate"], o[0]["scale"], o[0]["x"], o[0]["y"], o[0]["transform"], o[0]["vrr"], o[0]["mirrorOf"], o[0]["disabled"]) if o else "unlisted")' "$text" "$1"
}
before_dp1='3840x2160@59.997 scale=1.5 pos=0x0 transform=0 vrr=False mirror=none disabled=False'
before_dp2='2560x1440@59.951 scale=1 pos=2560x0 transform=0 vrr=False mirror=none disabled=False'
# The eval lines the stand-in was sent, one per line.
evals() { python3 -c 'import json,sys
for line in open(sys.argv[1]):
    c=json.loads(line)
    if c["argv"][2:3]==["eval"]: print(c["argv"][3])' "$calls"; }
eval_count() { local text; text="$(evals)"; if [[ -z $text ]]; then echo 0; else wc -l <<<"$text" | tr -d ' '; fi; }
# Every call's argv starts `--instance <sig>` and its environment names
# the same instance: `yes`, or the first call that does not.
calls_signed() { python3 -c 'import json,sys
for line in open(sys.argv[1]):
    c=json.loads(line)
    if c["argv"][:2]!=["--instance",sys.argv[2]] or c["signature"]!=sys.argv[2]:
        print(line.strip()); sys.exit(0)
print("yes")' "$calls" "$sig"; }
set_state() { # PYTHON statement on `s`, the state, ARG as `arg`; under the stand-in's lock
  python3 -c 'import fcntl,json,sys
lock=open(sys.argv[1] + ".lock", "a"); fcntl.flock(lock, fcntl.LOCK_EX)
s=json.load(open(sys.argv[1]))
arg=sys.argv[3]
exec(sys.argv[2])
json.dump(s, open(sys.argv[1], "w"))' "$state" "$1" "${2:-}"
}
record_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$(record)" "$1" 2>/dev/null || echo absent; }
record() { echo "$rt/vgs/monitors-preview.json"; }
record_there() { if [[ -e $(record) ]]; then echo yes; else echo no; fi; }
guard_lock() { echo "$rt/vgs/monitors-guard.lock"; }
guard_held() { if [[ -e $(guard_lock) ]] && ! flock -n "$(guard_lock)" true; then echo yes; else echo no; fi; }
guard_pid() { local pid=""; IFS= read -r pid <"$(guard_lock)" || true; echo "$pid"; }
# wait_free SECONDS: the guard lock is free within SECONDS, read every 0.1 s.
wait_free() {
  local i
  for ((i = 0; i < $1 * 10; i++)); do
    [[ $(guard_held) == no ]] && { echo free; return 0; }
    sleep 0.1
  done
  echo held
}
tx_lock() { echo "$rt/vgs/monitors-preview.lock"; }
# guard_on_tx SECONDS: `waits` once the guard waits on the transaction
# lock: a child of the guard is flock(1) whose descriptor 3 is that lock,
# read every 0.1 s for up to SECONDS; else `no`.
guard_on_tx() {
  local i pid child
  pid="$(guard_pid)"
  for ((i = 0; i < $1 * 10; i++)); do
    for child in $(ps -o pid= --ppid "$pid" 2>/dev/null); do
      [[ $(readlink -- "/proc/$child/fd/3" 2>/dev/null) == "$(tx_lock)" ]] && { echo waits; return 0; }
    done
    sleep 0.1
  done
  echo no
}
# tx_free SECONDS: `free` once the transaction lock can be taken, within
# SECONDS; else `held`.
tx_free() { if flock -w "$1" "$(tx_lock)" true; then echo free; else echo held; fi; }
log_has() { if grep -qF -- "$1" "$rt/vgs/monitors-guard.log" 2>/dev/null; then echo yes; else echo no; fi; }
# until_epoch T: sleep until the clock reads epoch second T. A real wait:
# the guard reads the wall clock against the record's deadline.
until_epoch() { python3 -c 'import sys,time; time.sleep(max(0.0, float(sys.argv[1]) - time.time()))' "$1"; }
token_of() { [[ $out =~ ^ok\ token=([0-9a-f]{32})\ deadline=([1-9][0-9]*)$ ]] && { token="${BASH_REMATCH[1]}"; deadline="${BASH_REMATCH[2]}"; return 0; }; token=""; deadline=""; return 1; }
# end_world: reap the world's guard; a guard still running is a failure.
end_world() {
  local reaped
  reaped="$(reap_dir "$rt")"
  [[ -z $reaped ]] || fail "a guard was still running at the case's end and was reaped: pid=$reaped"
}

req() { printf '{"rules": %s, "saved": []}' "$1"; }
rule_dp1_scale2="{\"output\": \"$dp1\", \"mode\": \"3840x2160@60.000\", \"position\": {\"x\": 0, \"y\": 0}, \"scale\": 2}"
rule_dp2_scale2='{"output": "DP-2", "mode": "2560x1440@59.950", "position": {"x": 2560, "y": 0}, "scale": 2}'
dp1_scale2="3840x2160@60.0 scale=2 pos=0x0 transform=0 vrr=False mirror=none disabled=False"
restore_dp1="hl.monitor({ output = \"$dp1\", disabled = false, mode = \"3840x2160@59.997\", position = \"0x0\", scale = 1.5, transform = 0, mirror = \"\" })"
restore_dp2='hl.monitor({ output = "DP-2", disabled = false, mode = "2560x1440@59.951", position = "2560x0", scale = 1, transform = 0, mirror = "" })'

# First use: no monitors.json, so no saved rule could restore anything.
# The deadline restores each captured field explicitly and verifies it.
case_first_use() {
  local bin="$1" pid sid
  new_world first-use
  gv "$bin" preview 2 "$(req "[{\"output\": \"$dp1\", \"mode\": \"3840x2160@60.000\", \"position\": {\"x\": 0, \"y\": 0}, \"scale\": 2, \"transform\": 1, \"vrr\": 1}, {\"output\": \"DP-2\", \"mode\": \"2560x1440@59.950\", \"position\": {\"x\": 2560, \"y\": 0}, \"scale\": 1, \"mirror\": \"$dp1\"}]")"
  if ! token_of; then fail "first use: the preview answers ok token=<32 hex> deadline=<epoch>: status=$status out=[$out] err=[$err]"; end_world; return; fi
  ok "first use: the preview answers ok token=<32 hex> deadline=<epoch>"
  expect_eq "first use: the preview applied DP-1's rule" "$(out_state DP-1)" "3840x2160@60.0 scale=2 pos=0x0 transform=1 vrr=True mirror=none disabled=False"
  expect_eq "first use: the preview applied DP-2's mirror" "$(out_state DP-2 | sed 's/.* mirror=\([^ ]*\).*/\1/')" "0"
  expect_eq "first use: the record is the user's alone" "$(stat -c %a "$(record)")" 600
  expect_eq "first use: the runtime directory is the user's alone" "$(stat -c %a "$rt/vgs")" 700
  expect_eq "first use: a guard holds the guard lock" "$(guard_held)" yes
  pid="$(guard_pid)"
  sid="$(ps -o sid= -p "$pid" 2>/dev/null | tr -d ' ')" || sid=""
  expect_eq "first use: the guard leads a session of its own" "$sid" "$pid"
  expect_eq "first use: the guard restores and exits after the deadline" "$(wait_free 6)" free
  expect_eq "first use: DP-1 reads its captured state again" "$(out_state DP-1)" "$before_dp1"
  expect_eq "first use: DP-2 reads its captured state again" "$(out_state DP-2)" "$before_dp2"
  expect_eq "first use: the restore sets every captured field, vrr where the preview set it, and no mirror" "$(evals | tail -n 2)" \
    "hl.monitor({ output = \"$dp1\", disabled = false, mode = \"3840x2160@59.997\", position = \"0x0\", scale = 1.5, transform = 0, mirror = \"\", vrr = 0 })
$restore_dp2"
  expect_eq "first use: the guard logs the restore" "$(log_has "guard=restored token=$token restored=2")" yes
  expect_eq "first use: the record is gone" "$(record_there)" no
  expect_eq "first use: every hyprctl call names the record's instance" "$(calls_signed)" yes
  gv "$bin" confirm "$token"
  expect_reply "first use: a confirm after the restore finds the preview gone" 1 "" "vgsh: refused: preview=gone"
  end_world
}

# A record of instance othersig_1, which the cases write by hand.
foreign_record='{"version":1,"token":"0123456789abcdef0123456789abcdef","deadline":1,"signature":"othersig_1","captured":[{"output":"DP-2","disabled":false,"mode":"2560x1440@59.951","position":{"x":2560,"y":0},"scale":2,"transform":0,"mirror":null,"vrr":null}],"failure":""}'
plant_foreign() {
  mkdir -p "$rt/vgs"
  printf '%s\n' "$foreign_record" >"$(record)"
  chmod 600 "$(record)"
}

# A record another Hyprland instance wrote while that instance runs is left
# as it is: no adopt arms for it, no guard restores it, a preview refuses
# over it, and nothing calls hyprctl for it.
case_foreign_alive() {
  local bin="$1" text="$foreign_record"
  new_world foreign
  make_socket othersig_1
  plant_foreign
  gv "$bin" adopt
  expect_reply "foreign: adopt leaves another instance's live record" 0 "ok adopt=foreign" ""
  expect_eq "foreign: adopt starts no guard" "$(guard_held)" no
  gv "$bin" 0123456789abcdef0123456789abcdef
  if [[ $status == 0 && $out == *" guard=foreign token=0123456789abcdef0123456789abcdef pid="* ]]; then ok "foreign: a guard for another instance's record logs it and exits"
  else fail "foreign: a guard for another instance's record logs it and exits: status=$status out=[$out] err=[$err]"; fi
  expect_eq "foreign: no eval reaches Hyprland" "$(eval_count)" 0
  expect_eq "foreign: the record is left as it was" "$(cat "$(record)")" "$text"
  expect_eq "foreign: DP-2 is left as it is" "$(out_state DP-2)" "$before_dp2"
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  expect_reply "foreign: a preview over another instance's live record is refused" 1 "" "vgsh: refused: preview=busy path=$(record)"
  expect_eq "foreign: nothing calls hyprctl for another instance's record" "$(wc -l <"$calls" | tr -d ' ')" 0
  end_world
}

# A record whose instance no longer runs is stale: adopt and a preview
# remove it, log it, and call no hyprctl for it.
case_foreign_stale() {
  local bin="$1"
  new_world stale
  plant_foreign
  gv "$bin" adopt
  expect_reply "stale: adopt removes a gone instance's record" 0 "ok adopt=stale" ""
  expect_eq "stale: the record is gone after adopt" "$(record_there)" no
  expect_eq "stale: adopt logs the removal" "$(log_has "record=stale-removed token=0123456789abcdef0123456789abcdef signature=othersig_1 by=adopt")" yes
  expect_eq "stale: adopt calls no hyprctl" "$(wc -l <"$calls" | tr -d ' ')" 0
  plant_foreign
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  token_of && ok "stale: a preview over a gone instance's record runs" || fail "stale: a preview over a gone instance's record runs: status=$status err=[$err]"
  expect_eq "stale: the preview logs the removal" "$(log_has "record=stale-removed token=0123456789abcdef0123456789abcdef signature=othersig_1 by=preview")" yes
  expect_eq "stale: no call names the gone instance" "$(calls_signed)" yes
  [[ -z $token ]] || gv "$bin" revert "$token"
  expect_eq "stale: the guard exits" "$(wait_free 3)" free
  end_world
}

# Keep: confirm removes the record, and the guard restores nothing.
case_confirmed() {
  local bin="$1"
  new_world confirmed
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "confirmed: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  gv "$bin" confirm "$token"
  expect_reply "confirmed: confirm answers ok" 0 "ok" ""
  expect_eq "confirmed: the record is gone" "$(record_there)" no
  until_epoch "$((deadline + 2))"
  expect_eq "confirmed: the guard exits by itself" "$(wait_free 2)" free
  expect_eq "confirmed: the guard sent no restore" "$(eval_count)" 1
  expect_eq "confirmed: DP-1 keeps the preview" "$(out_state DP-1)" "$dp1_scale2"
  end_world
}

# Keep, taken under the transaction lock while the guard waits on it at its
# deadline: the guard reads the record again under the lock and finds it
# gone.
case_confirmed_at_deadline() {
  local bin="$1" tx
  new_world confirmed-at-deadline
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "at the deadline: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  exec {tx}>>"$(tx_lock)"
  flock "$tx"
  expect_eq "at the deadline: the guard waits on the transaction lock" "$(guard_on_tx 8)" waits
  rm -f -- "$(record)"
  exec {tx}>&-
  expect_eq "at the deadline: the guard exits once the lock frees" "$(wait_free 3)" free
  expect_eq "at the deadline: the guard logs the record gone" "$(log_has "guard=gone token=$token")" yes
  expect_eq "at the deadline: a confirmed record is left alone" "$(eval_count)" 1
  expect_eq "at the deadline: DP-1 keeps the preview" "$(out_state DP-1)" "$dp1_scale2"
  end_world
}

# The clock steps back across the guard's read under the lock, here as a
# deadline moved later while the guard waits on the transaction lock: the
# guard lets the lock go, waits again and restores at the later deadline.
case_deadline_steps_back() {
  local bin="$1" tx later
  new_world steps-back
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "deadline stepped back: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  exec {tx}>>"$(tx_lock)"
  flock "$tx"
  expect_eq "deadline stepped back: the guard waits on the transaction lock" "$(guard_on_tx 8)" waits
  later=$(( $(date +%s) + 4 ))
  python3 -c 'import json,os,sys
r=json.load(open(sys.argv[1])); r["deadline"]=int(sys.argv[2])
open(sys.argv[1] + ".next", "w").write(json.dumps(r) + "\n"); os.chmod(sys.argv[1] + ".next", 0o600); os.replace(sys.argv[1] + ".next", sys.argv[1])' "$(record)" "$later"
  exec {tx}>&-
  sleep 0.5 # the guard takes the lock, reads the later deadline and lets the lock go
  expect_eq "deadline stepped back: the guard releases the transaction lock and waits" "$(tx_free 2)" free
  expect_eq "deadline stepped back: the guard sent no restore before the later deadline" "$(eval_count)" 1
  expect_eq "deadline stepped back: the guard restores at the later deadline and exits" "$(wait_free 9)" free
  expect_eq "deadline stepped back: DP-1 reads its captured state" "$(out_state DP-1)" "$before_dp1"
  end_world
}

# An output unplugged during the preview is skipped; the others restore.
case_unplugged() {
  local bin="$1"
  new_world unplugged
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2, $rule_dp2_scale2]")"
  token_of || { fail "unplugged: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  set_state 's["outputs"] = [o for o in s["outputs"] if o["name"] != "DP-2"]'
  expect_eq "unplugged: the guard restores and exits" "$(wait_free 6)" free
  expect_eq "unplugged: DP-1 reads its captured state again" "$(out_state DP-1)" "$before_dp1"
  expect_eq "unplugged: the restore sends DP-1's line alone" "$(evals | tail -n +3)" "$restore_dp1"
  expect_eq "unplugged: the guard logs the skip" "$(log_has "guard=restored token=$token restored=1 skipped=DP-2")" yes
  expect_eq "unplugged: the record is gone" "$(record_there)" no
  end_world
}

# A partial apply restores every output the preview captured.
case_partial() {
  local bin="$1" line='hl.monitor({ output = "DP-2", mode = "2560x1440@59.950", position = "2560x0", scale = 2 })'
  new_world partial
  set_state 's["evalFail"] = {arg: "error: refused"}' "$line"
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2, $rule_dp2_scale2]")"
  expect_reply "partial: a failed eval refuses the preview and restores" 1 "" "vgsh: refused: preview=apply-failed line=\"${line//\"/\\\"}\" reply=\"error: refused\" restored=2"
  expect_eq "partial: DP-1, applied before the failure, reads its captured state" "$(out_state DP-1)" "$before_dp1"
  expect_eq "partial: the record is gone" "$(record_there)" no
  expect_eq "partial: the guard exits" "$(wait_free 3)" free
  end_world
}

# A driver fallback: the output reads another mode, so the preview
# restores at once and refuses.
case_fallback() {
  local bin="$1"
  new_world fallback
  set_state 's["fallback"] = {"1920x1080": "3840x2160"}'
  gv "$bin" preview 2 "$(req "[{\"output\": \"$dp1\", \"mode\": \"1920x1080@60.000\", \"position\": {\"x\": 0, \"y\": 0}, \"scale\": 1}]")"
  expect_reply "fallback: an output that reads another mode refuses the preview and restores" 1 "" "vgsh: refused: preview=fallback output=$dp1 restored=1"
  expect_eq "fallback: DP-1 reads its captured state" "$(out_state DP-1)" "$before_dp1"
  expect_eq "fallback: the record is gone" "$(record_there)" no
  expect_eq "fallback: the guard exits" "$(wait_free 3)" free
  end_world
}

# A rule Hyprland answers `ok` for and never applies reads back otherwise
# for the whole settle bound: the preview restores and refuses.
case_never_lands() {
  local bin="$1" line="hl.monitor({ output = \"$dp1\", mode = \"3840x2160@60.000\", position = \"0x0\", scale = 2 })"
  new_world never-lands
  set_state 's["neverLands"] = [arg]' "$line"
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  expect_reply "never lands: a rule that never applies is a fallback" 1 "" "vgsh: refused: preview=fallback output=$dp1 restored=1"
  expect_eq "never lands: the record is gone" "$(record_there)" no
  expect_eq "never lands: the guard exits" "$(wait_free 3)" free
  end_world
}

# A failed apply whose own restore fails on one line: every other line is
# still sent, the record stays with the failure, and the armed guard
# restores at the deadline.
case_undo_kept() {
  local bin="$1" line='hl.monitor({ output = "DP-2", mode = "2560x1440@59.950", position = "2560x0", scale = 2 })'
  new_world undo-kept
  set_state 's["evalFail"] = {arg: "error: refused"}' "$line"
  set_state 's["evalFailOnce"] = {arg: "error: once"}' "$restore_dp1"
  gv "$bin" preview 3 "$(req "[$rule_dp1_scale2, $rule_dp2_scale2]")"
  expect_reply "undo: a failed restore refuses and keeps the record" 1 "" "vgsh: refused: preview=apply-failed line=\"${line//\"/\\\"}\" reply=\"error: refused\" restore=failed lines=1 line=\"${restore_dp1//\"/\\\"}\" reply=\"error: once\" record=kept"
  expect_eq "undo: the restore sends every captured line after one fails" "$(evals | tail -n 2)" "$restore_dp1
$restore_dp2"
  expect_eq "undo: a failed restore keeps the record" "$(record_there)" yes
  expect_eq "undo: the record names the failure" "$(record_field failure)" "restore=failed lines=1 line=\"${restore_dp1//\"/\\\"}\" reply=\"error: once\""
  expect_eq "undo: the guard stays armed" "$(guard_held)" yes
  expect_eq "undo: the guard restores at the deadline and exits" "$(wait_free 8)" free
  expect_eq "undo: DP-1 reads its captured state after the guard" "$(out_state DP-1)" "$before_dp1"
  expect_eq "undo: the record is gone after the guard" "$(record_there)" no
  end_world
}

# A revert whose restore fails keeps the record and its guard, which
# restores at the deadline.
case_revert_kept() {
  local bin="$1"
  new_world revert-kept
  gv "$bin" preview 3 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "revert kept: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  set_state 's["failReads"] = 1'
  gv "$bin" revert "$token"
  if [[ $status == 1 && $err == "vgsh: refused: revert=restore-failed restore=unread outputs=unread hyprctl=failed status=1 "*" record=kept" ]]; then ok "revert kept: a failed revert answers its refusal"
  else fail "revert kept: a failed revert answers its refusal: status=$status err=[$err]"; fi
  expect_eq "revert kept: a failed revert keeps the record" "$(record_there)" yes
  expect_eq "revert kept: the guard stays armed" "$(guard_held)" yes
  expect_eq "revert kept: the guard restores at the deadline and exits" "$(wait_free 8)" free
  expect_eq "revert kept: DP-1 reads its captured state" "$(out_state DP-1)" "$before_dp1"
  expect_eq "revert kept: the record is gone" "$(record_there)" no
  end_world
}

# A guard whose restore fails tries again after a pause.
case_retry() {
  local bin="$1"
  new_world retry
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "retry: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  set_state 's["failReads"] = 1'
  expect_eq "retry: the guard exits" "$(wait_free 9)" free
  expect_eq "retry: the guard logs the failed first attempt" "$(log_has "guard=retry token=$token attempt=1 restore=unread")" yes
  expect_eq "retry: the guard restores on a later attempt" "$(log_has "guard=restored token=$token restored=1")" yes
  expect_eq "retry: DP-1 reads its captured state" "$(out_state DP-1)" "$before_dp1"
  expect_eq "retry: the record is gone" "$(record_there)" no
  end_world
}

# A guard whose instance is gone stops trying and removes the record.
case_instance_gone() {
  local bin="$1"
  new_world instance-gone
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "instance gone: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  rm -f -- "${rt:?}/hypr/$sig/.socket.sock"
  set_state 's["failReads"] = 100'
  expect_eq "instance gone: the guard exits after one attempt" "$(wait_free 6)" free
  expect_eq "instance gone: the guard logs the instance gone" "$(log_has "guard=instance-gone token=$token signature=$sig restore=unread")" yes
  expect_eq "instance gone: the guard removes the record" "$(record_there)" no
  end_world
}

# A guard that fails every attempt gives up after the last, keeps the
# record with its failure, and the next adopt arms a guard that restores.
case_attempts() {
  local bin="$1"
  new_world attempts
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "attempts: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  set_state 's["failReads"] = 100'
  expect_eq "attempts: the guard gives up after its last attempt" "$(wait_free 12)" free
  expect_eq "attempts: the guard logs its last attempt" "$(log_has "guard=failed token=$token attempts=5 restore=unread")" yes
  expect_eq "attempts: the record stays" "$(record_there)" yes
  [[ $(record_field failure) == "restore=unread "* ]] && ok "attempts: the record names the failure" || fail "attempts: the record names the failure: [$(record_field failure)]"
  set_state 's["failReads"] = 0'
  gv "$bin" adopt
  [[ $out =~ ^ok\ adopt=armed\ token=$token$ ]] && ok "attempts: adopt arms a guard for the kept record" || fail "attempts: adopt arms a guard for the kept record: status=$status out=[$out] err=[$err]"
  expect_eq "attempts: the adopted guard restores and exits" "$(wait_free 6)" free
  expect_eq "attempts: DP-1 reads its captured state" "$(out_state DP-1)" "$before_dp1"
  expect_eq "attempts: the record is gone" "$(record_there)" no
  end_world
}

# A verb waits on the transaction lock for a bounded time.
case_lock_busy() {
  local bin="$1" tx
  new_world lock-busy
  mkdir -p "$rt/vgs"
  exec {tx}>>"$(tx_lock)"
  flock "$tx"
  gv_prefix=(timeout 45)
  gv "$bin" confirm 0123456789abcdef0123456789abcdef
  gv_prefix=()
  exec {tx}>&-
  expect_reply "lock busy: confirm refuses after its bound" 1 "" "vgsh: refused: lock=busy path=$(tx_lock) wait-s=30"
  end_world
}

# One preview at a time; revert restores at once; a token must match.
case_busy_revert() {
  local bin="$1" first
  new_world busy-revert
  gv "$bin" preview 5 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "busy: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  first="$token"
  gv "$bin" preview 5 "$(req "[$rule_dp2_scale2]")"
  expect_reply "busy: a second preview over a record is refused" 1 "" "vgsh: refused: preview=busy path=$(record)"
  expect_eq "busy: the second preview applied nothing" "$(out_state DP-2)" "$before_dp2"
  gv "$bin" revert 00000000000000000000000000000000
  expect_reply "revert: another token is refused" 1 "" "vgsh: refused: token=mismatch"
  gv "$bin" revert "$first"
  expect_reply "revert: the preview's token restores at once" 0 "ok restored=1" ""
  expect_eq "revert: DP-1 reads its captured state" "$(out_state DP-1)" "$before_dp1"
  expect_eq "revert: the record is gone" "$(record_there)" no
  expect_eq "revert: the guard exits" "$(wait_free 3)" free
  gv "$bin" revert "$first"
  expect_reply "revert: a second revert finds the preview gone" 1 "" "vgsh: refused: preview=gone"
  end_world
}

# Confirm at the deadline: whichever takes the transaction lock first wins,
# and the state matches the answer.
case_race() {
  local bin="$1" outcome
  new_world race
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "race: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  until_epoch "$deadline"
  gv "$bin" confirm "$token"
  wait_free 4 >/dev/null
  outcome="$status:$err:$(out_state DP-1)"
  case "$outcome" in
    "0::$dp1_scale2"|"1:vgsh: refused: preview=gone:$before_dp1") ok "race: confirm at the deadline and the state agree: ${outcome%%:*}" ;;
    *) fail "race: confirm at the deadline and the state disagree: $outcome" ;;
  esac
  expect_eq "race: the record is gone" "$(record_there)" no
  end_world
}

# A preview killed after its record and before its guard leaves the record;
# adopt arms a guard for it, which restores at once past the deadline.
case_adopt() {
  local bin="$1"
  new_world adopt
  gv "$bin" adopt
  expect_reply "adopt: no record" 0 "ok adopt=none" ""
  gv_env=(VGS_MONITOR_PREVIEW_FAULT=record)
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  gv_env=()
  expect_eq "adopt: the preview killed after its record exits by SIGKILL" "$status" 137
  expect_eq "adopt: its record is left" "$(record_there)" yes
  expect_eq "adopt: no guard runs for it" "$(guard_held)" no
  until_epoch "$(( $(date +%s) + 3 ))"
  gv "$bin" adopt
  [[ $out =~ ^ok\ adopt=armed\ token=[0-9a-f]{32}$ ]] && ok "adopt: a record whose guard is gone gets one" || fail "adopt: a record whose guard is gone gets one: status=$status out=[$out] err=[$err]"
  expect_eq "adopt: the new guard restores at once past the deadline and exits" "$(wait_free 4)" free
  expect_eq "adopt: the record is gone" "$(record_there)" no
  expect_eq "adopt: nothing was applied, so DP-1 reads as before" "$(out_state DP-1)" "$before_dp1"
  gv "$bin" preview 5 "$(req "[$rule_dp1_scale2]")"
  token_of || { fail "adopt: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  gv "$bin" adopt
  expect_reply "adopt: a record whose guard runs is left to it" 0 "ok adopt=guarded" ""
  gv "$bin" revert "$token"
  expect_eq "adopt: the guarded preview reverts" "$status" 0
  expect_eq "adopt: its guard exits" "$(wait_free 3)" free
  end_world
}

# A preview killed right after each step, under the test-run marker: the
# outputs read their captured state once the deadline passed.
# rows: step | record after the kill | guard after the kill | DP-1 after the kill
fault_rows=(
  "capture|no|no|$before_dp1"
  "arm|yes|yes|$before_dp1"
  "apply|yes|yes|$dp1_scale2"
  "verify|yes|yes|$dp1_scale2"
)
case_faults() {
  local bin="$1" row step want_record want_guard want_state
  for row in "${fault_rows[@]}"; do
    IFS='|' read -r step want_record want_guard want_state <<<"$row"
    new_world "fault-$step"
    gv_env=(VGS_MONITOR_PREVIEW_FAULT="$step")
    gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
    gv_env=()
    expect_eq "fault $step: the preview dies by SIGKILL" "$status" 137
    expect_eq "fault $step: the record" "$(record_there)" "$want_record"
    expect_eq "fault $step: the guard" "$(guard_held)" "$want_guard"
    expect_eq "fault $step: DP-1 right after the kill" "$(out_state DP-1)" "$want_state"
    expect_eq "fault $step: no guard runs after the deadline" "$(wait_free 6)" free
    expect_eq "fault $step: DP-1 reads its captured state after the deadline" "$(out_state DP-1)" "$before_dp1"
    expect_eq "fault $step: no record is left" "$(record_there)" no
    end_world
  done
}

# Without the test-run marker the fault is not read; a fault the helper
# does not know is refused under it.
case_fault_gate() {
  local bin="$1"
  new_world fault-gate
  gv_env=(VGS_TEST_RUN= VGS_MONITOR_PREVIEW_FAULT=apply)
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  gv_env=()
  token_of && ok "fault gate: without the marker the fault is not read" || fail "fault gate: without the marker the fault is not read: status=$status err=[$err]"
  [[ -z $token ]] || gv "$bin" revert "$token"
  gv_env=(VGS_MONITOR_PREVIEW_FAULT=sideways)
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  gv_env=()
  expect_reply "fault gate: an unknown step is refused" 2 "" 'vgsh: refused: fault="sideways" want=capture|record|arm|apply|verify'
  expect_eq "fault gate: the guard exits" "$(wait_free 3)" free
  end_world
}

# No guard holds a descriptor its caller had open: the caller holds a file
# named vgsh.lock on descriptor 9 without close-on-exec, as a runner whose
# descriptor leaked would. The preview's guard is checked, and a second
# guard for the same token, started straight from such a caller, which
# waits on the guard lock and then finds the record gone.
case_descriptors() {
  local bin="$1" pid links second comm=""
  new_world descriptors
  gv_prefix=(bash -c 'exec 9>>"$0"; exec "$@"' "$rt/vgsh.lock")
  gv "$bin" preview 5 "$(req "[$rule_dp1_scale2]")"
  gv_prefix=()
  token_of || { fail "descriptors: the preview answers ok: status=$status err=[$err]"; end_world; return; }
  pid="$(guard_pid)"
  links="$(for fd in /proc/"$pid"/fd/*; do readlink -- "$fd" || true; done)"
  [[ -n $links ]] && ok "descriptors: the guard's descriptors are read" || fail "descriptors: the guard's descriptors are read: /proc/$pid/fd read nothing"
  if grep -qF -- "$rt/vgsh.lock" <<<"$links"; then fail "descriptors: the preview's guard holds no descriptor its caller had open: it holds vgsh.lock"; else ok "descriptors: the preview's guard holds no descriptor its caller had open"; fi
  if grep -qF -- "monitors-preview.lock" <<<"$links"; then fail "descriptors: the guard does not hold the transaction lock while it waits: it does"; else ok "descriptors: the guard does not hold the transaction lock while it waits"; fi
  bash -c 'exec 9>>"$0"; exec "$@"' "$rt/vgsh.lock" "${base_env[@]}" XDG_RUNTIME_DIR="$rt" HYPRLAND_INSTANCE_SIGNATURE="$sig" STANDIN_STATE="$state" STANDIN_CALLS="$calls" \
    "$bin" "$token" </dev/null >"$world/second.out" 2>&1 &
  second=$!
  # The wrapper execs node in its own process: the pid runs the guard once
  # its command line names the library's guard verb.
  for _ in $(seq 1 50); do
    comm="$(tr '\0' ' ' <"/proc/$second/cmdline" 2>/dev/null)" || comm=""
    [[ $comm == *"/monitor-preview.js guard $token "* ]] && break
    sleep 0.1
  done
  sleep 0.3
  links="$(for fd in /proc/"$second"/fd/*; do readlink -- "$fd" || true; done)"
  expect_eq "descriptors: a second guard runs and waits on the guard lock" "$([[ $comm == *"/monitor-preview.js guard $token "* && $(guard_pid) != "$second" ]] && echo waits || echo "[$comm]")" waits
  if grep -qF -- "$rt/vgsh.lock" <<<"$links"; then fail "descriptors: a guard started straight from the caller holds no descriptor it had open: it holds vgsh.lock"; else ok "descriptors: a guard started straight from the caller holds no descriptor it had open"; fi
  gv "$bin" revert "$token"
  expect_eq "descriptors: the guards exit once the preview is reverted" "$(wait_free 3)" free
  for _ in $(seq 1 50); do kill -0 "$second" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$second" 2>/dev/null; then
    fail "descriptors: the second guard outlived its bound and is reaped"
    kill -TERM "$second" 2>/dev/null || true
    sleep 0.5
    kill -KILL "$second" 2>/dev/null || true
  fi
  wait "$second" 2>/dev/null || true
  expect_eq "descriptors: the second guard found the record gone" "$(grep -c " guard=gone token=$token pid=" "$world/second.out" || true)" 1
  end_world
}

case_refusals() {
  local bin="$1"
  new_world refusals
  gv "$bin" preview 1 "$(req "[$rule_dp1_scale2]")"
  expect_reply "refusals: a preview under two seconds" 2 "" "vgsh: refused: seconds=1 want=2..60"
  gv "$bin" preview 61 "$(req "[$rule_dp1_scale2]")"
  expect_reply "refusals: a preview over a minute" 2 "" "vgsh: refused: seconds=61 want=2..60"
  gv "$bin" preview 2 "$(req "[{\"output\": \"$dp1\", \"mode\": \"3840x2160@60.000\", \"position\": {\"x\": 0, \"y\": 0}, \"scale\": 2, \"bitdepth\": 10}]")"
  expect_reply "refusals: a field no capture reads back, changed" 1 "" "vgsh: refused: rule=0 bitdepth=10 want=saved-value-in-preview"
  mkdir -p "$rt/vgs"
  ln -s "$world/state.json" "$(record)"
  gv "$bin" preview 2 "$(req "[$rule_dp1_scale2]")"
  expect_reply "refusals: a record that is a symlink is never read" 1 "" "vgsh: refused: record=not-a-file path=$(record)"
  expect_eq "refusals: nothing reached Hyprland" "$(eval_count)" 0
  end_world
}

case_first_use "$repo/bin/vgsh-monitor-guard"
case_foreign_alive "$repo/bin/vgsh-monitor-guard"
case_foreign_stale "$repo/bin/vgsh-monitor-guard"
case_confirmed "$repo/bin/vgsh-monitor-guard"
case_confirmed_at_deadline "$repo/bin/vgsh-monitor-guard"
case_deadline_steps_back "$repo/bin/vgsh-monitor-guard"
case_unplugged "$repo/bin/vgsh-monitor-guard"
case_partial "$repo/bin/vgsh-monitor-guard"
case_fallback "$repo/bin/vgsh-monitor-guard"
case_never_lands "$repo/bin/vgsh-monitor-guard"
case_undo_kept "$repo/bin/vgsh-monitor-guard"
case_revert_kept "$repo/bin/vgsh-monitor-guard"
case_retry "$repo/bin/vgsh-monitor-guard"
case_instance_gone "$repo/bin/vgsh-monitor-guard"
case_attempts "$repo/bin/vgsh-monitor-guard"
case_lock_busy "$repo/bin/vgsh-monitor-guard"
case_busy_revert "$repo/bin/vgsh-monitor-guard"
case_race "$repo/bin/vgsh-monitor-guard"
case_adopt "$repo/bin/vgsh-monitor-guard"
case_faults "$repo/bin/vgsh-monitor-guard"
case_fault_gate "$repo/bin/vgsh-monitor-guard"
case_descriptors "$repo/bin/vgsh-monitor-guard"
case_refusals "$repo/bin/vgsh-monitor-guard"

# tree_copy NAME FILE OLD NEW: a copy of the helper's tree, the wrapper,
# its library, the libraries it loads and MonitorLogic.js, with OLD in
# FILE, a path under the tree, replaced by NEW; OLD must occur once and the
# file must change. Sets copy_bin.
tree_copy() {
  local root="$tmp/copies/$1"
  mkdir -p "$root/bin/lib" "$root/shell/Core"
  cp -- "$repo/bin/vgsh-monitor-guard" "$root/bin/"
  cp -- "$repo/bin/lib/monitor-preview.js" "$repo/bin/lib/judge-files.js" "$repo/bin/lib/qml-library.js" "$root/bin/lib/"
  cp -- "$repo/shell/Core/MonitorLogic.js" "$root/shell/Core/"
  OLD="$3" NEW="$4" python3 -c 'import os, sys
path = sys.argv[1]
text = open(path).read()
count = text.count(os.environ["OLD"])
if count != 1:
    sys.exit("needle occurs %d times" % count)
open(path, "w").write(text.replace(os.environ["OLD"], os.environ["NEW"], 1))' "$root/$2" || { echo "$suite: control=$1 needle" >&2; exit 1; }
  cmp -s -- "$repo/$2" "$root/$2" && { echo "$suite: control=$1 unchanged" >&2; exit 1; }
  copy_bin="$root/bin/vgsh-monitor-guard"
}
# control NAME CASE CHECK FILE OLD NEW: CASE against the copy with OLD in
# FILE replaced by NEW must fail the check named CHECK; another failure, or
# a case that stops on an error, is no red for this control.
control() {
  local name="$1" case_fn="$2" check="$3" count=""
  tree_copy "$name" "$4" "$5" "$6"
  rm -f -- "$tmp/control.count"
  ( failures=0; "$case_fn" "$copy_bin" >"$tmp/control-$name.log" 2>&1; echo "$failures" >"$tmp/control.count" )
  [[ -r $tmp/control.count ]] && IFS= read -r count <"$tmp/control.count"
  if [[ -z $count ]]; then fail "control $name: $case_fn stopped on an error: $tmp/control-$name.log"
  elif grep -qF -- "  FAIL  $check" "$tmp/control-$name.log"; then ok "control $name: '$check' fails on the copy"
  else fail "control $name: '$check' passed on a copy without the rule: $tmp/control-$name.log"; fi
}

lib=bin/lib/monitor-preview.js
logic=shell/Core/MonitorLogic.js
control reload-restores case_first_use "first use: DP-1 reads its captured state again" "$lib" \
  "    for (const line of plan.lines) {
        const reply = evalLine(signature, line);" \
  "    for (const line of [\"reload\"]) {
        const reply = hyprctl(signature, [\"reload\"]).ok ? \"ok\" : \"failed\";"
control reads-record-after-applying case_confirmed_at_deadline "at the deadline: a confirmed record is left alone" "$lib" \
  "            record = readRecord(paths);
            action = Monitors.guardAction(record, token, signature, now());
            if (action !== \"restore\") {
                tx.release();
                continue;
            }
            const result = await restore(record.signature, record.captured);" \
  "            const result = await restore(record.signature, record.captured);
            record = readRecord(paths);
            action = Monitors.guardAction(record, token, signature, now());
            if (action !== \"restore\") {
                tx.release();
                continue;
            }"
control keeps-lock-on-reread case_deadline_steps_back "deadline stepped back: the guard releases the transaction lock and waits" "$lib" \
  "            if (action !== \"restore\") {
                tx.release();
                continue;
            }" \
  "            if (action !== \"restore\") {
                continue;
            }"
control guard-acts-on-foreign case_foreign_alive "foreign: no eval reaches Hyprland" "$logic" \
  '    if (record.signature !== signature) return "foreign";
    return now < record.deadline' '    return now < record.deadline'
control adopt-arms-for-foreign case_foreign_alive "foreign: adopt leaves another instance's live record" "$logic" \
  '    if (record.signature !== signature) return alive ? "foreign" : "stale";' ''
control stale-kept case_foreign_stale "stale: adopt removes a gone instance's record" "$logic" \
  'return alive ? "foreign" : "stale";' 'return "foreign";'
control preview-blocked-by-stale case_foreign_stale "stale: a preview over a gone instance's record runs" "$lib" \
  'if (before.action !== "none" && before.action !== "stale") refuse' 'if (before.action !== "none") refuse'
control restores-unplugged case_unplugged "unplugged: the restore sends DP-1's line alone" "$logic" \
  "        if (resolve(outputs, entry.output) === -1) {" "        if (false) {"
control keeps-descriptors case_descriptors "descriptors: a guard started straight from the caller holds no descriptor it had open" bin/vgsh-monitor-guard \
  '(( 8#$flags & 8#2000000 )) || exec {fd}>&-' '(( 8#$flags & 8#2000000 )) || :'
control same-session case_first_use "first use: the guard leads a session of its own" "$lib" "{ detached: true, stdio:" "{ detached: false, stdio:"
control fault-without-marker case_fault_gate "fault gate: without the marker the fault is not read" "$lib" "    if (!process.env.VGS_TEST_RUN) return null;
" ""
control second-preview case_busy_revert "busy: a second preview over a record is refused" "$lib" \
  '    if (before.action !== "none" && before.action !== "stale") refuse("preview=busy path=" + paths.record);' ""
control apply-failed-keeps case_partial "partial: DP-1, applied before the failure, reads its captured state" "$lib" \
  'if (reply !== "ok") await undo(paths, signature, record, "preview=apply-failed' \
  'if (reply !== "ok") await undo(paths, signature, Object.assign({}, record, { captured: [] }), "preview=apply-failed'
control fallback-keeps case_fallback "fallback: DP-1 reads its captured state" "$lib" \
  'if (verified.differs.length > 0) await undo(paths, signature, record,' \
  'if (verified.differs.length > 0) await undo(paths, signature, Object.assign({}, record, { captured: [] }),'
control record-readable case_first_use "first use: the record is the user's alone" "$lib" \
  'replaceFile(paths.record, Monitors.recordText(record), "record", 0o600);' 'replaceFile(paths.record, Monitors.recordText(record), "record", 0o644);'
control settle-reads-once case_first_use "first use: the preview answers ok token=<32 hex> deadline=<epoch>" "$lib" \
  "if (differs.length === 0 || Date.now() >= until) return { ok: true, differs: differs };" "return { ok: true, differs: differs };"
control restore-stops-at-first case_undo_kept "undo: the restore sends every captured line after one fails" "$lib" \
  'if (reply !== "ok") failed.push({ line: line, reply: reply });' 'if (reply !== "ok") { failed.push({ line: line, reply: reply }); break; }'
control undo-removes-record case_undo_kept "undo: a failed restore keeps the record" "$lib" \
  '    keepFailure(paths, record, result.words);
    refuse(first + " " + result.words + " record=kept");' '    removeRecord(paths);
    refuse(first + " " + result.words + " record=kept");'
control revert-removes-record case_revert_kept "revert kept: a failed revert keeps the record" "$lib" \
  '        keepFailure(paths, record, result.words);
        refuse("revert=restore-failed' '        removeRecord(paths);
        refuse("revert=restore-failed'
control guard-tries-once case_retry "retry: the guard restores on a later attempt" "$lib" \
  "if (attempts >= RESTORE_ATTEMPTS) {" "if (attempts >= 1) {"
control guard-tries-unbounded case_attempts "attempts: the guard gives up after its last attempt" "$lib" \
  "const RESTORE_ATTEMPTS = 5;" "const RESTORE_ATTEMPTS = 50;"
control instance-gone-retries case_instance_gone "instance gone: the guard removes the record" "$lib" \
  "            if (!instanceAlive(record.signature)) {" "            if (false) {"
control lock-wait-unbounded case_lock_busy "lock busy: confirm refuses after its bound" "$lib" \
  "    const lock = hold(paths.transaction, TX_WAIT_S);" "    const lock = hold(paths.transaction, true);"
control arms-after-apply case_faults "fault apply: DP-1 reads its captured state after the deadline" "$lib" '    // 3. Arm the guard.
    if (!(await arm(paths, record.token))) {
        removeRecord(paths);
        refuse("guard=unarmed timeout-ms=" + ARM_TIMEOUT_MS + " log=" + paths.log);
    }
    after("arm", fault);

    // 4. Apply.
    for (const line of Monitors.render(plan.applied)) {
        const reply = evalLine(signature, line);
        if (reply !== "ok") await undo(paths, signature, record, "preview=apply-failed line=" + JSON.stringify(line) + " reply=" + JSON.stringify(reply));
    }
    after("apply", fault);' '    // 4. Apply.
    for (const line of Monitors.render(plan.applied)) {
        const reply = evalLine(signature, line);
        if (reply !== "ok") await undo(paths, signature, record, "preview=apply-failed line=" + JSON.stringify(line) + " reply=" + JSON.stringify(reply));
    }
    after("apply", fault);

    // 3. Arm the guard.
    if (!(await arm(paths, record.token))) {
        removeRecord(paths);
        refuse("guard=unarmed timeout-ms=" + ARM_TIMEOUT_MS + " log=" + paths.log);
    }
    after("arm", fault);'

rows_done "$suite"
