#!/usr/bin/env bash
# `vgsh pkg run`, `install` and `remove` (bin/vgsh-pkg) and the step runner
# they start, bin/lib/pkg-run.sh. Every command a row reaches is a stub on a
# PATH that holds nothing else but the tools the runner needs: sudo, doas
# and run0 record their argv and run the rest; pacman, paru, apt-get and
# dnf record theirs and print a fixed package list for a picker's query;
# fzf records its argv and its input and answers from a file. No row
# reaches a real package manager or a real elevation command.
#
# Rows run on a pseudo-terminal script(1) opens, apart from the no-terminal
# row, which runs under `setsid -w` with no controlling terminal. The user
# layer of shell.json is a scratch file per row. The row that asks which
# manager to pick from reads a fixture os-release bound over
# /etc/os-release under `unshare -rm`; without user namespaces that row
# cannot run and the suite exits 77 after every other row.
#
# Each control runs a row against a copy of the tree with one rule removed
# from bin/vgsh-pkg or bin/lib/pkg-run.sh, and that row must fail.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
for tool in script setsid timeout unshare; do
  command -v "$tool" >/dev/null || { echo "test-vgsh-pkg-run: status=not-measured missing=$tool"; exit 77; }
done
script_bin="$(command -v script)"

# The tools the runner and the stubs need, and nothing that changes a
# package.
tools="$tmp/tools"; mkdir -p "$tools"
for tool in bash readlink dirname sleep cat env; do
  found="$(command -v "$tool")" || { echo "test-vgsh-pkg-run: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$found" "$tools/$tool"
done

# Stubs, one directory per group so a row's PATH names exactly the ones it
# offers. Each writes one line per call to $LOG: its name, then each
# argument in brackets.
record='printf "%s" "${0##*/}" >>"$LOG"; for a; do printf " [%s]" "$a" >>"$LOG"; done; echo >>"$LOG"'
stub() { # DIR NAME BODY
  mkdir -p "$1"
  printf '#!/bin/sh\n%s\n%s\n' "$record" "$3" >"$1/$2"
  chmod +x "$1/$2"
}
for e in sudo doas run0; do
  # sudo -k and the keepalive's -n take no command to run.
  stub "$tmp/elevate-$e" "$e" 'case "$1" in -k) exit 0 ;; -n) shift ;; esac
exec "$@"'
done
managers="$tmp/managers"
stub "$managers" pacman 'case "$1" in -Slq) printf "alpha\nbeta\ngamma\n" ;; -Qqe) printf "alpha\n" ;; esac
[ "${STUB_FAIL:-}" != "$1" ] || exit 7'
stub "$managers" paru 'case "$1" in -Slqa) printf "aurpkg\n" ;; esac'
stub "$managers" apt-get '[ "${STUB_FAIL:-}" != "$1" ] || exit 7'
# mise records the directory its step runs in.
stub "$managers" mise 'pwd >"$LOG.cwd"'
# dnf 4 prints its metadata notice on stdout unless -q is given, and with
# the format's own newline a blank line after each name, one name per arch.
stub "$managers" dnf 'quiet=no
for a; do [ "$a" != -q ] || quiet=yes; done
case " $* " in *" repoquery "*)
  [ "$quiet" = yes ] || echo "Last metadata expiration check: 0:04:12 ago on Mon 28 Sep 2026 22:10:03 PDT."
  printf "zsh\n\nzsh\n\nfish\n\n" ;;
esac'
# fzf answers its Nth call with $ANSWERS/N and exits with $ANSWERS/N.status,
# 0 when absent; its input lands in $ANSWERS/N.input.
stub "$tmp/picker" fzf 'n=$(( $(cat "$ANSWERS/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" >"$ANSWERS/calls"
cat >"$ANSWERS/$n.input"
cat "$ANSWERS/$n" 2>/dev/null
exit "$(cat "$ANSWERS/$n.status" 2>/dev/null || echo 0)"'

