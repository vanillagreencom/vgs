# vgs.updates, the service that owns every update probe, its bar widget
# and its flyout. A copy of the plugin in the user directory, which wins
# the id over the shipped one, runs the shipped Service.qml, Widget.qml,
# Panel.qml and bin/check against the shipped bin/vgsh, with three changes
# only: one stub `tui` script beside the declared update TUIs, a run of
# which the row holds open until it opens a gate, listed with an entry so
# `openTui` reaches it; the declared `update`, `update-source` and `log`
# scripts replaced by ones that exit 0, since the pipeline itself would run
# package managers and its own controls are
# scripts/test-updates-pipeline.sh; and the vgsh it runs, a wrapper that
# confines each verb:
#
# - `pkg` runs the shipped `vgsh pkg` in an unprivileged mount namespace
#   whose /etc/os-release names the identity this row picks, `arch` or
#   `none`, with a PATH that holds the stand-ins under
#   scripts/smoke/fixtures/updates-bin and the few tools vgsh needs, so
#   bin/vgsh-pkg's own detection and parsers read stub output and no host
#   package manager runs;
# - every other verb runs the shipped vgsh with only the stand-in git ahead
#   of the shell's PATH: it answers for this checkout and the plugin copy
#   alone, so `self status` and `plugin outdated` reach no remote.
#
# Read back from the accepted status record: every source's count, one
# probe run per check however often it is read, a failing source named and
# kept, a list past the status ceiling cut with its count kept, a request
# during a check queued once, a TUI run's end starting one check, the
# pipeline listed in the launcher's Update group, and only
# the VGS rows where no manager is detected. The control is a bar widget
# that runs the check itself: on two bars it probes twice for one check.
#
# The widget and the flyout are read back from what they draw: the icon,
# its colour, the spinner and the badge for pending, checking, failed,
# stale and current values, `hideWhenCurrent` hiding the widget only while
# current, the tooltip's lines, the flyout's rows and a row's packages, the
# argv each button hands the terminal, and Refresh starting one check of
# the service. The pending, checking and failed values come from real
# checks; the stale and current ones are written through the service's own
# status provider, since the service marks a snapshot stale only after
# twice the interval, and a rebuild of the plugin publishes the real ones
# again, with no check of its own. Its control is a copy of the widget's
# judge that hides on a failed check, which the visibility readback reads
# hidden.
set -euo pipefail
updates_dir="$home/.config/vgs/plugins/vgs.updates"
updates_state="$home/.local/state/vgs/updates-smoke"
updates_fixtures="$repo/scripts/smoke/fixtures/updates-bin"
if ! command -v unshare >/dev/null 2>&1 || ! unshare -rm true 2>/dev/null; then
  printf 'qml-smoke: status=not-measured missing=unprivileged-mount-namespace\n'
  exit 77
fi
mkdir -p "$updates_dir" "$updates_state"
cp -R "$repo/shell/plugins/vgs.updates/." "$updates_dir/"
expected_errors+=('plugins: hidden by a higher-precedence plugin with the same id: vgs\.updates')

# The stand-in git, alone in its own directory.
mkdir -p "$updates_state/git-bin"
cp -- "$updates_fixtures/git" "$updates_state/git-bin/git"

# One directory per identity: its os-release and the PATH `vgsh pkg` gets.
# `arch` holds the stand-in managers; `none` holds no manager at all.
updates_identity() { # NAME OS_ID STAND_INS...
  local dir="$updates_state/identity-$1" tool
  mkdir -p "$dir/bin"
  printf 'ID=%s\n' "$2" >"$dir/os-release"
  for tool in bash env readlink dirname flock setsid timeout mkdir cat sleep seq; do ln -sf -- "$(command -v "$tool")" "$dir/bin/$tool"; done
  ln -sf -- "$node_bin" "$dir/bin/node"
  shift 2
  for tool; do cp -- "$updates_fixtures/$tool" "$dir/bin/$tool"; done
}
updates_identity arch arch pacman checkupdates paru flatpak mise
updates_identity none opensuse-tumbleweed
use_identity() { printf '%s\n' "$1" >"$updates_state/identity"; }
use_identity arch

