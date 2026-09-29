#!/usr/bin/env bash
# Controls for the theme catalog verbs: `vgsh theme catalog`, `vgsh theme
# install`, and `update`, `remove` and `outdated` on a catalog install. The
# rows run a tree copy whose themes/catalog/ is this suite's own fixture, so
# no shipped catalog change moves a row. Each row pins an exit status, the
# last stdout line, the keyed stderr line, a file's bytes or a JSON value.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
# outdated prints its rows through python3 and fetches a git row under
# these; the catalog rows need none of them but share the verb.
for tool in timeout python3 realpath env setsid; do
  tool_bin="$(command -v "$tool")" || { echo "test-vgsh-catalog: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$theme_path/$tool"
done

cfg="$tmp/cfg-catalog"; themes="$cfg/vgs/themes"; file="$cfg/vgs/theme.json"
mkdir -p "$cfg/vgs"
shelf="$tree/themes/catalog"
rm -rf -- "$shelf"
mkdir -p "$shelf"

# The fixture catalog: moor, a package with terminal slots and a curated
# file; bad, whose terminal.json the package judge refuses though the index
# is sound; ivy, a name a git source takes first; light, a shipped name.
palette='{ "background": "#101010", "foreground": "#eeeeee", "accent": "#3366ff", "success": "#22aa22", "warning": "#ddaa00", "danger": "#cc2222", "info": "#3399cc" }'
pin() { printf '{ "repo": "https://github.com/vanillagreencom/vgs-themes", "release": "themes-v1", "archive": "vgs-theme-%s.tar.gz", "size": 42, "sha256": "%s" }' "$1" "$2"; } # ARCHIVE SHA256
sha_a="$(printf 'a%.0s' $(seq 64))"; sha_b="$(printf 'b%.0s' $(seq 64))"
entry() { printf '{ "name": "%s", "mode": "dark", "thumbnail": null, "palette": %s, "imagery": %s }' "$1" "$palette" "$2"; } # NAME IMAGERY
printf '{ "schemaVersion": 1, "entries": [%s, %s, %s, %s] }\n' "$(entry moor "$(pin moor-r1 "$sha_a")")" "$(entry bad null)" "$(entry ivy null)" "$(entry light null)" >"$shelf/index.json"
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366ff" } }')" "$(slots_json '#202020')"
mkdir -p "$shelf/moor/targets"; printf 'curated\n' >"$shelf/moor/targets/foot.ini"
theme_pkg "$shelf/bad" "$(doc bad)" '{ "schemaVersion": 1, "slots": { "color0": "#000000" } }'
theme_pkg "$shelf/ivy" "$(doc ivy)"
theme_pkg "$shelf/light" "$(doc light)"

marker="$themes/moor/.vgs-catalog.json"
unstaged() { test -z "$(find "$cfg/vgs" -maxdepth 1 -name '.vgsh-theme-install.*' -print)"; }
# `vgsh theme catalog --json` for CFG, into $tmp/catalog.json.
catalog_json() { # CFG
  "${base_env[@]}" PATH="$theme_path" XDG_CONFIG_HOME="$1" XDG_RUNTIME_DIR="$rt_empty" "${THEME_BIN:-$tree/bin/vgsh}" theme catalog --json >"$tmp/catalog.json"
}
# The four install keys of catalog entry NAME, as `k=v` words.
state_of() { # NAME
  catalog_json "$cfg"
  python3 -c 'import json,sys
e = [e for e in json.load(open(sys.argv[1]))["entries"] if e["name"] == sys.argv[2]][0]
print(" ".join(k + "=" + json.dumps(e[k]) for k in ["installed", "definitionUpdate", "imageryInstalled", "imageryUpdate"]))' "$tmp/catalog.json" "$1"
}
marker_field() { python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))[sys.argv[2]]))' "$1" "$2"; } # FILE KEY
not_installed='installed=false definitionUpdate=false imageryInstalled=false imageryUpdate=false'

# The list.
catalog_json "$cfg"
check "catalog --json lists every index entry in index order" json_is "$tmp/catalog.json" '[e["name"] for e in d["entries"]] == ["moor", "bad", "ivy", "light"]'
check "catalog --json carries the index entry and its install state" json_is "$tmp/catalog.json" 'd["entries"][0] == {"name": "moor", "mode": "dark", "thumbnail": None, "palette": {"background": "#101010ff", "foreground": "#eeeeeeff", "accent": "#3366ffff", "success": "#22aa22ff", "warning": "#ddaa00ff", "danger": "#cc2222ff", "info": "#3399ccff"}, "imagery": {"repo": "https://github.com/vanillagreencom/vgs-themes", "release": "themes-v1", "archive": "vgs-theme-moor-r1.tar.gz", "size": 42, "sha256": "'"$sha_a"'"}, "installed": False, "imageryInstalled": False, "imageryUpdate": False, "definitionUpdate": False}'
tinst "catalog prints one text line per entry" "$cfg" "$rt_empty" 0 "theme=light mode=dark installed=false definitionUpdate=false imageryInstalled=false imageryUpdate=false" "" theme catalog
tinst "catalog with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=moor" theme catalog moor

