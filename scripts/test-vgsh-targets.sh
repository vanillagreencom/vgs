#!/usr/bin/env bash
# Controls for targets in `vgsh theme apply` beyond foot: a target whose
# wiring names a section keeps its include line in that section of its
# application's configuration file, and each shipped terminal target lands
# its file, keeps its include line and runs its reload, and a target whose
# wiring is null lands with nothing kept outside the state directory. Every
# command a target detects with and the command a reload signals with are
# stubs on the rows' PATH, under a temporary HOME, XDG_CONFIG_HOME and
# XDG_RUNTIME_DIR, so no row reaches a real application or the developer's
# session.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
export THEME_PATH="$stubs:$theme_path"
cfg="$tmp/cfg-targets"; mkdir -p "$cfg/vgs"; live="$state/theme"
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222", "foreground": "#eeeeee" } } }'
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

# The shipped terminal targets. Each is detected by a stub of its command,
# which records a run and exits 1, so detection never runs it. Their reload
# hooks run a real sh, id and touch; the signal command is a stub recording
# its arguments that exits with $tmp/signal-exit (1, no process matched,
# when absent), and touch reaches only this suite's configuration home. The
# targets are data: the judge rules these rows reach have their controls in
# test-vgsh.sh, test-vgsh-reload.sh and the section control above.
hook_tools="$tmp/hook-tools"; mkdir -p "$hook_tools"
for tool in sh id touch; do
  tool_bin="$(command -v "$tool")" || { echo "test-vgsh-targets: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$hook_tools/$tool"
done
for stub in alacritty ghostty kitty wezterm; do
  printf '#!/bin/sh\n: >"%s/ran-$(basename "$0")"\nexit 1\n' "$tmp" >"$stubs/$stub"
  chmod +x "$stubs/$stub"
done
signals="$tmp/signals"
cat >"$stubs/pkill" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$signals"
st=1
[ -f "$tmp/signal-exit" ] && read -r st <"$tmp/signal-exit"
exit "\$st"
EOF
chmod +x "$stubs/pkill"
export THEME_PATH="$stubs:$hook_tools:$theme_path"
uid="$(id -u)"
pending="$state/reload-pending.json"
cfg="$tmp/cfg-terminals"; mkdir -p "$cfg/vgs" "$cfg/kitty" "$cfg/alacritty" "$cfg/wezterm"
printf 'font_size 11\n' >"$cfg/kitty/kitty.conf"
printf '[general]\nlive_config_reload = true\n\n[window]\nopacity = 0.9\n' >"$cfg/alacritty/alacritty.toml"
wezterm_own=$'local wezterm = require \'wezterm\'\nlocal config = wezterm.config_builder()\nconfig.font_size = 11\nreturn config'
printf '%s\n' "$wezterm_own" >"$cfg/wezterm/wezterm.lua"
terminals() { # ALACRITTY GHOSTTY KITTY WEZTERM: each a state and a JSON reason
  printf '[{"name":"alacritty","state":"%s","reason":%s},{"name":"foot","state":"skipped","reason":"not-detected"},{"name":"ghostty","state":"%s","reason":%s},{"name":"kitty","state":"%s","reason":%s},{"name":"wezterm","state":"%s","reason":%s}]' $1 $2 $3 $4
}
written="written null"
signalled() { # WANT: the signal command's argument lines since the last `: >"$signals"`
  [[ "$(cat "$signals")" == "$1" ]]
}
both_signals="-USR2 -x -u $uid ghostty"$'\n'"-USR1 -x -u $uid kitty"

: >"$signals"
tinst "the terminal targets land" "$cfg" "$rt_empty" 0 "{\"state\":\"applied\",\"shell\":\"applied\",\"targets\":$(terminals "$written" "$written" "$written" "$written"),\"theme\":\"dusk\",\"reason\":null}" "" theme apply --json dusk
# Each file with the hex6 encoder: dusk's accent is #111111, the table's
# foreground #d7d7d9 and the shipped slots' color1 #f43f5e.
while IFS='|' read -r file want; do
  check "$file holds: $want" grep -qxF -- "$want" "$live/$file"
done <<'EOF'
kitty.conf|url_color #111111
kitty.conf|foreground #d7d7d9
kitty.conf|color1 #f43f5e
ghostty.conf|foreground = #d7d7d9
ghostty.conf|palette = 1=#f43f5e
alacritty.toml|foreground = "#d7d7d9"
alacritty.toml|red = "#f43f5e"
wezterm.lua|        foreground = '#d7d7d9',
wezterm.lua|        ansi = { '#0b0b0b', '#f43f5e', '#b4c96f', '#ffb000', '#74a7f7', '#a855f7', '#06b6d4', '#d7d7d9' },
wezterm.lua|    config.color_scheme = 'vgs'
EOF
check "the rendered alacritty.toml is TOML with the colours in their tables" python3 -c 'import sys, tomllib; c = tomllib.load(open(sys.argv[1], "rb"))["colors"]; sys.exit(0 if (c["primary"]["foreground"], c["normal"]["red"], len(c["normal"]), len(c["bright"])) == ("#d7d7d9", "#f43f5e", 8, 8) else 1)' "$live/alacritty.toml"
check "kitty.conf takes the include line first" test "$(cat "$cfg/kitty/kitty.conf")" == "include $live/kitty.conf"$'\nfont_size 11'
check "an absent config.ghostty is created holding the config-file line" test "$(cat "$cfg/ghostty/config.ghostty")" == "config-file = ?$live/ghostty.conf"
check "alacritty.toml takes the import in its general table" test "$(cat "$cfg/alacritty/alacritty.toml")" == $'[general]\nimport = ["'"$live"$'/alacritty.toml"]\nlive_config_reload = true\n\n[window]\nopacity = 0.9'
check "the wired alacritty.toml is TOML importing the theme" python3 -c 'import sys, tomllib; c = tomllib.load(open(sys.argv[1], "rb")); sys.exit(0 if c["general"] == {"import": [sys.argv[2]], "live_config_reload": True} and c["window"] == {"opacity": 0.9} else 1)' "$cfg/alacritty/alacritty.toml" "$live/alacritty.toml"
check "wezterm.lua runs the theme first and keeps its own text" test "$(cat "$cfg/wezterm/wezterm.lua")" == "pcall(dofile, \"$live/wezterm.lua\")"$'\n'"$wezterm_own"
check "the landed hooks signal ghostty and kitty by exact name for this user" signalled "$both_signals"
check "a signal that matched no process leaves nothing pending" test ! -e "$pending"
check "detection never ran a terminal" test -z "$(find "$tmp" -maxdepth 1 -name 'ran-*' -print)"

# Changed bytes touch the files alacritty and wezterm watch, whose wiring
# already stands; unchanged bytes touch and signal nothing.
touch -d @1000 -- "$cfg/alacritty/alacritty.toml" "$cfg/wezterm/wezterm.lua"
: >"$signals"
tinst "a changed theme reloads the terminals" "$cfg" "$rt_empty" 0 "ok theme=nord state=applied shell=applied" "" theme apply nord
check "the alacritty hook touched alacritty.toml" test "$(stat -c %Y -- "$cfg/alacritty/alacritty.toml")" != 1000
check "the wezterm hook touched wezterm.lua" test "$(stat -c %Y -- "$cfg/wezterm/wezterm.lua")" != 1000
check "a changed theme signals ghostty and kitty again" signalled "$both_signals"
touch -d @1000 -- "$cfg/alacritty/alacritty.toml" "$cfg/wezterm/wezterm.lua"
: >"$signals"
tinst "an unchanged theme reloads nothing" "$cfg" "$rt_empty" 0 "ok theme=nord state=unchanged shell=unchanged" "" theme apply nord
check "unchanged bytes touch neither watched file" test "$(stat -c %Y -- "$cfg/alacritty/alacritty.toml" "$cfg/wezterm/wezterm.lua" | tr '\n' ' ')" == "1000 1000 "
check "unchanged bytes signal nothing" signalled ""

# A signal command that fails leaves both signalled targets pending, and
# `vgsh theme reload` runs them again.
printf '2\n' >"$tmp/signal-exit"
: >"$signals"
failed="reload-pending \"reload-failed\""
tinst "a failing signal leaves its targets reload-pending" "$cfg" "$rt_empty" 3 "{\"state\":\"partial\",\"shell\":\"applied\",\"targets\":$(terminals "$written" "$failed" "$failed" "$written"),\"theme\":\"dusk\",\"reason\":null}" "vgsh: refused: target=ghostty reason=reload-failed command=sh status=1" theme apply --json dusk
check "the failed reloads are pending" test "$(cat "$pending")" == '{"schemaVersion":1,"targets":["ghostty","kitty"]}'
rm -- "$tmp/signal-exit"
: >"$signals"
tinst "reload signals the pending terminals" "$cfg" "$rt_empty" 0 "ok reload state=reloaded" "" theme reload
check "reload signalled ghostty and kitty" signalled "$both_signals"
check "a reload that succeeds clears the pending terminals" test ! -e "$pending"

# wezterm.lua is never created: WezTerm reads its defaults without one.
rm -- "$cfg/wezterm/wezterm.lua"
tinst "an absent wezterm.lua skips wezterm" "$cfg" "$rt_empty" 0 "{\"state\":\"applied\",\"shell\":\"applied\",\"targets\":$(terminals "$written" "$written" "$written" 'skipped "wiring-file-absent"'),\"theme\":\"nord\",\"reason\":null}" "" theme apply --json nord
check "an absent wezterm.lua stays absent" test ! -e "$cfg/wezterm/wezterm.lua"

# An import of the file's own in general would be a second import key,
# which TOML refuses: alacritty fails and its file is left byte for byte.
printf '[general]\nimport = ["~/.config/alacritty/mine.toml"]\n' >"$cfg/alacritty/alacritty.toml"
cp -- "$cfg/alacritty/alacritty.toml" "$tmp/alacritty-own"
conflict="vgsh: refused: target=alacritty reason=wiring-conflict path=$cfg/alacritty/alacritty.toml section=general key=import"
tinst "an alacritty.toml with its own import fails alacritty" "$cfg" "$rt_empty" 3 "$any_out" "$conflict" theme apply --json dusk
tail -n 1 "$tmp/out" >"$tmp/apply.json"
check "the conflicting alacritty is failed wiring-conflict" json_is "$tmp/apply.json" 'd["state"] == "partial" and [t for t in d["targets"] if t["name"] == "alacritty"] == [{"name": "alacritty", "state": "failed", "reason": "wiring-conflict"}]'
check "a conflicting alacritty.toml is left byte for byte" cmp -s "$tmp/alacritty-own" "$cfg/alacritty/alacritty.toml"
# The must-fail control: a judge copy that takes the refusal for a file
# already wired reports alacritty landed.
judge_control conflict-swallowed 'if (typeof next !== "string") return {' 'if (typeof next !== "string") return null; if (false) return {'
tinst "the conflict-swallowing mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json nord
tail -n 1 "$tmp/out" >"$tmp/apply.json"
check "the conflict-swallowing mutant reports alacritty landed" test "$(target_state alacritty)" == written
unset THEME_BIN

# A null wiring keeps nothing outside the state directory: the target lands
# its file, and disabled it only leaves theme/.
mkdir -p "$tree/themes/targets/bare"
printf '%s\n' '{ "app": "bare", "encoder": "hex6", "files": [{ "template": "bare.conf", "destination": "bare.conf" }], "detect": [], "wiring": null, "reload": null }' >"$tree/themes/targets/bare/target.json"
printf 'accent=@{palette.accent}\n' >"$tree/themes/targets/bare/bare.conf"
rm -- "$cfg/alacritty/alacritty.toml"
apply_json "a target with a null wiring applies" 0 nord
check "the unwired target is written" test "$(target_state bare)" == written
check "the unwired target's file lands in theme/" test "$(cat "$live/bare.conf")" == "accent=222222"
check "nothing outside the state directory names the unwired target" test -z "$(find "$cfg" "$tmp/home" -path "$state" -prune -o -name '*bare*' -print)"
printf '{ "disabledTargets": ["bare"] }\n' >"$cfg/vgs/shell.json"
apply_json "a disabled target with a null wiring" 0 dusk
check "the disabled unwired target is skipped" test "$(target_state bare)" == skipped
check "the disabled unwired target's file leaves theme/" test ! -e "$live/bare.conf"
rm -- "$cfg/vgs/shell.json"
# The must-fail control: a judge copy that plans a null wiring as absent
# skips the target.
judge_control none-skipped '        case "none":' '        case "none": return "wiring-file-absent";'
apply_json "the none-skipping mutant applies" 0 nord
check "the none-skipping mutant skips the unwired target" test "$(target_state bare)" == skipped
unset THEME_BIN
rm -r -- "$tree/themes/targets/bare"

rows_done test-vgsh-targets
