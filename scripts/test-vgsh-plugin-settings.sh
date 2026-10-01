#!/usr/bin/env bash
# Controls for `vgsh plugin settings <id>`: the settings one plugin hands its
# service, panel and floating TUIs, read offline from the shipped and user
# shell.json through bin/vgsh-plugin-judge. Every row runs a copy of the
# tree whose bundled plugin directory is empty, against a fixture plugin in
# the row's own user plugin directory, so no shipped plugin's defaults and
# no developer configuration reach a row. Each control runs the rows
# against a copy of the tree whose judge drops one rule, and a row must
# fail.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

tree="$tmp/tree"
mkdir -p "$tree/shell/Core" "$tree/shell/Commons" "$tree/shell/Ui/icons" "$tree/shell/plugins" "$tree/config"
cp -R -- "$repo/bin" "$tree/"
cp -- "$repo/shell/Core/PluginLogic.js" "$repo/shell/Core/PackageManagers.js" "$repo/shell/Core/HyprlandLayer.js" "$tree/shell/Core/"
cp -- "$repo/shell/Commons/SettingValues.js" "$tree/shell/Commons/"
cp -- "$repo/shell/Ui/icons/Lucide.js" "$tree/shell/Ui/icons/"
printf '{ "version": 1, "plugins": [], "disabledPlugins": [] }\n' >"$tree/config/shell.json"

cfg="$tmp/cfg"
probe="$cfg/vgs/plugins/acme.probe"
mkdir -p "$probe"
manifest acme.probe 0.1.0 ', "settings": { "mode": "fast", "count": 2, "trust": false },
  "schema": { "mode": { "type": "enum", "label": "Mode", "options": ["fast", "slow"] }, "count": { "type": "number", "label": "Count", "min": 1, "max": 9 }, "trust": { "type": "boolean", "label": "Trust" } }' >"$probe/manifest.json"
printf 'import QtQuick\nItem { property var shell: null }\n' >"$probe/Service.qml"
user_file() { printf '%s\n' "$1" >"$cfg/vgs/shell.json"; } # JSON

# settings_of BIN ID...: `BIN plugin settings ID...` against $cfg; stdout
# in $out, the first stderr line in $err, the exit status in $status.
settings_of() {
  local bin="$1"
  shift
  status=0
  out="$("${base_env[@]}" XDG_CONFIG_HOME="$cfg" "$bin" plugin settings "$@" 2>"$tmp/err" </dev/null)" || status=$?
  err=""
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  return 0
}

# Rows: name | user shell.json, `-` for none | id | exit | stdout | first stderr line
rows=(
  "the manifest's defaults with no user file|-|acme.probe|0|{\"mode\":\"fast\",\"count\":2,\"trust\":false}|"
  "the user's plugins row over the defaults|{ \"plugins\": [{ \"id\": \"acme.probe\", \"count\": 5, \"trust\": true }] }|acme.probe|0|{\"mode\":\"fast\",\"count\":5,\"trust\":true}|"
  "a value the schema refuses|{ \"plugins\": [{ \"id\": \"acme.probe\", \"trust\": \"yes\" }] }|acme.probe|1||vgsh: refused: setting=trust want=boolean id=acme.probe"
  "a number past the schema's bound|{ \"plugins\": [{ \"id\": \"acme.probe\", \"count\": 12 }] }|acme.probe|1||vgsh: refused: setting=count want=at-most:9 id=acme.probe"
  "an id no plugin has|-|acme.none|1||vgsh: refused: unknown=acme.none"
  "no id|-||2||vgsh: refused: id=missing"
)
# settings_rows BIN QUIET: every row through BIN; prints ok and FAIL lines
# unless QUIET is `quiet`; returns the number of failing rows.
settings_rows() {
  local row name file id want_exit want_out want_err args red=0
  for row in "${rows[@]}"; do
    IFS='|' read -r name file id want_exit want_out want_err <<<"$row"
    if [[ $file == - ]]; then rm -f -- "$cfg/vgs/shell.json"; else user_file "$file"; fi
    args=()
    [[ -z $id ]] || args=("$id")
    settings_of "$1" "${args[@]}"
    if [[ $status == "$want_exit" && $out == "$want_out" && $err == "$want_err" ]]; then
      [[ $2 == quiet ]] || ok "$name"
    else
      red=$((red + 1))
      [[ $2 == quiet ]] || fail "$name: exit=$status want=$want_exit out=[$out] want=[$want_out] err=[$err] want=[$want_err]"
    fi
  done
  return "$red"
}
settings_rows "$tree/bin/vgsh" loud || true

user_file '{ "plugins": 3 }'
settings_of "$tree/bin/vgsh" acme.probe
check "a user file the config judge refuses is refused" test "$status:${err%% error=*}" == "1:vgsh: refused: user-config=malformed path=$cfg/vgs/shell.json"
settings_of "$tree/bin/vgsh" acme.probe extra
check "a second argument is refused" test "$status:$err" == "2:vgsh: refused: argument=extra"

# Controls: a judge copy that reads no user file, and one that hands a
# value the schema refuses through.
control() { # NAME NEEDLE REPLACEMENT
  local copy_tree="$tmp/tree-$1"
  cp -R -- "$tree" "$copy_tree"
  copy_with "$1" "$tree/bin/vgsh-plugin-judge" "$2" "$3"
  cp -- "$copy" "$copy_tree/bin/vgsh-plugin-judge"
  check "the $1 mutant fails a row" test "$(settings_rows "$copy_tree/bin/vgsh" quiet && echo green || echo red)" == red
}
control ignores-user 'settingsFor(logic.effectiveConfig(shipped, user)' 'settingsFor(logic.effectiveConfig(shipped, null)'
control skips-schema 'if (refusal !== "") refuse(refusal.slice(' 'if (false) refuse(refusal.slice('

rows_done test-vgsh-plugin-settings
