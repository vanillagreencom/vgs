# No latency budget. TUI actions run the nested allow-listed fixture only.
set -euo pipefail
input_tui="$repo/shell/plugins/vgs.jarvis/tui/setup-input.sh"
cp -- "$input_tui" "$sandbox/input-tui-original"
cp -- "$source_repo/scripts/smoke/fixtures/tui/vgs.jarvis/tui/setup-input.sh" "$input_tui"
terminal_stand_in
terminal_ready "Jarvis input check"
jarvis_rescan
jarvis_enable
settings_page_open vgs.jarvis
input_open() {
  local revision snapshot
  revision="$(jarvis_revision)" || return 1
  snapshot="$rt_dir/vgsh-sources-$shell_qs_pid/$revision"
  forget_record
  if [[ $1 == status ]]; then
    expect "Settings opens the input readiness terminal" ok settings_act vgs.jarvis input
  else
    expect "the launcher opens the input readiness terminal" ok ipc shell openTui vgs.jarvis/setup-input
  fi
  expect_poll "input setup receives only the declared snapshot and argv" \
    "$(words --app-id=org.vgs.tui "--title=VGS · Check Jarvis input" -- "$tui_self" present --presentation full \
      --plugin vgs.jarvis --dir "$snapshot" --record vgs.jarvis/setup-input --run RUN --record-dir "$rt_dir/vgs/tui" \
      --app-id org.vgs.tui --window-title "VGS · Check Jarvis input" -- tui/setup-input.sh)" recorded
  expect_run_end "the input readiness fixture ends" vgs.jarvis/setup-input
}
input_action() { status_row vgs.jarvis input | py_reply 'import json,sys; print("offered" if json.load(sys.stdin)["action"]["offered"] else "pending")'; }
expect_poll "the input readiness action is offered" offered input_action
input_open status
input_open launcher
cp -- "$sandbox/input-tui-original" "$input_tui"
jarvis_rescan
settings_page_close vgs.jarvis
jarvis_disable
