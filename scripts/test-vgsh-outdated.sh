#!/usr/bin/env bash
# Controls for `vgsh plugin outdated` and `vgsh theme outdated`: one row per
# installed checkout from local bare repositories, the JSON and text forms,
# the error rows, and what the verbs never do: move a checkout, run a git
# hook, let git, ssh or a credential helper prompt or run an askpass,
# outlast the fetch timeout, keep the theme lock's descriptor in git, or
# change a package under an exclusive theme command.
# Expected commits come from the fixtures' own git, never from vgsh. Each
# control runs a copy of the tree, never bin/vgsh itself. The fetch's
# --no-auto-maintenance has no row: git starts maintenance only past an
# object count it samples from one object directory, which no fixture here
# reaches on demand.
set -euo pipefail

# Two rows remove a directory's permission bits, which bind only a non-root
# uid; a run that could not measure them is not a pass.
if [[ $(id -u) == 0 ]]; then
  echo "test-vgsh-outdated: status=not-measured reason=euid-0"
  exit 77
fi
# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

theme_tree
# The outdated verbs call these beside the tools theme_tree links.
for tool in timeout python3 realpath env setsid; do
  tool_bin="$(command -v "$tool")" || { echo "test-vgsh-outdated: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$theme_path/$tool"
done

source_repo probe "$(manifest acme.probe 0.1.0)"
for name in gone loose plain slow prompt http stop; do source_repo "$name" "$(manifest "acme.$name" 0.1.0)"; done
theme_source moss "$(doc moss)"

# Git hooks are live for every git call from here on: the fixture home's
# global configuration points core.hooksPath at a reference-transaction
# hook, which a fetch that moves a ref runs, and which leaves a marker. A
# plain fetch in the control clone proves the hook fires under this
# isolation; a fixture push fires it too, so each row clears the marker
# first.
hooks="$tmp/hooks"; mkdir -p "$hooks"
marker="$hooks/reference-transaction.marker"
printf '#!/bin/sh\nprintf "" >"$0.marker"\n' >"$hooks/reference-transaction"
chmod +x "$hooks/reference-transaction"
g config --global core.hooksPath "$hooks"
g clone -q "$tmp/src/probe.git" "$tmp/control"
source_commit probe "$(manifest acme.probe 0.1.1)"
rm -f -- "$marker"
g -C "$tmp/control" fetch -q
check "a plain fetch under the fixture configuration runs the reference-transaction hook" test -e "$marker"

# Plugins.
cfg="$tmp/cfg-plugins"; plugins="$cfg/vgs/plugins"
inst "plugin outdated --json with no plugin directory prints an empty list" "$cfg" "$rt_empty" 0 "[]" "" plugin outdated --json
inst "plugin outdated with no plugin directory prints no row" "$cfg" "$rt_empty" 0 "" "" plugin outdated
check "the empty text form is no line at all" test -z "$(<"$tmp/out")"
inst "add installs the probe" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/probe.git"
probe="$plugins/acme.probe"
old="$(head_of "$probe")"
inst "a current checkout is zero behind, its head its upstream" "$cfg" "$rt_empty" 0 "[{\"id\":\"acme.probe\",\"behind\":0,\"head\":\"$old\",\"upstream\":\"$old\",\"error\":null}]" "" plugin outdated --json

source_commit probe "$(manifest acme.probe 0.2.0)"
new="$(head_of "$tmp/src/probe")"
rm -f -- "$marker"
inst "a checkout one commit behind its upstream counts one" "$cfg" "$rt_empty" 0 "[{\"id\":\"acme.probe\",\"behind\":1,\"head\":\"$old\",\"upstream\":\"$new\",\"error\":null}]" "" plugin outdated --json
check "outdated leaves the checkout's HEAD" test "$(head_of "$probe")" == "$old"
check "outdated leaves the old manifest in the work tree" grep -q '"0.1.1"' "$probe/manifest.json"
check "outdated leaves the work tree clean" test -z "$(g -C "$probe" status --porcelain --untracked-files=all)"
check "the fetch moves the remote-tracking ref, its one write" test "$(g -C "$probe" rev-parse refs/remotes/origin/main)" == "$new"
check "the fetch writes no FETCH_HEAD" test ! -e "$probe/.git/FETCH_HEAD"
check "outdated runs no git hook" test ! -e "$marker"
inst "the text form names both commits by 12 digits" "$cfg" "$rt_empty" 0 "acme.probe behind=1 head=${old:0:12} upstream=${new:0:12}" "" plugin outdated
exec 7>>"$cfg/vgs/theme.lock"
flock 7
inst "plugin outdated runs while a theme command holds the theme lock" "$cfg" "$rt_empty" 0 "acme.probe behind=1 head=${old:0:12} upstream=${new:0:12}" "" plugin outdated
exec 7>&-

# The must-fail control of the hook rule: a copy whose git calls keep the
# user's hooks runs the hook on a fetch that moves a ref.
source_commit probe "$(manifest acme.probe 0.3.0)"
newer="$(head_of "$tmp/src/probe")"
rm -f -- "$marker"
tree_control hooks bin/vgsh '-c core.hooksPath=/dev/null ' ''
INST_BIN="$THEME_BIN" inst "the hook-keeping mutant reports the checkout" "$cfg" "$rt_empty" 0 "acme.probe behind=2 head=${old:0:12} upstream=${newer:0:12}" "" plugin outdated
check "the hook-keeping mutant runs the reference-transaction hook" test -e "$marker"
# The must-fail control of the fetch's writes: a copy that writes
# FETCH_HEAD leaves it in the checkout.
check "the hook-keeping mutant's fetch writes no FETCH_HEAD either" test ! -e "$probe/.git/FETCH_HEAD"
tree_control fetchhead bin/vgsh ' --no-write-fetch-head' ''
INST_BIN="$THEME_BIN" inst "the FETCH_HEAD-writing mutant reports the checkout" "$cfg" "$rt_empty" 0 "acme.probe behind=2 head=${old:0:12} upstream=${newer:0:12}" "" plugin outdated
check "the FETCH_HEAD-writing mutant writes FETCH_HEAD" test -e "$probe/.git/FETCH_HEAD"
# The must-fail control of the unchanged checkout: a copy that pulls
# instead of fetching moves HEAD, which the rows above hold still.
tree_control fastforward bin/vgsh 'fetch --quiet --no-recurse-submodules --no-write-fetch-head --no-auto-maintenance' 'pull --quiet --ff-only --no-recurse-submodules'
INST_BIN="$THEME_BIN" inst "the fast-forwarding mutant reports nothing behind" "$cfg" "$rt_empty" 0 "acme.probe behind=0 head=${newer:0:12} upstream=${newer:0:12}" "" plugin outdated
check "the fast-forwarding mutant moves the checkout's HEAD" test "$(head_of "$probe")" == "$newer"
unset THEME_BIN

# Every directory or symlink under the plugin directory is a row, and one
# update would refuse carries that refusal; a file is no row.
cfg="$tmp/cfg-plugin-errors"; plugins="$cfg/vgs/plugins"
for name in probe gone loose plain; do
  inst "add installs acme.$name" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/$name.git"
done
current="$(head_of "$plugins/acme.probe")"
g -C "$plugins/acme.gone" remote set-url origin "$tmp/src/absent.git"
g -C "$plugins/acme.loose" branch --unset-upstream
rm -rf -- "${plugins:?}/acme.plain/.git"
mkdir -p "$tmp/elsewhere/acme.link" "$plugins/stray"
ln -s "$tmp/elsewhere/acme.link" "$plugins/acme.link"
printf 'note\n' >"$plugins/notes.txt"
inst "a checkout update would refuse is an error row, and the verb succeeds" "$cfg" "$rt_empty" 0 "$any_out" "$any_out" plugin outdated --json
want="[
  {'id': 'acme.gone', 'behind': None, 'head': None, 'upstream': None, 'error': 'fetch=acme.gone'},
  {'id': 'acme.link', 'behind': None, 'head': None, 'upstream': None, 'error': 'symlink=$plugins/acme.link'},
  {'id': 'acme.loose', 'behind': None, 'head': None, 'upstream': None, 'error': 'upstream=missing path=$plugins/acme.loose'},
  {'id': 'acme.plain', 'behind': None, 'head': None, 'upstream': None, 'error': 'not-a-checkout=$plugins/acme.plain'},
  {'id': 'acme.probe', 'behind': 0, 'head': '$current', 'upstream': '$current', 'error': None},
  {'id': 'stray', 'behind': None, 'head': None, 'upstream': None, 'error': 'manifest=unreadable path=$plugins/stray/manifest.json error=ENOENT'},
]"
check "each row holds the id sorted, the count and commits or the refusal" json_is "$tmp/out" "d == $want"
check "git's cause for the unreachable remote passes through on stderr" grep -q -F -- "$tmp/src/absent.git" "$tmp/err"
check "no row prints a refusal line on stderr" test "$(grep -c '^vgsh: refused:' "$tmp/err")" == 0
inst "the text form of an error row" "$cfg" "$rt_empty" 0 "$any_out" "$any_out" plugin outdated
check "the text row holds the refusal after error=" has_line "acme.gone error=fetch=acme.gone"
chmod 000 "$plugins"
inst "plugin outdated refuses a plugin directory it cannot read" "$cfg" "$rt_empty" 1 "" "vgsh: refused: unreadable=$plugins" plugin outdated --json
# The must-fail control: a copy that lists an unreadable directory as empty.
tree_control unreadable bin/vgsh '[[ -d $user_plugins && -r $user_plugins && -x $user_plugins ]] || refuse 1 "unreadable=$user_plugins"' 'true'
INST_BIN="$THEME_BIN" inst "the unguarded mutant reports an unreadable directory as empty" "$cfg" "$rt_empty" 0 "[]" "" plugin outdated --json
unset THEME_BIN
chmod 700 "$plugins"
inst "plugin outdated with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=acme.probe" plugin outdated acme.probe
inst "plugin outdated --json with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=acme.probe" plugin outdated --json acme.probe

