#!/usr/bin/env bash
# Controls for a theme package's backgrounds: what `vgsh theme apply` makes
# the current background, what `vgsh theme background next` and `previous`
# move to, what `set` takes, for every screen or one output, and what
# `list` names.
# Each row pins an exit status, the last stdout line, the keyed stderr line,
# the state directory's `background` symlink and backgrounds.json. The
# image files are bytes no row decodes: the judge reads only their names.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
cfg="$tmp/cfg-bg"; mkdir -p "$cfg/vgs"; file="$cfg/vgs/theme.json"
link="$state/background"; doc="$state/backgrounds.json"

# dusk holds three images beside what the list skips: another extension, a
# hidden image, a directory with an image name, a symlink to an image, which
# no package contributes, and a dangling link. nord holds none. Both are
# installed, so a control's tree copy links the same image paths.
theme_pkg "$cfg/vgs/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$cfg/vgs/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222" } } }'
images="$cfg/vgs/themes/dusk/backgrounds"; mkdir -p "$images/d.png"
printf 'b' >"$images/b.png"; printf 'a' >"$images/a.JPG"; printf 't' >"$images/notes.txt"; printf 'h' >"$images/.hidden.png"
printf 'c' >"$images/c.png"; printf 'l' >"$tmp/bb-target"; ln -s -- "$tmp/bb-target" "$images/bb.png"; ln -s -- "$tmp/nowhere" "$images/e.png"

links_at() { [[ -L $link && "$(readlink -- "$link")" == "$1" ]]; }
links_to() { links_at "$images/$1"; }
no_link() { [[ ! -e $link && ! -L $link ]]; }
# doc_is CURRENT THEMES [SCREENS]: the state file's `current` and `themes`
# as JSON, its keys in the runner's order, and a stamp that leads with the
# current image's size, null for no image. SCREENS, output to path, is the
# `screens` map in name order, each entry `{ path, stamp }` stamped the same
# way; without it the file holds no `screens` key.
doc_is() {
  [[ -f $doc ]] && python3 -c 'import json,os,sys
d, cur, themes = json.load(open(sys.argv[1])), json.loads(sys.argv[2]), json.loads(sys.argv[3])
screens = json.loads(sys.argv[4]) if len(sys.argv) > 4 else None
stamped = lambda p, s: s.startswith("%d:" % os.stat(p).st_size)
keys = ["schemaVersion", "current", "stamp", "themes"] + ([] if screens is None else ["screens"])
ok = list(d) == keys and d["schemaVersion"] == 1 and d["current"] == cur and d["themes"] == themes and (d["stamp"] is None if cur is None else stamped(cur, d["stamp"]))
if ok and screens is not None:
    got = d["screens"]
    ok = list(got) == sorted(screens) and all(list(got[o]) == ["path", "stamp"] and got[o]["path"] == screens[o] and stamped(screens[o], got[o]["stamp"]) for o in screens)
sys.exit(0 if ok else 1)' "$doc" "$@"
}
stamp_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["stamp"])' "$doc"; }
no_doc() { [[ ! -e $doc && ! -L $doc ]]; }
at() { printf '"%s/%s"' "$images" "$1"; }
# The --json result: STATE BACKGROUND THEME PATH REASON, each value but
# STATE already JSON.
json_line() { printf '{"state":"%s","background":%s,"theme":%s,"path":%s,"reason":%s}' "$@"; }
step_line() { printf 'ok background=%s theme=dusk path=%s/%s' "$1" "$images" "$1"; }
set_line() { printf 'ok background=%s theme=%s path=%s%s' "$1" "$2" "$3" "${4:+ screen=$4}"; } # FILE THEME PATH [SCREEN]
entry() { printf '{"background":"%s","theme":%s,"path":"%s"}' "$1" "$2" "$3"; } # FILE THEME_JSON PATH

