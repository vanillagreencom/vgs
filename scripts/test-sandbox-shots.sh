#!/usr/bin/env bash
# Drive scripts/smoke/shot.sh, the sandbox capture helpers, with no
# sandbox: plain Unix sockets stand in for the host and nested Wayland
# sockets, and a stub grim on PATH writes the image each case needs. Each
# case pins the exit status and the first line on stderr. The controls at
# the end plant one defect per guard in a copy of the file and require the
# case that guard owns to go red. The scene cases drive
# scripts/sandbox-shots.sh itself up to its harness, in a scratch git
# repository, and the export cases drive scripts/smoke/tree.sh, which
# sandbox-shots.sh and the harness share.
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

# The scene choice of scripts/sandbox-shots.sh, before any sandbox starts:
# a tree ships either the Settings plugin or the bar's manager built-in, and
# a scene the tree does not ship is refused with exit 2. A scratch git
# repository holds the script, a link to the smoke directory, a revision
# with the bar's manager and a later one with vgs.settings, so --rev reads
# an older tree. A scene the tree ships passes the choice and reaches the
# harness, which, with no Wayland socket in the environment, exits 77.
shots_repo="$tmp/shots-repo"
mkdir -p "$shots_repo/scripts" "$shots_repo/shell/plugins/vgs.bar" "$shots_repo/bin" "$shots_repo/config" "$shots_repo/themes" "$shots_repo/tmp"
ln -s "$repo/scripts/smoke" "$shots_repo/scripts/smoke"
: >"$shots_repo/shell/plugins/vgs.bar/Manager.qml"; : >"$shots_repo/bin/vgsh"; : >"$shots_repo/config/shell.json"; : >"$shots_repo/themes/.keep"
git_quiet() { git -C "$shots_repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null; }
git_quiet init -q
git_quiet add shell bin config themes
git_quiet commit -q -m manager
old_rev="$(git -C "$shots_repo" rev-parse HEAD)"
mkdir -p "$shots_repo/shell/plugins/vgs.settings"
: >"$shots_repo/shell/plugins/vgs.settings/manifest.json"
git -C "$shots_repo" rm -q shell/plugins/vgs.bar/Manager.qml
git_quiet add shell
git_quiet commit -q -m settings
# scene_case SCRIPT LABEL STATUS LINE ARG...: SCRIPT run from the scratch
# repository gives STATUS and LINE on stderr, or with STATUS 77 a stdout
# line starting LINE.
scene_case() {
  local script="$1" label="$2" want_status="$3" want_line="$4" status=0 out err
  shift 4
  cp -- "$script" "$shots_repo/scripts/sandbox-shots.sh"
  out="$(env -i PATH="$tmp/bin:$PATH" HOME="$tmp" bash "$shots_repo/scripts/sandbox-shots.sh" --out "$shots_repo/tmp/shots-$RANDOM$RANDOM" "$@" 2>"$tmp/scene.err")" || status=$?
  err="$(head -n 1 "$tmp/scene.err")"
  if [[ $status -eq $want_status && ( $err == "$want_line" || ( $want_status -eq 77 && $out == "$want_line"* ) ) ]]; then return 0; fi
  echo "$label: exit=$status stderr=$err stdout=$(head -n 1 <<<"$out")"
  return 1
}
scene_cases=(
  "a checkout with the Settings plugin refuses the manager scene" 2 "sandbox-shots: refused: scene=manager tree=checkout" manager
  "a revision before the Settings plugin refuses the settings scene" 2 "sandbox-shots: refused: scene=settings tree=$old_rev" --rev "$old_rev" settings
  "a revision before the Settings plugin takes the manager scene" 77 "qml-smoke: status=not-measured" --rev "$old_rev" manager
  "a checkout with the Settings plugin takes the settings scene" 77 "qml-smoke: status=not-measured" settings
  "a scale other than 1 or 2 is refused" 2 "sandbox-shots: refused: scale=3" --scale 3 settings
  "scale 2 is taken" 77 "qml-smoke: status=not-measured" --scale 2 settings
)
# Each case is label, status, line, then its arguments up to the next case,
# counted by the arguments each row above carries.
scene_arity=(1 3 3 1 3 3)
at=0
for n in "${!scene_arity[@]}"; do
  label="${scene_cases[at]}"; status="${scene_cases[at + 1]}"; line="${scene_cases[at + 2]}"
  args=("${scene_cases[@]:at + 3:${scene_arity[n]}}")
  at=$((at + 3 + ${scene_arity[n]}))
  if scene_case "$repo/scripts/sandbox-shots.sh" "$label" "$status" "$line" "${args[@]}"; then ok "$label"; else fail "$label"; fi
done
# Controls: a copy with one refusal planted away sends the refused case on
# to the harness. Rows: label | the refusal's text, which must match once |
# its replacement | the refusal line the case wants | the case's arguments,
# split on spaces. A field holds no `|`, the separator.
shots_controls=(
  "an unshipped scene is not refused|if [[ (\$scene == settings || \$scene == manager) && \$scene != \"\$manager_scene\" ]]; then|if false; then|sandbox-shots: refused: scene=manager tree=checkout|manager"
  "a refused scale goes on to the harness|refused: scale=%s\\n' \"\$scale\" >&2; exit 2; }|refused: scale=%s\\n' \"\$scale\" >&2; }|sandbox-shots: refused: scale=3|--scale 3 settings"
)
shots_mutant="$tmp/sandbox-shots-mutant.sh"
for row in "${shots_controls[@]}"; do
  IFS='|' read -r label needle replacement line case_args <<<"$row"
  read -r -a args <<<"$case_args"
  if python3 -c '
import sys
src, dst, needle, replacement = sys.argv[1:]
text = open(src).read()
assert text.count(needle) == 1, "the refusal must match once"
open(dst, "w").write(text.replace(needle, replacement))' "$repo/scripts/sandbox-shots.sh" "$shots_mutant" "$needle" "$replacement"; then
    if scene_case "$shots_mutant" "control" 2 "$line" "${args[@]}" >/dev/null; then fail "control: $label left the refusal case green"; else ok "control: $label"; fi
  else
    fail "control: $label could not be planted"
  fi
done

# The export of another revision, scripts/smoke/tree.sh, with no sandbox. A
# scratch repository holds a revision whose bin/judge loads
# scripts/qml-library.js and a later one that moved the helper to bin/lib,
# as this checkout did. export_case exports REV as sandbox-shots.sh does,
# copies the later checkout's scripts/ and then overlays the export's
# helpers as the harness does, and runs the copied bin/judge under node,
# which prints which helper it loaded.
helper_repo="$tmp/helper-repo"
mkdir -p "$helper_repo/bin" "$helper_repo/scripts" "$helper_repo/shell" "$helper_repo/config" "$helper_repo/themes"
printf 'module.exports = { where: "scripts" };\n' >"$helper_repo/scripts/qml-library.js"
printf 'process.stdout.write(require(require("path").join(__dirname, "..", "scripts", "qml-library.js")).where);\n' >"$helper_repo/bin/judge"
: >"$helper_repo/shell/shell.qml"; : >"$helper_repo/config/shell.json"; : >"$helper_repo/themes/.keep"
helper_git() { git -C "$helper_repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null; }
helper_git init -q
helper_git add -A
helper_git commit -q -m before
before_rev="$(git -C "$helper_repo" rev-parse HEAD)"
mkdir -p "$helper_repo/bin/lib"
helper_git mv scripts/qml-library.js bin/lib/qml-library.js
printf 'module.exports = { where: "bin/lib" };\n' >"$helper_repo/bin/lib/qml-library.js"
printf 'process.stdout.write(require(require("path").join(__dirname, "lib", "qml-library.js")).where);\n' >"$helper_repo/bin/judge"
printf 'true\n' >"$helper_repo/scripts/validate"
helper_git add -A
helper_git commit -q -m after
after_rev="$(git -C "$helper_repo" rev-parse HEAD)"
# export_case LIB REV WANT: with tree.sh at LIB, REV's copied bin/judge
# prints WANT.
export_case() {
  local lib="$1" rev="$2" want="$3" dir target out status=0
  dir="$(mktemp -d "$tmp/export.XXXXXX")" && target="$(mktemp -d "$tmp/copy.XXXXXX")" || return 1
  out="$(
    source "$lib"
    tree_export "$helper_repo" "$rev" "$dir" || { echo "tree_export failed"; exit 1; }
    cp -R -- "$dir/bin" "$target/bin"
    cp -R -- "$helper_repo/scripts" "$target/scripts"
    tree_overlay_helpers "$dir" "$target"
    node "$target/bin/judge" 2>&1
  )" || status=$?
  [[ $status -eq 0 && $out == "$want" ]] && return 0
  echo "exit=$status out=$(head -n 1 <<<"$out")"
  return 1
}
export_cases=(
  "a revision before bin/lib runs its own helper from scripts/|$before_rev|scripts"
  "a revision after bin/lib exports no helper and runs its own|$after_rev|bin/lib"
)
for spec in "${export_cases[@]}"; do
  IFS='|' read -r label rev want <<<"$spec"
  if export_case "$repo/scripts/smoke/tree.sh" "$rev" "$want"; then ok "$label"; else fail "$label"; fi
done

# The harness copy accepts a tree_export that contains only shell, bin,
# config, themes and any legacy runtime helper. Installer-only files come
# from this checkout. This is the real copy helper scripts/smoke/harness.sh
# calls before it mutates the sandbox copy.
harness_copy_case() { # LIB
  local lib="$1" dir target out status=0
  dir="$tmp/harness-export"; target="$tmp/harness-copy"
  rm -rf -- "$dir" "$target"
  mkdir -p -- "$dir" "$target"
  out="$({
    source "$lib"
    tree_export "$helper_repo" "$before_rev" "$dir" || { echo "tree_export failed"; exit 1; }
    tree_harness_copy "$repo" "$target" "$dir"
    [[ -e "$target/packaging/install-system.sh" ]] || { echo "packaging missing"; exit 1; }
    [[ -e "$target/scripts/qml-smoke.sh" ]] || { echo "scripts missing"; exit 1; }
    cmp -s -- "$repo/VERSION" "$target/VERSION" || { echo "VERSION fallback missing"; exit 1; }
    cmp -s -- "$repo/LICENSE" "$target/LICENSE" || { echo "LICENSE fallback missing"; exit 1; }
    cmp -s -- "$repo/README.md" "$target/README.md" || { echo "README fallback missing"; exit 1; }
    echo ok
  } 2>&1)" || status=$?
  [[ $status -eq 0 && $out == ok ]] && return 0
  echo "exit=$status out=$(head -n 1 <<<"$out")"
  return 1
}
if harness_copy_case "$repo/scripts/smoke/tree.sh"; then ok "the harness copy accepts a tree_export without installer files"; else fail "the harness copy accepts a tree_export without installer files"; fi
copy_mutant="$tmp/tree-copy-mutant.sh"
if python3 - "$repo/scripts/smoke/tree.sh" "$copy_mutant" <<'PY'
import sys
src, dst = sys.argv[1:]
text = open(src).read()
needle = 'shutil.copytree(source / "packaging", target / "packaging")'
assert text.count(needle) == 1, "the harness copy packaging fallback must match once"
open(dst, "w").write(text.replace(needle, 'shutil.copytree(tree / "packaging", target / "packaging")'))
PY
then
  if harness_copy_case "$copy_mutant" >/dev/null; then fail "control: the old unconditional harness copy stayed green"; else ok "control: the old unconditional harness copy fails on a tree_export"; fi
