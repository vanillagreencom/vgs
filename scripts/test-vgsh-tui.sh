#!/usr/bin/env bash
# Controls for bin/vgsh-tui, the floating TUI presenter, and `vgsh tui
# present`, which hands it a command. present runs on a pseudo-terminal
# script(1) opens, with a key typed every 0.2 s, and runs stub commands: the
# Done and Failed prompts, the skip on 130, a typed Ctrl-C, the exit code,
# the plain
# presentation, the gum.env parse, the argv list, the exported paths and
# the plugin copy. launch and `vgsh tui present` run against a stub
# xdg-terminal-exec that records its argv, behind a stub setsid that
# records its first argument and runs the rest in the foreground. `vgsh tui
# list` and `vgsh tui open` run against a stub qs that answers the shell's
# reply and records its arguments. No row opens a terminal window.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
command -v script >/dev/null || { echo "test-vgsh-tui: status=not-measured missing=script"; exit 77; }
command -v timeout >/dev/null || { echo "test-vgsh-tui: status=not-measured missing=timeout"; exit 77; }
subject="$repo/bin/vgsh-tui"
stubs="$tmp/stubs"; state="$tmp/state"; rt="$tmp/rt"; snap="$tmp/snapshot"
gum_env="$state/vgs/theme/gum.env"
mkdir -p "$stubs" "$state/vgs/theme" "$rt"
tui_env=("${base_env[@]}" PATH="$stubs:$base_path" SHELL="$BASH" XDG_STATE_HOME="$state" XDG_RUNTIME_DIR="$rt")

stub() { printf '#!/bin/sh\n%s\n' "$2" >"$stubs/$1"; chmod +x "$stubs/$1"; } # NAME BODY
stub exits 'echo "ran $1"; exit "$1"'
stub record ": >\"$tmp/argv\"; for a; do printf '%s\\n' \"\$a\" >>\"$tmp/argv\"; done"
stub envdump 'printf "LIB=%s\nLOGO=%s\nID=%s\nDIR=%s\nACCENT=%s\nCONFIRM=%s\n" "${VGS_TUI_LIB-unset}" "${VGS_TUI_LOGO-unset}" "${VGS_PLUGIN_ID-unset}" "${VGS_PLUGIN_DIR-unset}" "${VGS_TUI_ACCENT-unset}" "${GUM_CONFIRM_SELECTED_BACKGROUND-unset}"'
stub setsid "printf '%s\\n' \"\$1\" >\"$tmp/setsid\"; [ \"\$1\" = -f ] && shift; exec \"\$@\""
# waitint SECS records its pid, then sleeps as that pid until SECS pass or a
# signal ends it.
stub waitint "echo \$\$ >\"$tmp/child\"; exec sleep \"\$1\""
stub xdg-terminal-exec ": >\"$tmp/term\"; for a; do printf '%s\\n' \"\$a\" >>\"$tmp/term\"; done"

# on_tty BIN ARGS...: BIN on a pseudo-terminal; stdout and stderr together
# land in $tmp/out, the exit status in $tty_status. A key is typed every
# 0.2 s: present drops keys queued within 0.1 s of each other as terminal
# replies, so the gap lets the next key answer the prompt. timeout ends a
# run whose prompt never gets its key.
on_tty() {
  local cmd
  cmd="$(printf '%q ' "$@")"
  set +e
  { while :; do printf x; sleep 0.2; done; } |
    timeout 30 "${tui_env[@]}" script -qec "$cmd" /dev/null >"$tmp/out" 2>&1
  tty_status=${PIPESTATUS[1]}
  set -e
}
# plain_run BIN ARGS...: BIN with no terminal; stdout in $tmp/out, stderr
# in $tmp/err, the exit status in $plain_status.
plain_run() {
  plain_status=0
  "${tui_env[@]}" "$@" </dev/null >"$tmp/out" 2>"$tmp/err" || plain_status=$?
}
out_has() { grep -qF -- "$1" "$tmp/out"; }
err_first() { local line=""; [[ -s $tmp/err ]] && IFS= read -r line <"$tmp/err"; printf '%s' "$line"; }
logo_line="███    ███   ███    ███   ███    ███"
done_text="Done! Press any key to close..."
failed_text() { printf 'Failed (exit code %s)! Press any key to close...' "$1"; }