# The wrapper the service copy runs as its vgsh. bin/check finds the core's
# library loader beside the vgsh it is given, so the loader is linked in.
updates_vgsh="$updates_state/vgsh-bin/vgsh"
mkdir -p "$updates_state/vgsh-bin/lib"
ln -sf -- "$repo/bin/lib/qml-library.js" "$updates_state/vgsh-bin/lib/qml-library.js"
cat >"$updates_vgsh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ \${1:-} == pkg ]]; then
  identity="$updates_state/identity-\$(<"$updates_state/identity")"
  exec unshare -rm "\$identity/bin/bash" -c 'mount --bind "\$1/os-release" /etc/os-release && export PATH="\$1/bin" && shift && exec "\$@"' \\
    bash "\$identity" "$repo/bin/vgsh" "\$@"
fi
exec env PATH="$updates_state/git-bin:\$PATH" UPDATES_SMOKE_CHECKOUTS="$repo:$updates_dir" "$repo/bin/vgsh" "\$@"
EOF
chmod 755 "$updates_vgsh"

# The copy's three changes, each checked to apply once.
python3 - "$updates_dir" "$updates_vgsh" <<'PY'
import json, pathlib, sys
plugin, vgsh = pathlib.Path(sys.argv[1]), sys.argv[2]
manifest = plugin / "manifest.json"
doc = json.loads(manifest.read_text())
assert "finish" not in doc["tui"], doc["tui"]
doc["tui"]["finish"] = {"script": "tui/finish.sh", "title": "Updates smoke", "size": "default", "presentation": "plain", "entry": {"label": "Updates smoke", "icon": "terminal", "group": "Smoke"}}
manifest.write_text(json.dumps(doc))
assert sorted(doc["tui"]) == ["finish", "log", "update", "update-source"], sorted(doc["tui"])
for name in ("update", "update-source", "log"):
    script = plugin / doc["tui"][name]["script"]
    assert script.is_file(), script
    script.write_text("#!/usr/bin/env bash\nexit 0\n")
service = plugin / "Service.qml"
lines = service.read_text().splitlines()
hits = [i for i, line in enumerate(lines) if line.startswith("    readonly property string vgshPath:")]
assert len(hits) == 1, hits
lines[hits[0]] = "    readonly property string vgshPath: " + json.dumps(vgsh)
service.write_text("\n".join(lines) + "\n")
PY
mkdir -p "$updates_dir/tui"
cat >"$updates_dir/tui/finish.sh" <<'TUI'
#!/usr/bin/env bash
# Runs until the row opens its gate.
gate="${XDG_STATE_HOME:?}/vgs/updates-smoke/tui-gate"
while [[ ! -e $gate ]]; do sleep 0.05; done
TUI
chmod 755 "$updates_dir/tui/finish.sh"

