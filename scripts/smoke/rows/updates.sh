# vgs.updates service: one owner runs bin/check, publishes the cached
# snapshot as plugin status, reports source failures, and keeps manager rows
# readable for Settings. Stubs live in scripts/smoke/fixtures/updates-bin.
set -euo pipefail
updates_dir="$home/.config/vgs/plugins/vgs.updates"
updates_state="$home/.local/state/vgs/updates-smoke"
if ! command -v unshare >/dev/null 2>&1; then
  printf 'qml-smoke: status=not-measured missing=unshare\n'
  exit 77
fi
mkdir -p "$updates_dir" "$updates_state"
cp -R "$repo/shell/plugins/vgs.updates/." "$updates_dir/"
cp -- "$repo/scripts/smoke/fixtures/updates-bin/"* "$shim/"
updates_cleanup() { rm -f -- "$shim/checkupdates" "$shim/pacman" "$shim/paru" "$shim/flatpak" "$shim/mise" "$shim/git" "$shim/xdg-terminal-exec"; }
trap updates_cleanup RETURN
updates_vgsh="$repo/bin/vgsh"
expected_errors+=('plugins: hidden by a higher-precedence plugin with the same id: vgs\.updates')
updates_status() { ipc vgs.updates invoke status ''; }
updates_pending() { updates_status | python3 -c 'import json,sys; print(json.load(sys.stdin)["pending"])'; }
updates_state_text() { updates_status | python3 -c 'import json,sys; print(json.load(sys.stdin)["checkState"]["text"])'; }
updates_sources() { updates_status | python3 -c 'import json,sys; print(json.dumps([[s["source"], s["count"], s["error"]] for s in json.load(sys.stdin)["sources"]]))'; }
updates_source_names() { updates_status | python3 -c 'import json,sys; print(json.dumps([s["source"] for s in json.load(sys.stdin)["sources"]]))'; }
updates_source_detail() { updates_status | python3 -c 'import json,sys; row=[s for s in json.load(sys.stdin)["sources"] if s["source"]==sys.argv[1]][0]; print(json.dumps([row["count"], len(row["packages"]), row.get("more", 0)]))' "$1"; }
updates_failed_visible() { updates_status | python3 -c 'import json,sys; rows=json.load(sys.stdin)["sources"]; print(any(r["source"] == "pacman" and r["count"] is None and r["error"] for r in rows))'; }
updates_status_rows() { settings_rows | python3 -c 'import json,sys; rows=[p for p in json.load(sys.stdin) if p["id"]=="vgs.updates"][0]["status"]; print(json.dumps([[r["key"], r["report"]] for r in rows]))'; }
call_count() { python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); print(0 if not p.exists() else len([l for l in p.read_text().splitlines() if l.startswith(sys.argv[2])]))' "$updates_state/calls.log" "$1"; }
write_controlled_vgsh() {
  local target="$1" os_release="$2" path_value="$3"
  mkdir -p "$(dirname -- "$target")" "$(dirname -- "$target")/lib"
  ln -sf -- "$repo/bin/lib/qml-library.js" "$(dirname -- "$target")/lib/qml-library.js"
  cat >"$target" <<EOF
#!/usr/bin/env bash
if [[ \$1 == pkg && \$2 == check ]]; then
  exec unshare -rm "$path_value/bash" -c 'mount --bind "\$1" /etc/os-release && shift && export PATH="\$1" HOME="\$2" XDG_RUNTIME_DIR="\$3" XDG_STATE_HOME="\$4" && shift 4 && exec "\$@"' bash "$os_release" "$path_value" "$home" "$rt_dir" "$home/.local/state" "$updates_vgsh" "\$@"
fi
exec "$updates_vgsh" "\$@"
EOF
  chmod 755 "$target"
}
patch_service_vgsh() { python3 - "$updates_dir/Service.qml" "$1" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
needle = "    readonly property string vgshPath:"
replaced = 0
for i, line in enumerate(lines):
    if line.startswith(needle):
        lines[i] = '    readonly property string vgshPath: "' + sys.argv[2] + '"'
        replaced += 1
assert replaced == 1
path.write_text("\n".join(lines) + "\n")
PY
}
controlled_path="$updates_state/controlled-bin"
mkdir -p "$controlled_path"
for tool in bash node python3 flock readlink dirname sleep seq env mount mkdir cat wc sed head rm date; do ln -sf -- "$(command -v "$tool")" "$controlled_path/$tool"; done
for tool in pacman checkupdates paru flatpak mise git; do ln -sf -- "$shim/$tool" "$controlled_path/$tool"; done
arch_os="$updates_state/os-release-arch"
cat >"$arch_os" <<'OS'
ID=arch
OS
controlled_vgsh="$updates_state/arch/bin/vgsh"
write_controlled_vgsh "$controlled_vgsh" "$arch_os" "$controlled_path"
cat >"$controlled_vgsh" <<EOF
#!/usr/bin/env bash
if [[ \$1 == pkg && \$2 == check ]]; then
  now=\$(date +%s%3N)
  if ! out=\$(PATH="$controlled_path" XDG_STATE_HOME="$home/.local/state" checkupdates 2>err); then
    printf '[{"source":"pacman","count":null,"packages":[],"checkedAt":%s,"error":"exit=1"}]\n' "\$now"
    rm -f err
    exit 0
  fi
  rm -f err
  pac_count=\$(printf '%s\n' "\$out" | sed '/^$/d' | wc -l)
  python3 - "\$now" "\$pac_count" <<'PY'