tinst "next before any apply is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=not-applied path=$state/theme.name" theme background next
tinst "an apply of a package with images is accepted" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
check "the apply links the first image in name order, a JPG in capitals included" links_to a.JPG
check "the state file names the image current and remembers nothing" doc_is "$(at a.JPG)" '{}'
tinst "next moves to the second image" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
check "next links the second image" links_to b.png
check "next remembers it for the applied package" doc_is "$(at b.png)" '{"dusk":"b.png"}'
tinst "next passes over a symlinked image to the third" "$cfg" "$rt_empty" 0 "$(step_line c.png)" "" theme background next
tinst "next after the last image wraps to the first" "$cfg" "$rt_empty" 0 "$(step_line a.JPG)" "" theme background next
tinst "next moves to the second image again" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
tinst "previous moves back to the first image" "$cfg" "$rt_empty" 0 "$(step_line a.JPG)" "" theme background previous
check "previous links the image before" links_to a.JPG
check "previous remembers it for the applied package" doc_is "$(at a.JPG)" '{"dusk":"a.JPG"}'
tinst "previous before the first image wraps to the last" "$cfg" "$rt_empty" 0 "$(step_line c.png)" "" theme background previous
check "the wrapped previous is remembered" doc_is "$(at c.png)" '{"dusk":"c.png"}'
tinst "next after the last image wraps to the first again" "$cfg" "$rt_empty" 0 "$(step_line a.JPG)" "" theme background next
tinst "next under --json prints the step's result" "$cfg" "$rt_empty" 0 "$(json_line ok '"b.png"' '"dusk"' "$(at b.png)" null)" "" theme background --json next
check "the --json step links the image it names" links_to b.png

tinst "an apply of a package with no images is accepted" "$cfg" "$rt_empty" 0 "ok theme=nord state=applied shell=applied" "" theme apply nord
check "a package with no images removes the link" no_link
check "a package with no images keeps what is remembered" doc_is null '{"dusk":"b.png"}'
tinst "next on a package with no images is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=no-backgrounds theme=nord path=$cfg/vgs/themes/nord/backgrounds" theme background next
tinst "previous under --json prints its refusal as the result" "$cfg" "$rt_empty" 1 "$(json_line failed null '"nord"' null '"no-backgrounds"')" "vgsh: refused: background=previous reason=no-backgrounds theme=nord path=$cfg/vgs/themes/nord/backgrounds" theme background --json previous
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

# A symlinked backgrounds/ holds no image, whatever it links to.
theme_pkg "$cfg/vgs/themes/fen" '{ "schemaVersion": 1, "name": "fen", "tokens": { "palette": { "accent": "#333333" } } }'
mkdir -p "$tmp/fen-images"; printf 'x' >"$tmp/fen-images/x.png"; ln -s -- "$tmp/fen-images" "$cfg/vgs/themes/fen/backgrounds"
tinst "an apply of a package whose backgrounds/ is a symlink is accepted" "$cfg" "$rt_empty" 0 "ok theme=fen state=applied shell=applied" "" theme apply fen
check "a symlinked backgrounds/ links no image" no_link
tinst "next on a symlinked backgrounds/ is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=no-backgrounds theme=fen path=$cfg/vgs/themes/fen/backgrounds" theme background next
tinst "nord applies after fen" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
rm -f -- "$doc"