log="$tmp/log"; answers="$tmp/answers"; cfg="$tmp/cfg"
tree="$tmp/tree"
# A tree holding bin/vgsh-pkg, bin/lib and shell/Core as copies, so a
# control can rewrite any of them, the repository's shell/Ui and config/
# linked, and bin/vgsh, whose `plugin rescan` a run ends with: with no lock
# file in the rows' runtime directory it prints shell=not-running.
make_tree() { # DIR
  mkdir -p "$1/bin" "$1/shell"
  cp -- "$repo/bin/vgsh-pkg" "$repo/bin/vgsh" "$1/bin/"
  cp -R -- "$repo/bin/lib" "$1/bin/lib"
  cp -R -- "$repo/shell/Core" "$1/shell/Core"
  ln -s -- "$repo/shell/Ui" "$1/shell/Ui"
  ln -s -- "$repo/config" "$1/config"
}
make_tree "$tree"

# pkg TREE PATH_DIRS [VAR=VALUE...] -- ARGS: bin/vgsh-pkg on a pseudo-terminal
# with a fresh log, answers and user config directory, PATH the directories
# named (colon-separated) then the tools. PKG_ANSWERS, set before the call
# and emptied by it, holds fzf's answers in order, `status=N` for an exit
# status alone. PKG_CWD, when set, is the directory it starts in. Output
# lands in $tmp/out, the exit
# status in $status. PKG_TTY=none runs it with no controlling terminal
# instead, stderr in $tmp/err.
pkg() {
  local at="$1" dirs="$2" extra=() cmd
  shift 2
  while [[ $1 != -- ]]; do extra+=("$1"); shift; done
  shift
  rm -rf -- "$log" "$log.cwd" "$answers" "$tmp/planted"
  : >"$log"
  mkdir -p "$answers" "$cfg/vgs" "$tmp/home"
  [[ -n ${PKG_CONFIG:-} ]] && printf '%s\n' "$PKG_CONFIG" >"$cfg/vgs/shell.json" || rm -f -- "$cfg/vgs/shell.json"
  local i=1 answer
  for answer in "${PKG_ANSWERS[@]}"; do
    [[ $answer == status=* ]] && printf '%s' "${answer#status=}" >"$answers/$i.status" || printf '%s' "$answer" >"$answers/$i"
    i=$((i + 1))
  done
  PKG_ANSWERS=()
  local env_words=(env -i PATH="$dirs:$tools" HOME="$tmp/home" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt_empty"
    LC_ALL=C LOG="$log" ANSWERS="$answers" "${extra[@]}")
  status=0
  if [[ ${PKG_TTY:-} == none ]]; then
    setsid -w "${env_words[@]}" "$node_bin" "$at/bin/vgsh-pkg" "$@" </dev/null >"$tmp/out" 2>"$tmp/err" || status=$?
  else
    cmd="$(printf '%q ' "${env_words[@]}" "$node_bin" "$at/bin/vgsh-pkg" "$@")"
    ( cd -- "${PKG_CWD:-.}" && SHELL="$BASH" timeout 30 "$script_bin" -qec "$cmd" /dev/null ) </dev/null >"$tmp/out" 2>&1 || status=$?
  fi
}
PKG_ANSWERS=()
sudo_path="$managers:$tmp/elevate-sudo"
log_is() { [[ "$(cat -- "$log")" == "$1" ]] || { printf 'log: [%s]\nwant: [%s]\n' "$(cat -- "$log")" "$1" >"$tmp/why"; return 1; }; }
out_has() { grep -qF -- "$1" "$tmp/out"; }
lines() { printf '%s\n' "$@"; }

