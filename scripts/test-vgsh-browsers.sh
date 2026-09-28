#!/usr/bin/env bash
# Controls for the shipped browser targets, themes/targets/zen,
# themes/targets/pywalfox and themes/targets/chromium: the files `vgsh theme
# apply` renders, the import line it keeps first in each Zen profile's
# chrome/userChrome.css, the colors.json link it keeps in pywal's cache
# directory, pywalfox's reload hook, chromium's setup skip and its hook's
# colour argument, and how `vgsh theme browser-policy` runs the writer.
# zen-browser, pywalfox, chromium and vgs-browser-policy are stubs on the
# rows' PATH, under a temporary HOME, XDG_CONFIG_HOME, XDG_CACHE_HOME and
# XDG_RUNTIME_DIR, so no row reaches a real browser, the system policy or
# the developer's session. bin/vgsh-browser-policy has its own suite,
# scripts/test-vgsh-browser-policy.sh.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree chromium pywalfox zen
runs="$tmp/browser-runs"; pending="$state/reload-pending.json"; live="$state/theme"
home="$tmp/home"; cache="$tmp/xdg-cache"
base_env+=(XDG_CACHE_HOME="$cache")
# zen-browser is detected and never run: its stub records a run and exits 1.
# pywalfox records its arguments and exits with the status $tmp/pywalfox-exit
# holds, 0 when absent, as `pywalfox update` exits with no browser connected.
cat >"$stubs/zen-browser" <<EOF
#!/bin/sh
printf 'zen-browser %s\n' "\$*" >>"$runs"
exit 1
EOF
cat >"$stubs/pywalfox" <<EOF
#!/bin/sh
printf 'pywalfox %s\n' "\$*" >>"$runs"
st=0
[ -f "$tmp/pywalfox-exit" ] && read -r st <"$tmp/pywalfox-exit"
exit "\$st"
EOF
chmod +x "$stubs/zen-browser" "$stubs/pywalfox"
export THEME_PATH="$stubs:$theme_path"

# dusk carries its own slots, color<N> being #0000<N in hex>, so each
# written slot names the one it came from.
slots="$(python3 -c 'import json; print(json.dumps({"schemaVersion": 1, "slots": {f"color{i}": f"#0000{i:02x}" for i in range(16)}}))')"
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#112233", "background": "#0a0b0c", "foreground": "#d0d1d2" } } }' "$slots"
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#445566" } } }'
fresh() { : >"$runs"; }
ran() { [[ "$(cat "$runs")" == "$1" ]]; }
apply_json() { # NAME WANT_EXIT WANT_FIRST_STDERR PACKAGE: an apply with --json into $tmp/apply.json
  tinst "$1" "$cfg" "$rt_empty" "$2" "$any_out" "$3" theme apply --json "$4"
  tail -n 1 "$tmp/out" >"$tmp/apply.json"
}
verdict() { # NAME: the target's state and reason in $tmp/apply.json
  python3 -c 'import json,sys; print(*[(t["state"], t["reason"]) for t in json.load(open(sys.argv[1]))["targets"] if t["name"] == sys.argv[2]][0])' "$tmp/apply.json" "$1"
}
import_line="@import url(\"file://$live/zen.css\");"
imports_first() { # USERCHROME OWN_TEXT
  [[ "$(head -n 1 -- "$1")" == "$import_line" && "$(tail -n +2 -- "$1")" == "$2" ]]
}
# pywalfox.json parses, holds a wallpaper, dusk's special colours and the
# sixteen slots in order.
pywal_json() {
  python3 - "$live/pywalfox.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "wallpaper" in d and d["alpha"] == "100", d
assert d["special"] == {"background": "#0a0b0c", "foreground": "#d0d1d2", "cursor": "#d0d1d2"}, d["special"]
assert list(d["colors"]) == [f"color{i}" for i in range(16)], d["colors"]
assert all(d["colors"][f"color{i}"] == f"#0000{i:02x}" for i in range(16)), d["colors"]
PY
}