# A terminal stand-in that runs the presenter with no window;
# rows/agent-warden.sh writes harness.sh's recording one over it.
cat >"$shim/xdg-terminal-exec" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 && $1 != -- ]]; do shift; done
shift
presenter=()
while [[ $# -gt 0 && $1 != -- ]]; do presenter+=("$1"); shift; done
"${presenter[@]}" "$@" </dev/null >/dev/null 2>&1
EOF
chmod 755 "$shim/xdg-terminal-exec"

# The accepted status record, as every instance reads it.
updates_values() { ipc vgs.updates invoke status ''; }
updates_field() { updates_values | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get(sys.argv[1])))' "$1"; }
updates_sources() { updates_values | python3 -c 'import json,sys; print(json.dumps([[s["source"], s["count"], s["error"]] for s in json.load(sys.stdin).get("sources", [])]))'; }
updates_source_names() { updates_values | python3 -c 'import json,sys; print(json.dumps([s["source"] for s in json.load(sys.stdin).get("sources", [])]))'; }
updates_state_text() { updates_values | python3 -c 'import json,sys; print(json.load(sys.stdin).get("checkState", {}).get("text", ""))'; }
# Whether the check state names the failing system source.
updates_names_system_failure() { [[ $(updates_state_text) == "System: exit=1"* ]] && echo True || echo False; }
# Whether the failing system row stays listed, with no count, beside AUR's.
updates_keeps_failed_row() { updates_sources | python3 -c 'import json,sys; r=json.load(sys.stdin); print(any(s[0] == "pacman" and s[1] is None and s[2] for s in r) and ["aur", 1, None] in r)'; }
# SOURCE's [count, listed packages, more] in the accepted record.
updates_listed() { updates_values | python3 -c 'import json,sys; r=[s for s in json.load(sys.stdin).get("sources", []) if s["source"]==sys.argv[1]]; print(json.dumps([r[0]["count"], len(r[0]["packages"]), r[0]["more"]] if r else None))' "$1"; }
# SOURCE's [count, packages] in status.json on disk.
updates_cached() { python3 -c 'import json,sys; r=[s for s in json.load(open(sys.argv[1]))["sources"] if s["source"]==sys.argv[2]]; print(json.dumps([r[0]["count"], len(r[0]["packages"])] if r else None))' "$home/.local/state/vgs/updates/status.json" "$1"; }
updates_idle() { [[ $(updates_state_text) == Checking ]] && echo checking || echo idle; }
updates_status_rows() { settings_rows | python3 -c 'import json,sys; rows=[p for p in json.load(sys.stdin) if p["id"]=="vgs.updates"][0]["status"]; print(json.dumps([[r["key"], r["report"]] for r in rows]))'; }
updates_widget_section() { ipc shell listShellConfig | python3 -c 'import json,sys; l=json.load(sys.stdin)["bar"]["layout"]; print(([s for s in ("left","center","right") if any(e["id"]=="vgs.updates" for e in l.get(s,[]))] + ["none"])[0])'; }
updates_tui_running() { lent tui.runs | python3 -c 'import json,sys; r=(json.load(sys.stdin) or {}).get("vgs.updates/finish"); print(json.dumps(r is not None and r.get("running") is not None))'; }
# Runs of one stand-in, from the log every stand-in appends to.
runs_of() { python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); print(0 if not p.exists() else sum(1 for l in p.read_text().splitlines() if l.split(" ")[0] == sys.argv[2]))' "$updates_state/calls.log" "$1"; }
package_queries() { echo "$(runs_of checkupdates) $(runs_of paru) $(runs_of flatpak) $(runs_of mise)"; }
checks() { runs_of checkupdates; }
# STEADY once the check count stays at WANT for a second, else the count.
checks_settle_at() { # WANT
  local got
  got="$(checks)"
  if [[ $got != "$1" ]]; then echo "$got"; return; fi
  sleep 1
  got="$(checks)"
  if [[ $got == "$1" ]]; then echo STEADY; else echo "$got"; fi
}

# First check: no snapshot exists, so the service checks at start.
rm -rf -- "$home/.local/state/vgs/updates"
expect "rescan after adding the updates copy answers ok" ok ipc shell rescanPlugins
expect_poll "the updates copy is discovered" True plugin_known vgs.updates
# The first check runs `vgsh theme outdated`, which holds the theme lock
# shared, so it starts once the scan's theme follow has ended.
expect_poll "the scan's theme follow ends before the first check" idle theme_idle
expect "enabling the updates service is allowed" ok ipc shell setPluginEnabled vgs.updates true
expect_poll "the updates service is built" True record_exists vgs.updates
updates_tui_rows() { ipc shell listTuis | python3 -c 'import json,sys; print(json.dumps(sorted([r["key"], r["group"]] for r in json.load(sys.stdin) if r["plugin"] == "vgs.updates")))'; }
expect "the pipeline is listed in the Update group and the one-source TUI is not listed" '[["vgs.updates/finish", "Smoke"], ["vgs.updates/update", "Update"]]' updates_tui_rows
expect_poll "the first check publishes every source vgsh reports" \
  '[["pacman", 2, null], ["aur", 1, null], ["flatpak", 1, null], ["mise", 1, null], ["vgs", 1, null], ["plugins", 1, null], ["themes", 0, null]]' updates_sources
expect "pending sums every source" 7 updates_field pending
expect "the check state says updates wait" "Updates waiting" updates_state_text
expect "the first check ran each package query once" "1 1 1 1" package_queries
expect "status.json holds the same system rows" '[2, 2]' updates_cached pacman

# Reads are not checks.
for _ in 1 2 3; do updates_values >/dev/null; done
expect "three reads start no check" STEADY checks_settle_at 1
expect "the Settings window opens for the updates rows" ok ipc shell summon window vgs.settings '{}'
expect_poll "the Settings window is open for the updates rows" open settings_open
expect "the Settings window opens the updates page" ok ipc smoke invokeInstance window vgs.settings openPlugin vgs.updates
expect_poll "the Settings page reads the three status rows" '[["pending", "reported"], ["lastCheck", "reported"], ["checkState", "reported"]]' updates_status_rows
expect "the Settings page started no check" STEADY checks_settle_at 1
expect "the Settings window closes" ok ipc shell hide window vgs.settings

# A request during a check is queued once, not run beside it.
touch "$updates_state/slow-checkupdates"
expect "an on-demand check starts" started ipc vgs.updates invoke check ''
expect "a request during the check is queued" queued ipc vgs.updates invoke check ''
expect "a third request during the check joins the queued one" queued ipc vgs.updates invoke check ''
rm -f -- "$updates_state/slow-checkupdates"
expect_poll "the check and the one queued check both run" 3 checks
expect "no third check follows" STEADY checks_settle_at 3
expect_poll "the service is idle after the queued check" idle updates_idle

# A failing source is named and kept beside the others.
touch "$updates_state/fail-checkupdates"
expect "a check with a failing system source starts" started ipc vgs.updates invoke check ''
expect_poll "the check state names the failing source" True updates_names_system_failure
expect "the failing source stays listed with no count" True updates_keeps_failed_row
rm -f -- "$updates_state/fail-checkupdates"

# A list past the status ceiling: the record lists the first packages and
# counts the rest; status.json keeps every one.
touch "$updates_state/many-checkupdates"
expect "a check with 1400 system updates starts" started ipc vgs.updates invoke check ''
expect_poll "the record lists the first packages and counts the rest" '[1400, 12, 1388]' updates_listed pacman
expect "pending keeps the full count" 1405 updates_field pending
expect "status.json keeps every package" '[1400, 1400]' updates_cached pacman
rm -f -- "$updates_state/many-checkupdates"

# A TUI run's end starts one check; a running TUI starts none.
expect_poll "the TUI startup probe has answered" false lent tui.probing
if [[ "$(lent tui.launcher)" == '"missing"' ]]; then
  expect "a request on a host without a terminal refreshes the launcher" "refused: tui=vgs.updates/finish reason=launcher-missing" ipc shell openTui vgs.updates/finish
fi
expect_poll "the launcher state is present" '"present"' lent tui.launcher
expect_poll "the launcher refresh is idle" false lent tui.probing
rm -f -- "$updates_state/tui-gate"
before="$(checks)"
expect "opening the updates TUI answers ok" ok ipc shell openTui vgs.updates/finish
expect_poll "the updates TUI is running" true updates_tui_running
expect "a running TUI starts no check" STEADY checks_settle_at "$before"
touch "$updates_state/tui-gate"
expect_run_end "the updates TUI's run ends" vgs.updates/finish
expect_poll "the TUI's end starts a check" "$((before + 1))" checks
expect "the TUI's end starts exactly one check" STEADY checks_settle_at "$((before + 1))"
expect_poll "the service is idle after the TUI check" idle updates_idle

# ---- The bar widget and the flyout ------------------------------------------
# Enabling the plugin placed its widget in its default section. Each TUI a
# button opens is a stub that exits at once; its end starts one check of
# the service, so every button waits for its run to end and the service to
# go idle before the next.
terminal_stand_in
terminal_ready "updates widget"
widget_key="$(bar_key)"
expect "the updates widget is placed in its default section" right updates_widget_section
expect_poll "the updates widget is built on the bar" '"vgs.updates"' ipc smoke readInstance "$widget_key" vgs.updates moduleName
# The widget as it judges itself: [state, icon, tone, badge, badge tone].
widget_view() { ipc smoke readInstance "$widget_key" vgs.updates view | python3 -c 'import json,sys; v=json.load(sys.stdin); print(json.dumps([v["state"], v["icon"], v["tone"], v["badge"], v["badgeTone"]]))'; }
# The widget as drawn: [the icon it shows, or `spinner`, the tone its
# colour is, the badge it shows, or ""]. A colour is read as the theme
# writes it and matched against the three the widget draws with.
widget_drawn() {
  local colours accent warning calm icon spinning badge shown
  colours="$(ipc smoke itemColours "$widget_key" vgs.updates Button Icon)" && accent="$(ipc smoke themeValue color.accent)" \
    && warning="$(ipc smoke themeValue color.warning)" && calm="$(ipc smoke themeValue button.variant.ghost.foreground)" \
    && icon="$(ipc smoke readDescendant "$widget_key" vgs.updates Icon name)" && spinning="$(ipc smoke readDescendant "$widget_key" vgs.updates Spinner visible)" \
    && badge="$(ipc smoke readDescendant "$widget_key" vgs.updates Badge text)" && shown="$(ipc smoke readDescendant "$widget_key" vgs.updates Badge visible)" || return
  python3 -c '
import json, sys
colours, accent, warning, calm, icon, spinning, badge, shown = (json.loads(a) for a in sys.argv[1:])
portable = lambda c: "#" + c[3:] + c[1:3]
tones = {portable(accent): "accent", portable(warning): "warning", portable(calm): "calm"}
drawn = [c for button in colours for c in button]
if spinning:
    print(json.dumps(["spinner", None if not drawn else drawn, badge if shown else ""]))
else:
    print(json.dumps([icon, tones.get(drawn[0], drawn[0]) if len(drawn) == 1 else drawn, badge if shown else ""]))' \
    "$colours" "$accent" "$warning" "$calm" "$icon" "$spinning" "$badge" "$shown"
}
widget_visible() { ipc smoke readInstance "$widget_key" vgs.updates visible; }
# The tooltip's lines but the last, the check's time, which moves; and
# whether that last line names a time.
widget_tip() { ipc smoke readInstance "$widget_key" vgs.updates tooltip | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).split("\n")[:-1]))'; }
widget_tip_line() { widget_tip | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[int(sys.argv[1])]))' "$1"; }
widget_tip_last() { ipc smoke readInstance "$widget_key" vgs.updates tooltip | python3 -c 'import json,re,sys; print(bool(re.fullmatch(r"Checked \S.*", json.load(sys.stdin).split("\n")[-1])))'; }
# hideWhenCurrent in the widget's layout entry of the user file, written
# whole and moved into place.
widget_hide_when_current() { # true|false
  python3 -c '
import json, os, sys
path, want = sys.argv[1], sys.argv[2] == "true"
doc = json.load(open(path))
entries = [e for e in doc["bar"]["layout"]["right"] if e["id"] == "vgs.updates"]
assert len(entries) == 1, entries
entries[0]["hideWhenCurrent"] = want
open(path + ".next", "w").write(json.dumps(doc))
os.replace(path + ".next", path)' "$home/.config/vgs/shell.json" "$1"
}
widget_setting() { ipc smoke readInstance "$widget_key" vgs.updates settings | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("hideWhenCurrent")))'; }
flyout_rows() { ipc smoke itemTexts panel vgs.updates Disclosure | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin), ensure_ascii=False))'; }
flyout_row() { flyout_rows | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[int(sys.argv[1])], ensure_ascii=False))' "$1"; }
flyout_open() { [[ $(ipc smoke readInstance panel vgs.updates rows) != absent ]] && echo open || echo closed; }
# Open the flyout with a click on the widget, unless it is open: a TUI's
# window takes the focus, which closes the popup.
open_flyout() {
  [[ $(flyout_open) == open ]] && return 0
  click_centre "$widget_key" vgs.updates || fail "the click on the updates widget failed"
  expect_poll "the widget's click opens the flyout" open flyout_open
}
# The words after the presenter's `--`: the script's file name and its
# arguments.
launched() { recorded | python3 -c 'import json,os,sys; w=json.load(sys.stdin); a=w[len(w) - 1 - w[::-1].index("--") + 1:]; print(json.dumps([os.path.basename(a[0])] + a[1:]))'; }
# Click the flyout button reading TEXT, read the argv it launched, WANT,
# and wait for its run of KEY, and the check its end starts, to end.
press_and_launch() { # TEXT KEY WANT
  local before
  open_flyout
  forget_record
  before="$(checks)"
  click_item panel vgs.updates Button "$1" || fail "the click on the flyout's $1 failed"
  expect_poll "the flyout's $1 opens its TUI with its argv" "$3" launched
  expect_run_end "the flyout's $1 run ends" "$2"
  expect_poll "the $1 run's end starts one check" "$((before + 1))" checks
  expect_poll "the service is idle after the $1 run" idle updates_idle
}

