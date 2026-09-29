#!/usr/bin/env bash
# Controls for the vgs.updates update pipeline: tui/update.sh and
# tui/update-source.sh over tui/pipeline.sh and bin/facts, and tui/log.sh,
# which shows the log the pipeline writes. Each row runs a
# copy of the plugin on a pseudo-terminal script(1) opens, as
# `vgsh-tui present` runs it, under an explicit environment whose PATH
# holds only stand-ins and the few tools the pipeline runs. VGS_TUI_LIB
# names a fixture tree holding the shipped bin/lib/tui.sh and a stand-in
# vgsh. Every stand-in appends its name and arguments to one calls file, so
# a row reads the order of every step and its argv. No row reaches a real
# vgsh, package manager, sudo, doas, snapshot tool or live session. The reboot
# rows stand a copied `sleep` in for Hyprland and remove its file while it
# runs, so /proc names its executable deleted.
#
# Each control runs a row against a copy of the plugin whose
# tui/pipeline.sh drops one rule, and that row must fail.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
for tool in script flock; do
  command -v "$tool" >/dev/null || { echo "test-updates-pipeline: status=not-measured missing=$tool"; exit 77; }
done
kernel=""
for dir in /lib/modules/*/; do [[ -d $dir ]] && { kernel="$(basename -- "$dir")"; break; }; done
[[ -n $kernel ]] || { echo "test-updates-pipeline: status=not-measured missing=/lib/modules/<release>"; exit 77; }

plugin="$tmp/plugin"
cp -R -- "$repo/shell/plugins/vgs.updates" "$plugin"
tree="$tmp/tree"
mkdir -p "$tree/bin/lib"
cp -- "$repo/bin/lib/tui.sh" "$repo/bin/lib/qml-library.js" "$tree/bin/lib/"
printf '0.1.0\n' >"$tree/VERSION"
calls="$tmp/calls"; fix="$tmp/fix"; rt="$tmp/rt"; state="$tmp/state"
mkdir -p "$fix" "$rt" "$state"
log="$state/vgs/updates/update.log"

# Stand-ins. Each first appends `<name> <arguments>` to $CALLS.
stubs="$tmp/stubs"; snapper_dir="$tmp/snapper-bin"; tools="$tmp/tools"
mkdir -p "$stubs" "$snapper_dir" "$tools"
record='printf "%s" "${0##*/}" >>"$CALLS"; for a; do printf " %s" "$a" >>"$CALLS"; done; echo >>"$CALLS"'
stub() { # DIR NAME BODY
  printf '#!/bin/sh\n%s\n%s\n' "$record" "$3" >"$1/$2"
  chmod +x "$1/$2"
}
# vgsh answers each read from $FIX; pacman's plan names the elevator in
# $FIX/elevator; `pkg run` fails with 9 for a manager $FIX/fail-<id> names;
# `pkg owner` answers only while $FIX/owner exists, with a new version after
# its first answer when $FIX/owner-changes does.
stub "$tree/bin" vgsh 'case "$1 $2" in
  "plugin settings") cat "$FIX/settings.json" ;;
  "pkg detect") cat "$FIX/detect.json" ;;
  "pkg plan")
    case "$4" in
      pacman) echo "{\"manager\":\"pacman\",\"binary\":\"pacman\",\"action\":\"upgrade\",\"elevate\":true,\"steps\":[[\"pacman\",\"-Syu\"]],\"elevator\":{\"ok\":true,\"command\":\"$(cat "$FIX/elevator")\"}}" ;;
      flatpak) echo "{\"manager\":\"flatpak\",\"binary\":\"flatpak\",\"action\":\"upgrade\",\"elevate\":false,\"steps\":[[\"flatpak\",\"update\"]],\"elevator\":null}" ;;
      mise) echo "{\"manager\":\"mise\",\"binary\":\"mise\",\"action\":\"upgrade\",\"elevate\":false,\"steps\":[[\"env\",\"MISE_MINIMUM_RELEASE_AGE=0\",\"mise\",\"upgrade\"]],\"elevator\":null}" ;;
      aur) echo "{\"manager\":\"aur\",\"binary\":\"paru\",\"action\":\"upgrade\",\"elevate\":false,\"steps\":[[\"paru\",\"-Sua\"]],\"elevator\":null}" ;;
      *) echo "vgsh: refused: manager=$4 action=upgrade reason=unsupported" >&2; exit 1 ;;
    esac ;;
  "self status") cat "$FIX/self.json" ;;
  "self update") echo "ok updated=vgs from=a to=b" ;;
  "plugin outdated") cat "$FIX/plugins.json" ;;
  "theme outdated") cat "$FIX/themes.json" ;;
  "pkg run") [ ! -e "$FIX/fail-$5" ] || exit 9 ;;
  "pkg owner")
    [ -e "$FIX/owner" ] || exit 1
    v=1
    if [ -e "$FIX/owner-asked" ] && [ -e "$FIX/owner-changes" ]; then v=2; fi
    : >"$FIX/owner-asked"
    echo "{\"manager\":\"pacman\",\"package\":\"vgs-git\",\"version\":\"0.1.0.r$v\"}" ;;
  "pid ") [ -e "$FIX/running" ] || exit 69; echo 42 ;;
