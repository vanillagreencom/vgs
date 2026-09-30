#!/usr/bin/env bash
# Controls for the requirement reports of bin/vgsh: the offer `plugin add`
# ends with, `plugin requirements`, `doctor`, `plugin rescan` and the rescan
# `vgsh pkg run` asks a running shell for once its steps end. Plugins come
# from local bare repositories. Detection reads /etc/os-release, so every
# row runs under `unshare -rm` with an Arch os-release bound over it, and
# the managers it finds are stubs ahead of the host's PATH: pacman and paru
# record their argv, sudo records its own and runs the rest, and qs records
# each IPC call a lock file naming this suite's pid sends. No row reaches a
# real package manager, a real elevation command or a live shell. Without
# user namespaces or script(1) the suite exits 77.
#
# Each control runs a row against a copy of the tree with one rule removed
# from bin/vgsh, bin/vgsh-pkg or bin/vgsh-plugin-judge, and that row must
# fail.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
for tool in script unshare; do
  command -v "$tool" >/dev/null || { echo "test-vgsh-requirements: status=not-measured missing=$tool"; exit 77; }
done
if ! unshare -rm true 2>/dev/null; then
  echo "test-vgsh-requirements: status=not-measured missing=user-namespaces"
  exit 77
fi
script_bin="$(command -v script)"

# Stubs. Each writes one line per call to $LOG: its name, then each argument
# in brackets. pacman fails with 7 when its first argument is $STUB_FAIL.
stubs="$tmp/stubs"; mkdir -p "$stubs"
record='printf "%s" "${0##*/}" >>"$LOG"; for a; do printf " [%s]" "$a" >>"$LOG"; done; echo >>"$LOG"'
stub() { # NAME BODY
  printf '#!/bin/sh\n%s\n%s\n' "$record" "$2" >"$stubs/$1"
  chmod +x "$stubs/$1"
}
# sudo -k and the keepalive's -n take no command to run.
stub sudo 'case "$1" in -k) exit 0 ;; -n) shift ;; esac
exec "$@"'
stub pacman '[ "${STUB_FAIL:-}" != "$1" ] || exit 7'
stub paru ''
stub flatpak ''
stub nix ''
stub qs 'echo ok'
# The qs the usage rows reach through $tmp, first on their PATH: it records
# its arguments in $STUB_ARGS and answers $STUB_REPLY.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >"${STUB_ARGS:-/dev/null}"\nprintf "%%s\\n" "${STUB_REPLY:-ok}"\n' >"$tmp/qs"
chmod +x "$tmp/qs"

