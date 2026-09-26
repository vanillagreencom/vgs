# Capabilities, each driven through the fixture's own IPC target and read
# back from the fixture, the core's lending record and the compositor or bus
# the capability reaches.
set -euo pipefail
lent() { ipc shell lent | python3 -c 'import json,sys; d=json.load(sys.stdin); v=d
for k in sys.argv[1].split("."): v=v.get(k) if isinstance(v, dict) else None
print(json.dumps(v))' "$1"; }
# qs ipc reads a bracketed argument as a list, so no argument here is JSON
# with brackets: `set` takes key=value with a JSON value, `dispatch` a
# dispatcher and its arguments separated by spaces.
probe() { ipc acme.probe invoke "$1" "${2:-}"; }
# The fixture holds every capability and the bare fixture none; another
# plugin may hold a shared capability beside the fixture.
lent_holds() { ipc shell lent | python3 -c 'import json,sys; h=json.load(sys.stdin)["holders"].get(sys.argv[1],[]); print("acme.probe" in h and "acme.bare" not in h)' "$1"; }
for cap in compositor configure ipc lock notifications polkit run screens shortcut; do
  expect "the $cap capability is lent to the fixture and not the bare plugin" True lent_holds "$cap"
done

expect "the fixture's shortcut is registered under its id" '["acme.probe:ping"]' lent shortcuts
count_lines() { python3 -c 'import sys; print(sum(1 for line in sys.stdin if sys.argv[1] in line))' "$1"; }
hypr_shortcuts() { hypr globalshortcuts | count_lines 'acme.probe:ping'; }
expect_poll "the compositor lists the fixture's shortcut" 1 hypr_shortcuts
presses_before="$(read_service presses)"
expect "the compositor triggers the fixture's shortcut" ok hypr dispatch 'hl.dsp.global("acme.probe:ping")'
expect_poll "the fixture's shortcut handler ran" "$((presses_before + 1))" read_service presses
expect "a second shortcut with the same name is refused" '"refused: shortcut=acme.probe:ping held"' read_service duplicateShortcut

ipc_targets() { "${shell_env[@]}" qs ipc --pid "$shell_pid" show 2>>"$sandbox/ipc.log" | count_lines 'target acme.probe'; }
expect "qs lists the fixture's IPC target" 1 ipc_targets
expect "the fixture answers on its IPC target" hello probe echo hello
expect "a second IPC handler with the same name is refused" '"refused: ipc=acme.probe:echo held"' read_service duplicateIpc

expect "configure writes a declared setting" ok probe set 'label="via-configure"'
expect_poll "the running service received the setting it wrote" '"via-configure"' read_service label
expect "configure refuses a value of the wrong type" "refused: setting=label want=string" probe set 'label=3'
expect "configure refuses an undeclared setting" "refused: setting=tags undeclared" probe set 'tags="x"'

# A widget placed twice writes only the layout entry it reads.
right_entries() {
  python3 - "$home/.config/vgs/shell.json" "$1" <<'PY'
import json, os, sys
p, action = sys.argv[1], sys.argv[2]
d = json.load(open(p))
right = d["bar"]["layout"]["right"]
if action == "add":
    right.append({"id": "acme.probe", "label": "second"})
elif action == "drop":
    d["bar"]["layout"]["right"] = [e for e in right if not (e["id"] == "acme.probe" and e.get("label") == "second")]
else:
    print(json.dumps([e.get("label") for e in right if e["id"] == "acme.probe"]))
    sys.exit(0)
json.dump(d, open(p + ".tmp", "w"), indent=2)
os.replace(p + ".tmp", p)
PY
}
probe_widgets() { ipc shell built | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for r in d[sys.argv[1]] if r["id"]=="acme.probe"))' "$(bar_key)"; }
right_entries add
expect_poll "the fixture widget is placed twice" 2 probe_widgets
expect "a widget's configure writes only its own layout entry" ok ipc smoke invokeInstance "$(bar_key)" acme.probe setLabel only-first
labels_now() { right_entries show; }
expect_poll "the other entry keeps its setting" '["only-first", "second"]' labels_now
right_entries drop
expect_poll "the second placement is gone" 1 probe_widgets