# The transport: ssh remotes answered by a stub ssh first on PATH, which
# records what ssh would consult before it prompts: the prompt setting git
# hands it, whether it may run an askpass, and whether it can open a
# terminal. It then fails, after 12 s for the slow host.
stub="$tmp/ssh-stub"; mkdir -p "$stub"
printf '%s\n' '#!/bin/sh' \
  'if (: </dev/tty) 2>/dev/null; then tty=yes; else tty=no; fi' \
  'printf "prompt=%s require=%s tty=%s\n" "${GIT_TERMINAL_PROMPT-unset}" "${SSH_ASKPASS_REQUIRE-unset}" "$tty" >>"$0.record"' \
  'case "$*" in *slow.invalid*) sleep 12 ;; esac' \
  'exit 1' >"$stub/ssh"
chmod +x "$stub/ssh"
cfg="$tmp/cfg-slow"
inst "add installs acme.slow" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/slow.git"
g -C "$cfg/vgs/plugins/acme.slow" remote set-url origin ssh://slow.invalid/slow.git
# Real waits: the timeout is production's fixed 10 s, and the stub answers
# the slow host after 12 s.
started=$SECONDS
INST_PATH="$stub:$base_path" inst "a fetch the timeout ends is an error row" "$cfg" "$rt_empty" 0 "acme.slow error=fetch=acme.slow timeout=10s" "$any_out" plugin outdated
check "the timeout ends the fetch before the remote answers" test $((SECONDS - started)) -lt 12
tree_control untimed bin/vgsh 'timeout --kill-after="$outdated_kill_grace" "$outdated_fetch_timeout" ' ''
INST_PATH="$stub:$base_path" INST_BIN="$THEME_BIN" inst "the untimed mutant waits for the remote's failure" "$cfg" "$rt_empty" 0 "acme.slow error=fetch=acme.slow" "$any_out" plugin outdated
unset THEME_BIN

