#!/usr/bin/env bash
# Control for scripts/qml-smoke.sh's `nested_unavailable` remedy gating
# (VGS-123, QA round).
#
# That function has six call sites and prints a fourth remedy — "point the
# sandbox at the session's own socket" — for exactly one of them. Gating it on
# WAYLAND_DISPLAY instead of on the cause offered that advice for a missing
# Hyprland binary, since a headless shell has WAYLAND_DISPLAY unset whichever
# precondition failed. The gate is now an explicit argument from the one call
# site that knows, and this is what pins it.
#
# The function is SLICED OUT and sourced rather than reached by running the real
# script: driving it through qml-smoke.sh would need a stubbed Hyprland, qs and
# python3 on PATH and would run the qmllint pass first. Extraction fails loudly
# if the function's shape changes, which is the only way this could go stale.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
smoke="$repo_root/scripts/qml-smoke.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

failures=0
case_failed=0
fail() {
  printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
  failures=$((failures + 1))
  case_failed=1
}
ok() {
  if [[ $case_failed -eq 0 ]]; then
    printf '  ok    %s\n' "$1"
  fi
  case_failed=0
}

awk '/^nested_unavailable\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' \
  "$smoke" >"$tmp/fn.sh"
if ! grep -q '^nested_unavailable() {$' "$tmp/fn.sh" || ! grep -q '^}$' "$tmp/fn.sh"; then
  echo "test-qml-smoke: could not slice nested_unavailable out of $smoke" >&2
  exit 1
fi

# Run the sliced function with the three things it reads from its script.
# WAYLAND is passed as the literal value to export, or `-` to unset it.
drive() {
  local wayland="$1"
  shift
  (
    set +e
    # shellcheck source=/dev/null
    . "$tmp/fn.sh"
    # These four are the environment the sliced function reads from its own
    # script. shellcheck cannot see the uses, because the only reader is the
    # sourced slice — that is the point of driving it this way.
    # shellcheck disable=SC2034  # read by the sliced nested_unavailable
    require_nested=false
    # shellcheck disable=SC2034  # written by the sliced function's fail()
    status=0
    # shellcheck disable=SC2317,SC2329  # called by the sliced function, not from here
    note() { printf 'qml-smoke: %s\n' "$*"; }
    # shellcheck disable=SC2317,SC2329  # called by the sliced function, not from here
    fail() { printf 'qml-smoke: FAIL: %s\n' "$*" >&2; }
    if [[ "$wayland" == - ]]; then
      unset WAYLAND_DISPLAY
    else
      export WAYLAND_DISPLAY="$wayland"
    fi
    nested_unavailable "$@"
  ) 2>&1
}

REMEDY="point the sandbox at the session's own socket"

# The defect: a headless shell hits the Hyprland precondition first, with
# WAYLAND_DISPLAY equally unset. Pointing at "the session socket" cannot fix a
# missing binary.
out="$(drive - "Hyprland not installed")"
if [[ "$out" == *"$REMEDY"* ]]; then
  fail "non-WAYLAND reason" "printed the socket remedy for a missing Hyprland:
$out"
fi
ok "a non-host-socket reason does not print the socket remedy"

# ...and the one call site that IS the WAYLAND case still gets it.
out="$(drive - "no host Wayland socket to nest inside (WAYLAND_DISPLAY unset)" no-host-socket)"
if [[ "$out" != *"$REMEDY"* ]]; then
  fail "host-socket reason" "did not print the socket remedy:
$out"
fi
ok "the host-socket cause prints the socket remedy"

# The secondary guard: with a display already set, "point at the session socket"
# is not the advice the reader needs.
out="$(drive wayland-1 "no host Wayland socket to nest inside (WAYLAND_DISPLAY unset)" no-host-socket)"
if [[ "$out" == *"$REMEDY"* ]]; then
  fail "WAYLAND set" "printed the socket remedy with WAYLAND_DISPLAY already set:
$out"
fi
ok "the remedy stays out when WAYLAND_DISPLAY is already set"

# Every reason still gets the three unconditional options, so the gating above
# cannot have been achieved by suppressing the whole block.
for reason in "Hyprland not installed" "nested compositor did not come up"; do
  out="$(drive - "$reason")"
  for needed in "install a nested compositor" "spare TTY/VM session" "vshell logs -n 200" \
    "never run 'qs -c vshell'"; do
    [[ "$out" == *"$needed"* ]] || fail "unconditional options" "missing '$needed' for reason: $reason"
  done
done
ok "the three unconditional options and the prohibition always print"

# The wiring itself: the flag has to be PASSED, or the gate above is dead and
# the remedy never reaches the one caller that needs it.
# Matched as a CALL, not as a bare mention: the token also appears in the
# function's own test and in its usage comment, so counting occurrences let the
# call site be deleted with the count still satisfied.
if ! grep -qE 'nested_unavailable "[^"]*" +no-host-socket' "$smoke"; then
  fail "call-site wiring" "no call site passes no-host-socket to nested_unavailable, so the gate is dead and the remedy reaches nobody"
fi
ok "the host-socket call site passes the cause explicitly"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-qml-smoke: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-qml-smoke: all checks passed"
