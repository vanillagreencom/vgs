#!/usr/bin/env bash
# Controls for bin/vgsh-sudo-grant, the time-boxed passwordless sudo grant,
# reached through `vgsh sudo`: the verbs and their bounds, install and
# uninstall, the rule text and its deadline, the visudo check, the expiry
# timer, publication by rename, the NixOS configuration-only path, the
# toggle, the question, the refusals of the root half and its startup.
# Every row runs a copy of vgsh and of the
# helper whose `prefix` is a temporary tree, so its /etc, /run and /usr are
# that tree's. sudo, visudo, systemd-run, systemctl, getent and gum are
# stand-ins there; the sudo stand-in runs the root half under `unshare -r`,
# where the tree reads as root's and nothing outside it is writable, so no
# row reaches the real /etc, the system's sudo or systemd. NixOS rows bind
# a fixture over /etc/os-release in a private mount namespace, keep the
# helper as the non-root user, and assert that the tree and sudo log stay
# untouched; their controls plant a forbidden write and remove the NixOS
# dispatch.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
suite=test-vgsh-sudo-grant
source_file="$repo/bin/vgsh-sudo-grant"
uid="$(id -u)"; gid="$(id -g)"
((uid != 0)) || { echo "$suite: status=not-measured reason=runs-as-root"; exit 77; }
for tool in unshare setsid script find mount sh; do
  command -v "$tool" >/dev/null || { echo "$suite: status=not-measured missing=$tool"; exit 77; }
done
unshare_bin="$(command -v unshare)"; setsid_bin="$(command -v setsid)"; script_bin="$(command -v script)"
mount_bin="$(command -v mount)"; sh_bin="$(command -v sh)"
"$unshare_bin" -r true 2>/dev/null || { echo "$suite: status=not-measured missing=user-namespaces"; exit 77; }
stat_bin="$(command -v stat)"; date_bin="$(command -v date)"

root="$tmp/root"; bin="$root/usr/bin"; installed="$root/usr/local/bin/vgs-sudo-grant"
vgs="$tmp/vgs"; helper="$vgs/bin/vgsh-sudo-grant"
rule="$root/etc/sudoers.d/99-vgs-nopasswd-$uid"; boot="$root/etc/tmpfiles.d/vgs-sudo-grant.conf"
unit="vgs-sudo-grant-expire-$uid"
mkdir -p "$bin" "$vgs/bin" "$vgs/shell/Core" "$tmp/home"
cp -- "$repo/bin/vgsh" "$vgs/bin/vgsh"
cp -- "$repo/bin/vgsh-pkg" "$vgs/bin/vgsh-pkg"
cp -R -- "$repo/bin/lib" "$vgs/bin/lib"
cp -- "$repo/shell/Core/PackageManagers.js" "$vgs/shell/Core/PackageManagers.js"
template="$vgs/bin/lib/tmpfiles.d/vgs-sudo-grant.conf"
for tool in awk cat chmod chown cmp cp env flock grep id install mkdir mktemp mv readlink rm sed touch; do
  tool_bin="$(command -v "$tool")" || { echo "$suite: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$bin/$tool"
done
# stat reports owner 1234 for the path $tmp/foreign names.
cat >"$bin/stat" <<EOF
#!/bin/sh
out="\$($stat_bin "\$@")" || exit \$?
for last; do :; done
if [ -f "$tmp/foreign" ] && [ "\$last" = "\$(cat "$tmp/foreign")" ]; then printf '%s\n' "\$out" | sed 's/^[0-9]* /1234 /'; else printf '%s\n' "\$out"; fi
EOF
# date prints a malformed deadline for `-d @<epoch>` while $tmp/date-junk exists.
cat >"$bin/date" <<EOF
#!/bin/sh
case "\$*" in *"-d @"*) [ -e "$tmp/date-junk" ] && { echo 2026-01-01; exit 0; } ;; esac
exec $date_bin "\$@"
EOF
# sudo: -h prints a usage with or without -N; -k is recorded; -n runs its
# command only while the grant's file exists and $tmp/sudo-ignores is
# absent; any other call exits with $tmp/sudo-exit when present, else runs
# its command as the namespace's root with SUDO_UID set.
cat >"$bin/sudo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/sudo.log"
case "\$1" in
  -h)
    echo 'usage: sudo -h | -K | -k | -V'
    if [ -e "$tmp/sudo-old" ]; then echo 'usage: sudo [-ABbEHPSn] [-C num]'; else echo 'usage: sudo -v [-ABkNnS] [-g group]'; fi
    exit 0 ;;
  -k) exit 0 ;;
esac
nonint=0
while :; do case "\$1" in -n) nonint=1; shift ;; -N) shift ;; --) shift; break ;; *) break ;; esac; done
if [ \$nonint = 1 ]; then
  if [ -e "$rule" ] && [ ! -e "$tmp/sudo-ignores" ]; then exec "\$@"; fi
  echo 'sudo: a password is required' >&2; exit 1
