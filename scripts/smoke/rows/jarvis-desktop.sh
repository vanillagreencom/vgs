# Jarvis's window, workspace, application and notice tools against the
# nested Hyprland. A disposable daemon copy carries scripted Session ports
# and a test-only driver that routes each call through the real router,
# Policy, audit, executors, request wire and service. The daemon's hyprctl
# is a stand-in pinned to this sandbox's instance, so no read reaches the
# live session. No audio, account, provider or network runs. Each result
# is read twice: the tool's own outcome, and Hyprland's state read by the
# row. No latency ceiling is measured: outcome and state reads poll every
# 200 ms (expect_poll); the driver polls its call file every 10 ms.
set -euo pipefail

jd_dir="$repo/shell/plugins/vgs.jarvis"
jd_backend="$jd_dir/backend/jarvisd.js"
jd_desktop="$jd_dir/backend/Desktop.js"
jd_service="$jd_dir/Service.qml"
jd_driver="$sandbox/jarvis-desktop-driver"
jd_gates="$sandbox/jarvis-desktop-gates"
jd_standin="$sandbox/jarvis-world/standins/hyprctl"
jd_entry="$home/.local/share/applications/smoke-jarvis-app.desktop"
jd_audit="$home/.local/state/vgs/jarvis/audit"
mkdir -p -- "$jd_driver"
cp -- "$jd_backend" "$sandbox/jarvis-desktop-backend-before"
cp -- "$jd_desktop" "$sandbox/jarvis-desktop-desktop-before"
cp -- "$jd_service" "$sandbox/jarvis-desktop-service-before"
jd_audit_before=false
[[ -e $jd_audit ]] && jd_audit_before=true
expect "the desktop row starts with Jarvis disabled" absent ipc smoke jarvisProcess

# The daemon's own reads, pinned to the nested instance. A dispatch is
# refused: the daemon changes Hyprland only through the shell.
cat >"$jd_standin" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$sandbox/jarvis-desktop-hyprctl.log"
[[ \${1:-} == dispatch ]] && exit 2
exec /usr/bin/env -i XDG_RUNTIME_DIR="$rt_dir" HYPRLAND_INSTANCE_SIGNATURE="$signature" "$hyprctl_bin" "\$@"
EOF
chmod 700 "$jd_standin"
: >"$sandbox/jarvis-desktop-hyprctl.log"
# The shell's dispatches dropped behind an `ok`, as a dispatcher that
# moves nothing answers.
cat >"$shim/hyprctl.jarvis-noop" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == dispatch ]]; then echo ok; else exec "$hyprctl_bin" "\$@"; fi
EOF
chmod 755 "$shim/hyprctl.jarvis-noop"
mkdir -p -- "$home/.local/share/applications"
printf '[Desktop Entry]\nType=Application\nName=Smoke Jarvis App\nExec=%s smoke.jarvis-app JarvisApp\nStartupWMClass=smoke.jarvis-app\n' \
  "$sandbox/toplevel" >"$jd_entry"

"$node_bin" "$source_repo/scripts/fixtures/jarvis/scripted.js" "$jd_backend" "$jd_gates"
"$node_bin" "$source_repo/scripts/fixtures/jarvis/desktop-driver.js" "$jd_backend" "$jd_driver"
jarvis_rescan