# Pending, from the last real check.
expect_poll "a pending check draws the accent count" '["pending", "refresh-cw", "accent", "7", "accent"]' widget_view
expect "the widget draws the icon in the accent colour with the count" '["refresh-cw", "accent", "7"]' widget_drawn
expect "the tooltip lists every source's count" '["7 updates waiting", "System: 2", "AUR: 1", "Flatpak: 1", "mise: 1", "VGS: 1", "Plugins: 1", "Themes: 0"]' widget_tip
expect "the tooltip ends with the check's time" True widget_tip_last

# The flyout: one row per source with its count and its own Update when it
# has updates; a click on a row lists its packages.
open_flyout
expect_poll "the flyout draws one row per source" \
  '[["System", "2 updates", "2", "Update"], ["AUR", "1 update", "1", "Update"], ["Flatpak", "1 update", "1", "Update"], ["mise", "1 update", "1", "Update"], ["VGS", "1 update", "1", "Update"], ["Plugins", "1 update", "1", "Update"], ["Themes", "Up to date", "0"]]' flyout_rows
click_item panel vgs.updates ListItem System || fail "the click on the flyout's System row failed"
expect_poll "a click on a row lists its packages" '["System", "2 updates", "2", "Update", "coreutils 9.11-2 → 9.12-1", "linux 6.1 → 6.2"]' flyout_row 0