fi
if [ -f "$tmp/sudo-exit" ]; then read -r st <"$tmp/sudo-exit"; exit "\$st"; fi
exec $unshare_bin -r env SUDO_UID="\${STUB_SUDO_UID:-$uid}" "\$@"
EOF
# visudo keeps the file it checked and its environment, and exits with $tmp/visudo-exit, 0 when absent.
cat >"$bin/visudo" <<EOF
#!/bin/sh
for a; do f="\$a"; done
cp -- "\$f" "$tmp/checked-rule"
env >"$tmp/visudo-env"
st=0; [ -f "$tmp/visudo-exit" ] && read -r st <"$tmp/visudo-exit"
exit "\$st"
EOF
# systemd-run records its argv and arms the timer unless $tmp/arm-exit holds a status.
cat >"$bin/systemd-run" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/systemd-run.log"
[ -f "$tmp/arm-exit" ] && { read -r st <"$tmp/arm-exit"; exit "\$st"; }
touch "$tmp/timer-active"
EOF
# systemctl: stop exits 5 for a unit not loaded; is-active answers the timer's state.
cat >"$bin/systemctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/systemctl.log"
case "\$1 \$2" in
  "stop $unit.timer") [ -e "$tmp/timer-active" ] || exit 5; rm -f "$tmp/timer-active" ;;
  "stop $unit.service") exit 5 ;;
  "is-active --quiet") [ "\$3" = "$unit.timer" ] && [ -e "$tmp/timer-active" ] ;;
  *) exit 64 ;;
esac
EOF
# getent names the account $tmp/account holds, vgsuser when absent.
cat >"$bin/getent" <<EOF
#!/bin/sh
[ "\$1 \$2" = "passwd $uid" ] || exit 2
name=vgsuser; [ -f "$tmp/account" ] && read -r name <"$tmp/account"
echo "\$name:x:$uid:$gid::/home/\$name:/bin/sh"
EOF
# systemd-tmpfiles --remove --boot -- FILE runs FILE's `r!` lines inside the
# tree, unless $tmp/tmpfiles-exit holds a status.
cat >"$bin/systemd-tmpfiles" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/tmpfiles.log"
[ -f "$tmp/tmpfiles-exit" ] && { read -r st <"$tmp/tmpfiles-exit"; exit "\$st"; }
[ "\$1 \$2 \$3" = "--remove --boot --" ] || exit 64
awk '!/^[[:space:]]*(#|\$)/' "\$4" | while read -r type path; do
  [ "\$type" = 'r!' ] || exit 65
  for f in $root\$path; do rm -f -- "\$f"; done
done
EOF
# gum confirm records its arguments and answers with $tmp/gum-answer.
cat >"$bin/gum" <<EOF
#!/bin/sh
[ "\$1" = confirm ] || exit 0
printf '%s\n' "\$@" >"$tmp/gum.log"
read -r st <"$tmp/gum-answer"
exit "\$st"
EOF
chmod +x "$bin"/stat "$bin"/date "$bin"/sudo "$bin"/visudo "$bin"/systemd-run "$bin"/systemctl "$bin"/getent "$bin"/gum "$bin"/systemd-tmpfiles

