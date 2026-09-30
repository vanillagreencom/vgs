# Measured on host cachy, AMD Ryzen 9 9950X, 2026-09-29. This row adds no
# latency budget. It starts the installed shell through harness.sh's
# start_shell, with the process-signalling stand-ins first on its PATH,
# so it reuses the smoke startup poll intervals: 10 ms for the first bar
# and one `vgsh ipc` round trip for readiness.
set -euo pipefail

read_only_prefix_signal_path() { # DIR
  local tool
  mkdir -p -- "$1"
  for tool in pkill killall kill pgrep; do
    cat >"$1/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >>"${VGS_READ_ONLY_SIGNAL_LOG:?}"
exit 0
SH
    chmod 755 "$1/$tool"
  done
}

read_only_prefix_prepare_tree() { # INSTALLED_PREFIX SANDBOX_TREE SIGNAL_DIR
  local installed_targets="$1/share/vgs/themes/targets"
  rm -rf -- "$installed_targets"
  mkdir -p -- "$installed_targets"
  if [[ -d $2/themes/targets ]]; then
    cp -R -- "$2/themes/targets/." "$installed_targets/"
  fi
  read_only_prefix_signal_path "$3"
}

read_only_prefix_signal_calls() { # LOG
  [[ -s $1 ]] && cat -- "$1"
  return 0
}

read_only_prefix_check_installed_log() { # LOG
  local log="$1"
  if [[ -n $log && -r $log ]]; then
    check_unexpected_log "installed shell log" "$log"
  else
    fail "installed shell log not found for pid $shell_qs_pid"
  fi
}

if [[ ${READ_ONLY_PREFIX_SOURCE_ONLY:-false} == true ]]; then
  return 0
fi

readonly_dest="$sandbox/read-only-prefix"
DESTDIR="$readonly_dest" PREFIX=/usr "$source_repo/packaging/install-system.sh" >/dev/null
expect "the read-only prefix install matches the manifest" "install-tree=ok root=$readonly_dest/usr manifest=$source_repo/packaging/install-tree.manifest" "$source_repo/scripts/check-install-tree.sh" "$readonly_dest" /usr
tree_smoke_observer "$source_repo" "$readonly_dest/usr/share/vgs"
signal_shim="$sandbox/read-only-signal-shim"
signal_log="$sandbox/read-only-signal-calls.log"
read_only_prefix_prepare_tree "$readonly_dest/usr" "$repo" "$signal_shim"
"$node_bin" "$source_repo/scripts/fixtures/jarvis/prepare.js" "$source_repo" "$readonly_dest/usr/share/vgs" "$sandbox/jarvis-installed-world"
chmod -R a-w -- "$readonly_dest/usr"
expect "voice APIs work from the non-writable installed prefix" "jarvis-voice-installed=ok" env -i PATH=/usr/bin:/bin "$node_bin" "$source_repo/scripts/fixtures/jarvis-voice/installed.js" "$readonly_dest/usr/share/vgs"
expect "local setup reads its inputs from the non-writable installed prefix" "jarvis-setup-installed=ok" \
  env -i PATH=/usr/bin:/bin "$source_repo/scripts/lib/jarvis-env.sh" "$sandbox/jarvis-installed-world/standins" -- \
  python3 "$source_repo/scripts/fixtures/jarvis-setup/installed.py" "$readonly_dest/usr/share/vgs"

tree_snapshot() { # ROOT
  python3 - "$1" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
rows = []
for current, dirs, files in os.walk(root, followlinks=False):
    dirs[:] = sorted(dirs)
    for name in sorted(files):
        path = pathlib.Path(current) / name
        rel = path.relative_to(root).as_posix()
        mode = stat.S_IMODE(path.lstat().st_mode)
        if path.is_symlink():
            rows.append(f"l {mode:o} {rel} -> {os.readlink(path)}")
        elif path.is_file():
            rows.append(f"f {mode:o} {rel} {hashlib.sha256(path.read_bytes()).hexdigest()}")
        else:
            rows.append(f"special {mode:o} {rel}")
for row in sorted(rows):
    print(row)
PY
}

tree_snapshot "$readonly_dest/usr" >"$sandbox/read-only-before.txt"

installed_bin="$readonly_dest/usr/bin/vgsh"
ipc() { ipc_via "$installed_bin" "$@"; }
if stop_shell && start_shell "$readonly_dest/usr" "$sandbox/read-only-qs.log" bar PATH="$signal_shim:$shell_start_path" VGS_READ_ONLY_SIGNAL_LOG="$signal_log"; then
  ok "the shell starts from a non-writable installed prefix"