# Each button's argv, as the terminal stand-in records it. The first
# Update is the System row's.
press_and_launch Update vgs.updates/update-source '["update-source.sh", "pacman"]'
press_and_launch "Update everything" vgs.updates/update '["update.sh"]'
press_and_launch "Open last log" vgs.updates/log '["log.sh"]'
before="$(checks)"
forget_record
expect "the widget's middle-click function opens the update TUI" ok ipc smoke invokeInstance "$widget_key" vgs.updates updateAll ''
expect_poll "the widget opens the update TUI with no argument" '["update.sh"]' launched
expect_run_end "the widget's update run ends" vgs.updates/update
expect_poll "the widget's run's end starts one check" "$((before + 1))" checks
expect_poll "the service is idle after the widget's run" idle updates_idle
open_flyout
before="$(checks)"
click_item panel vgs.updates Button Refresh || fail "the click on the flyout's Refresh failed"
expect_poll "Refresh starts the service's check" "$((before + 1))" checks
expect "Refresh starts one check" STEADY checks_settle_at "$((before + 1))"
expect_poll "the service is idle after Refresh" idle updates_idle
expect "the flyout closes" ok ipc shell hide panel vgs.updates

# Checking: the spinner stands in for the icon, the count stays.
touch "$updates_state/slow-checkupdates"
expect "a held check starts" started ipc vgs.updates invoke check ''
expect_poll "a running check spins" '["checking", "refresh-cw", "calm", "7", "accent"]' widget_view
expect "the widget draws the spinner with the count" '["spinner", null, "7"]' widget_drawn
rm -f -- "$updates_state/slow-checkupdates"
expect_poll "the service is idle after the held check" idle updates_idle

