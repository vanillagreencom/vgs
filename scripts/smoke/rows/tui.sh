# Floating TUIs through the `tui` capability and the core's `listTuis` and
# `openTui`, read back from a stand-in xdg-terminal-exec in the shell's own
# PATH directory. The real bin/vgsh-tui launches it; it records the argv it
# was handed and opens nothing, so no terminal starts. The fixture acme.tui
# declares one listed script. Rows: the published list, the app-id of the
# script's size, the snapshot path it runs from and its arguments, the
# core's own sudo grant and package install picker opened by key as the
# core's bin/vgsh, each refusal, a launcher that finds no terminal and the synchronous
# `launcher-missing` answer that follows until a probe finds one again, the
# launchers the core holds, and a disabled plugin's list and hold gone.
set -euo pipefail
tui_dir="$home/.config/vgs/plugins/acme.tui"
mkdir -p "$tui_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.tui/." "$tui_dir/"
tui_record="$sandbox/tui-argv"
# Written whole and moved into place, so a row never reads half a record.
cat >"$shim/xdg-terminal-exec" <<EOF
#!/bin/sh
: >"$tui_record.next"
for a; do printf '%s\n' "\$a" >>"$tui_record.next"; done
mv -f -- "$tui_record.next" "$tui_record"
EOF
chmod 755 "$shim/xdg-terminal-exec"
tui_self="$(readlink -f -- "$repo/bin/vgsh-tui")"
tui() { ipc acme.tui invoke "$1" "${2:-}"; }
# The record, and a list of words, as one JSON line each.
recorded() { python3 -c 'import json,os,sys; print(json.dumps(open(sys.argv[1]).read().split("\n")[:-1]) if os.path.exists(sys.argv[1]) else "absent")' "$tui_record"; }
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
listed='[{"key": "acme.tui/hello", "plugin": "acme.tui", "name": "hello", "title": "Hello", "label": "Say hello", "icon": "terminal", "group": "Smoke"}, '"$core_listed"']'
expect "listTuis lists the fixture's script" "$listed" respaced ipc shell listTuis
expect "the capability publishes the same list" "$listed" respaced tui entries

revision="$(ipc shell listPlugins | python3 -c 'import json,sys; print([p["revision"] for p in json.load(sys.stdin)["plugins"] if p["id"]=="acme.tui"][0])')"
snapshot="$rt_dir/vgsh-sources-$shell_qs_pid/$revision"
check_snapshot() { [[ -x $snapshot/tui/hello.sh && ! -L $snapshot/tui/hello.sh ]] && echo present || echo absent; }
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
  "$(words --app-id=org.vgs.tui.wide "--title=VGS · Hello" -- "$tui_self" present --presentation full --plugin acme.tui --dir "$snapshot" -- tui/hello.sh "a b" '$(touch planted)')" recorded
expect_poll "the core holds no launcher once it forked the terminal" '[]' lent tui.launching
forget_record
expect "running it with no argument list answers ok" ok tui run hello
expect_poll "the terminal is handed the script alone" \
  "$(words --app-id=org.vgs.tui.wide "--title=VGS · Hello" -- "$tui_self" present --presentation full --plugin acme.tui --dir "$snapshot" -- tui/hello.sh)" recorded

# open: a listed TUI by key, with no arguments, over IPC and through the
# capability.
forget_record
expect "openTui opens the listed script" ok ipc shell openTui acme.tui/hello
expect_poll "openTui hands the terminal the script and no argument" \
  "$(words --app-id=org.vgs.tui.wide "--title=VGS · Hello" -- "$tui_self" present --presentation full --plugin acme.tui --dir "$snapshot" -- tui/hello.sh)" recorded
forget_record
expect "the capability opens a listed key" ok tui open acme.tui/hello
expect_poll "the capability's open reaches the terminal" \
  "$(words --app-id=org.vgs.tui.wide "--title=VGS · Hello" -- "$tui_self" present --presentation full --plugin acme.tui --dir "$snapshot" -- tui/hello.sh)" recorded

# The core's own TUI: its command is the core's bin/vgsh beside the shell
# directory, whatever the shell's PATH holds, with no plugin copy.
core_vgsh="$(dirname -- "$(dirname -- "$tui_self")")/shell/../bin/vgsh"
forget_record
expect "openTui opens the core's sudo grant" ok ipc shell openTui core/sudo-grant
expect_poll "the terminal is handed the core's vgsh sudo grant" \
  "$(words --app-id=org.vgs.tui "--title=VGS · Passwordless sudo" -- "$tui_self" present --presentation full -- "$core_vgsh" sudo grant)" recorded
forget_record
expect "openTui opens the core's package install picker" ok ipc shell openTui core/pkg-install
expect_poll "the terminal is handed the core's vgsh pkg install" \
  "$(words --app-id=org.vgs.tui "--title=VGS · Install packages" -- "$tui_self" present --presentation full -- "$core_vgsh" pkg install)" recorded

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
  "$(words --app-id=org.vgs.tui.wide "--title=VGS · Hello" -- "$tui_self" present --presentation full --plugin acme.tui --dir "$snapshot" -- tui/hello.sh)" recorded

# A disabled plugin's TUIs leave the list and no longer open.
expect "disabling the tui fixture is allowed" ok ipc shell setPluginEnabled acme.tui false
expect_poll "a disabled plugin's TUIs leave the list" "[$core_listed]" respaced ipc shell listTuis
expect "openTui refuses a disabled plugin's key" "refused: tui=acme.tui/hello reason=disabled" ipc shell openTui acme.tui/hello
expect_poll "a disabled plugin holds no tui capability" False tui_held
