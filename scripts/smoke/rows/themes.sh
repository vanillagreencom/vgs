# The theme capability, driven through the fixture service and read back
# from what its callbacks received, from its `shell.theme` members, from
# Theme itself and from the core's lending record. rows/theme.sh leaves a
# hand-written document active, so the first apply is the vgs package.
# `done` can run before ThemeSource reloads the file, so `current` and
# `revision` are polled after it. The last block applies the shipped light
# package and reads one colour of each gallery section back as a property,
# then applies vgs so later rows start from the defaults.
set -euo pipefail
installed="$home/.config/vgs/themes"
# What the fixture's last apply callback received: state, shell, theme and
# reason, a null reason printed as None.
applied() { read_service themeApplied | python3 -c 'import json,sys; r=json.loads(json.load(sys.stdin)); print(r["state"], r["shell"], r["theme"], r["reason"])'; }
# The [name, state, reason] rows of that result's targets whose name starts
# with PREFIX.
applied_targets() { read_service themeApplied | python3 -c 'import json,sys; r=json.loads(json.load(sys.stdin)); print(json.dumps([[t["name"], t["state"], t["reason"]] for t in r["targets"] if t["name"].startswith(sys.argv[1])]))' "$1"; }
# What the fixture's last list callback received: `packages` as
# [name, source, state, reason] rows, `current` the rows marked current,
# `file` its state, name and modified flag, `reason` the list's own.
listed() {
  read_service themeListed | python3 -c '
import json, sys
r = json.loads(json.load(sys.stdin))
part = sys.argv[1]
if part == "packages": print(json.dumps(sorted([p["name"], p["source"], p["state"], p["reason"]] for p in r["packages"])))
elif part == "current": print(json.dumps(sorted(p["name"] for p in r["packages"] if p["current"])))
elif part == "file": print(r["file"]["state"], r["file"]["name"], r["file"]["modified"])
else: print(r["reason"])' "$1"
}
applies() { read_service themeApplies; }
lists() { read_service themeLists; }
theme_member() { probe theme "$1"; }
last_part() { probe theme last | python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v=v.get(k) if isinstance(v, dict) else None
print(json.dumps(v))' "$1"; }
swatch_accent() { probe theme "swatch=$1" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["accent"]))'; }
theme_jobs() { ipc shell lent | python3 -c 'import json,sys; print(json.dumps([[j["verb"], j["name"], j["waiters"]] for j in json.load(sys.stdin)["theme"]["jobs"]]))'; }
revision_rose() { local now; now="$(theme_member revision)" && [[ $now -gt $revision_before ]] && echo rose || echo same; }
# The sandbox copy's vgsh runs BODY for a theme command and the real
# runner for everything else, so the rows' own ipc calls keep working.
cp -p -- "$repo/bin/vgsh" "$repo/bin/vgsh.real"
stand_in_vgsh() {
  printf '#!/usr/bin/env bash\nif [[ ${1:-} == theme ]]; then\n%s\nfi\nexec %q "$@"\n' "$1" "$repo/bin/vgsh.real" >"$repo/bin/vgsh.next" \
    && chmod 755 -- "$repo/bin/vgsh.next" && mv -T -- "$repo/bin/vgsh.next" "$repo/bin/vgsh"
}

expect "enabling the fixture for the theme rows is allowed" ok ipc shell setPluginEnabled acme.probe true
expect_poll "the fixture service is back for the theme rows" True service_built
expect_poll "the rebuilt fixture has applied nothing" 0 applies

revision_before="$(theme_member revision)"
expect "the fixture applies the vgs package" ok probe theme-apply vgs
expect_poll "the vgs apply's result reaches the fixture" 1 applies
expect "the vgs apply wrote the shell's file" "applied applied vgs None" applied
expect "the sandbox copy ships no target, so no hook reaches a host application" '[]' applied_targets ""
expect_poll "current follows the vgs apply" '"vgs"' theme_member current
expect_poll "revision rose after the vgs apply" rose revision_rose
expect "last holds the vgs result with no apply running" '"applied"' last_part result.state