# Failed: a failing source draws the warning tone, and hideWhenCurrent
# does not hide it.
touch "$updates_state/fail-checkupdates"
expect "a check with a failing system source starts for the widget" started ipc vgs.updates invoke check ''
expect_poll "a failed source draws the warning" '["attention", "triangle-alert", "warning", "5", "warning"]' widget_view
expect "the widget draws the warning icon with the count" '["triangle-alert", "warning", "5"]' widget_drawn
expect "the tooltip names the failed source" '"System: check failed"' widget_tip_line 1
widget_hide_when_current true
expect_poll "the widget reads hideWhenCurrent" true widget_setting
expect "hideWhenCurrent leaves a failed check shown" true widget_visible

# Control: a copy of the widget's judge that hides on a failed check reads
# hidden, so the readback above catches a widget that hides it.
updates_logic="$updates_dir/UpdatesLogic.js"
cp -- "$updates_logic" "$updates_state/UpdatesLogic.js.shipped"
python3 -c '
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = "hidden: hideWhenCurrent === true && state === \"current\""
assert text.count(needle) == 1, text.count(needle)
path.write_text(text.replace(needle, "hidden: hideWhenCurrent === true && state !== \"checking\""))' "$updates_logic"
before="$(checks)"
expect "rescan after planting the hiding widget answers ok" ok ipc shell rescanPlugins
expect_poll "the hiding widget reads the failed check" '["attention", "triangle-alert", "warning", "5", "warning"]' widget_view
expect_poll "the control: a widget that hides on a failed check reads hidden" false widget_visible
cp -- "$updates_state/UpdatesLogic.js.shipped" "$updates_logic"
expect "rescan after restoring the widget answers ok" ok ipc shell rescanPlugins
expect_poll "the restored widget shows the failed check" true widget_visible
expect_poll "the restored service publishes the failed check" '["attention", "triangle-alert", "warning", "5", "warning"]' widget_view
# A rebuilt service publishes its cache and starts no check: not for the
# TUI runs an earlier instance saw end, and not while its cache read has not
# answered. The controls of both are scripts/test-updates-logic.js's.
expect "a rebuilt service starts no check" STEADY checks_settle_at "$before"
rm -f -- "$updates_state/fail-checkupdates"

