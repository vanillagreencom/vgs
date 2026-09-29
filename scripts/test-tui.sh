#!/usr/bin/env bash
# Controls for bin/lib/tui.sh, the floating TUI presentation library, and
# for the plugin template that sources it. Each library row sources it into
# a fresh bash with an explicit environment and runs one snippet: stub gum, sudo, uname and pgrep record their arguments or answer
# as the row sets. A row that needs no terminal runs under `setsid --wait`,
# a session with no controlling terminal; one that needs a terminal runs on
# a pseudo-terminal script(1) opens.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
for tool in script setsid flock; do
  command -v "$tool" >/dev/null || { echo "test-tui: status=not-measured missing=$tool"; exit 77; }
done
lib="$repo/bin/lib/tui.sh"
stubs="$tmp/stubs"; rt="$tmp/rt"
mkdir -p "$stubs" "$rt"
stub() { printf '#!/bin/sh\n%s\n' "$2" >"$stubs/$1"; chmod +x "$stubs/$1"; } # NAME BODY
# gum records its argv, one per line, and exits with $tmp/gum-exit, 0 when absent.
stub gum ": >\"$tmp/gum\"; for a; do printf '%s\\n' \"\$a\" >>\"$tmp/gum\"; done; st=0; [ -f \"$tmp/gum-exit\" ] && read -r st <\"$tmp/gum-exit\"; exit \"\$st\""
# sudo records each call; `sudo /usr/bin/true` exits 1 while $tmp/sudo-deny exists.
stub sudo "printf '%s\\n' \"\$*\" >>\"$tmp/sudo\"; [ \"\$*\" = /usr/bin/true ] && [ -e \"$tmp/sudo-deny\" ] && exit 1; exit 0"
# uname -r prints $tmp/release; pgrep prints $tmp/pids and exits with $tmp/pgrep-exit, else 1.
stub uname "cat \"$tmp/release\""
stub pgrep "cat \"$tmp/pids\" 2>/dev/null; st=1; [ -f \"$tmp/pgrep-exit\" ] && read -r st <\"$tmp/pgrep-exit\"; exit \"\$st\""

LIB="$lib"
lib_env=("${base_env[@]}" PATH="$stubs:$base_path" SHELL="$BASH" XDG_RUNTIME_DIR="$rt")
# run SNIPPET [ENV=VALUE...]: SNIPPET in bash after sourcing $LIB, with no
# controlling terminal; stdout in $tmp/out, stderr in $tmp/err, the exit
# status in $status.
run() {
  local snippet="$1"
  shift
  status=0
  "${lib_env[@]}" "$@" setsid --wait "$BASH" -c "set -euo pipefail; source $(printf '%q' "$LIB"); $snippet" \
    </dev/null >"$tmp/out" 2>"$tmp/err" || status=$?
}
# on_tty SNIPPET: the same on a pseudo-terminal; output in $tmp/out.
on_tty() {
  status=0
  "${lib_env[@]}" script -qec "$(printf '%q ' "$BASH" -c "set -euo pipefail; source $(printf '%q' "$LIB"); $1")" /dev/null \
    </dev/null >"$tmp/out" 2>&1 || status=$?
}
err_first() { local line=""; [[ -s $tmp/err ]] && IFS= read -r line <"$tmp/err"; printf '%s' "$line"; }
esc=$'\033'

# Colours: a #rrggbb value becomes a truecolor escape, anything else the
# ANSI fallback.
# Rows: value | fallback | escape after ESC[
rows=(
  "#ff5a36|33|38;2;255;90;54m"
  "#FF5A36|33|38;2;255;90;54m"
  "#000000|31|38;2;0;0;0m"
  "|33|33m"
  "red|32|32m"
  "#ff5a3|31|31m"
  "#ff5a366|31|31m"
  "ff5a36|31|31m"
)
for row in "${rows[@]}"; do
  IFS='|' read -r value fallback want <<<"$row"
  run "vgs_tui_sgr $(printf '%q' "$value") $fallback"
  check "colour [$value] is ESC[$want" test "$(cat "$tmp/out")" == "${esc}[$want"
