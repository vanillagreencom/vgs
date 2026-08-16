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

# ---------------------------------------------------------------------------
# sandbox_layer_state: the output size is never inferred as 0x0 (VGS-133 review)
#
# The defect: `others` (every layer on the monitor EXCEPT the one under test) is
# empty when the popout is the only thing mapped on that output, so screen_w and
# screen_h fell back to 0. The degenerate test `w >= screen_w and h >= screen_h`
# is vacuously true against 0x0, so it was guarded off with `screen_w > 0 and
# screen_h > 0` - disabling the check in exactly the case it could not evaluate
# and handing the caller "0x0" to compare heights against. The status is now 4.
#
# Sliced and driven with a stubbed `sandbox_layers`, the same discipline as
# nested_unavailable above: reaching it through the real script would need a
# nested Hyprland.
awk '/^sandbox_layer_state\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' \
  "$smoke" >"$tmp/layerfn.sh"
if ! grep -q '^sandbox_layer_state() {$' "$tmp/layerfn.sh" || ! grep -q '^}$' "$tmp/layerfn.sh"; then
  echo "test-qml-smoke: could not slice sandbox_layer_state out of $smoke" >&2
  exit 1
fi

# Prints the status on the first line, then the function's stdout.
layer_state() {
  local json="$1" ns="$2"
  (
    set +e
    export LAYERS_FIXTURE="$json"
    # shellcheck source=/dev/null
    . "$tmp/layerfn.sh"
    # shellcheck disable=SC2317,SC2329  # called by the sliced function, not from here
    sandbox_layers() { printf '%s' "$LAYERS_FIXTURE"; }
    out="$(sandbox_layer_state "$ns" 2>/dev/null)"
    printf '%s\n%s\n' "$?" "$out"
  )
}

NS="vshell:plugins:aiUsage"
# The wallpaper is what actually establishes the output size: it is the only
# always-present layer that spans the whole output. The bar is full WIDTH but
# 40px tall, so a fixture carrying the bar alone would put screen_h at 40 - a
# reminder that this heuristic reads the largest other surface, not the mode.
WALLPAPER='{"namespace":"vshell:blurwallpaper","w":1756,"h":933}'
BAR='{"namespace":"vshell:bar","w":1756,"h":40}'
POPOUT='{"namespace":"'"$NS"'","w":444,"h":933}'
mon() { printf '{"levels":{"2":[%s]}}' "$1"; }

# THE MUST-FAIL CONTROL. Before the fix this returned 0 and printed
# "444x933 0x0" - a healthy verdict reached by measuring against nothing.
out="$(layer_state "{\"MON1\":$(mon "$POPOUT")}" "$NS")"
if [[ "$(head -n1 <<<"$out")" != 4 ]]; then
  fail "lone surface" "a popout that is the only layer on its output must be status 4 (output size indeterminate), got:
$out"
fi
if [[ "$out" == *"0x0"* ]]; then
  fail "lone surface" "reported a 0x0 output size instead of refusing to measure:
$out"
fi
ok "a surface with nothing else on its output is refused, not measured against 0x0"

# The control that proves the refusal above is not just "always fails".
out="$(layer_state "{\"MON1\":$(mon "$WALLPAPER,$BAR,$POPOUT")}" "$NS")"
[[ "$(head -n1 <<<"$out")" == 0 ]] || fail "normal case" "a normal bar+popout output should be status 0, got:
$out"
[[ "$out" == *"444x933 1756x933"* ]] || fail "normal case" "wrong geometry line:
$out"
ok "a normal output still measures and passes"

# The degenerate test still fires, and now WITHOUT the > 0 guard that disabled it.
FULL='{"namespace":"'"$NS"'","w":1756,"h":933}'
WALL='{"namespace":"vshell:blurwallpaper","w":1756,"h":933}'
out="$(layer_state "{\"MON1\":$(mon "$WALL,$FULL")}" "$NS")"
[[ "$(head -n1 <<<"$out")" == 2 ]] || fail "degenerate" "a full-screen popout should be status 2, got:
$out"
ok "a popout as large as its output is still degenerate"

# Absent stays 1, so the new status did not swallow the absence case.
out="$(layer_state "{\"MON1\":$(mon "$WALLPAPER,$BAR")}" "$NS")"
[[ "$(head -n1 <<<"$out")" == 1 ]] || fail "absent" "an unmapped namespace should be status 1, got:
$out"
ok "an absent surface is still reported absent"

# The emitter's documented contract: one line per mapped surface per monitor.
# This is what assert_popout_geometry below has to consume.
out="$(layer_state "{\"MON1\":$(mon "$WALLPAPER,$BAR,$POPOUT"),\"MON2\":$(mon "$WALLPAPER,$BAR,$POPOUT")}" "$NS")"
[[ "$(head -n1 <<<"$out")" == 0 ]] || fail "multi-monitor" "two healthy outputs should be status 0, got:
$out"
[[ "$(tail -n +2 <<<"$out" | grep -c .)" == 2 ]] || fail "multi-monitor" "expected one geometry line per monitor, got:
$out"
ok "a popout mapped on two outputs emits one line per output"

# ---------------------------------------------------------------------------
# assert_popout_geometry: every emitted line is checked, none is skipped
#
# popout_check used to hard-reject any multi-line reply, contradicting the
# emitter's own contract. It now checks each line against the output THAT line
# names.
awk '/^assert_popout_geometry\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' \
  "$smoke" >"$tmp/geomfn.sh"
if ! grep -q '^assert_popout_geometry() {$' "$tmp/geomfn.sh" || ! grep -q '^}$' "$tmp/geomfn.sh"; then
  echo "test-qml-smoke: could not slice assert_popout_geometry out of $smoke" >&2
  exit 1
fi

geom() {
  (
    set +e
    # shellcheck source=/dev/null
    . "$tmp/geomfn.sh"
    # shellcheck disable=SC2317,SC2329  # called by the sliced function, not from here
    fail() { printf 'FAILMSG: %s\n' "$*"; }
    assert_popout_geometry "$1" aiUsage
    printf 'rc=%s\n' "$?"
  ) 2>&1
}

out="$(geom '444x933 1756x933')"
[[ "$out" == *"rc=0"* ]] || fail "single line" "a valid single line should pass, got: $out"
ok "a single valid line passes"

out="$(geom '444x933 1756x933
444x1080 1920x1080')"
[[ "$out" == *"rc=0"* ]] || fail "multi-monitor accepted" "two valid lines should pass rather than be rejected as unparseable, got: $out"
ok "two valid lines pass instead of being rejected for being multi-line"

# THE MUST-FAIL CONTROL for the loop: the SECOND output violates the invariant.
# A consumer that checked only the first line, or that split the whole blob,
# would pass this.
out="$(geom '444x933 1756x933
444x206 1920x1080')"
[[ "$out" == *"rc=1"* ]] || fail "second line violation" "a violation on the second output must fail, got: $out"
[[ "$out" == *"444x206"* ]] || fail "second line violation" "the diagnostic must name the offending surface, got: $out"
ok "a violation on the second output is caught, so no line is skipped"

out="$(geom '')"
[[ "$out" == *"rc=1"* ]] || fail "empty" "an empty reply must fail rather than pass on no evidence, got: $out"
ok "an empty reply refuses to pass on no evidence"

out="$(geom '444x933')"
[[ "$out" == *"rc=1"* ]] || fail "single field" "a single field must fail rather than compare equal to itself, got: $out"
ok "a single field cannot pass by comparing equal to itself"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-qml-smoke: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-qml-smoke: all checks passed"
