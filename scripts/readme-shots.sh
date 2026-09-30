#!/usr/bin/env bash
# Make the screenshots the first-party plugin READMEs show, from the one
# table docs/images/plugins/shots.tsv.
#
# Usage: scripts/readme-shots.sh [--from DIR] [--out DIR]
#
# Each table row names an image under docs/images/plugins/, the
# scripts/sandbox-shots.sh scene and shot it is cut from, and its crop.
# scripts/check-readme-images.py --table judges the table and hands this
# script its rows. Each crop is measured on the shot at its device pixels,
# against 00-desktop.png, the bare desktop the run takes first, whose
# bottom-left pixel is the desktop's colour:
#   full     the whole output.
#   bar      the bar band at full width: from the top through the last row
#            of the first run of rows of 00-desktop.png that differ from the
#            desktop's colour.
#   content  the box of the pixels below the bar band that differ from
#            00-desktop.png, grown by MARGIN_PX on every side and clamped
#            to the output, and taken from the top edge when the grown box
#            reaches the bar band, so a panel that drops from the bar shows
#            the bar above it. Below the band, the ticking clock never
#            widens the box. The bottom-right POINTER_PX square is left
#            out: the scenes park the pointer 2 logical pixels from that
#            corner (park_pointer in scripts/sandbox-shots.sh), and the
#            shape it shows there differs from shot to shot.
# A crop that finds no bar band or no content is refused, never widened to
# the whole output. Each image is encoded as WebP with WEBP_OPTIONS and no
# metadata.
#
# Without --from it runs scripts/sandbox-shots.sh --hidden --scale 2
# --modes dark --size 1280x800 over the table's scenes into
# tmp/readme-shots/<UTC time>, and exits with its status when that is not
# 0, so a sandbox that could not run (77) never passes. --from DIR reads a
# sandbox-shots directory instead. Every shot the table names, and
# 00-desktop.png, must be in DIR, listed in its shots.tsv as taken with the
# nested window hidden, and OUTPUT_SIZE. --out DIR writes the images there
# in place of docs/images/plugins/; it must lie under this checkout's tmp/
# (shot_dir_under in scripts/smoke/shot.sh).
#
# Each image written prints `readme-shots: wrote=<path> bytes=<n>
# size=<WxH>`. A refusal is one line `readme-shots: refused: <key>=<value>`
# on stderr, then its explanation; the keys and their exit codes are
# stop's table below. A missing ImageMagick prints
# `readme-shots: status=not-measured missing=magick` and exits 77.
# ImageMagick failing on a shot prints `readme-shots: failed: measure=` or
# `encode=` and the shot or image, and exits 1.
set -euo pipefail

# The capture every image is cut from: 1280 by 800 logical pixels at scale
# 2, so text is drawn at device pixels and every image shares one scale.
SHOTS_ARGS=(--hidden --scale 2 --modes dark --size 1280x800)
OUTPUT_SIZE=2560x1600
# 16 logical pixels at scale 2, the design system's space.xl, around a
# content crop.
MARGIN_PX=32
# 16 logical pixels at scale 2. The parked pointer's hotspot sits 2 logical
# pixels inside the corner, and the square keeps out any part of its image
# up to 14 logical pixels left of or above the hotspot. In the runs on host
# cachy on 2026-09-30 it drew within 4 device pixels of the corner.
POINTER_PX=32
# Lossy WebP at quality 85, the slowest and smallest method, with sharp
# RGB-to-YUV conversion so thin coloured text keeps its colour; the
# measurement that chose it is docs/architecture/readme-images.md
# § Encoding.
WEBP_OPTIONS=(-quality 85 -define webp:method=6 -define webp:use-sharp-yuv=true)

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
images_dir="$repo/docs/images/plugins"

