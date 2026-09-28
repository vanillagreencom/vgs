#!/usr/bin/env bash
# Controls for the entry wiring of `vgsh theme apply`: a target whose wiring
# names links keeps one symlink per link in its application's theme or
# extension directory, pointing at its file in the state directory's
# theme/, and edits no configuration file. A path something else holds is
# never replaced, and a disabled target loses only its own links and its
# owned directory. Only fixture targets run here, every command is a stub on
# the rows' PATH, and HOME and XDG_RUNTIME_DIR are temporary, so no row
# reaches a real application or the developer's session.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
export THEME_PATH="$stubs:$theme_path"
home="$tmp/home"; live="$state/theme"
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222" } } }'

# `lnk` links one file into its application's own themes directory under
# the configuration home; `occ` does the same where the rows put something
# of the user's; `ext` owns an extension directory under HOME holding two
# links, as a local editor extension is laid out.
entry_target() { # NAME WIRING_JSON FILES_JSON
  mkdir -p "$tree/themes/targets/$1"
  printf '{ "app": "%s", "encoder": "hex6", "files": %s, "detect": [], "wiring": %s, "reload": null }\n' "$1" "$3" "$2" >"$tree/themes/targets/$1/target.json"
}
for name in lnk occ; do
  entry_target "$name" "{ \"base\": \"config\", \"dir\": \"$name/themes\", \"owned\": false, \"links\": { \"vgs.toml\": \"$name.toml\" } }" "[{ \"template\": \"$name.toml\", \"destination\": \"$name.toml\" }]"
  printf 'accent = "#@{palette.accent}"\n' >"$tree/themes/targets/$name/$name.toml"
done
entry_target ext '{ "base": "home", "dir": ".ext/extensions/vgs-theme", "owned": true, "links": { "package.json": "ext.pkg.json", "vgs-color-theme.json": "ext.json" } }' '[{ "template": "theme.json", "destination": "ext.json" }, { "template": "package.json", "destination": "ext.pkg.json" }]'
printf '{ "colors": { "editor.background": "#@{color.background}", "focusBorder": "#@{palette.accent}" } }\n' >"$tree/themes/targets/ext/theme.json"
printf '{ "name": "vgs-theme" }\n' >"$tree/themes/targets/ext/package.json"

target_state() { # NAME: the target's [state, reason] in $tmp/apply.json
  python3 -c 'import json,sys; print(*[(t["state"], t["reason"]) for t in json.load(open(sys.argv[1]))["targets"] if t["name"] == sys.argv[2]][0])' "$tmp/apply.json" "$1"
}
apply_json() { # NAME WANT_EXIT PACKAGE [WANT_FIRST_STDERR]: apply with --json into $tmp/apply.json
  tinst "$1" "$cfg" "$rt_empty" "$2" "$any_out" "${4:-}" theme apply --json "$3"
  tail -n 1 "$tmp/out" >"$tmp/apply.json"
}
links_to() { [[ -L $1 && "$(readlink -- "$1")" == "$2" ]]; } # PATH TARGET
names_in() { [[ "$(find "$1" -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ')" == "$2" ]]; } # DIR "NAME ..."
ext_dir="$home/.ext/extensions/vgs-theme"
disable() { printf '{ "disabledTargets": [%s] }\n' "$1" >"$cfg/vgs/shell.json"; }
# Each case starts from no configuration and no extension directory, with
# lnk's directory a dotfile manager's link into another tree and occ's
# link path holding the user's own file.
fresh() { # NAME
  cfg="$tmp/cfg-$1"; mkdir -p "$cfg/vgs" "$tmp/dotfiles-$1/lnk/themes" "$cfg/occ/themes"
  rm -rf -- "$home/.ext"
  ln -s -- "$tmp/dotfiles-$1/lnk" "$cfg/lnk"
  printf 'mine\n' >"$cfg/occ/themes/vgs.toml"
}

