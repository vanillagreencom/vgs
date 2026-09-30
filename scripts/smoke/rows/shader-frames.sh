# Read the real passive layer window, independently of bar counters.
# Poll interval: one IPC round trip. Quiet windows settle for 0.2 s before
# a full 2 s observation, so a queued transition frame is not an idle tick.
# Controls disconnect the reader and remove the orb's motion-scale guard.
set -euo pipefail
expect "enable the layer frame fixture" ok ipc shell setPluginEnabled acme.layers true
expect_poll "the layer frame fixture builds" True record_exists acme.layers
expect "show the passive layer for frame readings" ok layered draw
expect_poll "the passive layer maps" "$monitors" layer_count vgs:layer
expect "observe the layer's own window" ok ipc smoke watchLayerFrames acme.layers
expect "the listening visual activates" ok layered voice 1

layer_advances() {
  local before after
  before="$(ipc smoke layerFrames)" || return 1
  [[ $before =~ ^[0-9]+$ ]] || { echo "$before"; return; }
  # A real wait lets the compositor present frames between observations.
  sleep 0.2
  after="$(ipc smoke layerFrames)" || return 1
  [[ $after =~ ^[0-9]+$ ]] || { echo "$after"; return; }
  if ((after > before)); then echo advancing; else echo stopped; fi
}
layer_quiet() {
  local before after
  sleep 0.2
  before="$(ipc smoke layerFrames)" || return 1
  [[ $before =~ ^[0-9]+$ ]] || { echo "$before"; return; }
  # The acceptance interval is a real two-second presentation observation.
  sleep 2
  after="$(ipc smoke layerFrames)" || return 1
  [[ $after =~ ^[0-9]+$ ]] || { echo "$after"; return; }
  printf '        layer_frames_before=%s after=%s interval_s=2\n' "$before" "$after" >&2
  if ((after == before)); then echo quiet; else echo swapped; fi
}
expect_poll "the listening layer advances frames" advancing layer_advances
expect "disconnect the layer reader control" ok ipc smoke layerFrameListening false
expect "a disconnected reader fails the advancing-frame assertion" stopped layer_advances
expect "restore the layer reader" ok ipc smoke layerFrameListening true
expect_poll "the connected reader advances again" advancing layer_advances

frame_theme="$home/.config/vgs/theme.json"
printf '%s\n' '{"schemaVersion":1,"name":"still","tokens":{"motion":{"scale":0}}}' >"$frame_theme.tmp"
mv -T -- "$frame_theme.tmp" "$frame_theme"
expect_poll "zero motion reaches the listening visual" 0 ipc smoke themeValue motion.scale
expect "zero motion presents no layer frame over two seconds" quiet layer_quiet

expect "hide the normal visual for the driver control" ok layered voice 0
expect "load the driver without its zero-motion guard" ok ipc smoke layerOrbLoad orb-frame-control "$repo/shell/Ui/feedback/VoiceOrbFrameControl.qml"
expect_poll "the driver control first proves it presents frames" advancing layer_advances
expect "the driver control fails the quiet-window assertion" swapped layer_quiet
expect "destroy the driver control" ok ipc smoke popupDrop orb-frame-control

printf '%s\n' '{"schemaVersion":1,"name":"vgs","tokens":{}}' >"$frame_theme.tmp"
mv -T -- "$frame_theme.tmp" "$frame_theme"
expect_poll "restore the normal motion scale" 1 ipc smoke themeValue motion.scale
expect "restore the listening visual" ok layered voice 1
expect_poll "the visual presents frames before unmapping" advancing layer_advances
expect "unmap the observed layer window" ok ipc smoke layerFrameVisible false
expect "the unmapped layer presents no frame over two seconds" quiet layer_quiet
expect "remap the observed window for the quiet-reader control" ok ipc smoke layerFrameVisible true
expect_poll "the mapped listening layer advances again" advancing layer_advances
expect "a mapped listening layer fails the unmapped-window assertion" swapped layer_quiet
expect "release the layer window reader" ok ipc smoke dropLayerFrames
expect "the layer fixture releases its layer" ok layered undraw
expect "disable the layer frame fixture" ok ipc shell setPluginEnabled acme.layers false
expect_poll "the frame fixture leaves no layer" 0 layer_count vgs:layer