# Stops: the Updates check stops a probe by signalling its process group,
# which the fetch's own session is not in. The verb ends the fetch, returns
# only once it ended and exits 128 plus the signal, printing no report.
# The stand-in fetch takes 2 s to end on TERM, so a verb that did not wait
# returns before its end.
cfg="$tmp/cfg-stop"
inst "add installs acme.stop" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/stop.git"
stop_git slow
for row in "TERM 143" "INT 130" "HUP 129"; do
  read -r sig want <<<"$row"
  stop_run "$sig" plugin outdated --json
  check "$sig ends plugin outdated with exit $want" test "$stop_status" == "$want"
  check "plugin outdated stopped by $sig prints no report" test ! -s "$tmp/out"
  check "plugin outdated returns after the fetch $sig stopped has ended" test "$stop_ended" == yes
  check "no fetch process outlives plugin outdated stopped by $sig" test "$stop_alive" == no
done
# The must-fail control of the fetch's trap: without it the fetch's session
# never hears the stop and outlives the verb.
tree_control trapless bin/vgsh 'trap_stops unattended_git_stop' ':'
INST_BIN="$THEME_BIN" stop_run TERM plugin outdated --json
check "the trapless mutant's fetch outlives plugin outdated" test "$stop_alive" == yes
unset THEME_BIN
# The must-fail control of the verb's wait: without step_run's trap the
# verb returns while the fetch still ends.
tree_control stepless bin/vgsh 'trap_stops step_stop' ':'
INST_BIN="$THEME_BIN" stop_run TERM plugin outdated --json
check "the stepless mutant's plugin outdated returns before its fetch ended" test "$stop_ended" == no
unset THEME_BIN
# The bound: a fetch that ignores TERM gets SIGKILL 5 s later, well before
# its own 12 s end; the control without the grace waits that end out.
stop_git deaf
stop_run TERM plugin outdated --json
check "TERM ends plugin outdated with exit 143 when the fetch ignores TERM" test "$stop_status" == 143
check "the kill grace ends a fetch that ignores TERM before its own end" test "$stop_ended/$stop_alive" == no/no
tree_control graceless bin/vgsh '--kill-after="$outdated_kill_grace" ' ''
INST_BIN="$THEME_BIN" stop_run TERM plugin outdated --json
check "the graceless mutant waits out a fetch that ignores TERM" test "$stop_ended" == yes
unset THEME_BIN
cfg="$tmp/cfg-prompt"
inst "add installs acme.prompt" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/prompt.git"
g -C "$cfg/vgs/plugins/acme.prompt" remote set-url origin ssh://fail.invalid/prompt.git
quiet="prompt=0 require=never tty=no"
rm -f -- "$stub/ssh.record"
INST_PATH="$stub:$base_path" inst "an ssh remote that fails is an error row" "$cfg" "$rt_empty" 0 "acme.prompt error=fetch=acme.prompt" "$any_out" plugin outdated
check "git's transport may not prompt, run an askpass or open a terminal" test "$(<"$stub/ssh.record")" == "$quiet"
tree_control prompting bin/vgsh 'GIT_TERMINAL_PROMPT=0 ' ''
rm -f -- "$stub/ssh.record"
INST_PATH="$stub:$base_path" INST_BIN="$THEME_BIN" inst "the prompting mutant reports the same row" "$cfg" "$rt_empty" 0 "acme.prompt error=fetch=acme.prompt" "$any_out" plugin outdated
check "the prompting mutant leaves the prompt setting to the caller" test "$(<"$stub/ssh.record")" == "prompt=unset require=never tty=no"
tree_control sshaskpass bin/vgsh 'SSH_ASKPASS_REQUIRE=never ' ''
rm -f -- "$stub/ssh.record"
INST_PATH="$stub:$base_path" INST_BIN="$THEME_BIN" inst "the ssh-askpass mutant reports the same row" "$cfg" "$rt_empty" 0 "acme.prompt error=fetch=acme.prompt" "$any_out" plugin outdated
check "the ssh-askpass mutant leaves ssh free to run an askpass" test "$(<"$stub/ssh.record")" == "prompt=0 require=unset tty=no"
unset THEME_BIN
# On a terminal, as a person running the verb has one: the fetch's own
# session leaves ssh none to read a passphrase from. script(1) ends each
# line it records with a carriage return, so the rows grep for the line.
saved_env=("${base_env[@]}"); base_env+=(PATH="$stub:$base_path")
rm -f -- "$stub/ssh.record"
on_terminal "" plugin outdated
check "plugin outdated on a terminal exits 0" test "$term_status" == 0
check "plugin outdated on a terminal prints the error row" grep -q -F -- "acme.prompt error=fetch=acme.prompt" "$tmp/out"
check "ssh under plugin outdated on a terminal can open no terminal" test "$(<"$stub/ssh.record")" == "$quiet"
tree_control sessionless bin/vgsh 'setsid --wait ' ''
rm -f -- "$stub/ssh.record"
INST_BIN="$THEME_BIN" on_terminal "" plugin outdated
check "the sessionless mutant on a terminal prints the error row" grep -q -F -- "acme.prompt error=fetch=acme.prompt" "$tmp/out"
check "the sessionless mutant's ssh opens the terminal" test "$(<"$stub/ssh.record")" == "prompt=0 require=never tty=yes"
unset THEME_BIN
base_env=("${saved_env[@]}")

