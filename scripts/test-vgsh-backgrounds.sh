#!/usr/bin/env bash
# Controls for a theme package's backgrounds: what `vgsh theme apply` makes
# the current background and what `vgsh theme background next` moves to.
# Each row pins an exit status, the last stdout line, the keyed stderr line,
# the state directory's `background` symlink and backgrounds.json. The
# image files are bytes no row decodes: the judge reads only their names.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
cfg="$tmp/cfg-bg"; mkdir -p "$cfg/vgs"; file="$cfg/vgs/theme.json"
link="$state/background"; doc="$state/backgrounds.json"

# dusk holds three images, a symlink to a file among them, beside what the
# list skips: another extension, a hidden image, a directory with an image
# name and a dangling link. nord holds none. Both are installed, so a
# control's tree copy links the same image paths.
theme_pkg "$cfg/vgs/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$cfg/vgs/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222" } } }'
images="$cfg/vgs/themes/dusk/backgrounds"; mkdir -p "$images/d.png"
printf 'b' >"$images/b.png"; printf 'a' >"$images/a.JPG"; printf 't' >"$images/notes.txt"; printf 'h' >"$images/.hidden.png"
printf 'c' >"$tmp/c-target"; ln -s -- "$tmp/c-target" "$images/c.png"; ln -s -- "$tmp/nowhere" "$images/e.png"

links_to() { [[ -L $link && "$(readlink -- "$link")" == "$images/$1" ]]; }
no_link() { [[ ! -e $link && ! -L $link ]]; }
# doc_is CURRENT THEMES: the state file's `current` and `themes` as JSON,
# its keys in the runner's order, and a stamp that leads with the current
# image's size, null for no image.
doc_is() {
  [[ -f $doc ]] && python3 -c 'import json,os,sys
d, cur, themes = json.load(open(sys.argv[1])), json.loads(sys.argv[2]), json.loads(sys.argv[3])
stamp = None if cur is None else "%d:" % os.stat(cur).st_size
sys.exit(0 if list(d) == ["schemaVersion", "current", "stamp", "themes"] and d["schemaVersion"] == 1 and d["current"] == cur and d["themes"] == themes and (d["stamp"] is None if stamp is None else d["stamp"].startswith(stamp)) else 1)' "$doc" "$1" "$2"
}
stamp_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stamp"])' "$doc"; }
no_doc() { [[ ! -e $doc && ! -L $doc ]]; }
at() { printf '"%s/%s"' "$images" "$1"; }
next_line() { printf 'ok background=%s theme=dusk path=%s/%s' "$1" "$images" "$1"; }

tinst "next before any apply is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=not-applied path=$state/theme.name" theme background next
tinst "an apply of a package with images is accepted" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
check "the apply links the first image in name order, a JPG in capitals included" links_to a.JPG
check "the state file names the image current and remembers nothing" doc_is "$(at a.JPG)" '{}'
tinst "next moves to the second image" "$cfg" "$rt_empty" 0 "$(next_line b.png)" "" theme background next
check "next links the second image" links_to b.png
check "next remembers it for the applied package" doc_is "$(at b.png)" '{"dusk":"b.png"}'
tinst "next reaches an image that is a symlink" "$cfg" "$rt_empty" 0 "$(next_line c.png)" "" theme background next
tinst "next after the last image wraps to the first" "$cfg" "$rt_empty" 0 "$(next_line a.JPG)" "" theme background next
tinst "next moves to the second image again" "$cfg" "$rt_empty" 0 "$(next_line b.png)" "" theme background next

tinst "an apply of a package with no images is accepted" "$cfg" "$rt_empty" 0 "ok theme=nord state=applied shell=applied" "" theme apply nord
check "a package with no images removes the link" no_link
check "a package with no images keeps what is remembered" doc_is null '{"dusk":"b.png"}'
tinst "next on a package with no images is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=no-backgrounds theme=nord path=$cfg/vgs/themes/nord/backgrounds" theme background next
tinst "an apply of the package again is accepted" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
check "the apply links the image next remembered" links_to b.png
mv -- "$images/b.png" "$tmp/b.png"
tinst "an apply whose remembered image is gone is accepted" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "a remembered image that is gone falls back to the first" links_to a.JPG
mv -- "$tmp/b.png" "$images/b.png"
# An image replaced under its name gives the state file a new stamp, so the
# plugin decodes it again.
tinst "an apply whose remembered image is back is accepted" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "the remembered image is shown again once it is back" links_to b.png
before_stamp="$(stamp_of)"; before_inode="$(stat -c %i -- "$doc")"
printf 'b2' >"$images/b.png.new" && mv -T -- "$images/b.png.new" "$images/b.png"
tinst "an apply over a replaced image is accepted" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "a replaced image replaces the state file with a new stamp" test "$(stamp_of)" != "$before_stamp" -a "$(stat -c %i -- "$doc")" != "$before_inode"
check "the rewritten state file names the replaced image" doc_is "$(at b.png)" '{"dusk":"b.png"}'
# An empty state is no file: nothing current and nothing remembered.
rm -- "$doc"
tinst "nord applies over no state file" "$cfg" "$rt_empty" 0 "ok theme=nord state=applied shell=applied" "" theme apply nord
check "no current image and nothing remembered writes no state file" no_doc

