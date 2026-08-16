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
# sandbox_layer_state: the output size is MEASURED, never inferred
#
# The defect was one, not three. Taking the largest OTHER layer on the monitor
# as a proxy for the output is wrong when there is no other layer (proxy 0x0,
# everything compared against zero), wrong when the other layers are all small
# (the bar is full WIDTH but ~32px tall, so the proxy is simply a wrong number),
# and wrong in principle either way because the verdict was reached against a
# figure the compositor never reported. The size now comes from
# `hyprctl monitors`: logical = mode / scale, axes swapped for the quarter-turn
# transforms.
#
# Sliced and driven with stubbed `sandbox_layers` / `sandbox_monitors`, the same
# discipline as nested_unavailable above: reaching it through the real script
# would need a nested Hyprland.
awk '/^sandbox_layer_state\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' \
  "$smoke" >"$tmp/layerfn.sh"
if ! grep -q '^sandbox_layer_state() {$' "$tmp/layerfn.sh" || ! grep -q '^}$' "$tmp/layerfn.sh"; then
  echo "test-qml-smoke: could not slice sandbox_layer_state out of $smoke" >&2
  exit 1
fi

# Prints the status on the first line, then the function's stdout.
layer_state() {
  local layers="$1" mons="$2" ns="$3"
  (
    set +e
    export LAYERS_FIXTURE="$layers" MONITORS_FIXTURE="$mons"
    # shellcheck source=/dev/null
    . "$tmp/layerfn.sh"
    # shellcheck disable=SC2317,SC2329  # called by the sliced function, not from here
    sandbox_layers() { printf '%s' "$LAYERS_FIXTURE"; }
    # shellcheck disable=SC2317,SC2329  # called by the sliced function, not from here
    sandbox_monitors() { printf '%s' "$MONITORS_FIXTURE"; }
    out="$(sandbox_layer_state "$ns" 2>/dev/null)"
    printf '%s\n%s\n' "$?" "$out"
  )
}

NS="vshell:plugins:aiUsage"
# Mode 1756x933 at scale 1: the output is 1756x933 logical.
MON1='[{"name":"MON1","width":1756,"height":933,"scale":1,"transform":0}]'
BAR='{"namespace":"vshell:bar","w":1756,"h":40}'
POPOUT='{"namespace":"'"$NS"'","w":444,"h":933}'
mon() { printf '{"levels":{"2":[%s]}}' "$1"; }

# MUST-FAIL CONTROL 1: the surface is the ONLY layer on its output. The proxy
# would have been 0x0; the measurement is unaffected by there being nothing else.
out="$(layer_state "{\"MON1\":$(mon "$POPOUT")}" "$MON1" "$NS")"
[[ "$(head -n1 <<<"$out")" == 0 ]] || fail "lone surface" "a lone popout must still be measured against its real output, got:
$out"
[[ "$out" == *"444x933 1756x933"* ]] || fail "lone surface" "wrong geometry - the output size was not measured:
$out"
[[ "$out" == *"0x0"* ]] && fail "lone surface" "fell back to a 0x0 output size:
$out"
ok "a surface alone on its output is measured, not compared against 0x0"

# MUST-FAIL CONTROL 2: the other layers are all SMALLER than the output. The
# proxy would have been the bar's 1756x40, so a correctly output-tall popout
# would have been reported as a height mismatch.
out="$(layer_state "{\"MON1\":$(mon "$BAR,$POPOUT")}" "$MON1" "$NS")"
[[ "$(head -n1 <<<"$out")" == 0 ]] || fail "small others" "a correct popout must not fail because the only other layer is bar-height, got:
$out"
[[ "$out" == *"444x933 1756x933"* ]] || fail "small others" "inferred the output from the bar instead of measuring it:
$out"
ok "a bar-only output does not make a correct popout look wrong"

# ...and the same shape must not SILENTLY ACCEPT a wrong one. Under the proxy
# the output read as 1756x40, so a 40px-tall popout matched it and passed.
SHORT='{"namespace":"'"$NS"'","w":444,"h":40}'
out="$(layer_state "{\"MON1\":$(mon "$BAR,$SHORT")}" "$MON1" "$NS")"
[[ "$out" == *"444x40 1756x933"* ]] || fail "small others accept" "a bar-height popout must be measured against the real 933-tall output, got:
$out"
ok "a bar-height popout is measured against the real output, not the bar"

# An unmeasurable output is a hard status, never a zero and never a guess.
out="$(layer_state "{\"MON1\":$(mon "$BAR,$POPOUT")}" '[]' "$NS")"
[[ "$(head -n1 <<<"$out")" == 4 ]] || fail "no monitor" "an output hyprctl does not report must be status 4, got:
$out"
[[ "$out" == *"0x0"* ]] && fail "no monitor" "fell back to a 0x0 output size:
$out"
ok "an output with no reported size is refused, not guessed at"