# present: the prompt by exit code, none on 130 or under plain, the logo
# under full only, and the command's code as present's own.
# Rows: name | presentation | code | prompt: done, failed or none | logo: yes or no
rows=(
  "a success|full|0|done|yes"
  "a failure|full|1|failed|yes"
  "an exit of 130|full|130|none|yes"
  "a plain failure|plain|1|none|no"
  "a plain success|plain|0|none|no"
)
for row in "${rows[@]}"; do
  IFS='|' read -r name presentation code want_prompt want_logo <<<"$row"
  on_tty "$subject" present --presentation "$presentation" -- exits "$code"
  check "$name exits $code" test "$tty_status" == "$code"
  check "$name runs the command" out_has "ran $code"
  case "$want_prompt" in
    done) check "$name prompts Done" out_has "$done_text" ;;
    failed) check "$name prompts Failed with the code" out_has "$(failed_text "$code")" ;;
    none) check "$name prompts nothing" test "$(grep -c -e 'Done!' -e 'Failed (' "$tmp/out")" == 0 ;;
  esac
  if [[ $want_logo == yes ]]; then check "$name draws the logo" out_has "$logo_line"
  else check "$name draws no logo" test "$(grep -cF -- "$logo_line" "$tmp/out")" == 0; fi
done

# The prompt is on /dev/tty: with present's stdout in a file, the terminal
# still shows it and the file holds only the command's output.
prompt_on_tty() { # BIN
  rm -f -- "$tmp/stdout"
  set +e
  { while :; do printf x; sleep 0.2; done; } |
    timeout 30 "${tui_env[@]}" script -qec "$(printf '%q ' "$1" present -- exits 1) >$(printf '%q' "$tmp/stdout")" /dev/null >"$tmp/out" 2>&1
  tty_status=${PIPESTATUS[1]}
  set -e
}
prompt_on_tty "$subject"
check "a redirected present exits with the code" test "$tty_status" == 1
check "a redirected present prompts on the terminal" out_has "$(failed_text 1)"
check "a redirected present keeps the prompt out of stdout" test "$(grep -c 'Failed (' "$tmp/stdout")" == 0
check "a redirected present's stdout holds the command's output" grep -qxF 'ran 1' "$tmp/stdout"

# argv reaches the command as a list, never through a shell.
rm -f -- "$tmp/argv" "$tmp/planted"
plain_run "$subject" present --presentation plain -- record 'a b' "\$(touch $tmp/planted)" ';' '*'
check "argv runs" test "$plain_status" == 0
check "argv arrives word for word" test "$(cat "$tmp/argv")" == "a b
\$(touch $tmp/planted)
;
*"
check "no argument ran as shell code" test ! -e "$tmp/planted"

# The exported paths: this checkout's library and logo, and no plugin
# identity for a core command even when the caller's environment had one.
plain_run env VGS_PLUGIN_ID=stale VGS_PLUGIN_DIR=/stale "$subject" present --presentation plain -- envdump
check "VGS_TUI_LIB is the checkout's library" grep -qxF "LIB=$repo/bin/lib/tui.sh" "$tmp/out"
check "VGS_TUI_LOGO is the checkout's logo" grep -qxF "LOGO=$repo/bin/lib/logo.txt" "$tmp/out"
check "a core command has no VGS_PLUGIN_ID" grep -qxF "ID=unset" "$tmp/out"
check "a core command has no VGS_PLUGIN_DIR" grep -qxF "DIR=unset" "$tmp/out"
check "no gum.env exports no colour" grep -qxF "ACCENT=unset" "$tmp/out"
check "no gum.env warns nothing" test ! -s "$tmp/err"

