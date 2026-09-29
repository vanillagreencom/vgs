# The requirement notice, raised for the fixture acme.needs, which misses
# one command it needs and two optional ones. Runs after rows/tui.sh and
# reuses its stand-in xdg-terminal-exec, which records the argv the core's
# TUI launch hands the terminal and runs the core's command as `true`, and
# its helpers. A stand-in bin/vgsh-pkg answers detection with pacman and
# paru, whatever the host runs. The Settings plugin is disabled throughout:
# the notice is the core's. Rows: `vgsh plugin add` raises the notice
# through pluginInstalled, which maps one surface centred on the focused
# monitor holding the keyboard and drawing each missing command with this
# system's package; Escape closes it and rests the plugin's own offers;
# enabling the plugin raises it again; the plugin's offer merges into a
# held notice and is refused while it rests, for a command it did not
# declare and for a value that is no list of commands; Install hands the
# terminal `vgsh pkg run install` with the primary's package, the notice
# stays open while the rescan after the run still misses the command and
# closes once a rescan finds it; a detection that fails shows the commands
# alone with Close.
set -euo pipefail
needs_src="$sandbox/src/acme.needs"
mkdir -p "$needs_src"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.needs/." "$needs_src/"
needs_git() { "${sandbox_env[@]}" git -C "$needs_src" -c user.name=smoke -c user.email=smoke@invalid "$@" >>"$sandbox/git.log" 2>&1; }
if needs_git init -q && needs_git add -A && needs_git commit -q -m fixture; then ok "the needs fixture is committed to a local repository"; else fail "needs fixture repository: $(tail -n 3 "$sandbox/git.log")"; fi

# Detection answers through bin/vgsh-pkg, which the shell and the add's
# judge both run under node; each stand-in is swapped in whole.
pkg_real="$sandbox/vgsh-pkg.real"
cp -- "$repo/bin/vgsh-pkg" "$pkg_real"
pkg_stub() { # DETECT_JSON, or "" for a detection that fails
  local body
  if [[ -n $1 ]]; then
    body="if (process.argv[2] === \"detect\" && process.argv[3] === \"--json\") { process.stdout.write('$1\\n'); process.exit(0); }"
  else
    body=""
  fi
  printf '#!/usr/bin/env node\n%s\nprocess.stderr.write("vgsh: refused: stub=vgsh-pkg\\n");\nprocess.exit(70);\n' "$body" >"$sandbox/vgsh-pkg.stub"
  chmod 755 "$sandbox/vgsh-pkg.stub"
  cp -- "$sandbox/vgsh-pkg.stub" "$repo/bin/vgsh-pkg.next" && mv -T -- "$repo/bin/vgsh-pkg.next" "$repo/bin/vgsh-pkg"
}
pkg_stub '{"primary":{"id":"pacman","binary":"pacman"},"overlays":[{"id":"aur","binary":"paru"}],"sources":[]}'

# The shown notice as [plugin, commands, required, installing], or null.
notice_shown() { ipc shell lent | python3 -c 'import json,sys; s=json.load(sys.stdin)["notices"]["shown"]; print(json.dumps(None if s is None else [s["plugin"], s["commands"], s["required"], s["installing"]]))'; }
notice_resting() { ipc shell lent | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["notices"]["resting"]))'; }
drawn() { ipc smoke noticeDrawn | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d[sys.argv[1]]))' "$1"; }
needs() { ipc acme.needs invoke "$1" "${2:-}"; }
# `centred` when the notice's one surface sits in the middle of the focused
# monitor, to within a pixel; else the two rectangles.
notice_centred() {
  local layers
  layers="$(layers_of vgs:notice)" || return 1
  hypr -j monitors | python3 -c '
import json, sys
ls = json.loads(sys.argv[1])
m = [m for m in json.load(sys.stdin) if m["focused"]]
if len(ls) != 1 or len(m) != 1:
    print("layers=%d focused=%d" % (len(ls), len(m))); sys.exit()
x, y, w, h = ls[0]
m = m[0]
mw, mh = m["width"] / m["scale"], m["height"] / m["scale"]
ok = abs(x + w / 2 - (m["x"] + mw / 2)) <= 1 and abs(y + h / 2 - (m["y"] + mh / 2)) <= 1
print("centred" if ok else json.dumps([ls[0], [m["x"], m["y"], mw, mh]]))' "$layers"
}
install_words() {
  words --app-id=org.vgs.tui "--title=VGS · Install requirements" -- "$tui_self" present --presentation full \
    --record core/requirements-install --run RUN --record-dir "$rt_dir/vgs/tui" --app-id org.vgs.tui --window-title "VGS · Install requirements" -- "$core_vgsh" pkg run install "$@"
}
needs_rows='["vgs-smoke-needs (vgs-smoke-needs-pkg): The command the fixture runs", "vgs-smoke-extra (vgs-smoke-extra-git) optional: An extra the fixture can do without", "vgs-smoke-unmapped optional: A command no manager here provides"]'
all_needs='["vgs-smoke-needs", "vgs-smoke-extra", "vgs-smoke-unmapped"]'

