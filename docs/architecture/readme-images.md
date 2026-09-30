# README images

Covers: scripts/readme-shots.sh, scripts/test-readme-shots.sh, scripts/check-readme-images.py, scripts/test-check-readme-images.py, docs/images/plugins/**

Every first-party plugin README shows a screenshot of the plugin. One table names each image and the sandbox shot it is cut from, one command makes every image from that table, and one offline check holds the READMEs, the table and the files to each other.

## Regeneration

- `scripts/readme-shots.sh` makes every image. It runs `scripts/sandbox-shots.sh --hidden --scale 2 --modes dark --size 1280x800` over the scenes the table names, into `tmp/readme-shots/<UTC time>`, then cuts and encodes each row into `docs/images/plugins/`. The nested sandbox draws every shot with the default theme `vgs`, so an image never shows the live desktop. A sandbox run that exits 77 or 1 ends the command with that status, and no image is written.
- `--from DIR` cuts the images again from an earlier sandbox-shots run. Each shot the table names must be in that run's `shots.tsv` as taken with the nested window hidden, and 2560 by 1600 pixels. `--out DIR` writes under this checkout's `tmp/` in place of `docs/images/plugins/`.
- `docs/images/plugins/shots.tsv` is the table: a header, then one row per image with four tab-separated fields, the image's file name, the sandbox-shots scene and shot it is cut from, and the crop. A new image is a new row, then the command. `scripts/check-readme-images.py --table` judges the table and hands the command its rows, so the table has one reader.
- The images live under `docs/images/plugins/`, flat, each named `<plugin id>-<slug>.webp`. `packaging/install-system.sh` installs every file under `shell/` but markdown, so an image beside its README would ship; nothing under `docs/` is installed.

## Crops

Each crop is measured on the shot at its device pixels, against the run's first shot, the bare desktop `00-desktop.png`, whose bottom-left pixel is the desktop's colour.

- `full`: the whole output.
- `bar`: the bar band at full width, from the top through the last row of the first run of desktop rows that differ from the desktop's colour.
- `content`: the box of the pixels below the bar band that differ from the desktop, grown by 16 logical pixels a side and clamped to the output. A box that grows into the bar band runs from the top edge, so a panel that drops from the bar shows the bar above it. The clock in the band never widens the box. The scenes park the pointer 2 logical pixels from the bottom-right corner, and the shape it shows there differs from shot to shot, so a square of 16 logical pixels in that corner is left out.
- A crop that finds no bar band, or no content, is refused, never widened to the whole output.

## Encoding

Each image is lossy WebP at quality 85, method 6, with sharp RGB-to-YUV conversion and no metadata. Measured on host cachy on 2026-09-30 with ImageMagick 7.1.2-32 and libwebp 1.6.0, over the table's 13 images cut from one run:

| Encoding | Total bytes | Largest image |
|---|---|---|
| Lossless | 1,628,430 | 636,416, the polkit prompt |
| Quality 85 | 348,940 | 53,262, the Dev Tools window |
| Quality 85, sharp YUV | 356,588 | 54,996, the Dev Tools window |
| Quality 90, sharp YUV | 412,300 | 63,526, the Dev Tools window |

Lossless puts the polkit prompt over the 200 KB commit-guards byte ceiling. At 200% zoom, text at quality 85 shows no artefact that quality 90 or 92 does not. Without sharp YUV, thin orange text such as a section heading loses its colour to chroma subsampling; with it, the colour matches the lossless image for 2% more bytes.

## Budget

An image may be 100 KiB, near twice the largest measured above and under the 200 KB byte ceiling. `scripts/check-readme-images.py` holds the figure and refuses a file over it.

## Invariants

1. Every first-party plugin README shows at least one image and names `scripts/readme-shots.sh`. Every image it shows is a relative path to an existing WebP file under `docs/images/plugins/`, within the budget. Every table row is well formed, its image exists and the README of the plugin its name starts with shows it. No other file sits in the directory without a row. Enforced by `scripts/check-readme-images.py`, a `tools` row of `scripts/validate`, whose docstring lists one key per rule; `scripts/test-check-readme-images.py` plants one defect per rule and the empty plugin walk. The md-refs row also fails a dead relative image link in any markdown file.
2. The crops hold the rules above, and the command refuses a missing shot, a shot not taken hidden, a shot of another size and an empty content crop. Enforced by `scripts/test-readme-shots.sh` over synthetic shots, whose controls, on copies of the script, drop the band's top-edge rule, read the box from the top row, read the pointer's corner and fall back to the whole output for an empty crop.
