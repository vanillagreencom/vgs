#!/usr/bin/env bash
# Controls for `vgsh theme wallpapers`: the verified download of a catalog
# install's wallpaper archive. The rows run a tree copy whose
# themes/catalog/ is this suite's own fixture and whose archives are
# file:// fixtures built here, under VGS_TEST_RUN, so no row reaches the
# network. Each row pins an exit status, the last stdout line, the keyed
# stderr line, a file's bytes or a JSON value. The fetch and the archive
# reader, bin/lib/theme-download.js, have their own suite,
# scripts/test-theme-download.js, which holds the controls of their rules:
# the sha256 and size checks, the cut-off, `..` and absolute names, the
# header checks and the HTTPS rule. This suite holds the controls of the
# judge's member rules, its file:// gate, its land and vgsh's locks.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree

cfg="$tmp/cfg-wallpapers"; themes="$cfg/vgs/themes"; marker="$themes/moor/.vgs-catalog.json"
mkdir -p "$cfg/vgs"
shelf="$tree/themes/catalog"
rm -rf -- "$shelf"
mkdir -p "$shelf"
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366ff" } }')" "$(slots_json '#202020')"
theme_pkg "$shelf/ivy" "$(doc ivy)"
assets="$tmp/assets"; releases="$assets/themes-v1"; mkdir -p "$releases"
cache="$tmp/home/.cache/vgs/theme-assets"
inst_env=(VGS_THEME_ASSET_BASE="file://$assets")

# Image fixtures: a real PNG and a real JPEG, and a text file.
python3 -c 'import base64,sys; open(sys.argv[1], "wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))' "$tmp/one.png"
cp -- "$repo/scripts/fixtures/convert-v1-themes/expected/catalog/thumbnails/alpha.jpg" "$tmp/one.jpg"
printf 'notes\n' >"$tmp/notes.txt"

# The fixture index: moor pins ARCHIVE under $releases with its own size
# and sha256 unless SIZE or SHA256 is given; ivy pins none.
index() { # ARCHIVE [SIZE] [SHA256]
  python3 - "$shelf/index.json" "$releases" "$@" <<'PY'
import hashlib, json, os, sys
out, releases, archive = sys.argv[1:4]
data = open(os.path.join(releases, archive), "rb").read()
size = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] != "" else len(data)
sha = sys.argv[5] if len(sys.argv) > 5 else hashlib.sha256(data).hexdigest()
palette = {"background": "#101010", "foreground": "#eeeeee", "accent": "#3366ff", "success": "#22aa22", "warning": "#ddaa00", "danger": "#cc2222", "info": "#3399cc"}
entry = lambda name, imagery: {"name": name, "mode": "dark", "thumbnail": None, "palette": palette, "imagery": imagery}
pin = {"repo": "https://github.com/vanillagreencom/vgs-themes", "release": "themes-v1", "archive": archive, "size": size, "sha256": sha}
with open(out, "w") as f:
    json.dump({"schemaVersion": 1, "entries": [entry("moor", pin), entry("ivy", None)]}, f)
PY
}
# An archive NAME under $releases holding MEMBERs, as tar_gz takes them.
archive() { tar_gz "$releases/$1" "${@:2}"; } # NAME MEMBER...
sha_of() { local sum; sum="$(sha256sum -- "$1")"; printf '%s' "${sum%% *}"; } # FILE
size_of() { stat -c %s -- "$1"; } # FILE
marker_field() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$1" "$2"; } # FILE KEY
last_json() { tail -n 1 -- "$tmp/out" >"$tmp/last.json"; json_is "$tmp/last.json" "$1"; } # PYTHON_EXPR_ON_d
unstaged() { test -z "$(find "$cfg/vgs" -maxdepth 1 -name '.vgsh-theme-wallpapers.*' -print)"; }
# The cache holds nothing but the download lock: no part, no archive.
cache_clean() { test "$(find "$cache" -mindepth 1 -printf '%P\n' 2>/dev/null | sort | tr '\n' ' ')" == "download.lock "; }
# A refused run leaves the package and its marker as SNAPSHOT holds them,
# no staging directory and nothing in the cache.
snapshot() { rm -rf -- "$tmp/snapshot"; cp -a -- "$themes/moor" "$tmp/snapshot"; }
left_nothing() { # ROW
  check "$1 leaves the package and its marker byte for byte" diff -r "$tmp/snapshot" "$themes/moor"
  check "$1 leaves no staging directory" unstaged
  check "$1 leaves nothing in the cache" cache_clean
}
# One --json run of `theme wallpapers moor` that the judge refuses with
# LINE, leaving nothing, its result naming REASON; STATUS is the exit
# status, 1 unless given.
refused() { # ROW LINE REASON [STATUS]
  snapshot
  tinst "$1" "$cfg" "$rt_empty" "${4:-1}" "$any_out" "$2" theme wallpapers --json moor
  check "$1 prints the failed result" last_json '{k: v for k, v in d.items() if k != "sha256"} == {"state": "failed", "theme": "moor", "wallpapers": None, "images": None, "reason": "'"$3"'"}'
  left_nothing "$1"
}

