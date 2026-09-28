#!/usr/bin/env bash
# The toolkit targets under themes/targets/, color-scheme, gtk3, gtk4,
# icons, kcolorscheme, qt5ct and qt6ct, through `vgsh theme apply`: each renders
# its colours with its encoder, is skipped when its command is not on PATH,
# keeps its include line or its link where its toolkit reads it, takes a
# package's curated file byte for byte, the qt targets run their reload hook,
# and icons and color-scheme assert the package's icon theme and colour mode
# on every apply. Every detect
# command and gsettings are stubs on the rows' PATH, and the hooks' `sh`,
# `cat` and `touch` act only under the temporary HOME and XDG_CONFIG_HOME, so
# no row reaches a toolkit, dconf or the developer's session. The controls at the end apply
# a tree copy whose target.json lacks one rule and require the row's
# assertion to turn.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree color-scheme gtk3 gtk4 icons kcolorscheme qt5ct qt6ct
live="$state/theme"; home="$tmp/home"

# Detection never runs a command: each detect stub records a run and exits 1.
detected=(gtk-launch gtk4-launch kreadconfig6 qt5ct qt6ct)
for stub in "${detected[@]}"; do
  printf '#!/bin/sh\n: >"%s/ran-$(basename "$0")"\nexit 1\n' "$tmp" >"$stubs/$stub"
  chmod +x "$stubs/$stub"
done
for tool in sh cat touch; do
  tool_bin="$(command -v "$tool")" || { echo "test-vgsh-toolkits: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$stubs/$tool"
done
# gsettings answers `get SCHEMA KEY` with $gs/KEY and appends each `set`'s
# arguments, one line per call, to $gs/sets-KEY. Detection never runs it.
gs="$tmp/gsettings"; mkdir -p "$gs"
gs_current="$gs/icon-theme"; gs_sets="$gs/sets-icon-theme"
cs_current="$gs/color-scheme"; cs_sets="$gs/sets-color-scheme"
printf "'Adwaita'\n" >"$gs_current"; printf "'default'\n" >"$cs_current"
cat >"$stubs/gsettings" <<EOF
#!/bin/sh
case "\$1" in
  get) cat -- "$gs/\$3" ;;
  set) printf '%s\n' "\$*" >>"$gs/sets-\$3" ;;
  *) : >"$tmp/ran-gsettings"; exit 1 ;;
esac
EOF
chmod +x "$stubs/gsettings"
with_stubs="$stubs:$theme_path"

# `dusk` sets only the accent, so every other colour is the shipped default:
# background #000000, text #d7d7d9. `curated` ships every toolkit file.
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$tree/themes/curated" '{ "schemaVersion": 1, "name": "curated", "tokens": {} }'
mkdir -p "$tree/themes/curated/targets"
printf '@define-color accent_color #123456;\n' >"$tree/themes/curated/targets/gtk3.css"
printf ':root { --accent-bg-color: #123456; }\n' >"$tree/themes/curated/targets/gtk4.css"
printf '[ColorScheme]\nactive_colors=#123456\n' >"$tree/themes/curated/targets/qt6ct.conf"
printf '[General]\nName=Curated\n' >"$tree/themes/curated/targets/kcolorscheme.colors"

