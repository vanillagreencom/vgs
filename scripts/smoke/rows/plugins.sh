# A fixture plugin in the sandbox user directory: kind service plus a bar
# widget, naming every capability. Proves user-directory discovery, the
# service host, that each instance receives exactly the capabilities its
# manifest names, that a settings change reaches a running instance without
# a rebuild, and that every capability delivers its object and releases it
# on disable. The service registers through its capabilities once and
# answers IPC calls that drive the rest. The rows read the fixture's own
# properties back through readInstance, never the build records.
set -euo pipefail
fixture="$sandbox/src/acme.probe"
mkdir -p "$fixture"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.probe/." "$fixture/"
# A second user plugin naming no capability, beside the fixture.
bare="$home/.config/vgs/plugins/acme.bare"
mkdir -p "$bare"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.bare/." "$bare/"
# The fixture reaches the user directory the way a user's plugin does:
# committed to a repository and installed with `vgsh plugin add`.
fixture_git() { "${sandbox_env[@]}" git -C "$fixture" -c user.name=smoke -c user.email=smoke@invalid "$@" >>"$sandbox/git.log" 2>&1; }
if fixture_git init -q && fixture_git add -A && fixture_git commit -q -m fixture; then ok "fixture committed to a local repository"; else fail "fixture repository: $(tail -n 3 "$sandbox/git.log")"; fi
add_out=""
if add_out="$("${shell_env[@]}" "$repo/bin/vgsh" plugin add "file://$fixture" 2>>"$sandbox/ipc.log")" \
  && [[ $add_out == $'ok added=acme.probe path='"$home/.config/vgs/plugins/acme.probe"$' config=unchanged\nshell=rescan-started' ]]; then
  ok "vgsh plugin add installs the fixture and rescans the shell"
else
  fail "vgsh plugin add: $add_out"
fi
expect_poll "user-directory plugin discovered and disabled until enabled" False plugin_enabled acme.probe
expect "enabling the fixture is allowed" ok ipc shell setPluginEnabled acme.probe true
expect "enabling the bare fixture is allowed" ok ipc shell setPluginEnabled acme.bare true
service_built() { ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any(r["id"]=="acme.probe" and r["kind"]=="service" for r in d.get("service",[])))'; }
read_widget() { ipc smoke readInstance "$(bar_key)" acme.probe "$1"; }
read_service() { ipc smoke readInstance service acme.probe "$1"; }
read_clock() { ipc smoke readInstance "$(bar_key)" vgs.bar/center-clock "$1"; }
read_tick() { ipc smoke readInstance "$(bar_key)" acme.tick "$1"; }
got=""
for _ in $(seq 1 25); do if got="$(service_built)" && [[ $got == True ]]; then break; fi; sleep 0.2; done
if [[ $got == True ]]; then ok "the service host built the fixture service"; else fail "service host: built=$got"; fi
expect_widgets "the fixture widget joined the right section" '["acme.tick","acme.probe"]'
expect "the fixture widget can call its compositor capability" true read_widget hasCompositor
expect "the fixture widget's settings array stayed an array" true read_widget tagsAreArray
all_caps='"compositor,configure,ipc,lock,manifest,notifications,polkit,run,screens,settings,shortcut,theme,toasts"'
expect "the fixture widget's shell holds exactly what it named" "$all_caps" read_widget shellKeys
expect "the fixture service's shell holds exactly what it named" "$all_caps" read_service shellKeys
expect_poll "a plugin naming no capability receives none" '"manifest,settings"' ipc smoke readInstance service acme.bare shellKeys
expect "the fixture service reads the manifest default" '"probe"' read_service label
expect "a placed widget reads its layout entry" '"ddd d MMM  HH:mm"' read_tick format
expect "the built-in clock reads the bar's clock format" '"ddd d MMM  HH:mm"' read_clock format

# The built-in receives the bar's capability, independently of fixture grants.
expect "the built-in workspaces receive a callable compositor action" true ipc smoke hasWorkspaceAction "$(bar_key)" vgs.bar/left-workspaces
active_ws() { hypr -j activeworkspace | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }

# A settings change reaches the running instance and builds nothing: the
# service's plugins[] row, then the clock's layout entry.
if before="$(builds)"; then
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["plugins"] = [e for e in d.get("plugins", []) if e["id"] != "acme.probe"] + [{"id": "acme.probe", "label": "changed-service-setting"}]
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
  expect_poll "the running service received its changed setting" '"changed-service-setting"' read_service label
  expect "the fixture widget keeps the manifest default its entry does not override" '"probe"' read_widget label
  expect "a service settings change rebuilds nothing" "$before" builds
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
center = d["bar"]["layout"]["center"]
[e for e in center if e["id"] == "acme.tick"][0]["format"] = "HH:mm:ss"
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
  expect_poll "the running widget received its changed layout entry" '"HH:mm:ss"' read_tick format
  expect "a widget settings change rebuilds nothing" "$before" builds
  python3 - "$home/.config/vgs/shell.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["plugins"] = [e for e in d.get("plugins", []) if e["id"] != "vgs.bar"] + [{"id": "vgs.bar", "clockFormat": "HH:mm:ss"}]
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
  expect_poll "the built-in clock received the bar's changed setting" '"HH:mm:ss"' read_clock format
  # The shared clock ticks seconds only while a format shows them: three
  # readings across 2.2 s change at least twice at second precision.
  clock_changes=0; clock_last=""
  for _ in 1 2 3; do
    if clock_now="$(ipc smoke textOf "$(bar_key)" vgs.bar/center-clock)"; then
      [[ -n $clock_last && $clock_now != "$clock_last" ]] && clock_changes=$((clock_changes + 1))
      clock_last="$clock_now"
    fi
    sleep 1.1
  done
  if [[ $clock_changes -ge 2 ]]; then ok "the shared clock ticks seconds for a seconds format"; else fail "clock text changed $clock_changes times in 2.2 s"; fi
  expect "a bar settings change rebuilds nothing" "$before" builds
  expect_builtins "the built-ins stay registered across a bar settings change" '["vgs.bar/center-clock","vgs.bar/left-workspaces","vgs.bar/right-manager"]'
else
  fail "buildCount unreadable before the settings rows"
fi