fi
expect "Jarvis enables from the non-writable installed prefix" ok ipc shell setPluginEnabled vgs.jarvis true
expect "Jarvis answers hello without retries from the non-writable installed prefix" ready jarvis_wait_ready 0
expect "task events use a private data engine from the read-only prefix" "task-prefix=ok" "$node_bin" "$source_repo/scripts/test-task-event.js" --prefix "$readonly_dest/usr/share/vgs/shell/plugins/vgs.jarvis/backend"
expect_poll "installed Jarvis discovers device choices without writing the prefix" devices jarvis_devices

installed_apply_vgs() {
  local err status=0
  err="$("${shell_env[@]}" PATH="$signal_shim:$shell_start_path" VGS_READ_ONLY_SIGNAL_LOG="$signal_log" "$installed_bin" theme apply vgs 2>&1 >/dev/null)" || status=$?
  if [[ $status == 0 ]]; then echo ok; else printf 'exit=%s %s\n' "$status" "${err%%$'\n'*}"; fi
}
# The first scan queues the theme follow, which holds the theme lock while
# it runs, and ping answers before that scan ends. An apply started under
# the follow is refused busy, the product's answer, so the row waits for
# the installed shell to go idle and never retries the apply.
# Controls for the wait's reads, against stand-in shell replies: a shell
# that answers before its first scan ends holds no job yet and is not
# idle, and a follow queued at the scan's end or a running download keeps
# it busy.
stand_in_scanned="" stand_in_jobs="" stand_in_download=""
stand_in_shell() { # the IPC replies of a shell in the stand-in state
  case "$1 $2" in
    "shell listPlugins") printf '{"scanned": %s}\n' "$stand_in_scanned" ;;
    "shell lent") printf '{"theme": {"jobs": %s, "download": %s}}\n' "$stand_in_jobs" "$stand_in_download" ;;
    *) return 1 ;;
  esac
}
# LABEL | scanned | jobs | download | theme_state's answer
wait_rows=(
  "a shell whose first scan runs|false|[]|null|scan=pending"
  "a shell whose follow runs|true|[{\"verb\": \"follow\", \"name\": null, \"started\": true, \"waiters\": 0}]|null|[[\"follow\", null, 0]]"
  "a shell whose download runs|true|[]|{\"verb\": \"wallpapers\", \"name\": \"nord\", \"started\": true, \"waiters\": 1}|[[\"wallpapers\", \"nord\", 1]]"
  "a shell with its scan ended and no job|true|[]|null|idle"
)
for row in "${wait_rows[@]}"; do
  IFS='|' read -r label stand_in_scanned stand_in_jobs stand_in_download want <<<"$row"
  expect "the wait reads $label" "$want" theme_state stand_in_shell
done
expect "the installed shell's startup follow ends" idle theme_idle
# Control: the apply with no wait, under the lock a stand-in holds as the
# follow does, is refused busy, and the row's apply check fails on it.
exec {startup_lock}>>"$home/.config/vgs/theme.lock"
if flock -n "$startup_lock"; then
  expect "an apply under the held theme lock is refused busy" "exit=75 vgsh: refused: theme=vgs reason=busy" installed_apply_vgs
else
  fail "the stand-in could not take the theme lock once the installed shell was idle"
fi
exec {startup_lock}>&-
expect "theme apply runs from the non-writable installed prefix" ok installed_apply_vgs
expect "the installed Gallery summons from the read-only prefix" ok ipc shell summon window vgs.gallery '{}'
expect_poll "the installed Gallery maps" 1 window_count Gallery
expect_poll "the installed Gallery builds the VoiceOrb examples" True orb_examples_ok
gallery_draw_orbs "the read-only installed VoiceOrb pack"
expect "the installed Gallery hides" ok ipc shell hide window vgs.gallery
expect_poll "the installed Gallery is gone" 0 window_count Gallery
if calls="$(read_only_prefix_signal_calls "$signal_log")" && [[ -z $calls ]]; then
  ok "the installed prefix row called no process-signalling command"
else
  fail "the installed prefix row called a process-signalling command:"
  printf '%s\n' "$calls"
fi
tree_snapshot "$readonly_dest/usr" >"$sandbox/read-only-after.txt"
if cmp -s -- "$sandbox/read-only-before.txt" "$sandbox/read-only-after.txt"; then
  ok "startup and theme apply leave the installed tree unchanged"
else
  diff_status=0
  fail "the installed tree changed under startup or theme apply"
  diff -u -- "$sandbox/read-only-before.txt" "$sandbox/read-only-after.txt" >"$sandbox/read-only.diff" || diff_status=$?
  case "$diff_status" in
    0|1) cat -- "$sandbox/read-only.diff" ;;
    *) fail "the read-only prefix diff could not be read: status=$diff_status" ;;
  esac
fi
chmod -R u+w -- "$readonly_dest/usr"
read_only_prefix_check_installed_log "$instance_log"