# Install.
tinst "install lands a catalog package" "$cfg" "$rt_empty" 0 "ok installed=moor path=$themes/moor" "" theme install moor
for part in theme.json terminal.json targets/foot.ini; do
  check "install copies $part byte for byte" cmp -s "$shelf/moor/$part" "$themes/moor/$part"
done
check "install writes the catalog marker" test "$(marker_field "$marker" source) $(marker_field "$marker" imagery)" == '"catalog" null'
installed_digest="$(marker_field "$marker" digest)"
check "the marker records a sha256 digest" test "${#installed_digest}" == 66
check "install leaves no staging directory" unstaged
check "catalog reports the install" test "$(state_of moor)" == 'installed=true definitionUpdate=false imageryInstalled=false imageryUpdate=false'
tinst "a reinstall is refused as installed" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=moor reason=installed path=$themes/moor" theme install moor
tinst "install of a package the judge refuses is refused" "$cfg" "$rt_empty" 1 "" 'vgsh: refused: theme=bad reason=terminal-slot token=terminal missing=color1' theme install bad
check "a refused install lands nothing" test ! -e "$themes/bad"
check "a refused install leaves no staging directory" unstaged
tinst "install of a name the catalog lacks is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=fen reason=not-in-catalog" theme install fen
tinst "install of a malformed name is refused" "$cfg" "$rt_empty" 1 "" 'vgsh: refused: theme="../moor" reason=malformed-name' theme install ../moor
tinst "install of a shipped name shadows the shipped package" "$cfg" "$rt_empty" 0 "ok installed=light path=$themes/light shadows=$tree/themes/light" "" theme install light
tinst "install takes no --json" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=--json" theme install --json moor
tinst "install without a name is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: name=missing" theme install

# A git source whose own repository carries a marker stays a git install:
# its .git decides, so install refuses its name as exists, catalog does not
# list it installed and outdated fetches it.
theme_source ivy "$(doc ivy)"
printf '{"source":"catalog","digest":"%s","imagery":null}\n' "$sha_a" >"$tmp/tsrc/ivy/.vgs-catalog.json"
theme_commit ivy .vgs-catalog.json "$(cat "$tmp/tsrc/ivy/.vgs-catalog.json")"
tinst "a git source carrying a marker installs through add" "$cfg" "$rt_empty" 0 "ok added=ivy path=$themes/ivy" "" theme add "$tmp/tsrc/ivy.git"
tinst "install refuses a git install's name as exists" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=ivy reason=exists path=$themes/ivy" theme install ivy
check "catalog does not list a git install as installed" test "$(state_of ivy)" == "$not_installed"
ivy_head="$(head_of "$themes/ivy")"
tinst "outdated fetches a git install carrying a marker" "$cfg" "$rt_empty" 0 "moor behind=0 head=${installed_digest:1:12} upstream=${installed_digest:1:12}" "" theme outdated
check "the git install's row is its checkout" has_line "ivy behind=0 head=${ivy_head:0:12} upstream=${ivy_head:0:12}"

