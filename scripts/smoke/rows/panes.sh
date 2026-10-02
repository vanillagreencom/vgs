# Pane kind and panes capability: a holder window lists enabled pane
# plugins, mounts a pane with that pane plugin's own shell, owns one mount
# at a time and refuses a second panes holder while it holds the capability.
# The pane's configure writes every configuration entry its plugin reads.
set -euo pipefail

pane_file="$home/.config/vgs/shell.json"
pane_saved="$sandbox/shell-before-panes.json"
pane_bar_key=""
cp -- "$pane_file" "$pane_saved"

install_plugin_copy() { # SOURCE ID NAME [ORDER]
  local source="$1" id="$2" name="$3" order="${4:-10}" target
  target="$home/.config/vgs/plugins/$id"
  rm -rf -- "${target:?}"
  mkdir -p -- "$target"
  cp -R "$repo/scripts/smoke/fixtures/plugins/$source/." "$target/"
  python3 - "$target/manifest.json" "$id" "$name" "$order" <<'PY'
import json, os, sys
path, plugin_id, name, order = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
doc = json.load(open(path))
doc["id"] = plugin_id
doc["name"] = name
if "pane" in doc:
    doc["pane"]["order"] = order
json.dump(doc, open(path + ".tmp", "w"))
os.replace(path + ".tmp", path)
PY
}

host_list() { ipc smoke readInstance window acme.panehost paneRows | py_reply 'import json,sys; print(json.dumps(json.loads(json.load(sys.stdin)), separators=(",", ":")))'; }
host_list_ids() { host_list | py_reply 'import json,sys; print(json.dumps([r["id"] for r in json.load(sys.stdin)], separators=(",", ":")))'; }
host_list_placed() { host_list | py_reply 'import json,sys; print(json.dumps([r["placed"] for r in json.load(sys.stdin) if r["id"] == "acme.pane"][0]))'; }
window_panes() { ipc shell built | py_reply 'import json,sys; print(json.dumps([r["id"] for r in json.load(sys.stdin).get("window", []) if r["kind"] == "pane"], separators=(",", ":")))'; }
pane_idle_watches() { ipc shell lent | py_reply 'import json,sys; print(json.dumps(sorted(w["id"] for w in json.load(sys.stdin)["idle"] if w["id"].startswith("acme.pane")), separators=(",", ":")))'; }
settings_pane_label() { ipc smoke readInstance window vgs.settings plugins | py_reply 'import json,sys; print(json.dumps([p["settings"]["label"] for p in json.load(sys.stdin) if p["id"] == "acme.pane"][0]))'; }

install_plugin_copy acme.panehost acme.panehost "Pane Host" 0
install_plugin_copy acme.pane acme.pane "Pane" 10
expect "rescan after adding the pane fixtures answers ok" ok ipc shell rescanPlugins
expect_poll "the pane host fixture is discovered" False plugin_enabled acme.panehost
expect_poll "the pane fixture is discovered" False plugin_enabled acme.pane
expect "enabling the pane fixture is allowed" ok ipc shell setPluginEnabled acme.pane true
expect_poll "the pane service is built" True record_exists acme.pane
expect "own-pane summon is refused while no panes holder is enabled" "refused: panes=no-holder" ipc smoke invokeInstance service acme.pane summonPane ''
expect "enabling the pane host is allowed" ok ipc shell setPluginEnabled acme.panehost true
pane_bar_key="$(bar_key)" || fail "the bar key is unreadable for pane rows"
pane_widget_placed() { bar_widget_ids | py_reply 'import json,sys; print(any("acme.pane" in ids for ids in json.load(sys.stdin)))'; }
tick_widget_placed() { bar_widget_ids | py_reply 'import json,sys; print(any("acme.tick" in ids for ids in json.load(sys.stdin)))'; }
expect_poll "the pane widget is placed" True pane_widget_placed