archive vgs-theme-moor-r1.tar.gz "file:backgrounds/0-one.png=$tmp/one.png" "file:backgrounds/1-one.jpg=$tmp/one.jpg"
index vgs-theme-moor-r1.tar.gz
r1="$releases/vgs-theme-moor-r1.tar.gz"; r1_sha="$(sha_of "$r1")"; r1_size="$(size_of "$r1")"
tinst "moor installs from the catalog" "$cfg" "$rt_empty" 0 "$any_out" "" theme install moor
tinst "ivy installs from the catalog" "$cfg" "$rt_empty" 0 "$any_out" "" theme install ivy
installed_digest="$(marker_field "$marker" digest)"

# The invocation.
tinst "wallpapers without a name is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: name=missing" theme wallpapers
tinst "wallpapers with a second name is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=ivy" theme wallpapers moor ivy
tinst "wallpapers with --update twice is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=--update" theme wallpapers --update moor --update
tinst "wallpapers with an unknown option is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=--force" theme wallpapers moor --force

# What the install is.
tinst "wallpapers of no install is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: wallpapers=fen reason=not-catalog path=$themes/fen" theme wallpapers fen
tinst "wallpapers of a malformed name is refused" "$cfg" "$rt_empty" 1 "" 'vgsh: refused: wallpapers="../moor" reason=malformed-name' theme wallpapers ../moor
tinst "wallpapers of an entry with no archive is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: wallpapers=ivy reason=no-imagery" theme wallpapers ivy
mkdir -p "$themes/moor/backgrounds"; cp -- "$tmp/one.png" "$themes/moor/backgrounds/mine.png"
snapshot
tinst "a backgrounds/ the download did not place is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: wallpapers=moor reason=exists path=$themes/moor/backgrounds" theme wallpapers moor
check "the refusal says where the user's own images belong" grep -qxF "the download did not place $themes/moor/backgrounds; your own images belong in $cfg/vgs/backgrounds" "$tmp/err"
left_nothing "the exists refusal"
rm -rf -- "$themes/moor/backgrounds"

# The transport: HTTPS only, and file:// only in a test run.
inst_env=(VGS_THEME_ASSET_BASE="http://127.0.0.1:9")
refused "an http:// base is refused" "vgsh: refused: wallpapers=moor reason=not-https url=\"http://127.0.0.1:9/themes-v1/vgs-theme-moor-r1.tar.gz\"" not-https
inst_env=(VGS_THEME_ASSET_BASE="file://$assets")
INST_TEST_RUN="" refused "a file:// base outside a test run is refused" "vgsh: refused: wallpapers=moor reason=not-https url=\"file://$releases/vgs-theme-moor-r1.tar.gz\"" not-https

# The pin decides the bytes.
index vgs-theme-moor-r1.tar.gz "" "$(printf '0%.0s' $(seq 64))"
refused "an archive of another sha256 is refused" "vgsh: refused: wallpapers=moor reason=sha256 got=$r1_sha want=$(printf '0%.0s' $(seq 64))" sha256
index vgs-theme-moor-r1.tar.gz "$((r1_size + 1))"
refused "an archive shorter than the pin is refused" "vgsh: refused: wallpapers=moor reason=size got=$r1_size want=$((r1_size + 1))" size
index vgs-theme-moor-r1.tar.gz "$((r1_size - 1))"
refused "an archive longer than the pin is refused" "vgsh: refused: wallpapers=moor reason=size got=$r1_size want=$((r1_size - 1))" size