esac'
# gum confirm answers the exit status in $FIX/answer-<question>, 0 when
# absent; style prints its lines.
stub "$stubs" gum 'case "$1" in
  confirm)
    for q; do :; done
    case "$q" in "Start the update?") f=start ;; Remove*) f=orphans ;; *Reboot*) f=reboot ;; *) f=other ;; esac
    st=0; [ ! -e "$FIX/answer-$f" ] || read -r st <"$FIX/answer-$f"; exit "$st" ;;
  style) shift; for a; do printf "%s\n" "$a"; done ;;
esac'
# sudo refuses every authorization and every command while
# $FIX/sudo-refuses exists; doas runs its command.
stub "$stubs" sudo 'case "$1" in -k) exit 0 ;; esac
[ ! -e "$FIX/sudo-refuses" ] || exit 1
case "$1" in -n|/usr/bin/true) exit 0 ;; esac
exec "$@"'
stub "$stubs" doas 'exec "$@"'
stub "$snapper_dir" snapper 'case "$*" in
  "--csvout list-configs") printf "config,subvolume\nroot,/\n" ;;
  *create*) [ ! -e "$FIX/fail-snapper" ] || exit 1 ;;
esac'
stub "$stubs" pacman '[ -e "$FIX/orphans" ] || exit 1; cat "$FIX/orphans"'
stub "$stubs" df 'a=99999999999; [ ! -e "$FIX/avail" ] || read -r a <"$FIX/avail"; printf "  Avail\n%s\n" "$a"'
stub "$stubs" pgrep '[ -e "$FIX/pids" ] || exit 1; cat "$FIX/pids"'
stub "$stubs" uname "echo $kernel"
stub "$stubs" systemctl ''
# paru authorizes through sudo and fails with 7 while $FIX/fail-paru exists.
stub "$stubs" paru '[ ! -e "$FIX/fail-paru" ] || { sudo /usr/bin/true; exit 7; }'
stub "$stubs" less ''
for tool in bash env readlink dirname mkdir mv rm script flock sleep cat id; do
  found="$(command -v "$tool")" || { echo "test-updates-pipeline: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$(readlink -f -- "$found")" "$tools/$tool"
done
ln -s -- "$node_bin" "$tools/node"

cp -- "$(command -v sleep)" "$tmp/Hyprland"
"$tmp/Hyprland" 300 &
hyprland_pid=$!
trap 'kill "$hyprland_pid" 2>/dev/null; rm -rf -- "${tmp:?}"' EXIT
rm -- "$tmp/Hyprland"

settings() { # AUR_COMMAND TRUST
  printf '{"intervalHours":6,"hideWhenCurrent":false,"aurCommand":"%s","snapshot":"auto","trustPluginUpdates":%s,"placement":"center"}\n' "$1" "$2" >"$fix/settings.json"
}
self_json() { # METHOD PACKAGE_JSON BEHIND
  printf '{"version":"0.1.0","method":"%s","package":%s,"current":"a","latest":"b","behind":%s,"error":null}\n' "$1" "$2" "$3" >"$fix/self.json"
}
# The fixture every row starts from: pacman with the AUR through paru,
# Flatpak and mise; a checkout one commit behind; one plugin and one theme
# behind; no snapshot tool, no orphan, no replaced Hyprland, every answer yes.
reset_fix() {
  rm -rf -- "${fix:?}" "$state/vgs"
  mkdir -p "$fix"
  settings "" false
  echo sudo >"$fix/elevator"
  printf '{"primary":{"id":"pacman","binary":"pacman"},"overlays":[{"id":"aur","binary":"paru"},{"id":"flatpak","binary":"flatpak"}],"sources":[{"id":"mise","binary":"mise"}]}\n' >"$fix/detect.json"
  self_json checkout null true
  printf '[{"id":"acme.one","behind":2,"head":"h","upstream":"u","error":null},{"id":"acme.two","behind":0,"head":"h","upstream":"h","error":null}]\n' >"$fix/plugins.json"
  printf '[{"id":"night","behind":1,"head":"h","upstream":"u","error":null}]\n' >"$fix/themes.json"
}

# pipeline SCRIPT ARG...: the plugin copy $PLUGIN, else $plugin, runs
# tui/SCRIPT on a pseudo-terminal; its output in $tmp/out, the exit status
# in $status, and the calls, but for the free-space and reboot probes and
# the plan box, in $tmp/seq. PIPE_PATH puts a directory before the stubs.
pipeline() {
  local script_path="${PLUGIN:-$plugin}/tui/$1"
  shift
  : >"$calls"
  status=0
  "${base_env[@]}" PATH="${PIPE_PATH:+$PIPE_PATH:}$stubs:$tools" VGS_TUI_LIB="$tree/bin/lib/tui.sh" VGS_PLUGIN_ID=vgs.updates VGS_PLUGIN_DIR="${PLUGIN:-$plugin}" \
    XDG_STATE_HOME="$state" XDG_RUNTIME_DIR="$rt" CALLS="$calls" FIX="$fix" \
    script -qec "$(printf '%q ' "$BASH" "$script_path" "$@")" /dev/null </dev/null >"$tmp/out" 2>&1 || status=$?
  local filtered=0
  grep -v -e '^df ' -e '^uname ' -e '^pgrep ' -e '^gum style' "$calls" >"$tmp/seq" || filtered=$?
  # grep -v exits 1 when every call is filtered out, and above 1 when it failed.
  [[ $filtered -le 1 ]] || { echo "test-updates-pipeline: calls=unreadable exit=$filtered" >&2; exit 1; }
}
seq_is() { [[ "$(cat "$tmp/seq")" == "$(printf '%s\n' "$@")" ]]; } # LINE...
has_call() { grep -qxF -- "$1" "$tmp/seq"; }
out_has() { grep -qF -- "$1" "$tmp/out"; }
out_lacks() { ! grep -qF -- "$1" "$tmp/out"; }
# Whether the first call A comes before the last call B.
before() { # A B
  local lines i a="" b=""
  mapfile -t lines <"$tmp/seq"
  for i in "${!lines[@]}"; do
    [[ -z $a && ${lines[i]} == "$1" ]] && a="$i"
    [[ ${lines[i]} == "$2" ]] && b="$i"
  done
  [[ -n $a && -n $b && $a -lt $b ]]
}

# assert NAME CMD...: an ok or FAIL line unless QUIET=1; a failure adds to
# $red either way.
red=0
assert() {
  local name="$1"
  shift
  if "$@"; then [[ ${QUIET:-0} == 1 ]] || ok "$name"
  else red=$((red + 1)); [[ ${QUIET:-0} == 1 ]] || fail "$name"
  fi
}

# The whole run, in order: the reads, the question, the sudo session, VGS,
# the system, Flatpak, mise, the plugin and the theme, the session's end,
# the AUR, the drop after it, the orphans. No snapshot tool is 127: no
# warning, and the run goes on.
row_full() {
  reset_fix
  pipeline update.sh
  assert "a full run exits 0" test "$status" == 0
  assert "a full run takes every step in order, the AUR after the session ends" seq_is \
    "vgsh plugin settings vgs.updates" "vgsh pkg detect --json" "vgsh self status --json" \
    "vgsh pkg plan upgrade pacman" "vgsh pkg plan upgrade flatpak" "vgsh pkg plan upgrade mise" "vgsh pkg plan upgrade aur" \
    "vgsh plugin outdated --json" "vgsh theme outdated --json" "gum confirm -- Start the update?" \
    "vgsh pkg owner $tree/VERSION" "sudo -k" "sudo /usr/bin/true" "vgsh self update" \
    "vgsh pkg run upgrade --manager pacman" "vgsh pkg run upgrade --manager flatpak" "vgsh pkg run upgrade --manager mise" \
    "vgsh plugin update acme.one" "vgsh theme update night" "sudo -k" \
    "vgsh pkg run upgrade --manager aur" "sudo -k" "pacman -Qtdq"
  assert "a plugin update gets no --yes by default" has_call "vgsh plugin update acme.one"
  assert "no snapshot tool warns nothing" out_lacks "snapshot=failed"
  assert "no snapshot tool keeps the update going quietly" out_lacks "without a snapshot"
  assert "the log keeps the plan box" grep -qF "Update everything" "$log"
}
row_trusted() {
  reset_fix
  settings "" true
  pipeline update.sh
  assert "trustPluginUpdates passes --yes to the plugin update" has_call "vgsh plugin update --yes acme.one"
  assert "trustPluginUpdates passes --yes to the theme update" has_call "vgsh theme update --yes night"
}
row_snapshot() {
  reset_fix
  PIPE_PATH="$snapper_dir" pipeline update.sh
  assert "a snapper configuration takes a snapshot inside the session" before "sudo /usr/bin/true" "sudo snapper -c root create -c number -d VGS update"
  assert "the snapshot comes before VGS" before "sudo snapper -c root cleanup number" "vgsh self update"
  touch "$fix/fail-snapper"
  PIPE_PATH="$snapper_dir" pipeline update.sh
  assert "a failed snapshot warns" out_has "updates: snapshot=failed exit=1"
  assert "a failed snapshot does not stop the update" has_call "vgsh pkg run upgrade --manager pacman"
  assert "a failed snapshot leaves the exit 0" test "$status" == 0
}
row_failure() {
  reset_fix
  touch "$fix/fail-pacman"
  pipeline update.sh
  assert "a failed system step ends the run with its status" test "$status" == 9
  assert "a failed step names the log in its recovery message" out_has "updates: failed exit=9 log=$log"
  assert "a failed step drops the credential last" test "$(tail -n 1 "$tmp/seq")" == "sudo -k"
  assert "a failed step runs no AUR" test "$(grep -c 'manager aur' "$tmp/seq")" == 0
}
row_reboot() {
  reset_fix
  printf '%s\n' "$hyprland_pid" >"$fix/pids"
  pipeline update.sh
  assert "a replaced Hyprland asks to reboot" has_call "gum confirm -- Hyprland was updated. Reboot now?"
  assert "a yes reboots" test "$(tail -n 1 "$tmp/seq")" == "systemctl reboot"
  echo 1 >"$fix/answer-reboot"
  pipeline update.sh
  assert "a no does not reboot" test "$(grep -c '^systemctl' "$tmp/seq")" == 0
}
row_orphans() {
  reset_fix
  printf 'foo\nbar\n' >"$fix/orphans"
  echo 1 >"$fix/answer-orphans"
  pipeline update.sh
  assert "orphans are asked about, default no" has_call "gum confirm --default=false -- Remove 2 orphaned package(s)?"
  assert "a no removes no orphan" test "$(grep -c 'pkg run remove' "$tmp/seq")" == 0
  rm -f -- "$fix/answer-orphans"
  pipeline update.sh
  assert "a yes removes the orphans through the package table" has_call "vgsh pkg run remove --manager pacman foo bar"
}
row_yes() {
  reset_fix
  printf 'foo\n' >"$fix/orphans"
  pipeline update.sh -y
  assert "-y asks no start question" test "$(grep -c 'Start the update' "$tmp/seq")" == 0
  assert "-y reports orphans instead of asking" test "$(grep -c 'orphaned' "$tmp/seq")" == 0
  assert "-y still runs the system step" has_call "vgsh pkg run upgrade --manager pacman"
}
row_declined() {
  reset_fix
  echo 1 >"$fix/answer-start"
  pipeline update.sh
  assert "a declined start exits 0" test "$status" == 0
  assert "a declined start runs nothing" test "$(grep -c -e '^sudo' -e 'pkg run' "$tmp/seq")" == 0
}
row_busy() {
  reset_fix
  mkdir -p "$state/vgs/updates"
  printf 'earlier run\n' >"$log"
  # This suite's own shell holds the lock, so closing its descriptor frees it.
  local held
  exec {held}>>"$rt/vgs-tui-updates.lock"
  flock -n "$held"
  pipeline update.sh
  exec {held}>&-
  assert "a second run is refused busy" test "$status" == 75
  assert "a busy run leaves the running run's log" test "$(cat "$log")" == "earlier run"
  assert "a busy run asks vgsh nothing" test ! -s "$tmp/seq"
}
row_aur_command() {
  reset_fix
  settings "paru -Sua --devel" false
  pipeline update.sh
  assert "aurCommand replaces the table's AUR plan" test "$(grep -c 'plan upgrade aur' "$tmp/seq")" == 0
  assert "aurCommand runs after the session ends" before "vgsh theme update night" "paru -Sua --devel"
}
# An AUR helper that caches a sudo credential and then fails still has it
# dropped, after it, and the run ends with the helper's status and the
# recovery message.
row_aur_failure() {
  reset_fix
  settings "paru -Sua --devel" false
  touch "$fix/fail-paru"
  pipeline update.sh
  assert "a failed AUR step ends the run with its status" test "$status" == 7
  assert "a failed AUR step names the log in its recovery message" out_has "updates: failed exit=7 log=$log"
  assert "a failed AUR step drops the credential it cached, last" test "$(tail -n 1 "$tmp/seq")" == "sudo -k"
  assert "the credential is dropped after the failed AUR step" before "paru -Sua --devel" "sudo -k"
}
# packages.elevate names doas: sudo is installed but refuses, and the
# update runs through doas without a sudo session.
row_doas() {
  reset_fix
  echo doas >"$fix/elevator"
  touch "$fix/sudo-refuses"
  PIPE_PATH="$snapper_dir" pipeline update.sh
  assert "a doas update exits 0" test "$status" == 0
  assert "a doas update starts no sudo session" test "$(grep -c '^sudo /usr/bin/true' "$tmp/seq")" == 0
  assert "a doas update takes its snapshot through doas" has_call "doas snapper -c root create -c number -d VGS update"
  assert "a doas update names doas in the plan box" out_has "Snapshot: snapper through doas, first"
  assert "a doas update runs the system step" has_call "vgsh pkg run upgrade --manager pacman"
}
# update-source.sh vgs on a vgs-git behind: the rebuild replaces the
# package, so a snapshot comes first and the running shell restarts on the
# new version, and no other package is upgraded.
row_vgs_only() {
  reset_fix
  self_json package '"vgs-git"' true
  touch "$fix/owner" "$fix/owner-changes" "$fix/running"
  PIPE_PATH="$snapper_dir" pipeline update-source.sh vgs
  assert "a VGS rebuild alone exits 0" test "$status" == 0
  assert "a VGS rebuild alone takes a snapshot before it" before "sudo snapper -c root create -c number -d VGS update" "paru -S vgs-git"
  assert "a VGS rebuild alone drops the credential after it" before "paru -S vgs-git" "sudo -k"
  assert "a VGS rebuild alone restarts the running shell" has_call "vgsh restart"
  assert "a VGS rebuild alone upgrades no other package" test "$(grep -c -e 'pkg run' -e '^pacman' "$tmp/seq")" == 0
}
row_vgs_git() {
  reset_fix
  self_json package '"vgs-git"' true
  touch "$fix/owner" "$fix/owner-changes" "$fix/running"
  pipeline update.sh
  assert "a package tree runs no self update" test "$(grep -c 'self update' "$tmp/seq")" == 0
  assert "a behind vgs-git is rebuilt after the AUR" before "vgsh pkg run upgrade --manager aur" "paru -S vgs-git"
  assert "the credential is dropped after the rebuild" before "paru -S vgs-git" "sudo -k"
  assert "a replaced VGS package restarts the running shell" has_call "vgsh restart"
}
row_source() {
  reset_fix
  pipeline update-source.sh flatpak
  assert "one source runs its step alone" seq_is \
    "vgsh plugin settings vgs.updates" "vgsh pkg detect --json" "vgsh pkg plan upgrade flatpak" \
    "gum confirm -- Start the update?" "vgsh pkg run upgrade --manager flatpak"
  pipeline update-source.sh aur
  assert "the AUR alone holds no session" test "$(grep -c '^sudo /usr/bin/true' "$tmp/seq")" == 0
  assert "the AUR alone drops the credential after it" before "vgsh pkg run upgrade --manager aur" "sudo -k"
  pipeline update-source.sh nope
  assert "an unknown source is refused" test "$status:$(head -n 1 "$tmp/out" | tr -d '\r')" == "2:updates: refused: source=nope reason=unknown"
  pipeline update-source.sh
  assert "a missing source is refused" test "$status:$(head -n 1 "$tmp/out" | tr -d '\r')" == "2:updates: refused: source=missing"
}
# tui/log.sh opens the log the pipeline wrote, at its end, and refuses
# before any run wrote one.
row_log() {
  reset_fix
  pipeline log.sh
  assert "the log TUI before any run is refused" test "$status:$(head -n 1 "$tmp/out" | tr -d '\r')" == "1:updates: refused: log=absent path=$log"
  assert "the log TUI before any run opens no pager" test ! -s "$tmp/seq"
  pipeline update.sh
  pipeline log.sh
  assert "the log TUI opens the log the pipeline wrote, at its end" seq_is "less -R +G -- $log"
  assert "the log TUI exits with the pager's status" test "$status" == 0
  pipeline log.sh extra
  assert "the log TUI refuses an argument" test "$status:$(head -n 1 "$tmp/out" | tr -d '\r')" == "2:updates: refused: argument=extra"
}

row_full; row_trusted; row_snapshot; row_failure; row_reboot; row_orphans; row_yes
row_declined; row_busy; row_aur_command; row_aur_failure; row_doas; row_vgs_only; row_vgs_git; row_source; row_log

# Controls: each runs one row against a plugin copy whose tui/FILE,
# pipeline.sh unless named, drops one rule, quietly, and that row must turn
# red.
control() { # NAME NEEDLE REPLACEMENT ROW [FILE]
  local copy_dir="$tmp/plugin-$1" file="${5:-pipeline.sh}"
  cp -R -- "$plugin" "$copy_dir"
  copy_with "$1" "$plugin/tui/$file" "$2" "$3"
  cp -- "$copy" "$copy_dir/tui/$file"
  red=0
  PLUGIN="$copy_dir" QUIET=1 "$4"
  check "the $1 mutant fails $4" test "$red" -gt 0
}
control aur-before-revoke 'if [[ $session == 1 ]]; then vgs_tui_sudo_session end; fi' \
  'if [[ $session == 1 ]]; then "$_updates_vgsh" pkg run upgrade --manager aur; vgs_tui_sudo_session end; fi' row_full
control passes-yes '_updates_yes_flag=()' '_updates_yes_flag=(--yes)' row_full
control aur-unguarded '      vgs_tui_sudo_session guard' '      :' row_aur_failure
control session-ignores-elevator 'if [[ $elevator == sudo ]]; then session=1; fi' 'if command -v sudo >/dev/null; then session=1; fi' row_doas
control snapshot-ignores-elevator '_updates_snapshot "$snapshot_tool" "$elevator" || status=$?' '_updates_snapshot "$snapshot_tool" sudo || status=$?' row_doas
control rebuild-unguarded 'if [[ $upgrades == 1 || $rebuild == 1 ]]; then replaces=1; fi' 'if [[ $upgrades == 1 ]]; then replaces=1; fi' row_vgs_only
control no-recovery "trap '_updates_failed \$?' ERR" ':' row_failure
control no-reboot-check '  _updates_reboot' '  :' row_reboot
control orphans-default-yes '--default=false || status=$?' '|| status=$?' row_orphans
control log-clobbers 'vgs_tui_log "$UPDATES_LOG_PART"' 'vgs_tui_log "$_updates_log"' row_busy
control unasked-start 'vgs_tui_confirm "Start the update?" || status=$?' 'true || status=$?' row_declined
control log-elsewhere 'printf '"'"'%s\n'"'"' "$(updates_state_dir)/update.log"' 'printf '"'"'%s\n'"'"' "$(updates_state_dir)/other.log"' row_log
control log-absent-opens '[[ -f $log ]] || _updates_refuse 1' '[[ -n $log ]] || _updates_refuse 1' row_log log.sh

rows_done test-updates-pipeline