# gum.env: every line KEY=#rrggbb with an accepted key, or none is used.
valid=$'GUM_CONFIRM_SELECTED_BACKGROUND=#aabbcc\nVGS_TUI_ACCENT=#FF5A36\nFOREGROUND=#000000\nBACKGROUND=#ffffff\nBORDER_FOREGROUND=#123456'
printf '%s\n' "$valid" >"$gum_env"
plain_run "$subject" present --presentation plain -- envdump
check "a valid gum.env exports a gum colour" grep -qxF "CONFIRM=#aabbcc" "$tmp/out"
check "a valid gum.env exports the accent" grep -qxF "ACCENT=#FF5A36" "$tmp/out"
check "a valid gum.env warns nothing" test ! -s "$tmp/err"
on_tty "$subject" present -- exits 0
check "the logo is drawn in the accent" out_has $'\033[38;2;255;90;54m'
bad_lines=(
  "PATH=#000000"
  "GUM_CONFIRM_PROMPT_FOREGROUND=red"
  "GUM_CONFIRM_PROMPT_FOREGROUND=#aabbc"
  "GUM_CONFIRM_PROMPT_FOREGROUND=#aabbcc; touch $tmp/planted"
  "GUM_CONFIRM_PROMPT_FOREGROUND=\$(touch $tmp/planted)"
  "gum_confirm_prompt_foreground=#aabbcc"
  "export GUM_CONFIRM_PROMPT_FOREGROUND=#aabbcc"
  " GUM_CONFIRM_PROMPT_FOREGROUND=#aabbcc"
  ""
)
for bad in "${bad_lines[@]}"; do
  printf '%s\n%s\n' "GUM_CONFIRM_SELECTED_BACKGROUND=#aabbcc" "$bad" >"$gum_env"
  plain_run "$subject" present --presentation plain -- envdump
  check "gum.env line [$bad] still runs the command" test "$plain_status" == 0
  check "gum.env line [$bad] exports no line of the file" grep -qxF "CONFIRM=unset" "$tmp/out"
  check "gum.env line [$bad] is named" test "$(err_first)" == "vgsh-tui: gum-env=rejected line=2 path=$gum_env"
  check "gum.env line [$bad] runs nothing" test ! -e "$tmp/planted"
done
rm -f -- "$gum_env"

# --plugin: the snapshot's tui/ directory is copied, VGS_PLUGIN_DIR names the
# copy, argv[0] runs from it, and the copy is gone when present exits. The
# script removes the snapshot first, as a restart would, then sources a
# file beside it through VGS_PLUGIN_DIR.
plugin_snapshot() {
  rm -rf -- "$snap"; mkdir -p "$snap/tui"
  printf '#!/usr/bin/env bash\nset -e\nrm -rf -- %q\nsource "$VGS_PLUGIN_DIR/tui/helper.sh"\nprintf "id=%%s dir=%%s self=%%s args=%%s\\n" "$VGS_PLUGIN_ID" "$VGS_PLUGIN_DIR" "$0" "$*"\n' "$snap" >"$snap/tui/run.sh"
  printf 'echo helper-sourced\n' >"$snap/tui/helper.sh"
  printf '#!/bin/sh\n' >"$snap/tui/noexec.sh"
  printf '#!/bin/sh\n' >"$snap/outside.sh"
  chmod +x "$snap/tui/run.sh" "$snap/outside.sh"
  ln -s -- "$stubs/exits" "$snap/tui/link.sh"
  printf '#!/bin/sh\necho $$ >%q\nexec sleep "$1"\n' "$tmp/child" >"$snap/tui/wait.sh"
  chmod +x "$snap/tui/wait.sh"
}
plugin_snapshot
on_tty "$subject" present --plugin acme.tui --dir "$snap" -- tui/run.sh 'x y'
check "a plugin script exits 0" test "$tty_status" == 0
check "a plugin script sources from the copy after the snapshot is gone" out_has "helper-sourced"
check "a plugin script sees its id, the copy, its own copy and its argument" \
  grep -qE "^id=acme\.tui dir=$rt/vgs-tui\.[^/ ]+ self=$rt/vgs-tui\.[^/ ]+/tui/run\.sh args=x y"$'\r?$' "$tmp/out"
check "the copy is removed when present exits" test -z "$(find "$rt" -mindepth 1 -maxdepth 1 -name 'vgs-tui.*')"

