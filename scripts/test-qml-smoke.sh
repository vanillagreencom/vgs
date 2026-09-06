#!/usr/bin/env bash
# Exercise the extracted smoke helpers without starting a nested compositor.
# Three surfaces, one table each: the remedy the unavailability notice prints, the layer
# state the sandbox measures, and the geometry reply the assertion accepts.
# The notice helper writes advice and nothing else, so its wording is the only channel
# a caller can read; the other two tables assert status and measured geometry.
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

# Cut one shipped helper out of the smoke script into $tmp/<name>.sh. A helper that no
# longer has this shape is a broken fixture, not a failed case: stop rather than test nothing.
slice() {
  local name="$1" dst="$tmp/$1.sh"
  awk -v open="$name() {" '$0 == open {f = 1} f {print} f && $0 == "}" {exit}' "$smoke" >"$dst"
  if ! grep -qF "$name() {" "$dst" || ! grep -q '^}$' "$dst"; then
    printf 'test-qml-smoke: could not slice %s out of %s\n' "$name" "$smoke" >&2
    exit 1
  fi
}
slice nested_unavailable
slice sandbox_layer_state
slice assert_popout_geometry

# Run the extracted notice helper with its script variables. A dash requests an unset display.
drive() {
  local wayland="$1"
  shift
  (
    set +e
    # shellcheck source=/dev/null
    . "$tmp/nested_unavailable.sh"
    # These variables are consumed by the sourced helper.
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
SOCKET_REASON="no host Wayland socket to nest inside (WAYLAND_DISPLAY unset)"

# Remedy text must follow the failed prerequisite: an unset display does not explain a
# missing binary, and a display that is already set needs no socket advice.
REMEDIES="-;Hyprland not installed;;absent
-;$SOCKET_REASON;no-host-socket;present
wayland-1;$SOCKET_REASON;no-host-socket;absent"

case_remedies() {
  local wayland reason cause verdict rows=0
  while IFS=';' read -r wayland reason cause verdict; do
    [[ -n "$wayland" ]] || continue
    rows=$((rows + 1))
    if [[ -n "$cause" ]]; then
      out="$(drive "$wayland" "$reason" "$cause")"
    else
      out="$(drive "$wayland" "$reason")"
    fi
    case "$verdict" in
      present)
        [[ "$out" == *"$REMEDY"* ]] || fail "remedies" "no socket remedy for $reason (display $wayland):
$out"
        # Wiring evidence for the row that names a cause: a remedy no shipped call site
        # ever requests reaches nobody.
        grep -qE "nested_unavailable \"[^\"]*\" +$cause" "$smoke" ||
          fail "remedies" "no call site passes $cause to nested_unavailable, so the gate is dead"
        ;;
      absent)
        [[ "$out" != *"$REMEDY"* ]] || fail "remedies" "socket remedy printed for $reason (display $wayland):
$out"
        ;;
      *) fail "remedies" "unknown verdict column: $verdict" ;;
    esac
  done <<<"$REMEDIES"
  [[ $rows -eq 3 ]] || fail "remedies" "expected 3 table rows, drove $rows"
  ok "the socket remedy follows the host-socket cause and no other"
}

case_unconditional_options() {
  # Retain the unconditional advice, so suppressing all output cannot satisfy the remedy table.
  local needed reason rows=0
  while IFS= read -r needed; do
    [[ -n "$needed" ]] || continue
    rows=$((rows + 1))
    for reason in "Hyprland not installed" "nested compositor did not come up"; do
      [[ "$(drive - "$reason")" == *"$needed"* ]] ||
        fail "unconditional options" "missing '$needed' for reason: $reason"
    done
  done <<'FRAGMENTS'
install a nested compositor
spare TTY/VM session
vshell logs -n 200
never run 'qs -c vshell'
FRAGMENTS
  [[ $rows -eq 4 ]] || fail "unconditional options" "expected 4 table rows, drove $rows"
  ok "the three unconditional options and the prohibition print for every reason"
}