# set, list and each screen's own image. The user folder holds u.png, a
# symlinked image and a text file. The tree ships sea, with one image, and
# a nord the installed nord shadows, whose n.png no list names; the
# installed bad is refused, so its z.png is no image either. elsewhere/ is
# a backgrounds/ no source owns, holding a c.png named like dusk's.
user="$cfg/vgs/backgrounds"; mkdir -p "$user"
printf 'u' >"$user/u.png"; ln -s -- "$tmp/bb-target" "$user/ul.png"; printf 't' >"$user/notes.txt"
theme_pkg "$tree/themes/sea" '{ "schemaVersion": 1, "name": "sea", "tokens": { "palette": { "accent": "#444444" } } }'
mkdir -p "$tree/themes/sea/backgrounds"; printf 's' >"$tree/themes/sea/backgrounds/s.png"
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": {} }'
mkdir -p "$tree/themes/nord/backgrounds"; printf 'n' >"$tree/themes/nord/backgrounds/n.png"
theme_pkg "$cfg/vgs/themes/bad" '{ "schemaVersion": 1, "name": "other", "tokens": {} }'
mkdir -p "$cfg/vgs/themes/bad/backgrounds"; printf 'z' >"$cfg/vgs/themes/bad/backgrounds/z.png"
elsewhere="$tmp/elsewhere/backgrounds"; mkdir -p "$elsewhere"; printf 'o' >"$elsewhere/c.png"
ln -s -- "$cfg" "$tmp/cfg-link"
uat() { printf '"%s/%s"' "$user" "$1"; }
# list_all_is WANT: the --json list in $tmp/out, less the images of the
# packages the repository ships, whose backgrounds no row owns, is WANT.
list_all_is() {
  python3 -c 'import json,os,sys
d = json.loads(open(sys.argv[1]).read().splitlines()[-1])
shipped = set(os.listdir(sys.argv[2])) - {"targets"}
got = [i for i in d["images"] if i["theme"] not in shipped]
sys.exit(0 if list(d) == ["state", "images", "reason"] and d["state"] == "ok" and d["reason"] is None and got == json.loads(sys.argv[3]) else 1)' "$tmp/out" "$repo/themes" "$1"
}
dusk_images="$(entry a.JPG '"dusk"' "$images/a.JPG"),$(entry b.png '"dusk"' "$images/b.png"),$(entry c.png '"dusk"' "$images/c.png")"
two_screens() { printf '{"DP-1":"%s","HDMI-A-1":"%s"}' "$1" "$2"; } # DP-1_PATH HDMI-A-1_PATH

tinst "list of a package with no images names none" "$cfg" "$rt_empty" 0 "" "" theme background list
tinst "list under --json prints an empty list" "$cfg" "$rt_empty" 0 '{"state":"ok","images":[],"reason":null}' "" theme background --json list
tinst "list --all under --json is accepted" "$cfg" "$rt_empty" 0 "$any_out" "" theme background --json list --all
check "list --all names each accepted package's images in name order, then the user folder's" list_all_is "[$dusk_images,$(entry s.png '"sea"' "$tree/themes/sea/backgrounds/s.png"),$(entry u.png null "$user/u.png")]"
tinst "list --all ends with the user folder's image, named by no package" "$cfg" "$rt_empty" 0 "background=u.png theme=- path=$user/u.png" "" theme background list --all
tinst "set of a user-folder image is accepted" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png")" "" theme background set "$user/u.png"
check "set links the user-folder image" links_at "$user/u.png"
check "a user-folder image is remembered for no package" doc_is "$(uat u.png)" '{}'
tinst "set of a package image while another package is applied is accepted" "$cfg" "$rt_empty" 0 "$(set_line c.png dusk "$images/c.png")" "" theme background set "$images/c.png"
check "an image of a package not applied is remembered for none" doc_is "$(at c.png)" '{}'
tinst "set through a symlink above the user folder is accepted" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png")" "" theme background set "$tmp/cfg-link/vgs/backgrounds/u.png"
check "set through a symlink above names the image by the folder's own path" links_at "$user/u.png"
tinst "set of a symlinked user-folder image is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=symlink path=$user/ul.png" theme background set "$user/ul.png"
tinst "set of a symlinked package image is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=symlink path=$images/bb.png" theme background set "$images/bb.png"
tinst "set in a symlinked backgrounds/ is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=symlink path=$cfg/vgs/themes/fen/backgrounds" theme background set "$cfg/vgs/themes/fen/backgrounds/x.png"
tinst "set in a backgrounds/ no source owns is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=outside path=$elsewhere/c.png" theme background set "$elsewhere/c.png"
tinst "set of a package file outside backgrounds/ is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=outside path=$cfg/vgs/themes/dusk/theme.json" theme background set "$cfg/vgs/themes/dusk/theme.json"
tinst "set of a refused package's image is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=outside path=$cfg/vgs/themes/bad/backgrounds/z.png" theme background set "$cfg/vgs/themes/bad/backgrounds/z.png"
tinst "set of a shadowed package's image is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=outside path=$tree/themes/nord/backgrounds/n.png" theme background set "$tree/themes/nord/backgrounds/n.png"
tinst "set of a text file is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=not-an-image path=$user/notes.txt" theme background set "$user/notes.txt"
tinst "set of an absent image is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=absent path=$user/none.png" theme background set "$user/none.png"
tinst "set of a directory with an image name is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=not-a-file path=$images/d.png" theme background set "$images/d.png"
tinst "set with a malformed output name is refused" "$cfg" "$rt_empty" 1 "" 'vgsh: refused: background=set reason=malformed-screen screen="../x"' theme background set "$user/u.png" --screen ../x
tinst "set under --json prints its refusal as the result" "$cfg" "$rt_empty" 1 '{"state":"failed","background":null,"theme":null,"path":null,"screen":null,"reason":"malformed-screen"}' 'vgsh: refused: background=set reason=malformed-screen screen="../x"' theme background --json set "$user/u.png" --screen ../x
check "refused sets leave the link" links_at "$user/u.png"

