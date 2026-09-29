# Measured on host cachy, AMD Ryzen 9 9950X, 2026-09-29. This row adds no
# latency budget. It reuses the smoke startup poll intervals in harness.sh:
# 10 ms for the first bar and one `vgsh ipc` round trip for readiness.
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
signal_shim="$sandbox/read-only-signal-shim"
signal_log="$sandbox/read-only-signal-calls.log"
read_only_prefix_prepare_tree "$readonly_dest/usr" "$repo" "$signal_shim"
chmod -R a-w -- "$readonly_dest/usr"

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

kill -TERM "$shell_pid" 2>/dev/null || true
for _ in $(seq 1 50); do
  kill -0 "$shell_pid" 2>/dev/null || break
  sleep 0.1
done
wait "$shell_pid" 2>/dev/null || true

installed_bin="$readonly_dest/usr/bin/vgsh"
installed_shell="$readonly_dest/usr/share/vgs/shell"
spawn "$sandbox/read-only-qs.log" "${shell_env[@]}" PATH="$signal_shim:$shim:$(dirname -- "$node_bin"):$PATH" VGS_READ_ONLY_SIGNAL_LOG="$signal_log" VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR="$shim" "$installed_bin" run
shell_pid="$spawn_pid"
ipc() {
  "${shell_env[@]}" "$installed_bin" ipc call "$@" 2>>"$sandbox/ipc.log" | tail -n 1
}

up=false
for _ in $(seq 1 $((timeout_s * 5))); do
  if pong="$(ipc shell ping 2>/dev/null)" && [[ $pong == ok ]]; then up=true; break; fi
  kill -0 "$shell_pid" 2>/dev/null || break
  sleep 0.2
done
if [[ $up == true ]]; then
  ok "the shell starts from a non-writable installed prefix"
else
  fail "installed shell did not answer ping within ${timeout_s}s"
  tail -n 40 "$sandbox/read-only-qs.log"
fi

installed_apply_vgs() {
  local err status=0
  err="$("${shell_env[@]}" PATH="$signal_shim:$shim:$(dirname -- "$node_bin"):$PATH" VGS_READ_ONLY_SIGNAL_LOG="$signal_log" "$installed_bin" theme apply vgs 2>&1 >/dev/null)" || status=$?
  if [[ $status == 0 ]]; then echo ok; else printf 'exit=%s %s\n' "$status" "${err%%$'\n'*}"; fi
}
# The first scan queues the theme follow, which holds the theme lock while
# it runs, and ping answers before that scan ends. An apply started under
# the follow is refused busy, the product's answer, so the row waits for
# the installed shell to go idle and never retries the apply.
# Controls for the wait's two reads, against stand-in shell replies: a
# shell that answers before its first scan ends holds no job yet and is
# not idle, and a follow queued at the scan's end keeps it busy.
stand_in_scanned="" stand_in_jobs=""
stand_in_shell() { # the IPC replies of a shell in the stand-in state
  case "$1 $2" in
    "shell listPlugins") printf '{"scanned": %s}\n' "$stand_in_scanned" ;;
    "shell lent") printf '{"theme": {"jobs": %s}}\n' "$stand_in_jobs" ;;
    *) return 1 ;;
  esac
}
# LABEL | scanned | jobs | theme_state's answer
wait_rows=(
  "a shell whose first scan runs|false|[]|scan=pending"
  "a shell whose follow runs|true|[{\"verb\": \"follow\", \"name\": null, \"started\": true, \"waiters\": 0}]|[[\"follow\", null, 0]]"
  "a shell with its scan ended and no job|true|[]|idle"
)
for row in "${wait_rows[@]}"; do
  IFS='|' read -r label stand_in_scanned stand_in_jobs want <<<"$row"
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

shell_qs_pid="$shell_pid"
if child="$(pgrep -P "$shell_pid" -x qs)"; then shell_qs_pid="$child"; fi
instance_log=""
for _ in $(seq 1 50); do
  if instance_id="$("${shell_env[@]}" qs list -p "$installed_shell" -j 2>/dev/null | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin) if i["pid"]==int(sys.argv[1])][0]["id"])' "$shell_qs_pid" 2>/dev/null)"; then
    instance_log="$rt_dir/quickshell/by-id/$instance_id/log.log"
    break
  fi
  sleep 0.2
done
read_only_prefix_check_installed_log "$instance_log"