# stop KEY VALUE [DETAIL]: the refusal's or failure's line, its
# explanation, DETAIL when given, and its exit.
stop() {
  local message status=1 class=refused
  case $1 in
    argument) message="usage: scripts/readme-shots.sh [--from DIR] [--out DIR]"; status=2 ;;
    out) message="--out must name a directory under this checkout's tmp/" ;;
    table) message="scripts/check-readme-images.py --table refused the table" ;;
    from) message="--from must name a scripts/sandbox-shots.sh directory holding shots.tsv and 00-desktop.png" ;;
    shot) message="the table names this shot and the run holds no such PNG" ;;
    shot-window) message="the run's shots.tsv does not list this shot as taken with the nested window hidden: run scripts/sandbox-shots.sh with --hidden" ;;
    shot-size) message="every shot must be $OUTPUT_SIZE: run scripts/sandbox-shots.sh with ${SHOTS_ARGS[*]}" ;;
    bar) message="00-desktop.png has no row at its top that differs from the desktop's colour" ;;
    crop-empty) message="no pixel below the bar band differs from 00-desktop.png" ;;
    measure) message="ImageMagick could not measure the shot"; class=failed ;;
    encode) message="ImageMagick could not crop and encode the image"; class=failed ;;
    *) message="readme-shots: internal: the key has no message" ;;
  esac
  printf 'readme-shots: %s: %s=%s\n%s\n' "$class" "$1" "$2" "$message" >&2
  [[ -z ${3:-} ]] || printf '%s\n' "$3" >&2
  exit "$status"
}