# SOURCE's `prefix=` line, which must occur once, names the tree.
place() { # SOURCE
  check "the helper's prefix line occurs once" test "$(grep -c '^prefix=$' "$1")" == 1
  sed "s|^prefix=\$|prefix=$root|" "$1" >"$helper"
  chmod +x "$helper"
  check "the placed helper names the tree" test "$(grep -c "^prefix=$root\$" "$helper")" == 1
}
# A new tree with nothing installed and every record cleared.
fresh() {
  rm -rf -- "${root:?}/etc" "${root:?}/run" "${root:?}/usr/local"
  mkdir -p "$root/etc/sudoers.d" "$root/etc/tmpfiles.d" "$root/run" "$root/run/current-system/sw/bin" "$root/usr/local/bin"
  chmod 0755 "$root/etc" "$root/etc/tmpfiles.d" "$root/run"; chmod 0750 "$root/etc/sudoers.d"
  rm -f -- "$tmp"/{sudo.log,systemd-run.log,systemctl.log,gum.log,tmpfiles.log,checked-rule,visudo-env,timer-active,foreign,date-junk,sudo-old,sudo-exit,sudo-ignores,visudo-exit,arm-exit,tmpfiles-exit,account,before-tree,after-tree}
  printf '0\n' >"$tmp/gum-answer"
}
# fresh, then the placed helper installed as the root half with its boot cleanup.
installed() {
  fresh
  cp -- "$helper" "$installed"; chmod 0755 "$installed"
  cp -- "$template" "$boot"; chmod 0644 "$boot"
}
caller="$tmp/caller"; mkdir -p "$caller"
ln -s -- "$node_bin" "$caller/node"
nixos_path="$tmp/nixos-path"; mkdir -p "$nixos_path"
cat >"$nixos_path/nix" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$nixos_path/nix"
no_node_path="$tmp/no-node-path"; mkdir -p "$no_node_path"
for tool in bash readlink dirname id; do
  tool_bin="$(command -v "$tool")" || { echo "$suite: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$no_node_path/$tool"
done
nixos_os_release="$tmp/os-release-nixos"
printf 'NAME=NixOS\nID=nixos\n' >"$nixos_os_release"
nixos_mount_script="$mount_bin --bind \"\$1\" /etc/os-release && shift && exec $unshare_bin --user --map-user=$uid --map-group=$gid \"\$@\""
nixos_mount_probe_status=0
"$unshare_bin" -rm "$sh_bin" -c "$nixos_mount_script" sh "$nixos_os_release" "$sh_bin" -c "[ \"\$(id -u)\" = \"$uid\" ] && grep -qx ID=nixos /etc/os-release" 2>/dev/null || nixos_mount_probe_status=$?
((nixos_mount_probe_status == 0)) || { echo "$suite: status=not-measured missing=nixos-os-release-namespace"; exit 77; }
row_env=(env -i HOME="$tmp/home" PATH="$caller:/usr/bin:/bin" LANG=C.UTF-8 VGS_PLANTED=1)
# run NAME WANT_EXIT WANT_FIRST_STDERR ARGS...: vgsh sudo ARGS in a session
# with no terminal; `*` takes any stderr. Stdout lands in $tmp/out, stderr in $tmp/err.
run() {
  local name="$1" want_exit="$2" want_err="$3" status=0 err=""
  shift 3
  "${row_env[@]}" "$setsid_bin" -w "$vgs/bin/vgsh" sudo "$@" </dev/null >"$tmp/out" 2>"$tmp/err" || status=$?
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  if [[ $status == "$want_exit" && ($want_err == "*" || $err == "$want_err") ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit stderr=[$err] want=[$want_err]"; fi
}
tree_snapshot() { find "$root" -printf '%P %y %s %m %T@\n' | sort; }
run_nixos_with_path() { # PATH_VALUE NAME WANT_EXIT WANT_FIRST_STDERR ARGS...
  local path_value="$1" name="$2" want_exit="$3" want_err="$4" status=0 err=""
  shift 4
  tree_snapshot >"$tmp/before-tree"
  env -i HOME="$tmp/home" PATH="$path_value" LANG=C.UTF-8 VGS_PLANTED=1 \
    "$unshare_bin" -rm "$sh_bin" -c "$nixos_mount_script" \
    sh "$nixos_os_release" "$setsid_bin" -w "$vgs/bin/vgsh" sudo "$@" \
    </dev/null >"$tmp/out" 2>"$tmp/err" || status=$?
  tree_snapshot >"$tmp/after-tree"
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  if [[ $status == "$want_exit" && ($want_err == "*" || $err == "$want_err") ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit stderr=[$err] want=[$want_err]"; fi
}
run_nixos_dirty() { # NAME WANT_EXIT WANT_FIRST_STDERR ARGS...
  local name="$1" want_exit="$2" want_err="$3"
  shift 3
  run_nixos_with_path "$nixos_path:$caller:/usr/bin:/bin" "$name" "$want_exit" "$want_err" "$@"
}
run_nixos() { # NAME WANT_EXIT WANT_FIRST_STDERR ARGS...
  local name="$1"
  run_nixos_dirty "$@"
  check "$name leaves the tree unchanged" cmp -s -- "$tmp/before-tree" "$tmp/after-tree"
  check "$name makes no sudo call" test ! -e "$tmp/sudo.log"
  check "$name writes no sudoers rule" no_rule
}
run_nixos_no_nix() { # NAME WANT_EXIT WANT_FIRST_STDERR ARGS...
  run_nixos_with_path "$caller:/usr/bin:/bin" "$@"
}
run_nixos_no_node() { # NAME WANT_EXIT WANT_FIRST_STDERR ARGS...
  run_nixos_with_path "$nixos_path:$no_node_path" "$@"
}
# run_tty NAME WANT_EXIT ARGS...: the same on a pseudo-terminal; stdout and
# stderr together land in $tmp/out, carriage returns dropped.
run_tty() {
  local name="$1" want_exit="$2" status=0
  shift 2
  "${row_env[@]}" SHELL="$BASH" "${tty_env[@]}" "$script_bin" -qec "$(printf '%q ' "$vgs/bin/vgsh" sudo "$@")" /dev/null </dev/null >"$tmp/raw" 2>&1 || status=$?
  tr -d '\r' <"$tmp/raw" >"$tmp/out"
  if [[ $status == "$want_exit" ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit output=[$(cat "$tmp/out")]"; fi
}
tty_env=()
# root NAME WANT_EXIT WANT_FIRST_STDERR ARGS...: the installed root half run
# directly as the namespace's root, SUDO_UID set to $root_caller.
root_caller="$uid"
root() {
  local name="$1" want_exit="$2" want_err="$3" status=0 err=""
  shift 3
  "${row_env[@]}" "$unshare_bin" -r env SUDO_UID="$root_caller" "$installed" "$@" </dev/null >"$tmp/out" 2>"$tmp/err" || status=$?
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  if [[ $status == "$want_exit" && ($want_err == "*" || $err == "$want_err") ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit stderr=[$err] want=[$want_err]"; fi
}
out_has() { grep -qF -- "$1" "$tmp/out"; }
first_out_matches() { local first; IFS= read -r first <"$tmp/out"; [[ $first =~ $1 ]]; }
sudo_calls() { cat -- "$tmp/sudo.log" 2>/dev/null; }
no_rule() { [[ ! -e $rule && -z $(ls -A -- "$root/etc/sudoers.d") ]]; }
tree_changed() { ! cmp -s -- "$tmp/before-tree" "$tmp/after-tree"; }
# The epoch of a rule's NOTAFTER deadline, from the rule file's text.
deadline_epoch() {
  local text d file="${1:-$rule}"
  text="$(cat -- "$file")"
  [[ $text =~ NOTAFTER=([0-9]{14})Z ]] || return 1
  d="${BASH_REMATCH[1]}"
  "$date_bin" -u -d "${d:0:8} ${d:8:2}:${d:10:2}:${d:12:2}" +%s
}
# Whether the rule's deadline is MINUTES from START, within ten seconds.
deadline_in() { # START MINUTES
  local e want
  e="$(deadline_epoch "${3:-}")" || return 1
  want=$(($1 + $2 * 60))
  ((e >= want - 10 && e <= want + 10))
}
place "$source_file"

# vgsh's own refusal of a subcommand it does not route.
fresh
run "vgsh sudo with no subcommand is refused" 2 "vgsh: refused: sudo-subcommand=missing"
run "an unknown sudo subcommand is refused" 2 "vgsh: refused: sudo-subcommand=elevate" elevate

# Bounds and arguments, refused before any sudo.
for bad in 0 1441 00 -5 abc 1.5 "" " 15" 99999; do
  run "grant [$bad] minutes is refused" 2 "vgs-sudo-grant: refused: minutes=$(printf '%q' "$bad")" grant "$bad"
done
run "grant takes one argument" 2 "vgs-sudo-grant: refused: argument=x" grant 15 x
run "status takes no argument" 2 "vgs-sudo-grant: refused: argument=x" status x
run "revoke takes no argument" 2 "vgs-sudo-grant: refused: argument=x" revoke x
check "a refused invocation runs no sudo" test ! -e "$tmp/sudo.log"

# Nothing installed: status says so without sudo; grant and revoke refuse.
run "status with no root half" 0 "" status
check "status names the absent root half" test "$(cat "$tmp/out")" == "sudo-grant=inactive root-half=absent"
run "grant with no root half is refused" 1 "vgs-sudo-grant: refused: root-half=absent path=$installed" grant
run "revoke with no root half is refused" 1 "vgs-sudo-grant: refused: root-half=absent path=$installed" revoke
check "an absent root half runs no sudo" test ! -e "$tmp/sudo.log"

# NixOS follows the package-manager table's nix row: VGS writes no sudo
# files and prints the configuration rule the user adds to NixOS.
fresh
run_nixos "nixos status on a fresh tree is skipped" 0 "" status
check "nixos status prints the skip reason" test "$(cat "$tmp/out")" == "sudo-grant=skipped=nixos-config"
installed
run_nixos "nixos status on an installed tree is skipped" 0 "" status
check "nixos installed status prints the skip reason" test "$(cat "$tmp/out")" == "sudo-grant=skipped=nixos-config"
fresh
start="$("$date_bin" +%s)"
run_nixos "nixos grant prints the configuration rule" 0 "" grant
check "nixos grant reports the default deadline first" first_out_matches '^ok sudo-grant=skipped=nixos-config minutes=15 until=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
check "nixos grant names the account in the snippet" out_has 'users = [ "vgsuser" ];'
check "nixos grant sets runAs to ALL" out_has 'runAs = "ALL";'
check "nixos grant writes the string command with NOTAFTER" grep -qxE -- '    commands = \[ "NOTAFTER=[0-9]{14}Z NOPASSWD: ALL" \];' "$tmp/out"
check "nixos grant default deadline is 15 minutes out" deadline_in "$start" 15 "$tmp/out"
installed
start="$("$date_bin" +%s)"
run_nixos "nixos grant 60 prints the configuration rule" 0 "" grant 60
check "nixos grant 60 reports the deadline first" first_out_matches '^ok sudo-grant=skipped=nixos-config minutes=60 until=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
check "nixos grant 60 deadline is 60 minutes out" deadline_in "$start" 60 "$tmp/out"
for verb in revoke install uninstall; do
  fresh
  run_nixos "nixos $verb is skipped" 0 "" "$verb"
  check "nixos $verb reports the skip reason" test "$(head -n 1 "$tmp/out")" == "ok sudo-grant=skipped=nixos-config"
done
fresh
run_nixos "nixos grant bad minutes is refused" 2 "vgs-sudo-grant: refused: minutes=1441" grant 1441
fresh
printf 'Admin\n' >"$tmp/account"
run_nixos "nixos grant refuses an unsupported account" 1 "vgs-sudo-grant: refused: account=unsupported name=Admin" grant
fresh
run_nixos_no_nix "nixos os-release without nix uses the normal path" 0 "" status
check "nixos without nix reports the normal absent root half" test "$(cat "$tmp/out")" == "sudo-grant=inactive root-half=absent"
check "nixos without nix still leaves the tree unchanged" cmp -s -- "$tmp/before-tree" "$tmp/after-tree"
check "nixos without nix makes no sudo call on a fresh status" test ! -e "$tmp/sudo.log"
fresh
run_nixos_no_node "nixos without node refuses detection" 1 "vgs-sudo-grant: refused: system=undetected exit=127" status
check "nixos without node makes no sudo call" test ! -e "$tmp/sudo.log"
check "nixos without node leaves the tree unchanged" cmp -s -- "$tmp/before-tree" "$tmp/after-tree"
check "nixos without node writes no sudoers rule" no_rule

# install prints what it places, then places the boot cleanup and then the
# root half, each root's, and drops the credential.
fresh
run "install succeeds" 0 "" install
check "install names the boot cleanup and its line" out_has "  $boot  the boot cleanup: r! /etc/sudoers.d/99-vgs-nopasswd-*"
check "install names the root half" out_has "  $installed  the root half vgsh sudo grant runs through sudo"
check "install prints its paths last" test "$(tail -n 1 "$tmp/out")" == "ok sudo-grant=installed root-half=$installed boot-cleanup=$boot"
check "install places the boot cleanup, then the root half, then drops the credential" test "$(sudo_calls)" == "install -m 0644 -o root -g root -T -- $template $boot
install -m 0755 -o root -g root -T -- $helper $installed
-k"
check "the root half is this helper byte for byte" cmp -s -- "$helper" "$installed"
check "the boot cleanup is the template byte for byte" cmp -s -- "$template" "$boot"
check "the modes are 0755 and 0644" test "$("$stat_bin" -c %a -- "$installed") $("$stat_bin" -c %a -- "$boot")" == "755 644"
fresh; printf 'r /etc/sudoers.d/*\n' >>"$template"
run "a template with another line is not installed" 1 "vgs-sudo-grant: refused: template=malformed path=$template" install
check "a malformed template runs no sudo" test ! -e "$tmp/sudo.log"
cp -- "$repo/bin/lib/tmpfiles.d/vgs-sudo-grant.conf" "$template"
fresh; printf '1\n' >"$tmp/sudo-exit"
run "a failed boot cleanup install stops before the root half" 1 "vgs-sudo-grant: refused: install=boot-cleanup path=$boot" install
check "a failed install places no root half" test ! -e "$installed"

# status through the root half: sudo -h, a cold credential, one sudo -N, the credential dropped.
installed
run "status with nothing granted" 0 "" status
check "status reports inactive and a current root half" test "$(cat "$tmp/out")" == "sudo-grant=inactive root-half=current"
check "status asks the root half through sudo -N from a cold credential" test "$(sudo_calls)" == "-h
-k
-N -- $installed __status $uid
-k"

# A grant with no terminal refuses at the question and writes nothing.
installed
run "grant with no terminal is refused at the question" 2 "*" grant
check "the no-terminal refusal is the library's" grep -qxF -- "vgs-tui: refused: confirm=no-terminal" "$tmp/err"
check "a grant with no answer writes no rule" no_rule
check "a grant with no answer arms no timer" test ! -e "$tmp/systemd-run.log"

# A grant: the warning, one question defaulting to no, the rule checked by
# visudo, the expiry armed for the deadline, the rule published by rename,
# and the grant proven effective.
installed
start="$("$date_bin" +%s)"
run_tty "a granted grant succeeds" 0 grant
check "the grant warns before it asks" out_has "WARNING: for the next 15 minutes, ANY process running as"
check "the grant asks once, defaulting to no" test "$(cat "$tmp/gum.log")" == "$(printf '%s\n' confirm --default=false -- "Enable passwordless sudo for 15 minutes? This is a significant security risk!")"
check "the rule is the one grant for the account" grep -qxE -- "vgsuser ALL=\(ALL\) NOTAFTER=[0-9]{14}Z NOPASSWD: ALL" "$rule"
check "the rule holds one line" test "$(wc -l <"$rule")" == 1
check "visudo checked the rule that was published" cmp -s -- "$tmp/checked-rule" "$rule"
check "the rule is mode 0440" test "$("$stat_bin" -c %a -- "$rule")" == 440
check "the default deadline is 15 minutes out" deadline_in "$start" 15
check "the staged file is gone" test "$(ls -A -- "$root/etc/sudoers.d")" == "99-vgs-nopasswd-$uid"
check "the expiry removes the rule at the deadline" test "$(cat "$tmp/systemd-run.log")" == "--quiet --collect --on-calendar=@$(deadline_epoch) --timer-property=AccuracySec=1s --unit=$unit -- $root/usr/bin/rm -f -- $rule"
check "the grant is proven effective through sudo -n" grep -qxF -- "-n -N -- /usr/bin/true" "$tmp/sudo.log"
check "the grant reports its deadline" out_has "ok sudo-grant=enabled minutes=15 until="
check "the root half's children see no caller variable" test -s "$tmp/visudo-env" -a "$(grep -c '^VGS_PLANTED=' "$tmp/visudo-env")" == 0
check "the root half's children see sudo's caller" grep -qxF -- "SUDO_UID=$uid" "$tmp/visudo-env"
run "status reports the active grant" 0 "" status
check "status names the deadline" grep -qxE -- "sudo-grant=active until=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z root-half=current" "$tmp/out"

# A second run revokes: no question, the timer stopped, the rule gone.
rm -f -- "$tmp/gum.log" "$tmp/systemctl.log"
run_tty "a second grant revokes" 0 grant
check "the second run reports the revoke" out_has "ok sudo-grant=revoked"
check "the second run asks nothing" test ! -e "$tmp/gum.log"
check "the revoke removes the rule" no_rule
check "the revoke stops the expiry" grep -qxF -- "stop $unit.timer" "$tmp/systemctl.log"
check "the stopped expiry is no longer active" test ! -e "$tmp/timer-active"
run "revoke with nothing granted" 0 "" revoke
check "revoke reports nothing to end" test "$(cat "$tmp/out")" == "ok sudo-grant=inactive"

# The bounds are inclusive; an unattended caller is still asked.
for minutes in 1 1440; do
  installed; start="$("$date_bin" +%s)"
  run_tty "a grant of $minutes minutes succeeds" 0 grant "$minutes"
  check "a grant of $minutes minutes ends $minutes minutes out" deadline_in "$start" "$minutes"
done
installed; tty_env=(VGS_TUI_UNATTENDED=1)
run_tty "an unattended grant runs" 0 grant
check "an unattended grant is still asked" test -e "$tmp/gum.log"
tty_env=()

# A declined or cancelled question and each failed step write nothing.
installed; printf '1\n' >"$tmp/gum-answer"
run_tty "a declined grant is refused" 1 grant
check "a declined grant names the decline" out_has "vgs-sudo-grant: refused: declined=grant"
check "a declined grant writes no rule" no_rule
installed; printf '130\n' >"$tmp/gum-answer"
run_tty "a cancelled grant exits 130" 130 grant
check "a cancelled grant writes no rule" no_rule
installed; printf '1\n' >"$tmp/visudo-exit"
run_tty "a rule visudo refuses fails the grant" 1 grant
check "the refusal names visudo" out_has "vgs-sudo-grant: refused: rule=refused"
check "a refused rule leaves no file" no_rule
check "a refused rule arms no timer" test ! -e "$tmp/systemd-run.log"
installed; printf '1\n' >"$tmp/arm-exit"
run_tty "a timer that cannot be armed fails the grant" 1 grant
check "the refusal names the timer" out_has "vgs-sudo-grant: refused: timer=arm-failed unit=$unit"
check "an unarmed timer leaves no file" no_rule
installed; touch "$tmp/date-junk"
run_tty "a malformed deadline fails the grant" 1 grant
check "the refusal names the deadline" out_has "vgs-sudo-grant: refused: deadline=malformed value=2026-01-01"
check "a malformed deadline leaves no file" no_rule
installed; touch "$tmp/sudo-ignores"
run_tty "a grant sudo does not honour is revoked" 1 grant
check "the refusal names the ineffective grant" out_has "vgs-sudo-grant: refused: grant=not-effective revoke-exit=0"
check "an ineffective grant leaves no file" no_rule
check "an ineffective grant's timer is stopped" test ! -e "$tmp/timer-active"
installed; rm -f -- "$boot"
run_tty "a grant with no boot cleanup is refused" 1 grant
check "the root half names the absent boot cleanup" out_has "vgs-sudo-grant: refused: boot-cleanup=absent path=$boot"
check "no boot cleanup, no rule" no_rule
installed; printf 'r /tmp/x\n' >>"$boot"
run_tty "a boot cleanup with another line is refused" 1 grant
check "a changed boot cleanup leaves no file" no_rule
installed; printf '%s\n' "$boot" >"$tmp/foreign"
run_tty "a boot cleanup another user owns is refused" 1 grant
check "a foreign boot cleanup leaves no file" no_rule
installed; chmod 0777 "$root/etc/sudoers.d"
run_tty "a writable sudoers.d is refused" 1 grant
check "the refusal names the directory" out_has "vgs-sudo-grant: refused: untrusted=$root/etc/sudoers.d"
installed; printf 'Admin\n' >"$tmp/account"
run_tty "an account name sudoers would misread is refused" 1 grant
check "the refusal names the account" out_has "vgs-sudo-grant: refused: account=unsupported name=Admin"
check "a refused account leaves no file" no_rule
installed; touch "$tmp/sudo-old"
run "a sudo without -N is refused" 1 "vgs-sudo-grant: refused: sudo=no-update-unsupported" grant
check "a sudo without -N is asked nothing else" test "$(sudo_calls)" == "-h"
installed; printf '# changed\n' >>"$installed"
run "a stale root half refuses the grant" 1 "vgs-sudo-grant: refused: root-half=stale path=$installed" grant
run "status reports a stale root half" 0 "" status
check "status names the stale root half" test "$(cat "$tmp/out")" == "sudo-grant=inactive root-half=stale"
installed; printf '1\n' >"$tmp/sudo-exit"
run "a wrong password fails status" 1 "vgs-sudo-grant: refused: status=failed exit=1 reply=''" status

# A rule the root half finds: an expired one is removed as found; one not
# of its form is reported and removed only by revoke.
installed
printf 'vgsuser ALL=(ALL) NOTAFTER=20000101000000Z NOPASSWD: ALL\n' >"$rule"
run "status with an expired rule" 0 "" status
check "an expired rule reads as inactive" test "$(cat "$tmp/out")" == "sudo-grant=inactive root-half=current"
check "an expired rule is removed" test ! -e "$rule"
printf 'vgsuser ALL=(ALL) NOPASSWD: ALL\n' >"$rule"
run "status with a rule of another form fails" 1 "vgs-sudo-grant: refused: grant=malformed path=$rule" status
run_tty "grant with a rule of another form fails" 1 grant
check "a grant leaves the other rule for revoke" test -e "$rule"
run "revoke removes a rule of another form" 0 "" revoke
check "revoke reports the removal" test "$(cat "$tmp/out")" == "ok sudo-grant=revoked"
check "the other rule is gone" test ! -e "$rule"
printf 'vgsuser ALL=(ALL) NOTAFTER=29990101000000Z NOPASSWD: ALL\n' >"$rule"; chmod 0666 "$rule"
run "a rule others can write is not read as a grant" 1 "vgs-sudo-grant: refused: grant=malformed path=$rule" status

# The root half itself: its startup, its actions, its caller.
installed
root "the root half refuses the user's verbs" 1 "vgs-sudo-grant: refused: root=grant" grant
root "the root half refuses an action it does not know" 2 "vgs-sudo-grant: refused: argument=__expire count=2" __expire "$uid"
root "the root half refuses an extra argument" 2 "vgs-sudo-grant: refused: argument=__status count=3" __status "$uid" x
root "the root half refuses minutes past the bound" 2 "vgs-sudo-grant: refused: minutes=1441" __enable "$uid" 1441
root "the root half refuses a uid that is not a number" 2 "vgs-sudo-grant: refused: uid=x" __status x
root_caller=0
root "the root half refuses root's own uid" 2 "vgs-sudo-grant: refused: uid=0" __status 0
root_caller=4242
root "the root half refuses another user's uid" 1 "vgs-sudo-grant: refused: caller=mismatch uid=$uid sudo-uid=4242" __enable "$uid" 15
check "another user's enable writes no rule" no_rule
root_caller="$uid"
root "the root half answers its caller" 3 "" __status "$uid"
check "the root half prints inactive" test "$(cat "$tmp/out")" == inactive
unprivileged() {
  local status=0 err
  err="$("${row_env[@]}" "$unshare_bin" -r env SUDO_UID="$uid" "$BASH" "$installed" __status "$uid" 2>&1 >/dev/null </dev/null)" || status=$?
  test "${err%%$'\n'*} exit=$status" == "vgs-sudo-grant: refused: startup=unprivileged exit=2"
}
check "the root half refuses a bash started without -p" unprivileged

# uninstall revokes the user's grant, removes every account's grant through
# the boot cleanup's own line, then removes the root half and the boot cleanup.
other="$root/etc/sudoers.d/99-vgs-nopasswd-4242"
installed
run_tty "a grant before uninstall" 0 grant
printf 'other ALL=(ALL) NOTAFTER=29990101000000Z NOPASSWD: ALL\n' >"$other"
run "uninstall succeeds" 0 "" uninstall
check "uninstall reports it" test "$(tail -n 1 "$tmp/out")" == "ok sudo-grant=uninstalled"
check "uninstall revokes the grant" test ! -e "$rule"
check "uninstall runs the boot cleanup's line now" test "$(cat "$tmp/tmpfiles.log")" == "--remove --boot -- $boot"
check "uninstall removes another account's grant" test ! -e "$other"
check "uninstall removes the root half and the boot cleanup" test ! -e "$installed" -a ! -e "$boot"
installed
printf 'other ALL=(ALL) NOTAFTER=29990101000000Z NOPASSWD: ALL\n' >"$other"; printf '1\n' >"$tmp/tmpfiles-exit"
run "uninstall stops when the grants cannot be removed" 1 "vgs-sudo-grant: refused: uninstall=grants path=$boot" uninstall
check "a stopped uninstall keeps the root half and the boot cleanup" test -e "$installed" -a -e "$boot"

# Must-fail controls, each on a copy of the helper missing one rule, placed
# and installed as its own root half.
control() { # NAME NEEDLE REPLACEMENT
  local copy="$tmp/control-$1"
  check "the $1 control's text occurs once" test "$(grep -c -F -- "$2" "$source_file")" == 1
  python3 -c 'import sys; p, o, a, b = sys.argv[1:]; s = open(p).read(); open(o, "w").write(s.replace(a, b))' "$source_file" "$copy" "$2" "$3"
  check "the $1 mutant differs" test "$(cmp -s "$source_file" "$copy"; echo $?)" == 1
  place "$copy"
  installed
}
control nixos-write "  printf 'NixOS builds /etc from its configuration, so VGS writes no sudo rule here.\n'" "  : >\"\$(rule_path \"\$uid\")\"
  printf 'NixOS builds /etc from its configuration, so VGS writes no sudo rule here.\n'"
run_nixos_dirty "the nixos-write mutant grants" 0 "" grant
check "the nixos-write mutant changes the tree" tree_changed
check "the nixos-write mutant writes the rule path" test -e "$rule"
control nixos-blind 'if [[ $detected_system == nix ]]; then' 'if false; then'
run_nixos_dirty "the nixos-blind mutant reaches the normal status" 0 "" status
check "the nixos-blind mutant prints the normal status" test "$(cat "$tmp/out")" == "sudo-grant=inactive root-half=current"
check "the nixos-blind mutant reaches sudo" test -e "$tmp/sudo.log"
control skip-visudo 'visudo -cqf "$enable_staged" >/dev/null ||' 'true ||'
printf '1\n' >"$tmp/visudo-exit"
run_tty "the skip-visudo mutant grants" 0 grant
check "the skip-visudo mutant publishes a rule visudo refused" test -e "$rule"
control wide-minutes '((10#$1 <= max_minutes))' '((10#$1 <= max_minutes + 1))'
run_tty "the wide-minutes mutant grants 1441 minutes" 0 grant 1441
check "the wide-minutes mutant publishes a 1441-minute rule" test -e "$rule"
control deadline-blind '[[ $deadline =~ ^[0-9]{14}Z$ ]] ||' 'true ||'
touch "$tmp/date-junk"
run_tty "the deadline-blind mutant's grant runs" 1 grant
check "the deadline-blind mutant publishes a malformed deadline" grep -qF "NOTAFTER=2026-01-01 " "$rule"
control caller-blind '[[ ${SUDO_UID:-} == "$1" ]] ||' 'true ||'
root_caller=4242
root "the caller-blind mutant enables for another user" 0 "" __enable "$uid" 15
root_caller="$uid"
control startup-blind '[[ $- == *p* ]] ||' 'true ||'
check "the startup-blind mutant runs under a plain bash" test "$(unprivileged; echo $?)" == 1
control unsanitized '  sanitize "$@"' '  :'
run_tty "the unsanitized mutant grants" 0 grant
check "the unsanitized mutant hands the caller's variable to visudo" grep -qxF VGS_PLANTED=1 "$tmp/visudo-env"
control boot-blind 'trusted "$tmpfiles_d" && trusted "$boot_file" && [[ $(boot_lines "$boot_file") == "$boot_rule" ]] ||' 'true ||'
rm -f -- "$boot"
run_tty "the boot-blind mutant grants with no boot cleanup" 0 grant
control mode-blind '(((8#${info#* } & 8#022) == 0))' 'true'
chmod 0777 "$root/etc/sudoers.d"
run_tty "the mode-blind mutant grants into a writable sudoers.d" 0 grant
control owner-blind '[[ $info == "0 "* ]] && ' ''
printf '%s\n' "$boot" >"$tmp/foreign"
run_tty "the owner-blind mutant grants with a foreign boot cleanup" 0 grant
control effect-blind 'if ! sudo -n -N -- /usr/bin/true' 'if false'
touch "$tmp/sudo-ignores"
run_tty "the effect-blind mutant reports an ineffective grant" 0 grant
control no-toggle 'if [[ $state == active ]]; then' 'if false; then'
run_tty "the no-toggle mutant grants" 0 grant
rm -f -- "$tmp/gum.log"
run_tty "the no-toggle mutant fails the second run" 1 grant
check "the no-toggle mutant asks again instead of revoking" test -e "$tmp/gum.log"
control unattended "VGS_TUI_UNATTENDED='' vgs_tui_confirm" 'vgs_tui_confirm'
tty_env=(VGS_TUI_UNATTENDED=1)
run_tty "the unattended mutant grants" 0 grant
check "the unattended mutant asks nothing" test ! -e "$tmp/gum.log"
tty_env=()
control expiry-blind '[[ $now < $grant_deadline ]] && return 0' 'return 0'
printf 'vgsuser ALL=(ALL) NOTAFTER=20000101000000Z NOPASSWD: ALL\n' >"$rule"
run "the expiry-blind mutant's status" 0 "" status
check "the expiry-blind mutant reads an expired rule as active" grep -q "^sudo-grant=active until=2000-01-01T00:00:00Z" "$tmp/out"
control account-blind '[[ $name =~ ^[a-z_][a-z0-9_-]{0,31}\$?$ ]] ||' 'true ||'
printf 'Admin\n' >"$tmp/account"
run_tty "the account-blind mutant grants for Admin" 0 grant
control stale-blind '[[ $(root_half_state) == current ]] ||' 'true ||'
printf '# changed\n' >>"$installed"
run_tty "the stale-blind mutant grants through a stale root half" 0 grant
control no-update-blind "grep -Eq '^usage: sudo .*\[[^]]*N[^]]*\]' <<<\"\$help\" ||" 'true ||'
touch "$tmp/sudo-old"
run "the no-update-blind mutant reaches the root half" 0 "" status
control warm-sudo '  sudo -k || refuse 1 "sudo=reset-failed"' '  true'
run "the warm-sudo mutant's status" 0 "" status
check "the warm-sudo mutant keeps the cached credential" test "$(sed -n 2p "$tmp/sudo.log")" == "-N -- $installed __status $uid"
control grants-kept '    sudo systemd-tmpfiles --remove --boot -- "$boot_file" </dev/null ||' '    true ||'
printf 'other ALL=(ALL) NOTAFTER=29990101000000Z NOPASSWD: ALL\n' >"$other"
run "the grants-kept mutant uninstalls" 0 "" uninstall
check "the grants-kept mutant leaves another account's grant without its boot cleanup" test -e "$other" -a ! -e "$boot"

rows_done "$suite"
