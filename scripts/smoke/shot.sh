# Sourced by the harness; captures the nested compositor's output with grim.
#
# grim speaks wlr-screencopy to the compositor its WAYLAND_DISPLAY names,
# so the one thing that keeps a capture off the live desktop is the socket
# handed to it. shot_socket resolves the nested socket and refuses the host
# socket, anything outside the sandbox's runtime dir, and anything that is
# not a socket. shot_dir_under refuses an output directory outside the
# repository's tmp/.
#
# A capture is proved current, not the single frame a hidden nested window
# drew once: `shot` compares each capture with the previous shot's, and a
# shot taken after a visible change must differ from it. It captures until
# two captures in a row match (a settled frame), and takes the last capture
# that differs once SHOT_SETTLE_S passes without one (an animated frame, such
# as an orbiting edge light: a compositor still drawing it is live). A
# capture that never differs from the previous shot is a stale frame and
# fails. A grim that does not return within SHOT_GRIM_TIMEOUT_S means the
# nested compositor drew no frame at all, which the caller reports as 77.
#
# A shot captures the one output SHOT_OUTPUT names, not the whole layout:
# grim captures a layout one output at a time and fails the whole capture
# with `failed to create buffer` on an output with no size, as a headless
# output of the nested compositor is on an NVIDIA host.
#
# Every shot is one line in shots.tsv beside the images: name, sha256 of
# the file, the previous shot's name, `settled` or `animated`, and the
# nested window's state on the host: the word SHOT_WINDOW_READER prints
# when it reads the same before the first capture and after the last,
# `changed` when it does not, `-` when no reader is set. With
# SHOT_WINDOW_REQUIRE set, a shot whose state is another word is refused
# after its capture, its PNG removed and no line written, so every line of
# shots.tsv was taken in that state. With SHOT_HOLD_READER set, a shot after
# whose capture that command reads the held output mode as anything but
# `held` is refused the same way, so no line names a capture of an output
# that left its held mode (shot_held below).

shot_refuse() { # REASON VALUE
  printf 'shot: refused: reason=%s value=%s\n' "$1" "$2" >&2
  return 1
}

