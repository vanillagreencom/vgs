# HiDPI: a shell started on the first monitor held at double its mode and
# scale 2. It reads:
# - the hold: the compositor reports the first monitor's sized mode,
#   doubled, at scale 2 (hold_mode's poll of `hyprctl -j monitors`);
# - a configuration reload under the hold, after the scale alone dropped
#   to 1: the reload runs the harness's hold file and the held mode and
#   scale come back;
# - the shell's screen, as the host handed it to the vgs.themes background
#   (the probe's screenOf): devicePixelRatio 2 at half the held mode, the
#   monitor's logical size;
# - the background's requested sourceSize: the held mode, in device pixels.
# Controls: the scale alone drops to 1 under the hold, the compositor
# reports that scale and the hold reads it as a reset, so the reading is
# the scale the compositor applied; with the hold file removed, the same
# scale-only drop and reload leave the held mode at scale 1 and the hold
# reads reset, so the file brings the hold back; a sandbox copy of
# Background.qml that decodes at logical pixels requests half the held
# mode.
# The row starts its own shell because a scale change under a running
# shell does not reach it: the screen reports no devicePixelRatio change,
# and a window that exists keeps drawing at the old ratio
# (docs/architecture/runtime-qml.md). It stops the shell
# rows/notices-control.sh left running, starts the sandbox's tree over the
# default set, every first-party plugin enabled (harness.sh's
# default_set_prepare), stops that shell and gives the monitor its own
# mode at scale 1 again. It leaves no shell running; rows/start-order.sh
# starts its own.
#
# This row adds no latency budget. It starts the shell through
# harness.sh's start_shell, so it reuses the smoke startup poll intervals:
# 10 ms for the first bar and one `vgsh ipc` round trip for readiness.
set -euo pipefail
ipc() {
  "${shell_env[@]}" "$repo/bin/vgsh" ipc call "$@" 2>>"$sandbox/ipc.log" | tail -n 1
}
# stop_shell fails the row itself when the instance lock stays held; the
# start below then fails on the held lock too, and the row goes on.
stop_shell || :

# screen_scale NAME: the screen the background on NAME was handed, as
# `WxH ratio=R`, the size in logical pixels.
screen_scale() { ipc smoke screenOf "background:$1" vgs.themes | py_reply 'import json,sys; w,h,r=json.load(sys.stdin); print("%dx%d ratio=%g" % (w, h, r))'; }

if ! hidpi_output="$(first_name)" || ! hidpi_base="$(unscaled_mode_of "$hidpi_output")" || ! hidpi_mode="$(hidpi_mode_of "$hidpi_output")"; then
  fail "the HiDPI row reads no sized mode at scale 1 on the first monitor ${hidpi_output:-unread}"
