#!/usr/bin/env bash
# Drive `bin/vshell-screensaver launch` on a stub Hyprland session with two monitors
# and no saver windows. A refused focus move is best-effort and the launch still
# exits 0; a refused exec_cmd leaves a monitor without a saver, so the launch exits
# nonzero and names the refusal count. ScreensaverService clears its active state
# only on that nonzero exit. Every run gets an explicit environment.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script_under_test="$repo_root/bin/vshell-screensaver"

fail() {
  printf 'test-screensaver-launch: FAIL: %s\n' "$*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || fail "required tool jq is not installed"
tmp="$(mktemp -d)" || fail "could not create a temporary directory"
trap 'rm -rf -- "${tmp:?}"' EXIT
mkdir "$tmp/stubs"
for tool in tte ghostty; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/stubs/$tool"
done
# Answers the two queries cmd_launch reads, and a dispatch with STUB_FOCUS_REPLY or
# STUB_EXEC_REPLY by the request's kind.
cat >"$tmp/stubs/hyprctl" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "monitors -j") printf '[{"name":"DP-1","focused":true,"disabled":false},{"name":"DP-2","focused":false,"disabled":false}]\n' ;;
  "clients -j") printf '[]\n' ;;
  dispatch\ hl.dsp.focus*) printf '%s\n' "$STUB_FOCUS_REPLY" ;;
  dispatch\ hl.dsp.exec_cmd*) printf '%s\n' "$STUB_EXEC_REPLY" ;;
  *) printf 'stub hyprctl: unexpected call: %s\n' "$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/stubs"/*

# name | focus reply | exec_cmd reply | expected exit | expected last stderr line ("" for none)
rows=(
  'applied|ok|ok|0|'
  'focus refused|Invalid dispatcher|ok|0|'
  'exec refused|ok|Invalid dispatcher|1|screensaver-launch-refused count=2'
)

for row in "${rows[@]}"; do
  IFS='|' read -r name focus_reply exec_reply want_exit want_last <<<"$row"
  mkdir -p "$tmp/$name/home"
  got_exit=0
  env -i HOME="$tmp/$name/home" PATH="$tmp/stubs:/usr/bin:/bin" VSHELL_NO_APP_SCOPE=1 \
    STUB_FOCUS_REPLY="$focus_reply" STUB_EXEC_REPLY="$exec_reply" \
    "$script_under_test" launch >/dev/null 2>"$tmp/stderr" || got_exit=$?
  [[ $got_exit == "$want_exit" ]] || fail "$name: exited $got_exit, want $want_exit; stderr: $(<"$tmp/stderr")"
  last_line=""
  while IFS= read -r line; do
    last_line="$line"
  done <"$tmp/stderr"
  if [[ -n $want_last ]]; then
    [[ $last_line == "$want_last" ]] || fail "$name: stderr ends '$last_line', want '$want_last'"
  else
    [[ $last_line != screensaver-launch-refused* ]] || fail "$name: reported '$last_line'"
  fi
done

printf 'test-screensaver-launch: ok (%d rows)\n' "${#rows[@]}"