expect "summoning the pane host window is allowed" ok ipc shell summon window acme.panehost '{}'
expect_poll "the pane host window is built" true ipc smoke activeFocusIn window acme.panehost
expect_poll "the holder lists the pane with its manifest metadata and placement" '[{"id":"acme.pane","name":"Pane","icon":"panel-right-open","group":"Fixtures","order":10,"placed":true,"hasWidget":true}]' host_list
expect "the pane host shell has panes and not the pane's capabilities" '"manifest,panes,settings,surfaces"' ipc smoke readInstance window acme.panehost shellKeys
expect "a non-pane holder cannot use own-pane summon" "refused: kind=pane id=acme.panehost" ipc smoke invokeInstance window acme.panehost summonPaneAsNonPane '{}'

expect_poll "the holder's Open pane button starts with keyboard focus" '["Button","Open pane",true,true,true]' ipc smoke focused window acme.panehost
type_keys -k Return || fail "keyboard Return on the holder's Open pane button failed"
expect_poll "keyboard Return mounts the pane" '["acme.pane"]' window_panes
expect_poll "the mounted pane reads its own manifest id" '"acme.pane"' ipc smoke readInstance window acme.pane manifestId
expect "the mounted pane got its own scoped shell, not the host shell" '"configure,idle,manifest,settings,surfaces"' ipc smoke readInstance window acme.pane shellKeys
expect "the mounted pane received the keyboard payload" '"{\"from\":\"button\"}"' ipc smoke readInstance window acme.pane payload
expect_poll "the pane's initial focus takes the keyboard" '["Button","Pane edit",true,true,true]' ipc smoke focused window acme.pane
type_keys -k Return || fail "keyboard Return on the pane edit button failed"
expect_poll "keyboard Return on the pane control edits the setting" '"pane-edited"' ipc smoke readInstance window acme.pane label
type_keys -k Escape || fail "keyboard Escape from the pane failed"
expect_poll "host-owned Escape destroys the mounted pane" '[]' window_panes
expect_poll "host-owned Escape returns focus to the holder" '["Button","Open pane",true,true,true]' ipc smoke focused window acme.panehost
expect "mounting the pane through the holder is allowed" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
expect "the mounted pane received the direct payload" '"{}"' ipc smoke readInstance window acme.pane payload

install_plugin_copy acme.pane acme.pane-alt "Pane Alt" 20
expect "rescan after adding the second pane answers ok" ok ipc shell rescanPlugins
expect_poll "the second pane is discovered" False plugin_enabled acme.pane-alt
expect "enabling the second pane is allowed" ok ipc shell setPluginEnabled acme.pane-alt true
expect_poll "the holder lists both panes in order" '["acme.pane","acme.pane-alt"]' host_list_ids
expect "the first mounted pane owns one idle watch" '["acme.pane"]' pane_idle_watches
expect "switching to the second pane is allowed" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane-alt'
expect_poll "switching destroys the previous pane build record" '["acme.pane-alt"]' window_panes
expect_poll "switching releases the previous pane's idle watch" '["acme.pane-alt"]' pane_idle_watches
expect "switching back to the first pane is allowed" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
expect_poll "only the selected pane remains mounted" '["acme.pane"]' window_panes
expect_poll "only the selected pane owns an idle watch" '["acme.pane"]' pane_idle_watches

install_plugin_copy acme.panehost acme.panehost2 "Pane Host Two" 0
expect "rescan after adding a second holder answers ok" ok ipc shell rescanPlugins
expect_poll "the second holder is discovered" False plugin_enabled acme.panehost2
expect "enabling a second panes holder is allowed" ok ipc shell setPluginEnabled acme.panehost2 true
expect "a second holder is refused while the first holds panes" "refused: capability=panes held-by=acme.panehost" ipc shell summon window acme.panehost2 '{}'
expect "the second holder is not built" False record_exists acme.panehost2

expect "the pane can edit its setting" ok ipc smoke invokeInstance window acme.pane setLabel pane-edited
expect_poll "the service reads the pane edit" '"pane-edited"' ipc smoke readInstance service acme.pane label
expect_poll "the widget reads the pane edit" '"pane-edited"' ipc smoke readInstance "$pane_bar_key" acme.pane label
expect_poll "the pane reads its own edit" '"pane-edited"' ipc smoke readInstance window acme.pane label