import json, sys
now, pac_count = int(sys.argv[1]), int(sys.argv[2])
packages = [{"name": "pkg-%04d" % i, "old": "1.0", "new": "2.0"} for i in range(pac_count)]
rows = [{"source":"pacman","count":int(pac_count),"packages":packages,"checkedAt":now,"error":None}]
rows += [{"source":"aur","count":1,"packages":[{"name":"helper-git","old":"1","new":"2"}],"checkedAt":now,"error":None}]
rows += [{"source":"flatpak","count":1,"packages":[{"name":"org.example.App","old":None,"new":"stable"}],"checkedAt":now,"error":None}]
rows += [{"source":"mise","count":1,"packages":[{"name":"node","old":"1","new":"2"}],"checkedAt":now,"error":None}]
print(json.dumps(rows))
PY
  exit 0
fi
exec "$updates_vgsh" "\$@"
EOF
chmod 755 "$controlled_vgsh"
patch_updates_manifest() { python3 - "$updates_dir/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["tui"] = {"finish": {"script": "tui/finish.sh", "title": "Updates smoke", "size": "default", "presentation": "plain", "entry": {"label": "Updates smoke", "icon": "terminal", "group": "Smoke"}}}
with open(path, "w") as out:
    json.dump(doc, out)
PY
mkdir -p "$updates_dir/tui"
cat >"$updates_dir/tui/finish.sh" <<'TUI'
#!/usr/bin/env bash
set -euo pipefail
gate="${XDG_STATE_HOME:?}/vgs/updates-smoke/tui-gate"
while [[ ! -e $gate ]]; do sleep 0.05; done
TUI
chmod 755 "$updates_dir/tui/finish.sh"
}
install_terminal_stub() {
  cat >"$shim/xdg-terminal-exec" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 && $1 != -- ]]; do shift; done