mkdir -p -- "$installed/smoke" "$installed/mismatch"
printf '%s\n' '{ "schemaVersion": 1, "name": "smoke", "tokens": { "palette": { "accent": "#12ab34" } } }' >"$installed/smoke/theme.json"
printf '%s\n' '{ "schemaVersion": 1, "name": "other", "tokens": {} }' >"$installed/mismatch/theme.json"
expect "the fixture asks for the list" ok probe theme-list
expect_poll "the list reaches the fixture" 1 lists
expect "the list names every package with its source and state" '[["light", "shipped", "ok", null], ["mismatch", "installed", "refused", "name-mismatch"], ["smoke", "installed", "ok", null], ["vgs", "shipped", "ok", null]]' listed packages
expect "the list marks the vgs package current" '["vgs"]' listed current
expect "the list reads the file loaded and unmodified" "loaded vgs False" listed file
expect "modified follows the last list" false theme_member modified
expect "fileState follows the shell's file" '"loaded"' theme_member fileState
expect "a swatch is the package's palette, alpha first" '"#ff12ab34"' swatch_accent smoke
expect "a refused package has no swatch" null theme_member swatch=mismatch
expect "an unknown package has no swatch" null theme_member swatch=nosuch

revision_before="$(theme_member revision)"
expect "the fixture applies an installed package" ok probe theme-apply smoke
expect_poll "the installed package's result reaches the fixture" 2 applies
expect "the installed package's apply wrote the shell's file" "applied applied smoke None" applied
expect_poll "current follows the installed package" '"smoke"' theme_member current
expect_poll "revision rose after the installed package's apply" rose revision_rose
expect "the shell draws the installed package's accent" '"#ff12ab34"' ipc smoke themeValue palette.accent
expect "applying the same package again is accepted" ok probe theme-apply smoke
expect_poll "the repeat apply's result reaches the fixture" 3 applies
expect "the repeat apply leaves the file unchanged" "unchanged unchanged smoke None" applied
# The runner refuses an unknown package with exit 1 and its JSON result.
expect "an unknown package's apply is accepted" ok probe theme-apply nosuch
expect_poll "the unknown package's result reaches the fixture" 4 applies
expect "the refusal's output is the result, not discarded" "failed unchanged nosuch unknown" applied
expect "a malformed name is refused at once" 'refused: theme="../x" reason=malformed-name' probe theme-apply ../x
expect "a malformed name queues nothing" '[]' theme_jobs

# A real partial apply: two fixture targets in the sandbox copy, which ships
# no target of its own, always detected, one naming no token. The shell takes the
# theme, the other target lands, and the result and its exit 3 reach the
# fixture whole.
fixture_targets="$repo/themes/targets"
fixture_target() { # NAME TEMPLATE_TEXT
  mkdir -p -- "$fixture_targets/$1"
  printf '{ "app": "%s", "encoder": "hex8", "files": [{ "template": "%s.conf", "destination": "%s.conf" }], "detect": [], "wiring": { "file": "%s/%s.conf", "line": "include=@{state}/%s.conf", "create": true }, "reload": null }\n' "$1" "$1" "$1" "$1" "$1" "$1" >"$fixture_targets/$1/target.json"
  printf '%s\n' "$2" >"$fixture_targets/$1/$1.conf"
}
fixture_target smoke-fails 'accent=@{palette.nope}'
fixture_target smoke-lands 'accent=@{palette.accent}'
expect "an apply a fixture target fails in is accepted" ok probe theme-apply vgs
expect_poll "the partial result reaches the fixture" 5 applies
expect "the shell takes the theme in a partial apply" "partial applied vgs None" applied
expect "the partial result names each fixture target's state" '[["smoke-fails", "failed", "placeholder"], ["smoke-lands", "written", null]]' applied_targets smoke-
expect "last holds the partial result" '"partial"' last_part result.state
expect "the landed fixture target's file is rendered into the state directory" "accent=ff5a36ff" cat "$home/.local/state/vgs/theme/smoke-lands.conf"
expect "the landed fixture target's include line is wired" "include=$home/.local/state/vgs/theme/smoke-lands.conf" cat "$home/.config/smoke-lands/smoke-lands.conf"
rm -r -- "$fixture_targets/smoke-fails" "$fixture_targets/smoke-lands"

write_theme '{ "schemaVersion": 1, "name": "smoke", "tokens": { "palette": { "accent": "#12ab35" } } }'
expect_poll "the shell takes a hand edit" '"#ff12ab35"' ipc smoke themeValue palette.accent
expect "the fixture lists after the hand edit" ok probe theme-list
expect_poll "the second list reaches the fixture" 2 lists
expect "a hand edit is modified" true theme_member modified
write_theme '{ nope'
expect_poll "fileState follows a refused edit" '"refused"' theme_member fileState
expect "a refused edit keeps current" '"smoke"' theme_member current