# Each row takes the tree it runs and answers 0 when every expectation holds.
row_no_terminal() {
  PKG_TTY=none pkg "$1" "$sudo_path" -- run install --manager pacman foo
  [[ $status == 1 && "$(head -n 1 "$tmp/err")" == "vgsh: refused: run=no-terminal" ]] && log_is ""
}
row_shell_process() {
  pkg "$1" "$sudo_path" VGSH_RUNNER_PID=4242 -- run install --manager pacman foo
  [[ $status == 1 ]] && out_has "vgsh: refused: caller=shell verb=run" && log_is ""
}
row_pacman_install() {
  pkg "$1" "$sudo_path" -- run install --manager pacman foo bar
  [[ $status == 0 ]] && out_has "sudo pacman -S --needed -- foo bar" && log_is "$(lines \
    "sudo [-k]" "sudo [/usr/bin/true]" \
    "sudo [pacman] [-S] [--needed] [--] [foo] [bar]" "pacman [-S] [--needed] [--] [foo] [bar]" \
    "sudo [-k]")"
}
row_apt_upgrade() {
  pkg "$1" "$sudo_path" -- run upgrade --manager apt
  [[ $status == 0 ]] && log_is "$(lines \
    "sudo [-k]" "sudo [/usr/bin/true]" \
    "sudo [apt-get] [update]" "apt-get [update]" \
    "sudo [apt-get] [full-upgrade]" "apt-get [full-upgrade]" \
    "sudo [-k]")"
}
row_first_failure() {
  pkg "$1" "$sudo_path" STUB_FAIL=update -- run upgrade --manager apt
  [[ $status == 7 ]] && log_is "$(lines \
    "sudo [-k]" "sudo [/usr/bin/true]" "sudo [apt-get] [update]" "apt-get [update]" "sudo [-k]")"
}
row_doas() {
  pkg "$1" "$managers:$tmp/elevate-doas:$tmp/elevate-run0" -- run remove --manager pacman foo
  [[ $status == 0 ]] && log_is "$(lines "doas [pacman] [-Rns] [--] [foo]" "pacman [-Rns] [--] [foo]")"
}
row_run0() {
  pkg "$1" "$managers:$tmp/elevate-run0" -- run upgrade --manager dnf
  [[ $status == 0 ]] && log_is "$(lines "run0 [dnf] [upgrade]" "dnf [upgrade]")"
}
row_configured() {
  PKG_CONFIG='{ "packages": { "elevate": "doas" } }' pkg "$1" "$sudo_path:$tmp/elevate-doas" -- run upgrade --manager pacman
  [[ $status == 0 ]] && log_is "$(lines "doas [pacman] [-Syu]" "pacman [-Syu]")"
}
row_configured_absent() {
  PKG_CONFIG='{ "packages": { "elevate": "run0" } }' pkg "$1" "$sudo_path" -- run upgrade --manager pacman
  [[ $status == 1 ]] && out_has "vgsh: refused: elevate=run0 reason=absent source=packages.elevate" && log_is ""
}
row_configured_unknown() {
  PKG_CONFIG='{ "packages": { "elevate": "pkexec" } }' pkg "$1" "$sudo_path" -- run upgrade --manager pacman
  [[ $status == 1 ]] && out_has "vgsh: refused: user-config=malformed path=$cfg/vgs/shell.json error=packages.elevate must be one of sudo, doas, run0, got \"pkexec\"" && log_is ""
}
row_no_elevator() {
  pkg "$1" "$managers" -- run upgrade --manager pacman
  [[ $status == 1 ]] && out_has "vgsh: refused: elevate=none candidates=sudo,doas,run0" && log_is ""
}
row_literal_name() {
  local name="\$(touch\${IFS}$tmp/planted)"
  pkg "$1" "$sudo_path" -- run install --manager pacman "$name"
  [[ $status == 0 && ! -e $tmp/planted ]] && grep -qxF "pacman [-S] [--needed] [--] [$name]" "$log"
}
row_home_directory() {
  mkdir -p "$tmp/project"
  printf '[tools]\nnode = "18"\n' >"$tmp/project/mise.toml"
  PKG_CWD="$tmp/project" pkg "$1" "$managers" -- run upgrade --manager mise
  [[ $status == 0 && "$(cat "$log.cwd" 2>/dev/null)" == "$tmp/home" ]] && log_is "mise [upgrade]"
}
row_aur_unelevated() {
  pkg "$1" "$managers:$tmp/elevate-sudo" -- run install --manager aur aurpkg
  [[ $status == 0 ]] && log_is "paru [-S] [--needed] [--] [aurpkg]"
}
row_picker_install() {
  PKG_ANSWERS=($'beta\ngamma\n')
  pkg "$1" "$sudo_path:$tmp/picker" VGS_TUI_SUCCESS='#112233' -- install --manager pacman
  [[ $status == 0 && "$(cat "$answers/1.input")" == "$(lines alpha beta gamma)" ]] && log_is "$(lines \
    "pacman [-Slq]" \
    "fzf [--multi] [--preview='pacman' '-Sii' {1}] [--preview-label=alt-p: toggle description, alt-j/k: scroll, tab: multi-select] [--preview-label-pos=bottom] [--preview-window=down:65%:wrap] [--bind=alt-p:toggle-preview] [--bind=alt-d:preview-half-page-down,alt-u:preview-half-page-up] [--bind=alt-k:preview-up,alt-j:preview-down] [--color=pointer:#112233,marker:#112233]" \
    "sudo [-k]" "sudo [/usr/bin/true]" \
    "sudo [pacman] [-S] [--needed] [--] [beta] [gamma]" "pacman [-S] [--needed] [--] [beta] [gamma]" \
    "sudo [-k]")"
}
row_picker_remove() {
  PKG_ANSWERS=($'alpha\n')
  pkg "$1" "$sudo_path:$tmp/picker" -- remove --manager pacman
  [[ $status == 0 ]] && grep -qF "[--preview='pacman' '-Qi' {1}]" "$log" && grep -qF "[--color=pointer:red,marker:red]" "$log" &&
    grep -qxF "pacman [-Qqe]" "$log" && grep -qxF "sudo [pacman] [-Rns] [--] [alpha]" "$log"
}
row_picker_cancelled() {
  PKG_ANSWERS=(status=130)
  pkg "$1" "$sudo_path:$tmp/picker" -- install --manager pacman
  [[ $status == 130 ]] && [[ "$(grep -c -e '^sudo' -e '^pacman \[-S\]' "$log")" == 0 ]]
}
row_picker_nothing() {
  PKG_ANSWERS=(status=1)
  pkg "$1" "$sudo_path:$tmp/picker" -- install --manager pacman
  [[ $status == 0 ]] && [[ "$(grep -c -e '^sudo' "$log")" == 0 ]]
}
row_aur_picker() {
  PKG_ANSWERS=($'aurpkg\n')
  pkg "$1" "$sudo_path:$tmp/picker" -- install --manager aur
  [[ $status == 0 ]] && grep -qF "[--preview='paru' '-Siia' {1}]" "$log" && [[ "$(grep -c '^sudo' "$log")" == 0 ]] &&
    grep -qxF "paru [-S] [--needed] [--] [aurpkg]" "$log"
}
row_picker_unsupported() {
  pkg "$1" "$managers:$tmp/picker:$tmp/elevate-sudo" -- remove --manager aur
  [[ $status == 1 ]] && out_has "vgsh: refused: manager=aur picker=remove reason=unsupported" && log_is ""
}