done
run 'vgs_tui_step "Updating"' VGS_TUI_ACCENT='#010203'
check "a step is an accent bold line after a blank line" test "$(cat "$tmp/out")" == $'\n'"${esc}[38;2;1;2;3m${esc}[1mUpdating${esc}[0m"
run 'vgs_tui_warn "careful"' VGS_TUI_WARNING='#040506'
check "a warning is on stderr alone" test ! -s "$tmp/out"
check "a warning is in the warning colour" test "$(cat "$tmp/err")" == "${esc}[38;2;4;5;6mcareful${esc}[0m"
run 'vgs_tui_error "broken"'
check "an error is on stderr alone" test ! -s "$tmp/out"
check "an error without a theme is ANSI red" test "$(cat "$tmp/err")" == "${esc}[31mbroken${esc}[0m"

run 'vgs_tui_header "-Title" "a line"'
check "a header is one bordered gum style" test "$(cat "$tmp/gum")" == "$(printf '%s\n' style --border normal --padding "1 2" -- -Title "a line")"

# Questions need the terminal; unattended, confirm answers yes and asks nothing.
rm -f -- "$tmp/gum"
run 'vgs_tui_confirm "Remove it?" --default=false' VGS_TUI_UNATTENDED=1
check "an unattended confirm answers yes" test "$status" == 0
check "an unattended confirm prints its answer" test "$(cat "$tmp/out")" == "Remove it? yes (unattended)"
check "an unattended confirm runs no gum" test ! -e "$tmp/gum"
for fn in confirm choose input filter; do
  run "vgs_tui_$fn 'Question?'"
  check "$fn with no terminal returns 2" test "$status" == 2
  check "$fn with no terminal is refused" test "$(err_first)" == "vgs-tui: refused: $fn=no-terminal"
  check "$fn with no terminal runs no gum" test ! -e "$tmp/gum"
done
on_tty 'vgs_tui_confirm "Remove it?" --default=false'
check "a confirm on a terminal asks gum" test "$(cat "$tmp/gum")" == "$(printf '%s\n' confirm --default=false -- "Remove it?")"
check "a confirm answers gum's yes" test "$status" == 0
echo 1 >"$tmp/gum-exit"
on_tty 'vgs_tui_confirm "Remove it?"'
check "a confirm answers gum's no" test "$status" == 1
rm -f -- "$tmp/gum-exit"
on_tty 'printf "a\nb\n" | vgs_tui_choose --header Pick'
check "a choose on a terminal hands gum its arguments" test "$(cat "$tmp/gum")" == "$(printf '%s\n' choose --header Pick)"