out="$(layer_state "{\"MON1\":$(mon "$BAR,$POPOUT")}" '[{"name":"MON1","width":1756,"height":933,"scale":0,"transform":0}]' "$NS")"
[[ "$(head -n1 <<<"$out")" == 4 ]] || fail "bad scale" "a monitor whose numbers do not convert must be status 4, got:
$out"
ok "a monitor whose numbers do not convert is refused, not entered as zero"

# The conversion itself: physical mode -> logical, with the quarter-turn swap.
# These are the two real monitors this was verified against.
ROT='[{"name":"MON1","width":5120,"height":2880,"scale":2,"transform":1}]'
TALL='{"namespace":"'"$NS"'","w":444,"h":2560}'
out="$(layer_state "{\"MON1\":$(mon "$TALL")}" "$ROT" "$NS")"
[[ "$out" == *"444x2560 1440x2560"* ]] || fail "transform" "5120x2880 @ scale 2, transform 1 must read as 1440x2560, got:
$out"
ok "the mode is converted to logical size, including the quarter-turn swap"

SCALED='[{"name":"MON1","width":6016,"height":3384,"scale":2,"transform":0}]'
BIG='{"namespace":"'"$NS"'","w":444,"h":1692}'
out="$(layer_state "{\"MON1\":$(mon "$BIG")}" "$SCALED" "$NS")"
[[ "$out" == *"444x1692 3008x1692"* ]] || fail "scale" "6016x3384 @ scale 2 must read as 3008x1692, got:
$out"
ok "a scaled output is divided by its scale"

# The degenerate test still fires, now against a measured output.
FULL='{"namespace":"'"$NS"'","w":1756,"h":933}'
out="$(layer_state "{\"MON1\":$(mon "$BAR,$FULL")}" "$MON1" "$NS")"
[[ "$(head -n1 <<<"$out")" == 2 ]] || fail "degenerate" "a popout as large as its output should be status 2, got:
$out"
ok "a popout as large as its measured output is still degenerate"

out="$(layer_state "{\"MON1\":$(mon "$BAR")}" "$MON1" "$NS")"
[[ "$(head -n1 <<<"$out")" == 1 ]] || fail "absent" "an unmapped namespace should be status 1, got:
$out"
ok "an absent surface is still reported absent"

# The emitter's one-line contract: a popout binds to exactly one screen, so a
# second mapping is a defect rather than a second line.
MON2='[{"name":"MON1","width":1756,"height":933,"scale":1,"transform":0},{"name":"MON2","width":1756,"height":933,"scale":1,"transform":0}]'
out="$(layer_state "{\"MON1\":$(mon "$BAR,$POPOUT"),\"MON2\":$(mon "$BAR,$POPOUT")}" "$MON2" "$NS")"
[[ "$(head -n1 <<<"$out")" == 5 ]] || fail "duplicate mapping" "a popout mapped on two outputs must be status 5, got:
$out"
ok "a popout mapped twice is a reported defect, not two lines"

out="$(layer_state "{\"MON1\":$(mon "$BAR,$POPOUT")}" "$MON1" "$NS")"
[[ "$(tail -n +2 <<<"$out" | grep -c .)" == 1 ]] || fail "one line" "the emitter must produce exactly one line, got:
$out"
ok "the emitter produces exactly one line"

# ---------------------------------------------------------------------------
# assert_popout_geometry: one line, and nothing passes on no evidence
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
ok "a valid single line passes"

out="$(geom '444x206 1756x933')"
[[ "$out" == *"rc=1"* ]] || fail "height mismatch" "a short popout must fail, got: $out"
ok "a popout shorter than its output fails"

out="$(geom '')"
[[ "$out" == *"rc=1"* ]] || fail "empty" "an empty reply must fail rather than pass on no evidence, got: $out"
ok "an empty reply refuses to pass on no evidence"

out="$(geom '   ')"
[[ "$out" == *"rc=1"* ]] || fail "blank" "a whitespace-only reply must fail, got: $out"
ok "a whitespace-only reply refuses to pass on no evidence"

out="$(geom '444x933')"
[[ "$out" == *"rc=1"* ]] || fail "single field" "a single field must fail rather than compare equal to itself, got: $out"
ok "a single field cannot pass by comparing equal to itself"

# The emitter promises one line, so multi-line here means it broke its contract.
out="$(geom '444x933 1756x933
444x933 1756x933')"
[[ "$out" == *"rc=1"* ]] || fail "multi-line" "a multi-line reply breaks the emitter contract and must fail, got: $out"
ok "a multi-line reply is refused, since the emitter promises one"

if [[ $failures -ne 0 ]]; then
  printf '\ntest-qml-smoke: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-qml-smoke: all checks passed"