# The gate holds a theme command until the row creates it, polling every
# 50 ms for at most 10 s, so the apply is still running while the row
# reads it, and the instance that asked is destroyed under it.
gate="$sandbox/theme-gate"
stand_in_vgsh "for _ in \$(seq 1 200); do [[ -e $(printf %q "$gate") ]] && break; sleep 0.05; done"
expect "an apply starts behind the gate" ok probe theme-apply vgs
expect "a second apply while one runs is refused at once" "refused: theme=smoke reason=busy" probe theme-apply smoke
expect "a list asked for during the apply is accepted" ok probe theme-list
expect "last names the running apply" '"vgs"' last_part applying
expect "the lending record holds both jobs with the fixture waiting on each" '[["apply", "vgs", 1], ["list", null, 1]]' theme_jobs
expect "disabling the fixture during the apply is allowed" ok ipc shell setPluginEnabled acme.probe false
expect_poll "the destroyed instance's callbacks are dropped" '[["apply", "vgs", 0], ["list", null, 0]]' theme_jobs
touch -- "$gate"
expect_poll "the apply and the list complete without their instance" '[]' theme_jobs
expect "the core kept the result" '"applied"' lent theme.last.result.state
expect "re-enabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
expect_poll "the fixture service is rebuilt" True service_built
expect_poll "the rebuilt instance reads the result from last" '"applied"' last_part result.state
expect "the result in last names the apply" '"vgs"' last_part result.theme
expect "the rebuilt instance received no callback" 0 applies
expect_poll "current follows the apply that outlived its instance" '"vgs"' theme_member current

expected_errors+=('theme: vgsh theme apply reason=output-unreadable name=smoke exit=2 ' 'theme: vgsh theme list reason=output-unreadable exit=2 ')
stand_in_vgsh 'echo "no result"; exit 2'
expect "an apply whose runner prints no result is accepted" ok probe theme-apply smoke
expect_poll "the unreadable apply reaches the fixture" 1 applies
expect "an apply with no result is a failed shell with its reason" "failed failed smoke output-unreadable" applied
expect "a list whose runner prints no result is accepted" ok probe theme-list
expect_poll "the unreadable list reaches the fixture" 1 lists
expect "a list with no result carries its reason" output-unreadable listed reason
expect "a failed list leaves no modified answer" null theme_member modified
expect "a failed list leaves no swatch" null theme_member swatch=smoke

# A runner that cannot start: the rows reach the shell through qs itself,
# since the sandbox's vgsh is the file that cannot start.
qs_call() { "${shell_env[@]}" qs ipc --pid "$shell_pid" call "$@" 2>>"$sandbox/ipc.log" | tail -n 1; }
expected_errors+=('theme: vgsh theme apply reason=start-failed name=smoke')
chmod 000 -- "$repo/bin/vgsh"
expect "an apply whose runner cannot start is accepted" ok qs_call acme.probe invoke theme-apply smoke
expect_poll "the failed start reaches the fixture" 2 qs_call smoke readInstance service acme.probe themeApplies
chmod 755 -- "$repo/bin/vgsh"
expect "a failed start is a failed shell with its reason" "failed failed smoke start-failed" applied
expect_log "the failed start is logged" 1 'theme: vgsh theme apply reason=start-failed name=smoke'
expect "no job waits after a failed start" '[]' theme_jobs

mv -T -- "$repo/bin/vgsh.real" "$repo/bin/vgsh"
expect "the fixture applies vgs with the real runner again" ok probe theme-apply vgs
expect_poll "the last apply's result reaches the fixture" 3 applies
expect "the vgs package is applied again" "unchanged unchanged vgs None" applied