# A new Zen install keeps its profiles.ini under ~/.config/zen, found by
# HOME while XDG_CONFIG_HOME names $cfg. pywal's directory is created
# under XDG_CACHE_HOME holding only the link.
cfg="$tmp/cfg-browsers"; mkdir -p "$cfg/vgs" "$home/.config/zen/xdg.default"
printf '[Profile0]\nName=default\nIsRelative=1\nPath=xdg.default\n' >"$home/.config/zen/profiles.ini"
fresh
apply_json "an apply with both browsers succeeds" 0 "" dusk
check "zen is written" test "$(verdict zen)" == "written None"
check "pywalfox is written" test "$(verdict pywalfox)" == "written None"
check "zen's accent is written as #rrggbb" grep -qxF -- '  --toolbarbutton-icon-fill: #112233 !important;' "$live/zen.css"
check "zen's background is written as #rrggbb" grep -qxF -- '  --zen-main-browser-background: #0a0b0c !important;' "$live/zen.css"
check "zen's container colours are terminal slots" grep -qxF -- '  --identity-tab-color: #00000c !important;' "$live/zen.css"
check "a profile's userChrome.css is created holding only the import" test "$(cat "$home/.config/zen/xdg.default/chrome/userChrome.css")" == "$import_line"
check "pywalfox.json is pywal's colors.json with sixteen slots" pywal_json
check "colors.json links to the state directory's pywalfox.json" test -L "$cache/wal/colors.json" -a "$(readlink -- "$cache/wal/colors.json")" == "$live/pywalfox.json"
check "nothing else is written in pywal's directory" test "$(ls -A -- "$cache/wal")" == colors.json
check "zen-browser is never run and pywalfox update runs once" ran "pywalfox update"
check "a hook that exits 0 leaves nothing pending" test ! -e "$pending"
fresh
apply_json "an apply of unchanged bytes succeeds" 0 "" dusk
check "unchanged bytes run no hook" ran ""

# Zen keeps ~/.zen when it exists: its profiles.ini is read first and the
# profile's own userChrome.css keeps its text after the import.
mkdir -p "$home/.zen/legacy.default/chrome"
printf '[Profile0]\nName=default\nIsRelative=1\nPath=legacy.default\n' >"$home/.zen/profiles.ini"
printf '#nav-bar { order: 1 }\n' >"$home/.zen/legacy.default/chrome/userChrome.css"
cp -- "$home/.config/zen/xdg.default/chrome/userChrome.css" "$tmp/xdg-before"
apply_json "an apply with a ~/.zen profile succeeds" 0 "" nord
check "the ~/.zen profile takes the import first and keeps its own text" imports_first "$home/.zen/legacy.default/chrome/userChrome.css" '#nav-bar { order: 1 }'
check "the ~/.config/zen profile is no longer written" cmp -s -- "$tmp/xdg-before" "$home/.config/zen/xdg.default/chrome/userChrome.css"

# pywalfox update failing leaves the target pending until a reload runs it.
printf '1\n' >"$tmp/pywalfox-exit"; fresh
apply_json "an apply whose pywalfox update fails is partial" 3 "vgsh: refused: target=pywalfox reason=reload-failed command=pywalfox status=1" dusk
check "a failing pywalfox update is reload-pending" test "$(verdict pywalfox)" == "reload-pending reload-failed"
check "the failed reload is pending" test "$(cat "$pending")" == '{"schemaVersion":1,"targets":["pywalfox"]}'
printf '0\n' >"$tmp/pywalfox-exit"; fresh
tinst "a reload runs pywalfox update again" "$cfg" "$rt_empty" 0 '{"state":"reloaded","targets":[{"name":"pywalfox","state":"reloaded","reason":null}],"reason":null}' "" theme reload --json
check "the reload ran pywalfox update once" ran "pywalfox update"
check "a successful reload clears the pending state" test ! -e "$pending"

# chromium is detected by its stub, which is never run. Until the setup
# command is on PATH the target is skipped; with it, the hook passes the
# background as six hex digits to vgs-browser-policy on every apply, which
# records its arguments and exits with $tmp/policy-exit, 0 when absent.
browsers_path="$tmp/browsers"; setup_path="$tmp/setup"; mkdir -p "$browsers_path" "$setup_path"
for tool in sh cat; do ln -s -- "$(command -v "$tool")" "$browsers_path/$tool"; done
cat >"$browsers_path/chromium" <<EOF
#!/bin/sh
printf 'chromium %s\n' "\$*" >>"$runs"
exit 1
EOF
cat >"$setup_path/vgs-browser-policy" <<EOF
#!/bin/sh
printf 'vgs-browser-policy %s\n' "\$*" >>"$runs"
st=0
[ -f "$tmp/policy-exit" ] && read -r st <"$tmp/policy-exit"
exit "\$st"
EOF
chmod +x "$browsers_path/chromium" "$setup_path/vgs-browser-policy"
without_setup="$browsers_path:$stubs:$theme_path"; with_setup="$setup_path:$without_setup"
cfg="$tmp/cfg-chromium"; mkdir -p "$cfg/vgs"
THEME_PATH="$without_setup"; fresh
apply_json "an apply without the browser policy setup succeeds" 0 "" dusk
check "chromium without its setup is skipped setup-absent" test "$(verdict chromium)" == "skipped setup-absent"
check "chromium without its setup lands no file" test ! -e "$live/chromium.color"
THEME_PATH="$with_setup"; fresh
apply_json "an apply with the setup succeeds" 0 "" dusk
check "chromium with its setup is written" test "$(verdict chromium)" == "written None"
check "chromium.color holds the background as six hex digits" test "$(cat "$live/chromium.color")" == 0a0b0c
check "the hook runs the writer with the colour and never runs chromium" ran "vgs-browser-policy 0a0b0c"
fresh
apply_json "an unchanged apply succeeds" 0 "" dusk
check "chromium's unchanged bytes are unchanged" test "$(verdict chromium)" == "unchanged None"
check "the hook runs on unchanged bytes too" ran "vgs-browser-policy 0a0b0c"
printf '1\n' >"$tmp/policy-exit"; fresh
apply_json "an apply whose policy write fails is partial" 3 "vgsh: refused: target=chromium reason=reload-failed command=sh status=1" dusk
check "a failed policy write is reload-pending" test "$(verdict chromium)" == "reload-pending reload-failed"
check "the failed policy write is pending" test "$(cat "$pending")" == '{"schemaVersion":1,"targets":["chromium"]}'
THEME_PATH="$without_setup"; fresh
tinst "a reload without the setup skips chromium" "$cfg" "$rt_empty" 0 '{"state":"reloaded","targets":[{"name":"chromium","state":"skipped","reason":"setup-absent"}],"reason":null}' "" theme reload --json
check "the skipped reload runs no hook" ran ""
check "the skipped reload leaves nothing pending" test ! -e "$pending"
rm -f -- "$tmp/policy-exit"