cfg="$tmp/cfg-toolkits"; mkdir -p "$cfg/vgs"
states() { # the apply's `name=state` per target, from $tmp/out's JSON line
  python3 -c 'import json,sys; print(" ".join(t["name"] + "=" + t["state"] for t in json.loads(sys.argv[1])["targets"]))' "$(tail -n 1 "$tmp/out")"
}
file_is() { cmp -s -- "$1" <(printf '%s' "$2"); } # FILE TEXT
links_to() { test -L "$1" && test "$(readlink -- "$1")" == "$2"; } # LINK TARGET
# Every `@define-color` and CSS variable of a GTK file is `rgba(...)`.
gtk_colours_are_rgba() {
  python3 - "$1" <<'PY'
import re, sys
lines = [l for l in open(sys.argv[1]) if l.startswith("@define-color") or l.strip().startswith("--")]
value = re.compile(r"^(@define-color [a-z_]+ |\s*--[a-z-]+: )rgba\(\d{1,3}, \d{1,3}, \d{1,3}, [01](\.\d{1,3})?\);$")
sys.exit(0 if lines and all(value.match(l.rstrip("\n")) for l in lines) else 1)
PY
}
# The qt scheme's three role lists each hold 21 `#rrggbb` colours, and the
# active Highlight, role 12, is COLOUR.
qt_scheme_is() { # FILE COLOUR
  python3 - "$1" "$2" <<'PY'
import re, sys
rows = dict(l.rstrip("\n").split("=", 1) for l in open(sys.argv[1]) if "=" in l)
lists = [rows.get(k, "").split(", ") for k in ("active_colors", "inactive_colors", "disabled_colors")]
ok = all(len(l) == 21 and all(re.fullmatch(r"#[0-9a-f]{6}", c) for c in l) for l in lists)
sys.exit(0 if ok and lists[0][12] == sys.argv[2] else 1)
PY
}
# Every colour of the KDE scheme is `#rrggbb`, and the selection's
# background is COLOUR.
kde_scheme_is() { # FILE COLOUR
  python3 - "$1" "$2" <<'PY'
import re, sys
group, colours, selection = None, [], None
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.startswith("["):
        group = line
    elif "=#" in line:
        key, value = line.split("=", 1)
        colours.append(value)
        if group == "[Colors:Selection]" and key == "BackgroundNormal":
            selection = value
sys.exit(0 if len(colours) > 90 and all(re.fullmatch(r"#[0-9a-f]{6}", c) for c in colours) and selection == sys.argv[2] else 1)
PY
}
mtime() { stat -c %Y -- "$1"; }

tinst "an apply with no toolkit on PATH" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json dusk
check "an apply with no toolkit on PATH skips every toolkit" test "$(states)" == "color-scheme=skipped gtk3=skipped gtk4=skipped icons=skipped kcolorscheme=skipped qt5ct=skipped qt6ct=skipped"
check "an undetected toolkit gets no file" test ! -e "$cfg/gtk-3.0" -a ! -e "$cfg/gtk-4.0" -a ! -e "$cfg/qt5ct" -a ! -e "$cfg/qt6ct" -a ! -e "$home/.local/share"

# gtk-3.0/gtk.css holds the user's own rules; gtk-4.0/gtk.css is absent.
# qt6ct.conf stands with an old mtime, qt5ct.conf does not stand at all.
mkdir -p "$cfg/gtk-3.0" "$cfg/qt6ct"
printf 'window { padding: 0; }\n' >"$cfg/gtk-3.0/gtk.css"
printf '[Appearance]\nstyle=Fusion\n' >"$cfg/qt6ct/qt6ct.conf"
touch -d @0 -- "$cfg/qt6ct/qt6ct.conf"
THEME_PATH="$with_stubs" tinst "every toolkit on PATH applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json dusk
check "every detected toolkit is written" test "$(states)" == "color-scheme=written gtk3=written gtk4=written icons=written kcolorscheme=written qt5ct=written qt6ct=written"
check "the gtk3 import goes first and the user's rules stay" file_is "$cfg/gtk-3.0/gtk.css" "@import url(\"file://$live/gtk3.css\");"$'\nwindow { padding: 0; }\n'
check "an absent gtk-4.0/gtk.css is created holding the import" file_is "$cfg/gtk-4.0/gtk.css" "@import url(\"file://$live/gtk4.css\");"$'\n'
check "gtk3 takes the accent as rgba" grep -qxF '@define-color accent_bg_color rgba(17, 17, 17, 1);' "$live/gtk3.css"
check "gtk3 takes the view background" grep -qxF '@define-color view_bg_color rgba(0, 0, 0, 1);' "$live/gtk3.css"
check "every gtk3 colour is rgba" gtk_colours_are_rgba "$live/gtk3.css"
check "gtk4 sets libadwaita's accent variable" grep -qxF '  --accent-bg-color: rgba(17, 17, 17, 1);' "$live/gtk4.css"
check "gtk4 sets the named window text colour" grep -qxF '@define-color window_fg_color rgba(215, 215, 217, 1);' "$live/gtk4.css"
check "every gtk4 colour is rgba" gtk_colours_are_rgba "$live/gtk4.css"
check "qt5ct's scheme is linked into qt5ct/colors" links_to "$cfg/qt5ct/colors/vgs.conf" "$live/qt5ct.conf"
check "qt6ct's scheme is linked into qt6ct/colors" links_to "$cfg/qt6ct/colors/vgs.conf" "$live/qt6ct.conf"
check "qt5ct's scheme holds 21 #rrggbb roles with the accent as Highlight" qt_scheme_is "$live/qt5ct.conf" "#111111"
check "qt6ct's scheme holds 21 #rrggbb roles with the accent as Highlight" qt_scheme_is "$live/qt6ct.conf" "#111111"
check "the qt6ct hook touches qt6ct.conf, which qt6ct's watcher reads" test "$(mtime "$cfg/qt6ct/qt6ct.conf")" -gt 0
check "the qt6ct hook leaves qt6ct.conf's settings as they were" file_is "$cfg/qt6ct/qt6ct.conf" $'[Appearance]\nstyle=Fusion\n'
check "the qt5ct hook creates no qt5ct.conf" test ! -e "$cfg/qt5ct/qt5ct.conf"
check "the KDE scheme is linked into the home's color-schemes" links_to "$home/.local/share/color-schemes/Vgs.colors" "$live/kcolorscheme.colors"
check "the KDE scheme is #rrggbb with the accent as the selection" kde_scheme_is "$live/kcolorscheme.colors" "#111111"

