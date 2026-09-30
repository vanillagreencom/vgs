# Plugin status, D037. The fixture's service publishes typed values through
# its `status` capability, and every instance of the plugin reads the one
# record the core holds for the plugin: the service, a bar widget on each of
# two screens and a summoned panel read back one revision and one set of
# values. A key the manifest does not declare, a value of the wrong type and
# values past the ceiling are refused by their keyed line and change
# nothing, and the published values do not change in place. Disabling the
# plugin drops its record from the lending record, a write through a
# provider the core retired does not bring it back, and the rebuilt service
# publishes again from nothing; a new source revision drops the record too.
# The row ends with the fixture disabled and its screen removed, so the
# later rows' bars and lending records hold nothing of it. rows/settings.sh
# enables it again to read its Status rows.
set -euo pipefail
status_dir="$home/.config/vgs/plugins/acme.status"
mkdir -p "$status_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.status/." "$status_dir/"
publish() { ipc acme.status invoke "$1" "${2:-}"; }
read_status() { ipc smoke readInstance "$1" acme.status "$2"; }
# The fixture's entry in the lending record's status records, or null.
lent_status() { ipc shell lent | py_reply 'import json,sys; r=json.load(sys.stdin)["status"].get("acme.status"); print(json.dumps(r if r is None else [r[k] for k in sys.argv[1:]]))' "$@"; }
bar_keys() { ipc shell built | py_reply 'import json,sys; print(" ".join(sorted(k for k in json.load(sys.stdin) if k.startswith("bar:"))))'; }
status_widgets() { ipc shell built | py_reply 'import json,sys; print(sum(1 for k, rows in json.load(sys.stdin).items() if k.startswith("bar:") for r in rows if r["id"] == "acme.status"))'; }
# readers PROPERTY: the property as every instance reads it, as one JSON
# list: the service first, then the widget on each bar, then the panel.
readers() {
  local got key out=()
  got="$(read_status service "$1")" || return
  out+=("$got")
  for key in $(bar_keys); do
    got="$(read_status "$key" "$1")" || return
    out+=("$got")
  done
  got="$(read_status panel "$1")" || return
  out+=("$got")
  python3 -c 'import json,sys; print(json.dumps([json.loads(a) for a in sys.argv[1:]]))' "${out[@]}"
}
# agreed PROPERTY: the one value every reader holds, or `readers=<list>`
# while they differ.
agreed() { readers "$1" | py_reply 'import json,sys; r=json.load(sys.stdin); print(json.dumps(r[0]) if len(r) >= 4 and all(v == r[0] for v in r) else "readers=" + json.dumps(r))'; }

expect "rescan after adding the status fixture answers ok" ok ipc shell rescanPlugins
expect_poll "the status fixture is discovered" True plugin_known acme.status
status_output=SMOKE-STATUS
expect "the nested compositor adds a monitor for the status rows" ok hypr output create headless "$status_output"
expect_poll "the new monitor gets a bar" "$((monitors + 1))" bar_count
expect "enabling the status fixture is allowed" ok ipc shell setPluginEnabled acme.status true
expect_poll "the status fixture's service is built" True record_exists acme.status
# acme.probe holds no `detail` handler and acme.status does: a plugin's
# shell.ipc.call reaches its own target alone.
expect "a plugin's call does not reach another plugin's handler" "unknown: detail" ipc acme.probe invoke call detail
expect_poll "the service's first write is accepted" '"ok"' read_status service startReply
expect_poll "a status widget is built on every bar" "$((monitors + 1))" status_widgets
expect "the fixture's panel is summoned" ok ipc shell summon panel acme.status '{}'
expect_poll "the service, every widget and the panel read the first write" '{"token": "present"}' agreed statusValues
expect "the lending record holds the fixture's record" '[["token"]]' lent_status keys

# Writes: each one reaches every instance with one new revision.
first_revision="$(read_status service statusRevision)" || fail "the service's revision is unreadable"
expect "a declared count is published" ok publish set 'pending=3'
expect "a declared state is published" ok publish set 'check={"tone":"warning","text":"Two sources failed"}'
expect "a declared time is published" ok publish set 'lastCheck=1790650695194'
expect "declared data is published" ok publish detail
expect_poll "every instance reads the four writes" '{"token": "present", "pending": 3, "check": {"tone": "warning", "text": "Two sources failed"}, "lastCheck": 1790650695194, "detail": {"items": [1, 2]}}' agreed statusValues
settled_revision() { agreed statusRevision | python3 -c 'import sys; t=sys.stdin.read().strip(); print(int(t) - int(sys.argv[1]) if t.lstrip("-").isdigit() else t)' "$first_revision"; }
expect "every instance reads one revision, four writes on" 4 settled_revision
expect "every widget reads the data the service published" '[1,2]' read_status "$(bar_key)" detailItems
expect "the lending record lists the published keys" '[["check", "detail", "lastCheck", "pending", "token"]]' lent_status keys

