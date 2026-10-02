# Sourced by harness.sh after verdict.sh; the mode and scale a row holds on
# a nested output. It reads the nested compositor through hypr, which
# harness.sh defines, and writes mode_hold and mode_hold_file, which
# verdict.sh and harness.sh declare. release_mode reports through expect
# and expect_poll, and hold_mode through ok and fail.

# monitor_rule NAME MODE [SCALE]: the Lua monitor rule that gives output
# NAME the mode MODE, such as 480x720, at SCALE, 1 by default, and the
# layout's origin. The nested Wayland output takes any mode and an integer
# scale; a headless output stays 0x0 in the sandbox
# (docs/architecture/runtime-hyprland-nested.md).
monitor_rule() { printf 'hl.monitor({ output = "%s", mode = "%s", position = "0x0", scale = %s })\n' "$1" "$2" "${3:-1}"; }
# output_mode NAME MODE [SCALE]: the nested compositor applies
# monitor_rule's rule now through `hyprctl eval`; the reply is hyprctl's.
# A configuration reload drops the rule but leaves the output at its mode
# and scale, unless a rule the configuration loads gives the output
# another (docs/architecture/runtime-hyprland-nested.md). Under a hold it stands
# for a reset, and a reload applies the held rule again from
# mode_hold_file. A row restores the mode it read first.
output_mode() { hypr eval "$(monitor_rule "$@")"; }
# mode_scale_of NAME: output NAME's mode and scale as `WxH scale=S`, such
# as `3510x1866 scale=2`, the mode in device pixels; returns 1 when no
# monitor has that name.
mode_scale_of() { hypr -j monitors | python3 -c 'import json,sys; m=[m for m in json.load(sys.stdin) if m["name"]==sys.argv[1]]; print("%dx%d scale=%g" % (m[0]["width"], m[0]["height"], m[0]["scale"])) if len(m)==1 else sys.exit(1)' "$1"; }
# mode_attempts: how many times take_mode applies one rule. A host
# configure of the nested window that arrives after the rule gives the
# output the host window's size again (held_mode_state), so a rule that
# took can read as another mode. The bound stops the retries when the
# host keeps configuring the window.
mode_attempts=3
# take_mode NAME MODE SCALE: output NAME takes MODE at SCALE. output_mode
# applies the rule, then mode_scale_of reads the output every 200 ms for
# up to 5 s; an output that never reads `MODE scale=SCALE` gets the rule
# again, up to mode_attempts times. Prints `attempts=<n> got=[<reading>]`,
# the last reading `unreadable` when the monitor cannot be read, and
# returns 0 when the output reads the mode and scale, 1 when it never
# does. A rule hyprctl does not answer `ok` is no reset: take_mode prints
# `attempts=<n> eval=[<reply>]` and returns 1 at once.
take_mode() {
  local output="$1" mode="$2" scale="$3" attempt reply got=""
  for ((attempt = 1; attempt <= mode_attempts; attempt++)); do
    if ! reply="$(output_mode "$output" "$mode" "$scale")" || [[ $reply != ok ]]; then
      printf 'attempts=%s eval=[%s]\n' "$attempt" "$reply"
      return 1
    fi
    for _ in $(seq 1 25); do
      got="$(mode_scale_of "$output")" || got=unreadable
      if [[ $got == "$mode scale=$scale" ]]; then
        printf 'attempts=%s got=[%s]\n' "$attempt" "$got"
        return 0
      fi
      sleep 0.2
    done
  done
  printf 'attempts=%s got=[%s]\n' "$mode_attempts" "$got"
  return 1
}
# hold_mode LABEL NAME MODE [SCALE]: output NAME takes MODE at SCALE, 1 by
# default, and the rows after it hold that mode and scale until
# release_mode. The rule goes into mode_hold_file, which every load of the
# configuration runs, and take_mode applies it now. The hold begins once
# the monitor reads both; a mode or a scale never taken is a failure,
# holds nothing and leaves no hold file.
hold_mode() {
  local label="$1" output="$2" want="$3 scale=${4:-1}" taken
  [[ ${#mode_hold[@]} -eq 0 ]] || { fail "$label: ${mode_hold[0]} already holds ${mode_hold[1]}; hold_mode does not nest"; return; }
  if ! monitor_rule "$output" "$3" "${4:-1}" >"$mode_hold_file.next" || ! mv -T -- "$mode_hold_file.next" "$mode_hold_file"; then
    fail "$label: the hold file $mode_hold_file is not written"
    rm -f -- "$mode_hold_file.next" || fail "$label: the partial hold file $mode_hold_file.next is not removed"
    return 0
  fi
  if taken="$(take_mode "$output" "$3" "${4:-1}")"; then
    mode_hold=("$output" "$want")
    ok "$label: $output reads $want, $taken"
  else
    fail "$label: $output does not read $want: $taken"
    rm -f -- "$mode_hold_file" || fail "$label: the hold file $mode_hold_file of a hold never taken is not removed"
  fi
  return 0
}
# hold_restore: the held mode and scale again, after held_mode_state read
# a reset, through take_mode with the held rule. Returns 0 once the
# output reads them. Otherwise prints `hold-restore: not-held
# output=<name> want=[<state>] <take_mode's reading>`, or
# `hold-restore: refused hold=none` when no row holds a mode, and returns
# 1. It writes no hold file: the file already holds the rule.
hold_restore() {
  local taken
  if [[ ${#mode_hold[@]} -eq 0 ]]; then
    echo 'hold-restore: refused hold=none'
    return 1
  fi
  if ! taken="$(take_mode "${mode_hold[0]}" "${mode_hold[1]% scale=*}" "${mode_hold[1]##*scale=}")"; then
    printf 'hold-restore: not-held output=%s want=[%s] %s\n' "${mode_hold[0]}" "${mode_hold[1]}" "$taken"
    return 1
  fi
}
# held_mode_state: what became of the held mode, as one word. `held`: the
# output reads its mode and scale. `reset`: the output reads another mode
# or another scale. Once the hold began, the host moves a nested output
# off it, and that is not what a held row measures. Aquamarine's Wayland
# backend turns every xdg_toplevel configure the host sends the nested
# window into a state event with the configure's size
# (CWaylandOutput::CWaylandOutput in src/backend/Wayland.cpp, aquamarine
# v0.15.1), and the host sends one whenever it resizes the window or
# changes its state, focus and tiling included. For a Wayland-backend
# output, Hyprland's state listener applies the active rule again with
# that size in place of the rule's mode, unless the two are equal
# (CMonitor::onConnect in src/output/Monitor.cpp, Hyprland v0.56.2). The
# rule keeps its scale, and CMonitor::applyMonitorRule moves a scale that
# leaves fractional logical pixels to the nearest one that does not: a
# 1755x933 window under a 3510x1866 hold at scale 2 reads 1755x933 at
# scale 1.5. A hold at the window's own size survives a configure of the
# same size and no resize. Each applied rule, the host's size included,
# becomes the active rule (CMonitor::applyMonitorRuleSoft, same file), so
# after a resize away a configure back to the window's own size differs
# from the active rule and gives the output that size again: a scale-1
# hold at the window's own size comes back without its rule, and a
# reading after both configures reads `held`. No host configure equals a
# doubled mode, so a scale-2 hold comes back only through its rule
# applied again (hold_restore), or a configuration reload, which the
# shell runs when its Hyprland layer changes: a reload drops every rule
# `hyprctl eval` added (src/config/lua/ConfigManager.cpp,
# CConfigManager::reload, v0.56.2) and applies the rule mode_hold_file
# names again. The shell writes no monitor rule of its own.
# `unreadable`: the monitor cannot be read, which excuses nothing.
held_mode_state() {
  local state
  state="$(mode_scale_of "${mode_hold[0]}")" || { echo unreadable; return; }
  if [[ $state == "${mode_hold[1]}" ]]; then echo held; else echo reset; fi
}
# release_mode LABEL NAME MODE [SCALE]: any hold ends, its file goes, and
# output NAME takes MODE at SCALE, 1 by default, again, whether or not
# hold_mode's mode was taken, and reads both before the rows go on.
release_mode() {
  mode_hold=()
  rm -f -- "$mode_hold_file" || fail "$1: the hold file $mode_hold_file is not removed"
  expect "$1" ok output_mode "$2" "$3" "${4:-1}"
  expect_poll "$2 reads $3 scale=${4:-1}" "$3 scale=${4:-1}" mode_scale_of "$2"
}