expect "enabling Settings for the pane edit check is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect "opening Settings on the pane plugin is allowed" ok ipc shell summon window vgs.settings '{"plugin":"acme.pane"}'
expect_poll "Settings opens the pane plugin page" '"acme.pane"' ipc smoke readInstance window vgs.settings page
expect "the Settings page writes the same setting" ok ipc smoke invokeInstance window vgs.settings applySetting '{"id":"acme.pane","key":"label","value":"pane-service"}'
expect_poll "the service reads the Settings edit" '"pane-service"' ipc smoke readInstance service acme.pane label
expect_poll "the widget reads the Settings edit" '"pane-service"' ipc smoke readInstance "$pane_bar_key" acme.pane label
expect_poll "the pane reads the Settings edit" '"pane-service"' ipc smoke readInstance window acme.pane label
expect_poll "the Settings page reads the shared setting" '"pane-service"' settings_pane_label
expect "disabling the mounted pane plugin is allowed" ok ipc shell setPluginEnabled acme.pane false
expect_poll "disabling the mounted pane drops its build record" '[]' window_panes
expect_poll "disabling the mounted pane releases its idle watch" '[]' pane_idle_watches
expect "re-enabling the pane plugin is allowed" ok ipc shell setPluginEnabled acme.pane true
expect_poll "re-enabling the pane plugin leaves it unmounted" '[]' window_panes
expect "mounting the pane after re-enable is allowed" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'

expect "the holder panes.setPlaced can unplace a listed pane plugin" ok ipc smoke invokeInstance window acme.panehost placeRequest '{"id":"acme.pane","placed":false}'
expect_poll "the holder list follows unplacement" false host_list_placed
expect_poll "the pane widget leaves the bar after panes.setPlaced" False pane_widget_placed
expect "the holder panes.setPlaced can place it again" ok ipc smoke invokeInstance window acme.panehost placeRequest '{"id":"acme.pane","placed":true}'
expect_poll "the holder list follows placement" true host_list_placed
expect_poll "the pane widget returns to the bar" True pane_widget_placed
expect "placing the non-pane widget precondition is allowed" ok ipc shell setPluginEnabled acme.tick true
expect_poll "the non-pane widget precondition is placed" True tick_widget_placed
expect "panes.setPlaced refuses a non-pane widget as unknown" "unknown: acme.tick" ipc smoke invokeInstance window acme.panehost placeRequest '{"id":"acme.tick","placed":false}'
expect_poll "the non-pane widget remains placed after refused panes.setPlaced" True tick_widget_placed
expect "panes.setPlaced refuses a non-boolean placement" "refused: placed=1 want=boolean" ipc smoke invokeInstance window acme.panehost placeRequest '{"id":"acme.pane","placed":1}'