touch -d @0 -- "$cfg/qt6ct/qt6ct.conf"
THEME_PATH="$with_stubs" tinst "a package's curated toolkit files land" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json curated
for file in gtk3.css gtk4.css qt6ct.conf kcolorscheme.colors; do
  check "$file takes the curated file byte for byte" cmp -s -- "$tree/themes/curated/targets/$file" "$live/$file"
done
check "qt6ct's changed bytes run its hook again" test "$(mtime "$cfg/qt6ct/qt6ct.conf")" -gt 0

printf '{ "disabledTargets": ["gtk3", "kcolorscheme", "qt6ct"] }\n' >"$cfg/vgs/shell.json"
THEME_PATH="$with_stubs" tinst "disabled toolkits" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json dusk
check "the disabled toolkits are skipped" test "$(states)" == "color-scheme=unchanged gtk3=skipped gtk4=written icons=unchanged kcolorscheme=skipped qt5ct=written qt6ct=skipped"
check "a disabled gtk3 leaves only the user's rules in gtk.css" file_is "$cfg/gtk-3.0/gtk.css" $'window { padding: 0; }\n'
check "a disabled qt6ct loses its link and keeps its colors directory" test ! -e "$cfg/qt6ct/colors/vgs.conf" -a ! -L "$cfg/qt6ct/colors/vgs.conf" -a -d "$cfg/qt6ct/colors"
check "a disabled KDE scheme loses its link and keeps color-schemes" test ! -L "$home/.local/share/color-schemes/Vgs.colors" -a -d "$home/.local/share/color-schemes"
check "the disabled toolkits' files leave theme/" test ! -e "$live/gtk3.css" -a ! -e "$live/qt6ct.conf" -a ! -e "$live/kcolorscheme.colors"
for stub in "${detected[@]}"; do
  check "detection never ran $stub" test ! -e "$tmp/ran-$stub"
done
rm -f -- "$cfg/vgs/shell.json"