# Update: the catalog's package changes, as a VGS update changes it, under
# an applied, unedited moor holding a background and an unpacked archive's
# pin.
tinst "moor applies" "$cfg" "$rt_empty" 0 "ok theme=moor state=applied shell=applied" "" theme apply moor
tinst "update of an unchanged catalog package is up to date" "$cfg" "$rt_empty" 0 "ok up-to-date=moor" "" theme update moor
mkdir -p "$themes/moor/backgrounds"; printf 'image\n' >"$themes/moor/backgrounds/a.png"
printf '{"source":"catalog","digest":%s,"imagery":%s}\n' "$installed_digest" "$(pin moor-r0 "$sha_b")" >"$marker"
check "catalog reports unpacked imagery the index pins anew" test "$(state_of moor)" == 'installed=true definitionUpdate=false imageryInstalled=true imageryUpdate=true'
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366fe" } }')" "$(slots_json '#202020')"
check "catalog reports the changed definition" test "$(state_of moor)" == 'installed=true definitionUpdate=true imageryInstalled=true imageryUpdate=true'
tinst "outdated counts a changed catalog package one behind" "$cfg" "$rt_empty" 0 "$any_out" "" theme outdated --json
catalog_digest="$(python3 -c 'import json,sys; print([r for r in json.load(open(sys.argv[1])) if r["id"] == "moor"][0]["upstream"])' "$tmp/out")"
check "the catalog row names both digests" json_is "$tmp/out" '[r for r in d if r["id"] == "moor"] == [{"id": "moor", "behind": 1, "head": '"$installed_digest"', "upstream": "'"$catalog_digest"'", "error": None}]'
tinst "update replaces the definition and follows the applied package" "$cfg" "$rt_empty" 0 "ok follow=reapplied theme=moor state=applied" "" theme update moor
check "update reports both digests before the follow" has_line "ok updated=moor from=${installed_digest:1:12} to=${catalog_digest:0:12}"
check "update lands the catalog's new theme.json" cmp -s "$shelf/moor/theme.json" "$themes/moor/theme.json"
check "the follow writes the new bytes to the theme file" cmp -s "$shelf/moor/theme.json" "$file"
check "update keeps the package's backgrounds" test "$(cat "$themes/moor/backgrounds/a.png")" == image
check "update records the new digest" test "$(marker_field "$marker" digest)" == "\"$catalog_digest\""
check "update keeps the unpacked imagery's pin" test "$(marker_field "$marker" imagery)" == "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$(pin moor-r0 "$sha_b")")"
check "update leaves no staging directory" unstaged
tinst "update after the catalog update is up to date" "$cfg" "$rt_empty" 0 "ok up-to-date=moor" "" theme update moor

# A hand edit is refused by update and reported by outdated.
cp -- "$themes/moor/theme.json" "$tmp/moor.json"
printf '\n' >>"$themes/moor/theme.json"
tinst "update refuses a hand-edited catalog install" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=moor reason=modified path=$themes/moor" theme update moor
tinst "outdated reports a hand-edited catalog install" "$cfg" "$rt_empty" 0 "$any_out" "" theme outdated
check "the hand-edited row carries update's refusal" has_line "moor error=theme=moor reason=modified path=$themes/moor"
cp -- "$tmp/moor.json" "$themes/moor/theme.json"

# A catalog version the judge refuses leaves the install as it was.
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366fd" } }')" '{ "schemaVersion": 1, "slots": {} }'
cp -- "$marker" "$tmp/marker.json"
tinst "update refuses a catalog version the judge refuses" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=moor reason=terminal-slot token=terminal missing=color0" theme update moor
check "a refused update keeps the installed theme.json" cmp -s "$tmp/moor.json" "$themes/moor/theme.json"
check "a refused update keeps the marker" cmp -s "$tmp/marker.json" "$marker"
check "a refused update leaves no staging directory" unstaged
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366fd" } }')" "$(slots_json '#202020')"