expect "hiding the host window is allowed" ok ipc shell hide window acme.panehost
expect_poll "hiding the host destroys the mounted pane" '[]' window_panes
expect_poll "hiding the host releases the pane idle watch" '[]' pane_idle_watches
expect_poll "the host window is closed before own-pane summon" false ipc smoke activeFocusIn window acme.panehost
expect "own-pane summon opens the holder window" ok ipc smoke invokeInstance service acme.pane summonPane ''
expect_poll "own-pane summon mounted the caller pane" '["acme.pane"]' window_panes
expect "the holder saw the own-pane payload" '"{\"from\":\"service\",\"pane\":\"acme.pane\"}"' ipc smoke readInstance window acme.panehost openedPayload
expect "own-pane summon overwrites a spoofed pane id" ok ipc smoke invokeInstance service acme.pane summonPaneWith '{"pane":"acme.pane-alt","from":"spoof"}'
expect_poll "own-pane summon with a spoofed id still mounts the caller pane" '["acme.pane"]' window_panes
expect "the holder saw the caller pane after a spoofed payload" '"{\"pane\":\"acme.pane\",\"from\":\"spoof\"}"' ipc smoke readInstance window acme.panehost openedPayload
expect "own-pane summon refuses an array payload" "refused: pane-payload=object" ipc smoke invokeInstance service acme.pane summonPaneWith '[1]'
expect "own-pane summon refuses non-json text" "refused: pane-payload=json" ipc smoke invokeInstance service acme.pane summonPaneWith 'not json'
expect "mounting the alternate pane before hide guard checks is allowed" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane-alt'
expect "hide by a different pane caller answers ok" ok ipc smoke invokeInstance service acme.pane hidePane ''
expect_poll "hide by a different pane caller keeps the holder window open" true ipc smoke activeFocusIn window acme.panehost
expect_poll "hide by a different pane caller keeps the mounted alternate pane" '["acme.pane-alt"]' window_panes
expect "mounting the caller pane before its hide check is allowed" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
expect "hide by the current pane caller answers ok" ok ipc smoke invokeInstance service acme.pane hidePane ''
expect_poll "hide by the current pane caller closes the holder window" false ipc smoke activeFocusIn window acme.panehost
expect_poll "hide by the current pane caller drops the pane" '[]' window_panes
expect "toggle while the holder is closed opens the caller pane" ok ipc smoke invokeInstance service acme.pane togglePane '{"from":"toggle-open"}'
expect_poll "toggle while closed mounts the caller pane" '["acme.pane"]' window_panes
expect "toggle while the holder shows the caller pane closes it" ok ipc smoke invokeInstance service acme.pane togglePane '{"from":"toggle-close"}'
expect_poll "toggle while showing the caller pane closes the holder" false ipc smoke activeFocusIn window acme.panehost
expect_poll "toggle while showing the caller pane drops the pane" '[]' window_panes



pane_identity_shell() {
  python3 - "$1" "$2" <<'PYDATA'
import json, sys
print(json.dumps([json.loads(sys.argv[1]), json.loads(sys.argv[2])], separators=(",", ":")))
PYDATA
}
four_view_labels() {
  local service widget pane settings
  service="$(ipc smoke readInstance service acme.pane label)" || return
  widget="$(ipc smoke readInstance "$pane_bar_key" acme.pane label)" || return
  pane="$(ipc smoke readInstance window acme.pane label)" || return
  settings="$(settings_pane_label)" || return
  python3 - "$service" "$widget" "$pane" "$settings" <<'PYDATA'
import json, sys
print(json.dumps([json.loads(v) for v in sys.argv[1:]], separators=(",", ":")))
PYDATA
}
restart_control_shell() { # NAME FILE OLD NEW
  stop_shell || return 1
  copy_tree "$1" || return 1
  edit_tree "$1" "$2" "$3" "$4" || return 1
  start_shell "$sandbox/tree-$1" "$sandbox/qs-$1.log" || return 1
  expect_poll "the $1 control shell knows the pane host" True plugin_enabled acme.panehost
}
restore_product_shell() { # LABEL
  stop_shell || return 1
  start_shell "$repo" "$sandbox/qs-$1.log" || return 1
  pane_bar_key="$(bar_key)" || fail "the bar key is unreadable after $1"
  expect_poll "the $1 shell knows the pane host" True plugin_enabled acme.panehost
}


restart_control_shell pane-key-unload shell/Hosts/PluginSlot.qml 'function unload() {' 'function unload() { return;'
expect "control: key-unload host summons" ok ipc shell summon window acme.panehost '{}'
expect "control: key-unload mounts the pane" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
expect "control: disabling the mounted pane is accepted" ok ipc shell setPluginEnabled acme.pane false
expect_poll "control: removing key-driven unload keeps the disabled pane mounted" '["acme.pane"]' window_panes
restore_product_shell restored-key-unload || fail "restoring after the key-unload control failed"
expect "key-unload restore: re-enabling after the control is allowed" ok ipc shell setPluginEnabled acme.pane true
expect "key-unload restore: host summons" ok ipc shell summon window acme.panehost '{}'
expect "key-unload restore: mount succeeds" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
expect "key-unload restore: disabling the mounted pane is accepted" ok ipc shell setPluginEnabled acme.pane false
expect_poll "key-unload restore: disabling drops the pane" '[]' window_panes
expect "key-unload restore: re-enabling the pane is allowed" ok ipc shell setPluginEnabled acme.pane true
expect "key-unload restore: mounting the pane is allowed" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'