# Refusals: each is one keyed line and leaves the values and the revision.
before_values="$(agreed statusValues)" || fail "the values are unreadable before the refusals"
before_revision="$(agreed statusRevision)" || fail "the revision is unreadable before the refusals"
expect "an undeclared key is refused" "refused: status=nope reason=undeclared" publish set 'nope="x"'
expect "a count written as a string is refused" "refused: status=pending reason=type" publish set 'pending="3"'
expect "a presence outside its set is refused" "refused: status=token reason=type" publish set 'token="stored"'
expect "values past the ceiling are refused" "refused: status=detail reason=size" publish big
expect "the refusals change no value" "$before_values" agreed statusValues
expect "the refusals change no revision" "$before_revision" agreed statusRevision
tampered() { publish tamper | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)))'; }
expect "the published values do not change in place" "$before_values" tampered

# Choices use the same one record and refusal path as other status types.
agreed_choices() { agreed statusValues | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["devices"]))'; }
choices_after_tamper() { publish tamper | py_reply 'import json,sys; print(json.dumps(json.load(sys.stdin)["devices"]))'; }
expect "a labeled choices list is published" ok publish set 'devices=[{"label":"Alpha","value":"a"},{"label":"Beta","value":"b"}]'
expect_poll "every instance reads the choices list" '[{"label": "Alpha", "value": "a"}, {"label": "Beta", "value": "b"}]' agreed_choices
choices_revision="$(agreed statusRevision)" || fail "the choices revision is unreadable"
expect "duplicate choice values are refused" 'refused: status=devices reason=type' publish set 'devices=[{"label":"Alpha","value":"a"},{"label":"Other","value":"a"}]'
expect "an empty offered id is refused" 'refused: status=devices reason=type' publish set 'devices=[{"label":"Automatic","value":""}]'
expect "choice refusals change no revision" "$choices_revision" agreed statusRevision
expect "a reader cannot change the choices in the record" '[{"label": "Alpha", "value": "a"}, {"label": "Beta", "value": "b"}]' choices_after_tamper

# Disable: the record goes with the plugin, and the provider of an
# instance the core retired cannot bring it back.
expect "the probe keeps the service's status provider" held ipc smoke holdStatus service acme.status
expect "disabling the status fixture is allowed" ok ipc shell setPluginEnabled acme.status false
expect_poll "disabling drops the record from the lending record" null lent_status keys
expect_poll "no status widget remains" 0 status_widgets
expect "a write through the retired provider is refused" "refused: status=pending reason=retired" ipc smoke heldStatusSet pending 5
expect "the refused write brings no record back" null lent_status keys
expect "enabling the status fixture again is allowed" ok ipc shell setPluginEnabled acme.status true
expect_poll "the rebuilt service publishes again from nothing" '[["token"]]' lent_status keys

# A new source revision drops the record, and the service built from it
# publishes again.
expect "a count is published before the source changes" ok publish set 'pending=4'
expect_poll "the record holds the count" '[["pending", "token"]]' lent_status keys
printf '// edited by the status row\n' >>"$status_dir/Panel.qml"
scans="$(log_lines 'plugins: scan complete changed=true')" || fail "the instance log is unreadable before the source change"
expect "a rescan after the source change answers ok" ok ipc shell rescanPlugins
expect_log "the rescan publishes the new revision" "$((scans + 1))" 'plugins: scan complete changed=true'
expect_poll "the new revision's service publishes again from nothing" '[["token"]]' lent_status keys

expect "disabling the status fixture after its rows is allowed" ok ipc shell setPluginEnabled acme.status false
expect_poll "the disabled fixture holds no record" null lent_status keys
expect "the nested compositor removes the status rows' monitor" ok hypr output remove "$status_output"
expect_poll "the removed monitor's bar surface is gone" "$monitors" bar_count
