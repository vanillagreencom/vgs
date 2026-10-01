# Monitor previews on the nested output through the `monitors` capability
# and bin/vgsh-monitor-guard, read back from the nested Hyprland through
# hyprctl, from the acme.monitors fixture and from the preview's files in
# the sandbox's runtime directory
# (docs/architecture/hyprland-monitors-preview.md). It runs after
# rows/monitor-rules.sh, which installed the fixture, left no monitors.json
# and gave the first nested output, WAYLAND-1, its own mode at scale 1.
#
# Each preview gives the output double its mode at scale 2, as
# rows/monitor-rules.sh writes it, for a few seconds. A host configure can
# move the output off that mode before the preview reads it back
# (validation-smoke-faults.md), which the preview refuses as a fallback, so
# a start that reads `preview=fallback` is tried again, up to mode_attempts
# times. The guard's restore gives the output its own mode at scale 1,
# which a configure of the window's own size leaves as it is.
#
# The cases: the deadline restores scale 1; Keep saves monitors.json and
# the layer's rule holds scale 2 through `hyprctl reload config-only`; the
# guard restores with the shell stopped by SIGSTOP and with the runner
# stopped, then the shell starts again; a preview killed right after each
# of capture, record, arm, apply and verify, run straight through the
# helper with the sandbox's environment, the test-run marker and
# VGS_MONITOR_PREVIEW_FAULT, reads scale 1 once the deadline passed, and the
# record a kill after `record` leaves stays until a shell start's adopt
# hands it to a guard.
# The control runs every time: a copy of the tree whose preview arms its
# guard only after it applied, killed right after `apply`, still reads
# scale 2 after the deadline, and adopt then restores it. Every guard the
# row leaves running is a failure, reaped by the pid in the guard lock.
#
# No latency is budgeted: each reading polls every 0.2 s, for up to 5 s
# through expect_poll and for up to 12 s while a guard's deadline passes.
set -euo pipefail
user_config="$home/.config/vgs/shell.json"
monitors_doc="$home/.config/vgs/monitors.json"
preview_record="$rt_dir/vgs/monitors-preview.json"
guard_lock="$rt_dir/vgs/monitors-guard.lock"
cp -- "$user_config" "$sandbox/shell-before-preview.json"

read_monitors() { ipc smoke readInstance service acme.monitors "$1"; }
preview_field() { read_monitors previewState | py_reply 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
write_phase() { read_monitors writeState | py_reply 'import json,sys; print(json.load(sys.stdin)["phase"])'; }
record_there() { if [[ -e $preview_record ]]; then echo yes; else echo no; fi; }
guard_held() { if [[ -e $guard_lock ]] && ! flock -n "$guard_lock" true; then echo yes; else echo no; fi; }
config_errors() { hypr -j configerrors | py_reply 'import json,sys; print(json.dumps([e for e in json.load(sys.stdin) if e]))'; }
# guard_ends: `free` once no guard holds the guard lock, read every 0.2 s
# for up to 12 s, past a deadline of up to 5 s and the guard's restore.
guard_ends() {
  for _ in $(seq 1 60); do
    [[ $(guard_held) == no ]] && { echo free; return 0; }
    sleep 0.2
  done
  echo held
}
# reap_guard LABEL: a guard still holding the guard lock is a failure; it
# gets TERM, then KILL, by the pid the lock file names, never by name.
reap_guard() {
  local pid=""
  [[ $(guard_held) == yes ]] || return 0
  IFS= read -r pid <"$guard_lock" || true
  fail "$1: a guard was still running: pid=${pid:-unread}"
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 25); do [[ $(guard_held) == no ]] && return 0; sleep 0.2; done
  kill -KILL "$pid" 2>/dev/null || true
}
# helper TREE ARGS...: TREE's bin/vgsh-monitor-guard as the shell runs it,
# with the sandbox's environment, which carries the test-run marker, and
# helper_env words last. Prints its stdout; its status is the helper's.
helper_env=()
helper() { local tree="$1"; shift; "${shell_env[@]}" "${shell_start_words[@]}" "${helper_env[@]}" "$tree/bin/vgsh-monitor-guard" "$@" </dev/null; }
helper_status() { local status=0; helper "$@" >/dev/null 2>&1 || status=$?; echo "$status"; }
# adopt_reply: `armed` when the helper's adopt armed a guard, else its reply.
adopt_reply() { local out; out="$(helper "$repo" adopt 2>&1)" || true; if [[ $out =~ ^ok\ adopt=armed\ token=[0-9a-f]{32}$ ]]; then echo armed; else echo "[$out]"; fi; }
outputs_list() { read_monitors outputs | py_reply 'import json,sys; print("listed" if any(o["name"]==sys.argv[1] for o in (json.load(sys.stdin) or [])) else "unlisted")' "$1"; }
layer_mentions_monitors() { if grep -qF -- "-- Monitors" "$home/.local/state/vgs/hypr/vgs.lua"; then echo yes; else echo no; fi; }
# start_preview SECONDS: a preview through the fixture, read until its
# phase leaves `starting`; one refused as a fallback is tried again, up to
# mode_attempts times. Prints `previewing`, or the last phase and failure.
start_preview() {
  local attempt reply phase="" failure=""
  for ((attempt = 1; attempt <= mode_attempts; attempt++)); do
    reply="$(ipc acme.monitors invoke preview "{\"rules\": $preview_rules, \"seconds\": $1}")" || reply="ipc-failed"
    [[ $reply == ok ]] || { echo "reply=[$reply]"; return 0; }
    for _ in $(seq 1 50); do
      phase="$(preview_field phase)" || phase=unread
      [[ $phase == starting ]] || break
      sleep 0.2
    done
    [[ $phase == previewing ]] && { echo previewing; return 0; }
    failure="$(preview_field failure)" || failure=unread
    [[ $failure == "refused: preview=fallback"* ]] || break
  done
  echo "phase=$phase failure=[$failure]"
}

