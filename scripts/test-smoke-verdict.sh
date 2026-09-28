#!/usr/bin/env bash
# Drive scripts/smoke/verdict.sh, the nested smoke's closing verdict, with
# the counters smoke_finish hands it and fixture compositor logs. No case
# needs a sandbox. Each case pins the exit status and the first line the
# verdict prints. The controls at the end plant one defect per rule in a
# copy of the file and require the case that rule owns to go red.
#
# The passing log holds lines copied from a passing run's nested
# hyprland.log: the nested window's output configured, then the failed
# allocations every passing run logs for Hyprland's headless output. The
# fault log adds the lines a failed allocation on the nested window's own
# output writes, built from Aquamarine's format strings in
# src/allocator/GBM.cpp, src/allocator/Swapchain.cpp and
# src/backend/Wayland.cpp (v0.15.1); no run here has logged them.
#
# Exit 0 when every case and control holds, 1 otherwise.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
verdict="$repo/scripts/smoke/verdict.sh"

tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${tmp:?}"' EXIT
failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

{
  echo 'DEBUG from aquamarine ]: Output WAYLAND-1: initialized'
  echo 'DEBUG from aquamarine ]: Output WAYLAND-1: configure toplevel with 1755x933'
  echo 'DEBUG from aquamarine ]: Swapchain: Reconfigured a swapchain to [Vector2D: x: 1755, y: 933] XR24 of length 3'
  for _ in $(seq 1 16); do
    echo 'ERR from aquamarine ]: GBM: Allocating with modifiers failed, falling back to modifier-less allocation'
    echo 'ERR from aquamarine ]: GBM: Failed to allocate a GBM buffer: bo null'
    echo "ERR from aquamarine ]: Couldn't allocate a gbm buffer with size [Vector2D: x: 1920, y: 1080] and format XR24"
    echo 'ERR from aquamarine ]: Swapchain: Failed acquiring a buffer'
  done
} >"$tmp/passing.log"
{
  cat "$tmp/passing.log"
  echo 'DEBUG from aquamarine ]: Output WAYLAND-1: configure toplevel with 1920x1040'
  echo 'ERR from aquamarine ]: GBM: Failed to allocate a GBM buffer: bo null'
  echo "ERR from aquamarine ]: Couldn't allocate a gbm buffer with size [Vector2D: x: 1920, y: 1040] and format XR24"
  echo 'ERR from aquamarine ]: Swapchain: Failed acquiring a buffer'
  echo 'ERR from aquamarine ]: Output WAYLAND-1: pending state rejected: swapchain failed reconfiguring'
} >"$tmp/fault.log"

# run_case FILE ROW: true when the verdict FILE defines gives the row's
# status and first line. The caller's shell options are the harness's.
run_case() {
  local file="$1" label failures_n behaviour stalled logs want_status want_line out status=0 names=() paths=() name
  IFS='|' read -r label failures_n behaviour stalled logs want_status want_line <<<"$2"
  read -r -a names <<<"$logs"
  for name in "${names[@]}"; do paths+=("$tmp/$name.log"); done
  out="$(env -i PATH="$PATH" bash -c 'set -euo pipefail; source "$1"; shift; smoke_verdict "$@"' _ \
    "$file" "$failures_n" "$behaviour" "$stalled" "${paths[@]}")" || status=$?
  [[ $status -eq $want_status && ${out%%$'\n'*} == "$want_line" ]] && return 0
  printf '        %s: status=%s want=%s first line: %s\n' "$label" "$status" "$want_status" "${out%%$'\n'*}"
  return 1
}

# Rows: label | failures | behaviour failures | stalled render | fixture
# logs, space-delimited, `missing` naming none written | status | first line.
cases=(
  "a clean run passes|0|0|false|passing|0|qml-smoke: ok"
  "all-geometry failure with a passing log fails|3|0|false|passing|1|qml-smoke: failed=3"
  "all-geometry failure with the nested output's fault is not measured|3|0|false|fault|77|qml-smoke: status=not-measured nested-compositor=buffer-allocation-failed failed=3"
  "the fault in a second log is read|3|0|false|passing fault|77|qml-smoke: status=not-measured nested-compositor=buffer-allocation-failed failed=3"
  "a behaviour failure with the fault fails|3|1|false|fault|1|qml-smoke: failed=3"
  "all-geometry failure with no readable log fails|3|0|false|missing|1|qml-smoke: failed=3"
  "all-geometry failure with an undrawn render row is not measured|3|0|true|passing|77|qml-smoke: status=not-measured nested-window=not-drawn failed=3"
  "a behaviour failure with an undrawn render row fails|3|1|true|passing|1|qml-smoke: failed=3"
)
for row in "${cases[@]}"; do
  if run_case "$verdict" "$row"; then ok "${row%%|*}"; else fail "${row%%|*}"; fi
done

# mutate OLD NEW OUT: a copy of the verdict with OLD, which must occur once,
# replaced by NEW.
mutate() {
  local text rest count
  text="$(<"$verdict")"
  rest="${text//"$1"/}"
  count=$(( (${#text} - ${#rest}) / ${#1} ))
  if [[ $count -ne 1 ]]; then
    printf '        mutation matched %s times: %s\n' "$count" "$1"
    return 1
  fi
  printf '%s\n' "${text/"$1"/"$2"}" >"$3"
  cmp -s -- "$verdict" "$3" && { printf '        mutation left the file unchanged: %s\n' "$1"; return 1; }
  return 0
}

# Rows: label | text | replacement | the case label that must go red. A
# field holds no `|`, the separator.
controls=(
  "the excuse reads any GBM allocation failure|'Output WAYLAND-[0-9]+: pending state rejected: swapchain failed reconfiguring'|'Failed to allocate a GBM buffer'|all-geometry failure with a passing log fails"
  "the nested output's fault is not read|nested_output_unallocated \"\$@\"; then|false; then|all-geometry failure with the nested output's fault is not measured"
  "a behaviour failure is excused by the fault|if [[ \$behaviour_failures -eq 0 ]] && nested_output_unallocated|if nested_output_unallocated|a behaviour failure with the fault fails"
  "an undrawn render row is not read|\$stalled_render == true|\$stalled_render == never|all-geometry failure with an undrawn render row is not measured"
  "a behaviour failure is excused by an undrawn row|\$behaviour_failures -eq 0 && \$stalled_render|\$stalled_render|a behaviour failure with an undrawn render row fails"
)
for i in "${!controls[@]}"; do
  IFS='|' read -r label old new target <<<"${controls[i]}"
  mutant="$tmp/mutant-$i.sh"
  if ! mutate "$old" "$new" "$mutant"; then fail "control: $label"; continue; fi
  row=""
  for candidate in "${cases[@]}"; do [[ ${candidate%%|*} == "$target" ]] && row="$candidate"; done
  if [[ -z $row ]]; then fail "control: $label names no case: $target"; continue; fi
  if run_case "$mutant" "$row" >/dev/null; then fail "control: $label left '$target' green"; else ok "control: $label"; fi
done

if [[ $failures -gt 0 ]]; then
  echo "test-smoke-verdict: failed=$failures"
  exit 1
fi
echo "test-smoke-verdict: ok"
