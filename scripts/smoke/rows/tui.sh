# Floating TUIs through the `tui` capability and the core's `listTuis` and
# `openTui`, read back from a stand-in xdg-terminal-exec in the shell's own
# PATH directory. The real bin/vgsh-tui launches it; it records the argv it
# was handed, maps the harness's toplevel helper with the app-id and title
# it was handed as the window, and runs the real presenter with no terminal
# behind it, so the presenter writes its exit records and no terminal
# starts. The fixture acme.tui declares one listed script and one gated
# one, which waits for a file the row creates, polled every 0.05 s for at
# most 20 s, and the Update entry scripts/smoke/rows/launcher.sh opens. Rows: the published list, the app-id of the script's size, the
# snapshot path it runs from and its arguments, the core's own sudo grant
# and package install picker opened by key as the core's bin/vgsh, each
# refusal, a launcher that finds no terminal and the synchronous
# `launcher-missing` answer that follows until a probe finds one again, the
# launchers the core holds, a run's `done` and state from its exit records,
# a second run of a live key refused busy with its window focused, a
# destroyed instance's `done` dropped while its run ends, a presenter copy
# that writes no ended record and the reap that ends its run, and a
# disabled plugin's list and hold gone.
set -euo pipefail
tui_dir="$home/.config/vgs/plugins/acme.tui"
mkdir -p "$tui_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.tui/." "$tui_dir/"
tui_record="$sandbox/tui-argv"
# The argv is written whole and moved into place, so a row never reads half
# a record. The window lives as long as the presenter. The presenter runs a
# fixture script as it is and any other command as `true`, so no core
# command, such as the sudo grant, runs in the sandbox.
cat >"$shim/xdg-terminal-exec" <<EOF
#!/usr/bin/env bash
: >"$tui_record.next"
for a; do printf '%s\n' "\$a" >>"$tui_record.next"; done
mv -f -- "$tui_record.next" "$tui_record"
app_id="" title=""
while [[ \$# -gt 0 && \$1 != -- ]]; do
  case "\$1" in
    --app-id=*) app_id="\${1#*=}" ;;
    --title=*) title="\${1#*=}" ;;
  esac
  shift