jd_id=""
# Readers that call it run in command substitutions, so the serial lives
# in a file and every call id stays unique.
jd_call() { # TOOL ARGS_JSON: one call for the driver; sets jd_id
  local serial
  serial="$(cat -- "$jd_driver/serial" 2>/dev/null || echo 0)"
  printf '%s\n' "$((serial + 1))" >"$jd_driver/serial"
  jd_id="smoke-$((serial + 1))"
  python3 -c 'import json,sys; print(json.dumps({"id": sys.argv[1], "tool": sys.argv[2], "arguments": json.loads(sys.argv[3])}))' \
    "$jd_id" "$1" "$2" >"$jd_driver/call.next"
  mv -T -- "$jd_driver/call.next" "$jd_driver/call.json"
}
jd_result() { # ID FIELD: the result's outcome or content, or pending
  python3 - "$jd_driver/results.jsonl" "$1" "$2" <<'PY'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
rows=[json.loads(l) for l in p.read_text().splitlines()] if p.exists() else []
row=next((r for r in rows if r["id"] == sys.argv[2] and "outcome" in r), None)
print("pending" if row is None else row[sys.argv[3]])
PY
}
jd_tool() { # LABEL OUTCOME TOOL ARGS_JSON
  jd_call "$3" "$4"
  expect_poll "$1" "$2" jd_result "$jd_id" outcome
}
jd_content_has() { # TEXT: whether the last call's result names TEXT
  python3 -c 'import sys; print(sys.argv[2] in sys.argv[1])' "$(jd_result "$jd_id" content)" "$1"
}
jd_client() { # ADDRESS FIELD
  hypr -j clients | py_reply 'import json,sys
c = next((c for c in json.load(sys.stdin) if c["address"] == sys.argv[1]), None)
print("absent" if c is None else json.dumps(c[sys.argv[2]]))' "$1" "$2"
}
jd_monitor() { # FIELD of the focused monitor
  hypr -j monitors | py_reply 'import json,sys
m = next((m for m in json.load(sys.stdin) if m["focused"]), None)
print("absent" if m is None else (m["name"] if sys.argv[1] == "name" else json.dumps(m[sys.argv[1]]["name"])))' "$1"
}
jd_class_address() { # CLASS: the one mapped window of CLASS, or windows=<n>
  hypr -j clients | py_reply 'import json,sys
cs = [c["address"] for c in json.load(sys.stdin) if c["class"] == sys.argv[1] and c["mapped"]]
print(cs[0] if len(cs) == 1 else "windows=%d" % len(cs))' "$1"
}
# The signature the service hands its child. J09 gives the daemon no
# session identifier, so the stand-in pins the nested instance; this reads
# the service's own hand-over from the launcher it started.
jd_signature() {
  local launcher
  launcher="$(jarvis_launcher_pid <<<"$(ipc smoke jarvisProcess)")" || return 1
  tr '\0' '\n' <"/proc/$launcher/environ" | sed -n 's/^HYPRLAND_INSTANCE_SIGNATURE=//p'
}
jd_launched_count() { hypr -j clients | py_reply 'import json,sys; print(sum(c["class"] == "smoke.jarvis-app" and c["mapped"] for c in json.load(sys.stdin)))'; }

jarvis_enable
expect "the service hands the daemon this session's Hyprland signature" "$signature" jd_signature
if open_toplevel "$sandbox/jarvis-desktop-target.log" smoke.jarvis-desktop target; then
  jd_target_pid="$toplevel_pid"
  jd_target="$(toplevel_address "$jd_target_pid")"
  if open_toplevel "$sandbox/jarvis-desktop-other.log" smoke.jarvis-desktop other; then
    jd_other_pid="$toplevel_pid"
    jd_other="$(toplevel_address "$jd_other_pid")"

    jd_tool "windows.list completes" completed windows.list '{}'
    expect "windows.list names the target window" True jd_content_has "$jd_target workspace="
    jd_tool "workspaces.list completes" completed workspaces.list '{}'
    expect "workspaces.list names the shown workspace" True jd_content_has 'name="1"'

    jd_tool "windows.focus reads the focus back" completed windows.focus "{\"window\": \"$jd_target\"}"
    expect "Hyprland shows the target focused" '["smoke.jarvis-desktop", "target"]' active_window
    jd_tool "windows.float reads floating back" completed windows.float "{\"window\": \"$jd_target\", \"action\": \"set\"}"
    expect "Hyprland shows the target floating" true jd_client "$jd_target" floating
    jd_tool "windows.move reads the position back" completed windows.move "{\"window\": \"$jd_target\", \"x\": 140, \"y\": 130}"
    geometry expect "Hyprland shows the target moved" '[140, 130]' jd_client "$jd_target" at
    jd_tool "windows.resize reads the size back" completed windows.resize "{\"window\": \"$jd_target\", \"width\": 460, \"height\": 310}"
    geometry expect "Hyprland shows the target resized" '[460, 310]' jd_client "$jd_target" size

    jd_tool "focus returns to the other window" completed windows.focus "{\"window\": \"$jd_other\"}"
    jd_tool "windows.fullscreen focuses its target first" completed windows.fullscreen "{\"window\": \"$jd_target\", \"mode\": \"fullscreen\", \"action\": \"set\"}"
    expect "Hyprland shows the target fullscreen" 2 jd_client "$jd_target" fullscreen
    expect "the other window stays out of fullscreen" 0 jd_client "$jd_other" fullscreen
    jd_tool "windows.fullscreen unset reads back" completed windows.fullscreen "{\"window\": \"$jd_target\", \"mode\": \"fullscreen\", \"action\": \"unset\"}"
    expect "Hyprland shows the target restored" 0 jd_client "$jd_target" fullscreen

    # A dispatcher that answers ok and moves nothing is not a completed
    # tool. The read-back defect must fail this same assertion once.
    jd_dropped() {
      local outcome
      shim_hyprctl jarvis-noop
      jd_call windows.focus "{\"window\": \"$jd_other\"}"
      for _ in $(seq 1 50); do
        outcome="$(jd_result "$jd_id" outcome)"
        [[ $outcome == pending ]] || break
        sleep 0.2
      done
      shim_hyprctl real
      expect "a dropped dispatch is not reported completed" failed printf '%s' "$outcome"
    }
    jd_dropped
    expect "the dropped focus left Hyprland unchanged" '["smoke.jarvis-desktop", "target"]' active_window
    jarvis_disable
    "$node_bin" "$source_repo/scripts/fixtures/jarvis/desktop-driver.js" --readback-defect "$jd_desktop"
    python3 - "$jd_service" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); s = p.read_text()