fresh rows
apply_json "an apply with entry targets" 0 dusk
check "a linked target is written" test "$(target_state lnk)" == "written None"
check "an owning target is written" test "$(target_state ext)" == "written None"
check "a link stands in the application's directory, through the dotfile link, naming its state file" links_to "$tmp/dotfiles-rows/lnk/themes/vgs.toml" "$live/lnk.toml"
check "the dotfile manager's directory link stays a link" test -L "$cfg/lnk"
check "the link reads the rendered file" test "$(cat "$cfg/lnk/themes/vgs.toml")" == 'accent = "#111111"'
check "nothing else is written in the application's directory" names_in "$tmp/dotfiles-rows/lnk" "themes themes/vgs.toml "
check "an owned directory is created under HOME holding only its links" names_in "$ext_dir" "package.json vgs-color-theme.json "
check "an owned directory's links name their state files" links_to "$ext_dir/package.json" "$live/ext.pkg.json"
check "each link names its own state file" links_to "$ext_dir/vgs-color-theme.json" "$live/ext.json"
check "a path holding the user's file skips its target" test "$(target_state occ)" == "skipped entry-occupied"
check "the user's file is never replaced" test "$(cat "$cfg/occ/themes/vgs.toml")" == mine
if ! inode="$(stat -c %i -- "$cfg/lnk/themes/vgs.toml")"; then fail "the link can be read before the second package"; inode=none; fi
apply_json "a second package" 0 nord
check "a managed link is left as it is" test "$(stat -c %i -- "$cfg/lnk/themes/vgs.toml")" == "$inode"
check "the link reads the new render" test "$(cat "$cfg/lnk/themes/vgs.toml")" == 'accent = "#222222"'

# Something other than the managed link at a link's path, or a file where
# the directory belongs, is the user's: the target is skipped and the path
# kept as it was.
rm -- "$cfg/occ/themes/vgs.toml"; ln -s -- "$tmp/elsewhere.toml" "$cfg/occ/themes/vgs.toml"
apply_json "a foreign link at a link's path" 0 dusk
check "a foreign link skips its target" test "$(target_state occ)" == "skipped entry-occupied"
check "a foreign link is kept" links_to "$cfg/occ/themes/vgs.toml" "$tmp/elsewhere.toml"
rm -r -- "$cfg/occ/themes"; printf 'mine\n' >"$cfg/occ/themes"
apply_json "a file where the directory belongs" 0 nord
check "a file at the directory skips its target" test "$(target_state occ)" == "skipped entry-occupied"
check "the file at the directory is kept" test "$(cat "$cfg/occ/themes")" == mine
rm -- "$cfg/occ/themes"; mkdir -p "$cfg/occ/themes"; printf 'mine\n' >"$cfg/occ/themes/vgs.toml"

# A disabled target loses its own links and its owned directory once that
# is empty; the application's directory, anything the user put there and a
# path the target never managed stay.
printf 'yours\n' >"$cfg/lnk/themes/other.toml"
disable '"lnk", "ext", "occ"'
apply_json "disabling the entry targets" 0 dusk
check "a disabled target is skipped" test "$(target_state lnk)" == "skipped disabled"
check "a disabled target's link is removed and the rest of its directory stays" names_in "$tmp/dotfiles-rows/lnk" "themes themes/other.toml "
check "a disabled target's owned directory is removed" test ! -e "$ext_dir" -a -d "$home/.ext/extensions"
check "a disabled target's files leave theme/" test ! -e "$live/lnk.toml" -a ! -e "$live/ext.json"
check "a disabled target never removes the user's file" test "$(cat "$cfg/occ/themes/vgs.toml")" == mine
disable ''
apply_json "enabling them again" 0 nord
check "the links come back" links_to "$ext_dir/package.json" "$live/ext.pkg.json"
printf 'notes\n' >"$ext_dir/notes.txt"
disable '"ext"'
apply_json "disabling an owned directory the user wrote into" 0 dusk
check "an owned directory holding the user's file keeps it and loses the links" names_in "$ext_dir" "notes.txt "