# The sudo session: drop the credential, authorize once, keep it alive in
# the background, and drop it again at end, on exit and on a signal, with
# the keepalive gone each time.
keepalive_gone() { local pid; pid="$(cat "$tmp/keepalive")"; [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null; }
session="vgs_tui_sudo_session start; printf '%s' \"\$_vgs_tui_keepalive_pid\" >$(printf '%q' "$tmp/keepalive")"
# Rows: name | what runs after start | exit
rows=(
  "an ended session||0"
  "an exiting session|exit 3|3"
  "a terminated session|kill -TERM \$\$; sleep 5|143"
  "a hung-up session|kill -HUP \$\$; sleep 5|129"
)
for row in "${rows[@]}"; do
  IFS='|' read -r name after want_exit <<<"$row"
  rm -f -- "$tmp/sudo" "$tmp/keepalive"
  run "$session; ${after:-vgs_tui_sudo_session end}"
  check "$name exits $want_exit" test "$status" == "$want_exit"
  check "$name drops, authorizes and drops again" test "$(cat "$tmp/sudo")" == "$(printf '%s\n' -k /usr/bin/true -k)"
  check "$name leaves no keepalive" keepalive_gone
done
rm -f -- "$tmp/sudo"; touch "$tmp/sudo-deny"
run 'vgs_tui_sudo_session start; echo started'
check "a refused password fails start" test "$status" == 1
check "a refused password is named" test "$(err_first)" == "vgs-tui: refused: sudo=not-authorized"
check "a refused password starts no session" test "$(cat "$tmp/sudo")" == "$(printf '%s\n' -k /usr/bin/true)"
rm -f -- "$tmp/sudo-deny"
run 'vgs_tui_sudo_session begin'
check "an unknown session step is refused" test "$status:$(err_first)" == "2:vgs-tui: refused: sudo-session=begin"

# The lock: one holder per name, a lower-case name only.
# Two holders of one name: this shell, then a child bash that sources the
# same library.
lock_twice() { run "vgs_tui_lock update; st=0; $BASH -c 'source \"\$0\"; vgs_tui_lock update' $(printf '%q' "$LIB") || st=\$?; echo second=\$st"; }
lock_twice
check "a second holder is refused busy" grep -qxF second=75 "$tmp/out"
check "a second holder is named" test "$(err_first)" == "vgs-tui: refused: lock=update reason=busy"
check "the lock file is under the runtime dir" test -f "$rt/vgs-tui-update.lock"
for name in "../x" "Update" "" "-x" "a/b"; do
  run "vgs_tui_lock $(printf '%q' "$name")"
  check "lock name [$name] is refused" test "$status:$(err_first)" == "2:vgs-tui: refused: lock-name=$name"
done

# The log: the script runs again under script(1) with its arguments, the
# file keeps its output and the exit status is the script's.
printf 'source "$LIB"\nvgs_tui_log %q "$@"\necho "logged=$VGS_TUI_LOGGED args=$*"\nexit 7\n' "$tmp/run.log" >"$tmp/logged.sh"
status=0
"${lib_env[@]}" LIB="$LIB" "$BASH" "$tmp/logged.sh" 'a b' c </dev/null >"$tmp/out" 2>&1 || status=$?
check "a logged script exits with its own status" test "$status" == 7
check "a logged script shows its output" grep -qF "logged=1 args=a b c" "$tmp/out"
check "the log keeps the output" grep -qF "logged=1 args=a b c" "$tmp/run.log"

# The reboot check: the running kernel's modules and a replaced Hyprland.
kernel=""
for dir in /lib/modules/*/; do [[ -d $dir ]] && { kernel="$(basename -- "$dir")"; break; }; done
[[ -n $kernel ]] || { echo "test-tui: status=not-measured missing=/lib/modules/<release>"; exit 77; }
cp -- "$(command -v sleep)" "$tmp/replaced"
"$tmp/replaced" 60 &
replaced_pid=$!
trap 'kill "$replaced_pid" 2>/dev/null; rm -rf -- "${tmp:?}"' EXIT
rm -- "$tmp/replaced"
# Rows: name | release | pids | exit | stdout
rows=(
  "a current system|$kernel||1|"
  "a replaced kernel|0.0.0-vgs-test||0|reboot=kernel"
  "a replaced Hyprland|$kernel|$replaced_pid|0|reboot=hyprland"
  "both replaced|0.0.0-vgs-test|$$ $replaced_pid|0|reboot=kernel reboot=hyprland"
  "a current Hyprland|$kernel|$$|1|"
)
for row in "${rows[@]}"; do
  IFS='|' read -r name release pids want_exit want_out <<<"$row"
  printf '%s\n' "$release" >"$tmp/release"
  printf '%s\n' $pids >"$tmp/pids"
  if [[ -n $pids ]]; then echo 0 >"$tmp/pgrep-exit"; else rm -f -- "$tmp/pgrep-exit"; fi
  run 'vgs_tui_reboot_check'
  check "$name exits $want_exit" test "$status" == "$want_exit"
  check "$name prints [$want_out]" test "$(tr '\n' ' ' <"$tmp/out" | sed 's/ $//')" == "$want_out"
done
echo 3 >"$tmp/pgrep-exit"; printf '%s\n' "$kernel" >"$tmp/release"; : >"$tmp/pids"
run 'vgs_tui_reboot_check'
check "a failed pgrep is refused" test "$status:$(err_first)" == "1:vgs-tui: refused: reboot-check=pgrep exit=3"

# The plugin template's confirm, .agents/skills/vgs-plugin/templates/tui.sh,
# run on a pseudo-terminal with a gum whose confirm answers as the row sets
# and whose other commands succeed: No ends the script with 0, and a Ctrl-C
# (130) or a refusal (2) leaves with its own code, so present shows no Done
# prompt for either.
template="$repo/.agents/skills/vgs-plugin/templates/tui.sh"
tstubs="$tmp/template-stubs"; mkdir -p "$tstubs"
printf '#!/bin/sh\n[ "$1" = confirm ] || exit 0\nread -r st <"%s"\nexit "$st"\n' "$tmp/confirm-exit" >"$tstubs/gum"
chmod +x "$tstubs/gum"
# run_template FILE CONFIRM_EXIT: FILE as a script, confirm answering
# CONFIRM_EXIT; the exit status in $status.
run_template() {
  printf '%s\n' "$2" >"$tmp/confirm-exit"
  status=0
  "${lib_env[@]}" PATH="$tstubs:$stubs:$base_path" VGS_TUI_LIB="$lib" script -qec "$(printf '%q ' "$BASH" "$1")" /dev/null \
    </dev/null >"$tmp/out" 2>&1 || status=$?
}
# run_template_rows FILE QUIET: every row through FILE; prints ok and FAIL
# lines unless QUIET is `quiet`; returns the number of failing rows.
run_template_rows() {
  local row confirm want red=0
  for row in "0|0" "1|0" "130|130" "2|2"; do
    IFS='|' read -r confirm want <<<"$row"
    run_template "$1" "$confirm"
    if [[ $status == "$want" ]]; then
      [[ $2 == quiet ]] || ok "the template exits $want when confirm answers $confirm"
    else
      red=$((red + 1))
      [[ $2 == quiet ]] || fail "the template exits $want when confirm answers $confirm: got $status"
    fi
  done
  return "$red"
}
run_template_rows "$template" loud || true

# Must-fail controls, each on a copy of the library missing one rule.
control() { # NAME NEEDLE REPLACEMENT: LIB names the copy
  local copy="$tmp/control-$1.sh"
  check "the $1 control's text occurs once" \
    python3 -c 'import sys; sys.exit(0 if open(sys.argv[1]).read().count(sys.argv[2]) == 1 else 1)' "$lib" "$2"
  python3 -c 'import sys; p, o, a, b = sys.argv[1:]; open(o, "w").write(open(p).read().replace(a, b))' "$lib" "$copy" "$2" "$3"
  check "the $1 mutant differs" test "$(cmp -s "$lib" "$copy"; echo $?)" == 1
  LIB="$copy"
}
control no-terminal-check ': 2>/dev/null <>/dev/tty ||' 'true ||'
rm -f -- "$tmp/gum"
run 'vgs_tui_confirm "Remove it?"'
check "the no-terminal-check mutant asks gum with no terminal" test -e "$tmp/gum"
control kept-credential 'sudo -k || _vgs_tui_refuse 1 "sudo=revoke-failed"' 'true || _vgs_tui_refuse 1 "sudo=revoke-failed"'
rm -f -- "$tmp/sudo"
run "$session; exit 0"
check "the kept-credential mutant ends without sudo -k" test "$(cat "$tmp/sudo")" == "$(printf '%s\n' -k /usr/bin/true)"
control shared-lock 'flock -n -E 75 "$_vgs_tui_lock_fd" || status=$?' 'true || status=$?'
lock_twice
check "the shared-lock mutant lets a second holder in" grep -qxF second=0 "$tmp/out"
LIB="$lib"

# The template's control: a copy that turns every confirm status into success.
template_copy="$tmp/control-template.sh"
python3 -c 'import sys; p, o = sys.argv[1:]; s = open(p).read(); a = "vgs_tui_confirm \"Continue?\" || status=$?"; assert s.count(a) == 1; open(o, "w").write(s.replace(a, "vgs_tui_confirm \"Continue?\" || exit 0"))' "$template" "$template_copy"
check "the swallowed-confirm mutant differs" test "$(cmp -s "$template" "$template_copy"; echo $?)" == 1
check "the swallowed-confirm mutant fails a template row" test "$(run_template_rows "$template_copy" quiet && echo green || echo red)" == red

rows_done test-tui
