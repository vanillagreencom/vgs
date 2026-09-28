#!/usr/bin/env bash
# Controls for targets in `vgsh theme apply` beyond foot: a target whose
# wiring names a section keeps its include line in that section of its
# application's configuration file, one whose wiring names a Mozilla
# profiles.ini keeps it in the file of every profile the ini lists, each
# shipped terminal target lands its file, keeps its include line and runs its
# reload, and a target whose wiring is null lands with nothing kept outside
# the state directory. Every command a target detects with and the command a
# reload signals with are stubs on the rows' PATH, under a temporary HOME,
# XDG_CONFIG_HOME and XDG_RUNTIME_DIR, so no row reaches a real application
# or the developer's session.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree alacritty foot ghostty kitty wezterm
export THEME_PATH="$stubs:$theme_path"
cfg="$tmp/cfg-targets"; mkdir -p "$cfg/vgs"; live="$state/theme"
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222", "foreground": "#eeeeee" } } }'
target_state() { # NAME: the target's state in $tmp/apply.json
  python3 -c 'import json,sys; print([t["state"] for t in json.load(open(sys.argv[1]))["targets"] if t["name"] == sys.argv[2]][0])' "$tmp/apply.json" "$1"
}
target_verdict() { # NAME: the target's state and reason in $tmp/apply.json
  python3 -c 'import json,sys; print(*[(t["state"], t["reason"]) for t in json.load(open(sys.argv[1]))["targets"] if t["name"] == sys.argv[2]][0])' "$tmp/apply.json" "$1"
}
apply_json() { # NAME WANT_EXIT PACKAGE [WANT_FIRST_STDERR]: apply with --json into $tmp/apply.json
  tinst "$1" "$cfg" "$rt_empty" "$2" "$any_out" "${4:-}" theme apply --json "$3"
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

# Profiles: `file` is relative to each profile directory the first of the
# inis under HOME that exists lists, a relative Path under the ini's own
# directory and an absolute one where it names; every listed profile whose
# directory exists is wired and unwired, and a section that names no profile
# is not one. The second ini is under HOME's .config while XDG_CONFIG_HOME
# names $cfg, so it is found by HOME alone.
home="$tmp/home"; ini="$home/.moz/profiles.ini"; ini2="$home/.config/moz/profiles.ini"
p0="$home/.moz/p0.default"; p1="$tmp/elsewhere/p1"; p2="$tmp/elsewhere/p2"
moz_target() { # CREATE
  mkdir -p "$tree/themes/targets/moz"
  printf '{ "app": "moz", "encoder": "hex6", "files": [{ "template": "moz.css", "destination": "moz.css" }], "detect": [], "wiring": { "file": "chrome/userChrome.css", "line": "@import url(\\"file://@{state}/moz.css\\");", "create": %s, "profiles": [".moz/profiles.ini", ".config/moz/profiles.ini"] }, "reload": null }\n' "$1" >"$tree/themes/targets/moz/target.json"
  printf ':root { --accent: #@{palette.accent}; }\n' >"$tree/themes/targets/moz/moz.css"
}
moz_ini() { # the first ini: a relative profile, an absolute one and an install section
  mkdir -p "$home/.moz"
  printf '[General]\nVersion=2\n\n[Profile0]\nName=default\nIsRelative=1\nPath=p0.default\n\n[Profile1]\nName=work\nIsRelative=0\nPath=%s\n\n[Install4F96D1932A9F858E]\nDefault=p0.default\nPath=%s\n' "$p1" "$tmp/install" >"$ini"
}
mkdir -p "$home/.config/moz"; printf '[Profile0]\nPath=%s\n' "$p2" >"$ini2"
moz_target true
moz_line="@import url(\"file://$live/moz.css\");"
apply_json "a profiles target whose one ini lists only absent profiles" 0 dusk
check "a profiles target with no listed profile directory is skipped" test "$(target_verdict moz)" == "skipped wiring-file-absent"
check "a skipped profiles target creates no profile" test ! -e "$p2" -a ! -e "$live/moz.css" -a ! -e "$cfg/chrome"
mkdir -p "$p2"
apply_json "a profiles target read from its second ini" 0 dusk
check "the second ini is read when the first is absent" test "$(cat "$p2/chrome/userChrome.css")" == "$moz_line"
rm -- "${p2:?}/chrome/userChrome.css"
mkdir -p "$p1/chrome"; printf '#nav-bar { order: 1 }\n' >"$p1/chrome/userChrome.css"
moz_ini
apply_json "a profiles target with its first ini" 0 nord
check "the profiles target is written" test "$(target_verdict moz)" == "written None"
check "a listed profile whose directory is absent is not created" test ! -e "$p0"
check "an absolute profile's file takes the line first and keeps its own text" test "$(cat "$p1/chrome/userChrome.css")" == "$moz_line"$'\n#nav-bar { order: 1 }'
check "the second ini is not read once the first exists" test ! -e "$p2/chrome/userChrome.css"
check "a section that names no profile is not wired" test ! -e "$tmp/install"
check "nothing is wired under the configuration home" test ! -e "$cfg/chrome"
mkdir -p "$p0"
apply_json "a profiles target once its relative profile exists" 0 nord
check "a relative profile's file is created holding the line" test "$(cat "$p0/chrome/userChrome.css")" == "$moz_line"
printf '{ "disabledTargets": ["moz"] }\n' >"$cfg/vgs/shell.json"
apply_json "disabling the profiles target" 0 dusk
check "a disabled profiles target leaves every profile's file without the line" test "$(cat "$p0/chrome/userChrome.css")" == "" -a "$(cat "$p1/chrome/userChrome.css")" == "#nav-bar { order: 1 }"
rm -- "${cfg:?}/vgs/shell.json"
moz_target false; rm -- "${p0:?}/chrome/userChrome.css"
apply_json "a profiles target with create false and one profile's file absent" 0 dusk
check "a profiles target with one file absent is skipped" test "$(target_verdict moz)" == "skipped wiring-file-absent"
check "a skipped profiles target leaves the other profile's file alone" test "$(cat "$p1/chrome/userChrome.css")" == "#nav-bar { order: 1 }"
moz_target true; mv -- "$ini" "$ini.saved"; mkdir -- "$ini"
apply_json "a profiles ini that cannot be read" 3 dusk "vgsh: refused: target=moz reason=unreadable path=$ini error=EISDIR"
check "an unreadable profiles ini fails its target" test "$(target_verdict moz)" == "failed unreadable"
printf '{ "disabledTargets": ["moz"] }\n' >"$cfg/vgs/shell.json"
apply_json "disabling a profiles target whose ini cannot be read" 3 dusk "vgsh: refused: target=moz reason=unreadable path=$ini error=EISDIR"
check "a disabled profiles target whose ini cannot be read fails" test "$(target_verdict moz)" == "failed unreadable"
rm -- "${cfg:?}/vgs/shell.json"
rmdir -- "$ini"; mv -- "$ini.saved" "$ini"
# Controls: each judge copy drops one rule, and the row that pins it turns.
# Each starts with no profile file wired.
moz_fresh() {
  rm -f -- "${p0:?}/chrome/userChrome.css" "${p1:?}/chrome/userChrome.css" "${p2:?}/chrome/userChrome.css" "${home:?}/p0.default/chrome/userChrome.css" "${cfg:?}/chrome/userChrome.css"
}
moz_fresh
judge_control profiles-ignored 'const selected = firstHomeRelative(wiring.profiles, readIfPresent);' 'return [path.join(configHome, wiring.file)];'
apply_json "the profiles-ignored mutant applies" 0 dusk
check "the profiles-ignored mutant wires the file under the configuration home" test -e "$cfg/chrome/userChrome.css" -a ! -e "$p0/chrome/userChrome.css"
moz_fresh; mkdir -p "$home/p0.default"
judge_control relative-under-home 'dir.relative ? path.join(path.dirname(selected.file), dir.path) : dir.path' 'dir.relative ? path.join(os.homedir(), dir.path) : dir.path'
apply_json "the relative-under-home mutant applies" 0 dusk
check "the relative-under-home mutant misses the ini's directory" test -e "$home/p0.default/chrome/userChrome.css" -a ! -e "$p0/chrome/userChrome.css"
moz_fresh
judge_control first-profile-only 'for (const file of files) {' 'for (const file of files.slice(0, 1)) {'
apply_json "the first-profile-only mutant applies" 0 dusk
check "the first-profile-only mutant leaves the second profile unwired" test -e "$p0/chrome/userChrome.css" -a ! -e "$p1/chrome/userChrome.css"
moz_fresh
judge_control last-ini-first 'for (const relative of relatives) {' 'for (const relative of relatives.slice().reverse()) {'
apply_json "the last-ini-first mutant applies" 0 dusk
check "the last-ini-first mutant wires the second ini's profile" test -e "$p2/chrome/userChrome.css" -a ! -e "$p0/chrome/userChrome.css"
moz_fresh; rmdir -- "$p0/chrome" "$p0"
judge_control stale-profile-created '.filter(isDirectory)' '.filter(dir => dir !== "")'
apply_json "the stale-profile-created mutant applies" 0 dusk
check "the stale-profile-created mutant creates an absent profile" test -e "$p0/chrome/userChrome.css"
moz_fresh; mv -- "$ini" "$ini.saved"; mv -- "$ini2" "$ini2.saved"
judge_control absent-ini-lands 'if (files.length === 0) return "wiring-file-absent";' 'if (false) return "wiring-file-absent";'
apply_json "the absent-ini-lands mutant applies" 0 nord
check "the absent-ini-lands mutant lands a target it wires nowhere" test "$(target_verdict moz)" == "written None"
mv -- "$ini.saved" "$ini"; mv -- "$ini2.saved" "$ini2"; moz_target false; printf 'x\n' >"$p1/chrome/userChrome.css"
judge_control every-file-absent 'files.some(file => fs.statSync(file, { throwIfNoEntry: false }) === undefined)' 'files.every(file => fs.statSync(file, { throwIfNoEntry: false }) === undefined)'
apply_json "the every-file-absent mutant applies" 3 dusk "vgsh: refused: target=moz reason=wiring-file-absent path=$p0/chrome/userChrome.css"
check "the every-file-absent mutant fails the target instead of skipping it" test "$(target_verdict moz)" == "failed wiring-file-absent"
unset THEME_BIN
rm -r -- "$tree/themes/targets/moz"

# The shipped terminal targets. Each is detected by a stub of its command,
# which records a run and exits 1, so detection never runs it. Their reload
# hooks run a real sh, id and touch; the signal command is a stub recording
# its arguments that exits with $tmp/signal-exit (1, no process matched,
# when absent), and touch reaches only this suite's HOME and configuration home. The
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
wezterm_home_own=$'return { font_size = 13 }'
printf '%s\n' "$wezterm_own" >"$cfg/wezterm/wezterm.lua"
mkdir -p "$home"; printf '%s\n' "$wezterm_home_own" >"$home/.wezterm.lua"; touch -d @1000 -- "$home/.wezterm.lua"
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
check "the config-home wezterm.lua wins over the HOME fallback" test "$(cat "$home/.wezterm.lua")" == "$wezterm_home_own" -a "$(stat -c %Y -- "$home/.wezterm.lua")" == 1000
check "the landed hooks signal ghostty and kitty by exact name for this user" signalled "$both_signals"
check "a signal that matched no process leaves nothing pending" test ! -e "$pending"
check "detection never ran a terminal" test -z "$(find "$tmp" -maxdepth 1 -name 'ran-*' -print)"

# Changed bytes touch the files alacritty and wezterm watch, whose wiring
# already stands; unchanged bytes touch and signal nothing.
touch -d @1000 -- "$cfg/alacritty/alacritty.toml" "$cfg/wezterm/wezterm.lua" "$home/.wezterm.lua"
: >"$signals"
tinst "a changed theme reloads the terminals" "$cfg" "$rt_empty" 0 "ok theme=nord state=applied shell=applied" "" theme apply nord
check "the alacritty hook touched alacritty.toml" test "$(stat -c %Y -- "$cfg/alacritty/alacritty.toml")" != 1000
check "the wezterm hook touched wezterm.lua" test "$(stat -c %Y -- "$cfg/wezterm/wezterm.lua")" != 1000
check "the wezterm hook left the HOME fallback untouched while config-home exists" test "$(stat -c %Y -- "$home/.wezterm.lua")" == 1000 -a "$(cat "$home/.wezterm.lua")" == "$wezterm_home_own"
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

# WezTerm loads the first existing configuration file: the config-home
# wezterm.lua, HOME/.config/wezterm/wezterm.lua when XDG_CONFIG_HOME points
# elsewhere, then HOME/.wezterm.lua.
rm -- "$cfg/wezterm/wezterm.lua"
printf '%s\n%s\n' "pcall(dofile, \"$live/wezterm.lua\")" "$wezterm_home_own" >"$home/.wezterm.lua"; touch -d @1000 -- "$home/.wezterm.lua"
apply_json "a HOME wezterm.lua fallback applies wezterm" 0 nord
check "the HOME wezterm.lua fallback is written" test "$(target_state wezterm)" == written
check "the include line goes into HOME/.wezterm.lua" test "$(cat "$home/.wezterm.lua")" == "pcall(dofile, \"$live/wezterm.lua\")"$'\n'"$wezterm_home_own"
check "a HOME wezterm.lua fallback leaves config-home absent" test ! -e "$cfg/wezterm/wezterm.lua"
check "the HOME wezterm.lua fallback hook touched the watched file" test "$(stat -c %Y -- "$home/.wezterm.lua")" != 1000
printf '{"schemaVersion":1,"targets":["wezterm"]}\n' >"$pending"
touch -d @1000 -- "$home/.wezterm.lua"
tinst "reload touches a pending HOME wezterm.lua" "$cfg" "$rt_empty" 0 "ok reload state=reloaded" "" theme reload
check "reload touched the HOME wezterm.lua fallback" test "$(stat -c %Y -- "$home/.wezterm.lua")" != 1000
check "reload cleared the pending wezterm hook" test ! -e "$pending"

printf '%s\n' "$wezterm_home_own" >"$home/.wezterm.lua"
judge_control fallbacks-ignored 'if (wiring.fallbacks === undefined || existingPath(configFile) !== undefined) return [configFile];' 'return [configFile]; if (false) return [configFile];'
apply_json "the fallbacks-ignored mutant applies" 0 dusk
check "the fallbacks-ignored mutant skips the HOME fallback" test "$(target_verdict wezterm)" == "skipped wiring-file-absent" -a ! -e "$cfg/wezterm/wezterm.lua"
unset THEME_BIN

printf '%s\n' "$wezterm_own" >"$cfg/wezterm/wezterm.lua"
printf '%s\n' "$wezterm_home_own" >"$home/.wezterm.lua"
judge_control fallback-before-file 'if (wiring.fallbacks === undefined || existingPath(configFile) !== undefined) return [configFile];' 'if (wiring.fallbacks === undefined) return [configFile];'
apply_json "the fallback-before-file mutant applies" 0 nord
check "the fallback-before-file mutant wires HOME instead of config-home" test "$(cat "$home/.wezterm.lua")" == "pcall(dofile, \"$live/wezterm.lua\")"$'\n'"$wezterm_home_own" -a "$(cat "$cfg/wezterm/wezterm.lua")" == "$wezterm_own"
unset THEME_BIN
rm -- "$cfg/wezterm/wezterm.lua"

printf '%s\n%s\n' "pcall(dofile, \"$live/wezterm.lua\")" "$wezterm_home_own" >"$home/.wezterm.lua"; touch -d @1000 -- "$home/.wezterm.lua"
touch -d @1000 -- "$live/wezterm.lua"
printf '{"schemaVersion":1,"targets":["wezterm"]}\n' >"$pending"
judge_control hook-not-wired-file 'render.reloadCommand(target, live, wiring.path);' 'render.reloadCommand(target, live, path.join(live, target.files[0].destination));'
tinst "the hook-not-wired-file mutant reloads" "$cfg" "$rt_empty" 0 "ok reload state=reloaded" "" theme reload
check "the hook-not-wired-file mutant touches the theme file instead of the wired HOME file" test "$(stat -c %Y -- "$home/.wezterm.lua")" == 1000 -a "$(stat -c %Y -- "$live/wezterm.lua")" != 1000
unset THEME_BIN

# With neither configuration file, wezterm.lua is never created: WezTerm
# reads its defaults without one.
rm -- "$home/.wezterm.lua"
tinst "an absent wezterm.lua skips wezterm" "$cfg" "$rt_empty" 0 "{\"state\":\"unchanged\",\"shell\":\"unchanged\",\"targets\":$(terminals 'unchanged null' 'unchanged null' 'unchanged null' 'skipped "wiring-file-absent"'),\"theme\":\"nord\",\"reason\":null}" "" theme apply --json nord
check "an absent wezterm.lua stays absent" test ! -e "$cfg/wezterm/wezterm.lua" -a ! -e "$home/.wezterm.lua"

# A one-line import array of the file's own in general takes the theme
# first, the rest of the file kept byte for byte; a second apply leaves it,
# and a disabled alacritty takes only its own entry back out.
printf '[general]\nimport = ["~/.config/alacritty/mine.toml"] # mine\nlive_config_reload = true\n' >"$cfg/alacritty/alacritty.toml"
cp -- "$cfg/alacritty/alacritty.toml" "$tmp/alacritty-own"
merged=$'[general]\nimport = ["'"$live"$'/alacritty.toml", "~/.config/alacritty/mine.toml"] # mine\nlive_config_reload = true'
apply_json "an alacritty.toml with its own import applies" 0 dusk
check "alacritty with its own import is written" test "$(target_state alacritty)" == written
check "the theme goes first in the file's own import array" test "$(cat "$cfg/alacritty/alacritty.toml")" == "$merged"
check "the merged alacritty.toml is TOML importing the theme before its own" python3 -c 'import sys, tomllib; c = tomllib.load(open(sys.argv[1], "rb")); sys.exit(0 if c["general"] == {"import": [sys.argv[2], "~/.config/alacritty/mine.toml"], "live_config_reload": True} else 1)' "$cfg/alacritty/alacritty.toml" "$live/alacritty.toml"
apply_json "a second apply over the merged import" 0 dusk
check "a second apply leaves the merged import" test "$(cat "$cfg/alacritty/alacritty.toml")" == "$merged"
printf '{ "disabledTargets": ["alacritty"] }\n' >"$cfg/vgs/shell.json"
apply_json "a disabled alacritty over the merged import" 0 dusk
check "the disabled alacritty is skipped" test "$(target_state alacritty)" == skipped
check "a disabled alacritty leaves the file's own import byte for byte" cmp -s "$tmp/alacritty-own" "$cfg/alacritty/alacritty.toml"
# The must-fail control: a judge copy that hands the removal no section
# leaves the theme's entry in the file's own array.
rm -- "$cfg/vgs/shell.json"
apply_json "alacritty merged again" 0 dusk
printf '{ "disabledTargets": ["alacritty"] }\n' >"$cfg/vgs/shell.json"
judge_control unwire-sectionless 'live, render.unwiredText);' 'live, (text, line) => render.unwiredText(text, line));'
apply_json "the sectionless-unwiring mutant applies" 0 dusk
check "the sectionless-unwiring mutant keeps the theme's entry" test "$(cat "$cfg/alacritty/alacritty.toml")" == "$merged"
unset THEME_BIN
rm -- "$cfg/vgs/shell.json"

# An import array that goes on past its line cannot take the theme without
# a second import key, which TOML refuses: alacritty fails and its file is
# left byte for byte.
printf '[general]\nimport = [\n  "~/.config/alacritty/mine.toml",\n]\n' >"$cfg/alacritty/alacritty.toml"
cp -- "$cfg/alacritty/alacritty.toml" "$tmp/alacritty-own"
conflict="vgsh: refused: target=alacritty reason=wiring-conflict path=$cfg/alacritty/alacritty.toml section=general key=import"
tinst "an alacritty.toml with a multi-line import fails alacritty" "$cfg" "$rt_empty" 3 "$any_out" "$conflict" theme apply --json dusk
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