# The members: only regular backgrounds/<image> files of at most 128 MiB.
# Each row: the archive's members, the refusal line after the key, and its
# reason.
member_rows=(
  "a symlink member|symlink:backgrounds/link.png=../../../.bashrc|link member=\"backgrounds/link.png\"|link"
  "a hard link member|hardlink:backgrounds/link.png=backgrounds/0-one.png|link member=\"backgrounds/link.png\"|link"
  "a directory member|dir:backgrounds|type member=\"backgrounds\" type=\"5\"|type"
  "a ../ member|file:../evil.png=$tmp/one.png|path member=\"../evil.png\"|path"
  "a nested member|file:backgrounds/sub/a.png=$tmp/one.png|path member=\"backgrounds/sub/a.png\"|path"
  "a member outside backgrounds/|file:theme.json=$tmp/notes.txt|path member=\"theme.json\"|path"
  "a member that is no image|file:backgrounds/notes.txt=$tmp/notes.txt|not-an-image member=\"backgrounds/notes.txt\"|not-an-image"
  "a hidden image|file:backgrounds/.one.png=$tmp/one.png|not-an-image member=\"backgrounds/.one.png\"|not-an-image"
  "a member over 128 MiB|claim:backgrounds/huge.png=209715200|oversize member=\"backgrounds/huge.png\" size=209715200 ceiling=134217728|oversize"
  "a bad header|badsum:backgrounds/a.png=$tmp/one.png|header defect=checksum got=4730 want=4731|header"
)
for row in "${member_rows[@]}"; do
  IFS='|' read -r label member line reason <<<"$row"
  archive vgs-theme-moor-bad.tar.gz "file:backgrounds/0-one.png=$tmp/one.png" "$member"
  index vgs-theme-moor-bad.tar.gz
  refused "$label is refused" "vgsh: refused: wallpapers=moor reason=$line" "$reason"
done
archive vgs-theme-moor-bad.tar.gz "file:backgrounds/a.png=$tmp/one.png" "file:./backgrounds/a.png=$tmp/one.jpg"
index vgs-theme-moor-bad.tar.gz
refused "a name held twice is refused" 'vgsh: refused: wallpapers=moor reason=duplicate member="backgrounds/a.png"' duplicate
archive vgs-theme-moor-bad.tar.gz
index vgs-theme-moor-bad.tar.gz
refused "an archive with no image is refused" "vgsh: refused: wallpapers=moor reason=no-image" no-image
cp -- "$tmp/notes.txt" "$releases/vgs-theme-moor-bad.tar.gz"
index vgs-theme-moor-bad.tar.gz
refused "a file that is no gzip is refused" "vgsh: refused: wallpapers=moor reason=archive error=Z_DATA_ERROR" archive

# The locks.
index vgs-theme-moor-r1.tar.gz
mkdir -p "$cache"
exec 6>>"$cache/download.lock"
flock 6
snapshot
tinst "a download while another holds the download lock is refused busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: wallpapers=moor reason=busy" theme wallpapers moor
left_nothing "the busy download"
tree_control unlocked-download bin/vgsh '  flock -n -E 75 8 || status=$?' '  status=0'
tinst "the unlocked-download mutant downloads under the held lock" "$cfg" "$rt_empty" 0 "ok wallpapers=moor state=installed images=2 archive=${r1_sha:0:12}" "$any_out" theme wallpapers moor
unset THEME_BIN
exec 6>&-
rm -rf -- "$themes/moor/backgrounds"; cp -- "$tmp/snapshot/.vgs-catalog.json" "$marker"
exec 7>>"$cfg/vgs/theme.lock"
flock 7
refused "a land while another command holds the theme lock is refused busy" "vgsh: refused: wallpapers=moor reason=busy" busy 75
tree_control unlocked-land bin/vgsh 'wallpapers-land "$1" "$config_home/vgs" "$stage" "$verdict" "$2" "$3"' 'wallpapers-land "$1" "$config_home/vgs" "$stage" held "$2" "$3"'
tinst "the unlocked-land mutant lands under the held lock" "$cfg" "$rt_empty" 0 "ok wallpapers=moor state=installed images=2 archive=${r1_sha:0:12}" "$any_out" theme wallpapers moor
unset THEME_BIN
exec 7>&-
rm -rf -- "$themes/moor/backgrounds"; cp -- "$tmp/snapshot/.vgs-catalog.json" "$marker"

