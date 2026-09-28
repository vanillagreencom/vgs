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
# Every shot is one line in shots.tsv beside the images: name, sha256 of
# the file, the previous shot's name, and `settled` or `animated`.

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

shot_last_name=""
shot_last_hash=""

# shot_grab SOCKET RUNTIME_DIR FILE: one capture, grim alone in an empty
# environment beside the nested socket. Exit 2 when grim timed out.
shot_grab() {
  local status=0
  timeout "${SHOT_GRIM_TIMEOUT_S:-10}" env -i PATH="$PATH" XDG_RUNTIME_DIR="$2" WAYLAND_DISPLAY="${1##*/}" \
    grim -t png "$3" >/dev/null 2>>"${3%/*}/grim.log" || status=$?
  [[ $status -eq 0 ]] && return 0
  [[ $status -eq 124 ]] && return 2
  return 1
}

# shot NAME: SHOT_DIR/NAME.png, proved current against the previous shot.
# Needs SHOT_DIR, SHOT_SOCKET and SHOT_RUNTIME_DIR. Returns 1 for a stale
# or failed capture, 2 when grim timed out; prints what it wrote.
shot() {
  local name="$1" file part hash stable="" last="" kind="" deadline status
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { shot_refuse name "$name"; return 1; }
  file="$SHOT_DIR/$name.png"
  part="$SHOT_DIR/.$name.part.png"
  deadline=$(( $(date +%s%N) / 1000000 + ${SHOT_SETTLE_S:-5} * 1000 ))
  while :; do
    status=0
    shot_grab "$SHOT_SOCKET" "$SHOT_RUNTIME_DIR" "$part" || status=$?
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
  printf '%s\t%s\t%s\t%s\n' "$name" "${stable:-$last}" "${shot_last_name:--}" "$kind" >>"$SHOT_DIR/shots.tsv"
  shot_last_name="$name"
  shot_last_hash="${stable:-$last}"
  printf '  shot  %s (%s)\n' "$file" "$kind"
}
