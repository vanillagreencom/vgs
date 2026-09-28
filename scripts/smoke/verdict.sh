# Sourced by harness.sh and by scripts/test-smoke-verdict.sh; defines the
# smoke's closing verdict and reads no sandbox state of its own.

# nested_output_unallocated LOG...: true when a nested compositor log holds
# the line Aquamarine's Wayland backend writes when the nested window's own
# output rejects a state because its swapchain could not allocate buffers
# (src/backend/Wayland.cpp, aquamarine v0.15.1). A GBM allocation line alone
# names no output: every passing run logs failed 1920x1080 XR24 allocations
# for Hyprland's headless FALLBACK output. Five passing runs of
# scripts/qml-smoke.sh --keep on the owner's machine (host cachy, AMD Ryzen 9
# 9950X, Hyprland 0.56.2, aquamarine 0.15.1) on 2026-09-27, counted with
# grep -c in each kept hyprland.log, each logged 16 `Failed to allocate a GBM
# buffer` lines and no rejection line. An unreadable log holds no line, so
# the run fails.
nested_output_unallocated() {
  grep -q -s -E 'Output WAYLAND-[0-9]+: pending state rejected: swapchain failed reconfiguring' -- "$@"
}

# smoke_verdict FAILURES BEHAVIOUR_FAILURES STALLED_RENDER LOG...: prints
# the run's closing line and returns its exit status. A run whose failures
# are all geometry or render rows met a sandbox fault when a render row drew
# no frame, or when the nested window's output could not allocate its
# buffers; it reports not-measured, which is never a pass, and names the
# cause. Any behaviour failure is a failure.
smoke_verdict() {
  local failures="$1" behaviour_failures="$2" stalled_render="$3"
  shift 3
  if [[ $failures -eq 0 ]]; then
    echo "qml-smoke: ok"
    return 0
  fi
  if [[ $behaviour_failures -eq 0 && $stalled_render == true ]]; then
    printf 'qml-smoke: status=not-measured nested-window=not-drawn failed=%s\n' "$failures"
    echo "the nested window stopped drawing; enable render_unfocused for class aquamarine in the host Hyprland window rules, or keep the window visible, then run the smoke again"
    return 77
  fi
  if [[ $behaviour_failures -eq 0 ]] && nested_output_unallocated "$@"; then
    printf 'qml-smoke: status=not-measured nested-compositor=buffer-allocation-failed failed=%s\n' "$failures"
    return 77
  fi
  echo "qml-smoke: failed=$failures"
  return 1
}