# The download.
tinst "wallpapers downloads and lands the pinned archive" "$cfg" "$rt_empty" 0 "ok wallpapers=moor state=installed images=2 archive=${r1_sha:0:12}" "progress state=downloading bytes=0 total=$r1_size" theme wallpapers moor
check "the landed PNG is the archive's byte for byte" cmp -s "$tmp/one.png" "$themes/moor/backgrounds/0-one.png"
check "the landed JPEG is the archive's byte for byte" cmp -s "$tmp/one.jpg" "$themes/moor/backgrounds/1-one.jpg"
check "the marker records the pin" test "$(marker_field "$marker" imagery)" == "{\"repo\": \"https://github.com/vanillagreencom/vgs-themes\", \"release\": \"themes-v1\", \"archive\": \"vgs-theme-moor-r1.tar.gz\", \"size\": $r1_size, \"sha256\": \"$r1_sha\"}"
check "the marker keeps the package digest" test "$(marker_field "$marker" digest)" == "$installed_digest"
check "the text form prints the last progress line of each state" grep -qxF "progress state=unpacking bytes=$r1_size total=$r1_size" "$tmp/err"
check "the download leaves no staging directory" unstaged
check "the download leaves nothing in the cache" cache_clean
tinst "catalog lists the download" "$cfg" "$rt_empty" 0 "$any_out" "" theme catalog --json
check "catalog reports the imagery installed and current" json_is "$tmp/out" '[(e["imageryInstalled"], e["imageryUpdate"], e["definitionUpdate"]) for e in d["entries"] if e["name"] == "moor"] == [(True, False, False)]'
tinst "an apply after the download" "$cfg" "$rt_empty" 0 "ok theme=moor state=applied shell=applied" "" theme apply moor
check "the apply makes the first image current" json_is "$state/backgrounds.json" 'd["current"] == "'"$themes/moor/backgrounds/0-one.png"'"'
check "the background link names the first image" test "$(readlink -- "$state/background")" == "$themes/moor/backgrounds/0-one.png"
tinst "wallpapers again is up to date" "$cfg" "$rt_empty" 0 "ok wallpapers=moor state=up-to-date images=2 archive=${r1_sha:0:12}" "" theme wallpapers moor
tinst "wallpapers --json again is up to date" "$cfg" "$rt_empty" 0 "$any_out" "" theme wallpapers --json moor
check "an up-to-date result is its only line" json_is "$tmp/out" 'd == {"state": "ok", "theme": "moor", "wallpapers": "up-to-date", "images": 2, "sha256": "'"$r1_sha"'", "reason": None}'

# A new pin.
archive vgs-theme-moor-r2.tar.gz "file:backgrounds/a.png=$tmp/one.png" "file:backgrounds/b.jpg=$tmp/one.jpg" "file:./backgrounds/c.JPEG=$tmp/one.jpg"
index vgs-theme-moor-r2.tar.gz
r2="$releases/vgs-theme-moor-r2.tar.gz"; r2_sha="$(sha_of "$r2")"; r2_size="$(size_of "$r2")"
snapshot
tinst "another archive's images without --update are refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: wallpapers=moor reason=installed archive=${r1_sha:0:12} pinned=${r2_sha:0:12}" theme wallpapers moor
check "the refusal says --update replaces them" grep -qxF "the index pins another archive; --update replaces the images of $themes/moor/backgrounds" "$tmp/err"
left_nothing "the installed refusal"
tinst "--update replaces the images" "$cfg" "$rt_empty" 0 "$any_out" "" theme wallpapers --json moor --update
check "the update's result is the last line" last_json 'd == {"state": "ok", "theme": "moor", "wallpapers": "updated", "images": 3, "sha256": "'"$r2_sha"'", "reason": None}'
python3 - "$tmp/out" "$r2_size" >"$tmp/states" <<'PY'
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1]) if line.strip()][:-1]
total = int(sys.argv[2])
assert all(sorted(l) == ["bytes", "state", "total"] and l["total"] == total for l in lines), lines
seen = []
for l in lines:
    if not seen or seen[-1][0] != l["state"]:
        seen.append([l["state"], []])
    seen[-1][1].append(l["bytes"])