# The shipped light package restyles every section of the gallery, not the
# bar alone. Each section's example is read back as a property, never a
# drawn frame, and compared with the token the shell's own judge resolves
# from the package file under node, which must differ from the vgs
# default, so a read that always matches fails. vgs is applied after it,
# so later rows start from the defaults.
# One example per section of the gallery: SECTION TYPE PROPERTY TOKEN.
gallery_colours=(
  "Surfaces Surface color surface.level.base.background"
  "Typography Label color text.display.color"
  "Buttons Button fill button.variant.primary.background"
  "Choices Switch indicator.color toggle.off"
  "Inputs TextField background.color textField.background"
  "Feedback Badge color badge.tone.neutral.background"
  "Lists Divider color divider.color"
)
# The colour ThemeLogic.accept resolves for TOKEN from shipped package
# NAME, as `#rrggbbaa`.
resolved_token() {
  node -e '
const fs = require("fs"), path = require("path");
const [repo, name, token] = process.argv.slice(1);
const { load } = require(path.join(repo, "scripts", "qml-library.js"));
const logic = load(path.join(repo, "shell", "Commons", "ThemeLogic.js"));
const { TOKENS } = load(path.join(repo, "shell", "Commons", "Tokens.js"));
const result = logic.accept(TOKENS, fs.readFileSync(path.join(repo, "themes", name, "theme.json"), "utf8"));
if (!result.ok) { process.stderr.write("resolved_token: " + logic.refusalLine(result) + "\n"); process.exit(1); }
let value = result.values;
for (const key of token.split(".")) value = value === undefined ? undefined : value[key];
if (typeof value !== "string") { process.stderr.write("resolved_token: absent token=" + token + "\n"); process.exit(1); }
console.log(value);' "$repo" "$1" "$2"
}
gallery_colour() { ipc smoke galleryColour panel vgs.gallery "$@"; }

revision_before="$(theme_member revision)"
expect "the fixture applies the light package" ok probe theme-apply light
expect_poll "the light apply's result reaches the fixture" 4 applies
expect "the light apply wrote the shell's file" "applied applied light None" applied
expect_poll "current follows the light apply" '"light"' theme_member current
expect_poll "revision rose after the light apply" rose revision_rose
expect "the gallery summons under the light package" ok ipc shell summon panel vgs.gallery '{}'
expect_poll "the light gallery maps one panel surface" 1 layer_count vgs:panel
for row in "${gallery_colours[@]}"; do
  read -r section type property token <<<"$row"
  if ! light="$(resolved_token light "$token")" || ! default="$(resolved_token vgs "$token")"; then
    fail "the judge resolves $token for the light and vgs packages"
    continue
  fi
  if [[ $light == "$default" ]]; then fail "the light package's $token differs from vgs: both $light"; else ok "the light package's $token differs from vgs"; fi
  expect_poll "the gallery's $section example draws the light package's $token" "$light" gallery_colour "$section" "$type" "$property"
done
expect "hiding the light gallery is allowed" ok ipc shell hide panel vgs.gallery
expect_poll "the light gallery's surface is gone" 0 layer_count vgs:panel

revision_before="$(theme_member revision)"
expect "the fixture applies vgs after the light package" ok probe theme-apply vgs
expect_poll "the vgs apply after the light package reaches the fixture" 5 applies
expect "the vgs apply after the light package wrote the shell's file" "applied applied vgs None" applied
expect_poll "current follows the vgs apply after the light package" '"vgs"' theme_member current
expect_poll "revision rose after the vgs apply after the light package" rose revision_rose
expect "disabling the fixture after the theme rows is allowed" ok ipc shell setPluginEnabled acme.probe false