from=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from|--out)
      [[ $# -ge 2 && -n $2 ]] || stop argument "$1"
      if [[ $1 == --from ]]; then from="$2"; else out="$2"; fi
      shift 2 ;;
    *) stop argument "$1" ;;
  esac
done

if ! command -v magick >/dev/null 2>&1; then
  printf 'readme-shots: status=not-measured missing=magick\n'
  exit 77
fi
source "$repo/scripts/smoke/shot.sh"
# What a helper printed on stderr, shown under the refusal it caused.
err_file="$(mktemp)" || { echo "readme-shots: scratch=mktemp-failed" >&2; exit 1; }
trap 'rm -f -- "${err_file:?}"' EXIT
if [[ -n $out ]]; then
  if ! images_dir="$(shot_dir_under "$repo" "$out" 2>"$err_file")"; then stop out "$out" "$(cat -- "$err_file")"; fi
fi
if ! rows="$(python3 "$repo/scripts/check-readme-images.py" --table 2>"$err_file")"; then
  stop table "docs/images/plugins/shots.tsv" "$(cat -- "$err_file")"
fi
mapfile -t table_rows <<<"$rows"
[[ -n $rows ]] || table_rows=()

if [[ -z $from ]]; then
  scenes=()
  for row in "${table_rows[@]}"; do
    IFS=$'\t' read -r _ scene _ _ <<<"$row"
    [[ " ${scenes[*]} " == *" $scene "* ]] || scenes+=("$scene")
  done
  from="$repo/tmp/readme-shots/$(date -u +%Y%m%dT%H%M%SZ)"
  status=0
  "$repo/scripts/sandbox-shots.sh" "${SHOTS_ARGS[@]}" --out "$from" "${scenes[@]}" || status=$?
  [[ $status -eq 0 ]] || exit "$status"
fi
[[ -d $from && -f $from/shots.tsv && -f $from/00-desktop.png ]] || stop from "$from"

# shot_png NAME: the run's PNG of shot NAME, checked hidden and sized. Its
# caller runs it in a subshell, where a refusal prints and exits; the
# caller exits with it.
shot_png() {
  local png="$from/$1.png" state size
  [[ -f $png ]] || stop shot "$1"
  if ! state="$(awk -F '\t' -v name="$1" '$1 == name { state = $5 } END { print state }' "$from/shots.tsv")"; then
    stop from "$from" "shots.tsv is unreadable"
  fi
  [[ $state == hidden ]] || stop shot-window "$1" "state=${state:-unlisted}"
  if ! size="$(magick identify -format '%wx%h' "$png")"; then stop measure "$1"; fi
  [[ $size == "$OUTPUT_SIZE" ]] || stop shot-size "$1" "size=$size"
  printf '%s\n' "$png"
}

# mask_rows reads a binary 8-bit PGM of a mask on stdin, 0 where a pixel
# holds nothing, and prints its bar band or its content box. `band` prints
# the row after the first run of rows holding a set pixel, or `none`.
# `box BAND` prints `X Y W H`, the box of the set pixels at and below row
# BAND, or `none`.
mask_program='import sys
data = sys.stdin.buffer.read()
magic, width, height, depth, pixels = data.split(maxsplit=4)
width, height = int(width), int(height)
assert magic == b"P5" and depth == b"255" and len(pixels) == width * height, "mask: not an 8-bit PGM"
rows = [pixels[y * width:(y + 1) * width] for y in range(height)]
if sys.argv[1] == "band":
    set_rows = [y for y, row in enumerate(rows) if row.strip(b"\0")]
    if not set_rows:
        print("none"); sys.exit()
    end = set_rows[0]
    while end < height and rows[end].strip(b"\0"):
        end += 1
    print(end)
else:
    band = int(sys.argv[2])
    top = bottom = left = right = None
    for y in range(band, height):
        row = rows[y]
        stripped = row.lstrip(b"\0")
        if not stripped:
            continue
        first, last = width - len(stripped), len(row.rstrip(b"\0")) - 1
        top = y if top is None else top
        bottom = y
        left = first if left is None else min(left, first)
        right = last if right is None else max(right, last)
    print("none" if top is None else "%d %d %d %d" % (left, top, right - left + 1, bottom - top + 1))'

# The operators that turn two images into the mask of the pixels where they
# differ in any channel.
differ=(-compose difference -composite -separate -evaluate-sequence max -threshold 0)
if ! desktop="$(shot_png 00-desktop)"; then exit 1; fi
if ! background="$(magick "$desktop" -format '%[pixel:p{0,%[fx:h-1]}]' info:)"; then stop measure 00-desktop; fi
if ! band="$(magick "$desktop" -alpha off \( +clone -fill "$background" -colorize 100 \) "${differ[@]}" -depth 8 pgm:- | python3 -c "$mask_program" band)"; then
  stop measure 00-desktop
fi
[[ $band != none ]] || stop bar "$desktop"
read -r width height <<<"${OUTPUT_SIZE/x/ }"

for row in "${table_rows[@]}"; do
  IFS=$'\t' read -r image _ shot crop <<<"$row"
  if ! png="$(shot_png "$shot")"; then exit 1; fi
  case $crop in
    full) geometry="${width}x${height}+0+0" ;;
    bar) geometry="${width}x${band}+0+0" ;;
    content)
      if ! box="$(magick "$png" "$desktop" -alpha off "${differ[@]}" \
        -fill black -draw "rectangle $((width - POINTER_PX)),$((height - POINTER_PX)) $width,$height" \
        -depth 8 pgm:- | python3 -c "$mask_program" box "$band")"; then
        stop measure "$shot"
      fi
      [[ $box != none ]] || stop crop-empty "$shot"
      read -r x y w h <<<"$box"
      left=$(( x - MARGIN_PX < 0 ? 0 : x - MARGIN_PX ))
      top=$(( y - MARGIN_PX <= band ? 0 : y - MARGIN_PX ))
      right=$(( x + w + MARGIN_PX > width ? width : x + w + MARGIN_PX ))
      bottom=$(( y + h + MARGIN_PX > height ? height : y + h + MARGIN_PX ))
      geometry="$((right - left))x$((bottom - top))+$left+$top" ;;
    *) echo "readme-shots: internal: crop=$crop passed the table's judge, which knows full, bar and content alone" >&2; exit 1 ;;
  esac
  target="$images_dir/$image"
  if ! magick "$png" -alpha off -crop "$geometry" +repage -strip "${WEBP_OPTIONS[@]}" "$target.part.webp" 2>"$err_file"; then
    stop encode "$image" "$(cat -- "$err_file")"
  fi
  mv -f -- "$target.part.webp" "$target"
  printf 'readme-shots: wrote=%s bytes=%s size=%s\n' "${target#"$repo"/}" "$(stat -c %s -- "$target")" "$(magick identify -format '%wx%h' "$target")"
done
