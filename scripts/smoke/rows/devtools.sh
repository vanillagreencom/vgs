# Dev Tools, vgs.devtools. The plugin runs over stand-ins in the shell's
# own PATH directory: a mise whose installs are one key per line of a file
# the row writes, a docker and a podman that hold no container, and a
# pacman that owns no file, so every probe the engine and the core's
# commands make reaches a stand-in or reads the host's PATH. The row picks
# an agent whose command that PATH does not hold, so it lists absent on any
# host. rows/tui.sh's stand-in terminal records the argv of every run and
# runs the real presenter with no terminal behind it, where the engine
# refuses to change anything, so a run ends at once.
# Rows: the service publishes the status its manifest declares; IPC open
# summons the panel, which draws the VGS section and every catalog section
# from the published catalog; a click on the agent's Install records the
# install TUI's argv, and the list is read again once that run ended; the
# panel's switch writes writeLaunchers, whose launcher verb writes and then
# removes the agent's launcher; the VGS section lists a fixture's missing
# requirement once the core's scan reports it, and its Install raises the
# core's requirement notice; the doctor capability answers for the core's
# commands and refuses a disabled or unknown owner; the Settings page reads
# the status rows back; and, as the controls, a copy of the plugin whose
# service ignores a run's end and a change of the scan's missing commands
# leaves the list as it was after each.
set -euo pipefail
dev_state="$sandbox/devtools-mise"
mkdir -p "$dev_state"
: >"$dev_state/installed"
# One global mise tool no row declares, for the Other mise tools section.
echo "github:acme/extra" >"$dev_state/installed"
# The stand-in mise answers what list, launchers and pkg check ask: its
# version, `ls --json` and `ls --global --json` from the installed keys,
# `which` for no command and `outdated --json` with no update.
cat >"$shim/mise" <<EOF
#!/usr/bin/env bash
case "\$1" in
  --version) echo "2026.9.9 linux-x64 (stub)" ;;
  ls)
    first=1
    printf '{'
    while IFS= read -r key; do
      [[ -n \$key ]] || continue
      [[ \$first == 1 ]] || printf ','
      first=0
      printf '"%s":[{"version":"1.0.0","installed":true,"active":true}]' "\$key"
    done <"$dev_state/installed"
    printf '}\n' ;;
  which) printf 'mise ERROR %s is not a mise bin. Perhaps you need to install it first.\n' "\$2" >&2; exit 1 ;;
  outdated) echo '{}' ;;
  *) exit 0 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$shim/docker"
printf '#!/bin/sh\nexit 0\n' >"$shim/podman"
printf '#!/bin/sh\necho "error: No package owns $2" >&2\nexit 1\n' >"$shim/pacman"
chmod 755 "$shim/mise" "$shim/docker" "$shim/podman" "$shim/pacman"
requires_dir="$home/.config/vgs/plugins/acme.requires"
mkdir -p "$requires_dir"
cp -R "$repo/scripts/smoke/fixtures/plugins/acme.requires/." "$requires_dir/"
shell_path="$(tr '\0' '\n' <"/proc/$shell_qs_pid/environ" | sed -n 's/^PATH=//p')"
[[ -n $shell_path ]] || fail "the shell's PATH is unreadable"
in_shell_env() { "${shell_env[@]}" PATH="$shell_path" "$@"; }

# The first agent built for this machine whose command the shell's PATH
# does not hold and that has no exec file, as `<id>\t<name>\t<command>\t<key>`.
absent_agent() { node - "$repo" "$shell_path" <<'JS'
const fs = require("fs"), path = require("path");
const [repo, PATH] = process.argv.slice(2);
const Catalog = require(path.join(repo, "bin/lib/qml-library.js")).load(path.join(repo, "shell/plugins/vgs.devtools/CatalogLogic.js"));
const catalog = JSON.parse(fs.readFileSync(path.join(repo, "shell/plugins/vgs.devtools/catalog.json"), "utf8"));
const machine = process.arch === "arm64" ? "aarch64" : "x86_64";
const onPath = command => PATH.split(":").some(dir => { try { fs.accessSync(path.join(dir, command), fs.constants.X_OK); return true; } catch (e) { return false; } });
const row = catalog.agents.find(r => r.exec === undefined && Catalog.availableOn(r, machine) && !onPath(r.command));
if (row === undefined) process.exit(1);
console.log([row.id, row.name, row.command, Catalog.specKey(row.package)].join("\t"));
JS
}
IFS=$'\t' read -r agent_id agent_name agent_command agent_key < <(absent_agent) || fail "no agent's command is absent from the shell's PATH"