else
  hold_mode "the nested compositor holds $hidpi_output at double its mode and scale 2" "$hidpi_output" "$hidpi_mode" 2
  if [[ ${#mode_hold[@]} -gt 0 ]]; then
    # Control of the hold's reading: the scale alone drops to 1.
    expect "control: $hidpi_output drops to scale 1 at the held mode" ok output_mode "$hidpi_output" "$hidpi_mode" 1
    expect_poll "control: $hidpi_output reads the held mode at scale 1" "$hidpi_mode scale=1" mode_scale_of "$hidpi_output"
    expect "control: the hold reads the scale-only drop as a reset" reset held_mode_state
    # A reload runs hyprland.lua again, which loads the hold file after its
    # default rule, so the held rule comes back over the drop. The reads
    # run under hold_check: a reset they read is their failure.
    expect "the nested instance reloads its configuration under the hold" ok hypr reload config-only
    hold_check expect_poll "the reload gives $hidpi_output the held mode and scale again" held held_mode_state
    # Control of the hold file: the same drop and reload without it. The
    # reload drops the eval'd rule and the output keeps the scale-1 drop,
    # so the file is what brings the hold back. The reload applies the
    # monitor rules before it answers (CConfigManager::postConfigReload
    # runs ensureMonitorStatus, Hyprland v0.56.2), so the reads follow the
    # reply at once.
    rm -- "$mode_hold_file" || fail "control: the hold file $mode_hold_file is not removed"
    expect "control: $hidpi_output drops to scale 1 at the held mode without the hold file" ok output_mode "$hidpi_output" "$hidpi_mode" 1
    expect_poll "control: $hidpi_output reads the held mode at scale 1 without the hold file" "$hidpi_mode scale=1" mode_scale_of "$hidpi_output"
    expect "control: the nested instance reloads its configuration without the hold file" ok hypr reload config-only
    hold_check expect "control: without the hold file the reload leaves $hidpi_output at the held mode and scale 1" "$hidpi_mode scale=1" mode_scale_of "$hidpi_output"
    hold_check expect "control: the hold reads the reload without its file as a reset" reset held_mode_state
    release_mode "the control ends at $hidpi_output's own mode at scale 1" "$hidpi_output" "$hidpi_base"
    hold_mode "the nested compositor holds $hidpi_output at scale 2 again before the shell starts" "$hidpi_output" "$hidpi_mode" 2
  fi
  if [[ ${#mode_hold[@]} -gt 0 ]]; then
    # A generated image larger than the output, named current in the
    # state file the background reads; the file as it was comes back after.
    hidpi_image="$home/.config/vgs/backgrounds/hidpi.png"
    mkdir -p -- "$(dirname -- "$hidpi_image")" "$bg_state"
    solid_png "$hidpi_image" 4000 2000 40 120 200
    if [[ -e $bg_state/backgrounds.json ]]; then cp -p -- "$bg_state/backgrounds.json" "$sandbox/hidpi-backgrounds.json"; fi
    bg_state_names "$hidpi_image"
    default_set_prepare '[]'
    if start_shell "$repo" "$sandbox/hidpi-qs.log"; then
      expect_poll "the shell started at scale 2 reads its screen at ratio 2 and half the held mode" "$hidpi_base ratio=2" screen_scale "$hidpi_output"
      expect_poll "the scale-2 background draws the prepared image" "$hidpi_image ready" background_image_on "$hidpi_output"
      expect_poll "the scale-2 background requests device pixels" "$hidpi_mode" background_source_size "$hidpi_output"
      expect "the start's follow ends before the logical-pixel control" idle theme_idle
      # Control: a copy of the background that decodes at logical pixels.
      plugin_qml="$repo/shell/plugins/vgs.themes/Background.qml"
      cp -p -- "$plugin_qml" "$sandbox/Background.qml.hidpi.real"
      if python3 - "$sandbox/Background.qml.hidpi.real" "$plugin_qml.tmp" <<'PY'
import pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:])
text = src.read_text()
replacements = {
    "Math.ceil(root.screen.width * root.screen.devicePixelRatio)": "root.screen.width",
    "Math.ceil(root.screen.height * root.screen.devicePixelRatio)": "root.screen.height",
}
for old in replacements:
    assert text.count(old) == 1, f"device-pixel control must match once: {old}"
for old, new in replacements.items():
    text = text.replace(old, new)
assert text != src.read_text(), "device-pixel control must change the file"
dst.write_text(text)
PY
      then
        mv -T -- "$plugin_qml.tmp" "$plugin_qml"
        expect "a rescan builds the logical-pixel control" ok ipc shell rescanPlugins
        expect_poll "control: the logical-pixel copy requests half the held mode" "$hidpi_base" background_source_size "$hidpi_output"
        cp -p -- "$sandbox/Background.qml.hidpi.real" "$plugin_qml.tmp" && mv -T -- "$plugin_qml.tmp" "$plugin_qml"
        expect "a rescan restores the device-pixel background" ok ipc shell rescanPlugins
        expect_poll "the restored scale-2 background requests device pixels" "$hidpi_mode" background_source_size "$hidpi_output"
        expect "the follow after the restoring rescan ends" idle theme_idle
      else
        fail "the logical-pixel control could not be planted in $plugin_qml"
      fi
      check_unexpected_log "the scale-2 shell's log" "$instance_log"
    fi
    stop_shell || :
    if [[ -e $sandbox/hidpi-backgrounds.json ]]; then
      mv -T -- "$sandbox/hidpi-backgrounds.json" "$bg_state/backgrounds.json"
    else
      rm -f -- "$bg_state/backgrounds.json"
    fi
    rm -f -- "$hidpi_image"
  fi
  release_mode "the nested compositor gives $hidpi_output its own mode at scale 1" "$hidpi_output" "$hidpi_base"
fi
