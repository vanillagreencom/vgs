#!/usr/bin/env bash
# Controls for following the applied theme package: the record `vgsh theme
# apply` keeps in applied.json, `vgsh theme follow`, the follow `vgsh theme
# update` ends with, and the `modified` flag `vgsh theme list` reads against
# the record. Each row pins an exit status, the last stdout line, the keyed
# stderr line, the record or the theme file's bytes.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
cfg="$tmp/cfg-follow"; themes="$cfg/vgs/themes"; file="$cfg/vgs/theme.json"; record="$state/applied.json"
mkdir -p "$cfg/vgs"

# dusk stands in the tree copy's shipped themes/, which a VGS update
# changes; fern is installed.
dusk="$tree/themes/dusk"
theme_pkg "$dusk" "$(doc dusk '{ "palette": { "accent": "#111111" } }')"
theme_pkg "$themes/fern" "$(doc fern)"

follow_line() { printf 'ok follow=%s theme=%s state=%s' "$1" "$2" "$3"; } # OUTCOME THEME STATE
# The record names NAME and holds the sha256 of FILE's bytes and a digest.
record_is() { # NAME FILE
  python3 -c 'import hashlib,json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if list(d) == ["schemaVersion", "name", "file", "package"] and d["schemaVersion"] == 1 and d["name"] == sys.argv[2] and d["file"] == hashlib.sha256(open(sys.argv[3], "rb").read()).hexdigest() and len(d["package"]) == 64 else 1)' "$record" "$1" "$2"
}
digest() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["package"])' "$record"; }
# `vgsh theme list --json`'s `modified` for CFG's theme file, as JSON.
modified_of() { # CFG
  "${base_env[@]}" PATH="$theme_path" XDG_CONFIG_HOME="$1" XDG_RUNTIME_DIR="$rt_empty" "${THEME_BIN:-$tree/bin/vgsh}" theme list --json |
    python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["file"]["modified"]))'
}

tinst "follow before any apply follows nothing" "$cfg" "$rt_empty" 0 "$(follow_line none - unchanged)" "" theme follow
check "a follow with no record writes none" test ! -e "$record"
tinst "dusk applies" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
check "apply records the package with the hash of the bytes it wrote" record_is dusk "$file"
tinst "follow of an unchanged package is current" "$cfg" "$rt_empty" 0 "$(follow_line current dusk unchanged)" "" theme follow
tinst "follow --json prints the structured result" "$cfg" "$rt_empty" 0 '{"state":"unchanged","shell":"unchanged","targets":[],"theme":"dusk","reason":null,"follow":"current"}' "" theme follow --json

# A shipped package changed under an unedited theme file, as a VGS update
# changes it: the file is unmodified until the follow, and the follow
# re-applies it.
before="$(digest)"
theme_pkg "$dusk" "$(doc dusk '{ "palette": { "accent": "#121212" } }')"
check "the unedited file of a changed package is unmodified" test "$(modified_of "$cfg")" == false
tinst "follow re-applies a changed package" "$cfg" "$rt_empty" 0 "$(follow_line reapplied dusk applied)" "" theme follow
check "the re-apply writes the package's new bytes" cmp -s "$dusk/theme.json" "$file"
check "the re-apply records the new digest" test "$(digest)" != "$before"
check "the re-apply records the bytes it wrote" record_is dusk "$file"
check "the re-applied file is unmodified" test "$(modified_of "$cfg")" == false

# Each part of the package's content: PART|TEXT|FOLLOW|STATE. terminal.json
# and a curated file re-apply with the shell file unchanged; a background is
# no colour.
while IFS='|' read -r part text want state_want; do
  before="$(digest)"
  mkdir -p "$(dirname -- "$dusk/$part")"
  printf '%s' "$text" >"$dusk/$part"
  tinst "a change to $part follows as $want" "$cfg" "$rt_empty" 0 "$(follow_line "$want" dusk "$state_want")" "" theme follow </dev/null
  if [[ $want == reapplied ]]; then moved=true; else moved=false; fi
  check "a change to $part moves the recorded digest: $moved" test "$([[ $(digest) != "$before" ]] && echo true || echo false)" == "$moved"
done <<EOF
terminal.json|$(slots_json '#0a0b0c')|reapplied|unchanged
targets/foot.ini|curated|reapplied|unchanged
backgrounds/a.png|image|current|unchanged
EOF
check "the followed terminal.json lands in the state directory" cmp -s "$dusk/terminal.json" "$state/theme/terminal.json"