# icons: the package's curated icons.theme names the icon theme, asserted
# through gsettings on every apply once it is installed and not already set.
# A package without one, dusk and curated here, sets none.
check "a package without an icon theme sets none" test ! -e "$gs_sets"
check "detection never ran gsettings" test ! -e "$tmp/ran-gsettings"
check "the icons file of a package without one is empty" test -e "$live/icons.theme" -a ! -s "$live/icons.theme"
icon_pkg() { # NAME ICON_THEME
  theme_pkg "$tree/themes/$1" "{ \"schemaVersion\": 1, \"name\": \"$1\", \"tokens\": {} }"
  mkdir -p "$tree/themes/$1/targets"; printf '%s\n' "$2" >"$tree/themes/$1/targets/icons.theme"
}
icon_pkg iconic Papirus-Dark
icon_pkg uninstalled vgs-no-such-icons
icon_pkg traversal ../x
mkdir -p "$home/.local/share/icons/Papirus-Dark"
set_line="set org.gnome.desktop.interface icon-theme Papirus-Dark"
sets_are() { [[ "$(cat -- "$gs_sets" 2>/dev/null)" == "$1" ]]; }
THEME_PATH="$with_stubs" tinst "a package's icon theme applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json iconic
check "the curated icon theme is written" test "$(states)" == "color-scheme=unchanged gtk3=written gtk4=written icons=written kcolorscheme=written qt5ct=written qt6ct=written"
check "the installed icon theme is set" sets_are "$set_line"
printf "'Papirus-Dark'\n" >"$gs_current"; : >"$gs_sets"
THEME_PATH="$with_stubs" tinst "an icon theme already set" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json iconic
check "an icon theme already set is not set again" sets_are ""
printf "'Adwaita'\n" >"$gs_current"
THEME_PATH="$with_stubs" tinst "an icon theme changed by hand" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json iconic
check "unchanged bytes keep icons unchanged" test "$(states)" == "color-scheme=unchanged gtk3=unchanged gtk4=unchanged icons=unchanged kcolorscheme=unchanged qt5ct=unchanged qt6ct=unchanged"
check "unchanged bytes assert the icon theme again" sets_are "$set_line"
: >"$gs_sets"
THEME_PATH="$with_stubs" tinst "an icon theme that is not installed" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json uninstalled
check "an icon theme that is not installed is not set" sets_are ""
THEME_PATH="$with_stubs" tinst "an icon theme name holding a path" "$cfg" "$rt_empty" 3 "$any_out" "vgsh: refused: target=icons reason=reload-failed command=sh status=1" theme apply --json traversal
check "an icon theme name holding a path is reload-pending" python3 -c 'import json,sys; t = {x["name"]: x for x in json.loads(sys.argv[1])["targets"]}; sys.exit(0 if t["icons"]["state"] == "reload-pending" else 1)' "$(tail -n 1 "$tmp/out")"
check "an icon theme name holding a path is not set" sets_are ""
THEME_PATH="$with_stubs" tinst "a package without an icon theme clears the pending icons" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json dusk

# color-scheme: the package's scheme.mode, asserted as GTK's colour scheme
# through gsettings on every apply unless the value already holds.
dark_line="set org.gnome.desktop.interface color-scheme prefer-dark"
light_line="set org.gnome.desktop.interface color-scheme prefer-light"
scheme_sets_are() { [[ "$(cat -- "$cs_sets" 2>/dev/null)" == "$1" ]]; }
: >"$cs_sets"
THEME_PATH="$with_stubs" tinst "a dark package" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json dusk
check "a dark package sets prefer-dark" scheme_sets_are "$dark_line"
check "the dark package's mode file is prefer-dark" file_is "$live/color-scheme.mode" $'prefer-dark\n'
: >"$cs_sets"
THEME_PATH="$with_stubs" tinst "a light package" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json light
check "a light package's mode is written" test "$(states)" == "color-scheme=written gtk3=written gtk4=written icons=unchanged kcolorscheme=written qt5ct=written qt6ct=written"
check "a light package sets prefer-light" scheme_sets_are "$light_line"
printf "'prefer-light'\n" >"$cs_current"; : >"$cs_sets"
THEME_PATH="$with_stubs" tinst "a colour scheme already set" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json light
check "a colour scheme already set is not set again" scheme_sets_are ""
printf "'prefer-dark'\n" >"$cs_current"
THEME_PATH="$with_stubs" tinst "a colour scheme changed by hand" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json light
check "unchanged bytes keep color-scheme unchanged" test "$(states)" == "color-scheme=unchanged gtk3=unchanged gtk4=unchanged icons=unchanged kcolorscheme=unchanged qt5ct=unchanged qt6ct=unchanged"
check "unchanged bytes assert the colour scheme again" scheme_sets_are "$light_line"