# Stale and current, written through the service's own provider.
expect "the probe keeps the updates service's status provider" held ipc smoke holdStatus service vgs.updates
expect "a stale check is written" ok ipc smoke heldStatusSet checkState '{"tone":"warning","text":"Check stale"}'
expect "nothing waiting is written" ok ipc smoke heldStatusSet pending 0
expect_poll "a stale check draws the warning" '["attention", "triangle-alert", "warning", "", "warning"]' widget_view
expect "the widget draws the warning icon with no count" '["triangle-alert", "warning", ""]' widget_drawn
expect "hideWhenCurrent leaves a stale check shown" true widget_visible
expect "a current check is written" ok ipc smoke heldStatusSet checkState '{"tone":"ok","text":"Up to date"}'
expect_poll "hideWhenCurrent hides a current widget" false widget_visible
expect "a current widget judges itself calm" '["current", "refresh-cw", "calm", "", "neutral"]' widget_view
widget_hide_when_current false
expect_poll "the widget reads hideWhenCurrent off" false widget_setting
expect_poll "a current widget shows with hideWhenCurrent off" true widget_visible
expect "the widget draws the calm icon with no count" '["refresh-cw", "calm", ""]' widget_drawn

# A rebuild publishes the cached snapshot, the failed check's, again, and a
# check brings the rows below back to the stand-ins' answers.
expect "disabling the updates plugin drops the written values" ok ipc shell setPluginEnabled vgs.updates false
expect "enabling the updates plugin again is allowed" ok ipc shell setPluginEnabled vgs.updates true
expect_poll "the rebuilt service publishes the cached failed check" '["attention", "triangle-alert", "warning", "5", "warning"]' widget_view
expect "a check after the rebuild starts" started ipc vgs.updates invoke check ''
expect_poll "the check publishes the pending count again" '["pending", "refresh-cw", "accent", "7", "accent"]' widget_view
expect_poll "the service is idle after the rebuild's check" idle updates_idle

