#!/usr/bin/env bash
# Drive scripts/readme-shots.sh --from over synthetic shots, with no
# sandbox. A scratch checkout holds a copy of the script, of the table's
# judge scripts/check-readme-images.py and of scripts/smoke/shot.sh, a
# table of its own, and under its tmp/ a run as scripts/sandbox-shots.sh
# writes one: shots.tsv and 2560x1600 PNGs made with ImageMagick over a
# flat desktop with a 56-row bar band, a clock in the band and a parked
# pointer in the bottom-right corner. Each case pins the exit status and
# the first stderr line; the pass case pins every image's size and WebP
# magic. The controls plant one defect per crop rule in a copy of the
# script and require the case that rule owns to go red.
#
# Exit 0 when every case and control holds, 1 otherwise, 77 without
# ImageMagick.
set -euo pipefail

TMP_ROOT="$(mktemp -d)" || { echo "test-readme-shots: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-readme-shots: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-readme-shots: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
if ! command -v magick >/dev/null 2>&1; then
  echo "test-readme-shots: status=not-measured missing=magick"
  exit 77
fi
failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

checkout="$TMP_ROOT/checkout"
mkdir -p "$checkout/scripts/smoke" "$checkout/docs/images/plugins" "$checkout/tmp"
cp -- "$repo/scripts/check-readme-images.py" "$checkout/scripts/"
cp -- "$repo/scripts/smoke/shot.sh" "$checkout/scripts/smoke/"

# The run. The desktop is #111111 with a black bar band over rows 0 to 55,
# a clock box in the band and a pointer speck in the bottom-right corner.
# Every shot keeps the band but draws its clock one box shorter, so the
# clock differs from the desktop's in every shot, and draws its pointer
# one pixel wider, so the parked pointer differs too.
run_dir="$checkout/tmp/run"
mkdir -p "$run_dir"
bar=(-fill '#000000' -draw 'rectangle 0,0 2559,55')
desk() { magick -size 2560x1600 xc:'#111111' "${bar[@]}" -fill '#eeeeee' -draw 'rectangle 1200,20 1259,35' -fill white -draw 'rectangle 2556,1596 2559,1599' "$@"; }
shot_base=(-size 2560x1600 xc:'#111111' "${bar[@]}" -fill '#eeeeee' -draw 'rectangle 1200,20 1239,35' -fill white -draw 'rectangle 2555,1596 2559,1599')
desk "$run_dir/00-desktop.png"
# panel: a box under the bar, 4 rows below the band. centre: a box in the
# middle. edge: a box on the right and bottom edges. clock: nothing but the
# clock and the pointer.
magick "${shot_base[@]}" -fill '#222222' -draw 'rectangle 2000,60 2399,459' "$run_dir/panel.png"
magick "${shot_base[@]}" -fill '#222222' -draw 'rectangle 1000,600 1399,899' "$run_dir/centre.png"
magick "${shot_base[@]}" -fill '#222222' -draw 'rectangle 2400,1400 2559,1599' "$run_dir/edge.png"
magick "${shot_base[@]}" "$run_dir/clock.png"
magick -size 1280x800 xc:'#111111' "$run_dir/small.png"
magick "${shot_base[@]}" -fill '#222222' -draw 'rectangle 1000,600 1399,899' "$run_dir/shown.png"
for name in 00-desktop panel centre edge clock small; do printf '%s\tsha\tprev\tsettled\thidden\n' "$name"; done >"$run_dir/shots.tsv"
printf 'shown\tsha\tprev\tsettled\tshown\n' >>"$run_dir/shots.tsv"
# A run whose desktop has no bar band.
flat_dir="$checkout/tmp/flat"
mkdir -p "$flat_dir"
magick -size 2560x1600 xc:'#111111' "$flat_dir/00-desktop.png"
cp -- "$run_dir/centre.png" "$flat_dir/"
printf '00-desktop\ts\tp\tsettled\thidden\ncentre\ts\tp\tsettled\thidden\n' >"$flat_dir/shots.tsv"

# The table each case runs over: image, shot and crop per row, the scene
# being no concern of --from.
table() { # ROW...
  local row
  printf 'image\tscene\tshot\tcrop\n'
  for row; do IFS=' ' read -r image shot crop <<<"$row"; printf '%s\tscene\t%s\t%s\n' "$image" "$shot" "$crop"; done
}
pass_rows=(
  "p.full.webp centre full"
  "p.bar.webp clock bar"
  "p.panel.webp panel content"
  "p.centre.webp centre content"
  "p.edge.webp edge content"
)
# Expected sizes: the band is 56 rows, the margin 32 px. The panel's box
# starts 4 rows under the band, within the margin, so it runs from the top
# edge; the centre's box grows by 32 a side; the edge's box is clamped on
# the right and the bottom.
# In the order the directory's glob lists them.
pass_sizes="p.bar.webp 2560x56
p.centre.webp 464x364
p.edge.webp 192x232
p.full.webp 2560x1600
p.panel.webp 464x492"

# run_tool SCRIPT TABLE_TEXT ARG...: SCRIPT as the checkout's
# scripts/readme-shots.sh over TABLE_TEXT, in an environment holding PATH
# alone; sets status, out and err_line.
run_tool() {
  local script="$1" table_text="$2"
  shift 2
  cp -- "$script" "$checkout/scripts/readme-shots.sh"
  printf '%s\n' "$table_text" >"$checkout/docs/images/plugins/shots.tsv"
  status=0
  env -i PATH="$PATH" HOME="$TMP_ROOT" bash "$checkout/scripts/readme-shots.sh" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || status=$?
  err_line="$(head -n 1 -- "$TMP_ROOT/err")"
}

# The sizes of the images written under DIR, one `name WxH` line each,
# every one checked WebP by its magic bytes.
sizes_in() {
  local file
  for file in "$1"/*.webp; do
    [[ $(head -c 4 -- "$file") == RIFF && $(head -c 12 -- "$file" | tail -c 4) == WEBP ]] || { echo "$(basename -- "$file") not-webp"; continue; }
    printf '%s %s\n' "$(basename -- "$file")" "$(magick identify -format '%wx%h' "$file")"
  done
}

# pass_case SCRIPT: whether SCRIPT writes every pass row at its size.
pass_case() {
  local out_dir="$checkout/tmp/out-$RANDOM$RANDOM"
  run_tool "$1" "$(table "${pass_rows[@]}")" --from "$run_dir" --out "$out_dir"
  [[ $status -eq 0 && $(sizes_in "$out_dir") == "$pass_sizes" ]] && return 0
  echo "        pass: exit=$status first stderr line: $err_line sizes: $(sizes_in "$out_dir" | tr '\n' ' ')"
  return 1
}
if pass_case "$repo/scripts/readme-shots.sh"; then ok "every crop is cut at its size and written as WebP"; else fail "every crop is cut at its size and written as WebP"; fi

# Refusal cases, four fields each: label, table rows (;-separated), the
# arguments, the exit status and the first stderr line. OUT is a fresh
# directory under the checkout's tmp/.
out_ok="$checkout/tmp/out-refusals"
cases=(
  "an unknown argument is refused" "p.a.webp centre full" "--bogus" 2 "readme-shots: refused: argument=--bogus"
  "an --out outside tmp/ is refused" "p.a.webp centre full" "--from $run_dir --out $TMP_ROOT/elsewhere" 1 "readme-shots: refused: out=$TMP_ROOT/elsewhere"
  "a malformed table is refused" "p.a.webp centre zoom" "--from $run_dir --out $out_ok" 1 "readme-shots: refused: table=docs/images/plugins/shots.tsv"
  "a run without shots.tsv is refused" "p.a.webp centre full" "--from $checkout/tmp --out $out_ok" 1 "readme-shots: refused: from=$checkout/tmp"
  "a shot the run lacks is refused" "p.a.webp absent full" "--from $run_dir --out $out_ok" 1 "readme-shots: refused: shot=absent"
  "a shot taken with the window shown is refused" "p.a.webp shown full" "--from $run_dir --out $out_ok" 1 "readme-shots: refused: shot-window=shown"
  "a shot of another size is refused" "p.a.webp small full" "--from $run_dir --out $out_ok" 1 "readme-shots: refused: shot-size=small"
  "a desktop with no bar band is refused" "p.a.webp centre full" "--from $flat_dir --out $out_ok" 1 "readme-shots: refused: bar=$flat_dir/00-desktop.png"
  "a content crop with nothing below the band is refused" "p.a.webp clock content" "--from $run_dir --out $out_ok" 1 "readme-shots: refused: crop-empty=clock"
)
declare -A case_at
for (( i = 0; i < ${#cases[@]}; i += 5 )); do
  label="${cases[i]}"; case_at[$label]=$i
  IFS=';' read -r -a rows <<<"${cases[i + 1]}"
  read -r -a args <<<"${cases[i + 2]}"
  run_tool "$repo/scripts/readme-shots.sh" "$(table "${rows[@]}")" "${args[@]}"
  if [[ $status -eq ${cases[i + 3]} && $err_line == "${cases[i + 4]}" ]]; then ok "$label"; else fail "$label: exit=$status first stderr line: $err_line"; fi
done

# Controls, four fields each: label, the text, which must match once, its
# replacement, and the case that goes red: `pass` for the pass case, else a
# refusal case's label, whose status and line must then differ.
controls=(
  "a box near the band is not taken from the top edge"
  'top=$(( y - MARGIN_PX <= band ? 0 : y - MARGIN_PX ))' 'top=$(( y - MARGIN_PX < 0 ? 0 : y - MARGIN_PX ))'
  pass
  "the box is read from the top row, the clock's band included"
  'python3 -c "$mask_program" box "$band"' 'python3 -c "$mask_program" box 0'
  pass
  "the parked pointer's corner is read"
  '-fill black -draw "rectangle $((width - POINTER_PX)),$((height - POINTER_PX)) $width,$height"' '-fill black'
  pass
  "an empty content crop falls back to the whole output"
  '[[ $box != none ]] || stop crop-empty "$shot"' '[[ $box != none ]] || box="0 0 $width $height"'
  "a content crop with nothing below the band is refused"
)
mutant="$TMP_ROOT/readme-shots-mutant.sh"
for (( i = 0; i < ${#controls[@]}; i += 4 )); do
  label="${controls[i]}"; target="${controls[i + 3]}"
  if ! python3 -c '
import sys
src, dst, needle, replacement = sys.argv[1:]
text = open(src).read()
assert text.count(needle) == 1, "the planted text must match once"
open(dst, "w").write(text.replace(needle, replacement))' "$repo/scripts/readme-shots.sh" "$mutant" "${controls[i + 1]}" "${controls[i + 2]}"; then
    fail "control: $label could not be planted"
    continue
  fi
  if [[ $target == pass ]]; then
    if pass_case "$mutant" >/dev/null; then fail "control: $label left the crops at their sizes"; else ok "control: $label"; fi
    continue
  fi
  if [[ -z ${case_at[$target]+set} ]]; then fail "control: $label names no case: $target"; continue; fi
  at=${case_at[$target]}
  IFS=';' read -r -a rows <<<"${cases[at + 1]}"
  read -r -a args <<<"${cases[at + 2]}"
  run_tool "$mutant" "$(table "${rows[@]}")" "${args[@]}"
  if [[ $status -eq ${cases[at + 3]} && $err_line == "${cases[at + 4]}" ]]; then fail "control: $label still gave '$target'"; else ok "control: $label"; fi
done

if [[ $failures -gt 0 ]]; then
  echo "test-readme-shots: failures=$failures"
  exit 1
fi
echo "test-readme-shots: ok"