for state, series in seen:
    assert series == sorted(set(series)) and series[-1] == total, (state, series)
print(" ".join(f"{state}:{series[0]}" for state, series in seen))
PY
check "the progress lines are downloading, verifying and unpacking, each from its first bytes to the total" test "$(cat "$tmp/states")" == "downloading:0 verifying:$r2_size unpacking:0"
check "the update removes the old archive's images" test ! -e "$themes/moor/backgrounds/0-one.png"
check "the update lands the new archive's images" cmp -s "$tmp/one.jpg" "$themes/moor/backgrounds/c.JPEG"
check "the marker records the new pin" test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["imagery"]["sha256"])' "$marker")" == "$r2_sha"
check "the update leaves no staging directory" unstaged
check "the update leaves nothing in the cache" cache_clean

# The land judges again: a pin that changed during the download is
# refused. The preload repins r1 as the fetch of r3 ends.
archive vgs-theme-moor-r3.tar.gz "file:backgrounds/r3.png=$tmp/one.png"
index vgs-theme-moor-r1.tar.gz
cp -- "$shelf/index.json" "$tmp/index-r1.json"
index vgs-theme-moor-r3.tar.gz
cat >"$tmp/repin.js" <<JS
const fs = require("fs");
const path = require("path");
const index = path.join(path.dirname(process.argv[1] || "."), "..", "themes", "catalog", "index.json");
if (process.argv.includes("wallpapers-fetch")) process.on("exit", () => fs.copyFileSync("$tmp/index-r1.json", index));
JS
snapshot
inst_env=(VGS_THEME_ASSET_BASE="file://$assets" NODE_OPTIONS="--require $tmp/repin.js")
tinst "a pin that changed during the download is refused" "$cfg" "$rt_empty" 1 "$any_out" "vgsh: refused: wallpapers=moor reason=changed" theme wallpapers --json moor --update
left_nothing "the changed refusal"
index vgs-theme-moor-r3.tar.gz
judge_control unchecked-stage 'if (staged === null || JSON.stringify(staged) !== JSON.stringify(plan.pin))' 'if (false)'
tinst "the unchecked-stage mutant lands images the index no longer pins" "$cfg" "$rt_empty" 0 "$any_out" "" theme wallpapers --json moor --update
check "the unchecked-stage mutant records a pin for other images" test -e "$themes/moor/backgrounds/r3.png" -a "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["imagery"]["sha256"])' "$marker")" == "$r1_sha"
unset THEME_BIN
inst_env=(VGS_THEME_ASSET_BASE="file://$assets")

