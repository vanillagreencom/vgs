#!/usr/bin/env bash
# The editor targets on the entry wiring, helix, zed and vscode, through
# `vgsh theme apply`: each renders its hand-written lines with its encoder
# into a document its application parses, is skipped when its command is not
# on PATH, keeps its links in its application's theme or extension
# directory, takes a package's curated file where the target accepts it, and
# helix runs its reload hook. Every command is a stub on the rows' PATH, sh
# included, under a temporary HOME and XDG_RUNTIME_DIR, so no row signals an
# editor or reaches the developer's session. The controls at the end apply a
# tree copy whose target.json lacks one rule and require the row's
# assertion to turn.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree helix vscode zed
home="$tmp/home"; live="$state/theme"; hook_args="$tmp/sh-args"

# Detection never runs a command: helix, zeditor and code record a run and
# exit 1. sh, the helix hook's command, records its arguments one per line.
for stub in helix zeditor code; do
  printf '#!/bin/sh\n: >"%s/ran-$(basename "$0")"\nexit 1\n' "$tmp" >"$stubs/$stub"
  chmod +x "$stubs/$stub"
done
printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s"\n' "$hook_args" >"$stubs/sh"
chmod +x "$stubs/sh"
with_stubs="$stubs:$theme_path"

# `dusk` and `nord` carry no terminal.json, so every slot is the shipped vgs
# slot: color1 #f43f5e, color2 #b4c96f. `curated` ships a file for each
# editor, vscode's a colour theme; `omarchy` ships vscode.json as Omarchy's
# packages do, naming an extension, which is no colour theme.
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222" } } }'
for pkg in curated omarchy; do
  theme_pkg "$tree/themes/$pkg" "{ \"schemaVersion\": 1, \"name\": \"$pkg\", \"tokens\": {} }"
  mkdir -p "$tree/themes/$pkg/targets"
done
printf '"ui.background" = { bg = "#123456" }\n' >"$tree/themes/curated/targets/helix.toml"
printf '{ "name": "mine", "author": "me", "themes": [] }\n' >"$tree/themes/curated/targets/zed.json"
printf '{ "name": "mine", "type": "dark", "colors": { "editor.background": "#123456" } }\n' >"$tree/themes/curated/targets/vscode.json"
printf '{\n  "name": "Tokyo Night",\n  "extension": "enkia.tokyo-night"\n}\n' >"$tree/themes/omarchy/targets/vscode.json"