# `vgsh theme browser-policy install` runs the tree's writer with `install`
# alone; any other form is refused before it runs.
cat >"$tree/bin/vgsh-browser-policy" <<EOF
#!/bin/sh
printf 'writer %s\n' "\$*" >>"$runs"
EOF
fresh
tinst "browser-policy install runs the writer" "$cfg" "$rt_empty" 0 "" "" theme browser-policy install
check "the writer runs once with install" ran "writer install"
fresh
tinst "browser-policy without install is refused" "$cfg" "$rt_empty" 2 "" "vgsh: refused: browser-policy-subcommand=remove" theme browser-policy remove
tinst "browser-policy with an extra argument is refused" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=now" theme browser-policy install now
check "a refused browser-policy runs no writer" ran ""
cp -- "$repo/bin/vgsh-browser-policy" "$tree/bin/vgsh-browser-policy"
THEME_PATH="$stubs:$theme_path"

# Must-fail controls, each on a copy of the tree whose target.json breaks
# one rule the rows above hold.
tree_control zen-hex8 themes/targets/zen/target.json '"encoder": "hex6"' '"encoder": "hex8"'
apply_json "the zen hex8 mutant applies" 0 "" nord
check "the zen hex8 mutant writes the accent with its alpha" grep -qxF -- '  --toolbarbutton-icon-fill: #445566ff !important;' "$live/zen.css"
tree_control zen-xdg-first themes/targets/zen/target.json '[".zen/profiles.ini", ".config/zen/profiles.ini"]' '[".config/zen/profiles.ini", ".zen/profiles.ini"]'
rm -- "${home:?}/.config/zen/xdg.default/chrome/userChrome.css"
apply_json "the xdg-first mutant applies" 0 "" dusk
check "the xdg-first mutant writes the ~/.config/zen profile beside a ~/.zen one" test -e "$home/.config/zen/xdg.default/chrome/userChrome.css"
tree_control pywalfox-home themes/targets/pywalfox/target.json '"base": "cache"' '"base": "home"'
apply_json "the home-based pywalfox mutant applies" 0 "" nord
check "the home-based pywalfox mutant links outside XDG_CACHE_HOME" test -L "$home/wal/colors.json"
tree_control pywalfox-no-reload themes/targets/pywalfox/target.json '"reload": { "command": ["pywalfox", "update"], "timeoutMs": 5000 }' '"reload": null'
fresh
apply_json "the hookless pywalfox mutant applies changed bytes" 0 "" dusk
check "the hookless pywalfox mutant runs no hook" ran ""
tree_control chromium-sometimes themes/targets/chromium/target.json '"timeoutMs": 15000, "always": true' '"timeoutMs": 15000'
THEME_PATH="$with_setup"; cfg="$tmp/cfg-chromium-sometimes"; mkdir -p "$cfg/vgs"
apply_json "the sometimes mutant applies" 0 "" dusk
fresh
apply_json "the sometimes mutant applies unchanged bytes" 0 "" dusk
check "the sometimes mutant runs no hook on unchanged bytes" ran ""
judge_control setup-ignored-apply 'if (!render.setupDone(target, onPath)) return "setup-absent";' ''
THEME_PATH="$without_setup"; cfg="$tmp/cfg-setup-ignored"; mkdir -p "$cfg/vgs"
apply_json "the setup-ignoring apply mutant runs the hook" 3 "vgsh: refused: target=chromium reason=reload-failed command=sh status=127" dusk
judge_control setup-ignored-reload 'if (!setup.value) return skipped("setup-absent");' ''
tinst "the setup-ignoring reload mutant runs the hook" "$cfg" "$rt_empty" 3 "$any_out" "vgsh: refused: target=chromium reason=reload-failed command=sh status=127" theme reload --json
unset THEME_BIN THEME_PATH

rows_done test-vgsh-browsers
