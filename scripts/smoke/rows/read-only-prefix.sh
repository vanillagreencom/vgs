# Measured on host cachy, AMD Ryzen 9 9950X, 2026-09-29. This row adds no
# latency budget. It reuses the smoke startup poll intervals in harness.sh:
# 10 ms for the first bar and one `vgsh ipc` round trip for readiness.
set -euo pipefail

readonly_dest="$sandbox/read-only-prefix"
DESTDIR="$readonly_dest" PREFIX=/usr "$source_repo/packaging/install-system.sh" >/dev/null
expect "the read-only prefix install matches the manifest" "install-tree=ok root=$readonly_dest/usr manifest=$source_repo/packaging/install-tree.manifest" "$source_repo/scripts/check-install-tree.sh" "$readonly_dest" /usr
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
spawn "$sandbox/read-only-qs.log" "${shell_env[@]}" PATH="$shim:$(dirname -- "$node_bin"):$PATH" VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR="$shim" "$installed_bin" run
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
  "${shell_env[@]}" "$installed_bin" theme apply vgs >/dev/null || return 1
  printf 'ok\n'
}
expect "theme apply runs from the non-writable installed prefix" ok installed_apply_vgs
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
for _ in $(seq 1 50); do
  if instance_id="$("${shell_env[@]}" qs list -p "$installed_shell" -j 2>/dev/null | python3 -c 'import json,sys; print([i for i in json.load(sys.stdin) if i["pid"]==int(sys.argv[1])][0]["id"])' "$shell_qs_pid" 2>/dev/null)"; then
    instance_log="$rt_dir/quickshell/by-id/$instance_id/log.log"
    break
  fi
  sleep 0.2
done