# ---- vgs.themes: the themes widget and panel ------------------------------
# The first-party themes plugin, reached the way a user reaches it: `vgsh
# plugin enable vgs.themes` places its widget in its default section, a
# click on the widget opens the panel under it, and a click on a row
# applies that package. The panel is read back through what it draws: each
# ThemeRow's visible texts (name, source, badges, then one line per
# problem of the last result) and its swatch colours. An installed copy of
# `light` shadows the shipped one, beside the installed `smoke` and the
# refused `mismatch` the rows above left. A fixture target that fails gives
# the result a failed target, and a stand-in runner a target state the
# panel names nowhere. The block leaves vgs applied and the plugin
# disabled, so later rows see the bar they saw before it.
layout_section_of() { ipc shell listShellConfig | python3 -c 'import json,sys; l=json.load(sys.stdin)["bar"]["layout"]; print(([s for s in ("left","center","right") if any(e["id"]==sys.argv[1] for e in l.get(s,[]))] + ["none"])[0])' "$1"; }
theme_rows() { ipc smoke itemTexts panel vgs.themes ThemeRow | python3 -c 'import json,sys; print(json.dumps(sorted(json.load(sys.stdin))))'; }
# The rows whose name is NAME, in tree order.
theme_row() { ipc smoke itemTexts panel vgs.themes ThemeRow | python3 -c 'import json,sys; print(json.dumps([r for r in json.load(sys.stdin) if r[0]==sys.argv[1]]))' "$1"; }
# The swatch of the one row named NAME whose secondary line is SECONDARY:
# its chip count and whether a chip draws COLOUR, as `#rrggbbaa`.
theme_swatch() {
  local texts colours
  texts="$(ipc smoke itemTexts panel vgs.themes ThemeRow)" && colours="$(ipc smoke itemColours panel vgs.themes ThemeRow Surface)" || return
  python3 -c 'import json,sys; t,c=json.loads(sys.argv[1]),json.loads(sys.argv[2]); m=[c[i] for i,r in enumerate(t) if r[:2]==sys.argv[3:5]]; print(json.dumps([len(m[0]), sys.argv[5] in m[0]]) if len(m)==1 else "rows=%d" % len(m))' "$texts" "$colours" "$1" "$2" "$3"
}
# click_row NAME: one click on the centre of the enabled list item NAME,
# polled for up to 5 s while a running apply disables the rows.
click_row() {
  local rect=absent
  for _ in $(seq 1 25); do
    rect="$(ipc smoke itemGeometry panel vgs.themes ListItem "$1")" && [[ $rect != absent ]] && break
    sleep 0.2
  done
  [[ $rect != absent ]] || return 1
  read -r cx cy < <(python3 -c 'import json,sys; x,y,w,h=json.loads(sys.argv[1]); print(int(x+w/2), int(y+h/2))' "$rect")
  click "$cx" "$cy"
}
# Whether the panel draws a label reading TEXT: True or False.
panel_label() { ipc smoke itemTexts panel vgs.themes Label | python3 -c 'import json,sys; print([sys.argv[1]] in json.load(sys.stdin))' "$1"; }
panel_open() { [[ $(ipc smoke readInstance panel vgs.themes packages) != absent ]] && echo open || echo closed; }
# A click the panel does not cover: the lower-left quarter of the screen,
# away from the right section the panel opens under.
click_outside() { click "$((mon_w / 4))" "$((mon_h * 3 / 4))"; }

expect "the themes panel is enabled as first-party before any placement" True plugin_enabled vgs.themes
expect "the themes panel summons before its widget is placed" ok ipc shell summon panel vgs.themes '{}'
expect_poll "the unanchored themes panel maps one panel surface" 1 layer_count vgs:panel
expect "hiding the unanchored themes panel is allowed" ok ipc shell hide panel vgs.themes
expect_poll "the unanchored themes panel's surface is gone" 0 layer_count vgs:panel
expect "the themes widget has no placement before it is enabled" none layout_section_of vgs.themes
expect "vgsh plugin enable places the themes widget" ok "${shell_env[@]}" "$repo/bin/vgsh" plugin enable vgs.themes
expect_poll "the themes widget lands in its default section" right layout_section_of vgs.themes
themes_key="$(bar_key)"
expect_poll "the themes widget is built on the bar" '"vgs.themes"' ipc smoke readInstance "$themes_key" vgs.themes moduleName

mkdir -p -- "$installed/light"
cp -- "$repo/themes/light/theme.json" "$repo/themes/light/terminal.json" "$installed/light/"
click_centre "$themes_key" vgs.themes || fail "the click on the themes widget failed"
expect_poll "a click on the widget opens the themes panel" open panel_open
expect_poll "the panel lists every package with its source and badges" '[["light", "installed"], ["light", "shipped", "Shadowed"], ["mismatch", "installed, name-mismatch", "Refused"], ["smoke", "installed"], ["vgs", "shipped", "Displayed"]]' theme_rows
expect "an accepted package's row draws its palette" '[7, true]' theme_swatch smoke installed '#12ab34ff'
expect "a refused package's row draws no swatch" '[0, false]' theme_swatch mismatch "installed, name-mismatch" '#12ab34ff'
expect "a shadowed package's row draws no swatch" '[0, false]' theme_swatch light shipped '#12ab34ff'