expect "the Settings plugin is disabled for the notice rows" False plugin_enabled vgs.settings
expect "no notice shows at first" null notice_shown
expect "the notice host has no surface at first" 0 layer_count vgs:notice

# pluginInstalled: add lands the plugin disabled, the shell scans and then
# raises the notice for the commands the scan did not find.
add_out=""
if add_out="$("${shell_env[@]}" "$repo/bin/vgsh" plugin add "file://$needs_src" 2>>"$sandbox/ipc.log")" \
  && [[ $add_out == "ok added=acme.needs path=$home/.config/vgs/plugins/acme.needs config=unchanged"$'\n'"shell=rescan-started"$'\n'"requires vgs-smoke-needs (vgs-smoke-needs-pkg)"$'\n'"requires vgs-smoke-extra (vgs-smoke-extra-git) optional"$'\n'"requires vgs-smoke-unmapped optional"$'\n'"install: vgsh pkg run install vgs-smoke-needs-pkg"$'\n'"install: vgsh pkg run install --manager aur vgs-smoke-extra-git" ]]; then
  ok "vgsh plugin add installs the needs fixture and names its missing packages"
else
  fail "vgsh plugin add of the needs fixture: $add_out"
fi
expect_poll "pluginInstalled raises the notice for every missing command" "[\"acme.needs\", $all_needs, [\"vgs-smoke-needs\"], false]" notice_shown
expect_poll "the notice host maps one surface" 1 layer_count vgs:notice
geometry expect "the notice is centred on the focused monitor" centred notice_centred
expect_poll "the notice holds the keyboard" true ipc smoke noticeFocused
expect "the notice names the plugin and the count" '"Needs needs 3 commands"' drawn title
expect "each missing command is drawn with this system's package" "$needs_rows" drawn rows
expect "an installable notice offers Install and Not now" '["Install", "Not now"]' drawn actions
expect "the plugin landed disabled" False plugin_enabled acme.needs

# Escape answers Not now: the notice goes and the plugin's own offers rest.
type_keys -k Escape || fail "sending Escape failed"
expect_poll "Escape closes the notice" null notice_shown
expect_poll "the closed notice leaves no surface" 0 layer_count vgs:notice
expect "the plugin's offers rest after Not now" '["acme.needs"]' notice_resting

# setPluginEnabled: enabling the plugin raises the notice again, whatever
# the rest, since the user asked.
expect "enabling the needs fixture is allowed" ok ipc shell setPluginEnabled acme.needs true
expect_poll "enabling a plugin that misses a command raises the notice" "[\"acme.needs\", $all_needs, [\"vgs-smoke-needs\"], false]" notice_shown
expect_poll "the needs fixture's service is built" True record_exists acme.needs

# The requirements capability: an offer merges into the plugin's held
# notice, and while the notice is gone and the plugin rests, it is refused.
expect "an offer while the notice shows merges into it" ok needs offer "vgs-smoke-extra"
expect "an offer of a present command is satisfied" satisfied needs offer "sh"
expect "an offer of a command the manifest does not declare is refused" "refused: requirement=pacman reason=undeclared" needs offer "vgs-smoke-needs|pacman"
expect "an offer that is not a list is refused" "refused: requirements=malformed" needs offer-json '"vgs-smoke-needs"'
expect "the merged notice is still the one notice" "[\"acme.needs\", $all_needs, [\"vgs-smoke-needs\", \"vgs-smoke-extra\"], false]" notice_shown
expect_poll "the notice holds the keyboard again" true ipc smoke noticeFocused
type_keys -k Escape || fail "sending Escape failed"
expect_poll "Escape closes the enabled notice" null notice_shown
resting_offer() { needs offer vgs-smoke-needs | sed -E 's/retry-ms=[0-9]+$/retry-ms=N/'; }
expect "an offer while the plugin rests is refused" "refused: requirements=acme.needs reason=resting retry-ms=N" resting_offer
expect "a refused offer raises no notice" 0 layer_count vgs:notice