tinst "dusk applies for the set rows" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
tinst "set of the applied package's image is accepted" "$cfg" "$rt_empty" 0 "$(set_line c.png dusk "$images/c.png")" "" theme background set "$images/c.png"
check "set of the applied package's image remembers it" doc_is "$(at c.png)" '{"dusk":"c.png"}'
tinst "next after set moves on from the set image" "$cfg" "$rt_empty" 0 "$(step_line a.JPG)" "" theme background next
tinst "set --screen is accepted" "$cfg" "$rt_empty" 0 "$(set_line b.png dusk "$images/b.png" DP-1)" "" theme background set "$images/b.png" --screen DP-1
check "set --screen leaves the link on the current image" links_to a.JPG
check "set --screen writes that screen's image alone" doc_is "$(at a.JPG)" '{"dusk":"a.JPG"}' "{\"DP-1\":\"$images/b.png\"}"
tinst "set --screen of a user-folder image is accepted" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png" HDMI-A-1)" "" theme background set "$user/u.png" --screen HDMI-A-1
tinst "next beside screen images is accepted" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
check "next leaves each screen's image" doc_is "$(at b.png)" '{"dusk":"b.png"}' "$(two_screens "$images/b.png" "$user/u.png")"
tinst "previous beside screen images is accepted" "$cfg" "$rt_empty" 0 "$(step_line a.JPG)" "" theme background previous
check "previous leaves each screen's image" doc_is "$(at a.JPG)" '{"dusk":"a.JPG"}' "$(two_screens "$images/b.png" "$user/u.png")"
tinst "set without --screen beside screen images is accepted" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png")" "" theme background set "$user/u.png"
check "set without --screen leaves each screen's image" doc_is "$(uat u.png)" '{"dusk":"a.JPG"}' "$(two_screens "$images/b.png" "$user/u.png")"
tinst "set --screen under --json prints its result" "$cfg" "$rt_empty" 0 "{\"state\":\"ok\",\"background\":\"c.png\",\"theme\":\"dusk\",\"path\":\"$images/c.png\",\"screen\":\"DP-1\",\"reason\":null}" "" theme background --json set "$images/c.png" --screen DP-1
check "a second set --screen replaces that screen's image" doc_is "$(uat u.png)" '{"dusk":"a.JPG"}' "$(two_screens "$images/c.png" "$user/u.png")"
tinst "list names the applied package's images" "$cfg" "$rt_empty" 0 "background=c.png theme=dusk path=$images/c.png" "" theme background list
tinst "list under --json prints the applied package's images" "$cfg" "$rt_empty" 0 "{\"state\":\"ok\",\"images\":[$dusk_images],\"reason\":null}" "" theme background --json list
tinst "an apply beside screen images is accepted" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "the apply shows the remembered image and clears every screen's" doc_is "$(at a.JPG)" '{"dusk":"a.JPG"}'
rm -- "$doc"
tinst "nord applies for the screen-only rows" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
tinst "set --screen with no current image is accepted" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png" DP-1)" "" theme background set "$user/u.png" --screen DP-1
check "a screen image alone keeps the state file" doc_is null '{}' "{\"DP-1\":\"$user/u.png\"}"
check "a screen image alone links nothing" no_link
tinst "nord applies over a screen image alone" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "an apply that clears the last screen image writes no state file" no_doc
mv -- "$state/theme.name" "$state/theme.name.ok"
tinst "list before any apply is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=list reason=not-applied path=$state/theme.name" theme background list
tinst "list under --json prints its refusal as the result" "$cfg" "$rt_empty" 1 '{"state":"failed","images":null,"reason":"not-applied"}' "vgsh: refused: background=list reason=not-applied path=$state/theme.name" theme background --json list
tinst "set before any apply is accepted" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png")" "" theme background set "$user/u.png"
check "set before any apply remembers nothing" doc_is "$(uat u.png)" '{}'
mv -- "$state/theme.name.ok" "$state/theme.name"
tinst "nord applies after the set rows" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "nord after the set rows leaves no state file" no_doc
# A fresh home: set is the first command, so no state directory exists yet.
mv -- "$state" "$tmp/state-kept"
tinst "set with no state directory is accepted" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png")" "" theme background set "$user/u.png"
check "set with no state directory links the image" links_at "$user/u.png"
check "set with no state directory writes the state file" doc_is "$(uat u.png)" '{}'
rm -r -- "${state:?}"; mv -- "$tmp/state-kept" "$state"