# Interruption. The preload ends the judge at once, as a signal would,
# right after the rename whose source is INTERRUPT_FROM or whose target is
# INTERRUPT_TO; bash's EXIT trap then removes the stage. The installed
# package waits in its backup beside themes/, and the next changing verb
# restores it, or completes the swap, byte for byte.
backup="$cfg/vgs/.vgsh-theme-backup-moor"
cat >"$tmp/interrupt.js" <<'JS'
const fs = require("fs");
const rename = fs.renameSync;
fs.renameSync = (from, to) => {
    rename(from, to);
    if (from === process.env.INTERRUPT_FROM || to === process.env.INTERRUPT_TO) process.exit(137);
};
JS
printf 'notes\n' >"$themes/moor/notes.txt"
cp -a -- "$themes/moor" "$tmp/moor-before-1"
# update with the preload ending it after the rename VAR names.
interrupted() { # NAME VAR
  inst_env=(NODE_OPTIONS="--require $tmp/interrupt.js" "$2=$themes/moor")
  tinst "$1" "$cfg" "$rt_empty" 137 "" "" theme update moor
  inst_env=()
}
interrupted "an update ended once the package moved to its backup exits 137" INTERRUPT_FROM
check "the ended update left the whole package in its backup" diff -r "$tmp/moor-before-1" "$backup"
check "the ended update left no installed directory" test ! -e "$themes/moor"
check "the ended update's stage is gone" unstaged
tinst "the next install restores the package before it refuses" "$cfg" "$rt_empty" 1 "" "vgsh: recovered: theme=moor state=restored path=$themes/moor" theme install moor
check "the restored package is the old one byte for byte" diff -r "$tmp/moor-before-1" "$themes/moor"
check "the restore removes the backup" test ! -e "$backup"
interrupted "an update ended once the new definition landed exits 137" INTERRUPT_TO
check "the landed definition is the catalog's" cmp -s "$shelf/moor/theme.json" "$themes/moor/theme.json"
check "the kept entries wait in the backup" test -f "$backup/backgrounds/a.png" -a -f "$backup/notes.txt"
tinst "the next install completes the swap before it refuses" "$cfg" "$rt_empty" 1 "" "vgsh: recovered: theme=moor state=completed path=$themes/moor" theme install moor
check "the completed swap keeps the backgrounds byte for byte" diff -r "$tmp/moor-before-1/backgrounds" "$themes/moor/backgrounds"
check "the completed swap keeps the user's file byte for byte" cmp -s "$tmp/moor-before-1/notes.txt" "$themes/moor/notes.txt"
check "the completed swap keeps the new definition" cmp -s "$shelf/moor/theme.json" "$themes/moor/theme.json"
check "the completion removes the backup" test ! -e "$backup"
tinst "the completed install is current" "$cfg" "$rt_empty" 0 "ok up-to-date=moor" "" theme update moor
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366f9" } }')" "$(slots_json '#202020')"
interrupted "an update ended before an update exits 137" INTERRUPT_FROM
tinst "update restores the package before it updates" "$cfg" "$rt_empty" 0 "$any_out" "vgsh: recovered: theme=moor state=restored path=$themes/moor" theme update moor
check "the update after a restore keeps the backgrounds" diff -r "$tmp/moor-before-1/backgrounds" "$themes/moor/backgrounds"
check "the update after a restore lands the catalog's definition" cmp -s "$shelf/moor/theme.json" "$themes/moor/theme.json"
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366f8" } }')" "$(slots_json '#202020')"
interrupted "an update ended before a remove exits 137" INTERRUPT_FROM
tinst "remove restores the package, then deletes it" "$cfg" "$rt_empty" 0 "ok removed=moor" "vgsh: recovered: theme=moor state=restored path=$themes/moor" theme remove moor
check "remove leaves neither the package nor its backup" test ! -e "$themes/moor" -a ! -e "$backup"

# The interruption controls: a copy of vgsh whose changing verbs skip the
# recovery installs a fresh package over the one in the backup, and a judge
# copy whose update keeps the backup in the stage loses the package.
tinst "moor installs for the interruption controls" "$cfg" "$rt_empty" 0 "$any_out" "" theme install moor
mkdir -p "$themes/moor/backgrounds"; printf 'image\n' >"$themes/moor/backgrounds/a.png"
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366f7" } }')" "$(slots_json '#202020')"
interrupted "an update ended for the unrecovered control exits 137" INTERRUPT_FROM
tree_control unrecovered bin/vgsh '  node "$theme_judge" recover "$config_home/vgs" || exit $?' ''
tinst "the unrecovered mutant installs over the package in the backup" "$cfg" "$rt_empty" 0 "ok installed=moor path=$themes/moor" "" theme install moor
check "the unrecovered mutant's install has no backgrounds" test ! -e "$themes/moor/backgrounds"
unset THEME_BIN
tinst "remove clears the unrecovered mutant's install" "$cfg" "$rt_empty" 0 "ok removed=moor" "vgsh: recovered: theme=moor state=completed path=$themes/moor" theme remove moor
tinst "moor installs for the staged-backup control" "$cfg" "$rt_empty" 0 "$any_out" "" theme install moor
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366f6" } }')" "$(slots_json '#202020')"
judge_control staged-backup 'const backup = path.join(configDir, BACKUP_PREFIX + name);' 'const backup = path.join(stage, "backup");'
interrupted "the staged-backup mutant is ended mid-update" INTERRUPT_FROM
check "the staged-backup mutant loses the package" test ! -e "$themes/moor" -a ! -e "$backup"
unset THEME_BIN
tinst "moor installs again after the interruption controls" "$cfg" "$rt_empty" 0 "$any_out" "" theme install moor

# A marker that is no marker refuses the list and the update; remove still
# deletes the package.
mkdir -p "$themes/fen"; doc fen >"$themes/fen/theme.json"; printf '{}\n' >"$themes/fen/.vgs-catalog.json"
tinst "update refuses a malformed marker" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=fen reason=marker path=$themes/fen/.vgs-catalog.json key=source" theme update fen
printf '{}\n' >"$themes/ivy/.vgs-catalog.json"
tinst "a malformed marker beside a .git is not read" "$cfg" "$rt_empty" 0 "$any_out" "" theme catalog
tinst "remove deletes a package with a malformed marker" "$cfg" "$rt_empty" 0 "ok removed=fen" "" theme remove fen

