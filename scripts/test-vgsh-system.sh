#!/usr/bin/env bash
# Controls for bin/vgsh-system, the closed table of system steps reached
# through `vgsh system`: the verbs and their arguments, each step's probe,
# root commands and record bytes, the one question before any write, the
# refusal of a destination VGS did not write, an undo that reverts only
# what VGS changed, the record's owner, and the NixOS configuration-only
# path. Every row runs a copy of vgsh and of the helper whose `prefix` is a
# temporary tree, so its /etc, /sys, /dev, /proc, /var and /usr are that
# tree's: sudo, gum, stat, udevadm, systemctl, modprobe and tailscale are
# stand-ins there, and the sudo stand-in runs each command under
# `unshare -r`, where the tree reads as root's and nothing outside it is
# writable, so no row reaches the real /etc, /dev, sudo, udev, systemd or
# tailscaled. NixOS rows bind a fixture over /etc/os-release in a private
# mount namespace, as scripts/test-vgsh-sudo-grant.sh does. The controls
# are copies of the helper missing one rule each.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
suite=test-vgsh-system
source_file="$repo/bin/vgsh-system"
uid="$(id -u)"; gid="$(id -g)"; user="$(id -un)"
((uid != 0)) || { echo "$suite: status=not-measured reason=runs-as-root"; exit 77; }
for tool in unshare setsid script find mount sh sha256sum; do
  command -v "$tool" >/dev/null || { echo "$suite: status=not-measured missing=$tool"; exit 77; }
done
unshare_bin="$(command -v unshare)"; setsid_bin="$(command -v setsid)"; script_bin="$(command -v script)"
mount_bin="$(command -v mount)"; sh_bin="$(command -v sh)"; stat_bin="$(command -v stat)"
"$unshare_bin" -r true 2>/dev/null || { echo "$suite: status=not-measured missing=user-namespaces"; exit 77; }

root="$tmp/root"; bin="$root/usr/bin"
vgs="$tmp/vgs"; helper="$vgs/bin/vgsh-system"
rule_src="$vgs/config/system/udev/60-vgs-apple-displays.rules"
rule="$root/etc/udev/rules.d/60-vgs-apple-displays.rules"
records="$root/var/lib/vgs/system"
hidraw="$root/dev/hidraw0"
mkdir -p "$bin" "$vgs/bin" "$vgs/shell/Core" "$vgs/config/system/udev" "$tmp/home"
cp -- "$repo/bin/vgsh" "$vgs/bin/vgsh"
cp -- "$repo/bin/vgsh-pkg" "$vgs/bin/vgsh-pkg"
cp -R -- "$repo/bin/lib" "$vgs/bin/lib"
cp -- "$repo/shell/Core/PackageManagers.js" "$vgs/shell/Core/PackageManagers.js"
cp -- "$repo/config/system/udev/60-vgs-apple-displays.rules" "$rule_src"
for tool in awk cat chmod chown env flock id install mkdir mv readlink rm sed sha256sum sleep kill tee touch; do
  tool_bin="$(command -v "$tool")" || { echo "$suite: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$bin/$tool"
done
# stat reports owner 0 for the suite's own files, as the tree reads under
# unshare -r, and owner 1234 for the path $tmp/foreign names.
cat >"$bin/stat" <<EOF
#!/bin/sh
out="\$($stat_bin "\$@")" || exit \$?
for last; do :; done
if [ -f "$tmp/foreign" ] && [ "\$last" = "\$(cat "$tmp/foreign")" ]; then printf '%s\n' "\$out" | sed 's/^[0-9]* /1234 /'; else printf '%s\n' "\$out" | sed 's/^$uid /0 /'; fi
EOF
# sudo: -k and -n are recorded and answer at once; any other call is
# recorded, exits with $tmp/sudo-exit when present, else runs its command
# as the namespace's root.
cat >"$bin/sudo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/sudo.log"
case "\$1" in -k|-n) exit 0 ;; esac
[ "\$1" = -- ] && shift
if [ -f "$tmp/sudo-exit" ]; then read -r st <"$tmp/sudo-exit"; exit "\$st"; fi
exec $unshare_bin -r "\$@"
EOF
# udevadm: a trigger gives the Apple node the access the rule grants while
# the VGS rule or $tmp/v1-rule exists, and takes it away otherwise; it
# fails while $tmp/udev-fail exists.
cat >"$bin/udevadm" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/udevadm.log"
[ -e "$tmp/udev-fail" ] && exit 1
if [ "\$1" = trigger ]; then
  if [ -e "$rule" ] || [ -e "$tmp/v1-rule" ]; then chmod 0600 "$hidraw"; else chmod 0000 "$hidraw"; fi
fi
exit 0
EOF
# systemctl answers from $tmp/units/<unit>.{active,enabled,masked,missing}.
cat >"$bin/systemctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/systemctl.log"
u="$tmp/units"
case "\$1 \$2" in
  "is-active --quiet") [ -e "\$u/\$3.active" ] ;;
  "is-enabled --quiet") [ -e "\$u/\$3.enabled" ] ;;
  "show --property=LoadState")
    if [ -e "\$u/\$4.missing" ]; then echo not-found; elif [ -e "\$u/\$4.masked" ]; then echo masked; else echo loaded; fi ;;
  "enable --now") touch "\$u/\$3.enabled" "\$u/\$3.active" ;;
  "disable "*) rm -f "\$u/\$2.enabled" ;;
  "stop "*) rm -f "\$u/\$2.active" ;;
  *) exit 64 ;;