# A state file or a backgrounds/ the judge cannot use refuses the apply
# before anything moves, so the theme file keeps nord.
nord_bytes="$tmp/nord.json"; cp -- "$file" "$nord_bytes"
printf '{ "schemaVersion": 1, "current": null, "stamp": null, "themes": { "dusk": "../x.png" } }\n' >"$doc"
tinst "an apply over a malformed state file is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=dusk reason=malformed path=$doc" theme apply dusk
tinst "next over a malformed state file is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=malformed path=$doc" theme background next
printf '{ nope\n' >"$doc"
tinst "an apply over an unparseable state file is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=dusk reason=unparseable path=$doc" theme apply dusk
check "refused applies leave the theme file alone" cmp -s "$nord_bytes" "$file"
rm -- "$doc"
chmod 000 "$images"
tinst "an apply whose backgrounds cannot be read is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=dusk reason=unreadable path=$images error=EACCES" theme apply dusk
chmod 755 "$images"
check "an unreadable backgrounds directory leaves the theme file alone" cmp -s "$nord_bytes" "$file"
check "a refused apply leaves no link" no_link
printf 'nord\n' >"$state/theme.name.ok"; printf '../x\n' >"$state/theme.name"
tinst "next refuses a theme.name no package could have" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=malformed path=$state/theme.name" theme background next
mv -- "$state/theme.name.ok" "$state/theme.name"

# Invocation and the lock.
tinst "background without a verb is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: background-subcommand=missing" theme background
tinst "background with an unknown verb is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: background-subcommand=prev" theme background prev
tinst "next with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=dusk" theme background next dusk
tinst "next takes no --json" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=--json" theme background --json next
tinst "dusk applies for the lock rows" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
exec 7>>"$cfg/vgs/theme.lock"
flock 7
tinst "next while the theme lock is held is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: background=next reason=busy" theme background next
check "a busy next leaves the link" links_to a.JPG
judge_control busy 'if (lock === "busy") refuse("background=next reason=busy", "busy", 75);' ''
tinst "the busy mutant moves on under the held lock" "$cfg" "$rt_empty" 0 "$(next_line b.png)" "" theme background next
unset THEME_BIN
exec 7>&-

# Must-fail controls, one per rule, each on a copy of the tree.
reset_dusk() { unset THEME_BIN; rm -f -- "$doc"; tinst "$1: dusk applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk; }
bg_control() { tree_control "$1" bin/lib/theme-backgrounds.js "$2" "$3"; } # NAME NEEDLE REPLACEMENT
reset_dusk "remembered control"
tinst "the remembered control remembers b.png" "$cfg" "$rt_empty" 0 "$(next_line b.png)" "" theme background next
bg_control remembered 'if (list.includes(remembered)) return remembered;' ''
tinst "the remembered mutant applies dusk again" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the remembered mutant shows the first image, not the remembered one" links_to a.JPG
reset_dusk "images control"
bg_control images 'EXTENSIONS.includes(path.extname(name).toLowerCase());' 'true;'
tinst "the images mutant applies dusk" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
tinst "the images mutant moves to b.png" "$cfg" "$rt_empty" 0 "$(next_line b.png)" "" theme background next
tinst "the images mutant moves to c.png" "$cfg" "$rt_empty" 0 "$(next_line c.png)" "" theme background next
tinst "the images mutant's next reaches the text file" "$cfg" "$rt_empty" 0 "$(next_line notes.txt)" "" theme background next
reset_dusk "unlink control"
bg_control unlink '            fs.rmSync(link, { force: true });' ''
tinst "the unlink mutant applies nord" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the unlink mutant keeps dusk's link under a package with no images" links_to a.JPG
reset_dusk "wrap control"
tinst "the wrap control moves to b.png" "$cfg" "$rt_empty" 0 "$(next_line b.png)" "" theme background next
tinst "the wrap control reaches the last image" "$cfg" "$rt_empty" 0 "$(next_line c.png)" "" theme background next
judge_control wrap '(list.indexOf(backgrounds.choose(list, shown.themes[name])) + 1) % list.length' 'Math.min(list.indexOf(backgrounds.choose(list, shown.themes[name])) + 1, list.length - 1)'
tinst "the wrap mutant stays on the last image" "$cfg" "$rt_empty" 0 "$(next_line c.png)" "" theme background next
reset_dusk "stamp control"
bg_control stamp '            stamp = stat.size + ":" + stat.mtimeMs;' '            stamp = "fixed";'
tinst "the stamp mutant applies dusk" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
before_inode="$(stat -c %i -- "$doc")"
printf 'a3' >"$images/a.JPG.new" && mv -T -- "$images/a.JPG.new" "$images/a.JPG"
tinst "the stamp mutant applies over a replaced image" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the stamp mutant leaves the state file in place for a replaced image" test "$(stat -c %i -- "$doc")" == "$before_inode"
reset_dusk "refusal control"
printf '{ "schemaVersion": 1, "current": null, "stamp": null, "themes": { "dusk": "../x.png" } }\n' >"$doc"
bg_control refusal 'if (!shaped) refuse(key + "=malformed path=" + file, "malformed");' ''
tinst "the refusal mutant applies over a malformed state file" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
unset THEME_BIN

rows_done test-vgsh-backgrounds
