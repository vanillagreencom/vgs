# theme.json restyles every surface through Theme; the bar's foreground is
# read back from a built bar instance and token values from Theme itself.
# A document the judge refuses is logged with its token and reason and
# leaves the last accepted theme; an absent file publishes the defaults.
set -euo pipefail
theme="$home/.config/vgs/theme.json"
# A QML color reads back as its channel object; the row compares its hex.
bar_foreground() { ipc smoke readInstance "$(bar_key)" vgs.bar foreground | py_reply 'import json,sys; c=json.load(sys.stdin); print("#%02x%02x%02x" % tuple(round(c[k] * 255) for k in "rgb"))'; }
theme_value() { ipc smoke themeValue "$1"; }
write_theme() { printf '%s\n' "$1" >"$theme.tmp" && mv -T -- "$theme.tmp" "$theme"; }

expect "every top-level token group is published frozen" '[]' ipc smoke themeUnpublished
expect "the bundled mono family is available" true ipc smoke fontAvailable "JetBrains Mono"
expect "the bundled sans family is available" true ipc smoke fontAvailable "Inter Variable"
expect "body text draws the bundled sans family" '"Inter Variable"' theme_value text.body.family
expect "label text draws the bundled mono family" '"JetBrains Mono"' theme_value text.label.family
expect "the bar draws the default foreground with no theme file" '#d7d7d9' bar_foreground
expect "the default theme is named" vgs ipc smoke themeName
expect "a derived colour resolves from the palette, alpha first" '"#ff000000"' theme_value color.onAccent
expect "a length resolves to whole pixels" 28 theme_value bar.height
expect "a write to a published token changes nothing" '"#ff000000"' ipc smoke themeWrite color.onAccent '#ffffffff'
group_after_write() { ipc smoke themeWrite color '{}' >/dev/null && theme_value color.onAccent; }
expect "a write to a published group changes nothing" '"#ff000000"' group_after_write
revision_before="$(ipc smoke themeRevision)" || revision_before=""

write_theme '{ "schemaVersion": 1, "name": "probe", "tokens": { "palette": { "foreground": "#123456" }, "bar": { "active": "#ffffff" } } }'
expect_poll "a theme file recolours the bar's foreground" '#123456' bar_foreground
expect "the accepted theme's name is published" probe ipc smoke themeName
expect "a component override changes the values derived from it" '"#ff000000"' theme_value bar.onActive
expect "the revision rose once for one accepted theme" "$((revision_before + 1))" ipc smoke themeRevision

expected_errors+=('theme: refused: document reason=not-json ')
write_theme '{ nope'
expect_log "a theme file that does not parse is refused" 1 'theme: refused: document reason=not-json .* file=.*/theme\.json'
expect "an unparseable theme file keeps the last theme" '#123456' bar_foreground
expected_errors+=('theme: refused: document reason=unknown-key key=foreground')
write_theme '{ "foreground": "#654321" }'
expect_log "the old palette shape is refused by its first key" 1 'theme: refused: document reason=unknown-key key=foreground file=.*/theme\.json'
expect "a refused document changes nothing" '#123456' bar_foreground
expected_errors+=('theme: refused: token=palette\.acent reason=unknown-token')
write_theme '{ "schemaVersion": 1, "name": "probe", "tokens": { "palette": { "acent": "#654321" } } }'
expect_log "an unknown token is refused by its path" 1 'theme: refused: token=palette\.acent reason=unknown-token file=.*/theme\.json'
expected_errors+=('theme: refused: token=radius\.md reason=type')
write_theme '{ "schemaVersion": 1, "name": "probe", "tokens": { "radius": { "md": "#654321" } } }'
expect_log "a value of the wrong type is refused by its token" 1 'theme: refused: token=radius\.md reason=type want=length got=color file=.*/theme\.json'
expect "the last accepted theme stands through every refusal" probe ipc smoke themeName
expect "the revision did not move for a refused document" "$((revision_before + 1))" ipc smoke themeRevision

# A family a theme names that Qt does not list is logged once for each
# bundled family drawn in its place: the one the token's default names.
expected_errors+=('theme: font=No Such Family unavailable')
write_theme '{ "schemaVersion": 1, "name": "fonts", "tokens": { "font": { "family": { "mono": "No Such Family", "sans": "No Such Family" } } } }'
expect_log "an unavailable mono family is logged once" 1 'theme: font=No Such Family unavailable; drawing JetBrains Mono'
expect_log "an unavailable sans family is logged once" 1 'theme: font=No Such Family unavailable; drawing Inter Variable'
expect_poll "an unavailable mono family draws the bundled mono family" '"JetBrains Mono"' theme_value text.label.family
expect_poll "an unavailable sans family draws the bundled sans family" '"Inter Variable"' theme_value text.body.family

# A theme file removed while the shell runs publishes the defaults, so the
# bar draws what a fresh start without the file would. The watcher keeps
# the file's directory, so a file created in its place is read again. A
# file that turns unreadable is logged and the last theme stays; a
# permission change alone reaches the watcher, so no reload is forced.
rm -f -- "${theme:?}"
expect_poll "a removed theme file returns the bar's foreground to the default" '#d7d7d9' bar_foreground
expect "a removed theme file publishes the default name" vgs ipc smoke themeName
write_theme '{ "schemaVersion": 1, "name": "again", "tokens": { "palette": { "foreground": "#654321" } } }'
expect_poll "a theme file created after a removal recolours the bar's foreground" '#654321' bar_foreground
expected_errors+=('theme: .*/theme\.json unreadable: ')
chmod 000 -- "$theme"
expect_log "a theme file that turns unreadable is logged" 1 'theme: .*/theme\.json unreadable: '
expect "an unreadable theme file keeps the last theme" '#654321' bar_foreground
chmod 644 -- "$theme"
write_theme '{ "schemaVersion": 1, "name": "again", "tokens": { "palette": { "foreground": "#123456" } } }'
expect_poll "a theme file readable again recolours the bar's foreground" '#123456' bar_foreground