# Control: a copy that checks per widget probes once per bar.
updates_control="$home/.config/vgs/plugins/acme.updates-control"
mkdir -p "$updates_control"
cat >"$updates_control/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.updates-control", "name": "Updates control", "version": "0.1.0", "author": "acme", "description": "A copy of the updates check that every widget runs itself", "kinds": ["bar-widget"], "entryPoints": { "bar-widget": "Widget.qml" }, "defaultSection": "right" }
JSON
control_command="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$updates_dir/bin/check" --vgsh "$updates_vgsh")"
cat >"$updates_control/Widget.qml" <<EOF
import QtQuick
import qs.Ui
import Quickshell.Io
BarWidget {
    property var shell: null
    Process {
        running: true
        command: $control_command
    }
}
EOF
expect "rescan after adding the per-widget control answers ok" ok ipc shell rescanPlugins
expect_poll "the per-widget control is discovered" True plugin_known acme.updates-control
expect_poll "the scan's theme follow ends before the per-widget control checks" idle theme_idle
control_output=SMOKE-UPDATES-CONTROL
expect "the nested compositor adds a monitor for the control" ok hypr output create headless "$control_output"
expect_poll "the control monitor gets a bar" "$((monitors + 1))" bar_count
before="$(checks)"
expect "enabling the per-widget control is allowed" ok ipc shell setPluginEnabled acme.updates-control true
control_widgets() { ipc shell built | python3 -c 'import json,sys; print(sum(1 for rows in json.load(sys.stdin).values() for r in rows if r["id"] == "acme.updates-control"))'; }
expect_poll "the control is built on every bar" "$((monitors + 1))" control_widgets
expect_poll "the control probes once per widget, not once per check" "$((before + monitors + 1))" checks
expect "disabling the per-widget control is allowed" ok ipc shell setPluginEnabled acme.updates-control false
expect "the nested compositor removes the control monitor" ok hypr output remove "$control_output"
expect_poll "the control monitor's bar is gone" "$monitors" bar_count

# No manager detected: only the VGS rows remain.
use_identity none
before="$(checks)"
expect "a check with no package manager starts" started ipc vgs.updates invoke check ''
expect_poll "with no manager detected only the VGS rows remain" '["vgs", "plugins", "themes"]' updates_source_names
expect "no package query ran" STEADY checks_settle_at "$before"

# Leave the later rows the shipped plugin, disabled.
expect "disabling the updates service is allowed" ok ipc shell setPluginEnabled vgs.updates false
rm -rf -- "$updates_dir" "$updates_control"
expect "rescan after removing the updates copies answers ok" ok ipc shell rescanPlugins
expect_poll "the updates control is gone" False plugin_known acme.updates-control
