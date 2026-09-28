#!/usr/bin/env bash
# Controls for the rule that no theme package contributes a symlink below its
# own directory: a symlinked curated file, or every file under a symlinked
# targets/, is dropped and named on its target's apply row with the template
# rendered in its place, on a target that runs no code; a regular curated
# file there is taken; and a package whose theme.json or terminal.json is a
# symlink is refused `symlink` by list, apply and the install judge; and the
# applied record's digest leaves a symlinked file out, so follow sees no
# change behind a link. The rows run under a temporary HOME and
# XDG_CONFIG_HOME; the symlinks point at a file standing for one of the
# owner's own.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
cfg="$tmp/cfg-links"; themes="$cfg/vgs/themes"; mkdir -p "$themes"; live="$state/theme"
secret="$tmp/owner-file"; printf 'owner secret\n' >"$secret"
target_dir plain '{ "app": "plain", "runsCode": false, "encoder": "hex6", "files": [{ "template": "plain.conf", "destination": "plain.conf" }], "detect": [], "wiring": null, "reload": null }' $'accent=@{palette.accent}\n'
pkg() { theme_pkg "$themes/$1" "{ \"schemaVersion\": 1, \"name\": \"$1\", \"tokens\": { \"palette\": { \"accent\": \"#444444\" } } }"; }
pkg linked; mkdir -p "$themes/linked/targets"; ln -s -- "$secret" "$themes/linked/targets/plain.conf"
pkg dirlinked; mkdir -p "$tmp/elsewhere"; cp -- "$secret" "$tmp/elsewhere/plain.conf"; ln -s -- "$tmp/elsewhere" "$themes/dirlinked/targets"
pkg regular; mkdir -p "$themes/regular/targets"; printf 'mine\n' >"$themes/regular/targets/plain.conf"
pkg linkdoc; mv -- "$themes/linkdoc/theme.json" "$tmp/linkdoc.json"; ln -s -- "$tmp/linkdoc.json" "$themes/linkdoc/theme.json"
pkg linkslots; slots_json '#555555' >"$tmp/slots.json"; ln -s -- "$tmp/slots.json" "$themes/linkslots/terminal.json"

apply_json() { # NAME WANT_EXIT PACKAGE [WANT_FIRST_STDERR]: apply with --json into $tmp/apply.json
  tinst "$1" "$cfg" "$rt_empty" "$2" "$any_out" "${4:-}" theme apply --json "$3"
  tail -n 1 "$tmp/out" >"$tmp/apply.json"
}
# PLAIN_IS STATE DROPPED: plain's apply row, each value as Python.
plain_is() { json_is "$tmp/apply.json" "d['targets'] == [{'name': 'plain', 'state': $1, 'reason': None, 'dropped': $2}]"; }
renders() { [[ "$(cat -- "$live/plain.conf")" == "accent=444444" ]]; }

# Curated files.
apply_json "a package with a symlinked curated file applies" 0 linked
check "the symlinked curated file is dropped and named" plain_is "'written'" "['plain.conf']"
check "the template renders in its place" renders
tinst "text output names the dropped symlink" "$cfg" "$rt_empty" 0 "ok theme=linked state=unchanged shell=unchanged" "" theme apply linked
check "the text row names the drop" has_line "target=plain state=unchanged dropped=plain.conf"
apply_json "a package whose targets/ is a symlink applies" 0 dirlinked
check "a file under a symlinked targets/ is dropped and named" plain_is "'unchanged'" "['plain.conf']"
check "the template stands for it" renders
apply_json "a package with a regular curated file applies" 0 regular
check "the regular curated file is taken and names no drop" plain_is "'written'" "[]"
check "the regular curated file lands byte for byte" cmp -s -- "$themes/regular/targets/plain.conf" "$live/plain.conf"

