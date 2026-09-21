#!/usr/bin/env bash
# Controls for bin/vgsh against a stub qs on PATH. Each row pins a reply,
# an exit status or a keyed refusal the header promises. No shell starts.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp:?}"' EXIT

# The stub answers `qs ipc ... call <target> <fn> ...` from STUB_REPLY and
# STUB_STATUS, prints STUB_NOISE on stdout before the reply (as qs does with
# its log) and STUB_STDERR on stderr after it.
cat >"$tmp/qs" <<'EOF'
#!/usr/bin/env bash
[[ -n ${STUB_NOISE:-} ]] && printf '%s\n' "$STUB_NOISE"
printf '%s\n' "${STUB_REPLY:-ok}"
[[ -n ${STUB_STDERR:-} ]] && printf '%s\n' "$STUB_STDERR" >&2
exit "${STUB_STATUS:-0}"
EOF
chmod +x "$tmp/qs"
export PATH="$tmp:$PATH"

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# rows: name | env | args | want stdout (last line) | want exit
run_row() { # NAME ENVSTR ARGS WANT_OUT WANT_EXIT
  local name="$1" envstr="$2" args="$3" want_out="$4" want_exit="$5" out status
  set +e
  # shellcheck disable=SC2086
  out="$(env $envstr "$repo/bin/vgsh" $args 2>"$tmp/err")"
  status=$?
  set -e
  local last="${out##*$'\n'}"
  if [[ $status == "$want_exit" && $last == "$want_out" ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit last=[$last] want=[$want_out] stderr=$(head -n 1 "$tmp/err")"; fi
}

list_json='{"plugins":[{"id":"vgs.bar","version":"0.1.0","kinds":["bar"],"enabled":true,"dir":"/x"}],"errors":[],"collisions":[],"scanError":"","scanned":true}'

run_row "enable prints ok" "STUB_REPLY=ok" "plugin enable vgs.clock" "ok" 0
run_row "reply is the last stdout line, log noise ahead of it is ignored" "STUB_REPLY=ok STUB_NOISE=INFO:something" "plugin enable vgs.clock" "ok" 0
run_row "stderr after the reply does not become the reply" "STUB_REPLY=ok STUB_STDERR=WARN:late" "plugin enable vgs.clock" "ok" 0
run_row "an unexpected reply is a refusal" "STUB_REPLY=ok_hidden" "plugin disable vgs.bar" "" 1
run_row "unknown id is a refusal with exit 1" "STUB_REPLY=unknown:_x" "plugin enable x" "" 1
run_row "not-running exits 69 on enable" "STUB_STATUS=1 STUB_REPLY=none" "plugin enable vgs.clock" "" 69
run_row "not-running exits 69 on list" "STUB_STATUS=1 STUB_REPLY=none" "plugin list" "" 69
run_row "list formats one row per plugin" "STUB_REPLY=$list_json" "plugin list" "vgs.bar                      0.1.0    enabled   kinds=bar" 0
run_row "missing id is exit 2" "" "plugin enable" "" 2
run_row "unknown subcommand is exit 2" "" "plugin frobnicate" "" 2
run_row "unknown command is exit 2" "" "frobnicate" "" 2

# The hidden reply carries a space, which env cannot pass; call directly.
set +e
out="$(STUB_REPLY='ok hidden=vgs.clock,vgs.workspaces' "$repo/bin/vgsh" plugin disable vgs.bar 2>/dev/null)"
status=$?
set -e
[[ $status == 0 && $out == $'ok hidden=vgs.clock,vgs.workspaces\nthose bar widgets stay enabled and return when a bar is enabled' ]] && ok "disable prints the hidden widgets and the note" || fail "hidden reply: exit=$status out=[$out]"

# Help ends with the last header line, not a stray shell line.
help_last="$("$repo/bin/vgsh" --help 2>&1 | tail -n 1)"
[[ $help_last == *"69 when the shell is not running."* ]] && ok "help ends with the exit-code line" || fail "help last line: $help_last"

if [[ $failures -gt 0 ]]; then echo "test-vgsh: failed=$failures"; exit 1; fi
echo "test-vgsh: ok"