restart_control_shell pane-hide-teardown shell/Hosts/PluginSlot.qml $'Component.onDestruction: {\n        if (releaseInputSurface !== null) releaseInputSurface();\n        unload();\n    }' $'Component.onDestruction: {\n        if (releaseInputSurface !== null) releaseInputSurface();\n        if (false) unload();\n    }'
expect "control: hide-teardown host summons" ok ipc shell summon window acme.panehost '{}'
expect "control: hide-teardown mounts the pane" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
expect "control: hide-teardown hides the holder" ok ipc shell hide window acme.panehost
expect_poll "control: removing PluginSlot destruction keeps the hidden pane in the ledger" '["acme.pane"]' window_panes
restore_product_shell restored-hide-teardown || fail "restoring after the hide-teardown control failed"
expect "hide-teardown restore: host summons" ok ipc shell summon window acme.panehost '{}'
expect "hide-teardown restore: mount succeeds" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
expect "hide-teardown restore: hiding the holder is accepted" ok ipc shell hide window acme.panehost
expect_poll "hide-teardown restore: hiding drops the pane" '[]' window_panes
expect "hide-teardown restore: host summons for later controls" ok ipc shell summon window acme.panehost '{}'
expect "hide-teardown restore: mount succeeds for later controls" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'

if restart_control_shell pane-payload-order shell/Core/Capabilities.qml $'const out = {};\n        for (const key of Object.keys(payload)) out[key] = payload[key];\n        out.pane = ctx.id;' $'const out = { pane: ctx.id };\n        for (const key of Object.keys(payload)) out[key] = payload[key];'; then
  expect "control: payload-order shell summons" ok ipc shell summon window acme.panehost '{}'
  expect "control: spoofed payload is accepted by the mutant" ok ipc smoke invokeInstance service acme.pane summonPaneWith '{"pane":"acme.pane-alt","from":"spoof"}'
  expect_poll "control: copying the caller pane before payload keys lets spoofed payload win" '["acme.pane-alt"]' window_panes
fi
restore_product_shell restored-payload-order || fail "restoring after the payload-order control failed"
expect "payload-order restore: host summons" ok ipc shell summon window acme.panehost '{}'
expect "payload-order restore: spoofed payload is accepted" ok ipc smoke invokeInstance service acme.pane summonPaneWith '{"pane":"acme.pane-alt","from":"spoof"}'
expect_poll "payload-order restore: caller pane wins after spoofed payload" '["acme.pane"]' window_panes

if restart_control_shell pane-hide-current shell/Core/Capabilities.qml 'if (verb === "hide") return Plugins.currentPaneId() === ctx.id ? Plugins.route("hide", "window", holder, "", null) : "ok";' 'if (verb === "hide") return Plugins.route("hide", "window", holder, "", null);'; then
  expect "control: hide-current shell summons" ok ipc shell summon window acme.panehost '{}'
  expect "control: hide-current mounts the alternate pane" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane-alt'
  expect "control: hide-current hide from another pane answers ok" ok ipc smoke invokeInstance service acme.pane hidePane ''
  expect_poll "control: dropping the current-pane guard lets another pane close the holder" false ipc smoke activeFocusIn window acme.panehost
fi
restore_product_shell restored-hide-current || fail "restoring after the hide-current control failed"
expect "hide-current restore: host summons" ok ipc shell summon window acme.panehost '{}'
expect "hide-current restore: alternate pane mounts" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane-alt'
expect "hide-current restore: hide from another pane answers ok" ok ipc smoke invokeInstance service acme.pane hidePane ''
expect_poll "hide-current restore: another pane cannot close the holder" true ipc smoke activeFocusIn window acme.panehost