# Package files.
tinst "list names both symlinked packages refused" "$cfg" "$rt_empty" 0 "$any_out" "" theme list
check "a symlinked theme.json is refused symlink" has_line "theme=linkdoc source=installed state=refused reason=symlink current=false"
check "a symlinked terminal.json is refused symlink" has_line "theme=linkslots source=installed state=refused reason=symlink current=false"
tinst "an apply of a symlinked theme.json is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=linkdoc reason=symlink path=$themes/linkdoc" theme apply linkdoc
judge() { "$node_bin" "$1/bin/vgsh-theme-judge" accept "$2"; }
check "the install judge refuses a symlinked theme.json" test "$(judge "$tree" "$themes/linkdoc" || true)" == "reason=symlink file=theme.json"
check "the install judge refuses a symlinked terminal.json" test "$(judge "$tree" "$themes/linkslots" || true)" == "reason=symlink file=terminal.json"
check "the install judge accepts a symlinked curated file" test "$(judge "$tree" "$themes/linked")" == linked

# The applied record's digest holds no symlinked file, so a change behind
# the link is no change to the package a follow applies again.
tinst "the linked package applies for the follow rows" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply linked
printf 'owner secret, edited\n' >"$secret"
tinst "a change behind a symlinked curated file follows as current" "$cfg" "$rt_empty" 0 "ok follow=current theme=linked state=unchanged" "" theme follow
tinst "the dirlinked package applies for the follow rows" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dirlinked
printf 'elsewhere, edited\n' >"$tmp/elsewhere/plain.conf"
tinst "a change under a symlinked targets/ follows as current" "$cfg" "$rt_empty" 0 "ok follow=current theme=dirlinked state=unchanged" "" theme follow

# Must-fail controls, one per rule, each on a copy of the tree: a judge
# that follows a symlink lands the owner's file and takes the linked
# package files; one that drops a symlink unreported names no drop; one
# that reads the package files but never refuses the link accepts them;
# one whose digest follows a link reapplies on a change behind it.
judge_control follows 'if (stat.isSymbolicLink()) return { state: "linked" };' 'if (false) return { state: "linked" };'
apply_json "the follows mutant applies the linked package" 0 linked
check "the follows mutant lands the owner's file" cmp -s -- "$secret" "$live/plain.conf"
apply_json "the follows mutant applies the symlinked theme.json" 0 linkdoc
check "the install judge copy that follows accepts the symlinked theme.json" test "$(judge "$tmp/tree-follows" "$themes/linkdoc")" == linkdoc
judge_control unreported 'curated.value.linked.includes(destination) || ' ''
apply_json "the unreported mutant applies the linked package" 0 linked
check "the unreported mutant names no drop" json_is "$tmp/apply.json" "[t['dropped'] for t in d['targets']] == [[]]"
judge_control package-unrefused 'if (read.linked !== null) {' 'if (false) {'
tinst "the package-unrefused mutant lists the symlinked theme.json" "$cfg" "$rt_empty" 0 "$any_out" "" theme list
check "the package-unrefused mutant refuses it for a document it never read" has_line "theme=linkdoc source=installed state=refused reason=package-theme current=false"
judge_control install-unrefused 'if (read.linked !== null) return logic.refusal("symlink", "", "file=" + read.linked);' ''
check "the install-unrefused mutant accepts a symlinked terminal.json" test "$(judge "$tmp/tree-install-unrefused" "$themes/linkslots")" == linkslots
unset THEME_BIN
tinst "the linked package applies for the digest control" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply linked
judge_control digest-follows 'if (fs.lstatSync(file, { throwIfNoEntry: false })?.isFile() !== true) continue;' 'if (fs.statSync(file, { throwIfNoEntry: false })?.isFile() !== true) continue;'
printf 'owner secret, edited again\n' >"$secret"
tinst "the digest-follows mutant follows a change behind the link" "$cfg" "$rt_empty" 0 "ok follow=reapplied theme=linked state=unchanged" "" theme follow
unset THEME_BIN
tinst "the dirlinked package applies for the digest directory control" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dirlinked
judge_control digest-dir-follows 'names = fs.lstatSync(dir).isSymbolicLink() ? [] : fs.readdirSync(dir).sort();' 'names = fs.readdirSync(dir).sort();'
printf 'elsewhere, edited again\n' >"$tmp/elsewhere/plain.conf"
tinst "the digest-dir-follows mutant follows a change under the symlinked targets/" "$cfg" "$rt_empty" 0 "ok follow=reapplied theme=dirlinked state=unchanged" "" theme follow
unset THEME_BIN

rows_done test-vgsh-package-links
