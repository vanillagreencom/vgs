#!/usr/bin/env bash
# Drive scripts/smoke/shot.sh, the sandbox capture helpers, with no
# sandbox: plain Unix sockets stand in for the host and nested Wayland
# sockets, and a stub grim on PATH writes the image each case needs. Each
# case pins the exit status and the first line on stderr. The controls at
# the end plant one defect per guard in a copy of the file and require the
# case that guard owns to go red.
#
# Exit 0 when every case and control holds, 1 otherwise.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
helper="$repo/scripts/smoke/shot.sh"

# The EXIT trap is armed only on the directory mktemp made: an empty or
# non-directory answer never reaches rm -rf.
tmp="$(mktemp -d)" || { echo "test-sandbox-shots: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $tmp && ! -L $tmp ]] || { echo "test-sandbox-shots: scratch=not-a-directory value=[$tmp]" >&2; exit 1; }
tmp="$(cd -- "$tmp" && pwd -P)"
trap 'rm -rf -- "${tmp:?}"' EXIT
failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# The host's runtime dir with its socket, and the sandbox's beneath it, as
# the harness makes them.
host="$tmp/run"; rt="$host/vs.test"
mkdir -p "$rt" "$tmp/bin" "$tmp/checkout/tmp"
python3 - "$host/wayland-1" "$host/wayland-2" "$rt/wayland-1" <<'PY'
import socket, sys
for path in sys.argv[1:]:
    socket.socket(socket.AF_UNIX).bind(path)
PY
ln -s "$host/wayland-1" "$rt/wayland-9"
: >"$rt/wayland-file"

# The stub grim: the mode file beside it picks what it writes to its last
# argument, since shot.sh runs grim in an empty environment. fixed-a and
# fixed-b write one image each time; counter writes a new one each call;
# hang never returns. It records its environment in env.log beside it.
cat >"$tmp/bin/grim" <<'SH'
#!/usr/bin/env bash
out="${!#}"
here="${0%/*}"
env | sort >"$here/env.log"
case "$(cat "$here/mode")" in
  fixed-a) printf 'image-a' >"$out" ;;
  fixed-b) printf 'image-b' >"$out" ;;
  counter) n=$(( $(cat "$here/count" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$here/count"; printf 'image-%s' "$n" >"$out" ;;
  hang) sleep 5 ;;
esac
SH
chmod 755 "$tmp/bin/grim"
hash_a="$(printf 'image-a' | sha256sum | cut -d' ' -f1)"

# run_case FILE LABEL SNIPPET STATUS LINE: true when the helper FILE gives
# the status and first stderr line. The snippet runs with the helper
# sourced, in an empty environment holding a marker that must never reach
# grim: T the test dir, RT the sandbox's runtime dir, HOST the host's, D
# an empty dir under the checkout's tmp/, and SHOT_DIR, SHOT_SOCKET and
# SHOT_RUNTIME_DIR set for `shot`.
run_case() {
  local file="$1" label="$2" snippet="$3" want_status="$4" want_line="$5" err status=0 dir
  dir="$tmp/checkout/tmp/case-$RANDOM$RANDOM"
  mkdir -p "$dir"
  env -i PATH="$tmp/bin:$PATH" HOST_MARKER=live T="$tmp" RT="$rt" HOST="$host" D="$dir" HASH_A="$hash_a" \
    SHOT_DIR="$dir" SHOT_SOCKET="$rt/wayland-1" SHOT_RUNTIME_DIR="$rt" \
    bash -c 'set -euo pipefail; source "$1"; eval "$2"' _ "$file" "$snippet" >"$dir/out" 2>"$dir/err" || status=$?
  err="$(head -n 1 "$dir/err")"
  [[ $status -eq $want_status && $err == "$want_line" ]] && return 0
  printf '        %s: status=%s want=%s first stderr line: %s\n' "$label" "$status" "$want_status" "$err"
  return 1
}

# Cases, four fields each: label, snippet, status, first stderr line.
cases=(
  "the nested socket resolves"
  '[[ $(shot_socket "$RT" wayland-1 "$HOST/wayland-1") == "$RT/wayland-1" ]]' 0 ""
  "the host socket is refused"
  'shot_socket "$HOST" wayland-1 "$HOST/wayland-1"' 1 "shot: refused: reason=host-socket value=$host/wayland-1"
  "a link to the host socket is refused"
  'shot_socket "$RT" wayland-9 "$HOST/wayland-1"' 1 "shot: refused: reason=host-socket value=$host/wayland-1"
  "the host's runtime dir is refused"
  'shot_socket "$HOST" wayland-2 "$HOST/wayland-1"' 1 "shot: refused: reason=host-runtime-dir value=$host"
  "a path for a socket name is refused"
  'shot_socket "$RT" ../wayland-1 "$HOST/wayland-1"' 1 "shot: refused: reason=socket-not-a-name value=../wayland-1"
  "a file that is no socket is refused"
  'shot_socket "$RT" wayland-file "$HOST/wayland-1"' 1 "shot: refused: reason=not-a-socket value=$rt/wayland-file"
  "an output dir under tmp/ is made"
  '[[ $(shot_dir_under "$T/checkout" "$T/checkout/tmp/shots/a") == "$T/checkout/tmp/shots/a" ]]' 0 ""
  "an output dir outside tmp/ is refused"
  'shot_dir_under "$T/checkout" "$T/elsewhere"' 1 "shot: refused: reason=out-dir-outside-tmp value=$tmp/elsewhere"
  "a new settled capture is taken"
  'echo fixed-b >"$T/bin/mode"; shot one >/dev/null; want="$(printf "one\t%s\t-\tsettled" "$(printf image-b | sha256sum | cut -d" " -f1)")"; [[ $(cat "$D/shots.tsv") == "$want" && $(cat "$D/one.png") == image-b ]]' 0 ""
  "a capture equal to the previous shot is stale"
  'echo fixed-a >"$T/bin/mode"; shot_last_name=before; shot_last_hash="$HASH_A"; SHOT_SETTLE_S=1 shot two' 1 "shot: stale name=two previous=before sha256=$hash_a"
  "a capture that keeps changing is taken as animated"
  'echo counter >"$T/bin/mode"; SHOT_SETTLE_S=1 shot three >/dev/null; [[ $(cut -f1,4 "$D/shots.tsv") == $(printf "three\tanimated") ]]' 0 ""
  "a grim that never returns reads as no frame"
  'echo hang >"$T/bin/mode"; SHOT_GRIM_TIMEOUT_S=1 shot four' 2 "shot: capture-failed name=four grim-status=timeout"
  "grim sees only the nested socket"
  'echo fixed-b >"$T/bin/mode"; shot five >/dev/null; grep -qx WAYLAND_DISPLAY=wayland-1 "$T/bin/env.log"; grep -qx "XDG_RUNTIME_DIR=$RT" "$T/bin/env.log"; ! grep -q HOST_MARKER "$T/bin/env.log"' 0 ""
)
for (( i = 0; i < ${#cases[@]}; i += 4 )); do
  if run_case "$helper" "${cases[@]:i:4}"; then ok "${cases[i]}"; else fail "${cases[i]}"; fi
done

# mutate OLD NEW OUT: a copy of the helper with OLD, which must occur once,
# replaced by NEW.
mutate() {
  local text rest count
  text="$(<"$helper")"
  rest="${text//"$1"/}"
  count=$(( (${#text} - ${#rest}) / ${#1} ))
  if [[ $count -ne 1 ]]; then
    printf '        mutation matched %s times: %s\n' "$count" "$1"
    return 1
  fi
  printf '%s\n' "${text/"$1"/"$2"}" >"$3"
  cmp -s -- "$helper" "$3" && { printf '        mutation left the file unchanged: %s\n' "$1"; return 1; }
  return 0
}

# Controls, four fields each: label, text, replacement, and the case that
# must go red.
controls=(
  "the host socket is not compared"
  '[[ $path != "$host_real" ]] ||' 'true ||' "a link to the host socket is refused"
  "the host's runtime dir is not compared"
  '[[ $rt_real != "$(dirname -- "$host_real")" ]] ||' 'true ||' "the host's runtime dir is refused"
  "a socket name may be a path"
  '[[ -n $name && $name != */* && $name != . && $name != .. ]] ||' '[[ -n $name ]] ||' "a path for a socket name is refused"
  "the output dir may lie outside tmp/"
  '[[ $dir == "$root"/* ]] ||' 'true ||' "an output dir outside tmp/ is refused"
  "a capture is not compared with the previous shot"
  'if [[ $hash != "$shot_last_hash" ]]; then' 'if true; then' "a capture equal to the previous shot is stale"
  "a grim timeout reads as an error"
  '[[ $status -eq 124 ]] && return 2' 'true' "a grim that never returns reads as no frame"
  "grim inherits the caller's environment"
  'env -i PATH="$PATH"' 'env PATH="$PATH"' "grim sees only the nested socket"
)
for (( i = 0; i < ${#controls[@]}; i += 4 )); do
  label="${controls[i]}"; target="${controls[i + 3]}"
  mutant="$tmp/mutant-$i.sh"
  if ! mutate "${controls[i + 1]}" "${controls[i + 2]}" "$mutant"; then fail "control: $label"; continue; fi
  row=()
  for (( j = 0; j < ${#cases[@]}; j += 4 )); do [[ ${cases[j]} == "$target" ]] && row=("${cases[@]:j:4}"); done
  if [[ ${#row[@]} -eq 0 ]]; then fail "control: $label names no case: $target"; continue; fi
  if run_case "$mutant" "${row[@]}" >/dev/null; then fail "control: $label left '$target' green"; else ok "control: $label"; fi
done

if [[ $failures -gt 0 ]]; then
  echo "test-sandbox-shots: failed=$failures"
  exit 1
fi
echo "test-sandbox-shots: ok"