# Controls: each judge copy drops one rule, and the row that pins it turns.
control() { # NAME NEEDLE REPLACEMENT
  judge_control "$1" "$2" "$3"; fresh "$1"
}
control any-link-managed 'stat.isSymbolicLink() && fs.readlinkSync(file) === to ?' 'stat.isSymbolicLink() ?'
rm -- "$cfg/occ/themes/vgs.toml"; ln -s -- "$tmp/elsewhere.toml" "$cfg/occ/themes/vgs.toml"
disable '"occ"'
apply_json "the any-link mutant disables occ" 0 dusk
check "the any-link mutant removes a link it never made" test ! -L "$cfg/occ/themes/vgs.toml"
control no-plan-check 'if (occupied !== undefined) return path.join(dir, occupied.name);' ''
apply_json "the no-plan-check mutant applies" 3 dusk "vgsh: refused: target=occ reason=entry-occupied path=$cfg/occ/themes/vgs.toml"
check "the no-plan-check mutant fails the occupied target instead of skipping it" test "$(target_state occ)" == "failed entry-occupied"
control never-rmdir 'if (target.wiring.owned) writing(dir, key, () => {' 'if (false) writing(dir, key, () => {'
apply_json "the never-rmdir mutant applies" 0 dusk
disable '"ext"'
apply_json "the never-rmdir mutant disables ext" 0 nord
check "the never-rmdir mutant leaves the owned directory" test -d "$ext_dir"
control rm-recursive 'fs.rmdirSync(dir);' 'fs.rmSync(dir, { recursive: true });'
apply_json "the recursive mutant applies" 0 dusk
printf 'notes\n' >"$ext_dir/notes.txt"
disable '"ext"'
apply_json "the recursive mutant disables ext" 0 nord
check "the recursive mutant deletes the user's file" test ! -e "$ext_dir/notes.txt"
control remove-any 'if (linkState(file, link.to) === "managed") fs.unlinkSync(file);' 'fs.rmSync(file, { force: true });'
disable '"occ"'
apply_json "the remove-any mutant disables occ" 0 dusk
check "the remove-any mutant deletes the user's file" test ! -e "$cfg/occ/themes/vgs.toml"
control home-as-config 'case "home": return os.homedir();' 'case "home": return configHome;'
apply_json "the home-as-config mutant applies" 0 dusk
check "the home-as-config mutant puts the owned directory under the configuration home" test -d "$cfg/.ext/extensions/vgs-theme" -a ! -e "$ext_dir"
unset THEME_BIN

# The cache base: `dir` is under ${XDG_CACHE_HOME:-~/.cache}, the fallback
# when the variable is unset and the variable when it is set.
entry_target cch '{ "base": "cache", "dir": "wal", "owned": false, "links": { "colors.json": "cch.json" } }' '[{ "template": "cch.json", "destination": "cch.json" }]'
printf '{ "special": { "background": "#@{color.background}" } }\n' >"$tree/themes/targets/cch/cch.json"
fresh cache
apply_json "a cache target without XDG_CACHE_HOME" 0 dusk
check "a cache target is written" test "$(target_state cch)" == "written None"
check "a cache target's link stands under ~/.cache" links_to "$home/.cache/wal/colors.json" "$live/cch.json"
xdg_cache="$tmp/xdg-cache"
base_env+=(XDG_CACHE_HOME="$xdg_cache")
apply_json "a cache target under XDG_CACHE_HOME" 0 nord
check "a cache target's link stands under XDG_CACHE_HOME" links_to "$xdg_cache/wal/colors.json" "$live/cch.json"
judge_control cache-as-home 'process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache")' 'path.join(os.homedir(), ".cache")'
rm -r -- "$xdg_cache"
apply_json "the cache-as-home mutant applies" 0 dusk
check "the cache-as-home mutant ignores XDG_CACHE_HOME" test ! -e "$xdg_cache/wal/colors.json"
unset THEME_BIN

rows_done test-vgsh-entries