line = '            HYPRLAND_INSTANCE_SIGNATURE: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE"),\n'
assert s.count(line) == 1
p.write_text(s.replace(line, ""))
PY
    jarvis_rescan
    jarvis_enable
    jd_control_count="$( (failures=0 row_class=behaviour; jd_dropped >"$sandbox/jarvis-desktop-control.log"; echo "$failures") )"
    expect "control: a read-back that never waits fails the dropped dispatch once" 1 printf '%s' "$jd_control_count"
    jd_control_count="$( (failures=0 row_class=behaviour; expect "the service hands the daemon this session's Hyprland signature" "$signature" jd_signature >"$sandbox/jarvis-desktop-signature-control.log"; echo "$failures") )"
    expect "control: a service that drops the signature fails its hand-over once" 1 printf '%s' "$jd_control_count"
    jarvis_disable
    cp -- "$sandbox/jarvis-desktop-desktop-before" "$jd_desktop"
    cp -- "$sandbox/jarvis-desktop-service-before" "$jd_service"
    jarvis_rescan
    jarvis_enable

    jd_tool "windows.workspace reads the move back" completed windows.workspace "{\"window\": \"$jd_target\", \"workspace\": 3}"
    expect_poll "Hyprland shows the target on workspace 3" '{"id": 3, "name": "3"}' jd_client "$jd_target" workspace
    jd_tool "workspaces.focus reads the shown workspace back" completed workspaces.focus '{"workspace": 3}'
    expect "Hyprland shows workspace 3" '"3"' jd_monitor activeWorkspace
    jd_tool "workspaces.focus returns to workspace 1" completed workspaces.focus '{"workspace": 1}'
    jd_tool "windows.reveal brings the target back into view" completed windows.reveal "{\"window\": \"$jd_target\"}"
    expect "Hyprland shows the revealed target focused" '["smoke.jarvis-desktop", "target"]' active_window
    expect "the reveal showed the target's workspace" '"3"' jd_monitor activeWorkspace
    jd_tool "workspaces.special shows a special workspace" completed workspaces.special '{"name": "jarvis"}'
    expect "Hyprland shows the special workspace" '"special:jarvis"' jd_monitor specialWorkspace
    jd_tool "workspaces.special hides it again" completed workspaces.special '{"name": "jarvis"}'
    expect "Hyprland hides the special workspace" '""' jd_monitor specialWorkspace
    jd_tool "the row returns to workspace 1" completed workspaces.focus '{"workspace": 1}'

    # The headless output has no usable size on NVIDIA; hold the monitor
    # focus as the dispatcher row does, in this nested configuration alone.
    jd_config="$home/.config/hypr/hyprland.lua"
    cp -- "$jd_config" "$sandbox/hyprland-before-jarvis-desktop.lua"
    printf '%s\n' 'hl.config({ input = { follow_mouse = 0 }, cursor = { no_warps = true }, misc = { mouse_move_focuses_monitor = false } })' >>"$jd_config"
    expect "the nested configuration holds explicit monitor focus" ok hypr reload config-only
    jd_first_monitor="$(jd_monitor name)"
    expect "the nested compositor adds a monitor" ok hypr output create headless SMOKE-JARVIS
    jd_tool "windows.monitor reads the focused monitor back" completed windows.monitor '{"monitor": "SMOKE-JARVIS"}'
    expect "Hyprland focuses the requested monitor" SMOKE-JARVIS jd_monitor name
    jd_tool "windows.monitor returns to the first monitor" completed windows.monitor "{\"monitor\": \"$jd_first_monitor\"}"
    expect "Hyprland focuses the first monitor again" "$jd_first_monitor" jd_monitor name
    expect "the nested compositor removes the added monitor" ok hypr output remove SMOKE-JARVIS
    cp -- "$sandbox/hyprland-before-jarvis-desktop.lua" "$jd_config.next"
    mv -T -- "$jd_config.next" "$jd_config"
    expect "the nested configuration restores its focus settings" ok hypr reload config-only

    # Quickshell adds a planted entry to its index when its directory
    # watch reports it; each try is one completed list call.
    jd_listed() {
      local outcome
      for _ in $(seq 1 25); do
        jd_call apps.list '{"query": "smoke jarvis"}'
        for _ in $(seq 1 25); do
          outcome="$(jd_result "$jd_id" outcome)"
          [[ $outcome == pending ]] || break
          sleep 0.2
        done
        [[ $outcome == completed ]] || { echo "outcome=$outcome"; return; }
        if [[ $(jd_content_has "smoke-jarvis-app name=\"Smoke Jarvis App\"") == True ]]; then echo listed; return; fi
        sleep 0.2
      done
      echo absent
    }
    expect "apps.list names the planted entry" listed jd_listed
    jd_tool "apps.launch reads the new window back" completed apps.launch '{"desktop": "smoke-jarvis-app"}'
    expect "the result names the launched window's class" True jd_content_has 'class="smoke.jarvis-app"'
    expect "Hyprland maps one window of the launched entry" 1 jd_launched_count
    jd_launched="$(jd_class_address smoke.jarvis-app)"
    jd_tool "windows.close closes the launched window" completed windows.close "{\"window\": \"$jd_launched\"}"
    expect "Hyprland lists the launched window no more" windows=0 jd_class_address smoke.jarvis-app
    jd_tool "windows.close closes the other window" completed windows.close "{\"window\": \"$jd_other\"}"
    expect "Hyprland lists the other window no more" absent jd_client "$jd_other" address
    close_toplevel "$jd_other_pid" "the closed window's helper exits"

    jd_notices() { ipc smoke jarvisMuteNotices "Smoke Jarvis notice" "from the desktop row"; }
    jd_notices_before="$(jd_notices)"
    jd_tool "notify.toast reads the service's reply" completed notify.toast '{"title": "Smoke Jarvis notice", "body": "Posted from the desktop row."}'
    expect "the shell shows the notice" "$((jd_notices_before + 1))" jd_notices
  else
    fail "the other desktop window maps"
  fi
  close_toplevel "$jd_target_pid" "the target desktop window exits"
else
  fail "the target desktop window maps"
fi
expect "the daemon read Hyprland and never dispatched" none \
  python3 -c 'import sys; lines=open(sys.argv[1]).read().splitlines(); bad=[l for l in lines if not l.startswith("--batch j/")]; print("none" if lines and not bad else "lines=%d bad=%s" % (len(lines), bad[:3]))' \
  "$sandbox/jarvis-desktop-hyprctl.log"
expect "every routed call was proposed" none \
  python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1])]; bad=[r for r in rows if "route" in r and r["route"] != "proposed"]; print("none" if not bad else bad[:3])' \
  "$jd_driver/results.jsonl"

jarvis_disable
rm -- "$jd_standin" "$jd_entry" "$shim/hyprctl.jarvis-noop" "$jd_dir/backend/desktop-driver-fixture.js" "$jd_dir/backend/scripted-fixture.js"
cp -- "$sandbox/jarvis-desktop-backend-before" "$jd_backend"
rm -f -- "$home/.local/state/vgs/jarvis/mute.json"
[[ $jd_audit_before == true ]] || rm -rf -- "${jd_audit:?}"
jarvis_rescan