# Git's own credential prompt: an HTTP remote that answers 401. The
# checkout's credential helper records the Credential Manager setting it
# is handed and has no credential; an askpass named by core.askPass,
# GIT_ASKPASS and SSH_ASKPASS leaves a marker if it runs.
auth_server
askpass="$tmp/askpass"
printf '%s\n' '#!/bin/sh' ': >"$0.ran"' 'echo x' >"$askpass"
helper="$tmp/credential-helper"
printf '%s\n' '#!/bin/sh' 'cat >/dev/null' 'printf "gcm=%s\n" "${GCM_INTERACTIVE-unset}" >>"$0.record"' >"$helper"
chmod +x "$askpass" "$helper"
cfg="$tmp/cfg-http"
inst "add installs acme.http" "$cfg" "$rt_empty" 0 "shell=not-running" "" plugin add "$tmp/src/http.git"
http="$cfg/vgs/plugins/acme.http"
g -C "$http" remote set-url origin "http://127.0.0.1:$auth_port/http.git"
g -C "$http" config core.askPass "$askpass"
g -C "$http" config credential.helper "$helper"
saved_env=("${base_env[@]}"); base_env+=(GIT_ASKPASS="$askpass" SSH_ASKPASS="$askpass")
rm -f -- "$askpass.ran" "$helper.record"
inst "a remote that asks for credentials is an error row" "$cfg" "$rt_empty" 0 "acme.http error=fetch=acme.http" "$any_out" plugin outdated
check "no askpass runs for git's credential prompt" test ! -e "$askpass.ran"
check "the stored-credential helper runs, told not to prompt" test "$(sort -u -- "$helper.record")" == "gcm=false"
tree_control gitaskpass bin/vgsh 'GIT_ASKPASS= ' ''
rm -f -- "$askpass.ran" "$helper.record"
INST_BIN="$THEME_BIN" inst "the git-askpass mutant reports the same row" "$cfg" "$rt_empty" 0 "acme.http error=fetch=acme.http" "$any_out" plugin outdated
check "the git-askpass mutant runs the askpass" test -e "$askpass.ran"
tree_control credentialprompt bin/vgsh 'GCM_INTERACTIVE=false ' ''
rm -f -- "$askpass.ran" "$helper.record"
INST_BIN="$THEME_BIN" inst "the credential-prompt mutant reports the same row" "$cfg" "$rt_empty" 0 "acme.http error=fetch=acme.http" "$any_out" plugin outdated
check "the credential-prompt mutant leaves the Credential Manager free to prompt" test "$(sort -u -- "$helper.record")" == "gcm=unset"
unset THEME_BIN
base_env=("${saved_env[@]}")