esac
EOF
# modprobe i2c-dev registers the class and the display adapter's node,
# readable while $tmp/i2c-rule exists; -r takes both away.
cat >"$bin/modprobe" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/modprobe.log"
case "\$*" in
  i2c-dev)
    mkdir -p "$root/sys/class/i2c-dev"; : >"$root/dev/i2c-5"
    if [ -e "$tmp/i2c-rule" ]; then chmod 0600 "$root/dev/i2c-5"; else chmod 0000 "$root/dev/i2c-5"; fi ;;
  "-r i2c-dev") rm -rf "$root/sys/class/i2c-dev" "$root/dev/i2c-5" ;;
  *) exit 64 ;;
esac
EOF
# tailscale: the operator lives in $tmp/operator; get fails while
# $tmp/tailscaled-down exists.
cat >"$bin/tailscale" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$tmp/tailscale.log"
[ -e "$tmp/tailscaled-down" ] && { echo 'failed to connect to local tailscaled' >&2; exit 1; }
case "\$1" in
  get) [ "\$2" = operator ] || exit 64; cat "$tmp/operator" ;;
  set) case "\$2" in --operator=*) printf '%s' "\${2#--operator=}" >"$tmp/operator" ;; *) exit 64 ;; esac ;;
  *) exit 64 ;;
esac
EOF
# gum confirm records its arguments, runs $tmp/gum-hook when present and
# answers with $tmp/gum-answer.
cat >"$bin/gum" <<EOF
#!/bin/sh
[ "\$1" = confirm ] || exit 0
printf '%s\n' "\$@" >"$tmp/gum.log"
[ -x "$tmp/gum-hook" ] && "$tmp/gum-hook"
read -r st <"$tmp/gum-answer"
exit "\$st"
EOF
chmod +x "$bin"/stat "$bin"/sudo "$bin"/udevadm "$bin"/systemctl "$bin"/modprobe "$bin"/tailscale "$bin"/gum