# Print status before helper stdout so a row can distinguish absence from failed measurement.
layer_state() {
  local layers="$1" mons="$2" ns="$3"
  (
    set +e
    export LAYERS_FIXTURE="$layers" MONITORS_FIXTURE="$mons"
    # shellcheck source=/dev/null
    . "$tmp/sandbox_layer_state.sh"
    # shellcheck disable=SC2317,SC2329  # called by the sliced function, not from here
    sandbox_layers() { printf '%s' "$LAYERS_FIXTURE"; }
    # shellcheck disable=SC2317,SC2329  # called by the sliced function, not from here
    sandbox_monitors() { printf '%s' "$MONITORS_FIXTURE"; }
    out="$(sandbox_layer_state "$ns" 2>/dev/null)"
    printf '%s\n%s\n' "$?" "$out"
  )
}

NS="vshell:plugins:aiUsage"
mon() { printf '{"levels":{"2":[%s]}}' "$1"; }

BAR='{"namespace":"vshell:bar","w":1756,"h":40}'
POPOUT='{"namespace":"'"$NS"'","w":444,"h":933}'
SHORT='{"namespace":"'"$NS"'","w":444,"h":40}'
FULL='{"namespace":"'"$NS"'","w":1756,"h":933}'
TALL='{"namespace":"'"$NS"'","w":444,"h":2560}'
BIG='{"namespace":"'"$NS"'","w":444,"h":1692}'

declare -A LAYERS=(
  [popout]="{\"MON1\":$(mon "$POPOUT")}"
  [bar]="{\"MON1\":$(mon "$BAR")}"
  [bar+popout]="{\"MON1\":$(mon "$BAR,$POPOUT")}"
  [bar+short]="{\"MON1\":$(mon "$BAR,$SHORT")}"
  [bar+full]="{\"MON1\":$(mon "$BAR,$FULL")}"
  [tall]="{\"MON1\":$(mon "$TALL")}"
  [big]="{\"MON1\":$(mon "$BIG")}"
  [two-outputs]="{\"MON1\":$(mon "$BAR,$POPOUT"),\"MON2\":$(mon "$BAR,$POPOUT")}"
)

# A NaN scale can pass float parsing and later fail integer conversion; unusable metadata
# must stay "cannot measure" (status 3) rather than "not there" (status 1).
declare -A MONS=(
  [one]='[{"name":"MON1","width":1756,"height":933,"scale":1,"transform":0}]'
  [two]='[{"name":"MON1","width":1756,"height":933,"scale":1,"transform":0},{"name":"MON2","width":1756,"height":933,"scale":1,"transform":0}]'
  [none]='[]'
  [rotated]='[{"name":"MON1","width":5120,"height":2880,"scale":2,"transform":1}]'
  [scaled]='[{"name":"MON1","width":6016,"height":3384,"scale":2,"transform":0}]'
  [zero-scale]='[{"name":"MON1","width":1756,"height":933,"scale":0,"transform":0}]'
  [nan-scale]='[{"name":"MON1","width":1756,"height":933,"scale":"NaN","transform":0}]'
  [inf-scale]='[{"name":"MON1","width":1756,"height":933,"scale":"Infinity","transform":0}]'
  [bad-transform]='[{"name":"MON1","width":1756,"height":933,"scale":1,"transform":99}]'
  [word-transform]='[{"name":"MON1","width":1756,"height":933,"scale":1,"transform":"sideways"}]'
  [not-dicts]='["not-a-dict"]'
  [not-a-list]='{"MON1":{"width":1756,"height":933,"scale":1,"transform":0}}'
  [name-list]='[{"name":["MON1"],"width":1756,"height":933,"scale":1,"transform":0}]'
  [name-dict]='[{"name":{"a":1},"width":1756,"height":933,"scale":1,"transform":0}]'
  [name-number]='[{"name":7,"width":1756,"height":933,"scale":1,"transform":0}]'
)