# shot_socket RUNTIME_DIR NAME HOST_SOCKET: the nested socket's absolute path.
shot_socket() {
  local rt="$1" name="$2" host="$3" rt_real path host_real
  [[ -n $name && $name != */* && $name != . && $name != .. ]] || { shot_refuse socket-not-a-name "$name"; return 1; }
  [[ -d $rt ]] || { shot_refuse runtime-dir-missing "$rt"; return 1; }
  rt_real="$(readlink -f -- "$rt")"
  path="$(readlink -f -- "$rt/$name")" || { shot_refuse socket-unresolved "$rt/$name"; return 1; }
  [[ -S $path ]] || { shot_refuse not-a-socket "$path"; return 1; }
  host_real="$(readlink -f -- "$host")" || host_real="$host"
  [[ $path != "$host_real" ]] || { shot_refuse host-socket "$path"; return 1; }
  [[ $rt_real != "$(dirname -- "$host_real")" ]] || { shot_refuse host-runtime-dir "$rt_real"; return 1; }
  [[ $(dirname -- "$path") == "$rt_real" ]] || { shot_refuse outside-runtime-dir "$path"; return 1; }
  printf '%s\n' "$path"
}

# shot_dir_under REPO DIR: DIR made and printed as an absolute path, which
# must lie under REPO/tmp/.
shot_dir_under() {
  local root dir
  root="$(readlink -f -- "$1")/tmp"
  mkdir -p -- "$2" || { shot_refuse out-dir-unwritable "$2"; return 1; }
  dir="$(readlink -f -- "$2")"
  [[ $dir == "$root"/* ]] || { shot_refuse out-dir-outside-tmp "$dir"; return 1; }
  printf '%s\n' "$dir"
}

# shot_grim SOCKET RUNTIME_DIR ARGS...: grim with ARGS, alone in an empty
# environment beside SOCKET, which shot_socket gave, within
# SHOT_GRIM_TIMEOUT_S; the status is timeout's, 124 when grim timed out.
shot_grim() {
  timeout "${SHOT_GRIM_TIMEOUT_S:-10}" env -i PATH="$PATH" XDG_RUNTIME_DIR="$2" WAYLAND_DISPLAY="${1##*/}" grim "${@:3}"
}

# shot_pixel SOCKET RUNTIME_DIR X Y: the colour at layout position (X, Y)
# as rrggbb, one pixel grim captures as a binary PPM. A capture that fails,
# times out or is no 1 by 1 PPM prints `pixel=unreadable` and returns 1.
shot_pixel() {
  local out
  out="$(shot_grim "$1" "$2" -g "$3,$4 1x1" -t ppm - 2>/dev/null | python3 -c '
import sys
data = sys.stdin.buffer.read()
head = data.split(b"\n", 3)
if len(head) == 4 and head[:3] == [b"P6", b"1 1", b"255"] and len(head[3]) == 3:
    print(head[3].hex())
')" && [[ $out =~ ^[0-9a-f]{6}$ ]] || { echo "pixel=unreadable"; return 1; }
  printf '%s\n' "$out"
}

shot_last_name=""
shot_last_hash=""

# shot_grab SOCKET RUNTIME_DIR OUTPUT FILE: one capture of OUTPUT, grim
# alone in an empty environment beside the nested socket. Exit 2 when grim
# timed out.
shot_grab() {
  local status=0
  shot_grim "$1" "$2" -o "$3" -t png "$4" >/dev/null 2>>"${4%/*}/grim.log" || status=$?
  [[ $status -eq 0 ]] && return 0
  [[ $status -eq 124 ]] && return 2
  return 1
}

# shot_window: the nested window's host state from SHOT_WINDOW_READER, a
# command the caller sets; `-` when it is unset. A reader that fails keeps
# the word it printed, such as `unreadable`.
shot_window() {
  [[ -n ${SHOT_WINDOW_READER:-} ]] || { echo -; return; }
  $SHOT_WINDOW_READER || true
}

# shot NAME: SHOT_DIR/NAME.png, proved current against the previous shot.
# Needs SHOT_DIR, SHOT_SOCKET, SHOT_RUNTIME_DIR and SHOT_OUTPUT. Returns 1
# for a stale or failed capture or one refused for its window state, 2 when
# grim timed out, 4 when SHOT_HOLD_READER read the hold left after the
# capture; prints what it wrote.
shot() {
  local name="$1" file part hash stable="" last="" kind="" deadline status window_before window_after window hold
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { shot_refuse name "$name"; return 1; }
  [[ -n ${SHOT_OUTPUT:-} ]] || { shot_refuse output-unnamed "$name"; return 1; }
  window_before="$(shot_window)"
  file="$SHOT_DIR/$name.png"
  part="$SHOT_DIR/.$name.part.png"
  deadline=$(( $(date +%s%N) / 1000000 + ${SHOT_SETTLE_S:-5} * 1000 ))
  while :; do
    status=0
    shot_grab "$SHOT_SOCKET" "$SHOT_RUNTIME_DIR" "$SHOT_OUTPUT" "$part" || status=$?
    if [[ $status -ne 0 ]]; then
      rm -f -- "$part"
      printf 'shot: capture-failed name=%s grim-status=%s\n' "$name" "$([[ $status -eq 2 ]] && echo timeout || echo error)" >&2
      return "$status"
    fi
    hash="$(sha256sum -- "$part" | cut -d' ' -f1)"
    if [[ $hash != "$shot_last_hash" ]]; then
      if [[ $hash == "$last" ]]; then kind=settled; stable="$hash"; break; fi
      last="$hash"
      mv -f -- "$part" "$file"
    fi
    if (( $(date +%s%N) / 1000000 >= deadline )); then
      [[ -n $last ]] && { kind=animated; break; }
      rm -f -- "$part"
      printf 'shot: stale name=%s previous=%s sha256=%s\n' "$name" "$shot_last_name" "$hash" >&2
      echo "every capture for ${SHOT_SETTLE_S:-5} s matched the previous shot, so the nested compositor did not draw the change" >&2
      return 1
    fi
    sleep 0.25
  done
  [[ $kind == settled ]] && mv -f -- "$part" "$file"
  rm -f -- "$part"
  window_after="$(shot_window)"
  window="$window_before"
  [[ $window_after == "$window_before" ]] || window=changed
  if [[ -n ${SHOT_WINDOW_REQUIRE:-} && $window != "$SHOT_WINDOW_REQUIRE" ]]; then
    rm -f -- "${file:?}"
    shot_refuse window-state "$window" || true
    printf 'the shot %s needs the nested window %s on the host\n' "$name" "$SHOT_WINDOW_REQUIRE" >&2
    return 1
  fi
  if [[ -n ${SHOT_HOLD_READER:-} ]]; then
    hold="$($SHOT_HOLD_READER)" || hold=unreadable
    if [[ $hold != held ]]; then
      rm -f -- "${file:?}"
      shot_refuse hold-left-after "$hold" || true
      return 4
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "${stable:-$last}" "${shot_last_name:--}" "$kind" "$window" >>"$SHOT_DIR/shots.tsv"
  shot_last_name="$name"
  shot_last_hash="${stable:-$last}"
  printf '  shot  %s (%s, window %s)\n' "$file" "$kind" "$window"
}

# shot_held NAME READER SETTLE: `shot NAME` under a held output mode.
# READER prints the hold's state, `held` while the output reads the held
# mode (held_mode_state in scripts/smoke/mode-hold.sh). SETTLE takes the
# hold again when the output left it, puts the pointer back where the scene
# left it, and returns 0 once the output reads the held mode: a host
# configure of the nested window resets the mode at any moment, and the
# reset stays until a rule takes the mode again. SETTLE runs before the
# capture; one that fails refuses the shot untaken. The capture runs with
# READER as SHOT_HOLD_READER, so `shot` refuses one after which the output
# left the mode, writing no PNG and no line; that capture runs SETTLE again
# and is taken once more. Returns 0 when taken under the hold, 1 when shot
# failed, 2 when grim got no frame (shot's 2), 3 when SETTLE failed, 4
# when the output left the mode during the retaken capture as well.
shot_held() {
  local name="$1" reader="$2" settle="$3" attempt status
  for attempt in 1 2; do
    if ! "$settle"; then
      shot_refuse hold-not-settled "$name" || true
      return 3
    fi
    status=0
    SHOT_HOLD_READER="$reader" shot "$name" || status=$?
    case $status in
      0) return 0 ;;
      2) return 2 ;;
      4) [[ $attempt -eq 2 ]] && return 4
         printf '  retake %s (the output left the held mode during the capture)\n' "$name" ;;
      *) return 1 ;;
    esac
  done
}