# Controls: each mutant target.json drops one rule, and the assertion that
# pins it must turn. The rows above use the same assertions.
# Each starts from no state directory, so every target's bytes change and
# its hook is due.
control_cfg() { cfg="$tmp/cfg-$1"; mkdir -p "$cfg/vgs"; rm -rf -- "${state:?}"; }
tree_control gtk3-encoder themes/targets/gtk3/target.json '"encoder": "rgba"' '"encoder": "hex6"'
control_cfg gtk3-encoder
THEME_PATH="$with_stubs" tinst "the gtk3 hex6 mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the gtk3 hex6 mutant's colours are not rgba" test "$(gtk_colours_are_rgba "$live/gtk3.css"; echo $?)" == 1
tree_control gtk4-create themes/targets/gtk4/target.json '"create": true' '"create": false'
control_cfg gtk4-create
THEME_PATH="$with_stubs" tinst "the non-creating gtk4 mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the non-creating gtk4 mutant writes no gtk.css" test ! -e "$cfg/gtk-4.0/gtk.css"
tree_control qt6ct-encoder themes/targets/qt6ct/target.json '"encoder": "hex6"' '"encoder": "hex8"'
control_cfg qt6ct-encoder
THEME_PATH="$with_stubs" tinst "the qt6ct hex8 mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the qt6ct hex8 mutant's roles are not #rrggbb" test "$(qt_scheme_is "$live/qt6ct.conf" "#111111"; echo $?)" == 1
tree_control qt5ct-reload themes/targets/qt5ct/target.json '"touch -c -- ' '"touch -- '
control_cfg qt5ct-reload
THEME_PATH="$with_stubs" tinst "the creating qt5ct hook mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the creating qt5ct hook mutant creates qt5ct.conf" test -e "$cfg/qt5ct/qt5ct.conf"
tree_control kcolorscheme-base themes/targets/kcolorscheme/target.json '"base": "home"' '"base": "config"'
control_cfg kcolorscheme-base; rm -rf -- "$home/.local/share/color-schemes"
THEME_PATH="$with_stubs" tinst "the configuration-home KDE mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the configuration-home KDE mutant links no scheme where KDE reads it" test ! -L "$home/.local/share/color-schemes/Vgs.colors"
tree_control icons-always themes/targets/icons/target.json '"always": true' '"always": false'
control_cfg icons-always
THEME_PATH="$with_stubs" tinst "the changed-only icons mutant lands iconic" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply iconic
printf "'Adwaita'\n" >"$gs_current"; : >"$gs_sets"
THEME_PATH="$with_stubs" tinst "the changed-only icons mutant applies unchanged bytes" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply iconic
check "the changed-only icons mutant never asserts the icon theme again" sets_are ""
tree_control icons-installed themes/targets/icons/target.json '[ -n \"$found\" ] || exit 0; ' ''
control_cfg icons-installed
THEME_PATH="$with_stubs" tinst "the installed-check mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply uninstalled
check "the installed-check mutant sets an icon theme that is not installed" sets_are "set org.gnome.desktop.interface icon-theme vgs-no-such-icons"
tree_control color-scheme-skip themes/targets/color-scheme/target.json '[ \"$(gsettings get org.gnome.desktop.interface color-scheme)\" = \"'"'"'$mode'"'"'\" ] && exit 0; ' ''
control_cfg color-scheme-skip
printf "'prefer-light'\n" >"$cs_current"; : >"$cs_sets"
THEME_PATH="$with_stubs" tinst "the no-skip colour scheme mutant applies" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply light
check "the no-skip colour scheme mutant sets a colour scheme already set" scheme_sets_are "$light_line"
tree_control color-scheme-always themes/targets/color-scheme/target.json '"always": true' '"always": false'
control_cfg color-scheme-always
THEME_PATH="$with_stubs" tinst "the changed-only colour scheme mutant lands light" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply light
printf "'prefer-dark'\n" >"$cs_current"; : >"$cs_sets"
THEME_PATH="$with_stubs" tinst "the changed-only colour scheme mutant applies unchanged bytes" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply light
check "the changed-only colour scheme mutant never asserts the colour scheme again" scheme_sets_are ""
unset THEME_BIN

rows_done test-vgsh-toolkits
