# Sourced by scripts/measure-shader.sh after scripts/smoke/harness.sh and
# scripts/smoke/verdict.sh; measures one scene of the shader instrument
# under the nested output's held mode. It reads the harness's sandbox, its
# spawn and its process-group leases, and the hold's readers.

# scene_attempts: how many times measure_held_scene measures one scene
# whose output left the held mode. Each reset needs a host configure of
# the nested window during the scene (held_mode_state in
# scripts/smoke/mode-hold.sh); the bound ends a run whose host keeps
# configuring the window.
scene_attempts=3

# measure_scene SCALE SCENE STEM: one standalone layer, VGS_SHADER_MODE
# SCENE, until its result reads complete or timeout_s passes. Writes
# STEM.launch.log, the instance log as STEM.log and the result as
# STEM.json, reaps the layer and ends its process group's lease, and sets
# scene_cpu_some_pct to cpu_some_pct of the scene's window. Exits 1, with
# the cause, when the layer leaves no instance, exits other than by the
# TERM it is sent, or never completes its samples.
measure_scene() {
  local scale="$1" scene="$2" stem="$3" scene_pid result done=false instance scene_exit=0 start_us start_ms poll group remaining=()
  start_us="$(cpu_some_us)"
  start_ms="$(now_ms)"
  spawn "$stem.launch.log" "${shell_env[@]}" VGS_SHADER_MODE="$scene" \
    QSG_RHI_BACKEND=vulkan QSG_RHI_PROFILE=1 QSG_NO_VSYNC=1 \
    QT_LOGGING_RULES='qt.scenegraph.time.renderloop.debug=true;qt.scenegraph.general=true;qt.rhi.general=true' \
    qs -p "$repo/shell/ShaderScene.qml"
  scene_pid="$spawn_pid"
  result=""
  for ((poll=0; poll<timeout_s*5; poll++)); do
    kill -0 "$scene_pid" 2>/dev/null || break
    if result="$("${shell_env[@]}" qs ipc --pid "$scene_pid" call shader result 2>/dev/null)" \
      && [[ $result == *'"complete":true'* ]]; then done=true; break; fi
    sleep 0.2
  done
  scene_cpu_some_pct="$(cpu_some_pct "$start_us" "$(cpu_some_us)" "$(( $(now_ms) - start_ms ))")"
  # Read the flushed instance log by the scene's own pid, not its stdout.
  # The listing answers none or unlisted when no instance names the pid.
  if ! instance="$(qs_list --all | py_reply 'import json,sys; print(next((i["id"] for i in json.load(sys.stdin) if i["pid"] == int(sys.argv[1])), "unlisted"))' "$scene_pid")" \
    || [[ $instance == none || $instance == unlisted ]]; then
    echo "shader-cost: failed scene=$scene scale=$scale instance=${instance:-unreadable}"; cat -- "$stem.launch.log"; exit 1;
  fi
  cp -- "$rt_dir/quickshell/by-id/$instance/log.log" "$stem.log"
  printf '%s\n' "$result" >"$stem.json"
  kill -TERM "$scene_pid"
  wait "$scene_pid" || scene_exit=$?
  # Reaping ends this process group's lease; teardown must not retain a
  # pid that the kernel can give to an unrelated process during later runs.
  for group in "${pgids[@]}"; do
    [[ $group == "$scene_pid" ]] || remaining+=("$group")
  done
  pgids=("${remaining[@]}")
  [[ $scene_exit == 0 || $scene_exit == 143 ]] || {
    printf 'shader-cost: failed scene=%s scale=%s exit=%s\n' "$scene" "$scale" "$scene_exit"; exit 1;
  }
  [[ $done == true ]] || { echo "shader-cost: failed scene=$scene scale=$scale samples=incomplete"; exit 1; }
}

# measure_held_scene SCALE SCENE STEM: measure_scene under the held mode.
# At scale 2 the held mode is double the host window's size, which no
# host configure equals, so only the hold's rule puts it back; the scene
# applies none, and a scene after which the output still reads the held
# mode ran under it from start to end. The scale-1 hold is the window's
# own size, which a host resize away and back restores without the rule
# (held_mode_state in scripts/smoke/mode-hold.sh), and the reading after
# the scene cannot see that. The scale stays 1 and the layer's size is
# fixed, so only the frames around the two changes are affected, and the
# 90th-percentile reading absorbs a few such frames. A scene after which
# the output reads a reset is
# discarded: the runner prints `shader-cost: mode-reset scene=<scene>
# scale=<n> got=[<reading>] attempt=<k>`, hold_restore takes the hold
# again and the scene runs again, up to scene_attempts times. Past the
# bound, smoke_verdict counts the reset and the run exits 77 with
# `nested-output=mode-reset` when it is the only failure. A hold that
# cannot be taken again, or an output that cannot be read, fails.
measure_held_scene() {
  local scale="$1" scene="$2" stem="$3" attempt state got
  for ((attempt = 1; ; attempt++)); do
    measure_scene "$scale" "$scene" "$stem"
    state="$(held_mode_state)" || { echo 'shader-cost: failed output=unreadable'; exit 1; }
    case "$state" in
      held) break ;;
      reset) ;;
      *) printf 'shader-cost: failed output=%s\n' "$state"; exit 1 ;;
    esac
    got="$(mode_scale_of "${mode_hold[0]}")" || got=unreadable
    printf 'shader-cost: mode-reset scene=%s scale=%s got=[%s] attempt=%s\n' "$scene" "$scale" "$got" "$attempt"
    if ((attempt >= scene_attempts)); then
      smoke_verdict "$((failures + 1))" "$behaviour_failures" "$stalled_render" "$((mode_resets + 1))" "$sandbox/hyprland.log"
      exit $?
    fi
    hold_restore || { printf 'shader-cost: failed output=not-restored scene=%s scale=%s\n' "$scene" "$scale"; exit 1; }
  done
  printf 'shader-cost: scene=%s scale=%s samples=600 cpu_some_pct=%s log=%s\n' "$scene" "$scale" "$scene_cpu_some_pct" "$stem.log"
}