# A hand edit stays and is modified, whatever the package does.
printf '\n' >>"$file"; cp -- "$file" "$tmp/edited.json"
check "a hand-edited file is modified" test "$(modified_of "$cfg")" == true
theme_pkg "$dusk" "$(doc dusk '{ "palette": { "accent": "#131313" } }')"
tinst "follow leaves a hand-edited file" "$cfg" "$rt_empty" 0 "$(follow_line edited dusk unchanged)" "" theme follow
check "the hand edit stays byte for byte" cmp -s "$tmp/edited.json" "$file"
check "the hand-edited file stays modified" test "$(modified_of "$cfg")" == true
rm -- "$file"
tinst "follow leaves a deleted theme file" "$cfg" "$rt_empty" 0 "$(follow_line edited dusk unchanged)" "" theme follow
check "the deleted theme file stays deleted" test ! -e "$file"

tinst "fern applies" "$cfg" "$rt_empty" 0 "ok theme=fern state=applied shell=applied" "" theme apply fern
mv -- "$themes/fern" "$tmp/fern"
tinst "follow of a package that is gone is unavailable" "$cfg" "$rt_empty" 0 "$(follow_line unavailable fern unchanged)" "" theme follow
check "an unavailable package leaves the theme file" cmp -s "$tmp/fern/theme.json" "$file"
mv -- "$tmp/fern" "$themes/fern"

# A record that is no record refuses the follow and the list; an apply
# writes a new one.
printf '{ "schemaVersion": 1, "name": "fern" }\n' >"$record"
tinst "follow refuses a malformed record" "$cfg" "$rt_empty" 1 '{"state":"failed","shell":"unchanged","targets":[],"theme":null,"reason":"malformed","follow":null}' "vgsh: refused: follow=applied reason=malformed path=$record" theme follow --json
tinst "list refuses a malformed record" "$cfg" "$rt_empty" 1 "" "vgsh: refused: themes=malformed path=$record" theme list
tinst "an apply over a malformed record succeeds" "$cfg" "$rt_empty" 0 "ok theme=fern state=unchanged shell=unchanged" "" theme apply fern
check "the apply replaces the malformed record" record_is fern "$file"

# Invocation and the lock.
tinst "follow with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=fern" theme follow fern
exec 7>>"$cfg/vgs/theme.lock"
flock 7
tinst "follow while the theme lock is held is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: follow=applied reason=busy" theme follow
judge_control busy 'const key = "follow=applied reason";' 'const key = "follow=applied reason"; lock = "held";'
tinst "the busy mutant follows under the held lock" "$cfg" "$rt_empty" 0 "$(follow_line current fern unchanged)" "" theme follow
unset THEME_BIN
exec 7>&-

# Update: an installed package fast-forwarded to a new colour re-applies
# when it is the applied package and its file is unedited, and its line is
# last; a hand edit stays; another package is not followed.
theme_source moss "$(doc moss)"
theme_source reed "$(doc reed)"
tinst "moss installs" "$cfg" "$rt_empty" 0 "ok added=moss path=$themes/moss" "" theme add "$tmp/tsrc/moss.git"
tinst "reed installs" "$cfg" "$rt_empty" 0 "ok added=reed path=$themes/reed" "" theme add "$tmp/tsrc/reed.git"
tinst "moss applies" "$cfg" "$rt_empty" 0 "ok theme=moss state=applied shell=applied" "" theme apply moss
theme_commit moss theme.json "$(doc moss '{ "palette": { "accent": "#123456" } }')"
tinst "update re-applies the applied, unedited package" "$cfg" "$rt_empty" 0 "$(follow_line reapplied moss applied)" "" theme update --yes moss
check "update reports the fast-forward before the follow" has_prefix "ok updated=moss from="
check "update's re-apply writes the new version's bytes" cmp -s "$themes/moss/theme.json" "$file"
check "the updated file is unmodified" test "$(modified_of "$cfg")" == false
theme_commit reed theme.json "$(doc reed '{ "palette": { "accent": "#654321" } }')"
tinst "update of a package that is not applied follows nothing" "$cfg" "$rt_empty" 0 "$(follow_line none - unchanged)" "" theme update --yes reed
check "an update of another package leaves the theme file" cmp -s "$themes/moss/theme.json" "$file"
printf '\n' >>"$file"; cp -- "$file" "$tmp/edited.json"
theme_commit moss theme.json "$(doc moss '{ "palette": { "accent": "#123457" } }')"
tinst "update leaves a hand-edited file" "$cfg" "$rt_empty" 0 "$(follow_line edited moss unchanged)" "" theme update --yes moss
check "update keeps the hand edit byte for byte" cmp -s "$tmp/edited.json" "$file"
check "the hand-edited file stays modified after an update" test "$(modified_of "$cfg")" == true

