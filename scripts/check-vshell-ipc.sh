#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
log="$tmp/qs.log"

cat >"$tmp/bin/qs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_QS_LOG"

case "$FAKE_QS_MODE:$*" in
  path-success:"ipc -p "*" --any-display call blackout status")
    printf 'off\n'
    ;;
  config-success:"ipc -c vshell --any-display call blackout status")
    printf 'off\n'
    ;;
  pid-success:"ipc --pid 202 call blackout status")
    printf 'off\n'
    ;;
  *)
    printf 'no matching instance\n' >&2
    exit 1
    ;;
esac
EOF
chmod +x "$tmp/bin/qs"

run_ipc() {
  PATH="$tmp/bin:$PATH" \
    FAKE_QS_LOG="$log" \
    FAKE_QS_MODE="$1" \
    VSHELL_PROC_ROOT="${2:-$tmp/empty-proc}" \
    "$repo_root/bin/vshell" ipc call blackout status
}

mkdir -p "$tmp/empty-proc"

: >"$log"
test "$(run_ipc path-success)" = "off"
expected_path="ipc -p $repo_root/quickshell/vshell --any-display call blackout status"
test "$(cat "$log")" = "$expected_path"

: >"$log"
test "$(run_ipc config-success)" = "off"
mapfile -t calls <"$log"
test "${#calls[@]}" -eq 2
test "${calls[0]}" = "$expected_path"
test "${calls[1]}" = "ipc -c vshell --any-display call blackout status"

proc_root="$tmp/proc"
mkdir -p "$proc_root/101" "$proc_root/202"
ln -s /usr/bin/quickshell "$proc_root/101/exe"
ln -s /usr/bin/quickshell "$proc_root/202/exe"
printf 'qs\0-p\0%s\0' "$tmp/unrelated-quickshell" >"$proc_root/101/cmdline"
printf 'qs\0-p\0%s\0' "$repo_root/quickshell/vshell" >"$proc_root/202/cmdline"

: >"$log"
test "$(run_ipc pid-success "$proc_root")" = "off"
mapfile -t calls <"$log"
test "${#calls[@]}" -eq 3
test "${calls[0]}" = "$expected_path"
test "${calls[1]}" = "ipc -c vshell --any-display call blackout status"
test "${calls[2]}" = "ipc --pid 202 call blackout status"
if grep -q -- '--pid 101' "$log"; then
  echo "selected an unrelated Quickshell process" >&2
  exit 1
fi

echo "vshell IPC selector checks passed"