# label; layers fixture; monitors fixture; expected status; expected geometry or -.
# Output size must come from the monitor mode and scale, never from another layer that can
# be smaller than the output; a status the caller reads as absence must mean absence.
LAYER_STATES='a surface alone on its output;popout;one;0;444x933 1756x933
a bar-only neighbour does not shrink the output;bar+popout;one;0;444x933 1756x933
a bar-height popout is measured against the output;bar+short;one;0;444x40 1756x933
a quarter turn swaps the logical axes;tall;rotated;0;444x2560 1440x2560
a scaled output is divided by its scale;big;scaled;0;444x1692 3008x1692
a popout as large as its output is degenerate;bar+full;one;2;-
an unmapped namespace is absent;bar;one;1;-
an unreported output cannot be measured;bar+popout;none;3;-
a zero scale does not convert;bar+popout;zero-scale;3;-
a popout mapped on two outputs breaks the one-record contract;two-outputs;two;3;-
a NaN scale does not convert;bar+popout;nan-scale;3;-
an infinite scale does not convert;bar+popout;inf-scale;3;-
an unknown transform does not convert;bar+popout;bad-transform;3;-
a word where a transform belongs;bar+popout;word-transform;3;-
a list of non-objects;bar+popout;not-dicts;3;-
an object where a list belongs;bar+popout;not-a-list;3;-
a list-valued output name;bar+popout;name-list;3;-
an object-valued output name;bar+popout;name-dict;3;-
a number-valued output name;bar+popout;name-number;3;-'

case_layer_states() {
  local label layers_key mons_key want_status want_geometry state status body rows=0
  while IFS=';' read -r label layers_key mons_key want_status want_geometry; do
    [[ -n "$label" ]] || continue
    rows=$((rows + 1))
    if [[ -z "${LAYERS[$layers_key]+set}" || -z "${MONS[$mons_key]+set}" ]]; then
      fail "layer states" "$label: no fixture named $layers_key or $mons_key"
      continue
    fi
    state="$(layer_state "${LAYERS[$layers_key]}" "${MONS[$mons_key]}" "$NS")"
    status="$(head -n1 <<<"$state")"
    body="$(tail -n +2 <<<"$state")"
    if [[ "$status" != "$want_status" ]]; then
      fail "layer states" "$label: expected status $want_status, got $status:
$state"
    elif [[ "$want_geometry" != - && "$body" != *"$want_geometry"* ]]; then
      fail "layer states" "$label: expected geometry $want_geometry, got:
$state"
    elif [[ "$status" == 0 && "$(grep -c . <<<"$body")" != 1 ]]; then
      # The emitter promises one line; a caller parses the first one it finds.
      fail "layer states" "$label: expected exactly one emitted line, got:
$state"
    fi
  done <<<"$LAYER_STATES"
  [[ $rows -eq 19 ]] || fail "layer states" "expected 19 table rows, drove $rows"
  ok "each layer and monitor payload measures, refuses or reports absence as declared"
}

geom() {
  (
    set +e
    # shellcheck source=/dev/null
    . "$tmp/assert_popout_geometry.sh"
    # shellcheck disable=SC2317,SC2329  # called by the sliced function, not from here
    fail() { printf 'FAILMSG: %s\n' "$*"; }
    assert_popout_geometry "$1" aiUsage
    printf 'rc=%s\n' "$?"
  ) 2>&1
}

# label; reply, with \n for the line break; expected status.
GEOMETRY='a valid single line;444x933 1756x933;0
a popout shorter than its output;444x206 1756x933;1
an empty reply;;1
a whitespace-only reply;   ;1
a single field cannot compare equal to itself;444x933;1
a multi-line reply breaks the emitter contract;444x933 1756x933\n444x933 1756x933;1'

case_geometry_replies() {
  local label reply want_rc rows=0
  while IFS=';' read -r label reply want_rc; do
    [[ -n "$label" ]] || continue
    rows=$((rows + 1))
    out="$(geom "$(printf '%b' "$reply")")"
    [[ "$out" == *"rc=$want_rc"* ]] ||
      fail "geometry replies" "$label: expected rc=$want_rc, got: $out"
  done <<<"$GEOMETRY"
  [[ $rows -eq 6 ]] || fail "geometry replies" "expected 6 table rows, drove $rows"
  ok "only a well-formed reply that measures full height passes"
}

CASES=(
  case_remedies
  case_unconditional_options
  case_layer_states
  case_geometry_replies
)
for smoke_case in "${CASES[@]}"; do
  "$smoke_case"
done

if [[ $failures -ne 0 ]]; then
  printf '\ntest-qml-smoke: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-qml-smoke: all checks passed"