os_release="$tmp/os-release"; printf 'NAME="Arch Linux"\nID=arch\n' >"$os_release"
nixos_release="$tmp/os-release-nixos"; printf 'NAME=NixOS\nID=nixos\n' >"$nixos_release"
rt_live="$tmp/rt-live"; mkdir -p "$rt_live"; printf '%s\n' "$$" >"$rt_live/vgsh.lock"
log="$tmp/log"
# The doctor rows' PATH: the stubs, then only what bin/vgsh, the scan and
# the judge run, so the core's other commands are missing on every host.
tools="$tmp/tools"; mkdir -p "$tools"
for tool in bash readlink dirname python3; do
  found="$(command -v "$tool")" || { echo "test-vgsh-requirements: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$(readlink -f -- "$found")" "$tools/$tool"
done
ln -s -- "$node_bin" "$tools/node"

# req BIN MODE ANSWER CFG RT [VAR=VALUE...] -- ARGS: BIN with ARGS under the
# fixture os-release, with a fresh $LOG. MODE `plain` gives it /dev/null on
# stdin, stdout in $tmp/out and stderr in $tmp/err; `terminal` runs it on a
# pseudo-terminal script(1) opens with ANSWER typed, both streams in
# $tmp/out. REQ_PATH replaces the PATH after the stubs and REQ_OS_RELEASE
# the bound os-release. The exit status lands in $status.
req() {
  local bin="$1" mode="$2" answer="$3" cfg="$4" rt="$5" extra=() words
  shift 5
  while [[ $1 != -- ]]; do extra+=("$1"); shift; done
  shift
  : >"$log"
  words=("${base_env[@]}" PATH="$stubs:${REQ_PATH:-$base_path}" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt" LOG="$log" "${extra[@]}")
  local bound=(unshare -rm sh -c 'mount --bind "$1" /etc/os-release && shift && exec "$@"' sh "${REQ_OS_RELEASE:-$os_release}")
  status=0
  : >"$tmp/err"
  if [[ $mode == plain ]]; then
    "${bound[@]}" "${words[@]}" "$bin" "$@" </dev/null >"$tmp/out" 2>"$tmp/err" || status=$?
  else
    "${bound[@]}" "${words[@]}" SHELL="$BASH" timeout 60 "$script_bin" -qec "$(printf '%q ' "$bin" "$@")" /dev/null <<<"$answer" >"$tmp/out" 2>&1 || status=$?
  fi
}
out_is() { [[ "$(cat -- "$tmp/out")" == "$1" ]] || { printf 'out: [%s]\nwant: [%s]\n' "$(cat -- "$tmp/out")" "$1" >"$tmp/why"; return 1; }; }
# A pseudo-terminal ends each line with a carriage return.
out_has() { tr -d '\r' <"$tmp/out" | grep -qxF -- "$1"; }
err_is() { [[ "$(cat -- "$tmp/err")" == "$1" ]]; }
log_is() { [[ "$(cat -- "$log")" == "$1" ]] || { printf 'log: [%s]\nwant: [%s]\n' "$(cat -- "$log")" "$1" >"$tmp/why"; return 1; }; }
log_has() { grep -qxF -- "$1" "$log"; }
lines() { printf '%s\n' "$@"; }
rescans() { grep -cxF "qs [ipc] [--pid] [$$] [call] [shell] [rescanPlugins]" "$log" || true; }

check "every command a row elevates, installs or reaches the shell with is a stub" \
  test "$("${base_env[@]}" PATH="$stubs:$base_path" sh -c 'for c in sudo pacman paru flatpak nix qs; do command -v "$c"; done')" == "$(lines "$stubs/sudo" "$stubs/pacman" "$stubs/paru" "$stubs/flatpak" "$stubs/nix" "$stubs/qs")"

# The fixture plugin: missing commands with a pacman package, an AUR-only
# package, no package, an optional one, one sharing another's package and
# one whose package name a shell would read as two commands, and git,
# which is present.
need() { # COMMAND PACKAGES PURPOSE [OPTIONAL]
  printf '{ "command": "%s", "packages": %s, "purpose": "%s"%s }' "$1" "$2" "$3" "${4:+, \"optional\": true}"
}
requirements="$(need vgs-need-one '{ "pacman": "need-one", "apt": "need-one-deb" }' First),
$(need vgs-need-two '{ "aur": "need-two" }' Second),
$(need vgs-need-bare '{}' "No package"),
$(need vgs-need-opt '{ "pacman": "need-opt" }' Optional yes),
$(need git '{ "pacman": "git" }' Present),
$(need vgs-need-dup '{ "pacman": "need-one" }' "Same package"),
$(need vgs-need-quote '{ "pacman": "need;one" }' Quoted)"
source_repo needs "$(manifest acme.needs 0.1.0 ", \"requirements\": [ $requirements ]")"
source_repo probe "$(manifest acme.probe 0.1.0)"
# On NixOS: a package for nix, which installs nothing through vgsh, beside
# one for the Flatpak overlay.
source_repo nixos "$(manifest acme.nixos 0.1.0 ", \"requirements\": [ $(need vgs-nix-one '{ "nix": "nix-one" }' Nix), $(need vgs-flat '{ "flatpak": "org.flat" }' Flat) ]")"

offer="$(lines \
  "requires vgs-need-one (need-one)" \
  "requires vgs-need-two (need-two)" \
  "requires vgs-need-bare" \
  "requires vgs-need-opt (need-opt) optional" \
  "requires vgs-need-dup (need-one)" \
  "requires vgs-need-quote (need;one)" \
  "install: vgsh pkg run install need-one need-opt need\\;one" \
  "install: vgsh pkg run install --manager aur need-two")"