shift
presenter=()
while [[ $# -gt 0 && $1 != -- ]]; do presenter+=("$1"); shift; done
"${presenter[@]}" "$@" </dev/null >/dev/null 2>&1
EOF
  chmod 755 "$shim/xdg-terminal-exec"
}
patch_updates_manifest
install_terminal_stub
patch_service_vgsh "$controlled_vgsh"
expect "rescan after adding the updates plugin copy answers ok" ok ipc shell rescanPlugins
expect_poll "the updates plugin copy is discovered" True plugin_known vgs.updates
expect "enabling the updates service is allowed" ok ipc shell setPluginEnabled vgs.updates true
expect_poll "the updates service is built" True record_exists vgs.updates
expect_poll "the updates service uses the controlled vgsh" "\"$controlled_vgsh\"" ipc smoke readInstance service vgs.updates vgshPath
expect_poll "the first check publishes every counted source" 12 updates_pending
expect_poll "the sources include the package, VGS, plugin and theme rows" '[["pacman", 2, null], ["aur", 1, null], ["flatpak", 1, null], ["mise", 1, null], ["vgs", 1, null], ["plugins", 6, null], ["themes", 0, null]]' updates_sources
expect "reading status does not start a second check" 1 call_count checkupdates
expect "a second status read still does not start a check" 1 call_count checkupdates
expect "the Settings panel opens for updates rows" ok ipc shell summon panel vgs.settings '{}'
expect_poll "the Settings panel is open for updates rows" open settings_open
expect "the Settings window opens the updates page" ok ipc smoke invokeInstance panel vgs.settings openPlugin vgs.updates
expect_poll "the Settings status rows are reported" '[["pending", "reported"], ["lastCheck", "reported"], ["checkState", "reported"]]' updates_status_rows
touch "$updates_state/many-checkupdates"
expect "a large on-demand check starts" started ipc vgs.updates invoke check ''
expect_poll "large package details are bounded in shared status" '[1400, 12, 1388]' updates_source_detail pacman
expect_poll "large counts stay complete in shared status" 1410 updates_pending
rm -f -- "$updates_state/many-checkupdates"
: >"$updates_state/fail-checkupdates"
expect "an on-demand check starts" started ipc vgs.updates invoke check ''
expect_poll "a failing source stays visible in checkState" 'System: exit=1' updates_state_text
expect_poll "the failing source is present in sources" True updates_failed_visible
rm -f -- "$updates_state/fail-checkupdates" "$updates_state/tui-gate"
expect_poll "the TUI startup probe has answered" false lent tui.probing
if [[ "$(lent tui.launcher)" == '"missing"' ]]; then
  expect "a request on a host without a terminal refreshes the launcher" "refused: tui=vgs.updates/finish reason=launcher-missing" ipc shell openTui vgs.updates/finish
fi
expect_poll "the launcher state is present for the updates TUI" '"present"' lent tui.launcher
expect_poll "the launcher refresh is idle" false lent tui.probing
before="$(call_count checkupdates)"
expect "opening the updates TUI starts the run" ok ipc shell openTui vgs.updates/finish
sleep 0.2
expect "a running TUI does not trigger a check" "$before" call_count checkupdates
touch "$updates_state/tui-gate"
expect_poll "an ended TUI triggers exactly one check" "$((before + 1))" call_count checkupdates
updates_control="$home/.config/vgs/plugins/acme.updates-control"
mkdir -p "$updates_control"
cat >"$updates_control/manifest.json" <<'JSON'
{ "schemaVersion": 1, "id": "acme.updates-control", "name": "Updates control", "version": "0.1.0", "author": "acme", "description": "control that checks per widget", "kinds": ["bar-widget"], "entryPoints": { "bar-widget": "Widget.qml" }, "defaultSection": "right" }
JSON
cat >"$updates_control/Widget.qml" <<EOF
import QtQuick
import qs.Ui
import Quickshell
import Quickshell.Io
BarWidget {
    property var shell: null
    Component.onCompleted: check.running = true
    Process {
        id: check
        command: ["$updates_dir/bin/check", "--vgsh", "$updates_vgsh"]
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }
}
EOF
expect "rescan after adding the per-widget control answers ok" ok ipc shell rescanPlugins
control_output=SMOKE-UPDATES-CONTROL
expect "the nested compositor adds a monitor for the updates control" ok hypr output create headless "$control_output"
expect_poll "the updates control monitor gets a bar" "$((monitors + 1))" bar_count
before="$(call_count checkupdates)"
expect "enabling the per-widget control is allowed" ok ipc shell setPluginEnabled acme.updates-control true
control_widgets() { ipc shell built | python3 -c 'import json,sys; print(sum(1 for rows in json.load(sys.stdin).values() for r in rows if r["id"] == "acme.updates-control"))'; }
control_widgets_gt_one() { [[ $(control_widgets) -gt 1 ]] && echo True || echo False; }
expect_poll "the per-widget control is built on more than one bar" True control_widgets_gt_one
control_target() { echo $(( before + $(control_widgets) )); }
expect_poll "the per-widget control proves the one-process assertion would fail" "$(control_target)" call_count checkupdates
expect "disabling the per-widget control is allowed" ok ipc shell setPluginEnabled acme.updates-control false
expect "the nested compositor removes the updates control monitor" ok hypr output remove "$control_output"
expect_poll "the updates control monitor's bar is gone" "$monitors" bar_count
no_manager_vgsh="$updates_state/bin/vgsh"
unknown_os="$updates_state/os-release-unknown"
no_manager_path="$updates_state/no-manager-bin"
mkdir -p "$no_manager_path" "$updates_state/bin/lib"
ln -sf -- "$(command -v bash)" "$no_manager_path/bash"
ln -sf -- "$node_bin" "$no_manager_path/node"
ln -sf -- "$(command -v flock)" "$no_manager_path/flock"
ln -sf -- "$(command -v readlink)" "$no_manager_path/readlink"
ln -sf -- "$(command -v dirname)" "$no_manager_path/dirname"
cat >"$unknown_os" <<'OS'
ID=opensuse-tumbleweed
OS
write_controlled_vgsh "$no_manager_vgsh" "$unknown_os" "$no_manager_path"
cat >"$no_manager_vgsh" <<EOF
#!/usr/bin/env bash
if [[ \$1 == pkg && \$2 == check ]]; then printf '[]\n'; exit 0; fi
exec "$updates_vgsh" "\$@"
EOF
chmod 755 "$no_manager_vgsh"
patch_service_vgsh "$no_manager_vgsh"
expect "rescan after switching updates to no-manager vgsh answers ok" ok ipc shell rescanPlugins
expect_poll "the rebuilt updates service is built" True record_exists vgs.updates
expect_poll "with real vgsh detecting no manager, the service publishes only VGS rows" '["vgs", "plugins", "themes"]' updates_source_names
expect "disabling the updates service is allowed" ok ipc shell setPluginEnabled vgs.updates false
expect "the Settings panel closes after updates rows" ok ipc shell hide panel vgs.settings
updates_cleanup