# Install: the primary's package through the core's TUI. The stand-in
# terminal runs `true`, so the command is still missing after the rescan
# the run's end starts, and the notice stays; once the command is on the
# shell's PATH, the next install's rescan finds it and closes the notice.
expect "enabling the enabled fixture raises the notice again" ok ipc shell setPluginEnabled acme.needs true
expect_poll "the notice is back" "[\"acme.needs\", $all_needs, [\"vgs-smoke-needs\"], false]" notice_shown
expect_poll "the notice holds the keyboard for Install" true ipc smoke noticeFocused
expect "no install ran before the rows" idle key_idle core/requirements-install
forget_record
type_keys -k Return || fail "sending Return failed"
expect_poll "Install hands the terminal vgsh pkg run install with the primary's package" "$(install_words vgs-smoke-needs-pkg)" recorded
expect_poll "the install run ends" idle key_idle core/requirements-install
expect_poll "the rescan after an install that left the command missing keeps the notice" "[\"acme.needs\", $all_needs, [\"vgs-smoke-needs\"], false]" notice_shown
expect "the notice still offers Install" '["Install", "Not now"]' drawn actions
printf '#!/bin/sh\nexit 0\n' >"$shim/vgs-smoke-needs"; chmod 755 "$shim/vgs-smoke-needs"
expect_poll "the notice holds the keyboard after the install" true ipc smoke noticeFocused
forget_record
type_keys -k Return || fail "sending Return failed"
expect_poll "the second Install reaches the terminal" "$(install_words vgs-smoke-needs-pkg)" recorded
expect_poll "the rescan after the install finds the command and closes the notice" null notice_shown
expect_poll "the satisfied notice leaves no surface" 0 layer_count vgs:notice
rm -f -- "$shim/vgs-smoke-needs"
expect "a rescan after the command goes starts" ok ipc shell rescanPlugins
needs_state() { ipc shell listPlugins | python3 -c 'import json,sys; print(json.dumps([r["state"] for p in json.load(sys.stdin)["plugins"] if p["id"]=="acme.needs" for r in p["requirements"]][0]))'; }
expect_poll "the removed command is missing again" '"missing"' needs_state

# A detection that fails: the notice lists the commands with no package
# and offers Close alone.
pkg_stub ""
expected_errors+=('notices: detect=failed exit=70 status=0 vgsh: refused: stub=vgsh-pkg')
expect "enabling the fixture while detection fails raises the notice" ok ipc shell setPluginEnabled acme.needs true
expect_poll "the notice shows with detection failed" 1 layer_count vgs:notice
expect_log "the failed detection is logged" 1 'notices: detect=failed exit=70 status=0 vgsh: refused: stub=vgsh-pkg'
expect "a notice without managers draws the commands alone" '["vgs-smoke-needs: The command the fixture runs", "vgs-smoke-extra optional: An extra the fixture can do without", "vgs-smoke-unmapped optional: A command no manager here provides"]' drawn rows
expect "a notice without an install offers Close alone" '["Close"]' drawn actions
expect "the message says detection failed" '"VGS could not detect this system'"'"'s package manager. Install these commands by hand."' drawn message
expect_poll "the notice without an install holds the keyboard" true ipc smoke noticeFocused
type_keys -k Escape || fail "sending Escape failed"
expect_poll "Escape closes the notice without an install" 0 layer_count vgs:notice

cp -- "$pkg_real" "$repo/bin/vgsh-pkg.next" && mv -T -- "$repo/bin/vgsh-pkg.next" "$repo/bin/vgsh-pkg"
expect "disabling the needs fixture is allowed" ok ipc shell setPluginEnabled acme.needs false
remove_out() { local out; out="$("${shell_env[@]}" "$repo/bin/vgsh" plugin remove acme.needs 2>>"$sandbox/ipc.log")" || return 1; printf '%s\n' "${out%%$'\n'*}"; }
expect "the needs fixture is removed" "ok removed=acme.needs" remove_out
expect_poll "the removed fixture leaves the list" False plugin_known acme.needs