expect "run starts a detached process" ok probe touch "$sandbox/touched-by-run"
touched() { [[ -f $sandbox/touched-by-run ]] && echo yes || echo no; }
expect_poll "the detached process ran" yes touched

bus_owner() { "${shell_env[@]}" gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner "$1" 2>>"$sandbox/ipc.log"; }
expect_poll "the core's notification server owns the bus name" "(true,)" bus_owner org.freedesktop.Notifications
notify() { "${shell_env[@]}" gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.Notify smoke 0 '' probe-summary probe-body '[]' '{}' 5000 >/dev/null 2>>"$sandbox/ipc.log" && echo sent; }
expect "a client sends a notification" sent notify
expect_poll "the fixture's subscriber received it" '"probe-summary"' read_service lastSummary

expect "the polkit agent exists while the fixture holds it" true lent polkitAgent
expect "the fixture reads the lent polkit agent" true read_service hasAgent
expect "the agent reports no registration on a bus without polkitd" false read_service agentRegistered
expect "the lending record reports the registration" false lent polkitRegistered

expect "the fixture locks the session" ok probe lock
expect_poll "the compositor confirms the lock" true read_service lockSecure
# A rebuild while locked keeps the session locked, and the rebuilt holder
# hands its screen over again. Change the holder's own source revision.
python3 - "$home/.config/vgs/plugins/acme.probe/manifest.json" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
d["version"] = "0.1.1"
json.dump(d, open(p + ".tmp", "w"))
os.replace(p + ".tmp", p)
PY
lock_content() { lent lock.content; }
if before="$(builds)"; then
  expect "a rescan while locked answers ok" ok ipc shell rescanPlugins
  rebuilt() { local now; now="$(builds)" && [[ $now -gt $before ]] && echo rebuilt || echo same; }
  expect_poll "the changed manifest rebuilt the holder" rebuilt rebuilt
  expect "only the holder service and its widgets rebuilt" "$((before + monitors + 1))" builds
  expect "the replacement service starts with no shortcut presses" 0 read_service presses
  expect_poll "the rebuilt holder handed its screen over again" true lock_content
  expect "the session stayed locked through the rebuild" true read_service lockSecure
  expect "the rebuilt fixture answers on its IPC target" hello probe echo hello
  presses_before="$(read_service presses)"
  expect "the compositor triggers the rebuilt fixture's shortcut" ok hypr dispatch 'hl.dsp.global("acme.probe:ping")'
  expect_poll "the rebuilt fixture's shortcut handler ran" "$((presses_before + 1))" read_service presses
else
  fail "buildCount unreadable before the lock rebuild rows"
fi
expect "the fixture unlocks the session" ok probe unlock
expect_poll "the compositor released the lock" false read_service lockSecure

expect "the fixture service sees every screen" "$monitors" read_service screenCount
expect "a service draws on no screen" true read_service noCurrentScreen
expect "the fixture widget draws on its bar's screen" "\"$(bar_key | sed 's/^bar://')\"" read_widget currentScreen

special_ws() { hypr -j monitors | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["specialWorkspace"]["name"])'; }
expect "the fixture toggles a special workspace" ok probe dispatch 'toggleSpecialWorkspace probe'
expect_poll "the compositor shows the special workspace" "special:probe" special_ws
expect_poll "the fixture closes the special workspace again" ok probe dispatch 'toggleSpecialWorkspace probe'
expect_poll "the compositor hides the special workspace" "" special_ws
expect "the fixture focuses a workspace" ok probe dispatch 'focusWorkspace 2'
expect_poll "the compositor moved to that workspace" 2 active_ws
expect_poll "the fixture focuses the first workspace again" ok probe dispatch 'focusWorkspace 1'
expect_poll "the compositor moved back" 1 active_ws