# Themes: installed packages alone, under a shared hold of the theme lock.
cfg="$tmp/cfg-themes"; themes="$cfg/vgs/themes"
tinst "theme outdated --json with no installed package prints an empty list" "$cfg" "$rt_empty" 0 "[]" "" theme outdated --json
tinst "theme add installs moss" "$cfg" "$rt_empty" 0 "ok added=moss path=$themes/moss" "" theme add "$tmp/tsrc/moss.git"
old="$(head_of "$themes/moss")"
tinst "a current package is zero behind, and no shipped package is a row" "$cfg" "$rt_empty" 0 "[{\"id\":\"moss\",\"behind\":0,\"head\":\"$old\",\"upstream\":\"$old\",\"error\":null}]" "" theme outdated --json
theme_commit moss theme.json "$(doc moss '{ "palette": { "accent": "#123456" } }')"
new="$(head_of "$tmp/tsrc/moss")"
mkdir -p "$tmp/elsewhere-theme/ivy" "$themes/targets"
doc ivy >"$tmp/elsewhere-theme/ivy/theme.json"
ln -s "$tmp/elsewhere-theme/ivy" "$themes/ivy"
rm -f -- "$marker"
tinst "a package one commit behind counts one, and a symlinked one carries update's refusal" "$cfg" "$rt_empty" 0 "[{\"id\":\"ivy\",\"behind\":null,\"head\":null,\"upstream\":null,\"error\":\"theme=ivy reason=symlink path=$themes/ivy\"},{\"id\":\"moss\",\"behind\":1,\"head\":\"$old\",\"upstream\":\"$new\",\"error\":null}]" "" theme outdated --json
check "theme outdated leaves the package's HEAD" test "$(head_of "$themes/moss")" == "$old"
check "theme outdated leaves the old theme.json" test "$(<"$themes/moss/theme.json")" == "$(doc moss)"
check "theme outdated leaves the package clean" test -z "$(g -C "$themes/moss" status --porcelain --untracked-files=all)"
check "theme outdated runs no git hook" test ! -e "$marker"
tinst "the theme text form" "$cfg" "$rt_empty" 0 "moss behind=1 head=${old:0:12} upstream=${new:0:12}" "" theme outdated
check "the symlinked package's text row" has_line "ivy error=theme=ivy reason=symlink path=$themes/ivy"
tinst "theme outdated with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=moss" theme outdated moss
tinst "theme outdated --json with an argument is exit 2" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=moss" theme outdated --json moss