row_dnf_picker() {
  PKG_ANSWERS=($'fish\n')
  pkg "$1" "$sudo_path:$tmp/picker" -- install --manager dnf
  [[ $status == 0 && "$(cat "$answers/1.input")" == "$(lines zsh fish)" ]] && grep -qxF "sudo [dnf] [install] [fish]" "$log"
}
row_picker_without_fzf() {
  pkg "$1" "$sudo_path" -- install --manager pacman
  [[ $status == 1 ]] && out_has "vgsh: refused: picker=fzf reason=absent" && log_is ""
}

rows=(no_terminal shell_process pacman_install apt_upgrade first_failure doas run0 configured configured_absent
  configured_unknown no_elevator literal_name aur_unelevated picker_install picker_remove picker_cancelled
  picker_nothing aur_picker picker_unsupported picker_without_fzf dnf_picker home_directory)
for r in "${rows[@]}"; do
  rm -f -- "$tmp/why"
  if "row_$r" "$tree"; then ok "$r"; else fail "$r: status=$status $(cat -- "$tmp/why" 2>/dev/null) out=[$(tr '\n' '|' <"$tmp/out")]"; fi
done

# Without --manager, install asks which manager to pick from when pacman's
# AUR overlay offers a picker beside it: a fixture os-release names Arch,
# bound over /etc/os-release, so the answer does not depend on the host.
chooser_status=77
printf 'NAME="Arch Linux"\nID=arch\n' >"$tmp/os-release-arch"
if unshare -rm true 2>/dev/null; then
  PKG_ANSWERS=($'aur\n' $'aurpkg\n')
  pkg_in_arch() {
    local cmd
    rm -rf -- "$log" "$answers"; : >"$log"; mkdir -p "$answers"
    printf '%s' "${PKG_ANSWERS[0]}" >"$answers/1"; printf '%s' "${PKG_ANSWERS[1]}" >"$answers/2"
    cmd="$(printf '%q ' env -i PATH="$sudo_path:$tmp/picker:$tools" HOME="$tmp/home" XDG_CONFIG_HOME="$cfg" LC_ALL=C LOG="$log" ANSWERS="$answers" "$node_bin" "$tree/bin/vgsh-pkg" install)"
    status=0
    SHELL="$BASH" timeout 30 unshare -rm sh -c 'mount --bind "$1" /etc/os-release && shift && exec "$@"' sh "$tmp/os-release-arch" \
      "$script_bin" -qec "$cmd" /dev/null </dev/null >"$tmp/out" 2>&1 || status=$?
  }
  pkg_in_arch
  check "install without a manager asks between pacman and the AUR" test "$(cat "$answers/1.input" 2>/dev/null)" == "$(lines pacman aur)"
  check "the AUR answer opens the helper's picker and installs through it" log_is "$(lines "fzf [--prompt=Install from> ] [--color=pointer:yellow]" \
    "paru [-Slqa]" \
    "fzf [--multi] [--preview='paru' '-Siia' {1}] [--preview-label=alt-p: toggle description, alt-j/k: scroll, tab: multi-select] [--preview-label-pos=bottom] [--preview-window=down:65%:wrap] [--bind=alt-p:toggle-preview] [--bind=alt-d:preview-half-page-down,alt-u:preview-half-page-up] [--bind=alt-k:preview-up,alt-j:preview-down] [--color=pointer:green,marker:green]" \
    "paru [-S] [--needed] [--] [aurpkg]")"
  chooser_status=0