fixture_target smoke-fails 'accent=@{palette.nope}'
click_row smoke || fail "the click on the smoke row failed"
expect_poll "a click on a row applies its package" '"smoke"' lent theme.last.result.theme
expect_poll "the shell displays the package the row applied" smoke ipc smoke themeName
expect_poll "the applied row is displayed and shows its failed target" '[["smoke", "installed", "Displayed", "smoke-fails failed: placeholder"]]' theme_row smoke
expect "the previously displayed row loses its badge" '[["vgs", "shipped"]]' theme_row vgs
rm -r -- "$fixture_targets/smoke-fails"
click_row smoke || fail "the second click on the smoke row failed"
expect_poll "a later apply of that package that succeeds clears its failed target" '[["smoke", "installed", "Displayed"]]' theme_row smoke
# A hand edit that keeps the package's name marks its row Modified while
# the panel stays open, and a click on the row applies the package again
# and clears the badge.
write_theme '{ "schemaVersion": 1, "name": "smoke", "tokens": { "palette": { "accent": "#12ab36" } } }'
expect_poll "a hand edit of the displayed package marks its row modified" '[["smoke", "installed", "Displayed", "Modified"]]' theme_row smoke
click_row smoke || fail "the click reapplying the modified smoke row failed"
expect_poll "reapplying the modified package clears its badge" '[["smoke", "installed", "Displayed"]]' theme_row smoke

# The gate holds every theme command, polling every 50 ms for at most
# 10 s, so the panel closes while its apply runs.
cp -p -- "$repo/bin/vgsh" "$repo/bin/vgsh.real"
panel_gate="$sandbox/themes-panel-gate"
stand_in_vgsh "for _ in \$(seq 1 200); do [[ -e $(printf %q "$panel_gate") ]] && break; sleep 0.05; done"
click_row light || fail "the click on the installed light row failed"
expect_poll "the row shows the apply running" '[["light", "installed", "Applying"], ["light", "shipped", "Shadowed"]]' theme_row light
click_outside || fail "the click outside the themes panel failed"
expect_poll "a click outside closes the panel during the apply" closed panel_open
touch -- "$panel_gate"
expect_poll "the apply completes with the panel closed" '[]' theme_jobs
click_centre "$themes_key" vgs.themes || fail "the click reopening the themes panel failed"
expect_poll "the reopened panel shows the apply's result" '[["light", "installed", "Displayed"], ["light", "shipped", "Shadowed"]]' theme_row light
expect "the theme changed while the panel was closed" light ipc smoke themeName

# A panel reopened while its apply runs reads the apply from last, and the
# result it waits for carries a target state no code of the panel names.
# The same gate holds the stand-in.
novel_gate="$sandbox/themes-novel-gate"
novel='{"state":"partial","shell":"unchanged","targets":[{"name":"smoke-novel","state":"smoke-state","reason":"smoke-reason"}],"theme":"vgs","reason":null}'
stand_in_vgsh "for _ in \$(seq 1 200); do [[ -e $(printf %q "$novel_gate") ]] && break; sleep 0.05; done
if [[ \${2:-} == apply ]]; then printf '%s\\n' $(printf %q "$novel"); exit 3; fi"
click_row vgs || fail "the click on the vgs row failed"
expect_poll "the vgs row shows its apply running" '[["vgs", "shipped", "Applying"]]' theme_row vgs
click_outside || fail "the click outside the themes panel failed"
expect_poll "the panel closes during the vgs apply" closed panel_open
click_centre "$themes_key" vgs.themes || fail "the click reopening the themes panel during the apply failed"
expect_poll "the panel reopened during the apply reads it from last" True panel_label "Applying vgs"
touch -- "$novel_gate"
expect_poll "the reopened panel shows a target state it names nowhere" '[["vgs", "shipped", "smoke-novel smoke-state: smoke-reason"]]' theme_row vgs
expect "the panel drops the running apply once it ends" False panel_label "Applying vgs"

mv -T -- "$repo/bin/vgsh.real" "$repo/bin/vgsh"
click_row vgs || fail "the click on the vgs row with the real runner failed"
expect_poll "the vgs row applied by the real runner is displayed with no problem" '[["vgs", "shipped", "Displayed"]]' theme_row vgs
expect_poll "the vgs package is displayed again" vgs ipc smoke themeName
rm -r -- "$installed/light"
click_outside || fail "the click closing the themes panel failed"
expect_poll "the themes panel closes" closed panel_open
expect "vgsh plugin disable takes the themes widget off the bar" ok "${shell_env[@]}" "$repo/bin/vgsh" plugin disable vgs.themes
expect_poll "the themes widget is gone" False record_exists vgs.themes
# ---- end vgs.themes ---------------------------------------------------------