devtools() { ipc vgs.devtools invoke "$1" "${2:-}"; }
# Its arguments as one JSON list, written as row_texts writes one.
texts() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1:], ensure_ascii=False))' "$@"; }
dev_lent() { ipc shell lent | python3 -c 'import json,sys; r=json.load(sys.stdin)["status"].get("vgs.devtools"); print(json.dumps(r if r is None else r["keys"]))'; }
panel_shown() { [[ $(ipc smoke instanceGeometry panel vgs.devtools) != absent ]] && echo shown || echo hidden; }
section_titles() { ipc smoke itemTexts panel vgs.devtools SectionHeader | python3 -c 'import json,sys; print(json.dumps([t[0] for t in json.load(sys.stdin)]))'; }
# The texts the first row drawing NAME draws, as JSON, or null.
row_texts() { ipc smoke itemTexts panel vgs.devtools ToolRow | python3 -c 'import json,sys; r=[t for t in json.load(sys.stdin) if t and t[0] == sys.argv[1]]; print(json.dumps(r[0] if r else None, ensure_ascii=False))' "$1"; }
# The VGS row's texts with its error line, which names the sandbox's
# path, read as `error=<key>`.
vgs_texts() { row_texts VGS | python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps(None if r is None else [t if not t.startswith("method=") else "error=" + t.split(" ")[0] for t in r], ensure_ascii=False))'; }
# The key the recorded run carries, then the recorded argv from the script
# on, as JSON, or `absent`.
recorded_tail() { recorded | python3 -c 'import json,sys
t=sys.stdin.read().strip()
if t == "absent": print(t); sys.exit()
w=json.loads(t); at=w.index("--record")
print(json.dumps([w[at + 1]] + w[w.index("--", at) + 1:]))'; }
# The ended record the presenter of KEY's last run wrote, by file name, or
# `none`: the presenter writes it when it exits and keeps only the newest.
ended_record() { local stem="${1/\//@}" f found=none; for f in "$rt_dir/vgs/tui/$stem@"*.ended.json; do [[ -e $f ]] && found="${f##*/}"; done; echo "$found"; }
# ended_record_moved KEY BEFORE: `moved` once KEY's ended record is another
# than BEFORE, so the presenter of the run a click started has exited and
# expect_run_end times only the core's reading of it.
ended_record_moved() { [[ $(ended_record "$1") != "$2" ]] && echo moved || echo waiting; }
# reveal_row NAME: the panel scrolled so the first row drawing NAME sits
# near its top, from where the row's box lies with the list at its start.
reveal_row() {
  local box y
  ipc smoke scrollTo panel vgs.devtools 0 >/dev/null || return
  box="$(ipc smoke scopedWindowGeometry panel vgs.devtools ToolRow "$1" Label "$1")" || return
  [[ $box == \[* ]] || { echo "absent"; return; }
  y="$(python3 -c 'import json,sys; print(max(0, int(json.loads(sys.argv[1])[1]) - 200))' "$box")" || return
  ipc smoke scrollTo panel vgs.devtools "$y" >/dev/null && echo revealed
}
scroll_bottom() { local r; r="$(ipc smoke scrollTo panel vgs.devtools 100000)" || return; [[ $r == \[* ]] && echo scrolled || echo "$r"; }
launcher_state() { [[ -f $home/.local/bin/$1 ]] && sed -n 2p "$home/.local/bin/$1" || echo absent; }

expect "rescan after adding the requirement fixture answers ok" ok ipc shell rescanPlugins
expect_poll "the requirement fixture is discovered" True plugin_known acme.requires
expect "enabling Dev Tools is allowed" ok ipc shell setPluginEnabled vgs.devtools true
expect_poll "the Dev Tools service is built" True record_exists vgs.devtools
expect_poll "the service publishes every status its manifest declares" '["catalog", "checks", "installed", "mise", "missingRequirements", "outdated"]' dev_lent

# The panel: IPC open summons it, and it draws the published catalog.
expect "IPC open summons the panel" ok devtools open
expect_poll "the panel is shown" shown panel_shown
expect_poll "the panel draws the VGS section and every catalog section in order" \
  '["VGS", "Agents", "Apps", "CLI tools", "Languages", "Editors", "Databases", "Terminals", "Other mise tools"]' section_titles
expect_poll "the VGS row names the version and the install method it could not read" \
  "$(texts VGS "$(cat "$repo/VERSION") · Unknown install" error=method=unknown Unknown)" vgs_texts
expect_poll "the absent agent draws Not installed and Install" "$(texts "$agent_name" "Not installed" Install)" row_texts "$agent_name"
expect_poll "the other mise tool draws its version and its actions" "$(texts github:acme/extra 1.0.0 Update Remove)" row_texts github:acme/extra

# A click on Install opens the install TUI with the row's id; the list is
# read again when the run ends, so the key mise now holds shows.
echo "$agent_key" >>"$dev_state/installed"
expect "no list runs before a trigger" "$(texts "$agent_name" "Not installed" Install)" row_texts "$agent_name"
install_before="$(ended_record vgs.devtools/install)"
forget_record
expect "the agent's row scrolls into view" revealed reveal_row "$agent_name"
click_scoped_in vgs:panel panel vgs.devtools ToolRow "$agent_name" Button Install || fail "the click on the agent's Install failed"
expect_poll "the click hands the install TUI the row's id" "$(words vgs.devtools/install tui/install.sh "$agent_id")" recorded_tail
expect_poll "the install run's presenter exits" moved ended_record_moved vgs.devtools/install "$install_before"
expect_run_end "the install run ends" vgs.devtools/install
expect_poll "the list read after the run shows the agent installed" "$(texts "$agent_name" 1.0.0 mise Update Remove)" row_texts "$agent_name"

# The panel's switch writes writeLaunchers; the service runs the launcher
# verb it picks, so the agent's launcher is written and then removed.
expect "the panel scrolls to its switch" scrolled scroll_bottom
click_in vgs:panel panel vgs.devtools Switch "Write launchers" || fail "the click on the launcher switch failed"
expect_poll "turning launchers on writes the agent's launcher" "# vgs.devtools launcher" launcher_state "$agent_command"
expect "the panel scrolls to its switch again" scrolled scroll_bottom
click_in vgs:panel panel vgs.devtools Switch "Write launchers" || fail "the second click on the launcher switch failed"
expect_poll "turning launchers off removes it" absent launcher_state "$agent_command"

# The VGS section: a plugin's missing requirement, listed once enabling
# the fixture moves the core scan's missing commands, which the service
# follows through the doctor capability with no refresh. The fixture marks
# it optional, so enabling it raises no core requirement notice. Install
# raises the core's notice for it, which Escape closes.
expect "a refresh answers ok" ok devtools refresh
expect "enabling the requirement fixture is allowed" ok ipc shell setPluginEnabled acme.requires true
has_fixture_missing() { ipc smoke doctorMissing service vgs.devtools | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d.get("acme.requires"), "core" in d]))'; }
expect_poll "the doctor capability reports the fixture's missing command and the core's list" '[["vgs-smoke-devtool"], true]' has_fixture_missing
expect_poll "the VGS section lists the fixture's missing requirement with Install" \
  "$(texts vgs-smoke-devtool "acme.requires · A command no sandbox has, which a package names" Missing Optional Install)" row_texts vgs-smoke-devtool
expect "the requirement's row scrolls into view" revealed reveal_row vgs-smoke-devtool
click_scoped_in vgs:panel panel vgs.devtools ToolRow vgs-smoke-devtool Button Install || fail "the click on the requirement's Install failed"
expect_poll "Install raises the core's notice for the fixture's command" '["acme.requires", ["vgs-smoke-devtool"], ["vgs-smoke-devtool"], false]' notice_shown
expect_poll "the notice maps" 1 layer_count vgs:notice
expect_poll "the notice holds the keyboard" true ipc smoke noticeFocused
type_keys -k Escape || fail "sending Escape to the notice failed"
expect_poll "Escape closes the notice" 0 layer_count vgs:notice
# The doctor capability's other owners: the core's commands the scan
# finds, and a disabled or unknown plugin.
scans="$(log_lines 'plugins: scan complete changed=')" || fail "the instance log is unreadable before the core request"
expect "the doctor capability takes a core command and scans first" ok ipc smoke doctorOffer service vgs.devtools core git
expect_log "the request's scan ends" "$((scans + 1))" 'plugins: scan complete changed='
expect "a core command the scan finds raises no notice" 0 layer_count vgs:notice
expect "the doctor capability refuses a command the core does not declare" "refused: requirement=vgs-smoke-nope reason=undeclared" ipc smoke doctorOffer service vgs.devtools core vgs-smoke-nope
expect "the doctor capability refuses a disabled plugin" "refused: owner=acme.status reason=disabled" ipc smoke doctorOffer service vgs.devtools acme.status token
expect "the doctor capability refuses an unknown owner" "refused: owner=acme.gone reason=unknown" ipc smoke doctorOffer service vgs.devtools acme.gone x

# Settings reads the status rows back, read-only.
installed_count() { in_shell_env node "$repo/shell/plugins/vgs.devtools/bin/devtools" --tree "$repo" list --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for rows in d["sections"].values() for r in rows if r["installed"] is True) + sum(1 for r in d["other"] if r["installed"] is True))'; }
missing_count() { in_shell_env "$repo/bin/vgsh" doctor --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for rows in [d["core"]] + list(d["plugins"].values()) for r in rows if r["state"] == "missing"))'; }
expect "enabling Settings is allowed" ok ipc shell setPluginEnabled vgs.settings true
expect_poll "the Settings service is built" True record_exists vgs.settings
expect "Settings opens the Dev Tools page" ok ipc vgs.settings invoke open '{"plugin":"vgs.devtools"}'
# The sandbox's tree is no install VGS knows, so the self-status the
# service reads reports its method unknown, and Checks names that.
checks_text="vgsh self status failed: method=unknown path=$(readlink -f -- "$repo"); a count a failed check feeds keeps its last answer"
if dev_installed="$(installed_count)" && dev_missing="$(missing_count)"; then
  expect_poll "the manager row carries the published status" \
    "$(python3 -c 'import json,sys; print(json.dumps([["mise", "reported", {"tone": "ok", "text": "2026.9.9"}, "success", "vgsh pkg run install mise"], ["Checks", "reported", {"tone": "warning", "text": sys.argv[3]}, "warning", ""], ["Tools installed", "reported", int(sys.argv[1]), "", ""], ["Updates available", "reported", 0, "", ""], ["VGS requirements missing", "reported", int(sys.argv[2]), "", "vgsh doctor"]]))' "$dev_installed" "$dev_missing" "$checks_text")" status_of vgs.devtools
  expect_poll "the page draws each status row, the catalog data not" \
    "$(python3 -c 'import json,sys; print(json.dumps([["mise", "2026.9.9", "Installs, updates and removes every tool the Dev Tools panel lists", "vgsh pkg run install mise"], ["Checks", sys.argv[3], "Whether every query the service runs answered; a count a failed query feeds keeps its last answer"], ["Tools installed", sys.argv[1]], ["Updates available", "0", "Tools mise can update, as mise outdated counts them"], ["VGS requirements missing", sys.argv[2], "Commands VGS or an enabled plugin runs that are not on PATH", "vgsh doctor"]]))' "$dev_installed" "$dev_missing" "$checks_text")" drawn_status
  expect "no Dev Tools status row takes an edit" '[[],[],[],[],[]]' ipc smoke statusRowInputs panel vgs.settings