done
shift
presenter=() fixture=no
while [[ \$# -gt 0 && \$1 != -- ]]; do
  [[ \$1 == --plugin ]] && fixture=yes
  presenter+=("\$1")
  shift
done
[[ \$fixture == yes ]] || set -- -- true
"$sandbox/toplevel" "\$app_id" "\$title" >/dev/null 2>&1 &
window=\$!
"\${presenter[@]}" "\$@" </dev/null >/dev/null 2>&1
kill "\$window" 2>/dev/null
wait "\$window"
EOF
chmod 755 "$shim/xdg-terminal-exec"
tui_self="$(readlink -f -- "$repo/bin/vgsh-tui")"
tui() { ipc acme.tui invoke "$1" "${2:-}"; }
# The record, with the run id the core chose as RUN, and a list of words, as
# one JSON line each.
recorded() { python3 -c '
import json, os, sys
if not os.path.exists(sys.argv[1]):
    print("absent"); sys.exit()
words = open(sys.argv[1]).read().split("\n")[:-1]
for i in range(len(words) - 1):
    if words[i] == "--run": words[i + 1] = "RUN"
print(json.dumps(words))' "$tui_record"; }
# Whether acme.tui holds the tui capability; the probe fixture may hold it too.
tui_held() { lent holders.tui | python3 -c 'import json,sys; print("acme.tui" in (json.load(sys.stdin) or []))'; }
words() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }
respaced() { "$@" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
forget_record() { rm -f -- "$sandbox/tui-argv"; }

expect "rescan after adding the tui fixture answers ok" ok ipc shell rescanPlugins
expect_poll "the tui fixture is discovered" True plugin_known acme.tui
expect "enabling the tui fixture is allowed" ok ipc shell setPluginEnabled acme.tui true
expect_poll "the tui fixture's service is built" True record_exists acme.tui
expect_poll "the fixture holds the tui capability" True tui_held

core_listed='{"key": "core/pkg-install", "plugin": "core", "name": "pkg-install", "title": "Install packages", "label": "Install packages", "icon": "package-plus", "group": "Packages"}, {"key": "core/pkg-remove", "plugin": "core", "name": "pkg-remove", "title": "Remove packages", "label": "Remove packages", "icon": "package-minus", "group": "Packages"}, {"key": "core/sudo-grant", "plugin": "core", "name": "sudo-grant", "title": "Passwordless sudo", "label": "Passwordless sudo", "icon": "shield-alert", "group": "System"}'
listed='[{"key": "acme.tui/hello", "plugin": "acme.tui", "name": "hello", "title": "Hello", "label": "Say hello", "icon": "terminal", "group": "Smoke"}, {"key": "acme.tui/update", "plugin": "acme.tui", "name": "update", "title": "Update", "label": "Update", "icon": "refresh-cw", "group": "Update"}, '"$core_listed"']'
expect "listTuis lists the fixture's script" "$listed" respaced ipc shell listTuis
expect "the capability publishes the same list" "$listed" respaced tui entries

revision="$(ipc shell listPlugins | python3 -c 'import json,sys; print([p["revision"] for p in json.load(sys.stdin)["plugins"] if p["id"]=="acme.tui"][0])')"
snapshot="$rt_dir/vgsh-sources-$shell_qs_pid/$revision"
check_snapshot() { [[ -x $snapshot/tui/hello.sh && ! -L $snapshot/tui/hello.sh ]] && echo present || echo absent; }
# The words the terminal is handed for the fixture's hello script with
# ARGS: the window, then present with the snapshot, the record and the
# window it records.
# `idle` once the core saw the last run of KEY end and holds no launch of
# it, so the next request for it is not refused busy.
key_idle() { ipc shell lent | python3 -c '
import json, sys
t, key = json.load(sys.stdin)["tui"], sys.argv[1]
r = t["runs"].get(key)
print("idle" if key not in t["pending"] and (r is None or r["running"] is None) else "busy")' "$1"; }
hello_words() {
  words --app-id=org.vgs.tui.wide "--title=VGS · Hello" -- "$tui_self" present --presentation full --plugin acme.tui --dir "$snapshot" \
    --record acme.tui/hello --run RUN --record-dir "$rt_dir/vgs/tui" --app-id org.vgs.tui.wide --window-title "VGS · Hello" -- tui/hello.sh "$@"
}
expect "the fixture's snapshot holds its executable script" present check_snapshot

# The core probes the launcher when it starts, against the host's PATH and
# before this row wrote the stand-in. A host without xdg-terminal-exec leaves
# it missing; then one request answers launcher-missing, starts no launcher
# and probes again, now against the stand-in. A present state takes no
# request, so no setup launch can land its record over a later row's.
expect_poll "the startup probe has answered" false lent tui.probing
if [[ "$(lent tui.launcher)" == '"missing"' ]]; then
  expect "a request on a host without a terminal answers launcher-missing" "refused: tui=hello reason=launcher-missing" tui run hello
fi
expect_poll "the launcher state is present" '"present"' lent tui.launcher
expect_poll "no probe is left running" false lent tui.probing
expect "the setup started no launcher" '[]' lent tui.launching

# run: the plugin's own script, from its snapshot, with its arguments as
# argv; shell syntax in an argument stays one word.
forget_record
expect "running the declared script answers ok" ok tui run 'hello|a b|$(touch planted)'
expect_poll "the terminal is handed the wide app-id, the snapshot and the arguments" \
  "$(hello_words "a b" '$(touch planted)')" recorded
expect_poll "the hello run ends before the next request" idle key_idle acme.tui/hello
expect_poll "the core holds no launcher once the presenter wrote its record" '[]' lent tui.launching
forget_record
expect "running it with no argument list answers ok" ok tui run hello
expect_poll "the terminal is handed the script alone" \
  "$(hello_words)" recorded
expect_poll "the hello run ends before the next request" idle key_idle acme.tui/hello

# open: a listed TUI by key, with no arguments, over IPC and through the
# capability.
forget_record
expect "openTui opens the listed script" ok ipc shell openTui acme.tui/hello
expect_poll "openTui hands the terminal the script and no argument" \
  "$(hello_words)" recorded
expect_poll "the hello run ends before the next request" idle key_idle acme.tui/hello
forget_record
expect "the capability opens a listed key" ok tui open acme.tui/hello
expect_poll "the capability's open reaches the terminal" \
  "$(hello_words)" recorded
expect_poll "the hello run ends before the next request" idle key_idle acme.tui/hello

# The core's own TUI: its command is the core's bin/vgsh beside the shell
# directory, whatever the shell's PATH holds, with no plugin copy.
core_vgsh="$(dirname -- "$(dirname -- "$tui_self")")/shell/../bin/vgsh"
forget_record
expect "openTui opens the core's sudo grant" ok ipc shell openTui core/sudo-grant
expect_poll "the terminal is handed the core's vgsh sudo grant" \
  "$(words --app-id=org.vgs.tui "--title=VGS · Passwordless sudo" -- "$tui_self" present --presentation full \
    --record core/sudo-grant --run RUN --record-dir "$rt_dir/vgs/tui" --app-id org.vgs.tui --window-title "VGS · Passwordless sudo" -- "$core_vgsh" sudo grant)" recorded
expect_poll "the core's run ends before the refusals" idle key_idle core/sudo-grant
forget_record
expect "openTui opens the core's package install picker" ok ipc shell openTui core/pkg-install
expect_poll "the terminal is handed the core's vgsh pkg install" \
  "$(words --app-id=org.vgs.tui "--title=VGS · Install packages" -- "$tui_self" present --presentation full \
    --record core/pkg-install --run RUN --record-dir "$rt_dir/vgs/tui" --app-id org.vgs.tui --window-title "VGS · Install packages" -- "$core_vgsh" pkg install)" recorded
expect_poll "the core's picker run ends before the refusals" idle key_idle core/pkg-install

# Refusals, each before any launcher starts.
forget_record
seventeen="hello$(printf '|a%.0s' $(seq 1 17))"
expect "a name the manifest does not declare is refused" "refused: tui=nope reason=undeclared" tui run nope
expect "seventeen arguments are refused" "refused: tui=hello reason=args" tui run "$seventeen"
expect "an empty argument is refused" "refused: tui=hello reason=args" tui run 'hello|'
expect "an argument with a control character is refused" "refused: tui=hello reason=args" tui run $'hello|a\tb'
expect "openTui refuses a key nothing lists" "refused: tui=acme.tui/nope reason=undeclared" ipc shell openTui acme.tui/nope
expect "a refused request starts no launcher" '[]' lent tui.launching
record_state() { [[ -e $sandbox/tui-argv ]] && echo recorded || echo none; }
expect "a refused request reaches no terminal" none record_state

# A launcher that finds no terminal. A stand-in bin/vgsh-tui that answers
# launch and check as the real one does without xdg-terminal-exec takes its
# place, since the sandbox PATH may hold a real one. The request made while
# the state said present answers ok and its launcher's exit 69 is logged;
# every later request answers launcher-missing at once, through the
# capability, openTui and vgsh tui open, and starts one probe.
cp -- "$repo/bin/vgsh-tui" "$sandbox/vgsh-tui.real"
printf '#!/bin/sh\nprintf '"'"'vgsh-tui: refused: terminal=missing\\n'"'"' >&2\nexit 69\n' >"$sandbox/vgsh-tui.missing"
chmod 755 "$sandbox/vgsh-tui.missing"
cp -- "$sandbox/vgsh-tui.missing" "$repo/bin/vgsh-tui.next" && mv -T -- "$repo/bin/vgsh-tui.next" "$repo/bin/vgsh-tui"
expected_errors+=('tui: refused: tui=acme\.tui/hello reason=launcher-missing')
expect "a request made while the launcher was present answers ok" ok tui run hello
expect_log "a launcher without a terminal is logged as launcher-missing" 1 'tui: refused: tui=acme\.tui/hello reason=launcher-missing'
expect_poll "the core released the failed launcher" '[]' lent tui.launching
expect_poll "the launcher's exit 69 records the terminal missing" '"missing"' lent tui.launcher
forget_record
expect "the capability answers launcher-missing at once" "refused: tui=hello reason=launcher-missing" tui run hello
expect "openTui answers launcher-missing at once" "refused: tui=acme.tui/hello reason=launcher-missing" ipc shell openTui acme.tui/hello
vgsh_open_refusal() { local status=0 err; err="$("${shell_env[@]}" "$repo/bin/vgsh" tui open acme.tui/hello 2>&1 >/dev/null)" || status=$?; printf '%s exit=%s\n' "${err%%$'\n'*}" "$status"; }
expect "vgsh tui open refuses with launcher-missing" "vgsh: refused: tui=acme.tui/hello reason=launcher-missing exit=1" vgsh_open_refusal
expect_poll "the probe a refusal started ends" false lent tui.probing
expect "the failed probe keeps the terminal missing" '"missing"' lent tui.launcher
expect "a launcher-missing answer starts no launcher" '[]' lent tui.launching
expect "a launcher-missing answer reaches no terminal" none record_state
cp -- "$sandbox/vgsh-tui.real" "$repo/bin/vgsh-tui.next" && mv -T -- "$repo/bin/vgsh-tui.next" "$repo/bin/vgsh-tui"
expect "a request before the next probe still answers launcher-missing" "refused: tui=hello reason=launcher-missing" tui run hello
expect_poll "the probe that request started finds the terminal again" '"present"' lent tui.launcher
expect "a later request answers ok once the probe passed" ok tui run hello
expect_poll "the later request reaches the terminal" \
  "$(hello_words)" recorded
expect_poll "the hello run ends before the next request" idle key_idle acme.tui/hello

# Exit records: a gated run of the fixture's wait script, with a `done`.
# The presenter writes the run's records; the core reads them into the
# fixture's state and its `done`, answers a second run of the live key
# busy and focuses its window.
tui_gate="$sandbox/tui-gate"
tui_done() { tui dones; }
# The fixture's state of its wait script as [running, code, ended].
wait_state() { tui state | python3 -c 'import json,sys; s=json.load(sys.stdin)["wait"]; print(json.dumps([s["running"], s["code"], s["endedAt"] is not None]))'; }
wait_window() { hypr -j clients | python3 -c 'import json,sys; print(sum(1 for c in json.load(sys.stdin) if c["class"]=="org.vgs.tui" and c["title"]=="VGS · Wait"))'; }
# The last ended code of the wait script's key the lending record holds.
wait_ended_code() { ipc shell lent | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["tui"]["runs"]["acme.tui/wait"]["ended"]["code"]))'; }
active_class() { hypr -j activewindow | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("class")))'; }
rm -f -- "$tui_gate"
expect "the wait script's state before any run" '[false, null, false]' wait_state
expect "a gated run with a done answers ok" ok tui run-done "wait|$tui_gate|3"
expect_poll "the run's record reaches the fixture's state" '[true, null, false]' wait_state
expect_poll "the launcher ends once the presenter holds the key" '[]' lent tui.launching
expect "no done fires while the run is open" '[]' tui_done
expect_poll "the stand-in terminal maps the run's window" 1 wait_window
spawn "$sandbox/toplevel-other.log" "${shell_env[@]}" "$sandbox/toplevel" org.example.other Other
other_pid="$spawn_pid"
expect_poll "another window takes the focus" '"org.example.other"' active_class
expect "a second run of the live key is refused busy" "refused: tui=wait reason=busy" tui run-done "wait|$tui_gate|3"
expect_poll "the busy answer focuses the live run's window" '"org.vgs.tui"' active_class
expect "a busy answer registers no done" '["acme.tui"]' lent tui.waiters
touch -- "$tui_gate"
expect_poll "the run's done fires with the command's code" '[["wait",3,null]]' tui_done
expect_poll "the fixture's state moves to the ended run" '[false, 3, true]' wait_state
expect "the core holds no done once it fired" '[]' lent tui.waiters
expect_poll "the run's window closes with the presenter" 0 wait_window
expect "the run's done fired once" '[["wait",3,null]]' tui_done
kill -TERM -- "$other_pid" 2>/dev/null || true

# A destroyed instance's done is dropped and its run still ends; the
# instance built after it reads the run from the state.
rm -f -- "$tui_gate"
expect "a gated run of the instance about to go answers ok" ok tui run-done "wait|$tui_gate|5"
expect_poll "the run is live" '[true, 3, true]' wait_state
expect "the core holds the instance's done" '["acme.tui"]' lent tui.waiters
expect "disabling the tui fixture during the run is allowed" ok ipc shell setPluginEnabled acme.tui false
expect_poll "the destroyed instance's done is dropped" '[]' lent tui.waiters
touch -- "$tui_gate"
expect_poll "the run ends without its instance" 5 wait_ended_code
expect "re-enabling the tui fixture is allowed" ok ipc shell setPluginEnabled acme.tui true
expect_poll "the tui fixture's service is built again" True record_exists acme.tui
expect_poll "the rebuilt instance reads the run the destroyed one started" '[false, 5, true]' wait_state
expect "the rebuilt instance received no done" '[]' tui_done

# Control: a presenter copy that writes no ended record leaves the run
# live and fires no done. A request for the key is then refused busy, finds
# no window and starts one reap, which ends the run with no code: the
# `done` answers it vanished.
tui_real="$sandbox/vgsh-tui.real"
cp -- "$repo/bin/vgsh-tui" "$tui_real"
end_line='  if [[ $record_active == 1 ]]; then record_end "${ran_code:-$status}"; fi'
if [[ $(grep -c -F -- "$end_line" "$tui_real") == 1 ]]; then
  python3 -c 'import sys; p, q, old = sys.argv[1:]; open(q, "w").write(open(p).read().replace(old, "  :"))' "$tui_real" "$sandbox/vgsh-tui.unended" "$end_line"
  chmod 755 "$sandbox/vgsh-tui.unended"
  cp -- "$sandbox/vgsh-tui.unended" "$repo/bin/vgsh-tui.next" && mv -T -- "$repo/bin/vgsh-tui.next" "$repo/bin/vgsh-tui"
  rm -f -- "$tui_gate"
  expect "a gated run under the unended control answers ok" ok tui run-done "wait|$tui_gate|6"
  expect_poll "the control's run is live" '[true, 5, true]' wait_state
  expect_poll "the control's window maps" 1 wait_window
  touch -- "$tui_gate"
  expect_poll "the control's presenter exits and its window closes" 0 wait_window
  expect "the unended control fires no done" '[]' tui_done
  expect "the unended control leaves the run live" '[true, 5, true]' wait_state
  cp -- "$tui_real" "$repo/bin/vgsh-tui.next" && mv -T -- "$repo/bin/vgsh-tui.next" "$repo/bin/vgsh-tui"
  expected_errors+=('tui: focus=none tui=acme\.tui/wait')
  expect "a request for the vanished run's key is refused busy" "refused: tui=wait reason=busy" tui run "wait|$tui_gate|0"
  expect_log "the busy answer finds no window for the vanished run" 1 'tui: focus=none tui=acme\.tui/wait'
  expect_poll "the reap it started ends the vanished run" '[false, null, true]' wait_state
  expect_poll "the vanished run's done fires with no code" '[["wait",null,"vanished"]]' tui_done
  expect_poll "no reap is left running" false lent tui.reaping
else
  fail "the unended control's line occurs once in bin/vgsh-tui"
fi

# A disabled plugin's TUIs leave the list and no longer open.
expect "disabling the tui fixture is allowed" ok ipc shell setPluginEnabled acme.tui false
expect_poll "a disabled plugin's TUIs leave the list" "[$core_listed]" respaced ipc shell listTuis
expect "openTui refuses a disabled plugin's key" "refused: tui=acme.tui/hello reason=disabled" ipc shell openTui acme.tui/hello
expect_poll "a disabled plugin holds no tui capability" False tui_held