# A state file or a backgrounds/ the judge cannot use refuses the apply
# before anything moves, so the theme file keeps nord.
nord_bytes="$tmp/nord.json"; cp -- "$file" "$nord_bytes"
printf '{ "schemaVersion": 1, "current": null, "stamp": null, "themes": { "dusk": "../x.png" } }\n' >"$doc"
tinst "an apply over a malformed state file is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: theme=dusk reason=malformed path=$doc" theme apply dusk
tinst "next over a malformed state file is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=malformed path=$doc" theme background next
# Each screens map no runner writes refuses the step, as a state file with
# a fifth key other than screens does.
while IFS='|' read -r label screens; do
  printf '{ "schemaVersion": 1, "current": null, "stamp": null, "themes": {}, "screens": %s }\n' "$screens" >"$doc"
  tinst "next over $label is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=malformed path=$doc" theme background next
done <<'ROWS'
a screens map that is a list|[]
an output name no output has|{ "../x": { "path": "/a.png", "stamp": "1:2" } }
a screen entry that is no object|{ "DP-1": "/a.png" }
a screen entry without its stamp|{ "DP-1": { "path": "/a.png" } }
a screen entry with a relative path|{ "DP-1": { "path": "a.png", "stamp": "1:2" } }
a screen entry with a key the runner does not write|{ "DP-1": { "path": "/a.png", "stamp": "1:2", "fit": "crop" } }
ROWS
printf '{ "schemaVersion": 1, "current": null, "stamp": null, "themes": {}, "fit": {} }\n' >"$doc"
tinst "next over a fifth key that is not screens is refused" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=next reason=malformed path=$doc" theme background next
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
tinst "set without a path is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: path=missing" theme background set
tinst "set --screen without an output is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: screen=missing" theme background set "$user/u.png" --screen
tinst "set with a second path is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=x.png" theme background set "$user/u.png" x.png
tinst "list with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=dusk" theme background list dusk
tinst "list --all with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=dusk" theme background list --all dusk
tinst "previous with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=dusk" theme background previous dusk
tinst "--json without a verb is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: background-subcommand=missing" theme background --json
tinst "dusk applies for the lock rows" "$cfg" "$rt_empty" 0 "ok theme=dusk state=applied shell=applied" "" theme apply dusk
exec 7>>"$cfg/vgs/theme.lock"
flock 7
tinst "next while the theme lock is held is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: background=next reason=busy" theme background next
check "a busy next leaves the link" links_to a.JPG
tinst "previous under --json while the lock is held prints the busy result" "$cfg" "$rt_empty" 75 "$(json_line failed null null null '"busy"')" "vgsh: refused: background=previous reason=busy" theme background --json previous
tinst "set while the theme lock is held is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: background=set reason=busy" theme background set "$images/c.png"
check "a busy set leaves the link" links_to a.JPG
judge_control busy 'if (lock === "busy") refuse(key + "=busy", "busy", 75);' ''
tinst "the busy mutant moves on under the held lock" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
tinst "the busy mutant sets under the held lock" "$cfg" "$rt_empty" 0 "$(set_line c.png dusk "$images/c.png")" "" theme background set "$images/c.png"
unset THEME_BIN
exec 7>&-