# The lock: an exclusive holder, as apply, add, update and remove hold it,
# refuses theme outdated busy; another shared holder does not.
exec 7>>"$cfg/vgs/theme.lock"
flock 7
tinst "theme outdated while a theme command holds the lock is refused as busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: outdated=themes reason=busy" theme outdated --json
tree_control lockless bin/vgsh 'theme_lock_hold "outdated=themes" -s' 'true'
tinst "the lockless mutant reads under an exclusive hold" "$cfg" "$rt_empty" 0 "$any_out" "" theme outdated --json
unset THEME_BIN
flock -u 7
flock -s 7
tinst "theme outdated runs beside another shared hold" "$cfg" "$rt_empty" 0 "$any_out" "" theme outdated --json
tree_control exclusive bin/vgsh 'theme_lock_hold "outdated=themes" -s' 'theme_lock_hold "outdated=themes"'
tinst "the exclusive mutant is refused beside a shared hold" "$cfg" "$rt_empty" 75 "" "vgsh: refused: outdated=themes reason=busy" theme outdated --json
unset THEME_BIN
exec 7>&-

# No git process of a row holds descriptor 9, the theme lock: a spy git
# first on PATH records whether it inherited it.
spy="$tmp/git-spy"; mkdir -p "$spy"
real_git="$(command -v git)" || { fail "git resolves on PATH"; real_git=git; }
printf '#!/bin/sh\n: >"%s/ran"\n[ -e /proc/self/fd/9 ] && : >"%s/fd9-open"\nexec "%s" "$@"\n' "$spy" "$spy" "$real_git" >"$spy/git"
chmod +x "$spy/git"
rm -f -- "$spy/ran" "$spy/fd9-open"
THEME_PATH="$spy:$theme_path" tinst "theme outdated through the git spy" "$cfg" "$rt_empty" 0 "$any_out" "" theme outdated
check "theme outdated ran git through the spy" test -e "$spy/ran"
check "no git process of theme outdated holds descriptor 9" test ! -e "$spy/fd9-open"
tree_control descriptor bin/vgsh '2>&1 9>&-)" || rc=$?' '2>&1)" || rc=$?'
rm -f -- "$spy/ran" "$spy/fd9-open"
THEME_PATH="$spy:$theme_path" tinst "the descriptor-keeping mutant reports the rows" "$cfg" "$rt_empty" 0 "$any_out" "" theme outdated
check "the descriptor-keeping mutant's fetch holds descriptor 9" test -e "$spy/fd9-open"
unset THEME_BIN

chmod 000 "$themes"
tinst "theme outdated refuses a themes directory it cannot read" "$cfg" "$rt_empty" 1 "" "vgsh: refused: themes=unreadable path=$themes error=EACCES" theme outdated --json
# The must-fail control: a copy that never reads the judge's status.
tree_control unwaited bin/vgsh 'wait "$!" || exit $?' 'true'
tinst "the unwaited mutant reports an unreadable directory as empty" "$cfg" "$rt_empty" 0 "[]" "$any_out" theme outdated --json
unset THEME_BIN
chmod 700 "$themes"

rows_done test-vgsh-outdated