# SOURCE's `prefix=` line, which must occur once, names the tree.
place() { # SOURCE
  check "the helper's prefix line occurs once" test "$(grep -c '^prefix=$' "$1")" == 1
  sed "s|^prefix=\$|prefix=$root|" "$1" >"$helper"
  chmod +x "$helper"
  check "the placed helper names the tree" test "$(grep -c "^prefix=$root\$" "$helper")" == 1
}
boot_a=11111111-2222-3333-4444-555555555555
boot_b=99999999-8888-7777-6666-555555555555
# A tree with one Apple display whose hidraw node is closed to the user,
# one other HID device, one display-class i2c adapter beside one that is
# not, no i2c-dev module, bluetooth installed and stopped, no tailscaled,
# no operator, and every record cleared.
fresh() {
  rm -rf -- "${root:?}/etc" "${root:?}/sys" "${root:?}/dev" "${root:?}/var" "${root:?}/proc" "$tmp/units"
  mkdir -p "$root/etc/udev/rules.d" "$root/dev" "$root/var/lib" "$root/proc/sys/kernel/random" "$tmp/units"
  chmod 0755 "$root/etc" "$root/etc/udev" "$root/etc/udev/rules.d" "$root/var" "$root/var/lib"
  mkdir -p "$root/sys/class/hidraw/hidraw0/device" "$root/sys/class/hidraw/hidraw1/device"
  printf 'DRIVER=hid-generic\nHID_ID=0003:000005AC:00009243\nHID_NAME=Apple Inc. Pro Display XDR\n' >"$root/sys/class/hidraw/hidraw0/device/uevent"
  printf 'HID_ID=0003:0000046D:0000C52B\n' >"$root/sys/class/hidraw/hidraw1/device/uevent"
  : >"$hidraw"; : >"$root/dev/hidraw1"; chmod 0000 "$hidraw"; chmod 0600 "$root/dev/hidraw1"
  local gpu="$root/sys/devices/pci0000:00/0000:00:01.0"
  mkdir -p "$gpu/drm/card1/card1-DP-1/i2c-5" "$root/sys/devices/platform/i2c-0" "$root/sys/bus/i2c/devices"
  printf '0x030000\n' >"$gpu/class"
  ln -s ../../../devices/pci0000:00/0000:00:01.0/drm/card1/card1-DP-1/i2c-5 "$root/sys/bus/i2c/devices/i2c-5"
  ln -s ../../../devices/platform/i2c-0 "$root/sys/bus/i2c/devices/i2c-0"
  printf '%s\n' "$boot_a" >"$root/proc/sys/kernel/random/boot_id"
  touch "$tmp/units/tailscaled.service.missing"
  : >"$tmp/operator"
  rm -f -- "$tmp"/{sudo.log,udevadm.log,systemctl.log,modprobe.log,tailscale.log,gum.log,gum-hook,foreign,sudo-exit,udev-fail,v1-rule,i2c-rule,tailscaled-down,before-tree,after-tree}
  printf '0\n' >"$tmp/gum-answer"
}
caller="$tmp/caller"; mkdir -p "$caller"
ln -s -- "$node_bin" "$caller/node"
nixos_path="$tmp/nixos-path"; mkdir -p "$nixos_path"
printf '#!/bin/sh\nexit 0\n' >"$nixos_path/nix"; chmod +x "$nixos_path/nix"
no_node_path="$tmp/no-node-path"; mkdir -p "$no_node_path"
for tool in bash readlink dirname id; do
  tool_bin="$(command -v "$tool")" || { echo "$suite: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$no_node_path/$tool"
done
nixos_os_release="$tmp/os-release-nixos"
printf 'NAME=NixOS\nID=nixos\n' >"$nixos_os_release"
nixos_mount_script="$mount_bin --bind \"\$1\" /etc/os-release && shift && exec $unshare_bin --user --map-user=$uid --map-group=$gid \"\$@\""
nixos_probe=0
"$unshare_bin" -rm "$sh_bin" -c "$nixos_mount_script" sh "$nixos_os_release" "$sh_bin" -c "[ \"\$(id -u)\" = \"$uid\" ] && grep -qx ID=nixos /etc/os-release" 2>/dev/null || nixos_probe=$?
((nixos_probe == 0)) || { echo "$suite: status=not-measured missing=nixos-os-release-namespace"; exit 77; }
row_env=(env -i HOME="$tmp/home" PATH="$caller:/usr/bin:/bin" LANG=C.UTF-8)
verdict() { # NAME WANT_EXIT WANT_FIRST_STDERR STATUS
  local err=""
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  if [[ $4 == "$2" && ($3 == "*" || $err == "$3") ]]; then ok "$1"; else fail "$1: exit=$4 want=$2 stderr=[$err] want=[$3]"; fi
}
# run NAME WANT_EXIT WANT_FIRST_STDERR ARGS...: vgsh system ARGS in a
# session with no terminal; `*` takes any stderr. Stdout lands in $tmp/out.
run() {
  local name="$1" want_exit="$2" want_err="$3" status=0
  shift 3
  "${row_env[@]}" "$setsid_bin" -w "$vgs/bin/vgsh" system "$@" </dev/null >"$tmp/out" 2>"$tmp/err" || status=$?
  verdict "$name" "$want_exit" "$want_err" "$status"
}
# run_tty NAME WANT_EXIT ARGS...: the same on a pseudo-terminal; stdout and
# stderr together land in $tmp/out, carriage returns dropped.
tty_env=()
run_tty() {
  local name="$1" want_exit="$2" status=0
  shift 2
  "${row_env[@]}" SHELL="$BASH" "${tty_env[@]}" "$script_bin" -qec "$(printf '%q ' "$vgs/bin/vgsh" system "$@")" /dev/null </dev/null >"$tmp/raw" 2>&1 || status=$?
  tr -d '\r' <"$tmp/raw" >"$tmp/out"
  if [[ $status == "$want_exit" ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit output=[$(cat "$tmp/out")]"; fi
}
tree_snapshot() { find "$root" "$tmp/units" -printf '%P %y %s %m %T@\n' | sort; }
# run_nixos NAME WANT_EXIT WANT_FIRST_STDERR PATH ARGS...: vgsh system with
# NixOS's os-release bound, the tree snapshotted around it.
run_nixos() {
  local name="$1" want_exit="$2" want_err="$3" path_value="$4" status=0
  shift 4
  tree_snapshot >"$tmp/before-tree"
  env -i HOME="$tmp/home" PATH="$path_value" LANG=C.UTF-8 \
    "$unshare_bin" -rm "$sh_bin" -c "$nixos_mount_script" sh "$nixos_os_release" "$setsid_bin" -w "$vgs/bin/vgsh" system "$@" \
    </dev/null >"$tmp/out" 2>"$tmp/err" || status=$?
  tree_snapshot >"$tmp/after-tree"
  verdict "$name" "$want_exit" "$want_err" "$status"
}
untouched() { cmp -s -- "$tmp/before-tree" "$tmp/after-tree"; }
out_has() { grep -qF -- "$1" "$tmp/out"; }
out_is() { test "$(cat "$tmp/out")" == "$1"; }
last_out_is() { test "$(tail -n 1 "$tmp/out")" == "$1"; }
sudo_calls() { cat -- "$tmp/sudo.log" 2>/dev/null; }
no_sudo() { test ! -e "$tmp/sudo.log"; }
state_json() { # STATE-REASON per step, table order
  printf '{"steps":{"apple-displays":{"state":"%s","reason":"%s"},"i2c-dev":{"state":"%s","reason":"%s"},"service-bluetooth":{"state":"%s","reason":"%s"},"service-tailscaled":{"state":"%s","reason":"%s"},"tailscale-operator":{"state":"%s","reason":"%s"}}}' "$@"
}
step_state() { # STEP: the state status --json reads for it
  "${row_env[@]}" "$vgs/bin/vgsh" system status --json </dev/null 2>/dev/null |
    python3 -c 'import json,sys; s=json.load(sys.stdin)["steps"][sys.argv[1]]; print(s["state"] + " " + s["reason"])' "$1"
}
# The sudo calls one session makes: the cold start, the password check,
# each COMMAND as one line, and the credential dropped at the end.
session() { printf '%s\n' -k /usr/bin/true "$@" -k; }
p() { printf '%s' "$bin/$1"; }
place "$source_file"

# vgsh's own refusal of a subcommand it does not route.
fresh
run "vgsh system with no subcommand is refused" 2 "vgsh: refused: system-subcommand=missing"
run "an unknown system subcommand is refused" 2 "vgsh: refused: system-subcommand=grant" grant

# Arguments, refused before any probe or sudo.
run "apply with no step is refused" 2 "vgs-system: refused: count=0 verb=apply" apply
run "apply takes one step" 2 "vgs-system: refused: count=2 verb=apply" apply apple-displays i2c-dev
run "an unknown step is refused" 2 "vgs-system: refused: step=etc-shadow" apply etc-shadow
run "undo refuses an unknown step" 2 "vgs-system: refused: step=apple" undo apple
run "a step name with a path is refused" 2 "vgs-system: refused: step=../apple-displays" apply ../apple-displays
run "status takes only --json" 2 "vgs-system: refused: argument=x" status x
check "a refused invocation runs no sudo" no_sudo
check "a refused invocation asks nothing" test ! -e "$tmp/gum.log"

# status: each probe reads real access, in table order.
run "status reads every step" 0 "" status --json
check "status names each step's state and reason" out_is "$(state_json needed hidraw-denied needed module-not-loaded needed inactive absent unit-missing needed operator-unset)"
# The manifest judge names steps from PluginLogic.SYSTEM_STEPS; the
# script's own table must be that list, in that order.
table_keys() { python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["steps"]))' "$tmp/out"; }
judge_steps() { "$node_bin" -e 'const { load } = require(process.argv[1]); process.stdout.write(load(process.argv[2]).SYSTEM_STEPS.join(" "))' "$repo/bin/lib/qml-library.js" "$repo/shell/Core/PluginLogic.js"; }
check "the script's step table is the manifest judge's" test "$(table_keys)" == "$(judge_steps)"
run "status prints one line per step" 0 "" status
check "the line form names the Apple step first" test "$(head -n 1 "$tmp/out")" == "system=apple-displays state=needed reason=hidraw-denied"
check "status runs no sudo" no_sudo
chmod 0600 "$hidraw"; : >"$tmp/v1-rule"; printf 'v1 rule\n' >"$root/etc/udev/rules.d/60-vshell-apple-displays.rules"
check "an Apple node another rule opened reads ready" test "$(step_state apple-displays)" == "ready granted"
rm -f -- "$hidraw"
check "an Apple display with no node reads unknown" test "$(step_state apple-displays)" == "unknown node-missing"
rm -rf -- "$root/sys/class/hidraw/hidraw0"
check "no Apple display reads absent" test "$(step_state apple-displays)" == "absent no-device"
fresh; chmod 0000 "$root/sys/class/hidraw/hidraw0/device/uevent"
check "an unreadable HID device reads unknown, never ready" test "$(step_state apple-displays)" == "unknown sysfs-unreadable"
fresh; mkdir -p "$root/sys/class/i2c-dev"; : >"$root/dev/i2c-5"; chmod 0000 "$root/dev/i2c-5"
check "a loaded module with a closed display node reads denied" test "$(step_state i2c-dev)" == "denied no-uaccess-rule"
chmod 0600 "$root/dev/i2c-5"
check "an open display node reads ready" test "$(step_state i2c-dev)" == "ready granted"
rm -f -- "$root/sys/bus/i2c/devices/i2c-5"
check "no display-class adapter reads absent" test "$(step_state i2c-dev)" == "absent no-adapter"
fresh; touch "$tmp/units/bluetooth.service.masked"
check "a masked unit reads denied" test "$(step_state service-bluetooth)" == "denied unit-masked"
touch "$tmp/units/bluetooth.service.active"
check "an active unit reads ready" test "$(step_state service-bluetooth)" == "ready active"
fresh; printf 'someone' >"$tmp/operator"
check "another user's operator reads denied" test "$(step_state tailscale-operator)" == "denied operator-other"
printf '%s' "$user" >"$tmp/operator"
check "the caller as operator reads ready" test "$(step_state tailscale-operator)" == "ready granted"
touch "$tmp/tailscaled-down"
check "an unreachable tailscaled reads unknown" test "$(step_state tailscale-operator)" == "unknown tailscaled-unreachable"
# A login name the operator cannot take reads that step unknown, the rest
# as before; id answers -un with it while $tmp/odd-user exists.
id_real="$(readlink -- "$bin/id")"
rm -f -- "${bin:?}/id"
printf '#!/bin/sh\nif [ -e %q ] && [ "$1" = -un ]; then echo john.doe; exit 0; fi\nexec %q "$@"\n' "$tmp/odd-user" "$id_real" >"$bin/id"
chmod +x "$bin/id"
fresh; touch "$tmp/odd-user"
run "status with an unsupported login name" 0 "" status --json
check "an unsupported login name reads only the operator unknown" out_is "$(state_json needed hidraw-denied needed module-not-loaded needed inactive absent unit-missing unknown user-unsupported)"
run "apply refuses the operator for an unsupported login name" 1 "vgs-system: refused: state=unknown reason=user-unsupported step=tailscale-operator" apply tailscale-operator
check "the refused operator runs no sudo" no_sudo
rm -f -- "${tmp:?}/odd-user"

# apply asks before anything: with no terminal, declined or cancelled,
# nothing is written and no sudo runs.
fresh; tree_snapshot >"$tmp/before-tree"
run "apply with no terminal is refused at the question" 2 "*" apply apple-displays
check "the no-terminal refusal is the library's" grep -qxF -- "vgs-tui: refused: confirm=no-terminal" "$tmp/err"
tree_snapshot >"$tmp/after-tree"
check "apply with no answer writes nothing" untouched
check "apply with no answer runs no sudo" no_sudo
fresh; printf '1\n' >"$tmp/gum-answer"; tree_snapshot >"$tmp/before-tree"
run_tty "a declined apply is refused" 1 apply apple-displays
check "a declined apply names the decline" out_has "vgs-system: refused: declined=apply step=apple-displays"
tree_snapshot >"$tmp/after-tree"
check "a declined apply writes nothing" untouched
check "a declined apply runs no sudo" no_sudo
fresh; printf '130\n' >"$tmp/gum-answer"; tree_snapshot >"$tmp/before-tree"
run_tty "a cancelled apply exits 130" 130 apply apple-displays
tree_snapshot >"$tmp/after-tree"
check "a cancelled apply writes nothing" untouched
check "a cancelled apply runs no sudo" no_sudo
fresh; tty_env=(VGS_TUI_UNATTENDED=1); printf '1\n' >"$tmp/gum-answer"
run_tty "an unattended apply is still asked" 1 apply apple-displays
check "the unattended apply asked gum" test -e "$tmp/gum.log"
check "the unattended decline runs no sudo" no_sudo
tty_env=()

# apple-displays: the rule's bytes, the record's bytes and each root command.
fresh
run_tty "apply apple-displays succeeds" 0 apply apple-displays
hash="$(sha256sum <"$rule_src")"; hash="${hash%% *}"
check "apply shows the rule's install before asking" out_has "  sudo $(p install) -m 0644 -o root -g root -T -- $rule_src $rule"
check "apply asks one question" test "$(cat "$tmp/gum.log")" == "$(printf '%s\n' confirm -- "Run these commands as root?")"
check "apple-displays runs its commands in one sudo session" test "$(sudo_calls)" == "$(session \
  "-- $(p install) -d -m 0755 -o root -g root -- $records" \
  "-- $(p tee) -- $records/.apple-displays" \
  "-- $(p mv) -fT -- $records/.apple-displays $records/apple-displays" \
  "-- $(p install) -m 0644 -o root -g root -T -- $rule_src $rule" \
  "-- $(p udevadm) control --reload" \
  "-- $(p udevadm) trigger --subsystem-match=hidraw --action=change --settle")"
check "the installed rule is the shipped file byte for byte" cmp -s -- "$rule_src" "$rule"
check "the rule is mode 0644" test "$("$stat_bin" -c %a -- "$rule")" == 644
check "the record names the caller and the rule's hash" test "$(cat "$records/apple-displays")" == "$(printf 'uid=%s\nrule=%s' "$uid" "$hash")"
check "no staged record is left" test "$(ls -A -- "$records")" == apple-displays
check "apply reports the step ready" last_out_is "ok system=apple-displays state=ready"
check "status reads the Apple step ready" test "$(step_state apple-displays)" == "ready granted"
rm -f -- "$tmp/sudo.log"
run "apply on a ready step runs nothing" 0 "" apply apple-displays
check "a ready apply says so" out_is "ok system=apple-displays state=ready"
check "a ready apply runs no sudo" no_sudo
# The shipped rule: the two hidraw lines, uaccess only.
check "the shipped rule holds only the two hidraw lines" test "$(grep -v '^#' "$repo/config/system/udev/60-vgs-apple-displays.rules" | grep -v '^$')" == 'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="1114", TAG+="uaccess"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="9243", TAG+="uaccess"'

# undo of the VGS rule removes it and its record, and reloads udev.
rm -f -- "$tmp/sudo.log"
run_tty "undo apple-displays succeeds" 0 undo apple-displays
check "undo removes the rule, reloads, then drops the record" test "$(sudo_calls)" == "$(session \
  "-- $(p rm) -f -- $rule" \
  "-- $(p udevadm) control --reload" \
  "-- $(p udevadm) trigger --subsystem-match=hidraw --action=change --settle" \
  "-- $(p rm) -f -- $records/apple-displays")"
check "undo leaves no rule and no record" test ! -e "$rule" -a ! -e "$records/apple-displays"
check "undo reports it" last_out_is "ok system=apple-displays state=undone"
rm -f -- "$tmp/sudo.log"
run "undo with no record changes nothing" 0 "" undo apple-displays
check "an untouched undo says so" out_is "ok system=apple-displays state=untouched"
check "an untouched undo runs no sudo" no_sudo

# A rule file VGS did not write is refused before the question, never overwritten.
fresh; printf 'someone else\n' >"$rule"
run "apply refuses a foreign rule file" 1 "vgs-system: refused: destination=foreign path=$rule" apply apple-displays
check "the foreign rule keeps its bytes" test "$(cat "$rule")" == "someone else"
check "a foreign rule asks nothing" test ! -e "$tmp/gum.log"
check "a foreign rule runs no sudo" no_sudo
fresh; ln -s /dev/null "$rule"
run "apply refuses a symbolic link at the destination" 1 "vgs-system: refused: destination=symlink path=$rule" apply apple-displays
check "a symlinked destination runs no sudo" no_sudo
fresh; chmod 0777 "$root/etc/udev/rules.d"
run "apply refuses a rules directory others can write" 1 "vgs-system: refused: untrusted=$root/etc/udev/rules.d" apply apple-displays
# A rule edited after VGS wrote it is foreign to undo, and the record stays.
fresh
run_tty "apply before an edit" 0 apply apple-displays
printf '# edited\n' >>"$rule"
run "undo refuses an edited rule" 1 "vgs-system: refused: destination=foreign path=$rule" undo apple-displays
check "the edited rule stays" grep -qxF '# edited' "$rule"
check "the record stays for the edited rule" test -e "$records/apple-displays"
# A command that fails after the record leaves the record, so undo still
# owns what was written.
fresh; touch "$tmp/udev-fail"
run_tty "a failing udevadm fails apply" 1 apply apple-displays
check "the failure names the command" out_has "vgs-system: refused: command=failed exit=1 argv="
check "the rule written before the failure is on record" test -e "$rule" -a -e "$records/apple-displays"
rm -f -- "$tmp/udev-fail"
run_tty "undo after a failed apply removes the rule" 0 undo apple-displays
check "the failed apply's rule is gone" test ! -e "$rule"
# A plan that changes while the question waits is not run.
fresh; printf '#!/bin/sh\ntouch %q\n' "$tmp/units/bluetooth.service.enabled" >"$tmp/gum-hook"; chmod +x "$tmp/gum-hook"
run_tty "a plan that changed under the question is refused" 1 apply service-bluetooth
check "the refusal names the changed plan" out_has "vgs-system: refused: plan=changed step=service-bluetooth"
check "a changed plan runs no command of the step" test "$(grep -c 'systemctl\|tee' "$tmp/sudo.log")" == 0

# i2c-dev: a record, then modprobe; undo unloads only in the boot that loaded it.
fresh; touch "$tmp/i2c-rule"
run_tty "apply i2c-dev succeeds" 0 apply i2c-dev
check "i2c-dev records, then loads the module" test "$(sudo_calls)" == "$(session \
  "-- $(p install) -d -m 0755 -o root -g root -- $records" \
  "-- $(p tee) -- $records/.i2c-dev" \
  "-- $(p mv) -fT -- $records/.i2c-dev $records/i2c-dev" \
  "-- $(p modprobe) i2c-dev" \
  "-- $(p udevadm) settle")"
check "the i2c-dev record names the boot" test "$(cat "$records/i2c-dev")" == "$(printf 'uid=%s\nloaded=1\nboot=%s' "$uid" "$boot_a")"
check "i2c-dev reports ready" last_out_is "ok system=i2c-dev state=ready"
rm -f -- "$tmp/sudo.log"
run_tty "undo i2c-dev in the same boot" 0 undo i2c-dev
check "undo unloads the module in the boot that loaded it" grep -qxF -- "-- $(p modprobe) -r i2c-dev" "$tmp/sudo.log"
fresh; touch "$tmp/i2c-rule"
run_tty "apply i2c-dev before a reboot" 0 apply i2c-dev
printf '%s\n' "$boot_b" >"$root/proc/sys/kernel/random/boot_id"; rm -f -- "$tmp/sudo.log"
run_tty "undo i2c-dev after a reboot" 0 undo i2c-dev
check "after a reboot undo leaves the module the system loaded" test "$(sudo_calls)" == "$(session "-- $(p rm) -f -- $records/i2c-dev")"
fresh
run_tty "i2c-dev without the package's rule loads the module but fails" 1 apply i2c-dev
check "the refusal names the denied access" out_has "vgs-system: refused: state=denied reason=no-uaccess-rule step=i2c-dev"

# Services: enable --now; undo disables only a unit VGS enabled and stops
# only a unit VGS started in this boot.
fresh
run_tty "apply service-bluetooth succeeds" 0 apply service-bluetooth
check "service-bluetooth records, then enables the unit now" test "$(sudo_calls)" == "$(session \
  "-- $(p install) -d -m 0755 -o root -g root -- $records" \
  "-- $(p tee) -- $records/.service-bluetooth" \
  "-- $(p mv) -fT -- $records/.service-bluetooth $records/service-bluetooth" \
  "-- $(p systemctl) enable --now bluetooth.service")"
check "the service record names what VGS changed" test "$(cat "$records/service-bluetooth")" == "$(printf 'uid=%s\nenabled=1\nstarted=1\nboot=%s' "$uid" "$boot_a")"
rm -f -- "$tmp/sudo.log"
run_tty "undo service-bluetooth" 0 undo service-bluetooth
check "undo disables and stops the unit VGS enabled" test "$(sudo_calls)" == "$(session \
  "-- $(p systemctl) disable bluetooth.service" \
  "-- $(p systemctl) stop bluetooth.service" \
  "-- $(p rm) -f -- $records/service-bluetooth")"
fresh; touch "$tmp/units/bluetooth.service.enabled"
run_tty "apply a service that was enabled but stopped" 0 apply service-bluetooth
check "the record of an enabled unit claims only the start" test "$(cat "$records/service-bluetooth")" == "$(printf 'uid=%s\nstarted=1\nboot=%s' "$uid" "$boot_a")"
rm -f -- "$tmp/sudo.log"
run_tty "undo a service VGS only started" 0 undo service-bluetooth
check "undo never disables a unit VGS did not enable" test "$(sudo_calls)" == "$(session \
  "-- $(p systemctl) stop bluetooth.service" \
  "-- $(p rm) -f -- $records/service-bluetooth")"
check "the unit stays enabled" test -e "$tmp/units/bluetooth.service.enabled"
fresh
run_tty "apply a service VGS will enable" 0 apply service-bluetooth
rm -f -- "${tmp:?}/units/bluetooth.service.active"
run_tty "apply the same service again once it stopped" 0 apply service-bluetooth
check "a second apply keeps that VGS enabled the unit" test "$(cat "$records/service-bluetooth")" == "$(printf 'uid=%s\nenabled=1\nstarted=1\nboot=%s' "$uid" "$boot_a")"
rm -f -- "${tmp:?}/sudo.log"
run_tty "undo after the second apply" 0 undo service-bluetooth
check "undo still disables the unit VGS enabled first" grep -qxF -- "-- $(p systemctl) disable bluetooth.service" "$tmp/sudo.log"
fresh
run_tty "apply before another uid's record" 0 apply service-bluetooth
sed -i "s/^uid=$uid\$/uid=4242/" "$records/service-bluetooth"; rm -f -- "${tmp:?}/units/bluetooth.service.active" "${tmp:?}/sudo.log"
run "apply refuses over another uid's record" 1 "vgs-system: refused: record=other-uid uid=4242 path=$records/service-bluetooth" apply service-bluetooth
check "the other uid's record stays" grep -qx "uid=4242" "$records/service-bluetooth"
check "a refused record asks nothing and runs no sudo" no_sudo
fresh; touch "$tmp/units/bluetooth.service.enabled"
run_tty "apply before a reboot" 0 apply service-bluetooth
printf '%s\n' "$boot_b" >"$root/proc/sys/kernel/random/boot_id"; rm -f -- "$tmp/sudo.log"
run_tty "undo after a reboot" 0 undo service-bluetooth
check "after a reboot undo stops nothing it did not start" test "$(sudo_calls)" == "$(session "-- $(p rm) -f -- $records/service-bluetooth")"
fresh
run "apply refuses a unit that is not installed" 1 "vgs-system: refused: state=absent reason=unit-missing step=service-tailscaled" apply service-tailscaled
touch "$tmp/units/bluetooth.service.masked"
run "apply refuses a masked unit" 1 "vgs-system: refused: state=denied reason=unit-masked step=service-bluetooth" apply service-bluetooth
check "a refused step runs no sudo" no_sudo
fresh; rm -f -- "$tmp/units/tailscaled.service.missing"
run_tty "apply service-tailscaled succeeds" 0 apply service-tailscaled
check "service-tailscaled enables its unit now" grep -qxF -- "-- $(p systemctl) enable --now tailscaled.service" "$tmp/sudo.log"

# The operator: the caller's own login name; undo resets it only while it
# still names the caller.
fresh
run_tty "apply tailscale-operator succeeds" 0 apply tailscale-operator
check "tailscale-operator records, then sets the caller" test "$(sudo_calls)" == "$(session \
  "-- $(p install) -d -m 0755 -o root -g root -- $records" \
  "-- $(p tee) -- $records/.tailscale-operator" \
  "-- $(p mv) -fT -- $records/.tailscale-operator $records/tailscale-operator" \
  "-- $(p tailscale) set --operator=$user")"
check "the operator record names the caller and the empty previous operator" test "$(cat "$records/tailscale-operator")" == "$(printf 'uid=%s\noperator=%s\nprevious=' "$uid" "$user")"
check "the operator is the caller" test "$(cat "$tmp/operator")" == "$user"
rm -f -- "$tmp/sudo.log"
run_tty "undo tailscale-operator" 0 undo tailscale-operator
check "undo resets the operator VGS set" grep -qxF -- "-- $(p tailscale) set --operator=" "$tmp/sudo.log"
check "the operator is unset again" test ! -s "$tmp/operator"
fresh
run_tty "apply the operator before another change" 0 apply tailscale-operator
printf 'someone' >"$tmp/operator"; rm -f -- "$tmp/sudo.log"
run_tty "undo after someone else set the operator" 0 undo tailscale-operator
check "undo never resets an operator it did not set" test "$(sudo_calls)" == "$(session "-- $(p rm) -f -- $records/tailscale-operator")"
check "the other operator stays" test "$(cat "$tmp/operator")" == someone
fresh; printf 'someone' >"$tmp/operator"
run "apply refuses another user's operator" 1 "vgs-system: refused: state=denied reason=operator-other step=tailscale-operator" apply tailscale-operator

# The record: root's, of its step's keys, and the caller's own.
fresh
run_tty "apply before the record rows" 0 apply service-bluetooth
sed -i "s/^uid=$uid\$/uid=4242/" "$records/service-bluetooth"
run "undo refuses another uid's record" 1 "vgs-system: refused: record=other-uid uid=4242 path=$records/service-bluetooth" undo service-bluetooth
printf 'uid=%s\nenabled=yes\n' "$uid" >"$records/service-bluetooth"
run "undo refuses a malformed record" 1 "vgs-system: refused: record=malformed path=$records/service-bluetooth" undo service-bluetooth
printf 'uid=%s\nrule=%s\n' "$uid" "$hash" >"$records/service-bluetooth"
run "undo refuses a key of another step" 1 "vgs-system: refused: record=malformed path=$records/service-bluetooth" undo service-bluetooth
printf 'uid=%s\nenabled=1\n' "$uid" >"$records/service-bluetooth"; printf '%s\n' "$records/service-bluetooth" >"$tmp/foreign"
run "undo refuses a record root does not own" 1 "vgs-system: refused: record=untrusted path=$records/service-bluetooth" undo service-bluetooth
check "a refused record runs no sudo" test "$(grep -c systemctl "$tmp/sudo.log")" == 1

# Root is refused: the steps act for the caller's own account.
fresh
caller_root() {
  local status=0 err
  err="$("${row_env[@]}" "$unshare_bin" -r "$helper" status 2>&1 >/dev/null </dev/null)" || status=$?
  test "${err%%$'\n'*} exit=$status" == "vgs-system: refused: caller=root exit=1"
}
check "root is refused" caller_root

# NixOS: a needed step reads nixos; apply prints the snippet; nothing is
# written and no sudo runs.
fresh
run_nixos "nixos status" 0 "" "$nixos_path:$caller:/usr/bin:/bin" status --json
check "nixos reads each needed step as nixos" out_is "$(state_json nixos hidraw-denied nixos module-not-loaded nixos inactive absent unit-missing nixos operator-unset)"
check "nixos status writes nothing" untouched
run_nixos "nixos apply prints the configuration" 0 "" "$nixos_path:$caller:/usr/bin:/bin" apply apple-displays
check "nixos apply reports the skip first" test "$(head -n 1 "$tmp/out")" == "ok system=apple-displays skipped=nixos-config"
check "nixos apply prints the hidraw lines as udev extraRules" out_has '  SUBSYSTEM=="hidraw", ATTRS{idVendor}=="05ac", ATTRS{idProduct}=="9243", TAG+="uaccess"'
check "nixos apply opens services.udev.extraRules" out_has "services.udev.extraRules = ''"
check "nixos apply writes nothing" untouched
check "nixos apply runs no sudo" no_sudo
check "nixos apply asks nothing" test ! -e "$tmp/gum.log"
run_nixos "nixos apply of the operator" 0 "" "$nixos_path:$caller:/usr/bin:/bin" apply tailscale-operator
check "nixos operator snippet names the caller" out_has "services.tailscale.extraSetFlags = [ \"--operator=$user\" ];"
run_nixos "nixos undo" 0 "" "$nixos_path:$caller:/usr/bin:/bin" undo service-bluetooth
check "nixos undo reports the skip" test "$(head -n 1 "$tmp/out")" == "ok system=service-bluetooth skipped=nixos-config"
check "nixos undo writes nothing" untouched
check "nixos rows run no sudo" no_sudo
run_nixos "a failed detection fails apply" 1 "vgs-system: refused: system=undetected exit=127" "$nixos_path:$no_node_path" apply apple-displays
check "a failed detection writes nothing" untouched
run_nixos "a failed detection reads needed steps unknown" 0 "" "$nixos_path:$no_node_path" status --json
check "an undetected system never reads needed as ready" out_is "$(state_json unknown system-undetected unknown system-undetected unknown system-undetected absent unit-missing unknown system-undetected)"
check "an undetected system runs no sudo" no_sudo

# Must-fail controls, each a copy of the helper missing one rule.
control() { # NAME NEEDLE REPLACEMENT
  local copy="$tmp/control-$1"
  check "the $1 control's text occurs once" test "$(python3 -c 'import sys; print(open(sys.argv[1]).read().count(sys.argv[2]))' "$source_file" "$2")" == 1
  python3 -c 'import sys; p, o, a, b = sys.argv[1:]; s = open(p).read(); open(o, "w").write(s.replace(a, b))' "$source_file" "$copy" "$2" "$3"
  check "the $1 mutant differs" test "$(cmp -s "$source_file" "$copy"; echo $?)" == 1
  place "$copy"
  fresh
}
control writes-before-question '  # A root command is never answered for the user, unattended or not.' '  vgs_tui_sudo_session start; mode=run; plan "$verb" "$step"; mode=show
  # A root command is never answered for the user, unattended or not.'
printf '1\n' >"$tmp/gum-answer"
run_tty "the writes-before-question mutant's declined apply" 1 apply apple-displays
check "the writes-before-question mutant runs root commands before the answer" grep -qF -- "-- $(p tee) -- $records/.apple-displays" "$tmp/sudo.log"
control undeclared-step '      known_step "$1" || bad_invocation' '      true || bad_invocation'
run "the undeclared-step mutant accepts a step outside the table" 1 "vgs-system: refused: internal=probe step=etc-shadow" apply etc-shadow
control file-presence '    opens_rw "$node" || denied=1' '    [[ -e $node ]] || denied=1'
check "the file-presence mutant reads a closed node ready" test "$(step_state apple-displays)" == "ready granted"
control disable-blind '  [[ -z ${record[enabled]+set} ]] || cmd "$systemctl" disable "$unit"' '  cmd "$systemctl" disable "$unit"'
touch "$tmp/units/bluetooth.service.enabled"
run_tty "the disable-blind mutant applies" 0 apply service-bluetooth
run_tty "the disable-blind mutant undoes" 0 undo service-bluetooth
check "the disable-blind mutant disables a unit VGS did not enable" grep -qxF -- "-- $(p systemctl) disable bluetooth.service" "$tmp/sudo.log"
control foreign-blind '  [[ -n $1 && $sum == "$1" ]] ||' '  true ||'
printf 'someone else\n' >"$rule"
run_tty "the foreign-blind mutant applies over a foreign rule" 0 apply apple-displays
check "the foreign-blind mutant overwrites the foreign rule" cmp -s -- "$rule_src" "$rule"
control symlink-blind '  [[ ! -L $rule_dest ]] || refuse 1 "destination=symlink path=$rule_dest"' '  :'
printf 'elsewhere\n' >"$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$rule"
run "the symlink-blind mutant reaches the foreign check" 1 "vgs-system: refused: destination=foreign path=$rule" apply apple-displays
control unattended "VGS_TUI_UNATTENDED='' vgs_tui_confirm" 'vgs_tui_confirm'
tty_env=(VGS_TUI_UNATTENDED=1); printf '1\n' >"$tmp/gum-answer"
run_tty "the unattended mutant applies unasked" 0 apply apple-displays
check "the unattended mutant asks nothing" test ! -e "$tmp/gum.log"
tty_env=()
control plan-blind '  [[ $shown == "$planned" ]] ||' '  true ||'
printf '#!/bin/sh\ntouch %q\n' "$tmp/units/bluetooth.service.enabled" >"$tmp/gum-hook"; chmod +x "$tmp/gum-hook"
run_tty "the plan-blind mutant runs a plan it did not show" 0 apply service-bluetooth
control uid-blind '  [[ ${record[uid]} == "$uid" ]] ||' '  true ||'
mkdir -p "$records"; printf 'uid=4242\nenabled=1\n' >"$records/service-bluetooth"
run_tty "the uid-blind mutant undoes another uid's record" 0 undo service-bluetooth
control operator-blind '  [[ $operator != "${record[operator]}" ]] ||' '  false ||'
mkdir -p "$records"; printf 'uid=%s\noperator=%s\nprevious=\n' "$uid" "$user" >"$records/tailscale-operator"; printf 'someone' >"$tmp/operator"
run_tty "the operator-blind mutant undoes" 0 undo tailscale-operator
check "the operator-blind mutant resets another user's operator" test ! -s "$tmp/operator"
control boot-blind '  [[ -z ${record[started]+set} || ${record[boot]} != "$boot" ]] ||' '  [[ -z ${record[started]+set} ]] ||'
mkdir -p "$records"; printf 'uid=%s\nstarted=1\nboot=%s\n' "$uid" "$boot_b" >"$records/service-bluetooth"
run_tty "the boot-blind mutant undoes" 0 undo service-bluetooth
check "the boot-blind mutant stops a unit an earlier boot's VGS started" grep -qxF -- "-- $(p systemctl) stop bluetooth.service" "$tmp/sudo.log"
control nixos-write "    printf 'NixOS builds the system from its configuration, so VGS changes nothing here.\\n'" "    : >\"\$rule_dest\"
    printf 'NixOS builds the system from its configuration, so VGS changes nothing here.\\n'"
run_nixos "the nixos-write mutant's apply" 0 "" "$nixos_path:$caller:/usr/bin:/bin" apply apple-displays
check "the nixos-write mutant changes the tree" test "$(untouched; echo $?)" == 1
control nixos-blind '  if [[ $detected_system == nix ]]; then
    printf '"'"'ok system=%s skipped=nixos-config\n'"'"' "$step"
    printf '"'"'NixOS builds' '  if false; then
    printf '"'"'ok system=%s skipped=nixos-config\n'"'"' "$step"
    printf '"'"'NixOS builds'
run_nixos "the nixos-blind mutant's apply" 2 "*" "$nixos_path:$caller:/usr/bin:/bin" apply apple-displays
check "the nixos-blind mutant reaches the question" grep -qxF -- "vgs-tui: refused: confirm=no-terminal" "$tmp/err"
control undetected-ready '      [[ ${state_of[$step]} != needed ]] || state_of[$step]=unknown reason_of[$step]=system-undetected' '      :'
run_nixos "the undetected-ready mutant's status" 0 "" "$nixos_path:$no_node_path" status --json
check "the undetected-ready mutant reports needed without a system" out_has '"apple-displays":{"state":"needed"'

rows_done "$suite"