# Must-fail controls, one per rule, each on a copy of the tree.
reset_dusk() { unset THEME_BIN; rm -f -- "$doc"; tinst "$1: dusk applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk; }
bg_control() { tree_control "$1" bin/lib/theme-backgrounds.js "$2" "$3"; } # NAME NEEDLE REPLACEMENT
reset_dusk "remembered control"
tinst "the remembered control remembers b.png" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
bg_control remembered 'if (list.includes(remembered)) return remembered;' ''
tinst "the remembered mutant applies dusk again" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the remembered mutant shows the first image, not the remembered one" links_to a.JPG
reset_dusk "images control"
bg_control images 'EXTENSIONS.includes(path.extname(name).toLowerCase());' 'true;'
tinst "the images mutant applies dusk" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
tinst "the images mutant moves to b.png" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
tinst "the images mutant moves to c.png" "$cfg" "$rt_empty" 0 "$(step_line c.png)" "" theme background next
tinst "the images mutant's next reaches the text file" "$cfg" "$rt_empty" 0 "$(step_line notes.txt)" "" theme background next
tinst "the images mutant sets the user folder's text file" "$cfg" "$rt_empty" 0 "$(set_line notes.txt - "$user/notes.txt")" "" theme background set "$user/notes.txt"
reset_dusk "linked image control"
bg_control linked-image 'if (stat.isSymbolicLink()) return "symlink";' 'if (stat.isSymbolicLink()) return "image";'
tinst "the linked-image mutant moves to b.png" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
tinst "the linked-image mutant reaches the symlinked bb.png" "$cfg" "$rt_empty" 0 "$(step_line bb.png)" "" theme background next
tinst "the linked-image mutant sets the symlinked ul.png" "$cfg" "$rt_empty" 0 "$(set_line ul.png - "$user/ul.png")" "" theme background set "$user/ul.png"
reset_dusk "linked directory control"
bg_control linked-dir 'return stat !== null && stat.isSymbolicLink();' 'return false;'
tinst "the linked-dir mutant applies fen" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply fen
check "the linked-dir mutant links the image behind the symlinked backgrounds/" test "$(readlink -- "$link")" == "$cfg/vgs/themes/fen/backgrounds/x.png"
tinst "the linked-dir mutant sets the image behind the symlinked backgrounds/" "$cfg" "$rt_empty" 0 "$(set_line x.png fen "$cfg/vgs/themes/fen/backgrounds/x.png")" "" theme background set "$cfg/vgs/themes/fen/backgrounds/x.png"
reset_dusk "unlink control"
bg_control unlink '            fs.rmSync(link, { force: true });' ''
tinst "the unlink mutant applies nord" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the unlink mutant keeps dusk's link under a package with no images" links_to a.JPG
reset_dusk "wrap control"
tinst "the wrap control moves to b.png" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
tinst "the wrap control reaches the last image" "$cfg" "$rt_empty" 0 "$(step_line c.png)" "" theme background next
judge_control wrap '(at + BACKGROUND_STEPS[step] + list.length) % list.length' 'Math.min(at + BACKGROUND_STEPS[step], list.length - 1)'
tinst "the wrap mutant stays on the last image" "$cfg" "$rt_empty" 0 "$(step_line c.png)" "" theme background next
reset_dusk "backward wrap control"
judge_control backward-wrap '(at + BACKGROUND_STEPS[step] + list.length) % list.length' 'Math.max(at + BACKGROUND_STEPS[step], 0)'
tinst "the backward wrap mutant stays on the first image" "$cfg" "$rt_empty" 0 "$(step_line a.JPG)" "" theme background previous
reset_dusk "direction control"
judge_control direction 'previous: -1' 'previous: 1'
tinst "the direction mutant's previous moves forward" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background previous
reset_dusk "stamp control"
bg_control stamp 'return { path: at, stamp: stat.size + ":" + stat.mtimeMs };' 'return { path: at, stamp: "fixed" };'
tinst "the stamp mutant applies dusk" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
before_inode="$(stat -c %i -- "$doc")"
printf 'a3' >"$images/a.JPG.new" && mv -T -- "$images/a.JPG.new" "$images/a.JPG"
tinst "the stamp mutant applies over a replaced image" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the stamp mutant leaves the state file in place for a replaced image" test "$(stat -c %i -- "$doc")" == "$before_inode"
reset_dusk "refusal control"
printf '{ "schemaVersion": 1, "current": null, "stamp": null, "themes": { "dusk": "../x.png" } }\n' >"$doc"
bg_control refusal 'if (!shaped) refuse(key + "=malformed path=" + file, "malformed");' ''
tinst "the refusal mutant applies over a malformed state file" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
reset_dusk "screens control"
printf '{ "schemaVersion": 1, "current": null, "stamp": null, "themes": {}, "screens": { "../x": { "path": "/a.png", "stamp": "1:2" } } }\n' >"$doc"
bg_control screens 'Object.entries(doc.screens).every(isScreen)' 'true'
tinst "the screens mutant applies over an output name no output has" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
reset_dusk "output control"
bg_control output 'OUTPUT_NAME.test(name)' 'true'
tinst "the output mutant sets an image for a malformed output name" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png" ../x)" "" theme background set "$user/u.png" --screen ../x
reset_dusk "screens key control"
bg_control screens-key 'if (Object.keys(state.screens).length > 0) doc.screens' 'if (true) doc.screens'
tinst "the screens-key mutant moves to b.png" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
check "the screens-key mutant writes an empty screens map" json_is "$doc" "d.get('screens') == {}"
reset_dusk "empty control"
tinst "the empty control applies nord" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
bg_control empty ' && Object.keys(after.screens).length === 0' ''
tinst "the empty mutant sets a screen image with no current image" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png" DP-1)" "" theme background set "$user/u.png" --screen DP-1
check "the empty mutant removes the state file that holds the screen image" no_doc
reset_dusk "outside control"
bg_control outside 'sources.find(s => realOrNull(s.dir, key) === parent)' 'sources.find(s => realOrNull(s.dir, key) !== null)'
tinst "the outside mutant takes elsewhere's c.png for dusk's" "$cfg" "$rt_empty" 0 "$(set_line c.png dusk "$images/c.png")" "" theme background set "$elsewhere/c.png"
reset_dusk "real path control"
bg_control real-path 'realOrNull(s.dir, key) === parent' 's.dir === path.dirname(base)'
tinst "the real-path mutant refuses a path through a symlink above the user folder" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=outside path=$tmp/cfg-link/vgs/backgrounds/u.png" theme background set "$tmp/cfg-link/vgs/backgrounds/u.png"
reset_dusk "set remember control"
judge_control set-remember 'const remembered = source.theme !== null && source.theme === applied;' 'const remembered = false;'
tinst "the set-remember mutant sets c.png" "$cfg" "$rt_empty" 0 "$(set_line c.png dusk "$images/c.png")" "" theme background set "$images/c.png"
tinst "the set-remember mutant's next moves on from the first image" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
reset_dusk "user remember control"
judge_control user-remember 'source.theme !== null && source.theme === applied' 'source.theme === applied'
mv -- "$state/theme.name" "$state/theme.name.ok"
tinst "the user-remember mutant sets u.png before any apply" "$cfg" "$rt_empty" 0 "$(set_line u.png - "$user/u.png")" "" theme background set "$user/u.png"
check "the user-remember mutant remembers the user image under a package named null" doc_is "$(uat u.png)" '{"null":"u.png"}'
mv -- "$state/theme.name.ok" "$state/theme.name"
reset_dusk "screen-only control"
judge_control screen-only 'const after = screen === null' 'const after = true'
tinst "the screen-only mutant sets b.png for DP-1" "$cfg" "$rt_empty" 0 "$(set_line b.png dusk "$images/b.png" DP-1)" "" theme background set "$images/b.png" --screen DP-1
check "the screen-only mutant moves the link to the screen's image" links_to b.png
reset_dusk "clear control"
tinst "the clear control sets b.png for DP-1" "$cfg" "$rt_empty" 0 "$(set_line b.png dusk "$images/b.png" DP-1)" "" theme background set "$images/b.png" --screen DP-1
judge_control clear '{ current: background, themes: shown.themes, screens: {} }' '{ current: background, themes: shown.themes, screens: shown.screens }'
tinst "the clear mutant applies dusk" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the clear mutant keeps the screen image through an apply" doc_is "$(at a.JPG)" '{}' "{\"DP-1\":\"$images/b.png\"}"
reset_dusk "keep control"
tinst "the keep control sets b.png for DP-1" "$cfg" "$rt_empty" 0 "$(set_line b.png dusk "$images/b.png" DP-1)" "" theme background set "$images/b.png" --screen DP-1
judge_control keep '{ [name]: chosen }), screens: shown.screens }' '{ [name]: chosen }), screens: {} }'
tinst "the keep mutant moves to b.png" "$cfg" "$rt_empty" 0 "$(step_line b.png)" "" theme background next
check "the keep mutant drops the screen image on a step" doc_is "$(at b.png)" '{"dusk":"b.png"}'
reset_dusk "scope control"
judge_control scope 'if (scope === "all") {' 'if (true) {'
tinst "the scope mutant's list ends with the user folder's image" "$cfg" "$rt_empty" 0 "background=u.png theme=- path=$user/u.png" "" theme background list
reset_dusk "user folder control"
judge_control user-folder '.concat([{ theme: null, dir: configDir }])' '.concat([])'
tinst "the user-folder mutant refuses a user-folder image as outside" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=outside path=$user/u.png" theme background set "$user/u.png"
reset_dusk "state directory control"
bg_control state-dir '    writing(stateDir, key, () => fs.mkdirSync(stateDir, { recursive: true }));' ''
mv -- "$state" "$tmp/state-kept"
tinst "the state-dir mutant cannot set with no state directory" "$cfg" "$rt_empty" 1 "" "vgsh: refused: background=set reason=unwritable path=$state/background error=ENOENT" theme background set "$user/u.png"
rm -rf -- "${state:?}"; mv -- "$tmp/state-kept" "$state"
reset_dusk "accepted control"
judge_control accepted '.filter(row => row.state === "ok")' ''
tinst "the accepted mutant sets a refused package's image" "$cfg" "$rt_empty" 0 "$(set_line z.png bad "$cfg/vgs/themes/bad/backgrounds/z.png")" "" theme background set "$cfg/vgs/themes/bad/backgrounds/z.png"
unset THEME_BIN

rows_done test-vgsh-backgrounds
