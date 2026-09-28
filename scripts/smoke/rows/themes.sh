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
