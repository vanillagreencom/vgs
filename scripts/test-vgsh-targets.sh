#!/usr/bin/env bash
# Controls for the wiring of targets in `vgsh theme apply` beyond the first
# line: a target whose wiring names a section keeps its include line in that
# section of its application's configuration file. Every command a target
# detects or reloads with is a stub on the rows' PATH under a temporary HOME
# and XDG_RUNTIME_DIR, so no row reaches a real application or the
# developer's session.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
export THEME_PATH="$stubs:$theme_path"
cfg="$tmp/cfg-targets"; mkdir -p "$cfg/vgs"; live="$state/theme"
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222" } } }'
target_state() { # NAME: the target's state in $tmp/apply.json
  python3 -c 'import json,sys; print([t["state"] for t in json.load(open(sys.argv[1]))["targets"] if t["name"] == sys.argv[2]][0])' "$tmp/apply.json" "$1"
}
apply_json() { # NAME WANT_EXIT PACKAGE: apply with --json into $tmp/apply.json
  tinst "$1" "$cfg" "$rt_empty" "$2" "$any_out" "" theme apply --json "$3"
  tail -n 1 "$tmp/out" >"$tmp/apply.json"
}

# A section: the line goes after the first header of the section, a file
# without one takes the header and the line at its end, and the file's own
# text is kept.
mkdir -p "$tree/themes/targets/sect" "$cfg/sect"
printf '%s\n' '{ "app": "sect", "encoder": "hex6", "files": [{ "template": "sect.toml", "destination": "sect.toml" }], "detect": [], "wiring": { "file": "sect/sect.toml", "line": "import = [\"@{state}/sect.toml\"]", "create": true, "section": "general" }, "reload": null }' >"$tree/themes/targets/sect/target.json"
printf 'accent = "#@{palette.accent}"\n' >"$tree/themes/targets/sect/sect.toml"
sect_line="import = [\"$live/sect.toml\"]"
printf '[window]\nx = 1\n[general]\nlive = true\n' >"$cfg/sect/sect.toml"
apply_json "a target with a section applies" 0 dusk
check "the sectioned target is written" test "$(target_state sect)" == written
check "the include line goes after its section's header" test "$(cat "$cfg/sect/sect.toml")" == $'[window]\nx = 1\n[general]\n'"$sect_line"$'\nlive = true'
printf '[window]\nx = 1\n' >"$cfg/sect/sect.toml"
tinst "a file without the section is wired" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "a file without the section takes its header and the line at its end" test "$(cat "$cfg/sect/sect.toml")" == $'[window]\nx = 1\n[general]\n'"$sect_line"
rm -- "$cfg/sect/sect.toml"
tinst "an absent sectioned file is created" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "an absent file becomes the header and the line" test "$(cat "$cfg/sect/sect.toml")" == $'[general]\n'"$sect_line"
# The must-fail control: a judge copy that drops the section puts the line
# first, where a TOML file reads it outside its table.
printf '[general]\nlive = true\n' >"$cfg/sect/sect.toml"
judge_control section-dropped '"utf8").toString("latin1"), target.wiring.section);' '"utf8").toString("latin1"));'
tinst "the section-dropping mutant applies" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "the section-dropping mutant puts the line first" test "$(head -n 1 "$cfg/sect/sect.toml")" == "$sect_line"
unset THEME_BIN
rm -r -- "$tree/themes/targets/sect"

rows_done test-vgsh-targets