cfg="$tmp/cfg-editors"; mkdir -p "$cfg/vgs"
helix_link="$cfg/helix/themes/vgs.toml"; zed_link="$cfg/zed/themes/vgs.json"; ext="$home/.vscode/extensions/vgs-theme"
result() { # HELIX VSCODE ZED: each `state` or `state:reason`
  local out="" t s
  for t in helix:"$1" vscode:"$2" zed:"$3"; do
    s="${t#*:}"
    if [[ $s == *:* ]]; then s="\"state\":\"${s%%:*}\",\"reason\":\"${s#*:}\""; else s="\"state\":\"$s\",\"reason\":null"; fi
    out+="${out:+,}{\"name\":\"${t%%:*}\",$s}"
  done
  printf '{"state":"applied","shell":"applied","targets":[%s],"theme":"%s","reason":null}' "$out" "$4"
}
links_to() { [[ -L $1 && "$(readlink -- "$1")" == "$2" ]]; } # PATH TARGET
# Every colour of a document: each `"#..."` string in it.
colours() { grep -oE '"#[^"]*"' -- "$1"; }
colours_are() { # FILE REGEX: every colour matches, and there is one
  local found
  found="$(colours "$1")" || return 1
  ! grep -qvxE "\"#$2\"" <<<"$found"
}
toml_parses() { python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' "$1"; }
json_value() { # FILE PYTHON_EXPR_ON_d WANT
  local got
  got="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null)" || return 1
  [[ $got == "$3" ]]
}
hook_ran_pinned() {
  [[ "$(cat -- "$hook_args")" == "-c"$'\n'"pkill -USR1 -x -u \"\$(id -u)\" 'hx|helix'; [ \$? -le 1 ]" ]]
}

tinst "an apply with no editor on PATH skips all three" "$cfg" "$rt_empty" 0 "$(result skipped:not-detected skipped:not-detected skipped:not-detected dusk)" "" theme apply --json dusk
check "an undetected editor gets no directory" test ! -e "$cfg/helix" -a ! -e "$cfg/zed" -a ! -e "$home/.vscode"
check "an undetected helix runs no hook" test ! -e "$hook_args"

THEME_PATH="$with_stubs" tinst "the three editors land" "$cfg" "$rt_empty" 0 "$(result written written written nord)" "" theme apply --json nord
check "helix's link names its state file" links_to "$helix_link" "$live/helix.toml"
check "zed's link names its state file" links_to "$zed_link" "$live/zed.json"
check "vscode's owned extension directory holds its two links" test "$(find "$ext" -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ')" == "package.json vgs-color-theme.json "
check "vscode's manifest link names its state file" links_to "$ext/package.json" "$live/vscode.package.json"
check "vscode's theme link names its state file" links_to "$ext/vgs-color-theme.json" "$live/vscode.json"
check "helix's theme is TOML" toml_parses "$helix_link"
check "helix takes the accent as #rrggbb" grep -qxF 'special = "#222222"' "$helix_link"
check "helix takes the background token" grep -qxF '"ui.background" = { bg = "#000000" }' "$helix_link"
check "helix takes the shipped slots" grep -qxF 'string = "#b4c96f"' "$helix_link"
check "every helix colour is #rrggbb" colours_are "$helix_link" '[0-9a-f]{6}'
check "zed's theme family names vgs" json_value "$zed_link" 'd["themes"][0]["name"]' vgs
check "zed takes the accent as #rrggbbaa" json_value "$zed_link" 'd["themes"][0]["style"]["text.accent"]' '#222222ff'
check "zed takes the shipped slots" json_value "$zed_link" 'd["themes"][0]["style"]["terminal.ansi.red"]' '#f43f5eff'
check "every zed colour is #rrggbbaa" colours_are "$zed_link" '[0-9a-f]{8}'
check "vscode's manifest contributes the linked theme" json_value "$ext/package.json" 'd["contributes"]["themes"][0]["path"]' ./vgs-color-theme.json
check "vscode takes the accent as #rrggbbaa" json_value "$ext/vgs-color-theme.json" 'd["colors"]["focusBorder"]' '#222222ff'
check "vscode takes the background token" json_value "$ext/vgs-color-theme.json" 'd["colors"]["editor.background"]' '#000000ff'
check "vscode takes the shipped slots" json_value "$ext/vgs-color-theme.json" 'd["colors"]["terminal.ansiRed"]' '#f43f5eff'
check "every vscode colour is #rrggbbaa" colours_are "$ext/vgs-color-theme.json" '[0-9a-f]{8}'
check "helix's hook signals Helix and tolerates none running" hook_ran_pinned
rm -f -- "$hook_args"
THEME_PATH="$with_stubs" tinst "unchanged bytes" "$cfg" "$rt_empty" 0 "ok theme=nord state=unchanged shell=unchanged" "" theme apply nord
check "unchanged bytes run no helix hook" test ! -e "$hook_args"

THEME_PATH="$with_stubs" tinst "a package's curated editor files land" "$cfg" "$rt_empty" 0 "$(result written written written curated)" "" theme apply --json curated
check "helix takes the curated theme byte for byte" cmp -s -- "$tree/themes/curated/targets/helix.toml" "$helix_link"
check "zed takes the curated theme byte for byte" cmp -s -- "$tree/themes/curated/targets/zed.json" "$zed_link"
check "vscode takes a curated colour theme byte for byte" cmp -s -- "$tree/themes/curated/targets/vscode.json" "$ext/vgs-color-theme.json"
THEME_PATH="$with_stubs" tinst "a package whose vscode.json names an extension" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json omarchy
check "vscode renders its own theme in place of an extension pointer" json_value "$ext/vgs-color-theme.json" 'd["colors"]["focusBorder"]' '#ff5a36ff'

# A theme of the user's at helix's link path is kept and skips the target;
# a disabled vscode loses its owned directory.
rm -- "$helix_link"; printf 'mine\n' >"$helix_link"
printf '{ "disabledTargets": ["vscode"] }\n' >"$cfg/vgs/shell.json"
THEME_PATH="$with_stubs" tinst "a user's vgs.toml and a disabled vscode" "$cfg" "$rt_empty" 0 "$(result skipped:entry-occupied skipped:disabled written dusk)" "" theme apply --json dusk
check "the user's vgs.toml is kept" test "$(cat -- "$helix_link")" == mine
check "a disabled vscode's extension directory is removed" test ! -e "$ext" -a -d "$home/.vscode/extensions"
check "detection ran no editor" test ! -e "$tmp/ran-helix" -a ! -e "$tmp/ran-zeditor" -a ! -e "$tmp/ran-code"

# Controls: each mutant target.json drops one rule, and the assertion that
# pins it must turn. The rows above use the same assertions.
control_cfg() { cfg="$tmp/cfg-$1"; mkdir -p "$cfg/vgs"; rm -rf -- "$hook_args" "$home/.vscode"; helix_link="$cfg/helix/themes/vgs.toml"; zed_link="$cfg/zed/themes/vgs.json"; }
turned() { test "$("$@"; echo $?)" == 1; } # CMD...: the assertion fails
tree_control helix-encoder themes/targets/helix/target.json '"encoder": "hex6"' '"encoder": "hex8"'
control_cfg helix-encoder
THEME_PATH="$with_stubs" tinst "the helix hex8 mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the helix hex8 mutant's theme is linked" test -s "$helix_link"
check "the helix hex8 mutant's colours are not #rrggbb" turned colours_are "$helix_link" '[0-9a-f]{6}'
tree_control zed-encoder themes/targets/zed/target.json '"encoder": "hex8"' '"encoder": "hex6"'
control_cfg zed-encoder
THEME_PATH="$with_stubs" tinst "the zed hex6 mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the zed hex6 mutant's theme is linked" test -s "$zed_link"
check "the zed hex6 mutant's colours are not #rrggbbaa" turned colours_are "$zed_link" '[0-9a-f]{8}'
tree_control vscode-encoder themes/targets/vscode/target.json '"encoder": "hex8"' '"encoder": "hex6"'
control_cfg vscode-encoder
THEME_PATH="$with_stubs" tinst "the vscode hex6 mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the vscode hex6 mutant's theme is linked" test -s "$ext/vgs-color-theme.json"
check "the vscode hex6 mutant's colours are not #rrggbbaa" turned colours_are "$ext/vgs-color-theme.json" '[0-9a-f]{8}'
tree_control vscode-any-curated themes/targets/vscode/target.json ', "curatedKeys": ["colors", "tokenColors", "semanticTokenColors"]' ''
control_cfg vscode-any-curated
THEME_PATH="$with_stubs" tinst "the any-curated mutant applies the extension pointer" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply omarchy
check "the any-curated mutant takes the extension pointer as its theme" cmp -s -- "$tree/themes/omarchy/targets/vscode.json" "$ext/vgs-color-theme.json"
check "the any-curated mutant's theme is not the render" turned json_value "$ext/vgs-color-theme.json" 'd["colors"]["focusBorder"]' '#ff5a36ff'
tree_control vscode-config-base themes/targets/vscode/target.json '"base": "home"' '"base": "config"'
control_cfg vscode-config-base
THEME_PATH="$with_stubs" tinst "the config-base mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the config-base mutant lands its links under the configuration home" test -L "$cfg/.vscode/extensions/vgs-theme/package.json"
check "the config-base mutant misses VS Code's extensions directory" turned test -L "$ext/package.json"
tree_control helix-hook themes/targets/helix/target.json '; [ $? -le 1 ]' ''
control_cfg helix-hook
# The state directory is shared, so the package changes to change bytes.
THEME_PATH="$with_stubs" tinst "the no-helix-tolerance mutant applies changed bytes" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the no-helix-tolerance mutant's hook ran" test -s "$hook_args"
check "the no-helix-tolerance mutant's hook is not the pinned argv" turned hook_ran_pinned
unset THEME_BIN

rows_done test-vgsh-editor-entries