# A script outside the copied tui/ directory, or not executable, is refused
# under the Failed prompt, and its copy is removed too.
# Rows: argv[0] | reason
rows=(
  "outside.sh|outside-tui"
  "tui/../outside.sh|outside-tui"
  "/bin/true|outside-tui"
  "tui/missing.sh|outside-tui"
  "tui/link.sh|outside-tui"
  "tui/noexec.sh|not-executable"
)
for row in "${rows[@]}"; do
  IFS='|' read -r rel reason <<<"$row"
  plugin_snapshot
  on_tty "$subject" present --plugin acme.tui --dir "$snap" -- "$rel"
  check "script [$rel] exits 1" test "$tty_status" == 1
  check "script [$rel] is refused $reason" out_has "vgsh-tui: refused: script=$rel reason=$reason"
  check "script [$rel] is reported under the Failed prompt" out_has "$(failed_text 1)"
  check "script [$rel] leaves no copy" test -z "$(find "$rt" -mindepth 1 -maxdepth 1 -name 'vgs-tui.*')"
done
rm -rf -- "$snap"
on_tty "$subject" present --plugin acme.tui --dir "$snap" -- tui/run.sh
check "a missing snapshot is refused" out_has "vgsh-tui: refused: copy=$snap/tui reason=failed"
check "a missing snapshot exits 1" test "$tty_status" == 1