report="$(lines \
  "missing vgs-need-one (need-one): First" \
  "missing vgs-need-two (need-two): Second" \
  "missing vgs-need-bare: No package" \
  "missing vgs-need-opt (need-opt) optional: Optional" \
  "present git (git): Present" \
  "missing vgs-need-dup (need-one): Same package" \
  "missing vgs-need-quote (need;one): Quoted")"

# Each row takes the vgsh it runs and a fresh configuration directory, and
# answers 0 when every expectation holds.
row_offer_no_terminal() {
  req "$1" plain "" "$2" "$rt_empty" -- plugin add "$tmp/src/needs.git"
  [[ $status == 0 ]] && err_is "" && log_is "" && out_is "$(lines "ok added=acme.needs path=$2/vgs/plugins/acme.needs config=unchanged" "shell=not-running" "$offer")"
}
row_offer_declined() {
  req "$1" terminal n "$2" "$rt_empty" -- plugin add "$tmp/src/needs.git"
  [[ $status == 0 ]] && log_is "" && grep -qF "Install now? [y/N]" "$tmp/out" && out_has "install: vgsh pkg run install --manager aur need-two"
}
# y installs each manager's packages as argv, pacman's behind one sudo
# session and paru's with none. A running shell hears the landing as
# pluginInstalled with the new plugin's id, which rescans and raises its
# notice, and rescans after each install.
row_offer_accepted() {
  req "$1" terminal y "$2" "$rt_live" -- plugin add "$tmp/src/needs.git"
  [[ $status == 0 ]] && log_has "sudo [pacman] [-S] [--needed] [--] [need-one] [need-opt] [need;one]" \
    && log_has "pacman [-S] [--needed] [--] [need-one] [need-opt] [need;one]" \
    && log_has "paru [-S] [--needed] [--] [need-two]" && [[ $(rescans) == 2 ]] \
    && [[ $(grep -cxF "qs [ipc] [--pid] [$$] [call] [shell] [pluginInstalled] [acme.needs]" "$log") == 1 ]]
}
row_offer_silent() {
  req "$1" terminal y "$2" "$rt_empty" -- plugin add "$tmp/src/probe.git"
  [[ $status == 0 ]] && log_is "" && ! grep -qF "Install now?" "$tmp/out"
}
row_install_failure() {
  req "$1" terminal y "$2" "$rt_empty" STUB_FAIL=-S -- plugin add "$tmp/src/needs.git"
  [[ $status == 7 ]] && log_has "pacman [-S] [--needed] [--] [need-one] [need-opt] [need;one]" && ! grep -q "^paru " "$log"
}
row_nix_by_hand() {
  REQ_OS_RELEASE="$nixos_release" req "$1" plain "" "$2" "$rt_empty" -- plugin add "$tmp/src/nixos.git"
  [[ $status == 0 ]] && err_is "" && log_is "" && out_is "$(lines "ok added=acme.nixos path=$2/vgs/plugins/acme.nixos config=unchanged" "shell=not-running" \
    "requires vgs-nix-one (nix-one)" "requires vgs-flat (org.flat)" "by-hand nix nix-one" "install: vgsh pkg run install --manager flatpak org.flat")" || return 1
  rm -rf -- "${2:?}/vgs/plugins/acme.nixos"
  REQ_OS_RELEASE="$nixos_release" req "$1" terminal y "$2" "$rt_empty" -- plugin add "$tmp/src/nixos.git"
  [[ $status == 0 ]] && log_is "flatpak [install] [org.flat]"
}
row_run_rescans() {
  req "$1" terminal "" "$2" "$rt_live" -- pkg run install --manager pacman foo
  [[ $status == 0 && $(rescans) == 1 ]] && grep -qF "shell=rescan-started" "$tmp/out"
}
row_failed_run_rescans() {
  req "$1" terminal "" "$2" "$rt_live" STUB_FAIL=-S -- pkg run install --manager pacman foo
  [[ $status == 7 && $(rescans) == 1 ]]
}
row_refused_run_leaves_shell() {
  req "$1" plain "" "$2" "$rt_live" VGSH_RUNNER_PID=4242 -- pkg run install --manager pacman foo
  [[ $status == 1 && $(rescans) == 0 ]]
}
row_requirements() {
  req "$1" plain "" "$2" "$rt_empty" -- plugin add "$tmp/src/needs.git"
  req "$1" plain "" "$2" "$rt_empty" -- plugin requirements acme.needs
  [[ $status == 0 ]] && err_is "" && out_is "$report"
}
row_requirements_json() {
  req "$1" plain "" "$2" "$rt_empty" -- plugin add "$tmp/src/needs.git"
  req "$1" plain "" "$2" "$rt_empty" -- plugin requirements --json acme.needs
  [[ $status == 0 ]] && json_is "$tmp/out" 'd[0] == {"command": "vgs-need-one", "packages": {"pacman": "need-one", "apt": "need-one-deb"}, "optional": False, "purpose": "First", "state": "missing", "package": {"manager": "pacman", "name": "need-one"}} and d[1]["package"] == {"manager": "aur", "name": "need-two"} and d[2]["package"] is None and d[4]["state"] == "present" and len(d) == 7'
}
# A plugin add lands disabled is left out; enabled, it is reported beside
# the core, whose commands this PATH lacks apart from node and python3.
row_doctor() {
  req "$1" plain "" "$2" "$rt_empty" -- plugin add "$tmp/src/needs.git"
  REQ_PATH="$tools" req "$1" plain "" "$2" "$rt_empty" -- doctor --json
  [[ $status == 0 ]] && json_is "$tmp/out" '"acme.needs" not in d["plugins"]' || return 1
  printf '{ "version": 1, "plugins": [ { "id": "acme.needs" } ] }\n' >"$2/vgs/shell.json"
  REQ_PATH="$tools" req "$1" plain "" "$2" "$rt_empty" -- doctor --json
  [[ $status == 0 ]] && json_is "$tmp/out" '[r["state"] for r in d["plugins"]["acme.needs"]] == ["missing"] * 7 and {r["command"]: r["state"] for r in d["core"]}["node"] == "present" and {r["command"]: r["state"] for r in d["core"]}["git"] == "missing" and {r["command"]: r["package"] for r in d["core"]}["python3"] == {"manager": "pacman", "name": "python"}' || return 1
  REQ_PATH="$tools" req "$1" plain "" "$2" "$rt_empty" -- doctor
  [[ $status == 0 ]] && err_is "" && out_has "acme.needs missing vgs-need-two (need-two): Second" \
    && out_has "acme.needs missing git (git): Present" && grep -qx "core present node (nodejs): .*" "$tmp/out" \
    && grep -qx "core missing git (git): .*" "$tmp/out" && grep -qx "core missing gum (gum) optional: .*" "$tmp/out"
}