restart_control_shell pane-host-shell shell/Hosts/PaneHost.qml 'mounted.sawInstance = true;' 'mounted.sawInstance = true; instance.shell = { manifest: Registry.manifests["acme.panehost"], settings: {}, panes: {}, idle: { watch: (seconds, onChange) => () => {} } };'
expect "control: host-shell provider starts" ok ipc shell summon window acme.panehost '{}'
expect "control: host-shell provider mounts the pane" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
control_manifest="$(ipc smoke readInstance window acme.pane manifestId)" || fail "control: host-shell manifest read failed"
control_keys="$(ipc smoke readInstance window acme.pane shellKeys)" || fail "control: host-shell shell keys read failed"
expect "control: handing the host shell to the pane breaks pane identity and capability readback" '["acme.panehost","idle,manifest,panes,settings"]' pane_identity_shell "$control_manifest" "$control_keys"
restore_product_shell restored-provider
expect "provider restore: the host summons again" ok ipc shell summon window acme.panehost '{}'
expect "provider restore: mounting the pane is allowed" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
restored_manifest="$(ipc smoke readInstance window acme.pane manifestId)" || fail "provider restore: manifest read failed"
restored_keys="$(ipc smoke readInstance window acme.pane shellKeys)" || fail "provider restore: shell keys read failed"
expect "provider restore: pane identity and capabilities are green" '["acme.pane","configure,idle,manifest,settings,surfaces"]' pane_identity_shell "$restored_manifest" "$restored_keys"

expect "configure control baseline writes every view" ok ipc smoke invokeInstance window acme.pane setLabel before-control
expect "configure control baseline opens Settings" ok ipc shell summon window vgs.settings '{"plugin":"acme.pane"}'
expect_poll "configure control baseline is green" '["before-control","before-control","before-control","before-control"]' four_view_labels
restart_control_shell pane-configure-target shell/Core/PluginLogic.js 'return kind === "pane" ? settingTargets(config, manifest) : [settingTargetOf(kind)];' 'return kind === "pane" ? ["plugins"] : [settingTargetOf(kind)];'
expect "control: plugins-only configure shell summons" ok ipc shell summon window acme.panehost '{}'
expect "control: plugins-only configure mounts the pane" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
expect "control: Settings opens the pane plugin page" ok ipc shell summon window vgs.settings '{"plugin":"acme.pane"}'
expect "control: the pane edit is accepted by the mutant" ok ipc smoke invokeInstance window acme.pane setLabel plugins-only
expect_poll "control: plugins-only pane configure breaks four-view readback" '["plugins-only","before-control","plugins-only","before-control"]' four_view_labels
restore_product_shell restored-configure
expect "configure restore: the host summons again" ok ipc shell summon window acme.panehost '{}'
expect "configure restore: mounting the pane is allowed" ok ipc smoke invokeInstance window acme.panehost mountPane 'acme.pane'
expect "configure restore: Settings opens the pane plugin page" ok ipc shell summon window vgs.settings '{"plugin":"acme.pane"}'
expect "configure restore: pane edit is accepted" ok ipc smoke invokeInstance window acme.pane setLabel restored-configure
expect_poll "configure restore: four-view readback is green" '["restored-configure","restored-configure","restored-configure","restored-configure"]' four_view_labels

cp -- "$pane_saved" "$pane_file.tmp" && mv -T -- "$pane_file.tmp" "$pane_file"
rm -rf -- "${home:?}/.config/vgs/plugins/acme.panehost" "${home:?}/.config/vgs/plugins/acme.pane" "${home:?}/.config/vgs/plugins/acme.pane-alt" "${home:?}/.config/vgs/plugins/acme.panehost2"
expect "rescan after removing the pane fixtures answers ok" ok ipc shell rescanPlugins
expect_poll "the pane fixture is gone after restore" absent plugin_enabled acme.pane
