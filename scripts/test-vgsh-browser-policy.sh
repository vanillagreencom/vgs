#!/usr/bin/env bash
# Controls for bin/vgsh-browser-policy, the Chromium-family colour writer:
# its argument, the canonical skip, the `sudo -n` elevation, the refresh of
# running browsers, the root half's hardening, creation and write, and the
# install of its sudoers rule. Every row runs a copy whose `prefix` is a
# temporary tree, so its /etc and /usr are that tree's. sudo is a stub that
# runs the root half under `unshare -r`, where the tree reads as root's and
# nothing outside it is writable, so no row writes the real /etc or reaches
# a running browser.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
source_file="$repo/bin/vgsh-browser-policy"
unshare_bin="$(command -v unshare)" || { echo "test-vgsh-browser-policy: status=not-measured missing=unshare"; exit 77; }
"$unshare_bin" -r true 2>/dev/null || { echo "test-vgsh-browser-policy: status=not-measured missing=user-namespaces"; exit 77; }
stat_bin="$(command -v stat)"
uid="$(id -u)"; gid="$(id -g)"
root="$tmp/root"; bin="$root/usr/bin"; helper="$root/usr/local/bin/vgs-browser-policy"
mkdir -p "$bin" "$root/usr/local/bin" "$tmp/home"
for tool in awk cat chmod chown cp grep id mkdir mktemp mv readlink rm sed; do
  tool_bin="$(command -v "$tool")" || { echo "test-vgsh-browser-policy: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$bin/$tool"
done
sudo_log="$tmp/sudo.log"; refresh_log="$tmp/refresh.log"
# stat reports the tree's files as root's unless $tmp/as-user exists: a
# test cannot make a file root owns, and inside `unshare -r` real stat
# already answers 0.
cat >"$bin/stat" <<EOF
#!/bin/sh
out="\$($stat_bin "\$@")" || exit \$?
[ -e "$tmp/as-user" ] && { printf '%s\n' "\$out"; exit 0; }
printf '%s\n' "\$out" | sed 's/^$uid:$gid /0:0 /'
EOF
# sudo -n runs its command as the namespace's root when $tmp/rule exists
# and refuses as a missing rule does otherwise; any other call is recorded
# and exits with the status $tmp/sudo-exit holds, 0 when absent.
cat >"$bin/sudo" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$sudo_log"
if [ "\$1" = -n ]; then
  [ -e "$tmp/rule" ] || { echo 'sudo: a password is required' >&2; exit 1; }
  shift; [ "\$1" = -- ] && shift
  exec $unshare_bin -r "\$@"
fi
st=0; [ -f "$tmp/sudo-exit" ] && read -r st <"$tmp/sudo-exit"
exit "\$st"
EOF
# visudo keeps the file it checks and exits with $tmp/visudo-exit, 0 when absent.
cat >"$bin/visudo" <<EOF
#!/bin/sh
for a; do f="\$a"; done
cp -- "\$f" "$tmp/checked-rule"
st=0; [ -f "$tmp/visudo-exit" ] && read -r st <"$tmp/visudo-exit"
exit "\$st"
EOF
# ps lists the process names $tmp/procs holds.
cat >"$bin/ps" <<EOF
#!/bin/sh
[ "\$1 \$3 \$4" = "-u -o comm=" ] || exit 64
cat -- "$tmp/procs" 2>/dev/null
exit 0
EOF
chmod +x "$bin/stat" "$bin/sudo" "$bin/visudo" "$bin/ps"
all_browsers=(chromium google-chrome-stable google-chrome microsoft-edge-stable brave)
browsers() { # NAME...: exactly these browser commands are installed
  local name
  for name in "${all_browsers[@]}"; do rm -f -- "${bin:?}/$name"; done
  for name in "$@"; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"%s"\n' "$name" "$refresh_log" >"$bin/$name"
    chmod +x "$bin/$name"
  done
}
# SOURCE's `prefix=` line, which must occur once, names the tree.
place() { # SOURCE
  check "the helper's prefix line occurs once" test "$(grep -c '^prefix=$' "$1")" == 1
  sed "s|^prefix=\$|prefix=$root|" "$1" >"$helper"
  chmod +x "$helper"
  check "the placed helper names the tree" test "$(grep -c "^prefix=$root\$" "$helper")" == 1
}
fresh() { # a new tree: /etc and /etc/opt root's 0755, no policy, no rule
  rm -rf -- "${root:?}/etc" "$tmp/as-user" "$tmp/rule" "$tmp/procs" "$tmp/sudo-exit" "$tmp/visudo-exit" "$tmp/checked-rule"
  mkdir -p "$root/etc/opt"; chmod 0755 "$root/etc" "$root/etc/opt"
  : >"$sudo_log"; : >"$refresh_log"
}
# run NAME AS WANT_EXIT WANT_FIRST_STDERR ARGS...: AS is `user`, or `root`
# for the helper run directly under `unshare -r`; WANT_FIRST_STDERR `*`
# takes any. Stdout lands in $tmp/out and stderr in $tmp/err.
run() {
  local name="$1" as="$2" want_exit="$3" want_err="$4" status=0 err=""
  shift 4
  local cmd=(env -i HOME="$tmp/home" PATH=/nonexistent "$helper" "$@")
  [[ $as == root ]] && cmd=("$unshare_bin" -r "${cmd[@]}")
  "${cmd[@]}" </dev/null >"$tmp/out" 2>"$tmp/err" || status=$?
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  if [[ $status == "$want_exit" && ( $want_err == "*" || $err == "$want_err" ) ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit stderr=[$err] want=[$want_err]"; fi
}
managed="$root/etc/chromium/policies/managed"
policy() { printf '{"BrowserThemeColor": "#%s", "BrowserColorScheme": "device"}' "$1"; }
holds() { # FILE HEX: FILE is the canonical policy for HEX, a regular file mode 0644
  [[ -f $1 && ! -L $1 && $("$stat_bin" -c %a -- "$1") == 644 && $(cat -- "$1") == "$(policy "$2")" ]]
}
modes() { # DIR...: each is a real directory mode 0755
  local dir
  for dir; do [[ -d $dir && ! -L $dir && $("$stat_bin" -c %a -- "$dir") == 755 ]] || return 1; done
}
elevated() { test "$(cat "$sudo_log")" == "-n -- $helper $1"; }
place "$source_file"

# The argument is six lowercase hex digits, one of them, in either half,
# refused before any elevation or write.
fresh; browsers chromium; touch "$tmp/rule"
for bad in "" "1C2027" "abc12" "abc1234" "1c202g" "#1c2027" "../../x" '$(id)' "1c2027;id"; do
  run "the argument [$bad] is refused" user 2 "vgs-browser-policy: argument=$(printf '%q' "$bad") count=1" "$bad"
  run "the root half refuses the argument [$bad]" root 2 "vgs-browser-policy: argument=$(printf '%q' "$bad") count=1" "$bad"
done
run "two colours are refused" user 2 "vgs-browser-policy: argument=1c2027 count=2" 1c2027 ffffff
run "no argument is refused" user 2 "vgs-browser-policy: argument='' count=0"
check "no refused argument reached sudo" test ! -s "$sudo_log"
check "no refused argument wrote a policy" test ! -e "$root/etc/chromium"

# Without the rule, sudo -n refuses and the hook fails with nothing written.
fresh; browsers chromium
run "a missing rule fails the hook" user 1 "sudo: a password is required" 1c2027
check "a missing rule names the failed elevation" grep -qxF -- "vgs-browser-policy: elevation-failed=$helper" "$tmp/err"
check "the elevation is sudo -n of the installed writer with the colour" elevated 1c2027
check "a missing rule writes nothing" test ! -e "$root/etc/chromium"

# With the rule, an installed browser's directory is created root's 0755 and
# takes the policy; an absent browser's is not; a running browser that is
# installed is refreshed, and one that is not installed is not.
fresh; browsers chromium; touch "$tmp/rule"; printf 'chromium\nbrave\nbash\n' >"$tmp/procs"
run "a first write succeeds" user 0 "" 1c2027
check "chromium's managed policy is canonical" holds "$managed/color.json" 1c2027
check "chromium's chain is created 0755" modes "$root/etc/chromium" "$root/etc/chromium/policies" "$managed"
check "an absent browser takes no directory" test ! -e "$root/etc/brave" -a ! -e "$root/etc/opt/chrome"
check "only the running installed browser is refreshed" test "$(cat "$refresh_log")" == "chromium --refresh-platform-policy --no-startup-window"
check "the staged file is gone" test "$(ls -A -- "$managed")" == color.json

# A canonical file skips the elevation and the refresh; one a user owns, or
# of another colour, takes the write again.
: >"$sudo_log"; : >"$refresh_log"
run "a canonical policy is left alone" user 0 "" 1c2027
check "a canonical policy runs no sudo" test ! -s "$sudo_log"
check "a canonical policy refreshes nothing" test ! -s "$refresh_log"
touch "$tmp/as-user"
run "a user-owned policy is rewritten" user 0 "" 1c2027
check "a user-owned policy elevates" elevated 1c2027
rm -f -- "$tmp/as-user"; : >"$sudo_log"
run "a new colour is written" user 0 "" a0b1c2
check "the new colour replaces the old" holds "$managed/color.json" a0b1c2

# The root half hardens a writable chain and replaces a planted link or
# directory without following it.
chmod 0777 "$root/etc/chromium/policies"
run "a writable parent is hardened" root 0 "" 1c2027
check "the writable parent is 0755 again" modes "$root/etc/chromium/policies"
printf 'victim\n' >"$tmp/victim"; rm -f -- "$managed/color.json"; ln -s -- "$tmp/victim" "$managed/color.json"
run "a planted link is replaced" root 0 "" 1c2027
check "the link's target is untouched" test "$(cat "$tmp/victim")" == victim
check "the planted link became the policy" holds "$managed/color.json" 1c2027
rm -f -- "$managed/color.json"; mkdir -p "$managed/color.json/nested"
run "a planted directory is replaced" root 0 "" 1c2027
check "the planted directory became the policy" holds "$managed/color.json" 1c2027

# A chain through a link or an untrusted system directory is refused while
# every other directory still takes the write; an existing directory whose
# browser is gone still takes it.
fresh; browsers chromium brave google-chrome
mkdir -p "$tmp/evil/policies/managed" "$root/etc/opt/edge/policies/managed"; ln -s -- "$tmp/evil" "$root/etc/brave"
chmod 0777 "$root/etc/opt"
run "a linked chain fails the write" root 1 "vgs-browser-policy: untrusted=$root/etc/opt" 1c2027
check "the linked chain is refused" grep -qxF -- "vgs-browser-policy: not-a-directory=$root/etc/brave" "$tmp/err"
check "nothing is written through the link" test ! -e "$tmp/evil/policies/managed/color.json"
check "the untrusted /etc/opt takes no chrome directory" test ! -e "$root/etc/opt/chrome"
check "chromium is written beside the refusals" holds "$managed/color.json" 1c2027
chmod 0755 "$root/etc/opt"; rm -- "$root/etc/brave"
run "a trusted /etc/opt takes the write" root 0 "" 1c2027
check "chrome's directory is created" holds "$root/etc/opt/chrome/policies/managed/color.json" 1c2027
check "edge's existing directory is written with edge gone" holds "$root/etc/opt/edge/policies/managed/color.json" 1c2027

# No browser and no directory: the root half refuses, the user's hook has
# nothing to do.
fresh; browsers; touch "$tmp/rule"
run "the root half with no browser refuses" root 1 "vgs-browser-policy: no-policy-directory=$root/etc" 1c2027
run "the hook with no browser does nothing" user 0 "" 1c2027
check "the hook with no browser runs no sudo" test ! -s "$sudo_log"

# install checks the rule with visudo, installs it and then the writer, each
# root:root, the rule naming the user and six hex classes alone.
fresh
run "install succeeds" user 0 "" install
rule="$(id -un) ALL=(root) NOPASSWD: /usr/local/bin/vgs-browser-policy [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
check "the checked rule is the one grant" test "$(grep -v '^#' "$tmp/checked-rule")" == "$rule"
staged_rule="$(awk 'NR == 1 { print $(NF - 1) }' "$sudo_log")"
check "install runs the rule, then the writer" test "$(cat "$sudo_log")" == "install -m 0440 -o root -g root -T -- $staged_rule $root/etc/sudoers.d/vgs-browser-policy
install -m 0755 -o root -g root -T -- $helper $helper"
check "the staged rule is removed" test ! -e "$staged_rule"
check "install prints its paths" test "$(cat "$tmp/out")" == "ok browser-policy rule=$root/etc/sudoers.d/vgs-browser-policy writer=$helper"
fresh; printf '1\n' >"$tmp/visudo-exit"
run "a rule visudo refuses is not installed" user 1 "vgs-browser-policy: install=rule-refused" install
check "a refused rule runs no sudo" test ! -s "$sudo_log"
fresh; printf '1\n' >"$tmp/sudo-exit"
run "a failed rule install stops before the writer" user 1 "vgs-browser-policy: install=rule path=$root/etc/sudoers.d/vgs-browser-policy" install
check "a failed rule install runs one sudo" test "$(wc -l <"$sudo_log")" == 1
fresh
run "install as root is refused" root 1 "vgs-browser-policy: install=root" install

# Must-fail controls, each on a copy of the helper missing one rule.
control() { # NAME NEEDLE REPLACEMENT
  local copy="$tmp/control-$1"
  check "the $1 control's text occurs once" test "$(grep -c -F -- "$2" "$source_file")" == 1
  python3 -c 'import sys; p, o, a, b = sys.argv[1:]; s = open(p).read(); open(o, "w").write(s.replace(a, b))' "$source_file" "$copy" "$2" "$3"
  check "the $1 mutant differs" test "$(cmp -s "$source_file" "$copy"; echo $?)" == 1
  place "$copy"
}
control wide-argument '! $1 =~ ^[0-9a-f]{6}$' '! $1 =~ ^#?[0-9a-fA-F]{6}$'
fresh; browsers chromium; touch "$tmp/rule"
run "the wide-argument mutant takes #1C2027" user 0 "" "#1C2027"
control owner-blind '== "0:0 644" ]]' '== *" 644" ]]'
fresh; browsers chromium; touch "$tmp/rule"
run "the owner-blind mutant writes" user 0 "" 1c2027
touch "$tmp/as-user"; : >"$sudo_log"
run "the owner-blind mutant runs" user 0 "" 1c2027
check "the owner-blind mutant skips a user-owned policy" test ! -s "$sudo_log"
control link-following '[[ -d $step && ! -L $step ]] ||' '[[ -d $step ]] ||'
fresh; browsers chromium brave; mkdir -p "$tmp/evil2/policies/managed"; ln -s -- "$tmp/evil2" "$root/etc/brave"
run "the link-following mutant writes" root 0 "" 1c2027
check "the link-following mutant writes through the link" test -e "$tmp/evil2/policies/managed/color.json"
control mode-blind '(( (8#${info#* } & 8#022) == 0 ))' 'true'
fresh; browsers google-chrome; chmod 0777 "$root/etc/opt"
run "the mode-blind mutant writes" root 0 "" 1c2027
check "the mode-blind mutant creates chrome under a writable /etc/opt" test -e "$root/etc/opt/chrome/policies/managed/color.json"
control no-chmod '{ chown root:root -- "$step" && chmod 0755 -- "$step"; }' '{ chown root:root -- "$step"; }'
fresh; browsers chromium; mkdir -p "$managed"; chmod 0777 "$root/etc/chromium/policies"
run "the no-chmod mutant writes" root 0 "" 1c2027
check "the no-chmod mutant leaves the parent writable" test "$("$stat_bin" -c %a -- "$root/etc/chromium/policies")" == 777
control no-replace 'if [[ -L $dest || -d $dest ]]; then rm -rf' 'if false; then rm -rf'
fresh; browsers chromium; mkdir -p "$managed/color.json"
run "the no-replace mutant fails on a planted directory" root 1 "*" 1c2027
check "the no-replace mutant names the failed write" grep -qxF -- "vgs-browser-policy: write-failed=$managed/color.json" "$tmp/err"
control every-browser 'elif installed_any "${entry#*|}"; then' 'elif true; then'
fresh; browsers chromium
run "the every-browser mutant writes" root 0 "" 1c2027
check "the every-browser mutant creates brave's directory" test -e "$root/etc/brave/policies/managed/color.json"
control refresh-all 'grep -qxF -- "$process" <<<"$running" &&' 'true &&'
fresh; browsers chromium brave; touch "$tmp/rule"
run "the refresh-all mutant writes" user 0 "" 1c2027
check "the refresh-all mutant refreshes a browser that is not running" grep -q '^brave ' "$refresh_log"

rows_done test-vgsh-browser-policy