# rows: label | function. Each runs against the tree under test with a
# configuration directory of its own.
declare -a ROWS=(
  "add without a terminal prints each missing command and the install commands|row_offer_no_terminal"
  "add declined on a terminal installs nothing|row_offer_declined"
  "add accepted on a terminal installs each manager's packages and rescans|row_offer_accepted"
  "add of a plugin that requires nothing asks nothing|row_offer_silent"
  "a failed install ends add with its status|row_install_failure"
  "nix's packages are named for its own configuration, and the overlay's installed|row_nix_by_hand"
  "a run asks a running shell to rescan|row_run_rescans"
  "a failed run still asks for the rescan|row_failed_run_rescans"
  "a refused run asks for no rescan|row_refused_run_leaves_shell"
  "plugin requirements names each requirement's state and package|row_requirements"
  "plugin requirements --json carries the package pick|row_requirements_json"
  "doctor reports the core and the enabled plugins only|row_doctor"
)
config_count=0
# run_rows BIN QUIET: every row through BIN; prints ok/FAIL lines unless
# QUIET and returns the number of rows that failed.
run_rows() {
  local bin="$1" quiet="$2" row name fn red=0
  for row in "${ROWS[@]}"; do
    IFS='|' read -r name fn <<<"$row"
    config_count=$((config_count + 1))
    rm -f -- "$tmp/why"
    if "$fn" "$bin" "$tmp/cfg-$config_count"; then
      [[ $quiet == quiet ]] || ok "$name"
    else
      red=$((red + 1))
      [[ $quiet == quiet ]] || fail "$name: exit=$status $(cat -- "$tmp/why" 2>/dev/null || true)"
    fi
  done
  return "$red"
}
run_rows "$repo/bin/vgsh" loud || true