# Ctrl-C: the terminal's interrupt byte, typed once the command runs, stops
# the command, and present exits 130 with no prompt and no copy left. The
# command sleeps 8 s, so a Ctrl-C that fails to reach it ends in a Done
# prompt instead of the timeout.
# on_tty_interrupt BIN ARGS...: as on_tty, with 0x03 typed once $tmp/child
# exists. The typist stops when the reader side has exited, which marks
# $tmp/reader-done, or after the reader's own 30 s deadline, so a command
# that never writes the marker ends the helper instead of hanging it.
on_tty_interrupt() {
  local cmd polls=0
  cmd="$(printf '%q ' "$@")"
  rm -f -- "$tmp/child" "$tmp/reader-done"
  set +e
  {
    while [[ ! -s $tmp/child && ! -e $tmp/reader-done ]] && ((polls++ < 600)); do sleep 0.05; done
    [[ -s $tmp/child ]] && printf '\003'
    while [[ ! -e $tmp/reader-done ]]; do printf x; sleep 0.2; done
  } | {
    timeout 30 "${tui_env[@]}" script -qec "$cmd" /dev/null >"$tmp/out" 2>&1
    st=$?
    : >"$tmp/reader-done"
    exit "$st"
  }
  tty_status=${PIPESTATUS[1]}
  set -e
}
child_gone() { local pid; pid="$(cat "$tmp/child" 2>/dev/null)"; [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null; }
on_tty_interrupt "$subject" present -- waitint 8
check "a Ctrl-C'd command exits 130" test "$tty_status" == 130
check "a Ctrl-C'd command is stopped" child_gone
check "a Ctrl-C'd command prompts nothing" test "$(grep -c -e 'Done!' -e 'Failed (' "$tmp/out")" == 0
plugin_snapshot
on_tty_interrupt "$subject" present --plugin acme.tui --dir "$snap" -- tui/wait.sh 8
check "a Ctrl-C'd plugin script exits 130" test "$tty_status" == 130
check "a Ctrl-C'd plugin script is stopped" child_gone
check "a Ctrl-C'd plugin script prompts nothing" test "$(grep -c -e 'Done!' -e 'Failed (' "$tmp/out")" == 0
check "a Ctrl-C'd plugin script leaves no copy" test -z "$(find "$rt" -mindepth 1 -maxdepth 1 -name 'vgs-tui.*')"

# launch: setsid -f, which forks the terminal off so launch returns, then
# xdg-terminal-exec with the app-id of the size, the title and present's
# argv.
# launch_row NAME WANT_TERMINAL_ARGV_LINES ARGS...
launch_row() {
  local name="$1" want="$2"
  shift 2
  rm -f -- "$tmp/term" "$tmp/setsid"
  plain_run "$@"
  check "$name exits 0" test "$plain_status" == 0
  check "$name forks through setsid -f" test "$(cat "$tmp/setsid" 2>/dev/null)" == -f
  check "$name hands the terminal its argv" test "$(cat "$tmp/term" 2>/dev/null)" == "$want"
}
lines() { printf '%s\n' "$@"; }
launch_row "a default launch" "$(lines --app-id=org.vgs.tui "--title=VGS · Update x" -- "$subject" present --presentation full -- exits 0)" \
  "$subject" launch --title "Update x" -- exits 0
launch_row "a wide launch" "$(lines --app-id=org.vgs.tui.wide "--title=VGS · w" -- "$subject" present --presentation full -- exits 0)" \
  "$subject" launch --title w --size wide -- exits 0
launch_row "a tall plain launch" "$(lines --app-id=org.vgs.tui.tall "--title=VGS · t" -- "$subject" present --presentation plain -- exits 'a b')" \
  "$subject" launch --size tall --presentation plain --title t -- exits 'a b'
launch_row "a plugin launch" "$(lines --app-id=org.vgs.tui "--title=VGS · p" -- "$subject" present --presentation full --plugin acme.tui --dir "$snap" -- tui/run.sh)" \
  "$subject" launch --title p --plugin acme.tui --dir "$snap" -- tui/run.sh
launch_row "a relative snapshot" "$(lines --app-id=org.vgs.tui "--title=VGS · p" -- "$subject" present --presentation full --plugin acme.tui --dir "$tmp/./snapshot" -- tui/run.sh)" \
  env -C "$tmp" "$subject" launch --title p --plugin acme.tui --dir ./snapshot -- tui/run.sh
launch_row "vgsh tui present" "$(lines --app-id=org.vgs.tui "--title=VGS · exits" -- "$subject" present --presentation full -- exits 0)" \
  "$repo/bin/vgsh" tui present -- exits 0
launch_row "vgsh tui present with a title and a size" "$(lines --app-id=org.vgs.tui.tall "--title=VGS · Up" -- "$subject" present --presentation full -- "$stubs/exits" 1)" \
  "$repo/bin/vgsh" tui present --title Up --size tall -- "$stubs/exits" 1

# Refusals before any terminal opens.
# Rows: exit | first stderr line | the command's words, space-delimited
rows=(
  "2|vgsh-tui: refused: title=missing|$subject launch -- exits 0"
  "2|vgsh-tui: refused: size=huge|$subject launch --title t --size huge -- exits 0"
  "2|vgsh-tui: refused: size=toString|$subject launch --title t --size toString -- exits 0"
  "2|vgsh-tui: refused: presentation=loud|$subject launch --title t --presentation loud -- exits 0"
  "2|vgsh-tui: refused: argument=exits|$subject launch --title t exits"
  "2|vgsh-tui: refused: separator=missing|$subject launch --title t"
  "2|vgsh-tui: refused: command=missing|$subject launch --title t --"
  "2|vgsh-tui: refused: option=--title value=missing|$subject launch --title"
  "2|vgsh-tui: refused: dir=missing plugin=acme.tui|$subject launch --title t --plugin acme.tui -- exits 0"
  "2|vgsh-tui: refused: plugin=missing dir=/x|$subject launch --title t --dir /x -- exits 0"
  "2|vgsh-tui: refused: argument=--title|$subject present --title t -- exits 0"
  "2|vgsh-tui: refused: argument=--size|$subject present --size wide -- exits 0"
  "2|vgsh-tui: refused: verb=frob|$subject frob"
  "2|vgsh-tui: refused: argument=x|$subject check x"
  "2|vgsh-tui: refused: verb=missing|$subject"
  "2|vgsh: refused: tui-subcommand=missing|$repo/bin/vgsh tui"
  "2|vgsh: refused: tui-subcommand=frob|$repo/bin/vgsh tui frob"
  "2|vgsh: refused: key=missing|$repo/bin/vgsh tui open"
  "2|vgsh: refused: argument=x|$repo/bin/vgsh tui open a/b x"
  "2|vgsh: refused: argument=x|$repo/bin/vgsh tui list x"
  "2|vgsh: refused: option=--title value=missing|$repo/bin/vgsh tui present --title"
  "2|vgsh: refused: argument=exits|$repo/bin/vgsh tui present exits"
  "2|vgsh: refused: command=missing|$repo/bin/vgsh tui present --"
  "2|vgsh-tui: refused: size=huge|$repo/bin/vgsh tui present --size huge -- exits 0"
)
for row in "${rows[@]}"; do
  IFS='|' read -r want_exit want_err words <<<"$row"
  read -r -a cmd <<<"$words"
  rm -f -- "$tmp/term"
  plain_run "${cmd[@]}"
  check "[${words#"$repo/"}] exits $want_exit" test "$plain_status" == "$want_exit"
  check "[${words#"$repo/"}] names [$want_err]" test "$(err_first)" == "$want_err"
  check "[${words#"$repo/"}] opens no terminal" test ! -e "$tmp/term"
done

# vgsh tui list and open: the shell's reply through a stub qs, which records
# the call vgsh handed it. The shell decides what is listed and opened.
stub qs "printf '%s\\n' \"\$*\" >\"$tmp/qs\"; printf 'qs log line\\n%s\\n' \"\$STUB_REPLY\""
printf '%s\n' "$$" >"$rt/vgsh.lock"
entries='[{"key":"acme.tui/hello","plugin":"acme.tui","name":"hello","title":"Hello","label":"Say hello","icon":"terminal","group":"Smoke"},{"key":"core/doctor","plugin":"core","name":"doctor","title":"Doctor","label":"Check the system","icon":"stethoscope","group":"System"}]'
listed="$(printf '%-32s %-16s %s\\n%-32s %-16s %s' acme.tui/hello Smoke 'Say hello' core/doctor System 'Check the system')"
# cli_row BIN REPLY WORDS WANT_EXIT WANT_STDOUT WANT_FIRST_STDERR WANT_QS_CALL:
# WANT_STDOUT holds printf %b escapes; returns 1 when a check failed.
cli_row() {
  local bin="$1" reply="$2" words want_exit="$4" want_out="$5" want_err="$6" want_call="$7" bad=0
  read -r -a words <<<"$3"
  rm -f -- "$tmp/qs"
  plain_run env STUB_REPLY="$reply" "$bin" "${words[@]}"
  [[ $plain_status == "$want_exit" ]] || bad=1
  [[ "$(cat "$tmp/out")" == "$(printf '%b' "$want_out")" ]] || bad=1
  [[ "$(err_first)" == "$want_err" ]] || bad=1
  [[ "$(cat "$tmp/qs" 2>/dev/null)" == "$want_call" ]] || bad=1
  return "$bad"
}
# rows: name | shell reply | vgsh words | exit | stdout | first stderr line | qs call
cli_rows=(
  "tui list prints a line per listed TUI|$entries|tui list|0|$listed||ipc --pid $$ call shell listTuis"
  "tui list with nothing listed prints nothing|[]|tui list|0|||ipc --pid $$ call shell listTuis"
  "tui list refuses a reply that is not a list|null|tui list|1||vgsh: refused: reply=malformed|ipc --pid $$ call shell listTuis"
  "tui list refuses an object reply|{\"key\":\"a/b\"}|tui list|1||vgsh: refused: reply=malformed|ipc --pid $$ call shell listTuis"
  "tui list refuses a row without a string label|[{\"key\":\"a/b\",\"group\":\"G\",\"label\":3}]|tui list|1||vgsh: refused: reply=malformed|ipc --pid $$ call shell listTuis"
  "tui list refuses a guard refusal as unparseable|refused: guard=unowned pid=1|tui list|1||vgsh: refused: reply=unparseable|ipc --pid $$ call shell listTuis"
  "tui open prints the shell's ok|ok|tui open acme.tui/hello|0|ok||ipc --pid $$ call shell openTui acme.tui/hello"
  "tui open refuses with the shell's refusal|refused: tui=acme.tui/nope reason=undeclared|tui open acme.tui/nope|1||vgsh: refused: tui=acme.tui/nope reason=undeclared|ipc --pid $$ call shell openTui acme.tui/nope"
)
# run_cli_rows BIN QUIET: every row through BIN; prints ok and FAIL lines
# unless QUIET is `quiet`; returns the number of failing rows.
run_cli_rows() {
  local row name reply words want_exit want_out want_err want_call red=0
  for row in "${cli_rows[@]}"; do
    IFS='|' read -r name reply words want_exit want_out want_err want_call <<<"$row"
    if cli_row "$1" "$reply" "$words" "$want_exit" "$want_out" "$want_err" "$want_call"; then
      [[ $2 == quiet ]] || ok "$name"
    else
      red=$((red + 1))
      [[ $2 == quiet ]] || fail "$name: exit=$plain_status stdout=$(cat "$tmp/out") stderr=$(err_first) qs=$(cat "$tmp/qs" 2>/dev/null)"
    fi
  done
  return "$red"
}
run_cli_rows "$repo/bin/vgsh" loud || true

# With no xdg-terminal-exec on PATH, launch refuses before exec.
bare="$tmp/bare"; mkdir -p "$bare"
ln -s -- "$node_bin" "$bare/node"
for tool in bash readlink dirname awk; do
  tool_bin="$(command -v "$tool")" || { echo "test-vgsh-tui: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$bare/$tool"
done
plain_run env PATH="$bare" "$subject" launch --title t -- exits 0
check "no terminal launcher exits 69" test "$plain_status" == 69
check "no terminal launcher is named" test "$(err_first)" == "vgsh-tui: refused: terminal=missing"
# check: launch's own terminal test, which the shell runs before it answers.
plain_run env PATH="$bare" "$subject" check
check "check without a terminal launcher exits 69" test "$plain_status" == 69
check "check without a terminal launcher names it as launch does" test "$(err_first)" == "vgsh-tui: refused: terminal=missing"
plain_run "$subject" check
check "check with a terminal launcher on PATH exits 0" test "$plain_status" == 0
check "check with a terminal launcher prints nothing" test ! -s "$tmp/err"

# A tree for a copy of bin/vgsh, bin/vgsh-tui or bin/vgsh-plugin-judge, as
# the runner CLI's mutant trees are built: the three files copied, so a
# control can rewrite one, and
# bin/lib, which holds the loader, linked beside them. SHELL_DIR is linked
# as shell/, where launch reads the size table.
tui_tree() { # DIR SHELL_DIR
  mkdir -p "$1/bin"
  cp -- "$repo/bin/vgsh" "$repo/bin/vgsh-tui" "$repo/bin/vgsh-plugin-judge" "$1/bin/"
  ln -s -- "$repo/bin/lib" "$1/bin/lib"
  ln -s -- "$2" "$1/shell"
}

# With the size table unreadable, launch refuses rather than guess an app-id.
mkdir -p "$tmp/no-table-shell/Core"
tui_tree "$tmp/no-table" "$tmp/no-table-shell"
rm -f -- "$tmp/term"
plain_run "$tmp/no-table/bin/vgsh-tui" launch --title t -- exits 0
check "an unreadable size table exits 1" test "$plain_status" == 1
check "an unreadable size table is named after the loader's line" grep -qxF "vgsh-tui: refused: size-table=unreadable exit=2" "$tmp/err"
check "an unreadable size table opens no terminal" test ! -e "$tmp/term"

# Must-fail controls, each on a copy of one file in a copy of the tree.
# control NAME FILE NEEDLE REPLACEMENT: sets control_bin to the copy of FILE.
control() {
  local dir="$tmp/control-$1"
  tui_tree "$dir" "$repo/shell"
  check "the $1 control's text occurs once in $2" \
    python3 -c 'import sys; sys.exit(0 if open(sys.argv[1]).read().count(sys.argv[2]) == 1 else 1)' "$repo/bin/$2" "$3"
  python3 -c 'import sys; p, o, a, b = sys.argv[1:]; open(o, "w").write(open(p).read().replace(a, b))' "$repo/bin/$2" "$dir/bin/$2" "$3" "$4"
  check "the $1 mutant differs" test "$(cmp -s "$repo/bin/$2" "$dir/bin/$2"; echo $?)" == 1
  control_bin="$dir/bin/$2"
}

control sourced-gum-env vgsh-tui '  while IFS= read -r line || [[ -n $line ]]; do' '  source "$gum_env"; while false; do'
printf '%s\n' "GUM_CONFIRM_PROMPT_FOREGROUND=\$(touch $tmp/planted)" >"$gum_env"
plain_run "$control_bin" present --presentation plain -- exits 0
check "the sourced-gum-env mutant runs the planted line" test -e "$tmp/planted"
rm -f -- "$gum_env" "$tmp/planted"

control stdout-prompt vgsh-tui '"$(vgs_tui_sgr "${VGS_TUI_DANGER:-}" 31)" "$code" >/dev/tty' '"$(vgs_tui_sgr "${VGS_TUI_DANGER:-}" 31)" "$code"'
prompt_on_tty "$control_bin"
check "the stdout-prompt mutant keeps the prompt off the terminal" test "$(grep -c 'Failed (' "$tmp/out")" == 0
check "the stdout-prompt mutant writes the prompt to stdout" grep -q 'Failed (exit code 1)' "$tmp/stdout"

control shell-string vgsh-tui $'\n    "${argv[@]}"\n' $'\n    bash -c "${argv[*]}"\n'
rm -f -- "$tmp/argv"
plain_run "$control_bin" present --presentation plain -- record 'a b' "\$(touch $tmp/planted)"
check "the shell-string mutant runs an argument as shell code" test -e "$tmp/planted"
rm -f -- "$tmp/planted"

# The helper's own control: a command that exits without writing the marker,
# under the plain presentation so nothing waits for a key, ends the helper
# well inside the deadline, and the Ctrl-C checks fail for it.
started=$SECONDS
on_tty_interrupt "$subject" present --presentation plain -- exits 0
check "a command without the marker ends the helper before the deadline" test $((SECONDS - started)) -lt 30
check "a command without the marker fails the Ctrl-C exit check" test "$tty_status" != 130
check "a command without the marker fails the Ctrl-C stop check" test "$(child_gone && echo gone || echo absent)" == absent

control ignored-interrupt vgsh-tui $'\n    trap : INT\n' $'\n    trap \'\' INT\n'
on_tty_interrupt "$control_bin" present -- waitint 8
check "the ignored-interrupt mutant lets the command outlive Ctrl-C" test "$tty_status" == 0
check "the ignored-interrupt mutant prompts Done" out_has "$done_text"

control snapshot-dir vgsh-tui 'if copy_plugin; then export VGS_PLUGIN_DIR="$copy_dir"' 'if copy_plugin; then export VGS_PLUGIN_DIR="$plugin_dir"'
plugin_snapshot
on_tty "$control_bin" present --plugin acme.tui --dir "$snap" -- tui/run.sh
check "the snapshot-dir mutant loses the sourced file with the snapshot" test "$(grep -c helper-sourced "$tmp/out")" == 0

control one-app-id vgsh-tui 'process.stdout.write(layer.TUI_WINDOWS[size].appId);' 'process.stdout.write(layer.TUI_WINDOWS["default"].appId);'
rm -f -- "$tmp/term"
plain_run "$control_bin" launch --title w --size wide -- exits 0
check "the one-app-id mutant opens a wide TUI as default" grep -qxF -- --app-id=org.vgs.tui "$tmp/term"

control dropped-size vgsh '--size "$size" --presentation full' '--presentation full'
rm -f -- "$tmp/term"
plain_run "$control_bin" tui present --size tall -- exits 0
check "the dropped-size mutant opens a tall TUI as default" grep -qxF -- --app-id=org.vgs.tui "$tmp/term"

control attached-terminal vgsh-tui '  setsid -f xdg-terminal-exec' '  exec setsid xdg-terminal-exec'
rm -f -- "$tmp/term" "$tmp/setsid"
plain_run "$control_bin" launch --title t -- exits 0
check "the attached-terminal mutant does not fork the terminal off" test "$(cat "$tmp/setsid" 2>/dev/null)" != -f

control open-reply vgsh 'reply="$(ipc shell openTui "$1")" || exit $?' 'reply="$(ipc shell openTui "$1")" && reply=ok || exit $?'
check "the open-reply mutant fails a tui open row" test "$(run_cli_rows "$control_bin" quiet >/dev/null && echo green || echo red)" == red

control list-lines vgsh-plugin-judge 'e.key.padEnd(32)' 'e.label.padEnd(32)'
check "the list-lines mutant fails a tui list row" test "$(run_cli_rows "$tmp/control-list-lines/bin/vgsh" quiet >/dev/null && echo green || echo red)" == red

control unshaped-reply vgsh-plugin-judge 'if (!Array.isArray(entries) || ' 'if (false && '
check "the unshaped-reply mutant fails a tui list row" test "$(run_cli_rows "$tmp/control-unshaped-reply/bin/vgsh" quiet >/dev/null && echo green || echo red)" == red

control unchecked-terminal vgsh-tui 'bad_invocation "argument=$1"; require_terminal ;;' 'bad_invocation "argument=$1"; : ;;'
plain_run env PATH="$bare" "$control_bin" check
check "the unchecked-terminal mutant answers check without a terminal launcher" test "$plain_status" == 0

rows_done test-vgsh-tui