# A follow that is partial makes update's exit 3: a target that fails.
tinst "moss applies over the hand edit" "$cfg" "$rt_empty" 0 "ok theme=moss state=applied shell=applied" "" theme apply moss
target_dir fails "$(target_json fails hex6 '[]' 'include=@{state}/fails.conf' true)" 'x=@{palette.nope}'
theme_commit moss theme.json "$(doc moss '{ "palette": { "accent": "#123458" } }')"
tinst "update whose follow is partial exits 3" "$cfg" "$rt_empty" 3 "partial follow=reapplied theme=moss state=partial" 'vgsh: refused: target=fails reason=placeholder template=fails.conf placeholder="palette.nope"' theme update --yes moss
rm -r -- "$tree/themes/targets/fails"

# Must-fail controls, one per rule, each on a copy of the tree. Each starts
# from fern applied, unedited, with its package then changed.
fern_changed() { # ACCENT
  unset THEME_BIN
  theme_pkg "$themes/fern" "$(doc fern)"
  tinst "fern applies for a control" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply fern
  theme_pkg "$themes/fern" "$(doc fern "{ \"palette\": { \"accent\": \"$1\" } }")"
}
fern_changed '#212121'
rm -f -- "$record"
judge_control record '    replaceFile(path.join(stateDir, APPLIED_FILE), JSON.stringify({ schemaVersion: 1, name, file: sha256(row.files.theme), package: digest }) + "\n", key);' ''
tinst "the record mutant applies fern" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply fern
check "the record mutant's apply leaves no record" test ! -e "$record"

fern_changed '#222222'
judge_control current 'if (packageDigest(row, key) === applied.package) return settled("current");' 'return settled("current");'
tinst "the current mutant takes a changed package as current" "$cfg" "$rt_empty" 0 "$(follow_line current fern unchanged)" "" theme follow

fern_changed '#232323'
judge_control curated 'for (const file of targetFiles(row, key)) part(TARGETS + "/" + file.name, file.bytes);' ''
tinst "the curated mutant re-applies the colour change" "$cfg" "$rt_empty" 0 "$any_out" "" theme follow
mkdir -p "$themes/fern/targets"; printf 'curated\n' >"$themes/fern/targets/foot.ini"
tinst "the curated mutant takes a changed curated file as current" "$cfg" "$rt_empty" 0 "$(follow_line current fern unchanged)" "" theme follow
rm -r -- "$themes/fern/targets"

fern_changed '#242424'
printf '\n' >>"$file"
judge_control edited 'if (bytes === undefined || sha256(bytes) !== applied.file) return settled("edited");' ''
tinst "the edited mutant follows over a hand edit" "$cfg" "$rt_empty" 0 "$(follow_line reapplied fern applied)" "" theme follow
check "the edited mutant overwrites the hand edit" cmp -s "$themes/fern/theme.json" "$file"

fern_changed '#252525'
judge_control modified 'return !(applied !== null && applied.name === file.name && sha256(file.bytes) === applied.file);' 'return true;'
check "the modified mutant reports the unedited file of a changed package modified" test "$(modified_of "$cfg")" == true

unset THEME_BIN
tinst "moss applies for the update control" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply moss
theme_commit moss theme.json "$(doc moss '{ "palette": { "accent": "#123459" } }')"
tree_control update bin/vgsh '  exec node "$theme_judge" follow text "$config_home/vgs" "$state_home/vgs" held "$name"' ''
tinst "the update mutant fast-forwards" "$cfg" "$rt_empty" 0 "$any_out" "" theme update --yes moss
check "the update mutant's last line is the fast-forward" has_prefix "ok updated=moss from="
check "the update mutant leaves the old version's bytes" test "$(cmp -s "$themes/moss/theme.json" "$file"; echo $?)" == 1
unset THEME_BIN

rows_done test-vgsh-follow