expect "enabling the monitors fixture for the previews is allowed" ok ipc shell setPluginEnabled acme.monitors true
expect_poll "the monitors fixture builds for the previews" True record_exists acme.monitors
expect_poll "no preview runs before the first" idle preview_field phase

if ! preview_output="$(first_name)" || ! preview_base="$(unscaled_mode_of "$preview_output")" || ! preview_double="$(hidpi_mode_of "$preview_output")"; then
  fail "the monitor preview row reads no sized mode at scale 1 on the first monitor ${preview_output:-unread}"
else
  expect_poll "the fixture's outputs list $preview_output" listed outputs_list "$preview_output"
  preview_refresh="$(read_monitors outputs | py_reply 'import json,sys; print("%.3f" % [o for o in json.load(sys.stdin) if o["name"]==sys.argv[1]][0]["refreshRate"])' "$preview_output")" || preview_refresh=unread
  preview_rules="[{\"output\": \"$preview_output\", \"mode\": \"$preview_double@$preview_refresh\", \"position\": {\"x\": 0, \"y\": 0}, \"scale\": 2}]"
  preview_request="{\"rules\": $preview_rules, \"saved\": []}"
  scale2="$preview_double scale=2"
  scale1="$preview_base scale=1"

  # The deadline restores scale 1.
  expect "a 3 s preview at scale 2 starts" previewing start_preview 3
  expect "the preview reads scale 2" "$scale2" mode_scale_of "$preview_output"
  expect "the preview's record is written" yes record_there
  expect "a guard holds the guard lock" yes guard_held
  expect "the guard restores and exits after the deadline" free guard_ends
  expect_poll "the deadline restores scale 1" "$scale1" mode_scale_of "$preview_output"
  expect "the restored preview's record is gone" no record_there
  expect_poll "the preview ends in the capability after the deadline" idle preview_field phase
  expect "the restore's lines hold no configuration error" '[]' config_errors

  # Keep saves monitors.json, and the layer's rule holds scale 2 through a
  # reload.
  expect "a 5 s preview at scale 2 starts for Keep" previewing start_preview 5
  preview_token="$(preview_field token)" || preview_token=unread
  expect "Keep is accepted" ok ipc acme.monitors invoke confirm "$preview_token"
  expect_poll "Keep ends the preview" idle preview_field phase
  expect_poll "Keep writes the rules" idle write_phase
  expect "Keep saves monitors.json" "$(printf '{\n  "version": 1,\n  "rules": [\n    {\n      "output": "%s",\n      "mode": "%s",\n      "position": {\n        "x": 0,\n        "y": 0\n      },\n      "scale": 2\n    }\n  ]\n}' "$preview_output" "$preview_double@$preview_refresh")" cat -- "$monitors_doc"
  expect "the kept preview's guard exits with nothing to restore" free guard_ends
  expect "the kept preview reads scale 2 after its deadline" "$scale2" mode_scale_of "$preview_output"
  expect "the nested instance reloads after Keep" ok hypr reload config-only
  expect "Keep holds scale 2 through a reload" held layer_mode_reads "$preview_output" "$preview_double" 2
  rm -f -- "$monitors_doc"
  expect_poll "with monitors.json removed the layer writes no Monitors section" no layer_mentions_monitors
  release_mode "the nested compositor gives $preview_output its own mode at scale 1 after Keep" "$preview_output" "$preview_base"

  # The guard restores with the shell stopped by SIGSTOP.
  expect "a 3 s preview starts before the shell stops" previewing start_preview 3
  kill -STOP "$shell_qs_pid"
  expect "the guard restores while the shell is stopped" free guard_ends
  expect "scale 1 is back while the shell is stopped" "$scale1" mode_scale_of "$preview_output"
  expect "the record is gone while the shell is stopped" no record_there
  kill -CONT "$shell_qs_pid"
  expect_poll "the shell answers again after SIGCONT" ok ipc shell ping
  expect_poll "the preview ends in the capability once the shell runs again" idle preview_field phase

  # The guard restores with the runner stopped, and the shell starts again.
  expect "a 3 s preview starts before the runner stops" previewing start_preview 3
  if stop_shell; then
    ok "the runner stops during the preview"
    expect "the guard restores with the runner stopped" free guard_ends
    expect "scale 1 is back with the runner stopped" "$scale1" mode_scale_of "$preview_output"
    expect "the record is gone with the runner stopped" no record_there
  fi
  start_shell "$repo" "$sandbox/monitor-preview-restart.log" || fail "the shell starts again after the runner stopped"
  expect_poll "the monitors fixture builds again" True record_exists acme.monitors

  # A preview killed right after each step.
  for preview_step in capture record arm apply verify; do
    helper_env=(VGS_MONITOR_PREVIEW_FAULT="$preview_step")
    expect "a preview killed after $preview_step dies by SIGKILL" 137 helper_status "$repo" preview 3 "$preview_request"
    helper_env=()
    case $preview_step in
      capture) expect "a kill after capture leaves no record" no record_there ;;
      record)
        expect "a kill after record leaves its record" yes record_there
        expect "a kill after record leaves no guard" no guard_held
        sleep 4 # past the record's deadline, which nothing watches
        expect "the record stays past its deadline with no guard" yes record_there
        # The shell's start hands the record to a guard.
        stop_shell || :
        start_shell "$repo" "$sandbox/monitor-preview-adopt.log" || fail "the shell starts again to adopt the record"
        expect_poll "the monitors fixture builds after the adopting start" True record_exists acme.monitors ;;
      *) expect "a kill after $preview_step leaves its guard running" yes guard_held ;;
    esac
    case $preview_step in
      apply|verify) expect_poll "a kill after $preview_step leaves scale 2 until the deadline" "$scale2" mode_scale_of "$preview_output" ;;
    esac
    expect "no guard runs once the deadline after $preview_step passed" free guard_ends
    expect_poll "scale 1 is back after a kill after $preview_step" "$scale1" mode_scale_of "$preview_output"
    expect "no record is left after a kill after $preview_step" no record_there
  done

  # The control: a preview that arms its guard only after it applied,
  # killed between the two, leaves scale 2 past its deadline.
  copy_tree preview-arms-late
  if edit_tree preview-arms-late bin/lib/monitor-preview.js '    // 3. Arm the guard.
    if (!(await arm(paths, record.token))) {
        removeRecord(paths);
        refuse("guard=unarmed timeout-ms=" + ARM_TIMEOUT_MS + " log=" + paths.log);
    }
    after("arm", fault);

    // 4. Apply.
    const applied = applyLines(signature, Monitors.render(plan.applied));
    if (!applied.ok) await undo(paths, signature, plan.captured, "preview=apply-failed line=" + JSON.stringify(applied.line) + " reply=" + JSON.stringify(applied.reply));
    after("apply", fault);' '    // 4. Apply.
    const applied = applyLines(signature, Monitors.render(plan.applied));
    if (!applied.ok) await undo(paths, signature, plan.captured, "preview=apply-failed line=" + JSON.stringify(applied.line) + " reply=" + JSON.stringify(applied.reply));
    after("apply", fault);

    // 3. Arm the guard.
    if (!(await arm(paths, record.token))) {
        removeRecord(paths);
        refuse("guard=unarmed timeout-ms=" + ARM_TIMEOUT_MS + " log=" + paths.log);
    }
    after("arm", fault);'; then
    helper_env=(VGS_MONITOR_PREVIEW_FAULT=apply)
    expect "control: the late-arming copy killed after apply dies by SIGKILL" 137 helper_status "$sandbox/tree-preview-arms-late" preview 3 "$preview_request"
    helper_env=()
    expect "control: the late-arming copy has no guard" no guard_held
    sleep 4 # past the copy's deadline
    expect "control: the late-arming copy leaves scale 2 past its deadline" "$scale2" mode_scale_of "$preview_output"
    expect "control: adopt hands the copy's record to a guard" armed adopt_reply
    expect "control: the adopted guard exits" free guard_ends
    expect_poll "control: adopt's guard restores scale 1" "$scale1" mode_scale_of "$preview_output"
  fi
  reap_guard "the monitor preview row"
  [[ ! -e $preview_record ]] || { fail "the monitor preview row left its record"; rm -f -- "$preview_record"; }
  expect "the previews leave no configuration error" '[]' config_errors
  release_mode "the nested compositor gives $preview_output its own mode at scale 1 after the previews" "$preview_output" "$preview_base"
fi
cp -- "$sandbox/shell-before-preview.json" "$user_config.next" && mv -T -- "$user_config.next" "$user_config"
expect "disabling the monitors fixture after the previews is allowed" ok ipc shell setPluginEnabled acme.monitors false
expect_poll "the monitors fixture is disabled after the previews" False plugin_enabled acme.monitors