fi

# Controls: each copy removes one rule, and the row that holds it must fail.
# control NAME FILE NEEDLE REPLACEMENT ROW: FILE relative to the tree.
control() {
  local dir="$tmp/control-$1"
  make_tree "$dir"
  check "the $1 control's text occurs once in $2" \
    python3 -c 'import sys; sys.exit(0 if open(sys.argv[1]).read().count(sys.argv[2]) == 1 else 1)' "$repo/$2" "$3"
  python3 -c 'import sys; p, a, b = sys.argv[1:]; s = open(p).read(); open(p, "w").write(s.replace(a, b))' "$dir/$2" "$3" "$4"
  check "the $1 mutant differs from $2" test "$(cmp -s "$repo/$2" "$dir/$2"; echo $?)" == 1
  if "row_$5" "$dir"; then fail "the $1 mutant passes row $5"; else ok "the $1 mutant fails row $5"; fi
}
control runs-without-terminal bin/vgsh-pkg 'fs.closeSync(fs.openSync("/dev/tty", "r+"));' ';' no_terminal
control elevates-in-shell bin/vgsh-pkg 'if (process.env.VGSH_RUNNER_PID !== undefined)' 'if (false)' shell_process
control no-sudo-session bin/lib/pkg-run.sh $'if [[ $elevator == sudo ]]; then\n  vgs_tui_sudo_session start' $'if false; then\n  vgs_tui_sudo_session start' apt_upgrade
control runs-past-failure bin/lib/pkg-run.sh '[[ $status -eq 0 ]] || exit "$status"' ':' first_failure
control shell-string bin/lib/pkg-run.sh '  "${step[@]}" || status=$?' '  bash -c "${step[*]}" || status=$?' literal_name
control caller-directory bin/vgsh-pkg 'stdio: "inherit", cwd: process.env.HOME || "/" });' 'stdio: "inherit" });' home_directory
control always-elevates bin/vgsh-pkg '    if (r.plan.elevate) {' '    if (true) {' aur_unelevated
control ignores-configuration bin/vgsh-pkg 'table.elevator(configuredElevator(), onPath)' 'table.elevator(undefined, onPath)' configured
control unquoted-preview bin/vgsh-pkg '    return "'"'"'" + word.replace' '    return word; "'"'"'" + word.replace' picker_install
control fixed-colour bin/vgsh-pkg 'return value !== undefined && HEX_COLOUR.test(value) ? value : fallback;' 'return fallback;' picker_install
control dnf-notice shell/Core/PackageManagers.js 'list: ["{bin}", "-q", "repoquery", "--available",' 'list: ["{bin}", "repoquery", "--available",' dnf_picker
control fzf-looked-up-late bin/vgsh-pkg '        if (!onPath("fzf")) refuse("picker=fzf reason=absent");' '' picker_without_fzf
control cancel-runs-nothing bin/vgsh-pkg '    if (r.status === 130) return { cancelled: true };' '' picker_cancelled

if [[ $failures -gt 0 ]]; then echo "test-vgsh-pkg-run: failed=$failures"; exit 1; fi
if [[ $chooser_status == 77 ]]; then echo "test-vgsh-pkg-run: status=not-measured missing=user-namespaces"; exit 77; fi
echo "test-vgsh-pkg-run: ok"