else
  fail "control: the old unconditional harness copy could not be planted"
fi

# Controls, one per rule: a copy of tree.sh that exports no helper, and one
# that overlays nothing, each leave the older revision without its helper.
tree_controls=(
  "the export carries no helper|tree_runtime_helpers=(scripts/qml-library.js scripts/check-manifests.js)|tree_runtime_helpers=(scripts/no-helper.js)"
  "the copy takes no helper|  cp -R -- \"\$tree/scripts/.\" \"\$target/scripts/\"|  :"
)
for spec in "${tree_controls[@]}"; do
  IFS='|' read -r label needle replacement <<<"$spec"
  tree_mutant="$tmp/tree-mutant.sh"
  if python3 - "$repo/scripts/smoke/tree.sh" "$tree_mutant" "$needle" "$replacement" <<'PY'
import sys
src, dst, needle, replacement = sys.argv[1:]
text = open(src).read()
assert text.count(needle) == 1, "the control's needle must match once"
open(dst, "w").write(text.replace(needle, replacement))
PY
  then
    if export_case "$tree_mutant" "$before_rev" scripts >/dev/null; then fail "control: $label left the older revision green"; else ok "control: $label"; fi
  else
    fail "control: $label could not be planted"
  fi
done

# The harness names a missing ImageMagick among its prerequisites, since the
# notifications row and the Slack scene draw converted emoji: with no tool
# on PATH its not-measured line lists magick, and a copy without the check
# leaves it out.
# harness_missing HARNESS: the harness's missing list with an empty PATH.
harness_missing() {
  local out status=0
  out="$(env -i PATH="$tmp/no-tools" HOME="$tmp" "$BASH" -c 'repo="$1"; source "$2"' _ "$repo" "$1" 2>/dev/null)" || status=$?
  [[ $status -eq 77 ]] || { echo "exit=$status"; return; }
  sed -n 's/^qml-smoke: status=not-measured missing=//p' <<<"$out"
}
mkdir -p "$tmp/no-tools"
has_magick() { tr ',' '\n' <<<"$1" | grep -qx magick; }
got="$(harness_missing "$repo/scripts/smoke/harness.sh")"
if has_magick "$got"; then ok "the harness names a missing ImageMagick"; else fail "the harness names a missing ImageMagick: got $got"; fi
harness_mutant="$tmp/harness-mutant.sh"
needle='|| missing+=("magick")'
if [[ $(grep -cF -- "$needle" "$repo/scripts/smoke/harness.sh") -eq 1 ]]; then
  text="$(<"$repo/scripts/smoke/harness.sh")"
  printf '%s\n' "${text/"$needle"/|| true}" >"$harness_mutant"
  got="$(harness_missing "$harness_mutant")"
  if has_magick "$got"; then fail "control: a harness without the ImageMagick check still names it"; else ok "control: a harness without the ImageMagick check leaves it out"; fi
else
  fail "control: the ImageMagick check could not be planted"
fi

if [[ $failures -gt 0 ]]; then
  echo "test-sandbox-shots: failed=$failures"
  exit 1
fi
echo "test-sandbox-shots: ok"