# The usage rows need no fixture.
inst "plugin requirements refuses an id no plugin has" "$tmp/cfg-usage" "$rt_empty" 1 "" "vgsh: refused: unknown=acme.absent" plugin requirements acme.absent
inst "plugin requirements without an id is exit 2" "$tmp/cfg-usage" "$rt_empty" 2 "" "vgsh: refused: id=missing" plugin requirements
inst "plugin requirements refuses a second argument" "$tmp/cfg-usage" "$rt_empty" 2 "" "vgsh: refused: argument=more" plugin requirements acme.absent more
inst "doctor refuses an argument" "$tmp/cfg-usage" "$rt_empty" 2 "" "vgsh: refused: argument=more" doctor more
inst "plugin rescan with no shell says so" "$tmp/cfg-usage" "$rt_empty" 0 "shell=not-running" "" plugin rescan
inst "plugin rescan asks a running shell" "$tmp/cfg-usage" "$rt_live" 0 "shell=rescan-started" "" plugin rescan
check "the rescan names the shell's pid from the lock file" test "$(cat "$tmp/args")" == "ipc --pid $$ call shell rescanPlugins"
mkdir -p "$tmp/cfg-bad/vgs"; printf '{ "version": 1, "plugins": [ "junk" ] }\n' >"$tmp/cfg-bad/vgs/shell.json"
inst "doctor refuses a user file the config judge refuses" "$tmp/cfg-bad" "$rt_empty" 1 "" "vgsh: refused: user-config=malformed path=$tmp/cfg-bad/vgs/shell.json error=plugins.0 must be an object with a string id" doctor

# controls: label, the file under bin/, its text and the replacement, one
# control per four entries. The copy replaces that file in a tree of its
# own, and the rows must fail against it.
declare -a CONTROLS=(
  "add reports the missing requirements" vgsh '  offer_requirements "$id"' ''
  "add asks only on a terminal" vgsh '  [[ -t 0 ]] || return 0' ''
  "add installs only on yes" vgsh '    *) return 0 ;;' '    *) ;;'
  "a run asks for the rescan" vgsh-pkg '            rescanShell();' ''
  "doctor reports enabled plugins only" vgsh-plugin-judge '.filter(id => logic.isEnabled(effective, plugins.get(id).manifest, defaultBarId))' ''
  "the core's commands are looked up on PATH" vgsh-plugin-judge '.filter(command => !onPath(command))' '.filter(command => false)'
  "a row carries this system's package" vgsh-plugin-judge '{ package: logic.PackageManagers.packageFor(row.packages, found) }' '{ package: null }'
  "nix gets no install command" vgsh-plugin-judge 'lines.push(group.installs ? ' 'lines.push(true ? '
  "add tells the shell which plugin it installed" vgsh '  rescan_if_running pluginInstalled "$id"' '  rescan_if_running rescanPlugins'
)
for ((i = 0; i < ${#CONTROLS[@]}; i += 4)); do
  label="${CONTROLS[i]}" file="${CONTROLS[i + 1]}"
  copy_with "control-$((i / 4))" "$repo/bin/$file" "${CONTROLS[i + 2]}" "${CONTROLS[i + 3]}"
  tree="$tmp/tree-$((i / 4))"; mkdir -p "$tree/bin"
  cp -R -- "$repo/bin/." "$tree/bin/"
  cp -- "$copy" "$tree/bin/$file"
  for sibling in shell config; do ln -s -- "$repo/$sibling" "$tree/$sibling"; done
  if run_rows "$tree/bin/vgsh" quiet; then fail "control: $label: the rows pass without the rule"; else ok "control: the rows fail without the rule: $label"; fi
done

rows_done test-vgsh-requirements
