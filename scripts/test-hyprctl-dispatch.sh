#!/usr/bin/env bash
# Drive bin/vshell-hyprctl-dispatch against a stub hyprctl that
# answers a chosen reply and exit status. Only the exact reply "ok" with exit 0 is an
# applied dispatch; every other row must exit 1 and print the refusal key with
# hyprctl's exit status. A refusal Hyprland answers with exit 0 is how a classic-config
# session answers a Lua request, and exit 7 is how a Lua session answers an erroring one.
# Every run gets an explicit environment.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
program="$repo_root/bin/vshell-hyprctl-dispatch"

fail() {
  printf 'test-hyprctl-dispatch: FAIL: %s\n' "$*" >&2
  exit 1
}

tmp="$(mktemp -d)" || fail "could not create a temporary directory"
trap 'rm -rf -- "${tmp:?}"' EXIT
mkdir "$tmp/stubs"
cat >"$tmp/stubs/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_ARGV"
printf '%s\n' "$STUB_REPLY"
exit "$STUB_EXIT"
EOF
chmod +x "$tmp/stubs/hyprctl"

request='hl.dsp.focus({monitor="DP-1"})'

# reply | hyprctl exit | expected exit | expected first stderr line ("" for none)
rows=(
  'ok|0|0|'
  'Invalid dispatcher|0|1|hyprctl-dispatch-refused exit=0'
  "error: attempt to call a nil value (field 'vgsprobe')|7|1|hyprctl-dispatch-refused exit=7"
  'ok|7|1|hyprctl-dispatch-refused exit=7'
  '|0|1|hyprctl-dispatch-refused exit=0'
)

for row in "${rows[@]}"; do
  IFS='|' read -r reply exit_status want_return want_key <<<"$row"
  got_return=0
  env -i PATH="$tmp/stubs:/usr/bin:/bin" STUB_ARGV="$tmp/argv" STUB_REPLY="$reply" STUB_EXIT="$exit_status" \
    "$program" "$request" \
    >"$tmp/stdout" 2>"$tmp/stderr" || got_return=$?
  [[ $got_return == "$want_return" ]] || fail "reply '$reply' exit $exit_status: exited $got_return, want $want_return"
  [[ ! -s $tmp/stdout ]] || fail "reply '$reply' exit $exit_status: wrote to stdout"
  first_line=""
  IFS= read -r first_line <"$tmp/stderr" || true
  [[ $first_line == "$want_key" ]] || fail "reply '$reply' exit $exit_status: stderr starts '$first_line', want '$want_key'"
  [[ $(<"$tmp/argv") == "dispatch"$'\n'"$request" ]] || fail "reply '$reply' exit $exit_status: hyprctl argv was $(<"$tmp/argv")"
done

printf 'test-hyprctl-dispatch: ok (%d rows)\n' "${#rows[@]}"