# The judge's controls, each on a fresh install of moor.
fresh() { # ARCHIVE
  tinst "moor is removed for a control" "$cfg" "$rt_empty" 0 "$any_out" "" theme remove moor
  tinst "moor installs for a control" "$cfg" "$rt_empty" 0 "$any_out" "" theme install moor
  index "$1"
}
archive vgs-theme-moor-bad.tar.gz "symlink:backgrounds/link.png=../../../.bashrc"
fresh vgs-theme-moor-bad.tar.gz
judge_control linked 'if (member.kind === "symlink" || member.kind === "hardlink") refuse(' 'if (false) refuse('
tinst "the linked mutant takes a link for another kind" "$cfg" "$rt_empty" 1 "$any_out" 'vgsh: refused: wallpapers=moor reason=type member="backgrounds/link.png" type="2"' theme wallpapers --json moor
unset THEME_BIN
archive vgs-theme-moor-bad.tar.gz "file:backgrounds/notes.txt=$tmp/notes.txt"
fresh vgs-theme-moor-bad.tar.gz
judge_control any-name 'if (!backgrounds.isImageName(file)) refuse(' 'if (false) refuse('
tinst "the any-name mutant lands a file that is no image" "$cfg" "$rt_empty" 0 "$any_out" "$any_out" theme wallpapers moor
check "the any-name mutant's package holds the text file" cmp -s "$tmp/notes.txt" "$themes/moor/backgrounds/notes.txt"
unset THEME_BIN
archive vgs-theme-moor-bad.tar.gz "file:backgrounds/sub/a.png=$tmp/one.png"
fresh vgs-theme-moor-bad.tar.gz
judge_control any-path 'if (!member.name.startsWith(backgrounds.DIR + "/") || file.includes("/")) refuse(' 'if (false) refuse('
tinst "the any-path mutant judges a nested member by its name" "$cfg" "$rt_empty" 1 "$any_out" 'vgsh: refused: wallpapers=moor reason=not-an-image member="backgrounds/sub/a.png"' theme wallpapers --json moor
unset THEME_BIN
archive vgs-theme-moor-bad.tar.gz "claim:backgrounds/huge.png=209715200"
fresh vgs-theme-moor-bad.tar.gz
judge_control unbounded 'if (member.size > download.MEMBER_CEILING) refuse(' 'if (false) refuse('
tinst "the unbounded mutant writes the member until the archive ends" "$cfg" "$rt_empty" 1 "$any_out" 'vgsh: refused: wallpapers=moor reason=header defect=truncated' theme wallpapers --json moor
unset THEME_BIN
fresh vgs-theme-moor-r1.tar.gz
judge_control file-anywhere 'download.archiveUrl(plan.pin, process.env[ASSET_BASE], Boolean(process.env[TEST_RUN]))' 'download.archiveUrl(plan.pin, process.env[ASSET_BASE], true)'
INST_TEST_RUN="" tinst "the file-anywhere mutant downloads a file:// base outside a test run" "$cfg" "$rt_empty" 0 "ok wallpapers=moor state=installed images=2 archive=${r1_sha:0:12}" "$any_out" theme wallpapers moor
unset THEME_BIN

inst_env=(VGS_THEME_ASSET_BASE="file://$assets")
index vgs-theme-moor-r1.tar.gz
preview_dir="$cache/previews"
rm -rf -- "$preview_dir"; mkdir -p "$preview_dir"
printf 'partial\n' >"$preview_dir/$r1_sha-0-one.png.part"
tinst "preview ignores and removes a stale part" "$cfg" "$rt_empty" 0 "$any_out" "" theme preview --json moor
check "preview returns a completed image, not the stale part" last_json 'd["state"] == "ok" and d["path"].endswith("-0-one.png") and not d["path"].endswith(".part")'
check "preview removed the stale part" test ! -e "$preview_dir/$r1_sha-0-one.png.part"
check "preview wrote the image byte for byte" cmp -s "$tmp/one.png" "$preview_dir/$r1_sha-0-one.png"

rm -rf -- "$themes/moor/backgrounds"; cp -- "$tmp/snapshot/.vgs-catalog.json" "$marker"
rm -rf -- "$preview_dir"; mkdir -p "$preview_dir"; printf 'partial\n' >"$preview_dir/$r1_sha-0-one.png.part"
judge_control part-hit 'cachedPreview = fs.readdirSync(previewCacheDir(), { withFileTypes: true }).find(entry => entry.isFile() && entry.name.startsWith(pin.sha256 + "-") && !entry.name.endsWith(".part"));' 'cachedPreview = fs.readdirSync(previewCacheDir(), { withFileTypes: true }).find(entry => entry.isFile() && entry.name.startsWith(pin.sha256 + "-"));'
tinst "the part-hit mutant returns the stale preview part" "$cfg" "$rt_empty" 0 "$any_out" "" theme preview --json moor
check "the part-hit mutant reports the .part path" last_json 'd["state"] == "ok" and d["path"].endswith(".part")'
unset THEME_BIN

rows_done test-vgsh-wallpapers