# The lock.
exec 7>>"$cfg/vgs/theme.lock"
flock 7
tinst "install while the theme lock is held is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: theme=bad reason=busy" theme install bad
check "a busy install leaves no staging directory" unstaged
tinst "update of a catalog install while the lock is held is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: theme=moor reason=busy" theme update moor
tree_control lockless bin/vgsh '  theme_lock_change "theme=$1"' ''
tinst "the lockless mutant installs under the held lock" "$cfg" "$rt_empty" 1 "" 'vgsh: refused: theme=bad reason=terminal-slot token=terminal missing=color1' theme install bad
unset THEME_BIN
exec 7>&-

# Remove.
tinst "remove deletes a catalog install" "$cfg" "$rt_empty" 0 "ok removed=moor" "" theme remove moor
check "catalog reports a removed install as not installed" test "$(state_of moor)" == "$not_installed"

# Must-fail controls, one per rule, each on a copy of the tree.
fresh() { rm -rf -- "${themes:?}/moor" "$themes/bad"; }
fresh
judge_control unjudged 'function judgeStaged(pkg, name) {' 'function judgeStaged(pkg, name) { return;'
tinst "the unjudged mutant installs a package the judge refuses" "$cfg" "$rt_empty" 0 "ok installed=bad path=$themes/bad" "" theme install bad
fresh
judge_control unmarked '    write(catalog.MARKER_FILE, catalog.markerText(digest, imagery));' ''
tinst "the unmarked mutant installs moor" "$cfg" "$rt_empty" 0 "ok installed=moor path=$themes/moor" "" theme install moor
check "the unmarked mutant's install carries no marker" test ! -e "$marker"
unset THEME_BIN
check "without its marker the install is no catalog install" test "$(state_of moor)" == "$not_installed"
fresh
judge_control marker-first 'if (fs.lstatSync(path.join(dir, ".git"), { throwIfNoEntry: false }) !== undefined) return { origin: "git", marker: null };' ''
rm -- "$themes/ivy/.vgs-catalog.json"; git -C "$themes/ivy" checkout -q -- .vgs-catalog.json
tinst "the marker-first mutant takes a git install for a catalog install" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=ivy reason=installed path=$themes/ivy" theme install ivy
unset THEME_BIN
tinst "moor installs for the update controls" "$cfg" "$rt_empty" 0 "$any_out" "" theme install moor
mkdir -p "$themes/moor/backgrounds"; printf 'image\n' >"$themes/moor/backgrounds/a.png"
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366fc" } }')" "$(slots_json '#202020')"
judge_control unkept 'kept = fs.readdirSync(from).filter(entry => !DEFINITION.includes(entry)).sort();' 'kept = [];'
tinst "the unkept mutant updates moor" "$cfg" "$rt_empty" 0 "$any_out" "" theme update moor
check "the unkept mutant loses the backgrounds" test ! -e "$themes/moor/backgrounds/a.png"
unset THEME_BIN
printf '\n' >>"$themes/moor/theme.json"
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366fb" } }')" "$(slots_json '#202020')"
judge_control unguarded 'if (packageDigest(digestRow(dir, key), key) !== marker.digest) refuse(' 'if (false) refuse('
tinst "the unguarded mutant updates over a hand edit" "$cfg" "$rt_empty" 0 "$any_out" "" theme update moor
check "the unguarded mutant replaces the hand edit" cmp -s "$shelf/moor/theme.json" "$themes/moor/theme.json"
unset THEME_BIN
printf '{"source":"catalog","digest":%s,"imagery":%s}\n' "$(marker_field "$marker" digest)" "$(pin moor-r0 "$sha_b")" >"$marker"
theme_pkg "$shelf/moor" "$(doc moor '{ "palette": { "accent": "#3366fa" } }')" "$(slots_json '#202020')"
judge_control unpinned 'stageCatalog(source, pkg, marker.imagery, key);' 'stageCatalog(source, pkg, null, key);'
tinst "the unpinned mutant updates moor" "$cfg" "$rt_empty" 0 "$any_out" "" theme update moor
check "the unpinned mutant drops the unpacked imagery's pin" test "$(marker_field "$marker" imagery)" == null
unset THEME_BIN

rows_done test-vgsh-catalog