else
  fail "the list or the doctor report is unreadable for the status counts"
fi
expect "disabling Settings after its rows is allowed" ok ipc shell setPluginEnabled vgs.settings false

# Control: a copy of the plugin whose service ignores a run's end, in the
# user directory, where it hides the shipped one. A run of its install TUI
# ends and the list stays as it was.
control_dir="$home/.config/vgs/plugins/vgs.devtools"
cp -R "$repo/shell/plugins/vgs.devtools" "$control_dir"
relist_line='        if (finished.length > 0) trigger("tui");'
scan_line='        trigger("scan");'
if [[ $(grep -c -F -- "$relist_line" "$control_dir/Service.qml") == 1 && $(grep -c -F -- "$scan_line" "$control_dir/Service.qml") == 1 ]]; then
  python3 -c 'import sys; p, a, b = sys.argv[1:]; text = open(p).read(); open(p, "w").write(text.replace(a, "        if (false) trigger(\"tui\");").replace(b, "        if (false) trigger(\"scan\");"))' "$control_dir/Service.qml" "$relist_line" "$scan_line"
  expected_errors+=('plugins: hidden by a higher-precedence plugin with the same id: .*vgs\.devtools')
  scans="$(log_lines 'plugins: scan complete changed=true')" || fail "the instance log is unreadable before the control copy"
  expect "rescan after adding the control copy answers ok" ok ipc shell rescanPlugins
  expect_log "the rescan publishes the control copy" "$((scans + 1))" 'plugins: scan complete changed=true'
  expect_poll "the control copy's service publishes" '["catalog", "checks", "installed", "mise", "missingRequirements", "outdated"]' dev_lent
  grep -vxF -- "$agent_key" "$dev_state/installed" >"$dev_state/installed.next" || true
  mv -f -- "$dev_state/installed.next" "$dev_state/installed"
  expect "the control's summon answers ok" ok devtools open
  expect_poll "a refresh lists the agent absent again" "$(texts "$agent_name" "Not installed" Install)" row_texts "$agent_name"
  echo "$agent_key" >>"$dev_state/installed"
  install_before="$(ended_record vgs.devtools/install)"
  expect "the control's agent row scrolls into view" revealed reveal_row "$agent_name"
  forget_record
  click_scoped_in vgs:panel panel vgs.devtools ToolRow "$agent_name" Button Install || fail "the control's click on Install failed"
  expect_poll "the control's click hands the install TUI the row's id" "$(words vgs.devtools/install tui/install.sh "$agent_id")" recorded_tail
  expect_poll "the control's install run's presenter exits" moved ended_record_moved vgs.devtools/install "$install_before"
  expect_run_end "the control's install run ends" vgs.devtools/install
  # expect_poll's own window, 5 s at 0.2 s: the shipped service's list
  # shows the agent installed within it.
  relisted=no
  for _ in $(seq 1 25); do
    if [[ $(row_texts "$agent_name") == *'"1.0.0"'* ]]; then relisted=yes; break; fi
    sleep 0.2
  done
  if [[ $relisted == no ]]; then ok "the control copy leaves the list as it was after the run"; else fail "the control copy listed again after the run"; fi
  expect "disabling the requirement fixture under the control copy is allowed" ok ipc shell setPluginEnabled acme.requires false
  expect_poll "the doctor capability drops the disabled fixture" '[null, true]' has_fixture_missing
  # expect_poll's own window again: the shipped service lists the
  # requirements anew within it and drops the row.
  dropped=no
  for _ in $(seq 1 25); do
    if [[ $(row_texts vgs-smoke-devtool) == null ]]; then dropped=yes; break; fi
    sleep 0.2
  done
  if [[ $dropped == no ]]; then ok "the control copy keeps the disabled fixture's requirement"; else fail "the control copy listed the requirements again after the scan changed"; fi
  rm -rf -- "$control_dir"
  expect "rescan after removing the control copy answers ok" ok ipc shell rescanPlugins
else
  fail "the control's lines occur once each in the Dev Tools service"
fi

expect "hiding the panel answers ok" ok ipc shell hide panel vgs.devtools
expect "disabling Dev Tools is allowed" ok ipc shell setPluginEnabled vgs.devtools false
expect_poll "a disabled Dev Tools holds no status record" null dev_lent
expect "disabling the requirement fixture is allowed" ok ipc shell setPluginEnabled acme.requires false
rm -f -- "$shim/mise" "$shim/docker" "$shim/podman" "$shim/pacman"
