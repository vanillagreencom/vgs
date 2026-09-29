#!/usr/bin/env bash
# Controls for bin/vgsh-tui, the floating TUI presenter, and `vgsh tui
# present`, which hands it a command. present runs on a pseudo-terminal
# script(1) opens, with a key typed every 0.2 s, and runs stub commands: the
# Done and Failed prompts, the skip on 130, a typed Ctrl-C, the exit code,
# the plain
# presentation, the gum.env parse, the argv list, the exported paths and
# the plugin copy, and the exit record: its running and ended files, the
# key's lock, a busy key, a termination and reap. launch and `vgsh tui
# present` run against a stub
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
stub xdg-terminal-exec ": >\"$tmp/term\"; for a; do printf '%s\\n' \"\$a\" >>\"$tmp/term\"; done; printf '%s\\n' \"\${VGSH_RUNNER_PID-unset}\" >\"$tmp/term-env\""

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

# --plugin: the whole snapshot is copied, VGS_PLUGIN_DIR names the copy,
# argv[0] runs from it, and the copy is gone when present exits. The script
# removes the snapshot first, as a restart would, then sources a file beside
# it and one at the snapshot's root, where a plugin keeps its own programs
# and data, through VGS_PLUGIN_DIR.
plugin_snapshot() {
  rm -rf -- "$snap"; mkdir -p "$snap/tui"
  printf '#!/usr/bin/env bash\nset -e\nrm -rf -- %q\nsource "$VGS_PLUGIN_DIR/tui/helper.sh"\nsource "$VGS_PLUGIN_DIR/data.sh"\nprintf "id=%%s dir=%%s self=%%s args=%%s\\n" "$VGS_PLUGIN_ID" "$VGS_PLUGIN_DIR" "$0" "$*"\n' "$snap" >"$snap/tui/run.sh"
  printf 'echo helper-sourced\n' >"$snap/tui/helper.sh"
  printf 'echo root-data-sourced\n' >"$snap/data.sh"
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
check "a plugin script reads its snapshot's root from the copy" out_has "root-data-sourced"
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
check "a missing snapshot is refused" out_has "vgsh-tui: refused: copy=$snap reason=failed"
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
# The shell's marker stays behind: the terminal is the user's, not the
# shell's, and `vgsh pkg run` refuses a caller that carries it.
rm -f -- "$tmp/term-env"
plain_run env VGSH_RUNNER_PID=4242 "$subject" launch --title t -- exits 0
check "a launch from the shell hands the terminal no VGSH_RUNNER_PID" test "$(cat "$tmp/term-env" 2>/dev/null)" == unset
launch_row "vgsh tui present" "$(lines --app-id=org.vgs.tui "--title=VGS · exits" -- "$subject" present --presentation full -- exits 0)" \
  "$repo/bin/vgsh" tui present -- exits 0
launch_row "vgsh tui present with a title and a size" "$(lines --app-id=org.vgs.tui.tall "--title=VGS · Up" -- "$subject" present --presentation full -- "$stubs/exits" 1)" \
  "$repo/bin/vgsh" tui present --title Up --size tall -- "$stubs/exits" 1

# The exit record: present writes the running record before the command
# runs and the ended record, with the command's code, after it, and holds
# the key's lock meanwhile.
rdir="$rt/vgs/tui"
stub during "ls -A \"\$1\" >\"$tmp/during\"; cat -- \"\$1\"/acme.tui@hello@*.running.json >\"$tmp/during-record\""
# leaver leaves a process behind that keeps every descriptor it was handed.
stub leaver "sleep 30 </dev/null >/dev/null 2>&1 & echo \$! >\"$tmp/leaver\""
# fdlocks counts the lock files it holds open.
stub fdlocks "for f in /proc/\$\$/fd/*; do readlink \"\$f\"; done | grep -c '\\.lock\$' >\"$tmp/fdlocks\""
title_words='VGS · Hi "q" \x'
record_opts=(--record acme.tui/hello --run 1-1 --record-dir "$rdir" --app-id org.vgs.tui --window-title "$title_words")
# record_of FILE: the record's fields as one JSON line, timestamps replaced
# by whether each has the shape present writes, or `absent`.
record_of() {
  python3 - "$1" <<'PY'
import json, os, re, sys
path = sys.argv[1]
if not os.path.exists(path):
    print("absent"); sys.exit()
r = json.load(open(path))
stamp = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")
for k in ("startedAt", "endedAt"):
    if isinstance(r.get(k), str):
        r[k] = "stamp" if stamp.match(r[k]) else "malformed:" + r[k]
print(json.dumps(r, sort_keys=True))
PY
}
want_record() { # STATE CODE
  python3 -c 'import json,sys; s, c, t = sys.argv[1:]; print(json.dumps({"key": "acme.tui/hello", "run": "1-1", "state": s, "code": None if c == "null" else int(c), "startedAt": "stamp", "endedAt": None if s == "running" else "stamp", "window": {"appId": "org.vgs.tui", "title": t}}, sort_keys=True))' "$1" "$2" "$title_words"
}
mkdir -p "$rdir"
printf '{}\n' >"$rdir/acme.tui@hello@0-1.running.json"
printf '{}\n' >"$rdir/acme.tui@hello@0-2.ended.json"
printf '{}\n' >"$rdir/acme.tui@other@0-3.running.json"
: >"$rdir/acme.tui@hello@0-4.lock"
: >"$rdir/acme.tui@other@0-3.lock"
plain_run "$subject" present --presentation plain "${record_opts[@]}" -- during "$rdir"
check "a recorded run exits with the command's code" test "$plain_status" == 0
check "the running record and the run lock are in place while the command runs" test "$(cat "$tmp/during")" == "$(printf '%s\n' acme.tui@hello.lock acme.tui@hello@0-2.ended.json acme.tui@hello@1-1.lock acme.tui@hello@1-1.running.json acme.tui@other@0-3.lock acme.tui@other@0-3.running.json)"
printf '%s\n' "$(cat "$tmp/during-record")" >"$tmp/during.json"
check "the running record carries the key, the run and the window" test "$(record_of "$tmp/during.json")" == "$(want_record running null)"
check "the ended record carries the command's code" test "$(record_of "$rdir/acme.tui@hello@1-1.ended.json")" == "$(want_record ended 0)"
check "the run removes its run lock and leaves its records, the key lock and another key's files alone" test "$(LC_ALL=C ls -A "$rdir")" == "$(printf '%s\n' acme.tui@hello.lock acme.tui@hello@1-1.ended.json acme.tui@hello@1-1.running.json acme.tui@other@0-3.lock acme.tui@other@0-3.running.json)"
rm -f -- "$rdir/acme.tui@other@0-3.lock"
plain_run "$subject" present --presentation plain "${record_opts[@]/1-1/1-2}" -- exits 3
check "a failed recorded run exits with its code" test "$plain_status" == 3
check "the next run removes the last run's records and keeps its own" test "$(LC_ALL=C ls -A "$rdir" | grep 'acme\.tui@hello@')" == "$(printf '%s\n' acme.tui@hello@1-2.ended.json acme.tui@hello@1-2.running.json)"
check "the next run's ended record carries its code" test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["code"])' "$rdir/acme.tui@hello@1-2.ended.json")" == 3
# A process the command leaves behind does not hold the key.
plain_run "$subject" present --presentation plain "${record_opts[@]}" -- leaver
key_free() { flock -n "$rdir/acme.tui@hello.lock" true; }
check "a process the command left behind does not hold the key" key_free
[[ -s $tmp/leaver ]] && kill "$(cat "$tmp/leaver")" 2>/dev/null
# The command holds neither the key lock nor the run lock open.
plain_run "$subject" present --presentation plain "${record_opts[@]}" -- fdlocks
check "the command inherits no lock" test "$(cat "$tmp/fdlocks")" == 0
# Another presenter of the key is refused before the logo, with no record.
exec {held}>>"$rdir/acme.tui@hello.lock"
flock "$held"
rm -f -- "$rdir"/*.json
plain_run "$subject" present "${record_opts[@]}" -- exits 0
check "a presenter of a held key exits 75" test "$plain_status" == 75
check "a presenter of a held key names it" test "$(err_first)" == "vgsh-tui: refused: record=acme.tui/hello reason=busy"
check "a presenter of a held key runs nothing and draws no logo" test "$(grep -c -e 'ran 0' -e "$logo_line" "$tmp/out")" == 0
check "a presenter of a held key writes no record" test -z "$(ls "$rdir" | grep '\.json$')"
exec {held}>&-
# A termination while the command runs ends the record with present's code.
rm -f -- "$tmp/child"
"${tui_env[@]}" "$subject" present --presentation plain "${record_opts[@]}" -- waitint 2 </dev/null >/dev/null 2>&1 &
present_pid=$!
for _ in $(seq 1 100); do [[ -s $tmp/child ]] && break; sleep 0.05; done
kill -TERM "$present_pid"
term_status=0
wait "$present_pid" || term_status=$?
check "a terminated presenter exits 143" test "$term_status" == 143
check "a terminated presenter ends its record with 143" test "$(record_of "$rdir/acme.tui@hello@1-1.ended.json")" == "$(want_record ended 143)"
rm -f -- "$rdir"/*.json

# reap: a running record whose key no presenter holds is ended with a null
# code; a held key's record stays; a record reap cannot read is refused.
printf '%s\n' '{"key":"core/doctor","run":"5-1","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@5-1.running.json"
printf '%s\n' '{"key":"acme.tui/hello","run":"6-1","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/acme.tui@hello@6-1.running.json"
exec {held}>>"$rdir/acme.tui@hello.lock"
flock "$held"
: >"$rdir/core@doctor@5-1.lock"
: >"$rdir/acme.tui@hello@6-1.lock"
plain_run "$subject" reap
check "reap exits 0" test "$plain_status" == 0
check "reap names the run it ended" test "$(cat "$tmp/out")" == "reaped=core/doctor run=5-1"
check "reap ends the dead run with a null code" test "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["state"], r["code"], r["endedAt"] is not None, r["startedAt"])' "$rdir/core@doctor@5-1.ended.json")" == "ended None True 2026-09-29T07:00:00.000Z"
check "reap removes the dead run's running record" test ! -e "$rdir/core@doctor@5-1.running.json"
check "reap removes the dead run's run lock" test ! -e "$rdir/core@doctor@5-1.lock"
check "reap leaves a held key's running record and run lock" test -e "$rdir/acme.tui@hello@6-1.running.json" -a -e "$rdir/acme.tui@hello@6-1.lock"
exec {held}>&-
rm -f -- "$rdir"/*.json "$rdir"/*@*@*.lock
# A presenter that died between its ended record and removing its running
# one: reap removes the running record and keeps the code.
printf '%s\n' '{"key":"core/doctor","run":"8-1","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@8-1.running.json"
printf '%s\n' '{"key":"core/doctor","run":"8-1","state":"ended","code":2,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":"2026-09-29T07:00:01.000Z","window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@8-1.ended.json"
: >"$rdir/core@doctor@8-1.lock"
plain_run "$subject" reap
check "reap of a run that already ended exits 0 and names nothing" test "$plain_status:$(cat "$tmp/out")" == "0:"
check "reap keeps the run's ended record and its code" test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["code"])' "$rdir/core@doctor@8-1.ended.json")" == 2
check "reap removes the ended run's running record" test ! -e "$rdir/core@doctor@8-1.running.json"
check "reap removes the ended run's run lock" test ! -e "$rdir/core@doctor@8-1.lock"
rm -f -- "$rdir"/*.json
printf '{}\n' >"$rdir/core@doctor@7-1.running.json"
plain_run "$subject" reap
check "reap exits 1 on a record it cannot end" test "$plain_status" == 1
check "reap names the record it cannot end" test "$(err_first)" == "vgsh-tui: refused: reap=$rdir/core@doctor@7-1.running.json reason=malformed"
rm -f -- "$rdir"/*.json
plain_run env XDG_RUNTIME_DIR="$tmp/rt-none" "$subject" reap
check "reap with no record directory ends nothing" test "$plain_status:$(cat "$tmp/out")" == "0:"

# launch --record: present learns the record directory, the app-id and the
# window title, and launch returns once the run's record is there, behind a
# stub terminal that records its argv and starts the command.
stubs_run="$tmp/stubs-run"; mkdir -p "$stubs_run"
printf '#!/bin/sh\n: >"%s"; for a; do printf "%%s\\n" "$a" >>"%s"; done\nwhile [ "$1" != -- ]; do shift; done; shift\n"$@" </dev/null >/dev/null 2>&1 &\n' "$tmp/term" "$tmp/term" >"$stubs_run/xdg-terminal-exec"
chmod +x "$stubs_run/xdg-terminal-exec"
rm -f -- "$tmp/term"
plain_run env PATH="$stubs_run:$stubs:$base_path" "$subject" launch --title Hello --size wide --record acme.tui/hello --run 2-1 -- exits 4
check "a recorded launch exits 0 once the record is there" test "$plain_status" == 0
check "a recorded launch hands present the record, the directory and the window" test "$(cat "$tmp/term")" == "$(lines --app-id=org.vgs.tui.wide "--title=VGS · Hello" -- "$subject" present --presentation full --record acme.tui/hello --run 2-1 --record-dir "$rdir" --app-id org.vgs.tui.wide --window-title "VGS · Hello" -- exits 4)"
for _ in $(seq 1 100); do [[ -e $rdir/acme.tui@hello@2-1.ended.json ]] && break; sleep 0.05; done
check "the launched run ends its record with the command's code" test "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["code"], r["window"]["appId"])' "$rdir/acme.tui@hello@2-1.ended.json")" == "4 org.vgs.tui.wide"
rm -f -- "$rdir"/*.json

# wait: one process blocks on the run lock and exits as soon as the
# presenter releases it. Ceiling: 1000 ms from presenter's exit to wait's
# exit. scripts/test-vgsh-tui.sh measured 0 ms on cachy x86_64 on
# 2026-09-29, from the shell's reap of the presenter to its reap of wait; 0
# means under 1 ms at date's nanosecond resolution rounded to milliseconds.
wait_opts=(--record acme.tui/hello --run 10-1 --record-dir "$rdir" --app-id org.vgs.tui --window-title "$title_words")
rm -f -- "$tmp/child" "$tmp/wait-out" "$tmp/wait-err"
"${tui_env[@]}" "$subject" present --presentation plain "${wait_opts[@]}" -- waitint 1 </dev/null >/dev/null 2>&1 &
present_pid=$!
for _ in $(seq 1 100); do [[ -e $rdir/acme.tui@hello@10-1.running.json ]] && break; sleep 0.05; done
"${tui_env[@]}" "$subject" wait --record acme.tui/hello --run 10-1 >"$tmp/wait-out" 2>"$tmp/wait-err" &
wait_pid=$!
sleep 0.1
check "wait stays blocked while the presenter holds the lock" kill -0 "$wait_pid"
present_status=0
wait "$present_pid" || present_status=$?
present_done="$(date +%s%N)"
wait_status=0
wait "$wait_pid" || wait_status=$?
wait_done="$(date +%s%N)"
wait_ms="$(python3 -c 'import sys; print((int(sys.argv[2]) - int(sys.argv[1])) // 1000000)' "$present_done" "$wait_done")"
echo "test-vgsh-tui: wait-latency-ms=$wait_ms"
check "wait exits after the presenter exits" test "$present_status:$wait_status" == "0:0"
check "wait prints the ended record once" test "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["key"], r["run"], r["state"], r["code"])' "$tmp/wait-out")" == "acme.tui/hello 10-1 ended 0"
check "wait exits within the lock-release ceiling" test "$wait_ms" -le 1000
check "no run lock is left once the run and its wait end" test ! -e "$rdir/acme.tui@hello@10-1.lock"
rm -f -- "$rdir"/*.json "$tmp/wait-out" "$tmp/wait-err"

printf '%s\n' '{"key":"core/doctor","run":"11-1","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@11-1.running.json"
: >"$rdir/core@doctor@11-1.lock"
plain_run "$subject" wait --record core/doctor --run 11-1
check "wait ends a dead presenter's run" test "$plain_status" == 0
check "wait prints the dead run's ended record" test "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["state"], r["code"], r["endedAt"] is not None, r["startedAt"])' "$tmp/out")" == "ended None True 2026-09-29T07:00:00.000Z"
check "wait removes the dead run's running record" test ! -e "$rdir/core@doctor@11-1.running.json"
check "wait removes the dead run's run lock" test ! -e "$rdir/core@doctor@11-1.lock"
rm -f -- "$rdir"/*.json
plain_run "$subject" wait --record core/doctor --run 12-1
check "wait refuses a gone run with its own code" test "$plain_status" == 3
check "wait names a gone run" test "$(err_first)" == "vgsh-tui: refused: wait=core/doctor run=12-1 reason=gone"
check "a gone run's wait leaves no run lock" test ! -e "$rdir/core@doctor@12-1.lock"

# A wait that finds only the running record reads the records again under
# the key lock: reap may end the run, or a later run of the key remove its
# records, while the wait waits for that lock. The test holds the key lock,
# waits until the wait's flock is blocked on it, polling every 0.01 s for at
# most 5 s, changes the records as each of those would, and releases the
# lock.
# recheck_under_key BIN RUN CHANGE...: sets recheck_blocked and
# recheck_status, and leaves stdout in $tmp/out.
flock_blocked() { [[ $(ps -o comm= --ppid "$1" 2>/dev/null) == flock ]]; }
recheck_under_key() {
  local bin="$1" run="$2" pid n
  shift 2
  printf '%s\n' '{"key":"core/doctor","run":"'"$run"'","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@$run.running.json"
  exec {held}>>"$rdir/core@doctor.lock"
  flock "$held"
  # The wait does not inherit the test's hold on the key lock.
  "${tui_env[@]}" "$bin" wait --record core/doctor --run "$run" >"$tmp/out" 2>"$tmp/err" {held}>&- &
  pid=$!
  for ((n = 0; n < 500; n++)); do flock_blocked "$pid" && break; sleep 0.01; done
  recheck_blocked=0
  flock_blocked "$pid" && recheck_blocked=1
  "$@"
  exec {held}>&-
  recheck_status=0
  wait "$pid" || recheck_status=$?
}
# reap_ends RUN: reap has written the run's ended record and not yet
# removed its running one.
reap_ends() {
  sed -e 's/"state":"running"/"state":"ended"/' -e 's/"endedAt":null/"endedAt":"2026-09-29T07:00:01.000Z"/' "$rdir/core@doctor@$1.running.json" >"$rdir/core@doctor@$1.ended.json"
}
later_run_removes() { rm -f -- "$rdir/core@doctor@$1.running.json"; }
recheck_under_key "$subject" 17-1 reap_ends 17-1
check "a wait blocks on the key lock for a run with only its running record" test "$recheck_blocked" == 1
check "a wait prints the record reap wrote while it waited for the key lock" test "$recheck_status:$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["run"], r["endedAt"])' "$tmp/out")" == "0:17-1 2026-09-29T07:00:01.000Z"
recheck_under_key "$subject" 17-2 later_run_removes 17-2
check "a wait whose run a later run removed while it waited for the key lock is gone" test "$recheck_status:$(err_first)" == "3:vgsh-tui: refused: wait=core/doctor run=17-2 reason=gone"
rm -f -- "$rdir"/*.json "$rdir"/*@*@*.lock

# Back to back: run A of a key ends and run B of the same key starts at
# once, with a wait for A that the shell started while A was live. hold
# FIFO runs until the test opens FIFO for writing, so A and B end when the
# test says. The wait is stopped with SIGSTOP and continued by hand, so the
# order is fixed, not raced:
#   - gone: B runs to its end, which removes A's ended record, before A's
#     wait reads. The wait exits 3, the gone code, never 1.
#   - live: B's command still runs, and holds the key lock, when A's wait
#     reads. The wait prints A's ended record within the 1000 ms ceiling
#     above.
# The shape repeats 50 times; every repetition must pass.
hold="$tmp/hold"
mkfifo -- "$hold"
stub hold 'exec cat -- "$1" >/dev/null'
b2b_opts=(--record acme.tui/b2b --record-dir "$rdir" --app-id org.vgs.tui --window-title t)
# b2b_held RUN: a presenter of acme.tui/b2b whose command holds; returns
# once the run's record is there, the point after which the shell starts a
# wait. Polls every 0.01 s for at most 5 s, a ceiling on a presenter's
# start. Sets held_pid.
b2b_held() {
  "${tui_env[@]}" "$subject" present --presentation plain "${b2b_opts[@]}" --run "$1" -- hold "$hold" </dev/null >/dev/null 2>&1 &
  held_pid=$!
  for _ in $(seq 1 500); do [[ -e $rdir/acme.tui@b2b@$1.running.json ]] && return 0; sleep 0.01; done
  return 1
}
# b2b_release: ends the held command and waits for its presenter. The
# write end opens once the command has opened the FIFO; the timeout ends a
# release no command ever reads.
b2b_release() { timeout 10 "$BASH" -c ': >"$1"' _ "$hold" || :; wait "$held_pid" || :; }
# b2b_waiter BIN RUN: a stopped `BIN wait` for RUN. Sets waiter_pid.
b2b_waiter() {
  "${tui_env[@]}" "$1" wait --record acme.tui/b2b --run "$2" >"$tmp/b2b-out" 2>"$tmp/b2b-err" &
  waiter_pid=$!
  kill -STOP "$waiter_pid"
}
# b2b_gone BIN A B: the gone shape. Sets b2b_result to the wait's exit
# status and first stderr line.
b2b_gone() {
  local status=0 line=""
  b2b_held "$2" || { b2b_result="presenter $2 never started"; return 0; }
  b2b_waiter "$1" "$2"
  b2b_release
  "${tui_env[@]}" "$subject" present --presentation plain "${b2b_opts[@]}" --run "$3" -- true </dev/null >/dev/null 2>&1 || :
  kill -CONT "$waiter_pid"
  wait "$waiter_pid" || status=$?
  [[ -s $tmp/b2b-err ]] && IFS= read -r line <"$tmp/b2b-err"
  b2b_result="$status|$line|$(cat "$tmp/b2b-out")"
}
# b2b_live BIN A B: the live shape. Sets b2b_result to the wait's exit
# status and the run and state of the record it printed, or `blocked` when
# the wait had not exited within the ceiling while B ran.
b2b_live() {
  local status=0 n
  b2b_held "$2" || { b2b_result="presenter $2 never started"; return 0; }
  b2b_waiter "$1" "$2"
  b2b_release
  b2b_held "$3" || { kill -CONT "$waiter_pid"; b2b_result="presenter $3 never started"; return 0; }
  kill -CONT "$waiter_pid"
  for ((n = 0; n < 100; n++)); do kill -0 "$waiter_pid" 2>/dev/null || break; sleep 0.01; done
  if kill -0 "$waiter_pid" 2>/dev/null; then
    b2b_result=blocked
    b2b_release
    wait "$waiter_pid" || :
    return 0
  fi
  wait "$waiter_pid" || status=$?
  b2b_result="$status|$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["run"], r["state"])' "$tmp/b2b-out" 2>/dev/null)"
  b2b_release
}
b2b_passes=0 b2b_first=""
for ((i = 100; i < 150; i++)); do
  b2b_gone "$subject" "$i-1" "$i-2"
  gone="$b2b_result"
  b2b_live "$subject" "$i-3" "$i-4"
  live="$b2b_result"
  if [[ $gone == "3|vgsh-tui: refused: wait=acme.tui/b2b run=$i-1 reason=gone|" && $live == "0|$i-3 ended" ]]; then
    b2b_passes=$((b2b_passes + 1))
  elif [[ -z $b2b_first ]]; then
    b2b_first="run $i: gone=[$gone] live=[$live]"
  fi
done
echo "test-vgsh-tui: back-to-back=$b2b_passes/50${b2b_first:+ first-failure=$b2b_first}"
check "the back-to-back wait passes 50 times in a row" test "$b2b_passes" == 50
check "back-to-back runs leave no run lock" test -z "$(ls "$rdir" | grep '^acme\.tui@b2b@.*\.lock$')"
rm -f -- "$rdir"/acme.tui@b2b*

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
  "2|vgsh-tui: refused: run=missing record=acme.tui/hello|$subject launch --title t --record acme.tui/hello -- exits 0"
  "2|vgsh-tui: refused: record=missing run=1-1|$subject launch --title t --run 1-1 -- exits 0"
  "2|vgsh-tui: refused: record=Acme.tui/x|$subject launch --title t --record Acme.tui/x --run 1 -- exits 0"
  "2|vgsh-tui: refused: record=acme.tui/a/b|$subject launch --title t --record acme.tui/a/b --run 1 -- exits 0"
  "2|vgsh-tui: refused: record=acme.tui|$subject launch --title t --record acme.tui --run 1 -- exits 0"
  "2|vgsh-tui: refused: run=1_1|$subject launch --title t --record a/b --run 1_1 -- exits 0"
  "2|vgsh-tui: refused: argument=--record-dir|$subject launch --title t --record-dir /x -- exits 0"
  "2|vgsh-tui: refused: argument=--app-id|$subject launch --title t --app-id org.vgs.tui -- exits 0"
  "2|vgsh-tui: refused: argument=--window-title|$subject launch --title t --window-title t -- exits 0"
  "2|vgsh-tui: refused: record=missing|$subject present --app-id org.vgs.tui -- exits 0"
  "2|vgsh-tui: refused: record-dir=missing|$subject present --record a/b --run 1 -- exits 0"
  "2|vgsh-tui: refused: record-dir=rel|$subject present --record a/b --run 1 --record-dir rel -- exits 0"
  "2|vgsh-tui: refused: app-id=missing|$subject present --record a/b --run 1 --record-dir /x -- exits 0"
  "2|vgsh-tui: refused: app-id=org/vgs|$subject present --record a/b --run 1 --record-dir /x --app-id org/vgs -- exits 0"
  "2|vgsh-tui: refused: window-title=missing-or-control|$subject present --record a/b --run 1 --record-dir /x --app-id org.vgs.tui -- exits 0"
  "2|vgsh-tui: refused: argument=x|$subject reap x"
  "2|vgsh-tui: refused: record=missing|$subject wait --run 1-1"
  "2|vgsh-tui: refused: run=missing record=a/b|$subject wait --record a/b"
  "2|vgsh-tui: refused: argument=x|$subject wait --record a/b --run 1-1 x"
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

# The prompt is the library's: this control's tree holds a copy of bin/lib
# rather than the link tui_tree makes, so the mutant never reaches the
# tracked file.
control_lib() { # NAME NEEDLE REPLACEMENT
  local dir="$tmp/control-$1"
  tui_tree "$dir" "$repo/shell"
  rm -- "$dir/bin/lib"
  cp -R -- "$repo/bin/lib" "$dir/bin/lib"
  check "the $1 control's text occurs once in lib/tui.sh" \
    python3 -c 'import sys; sys.exit(0 if open(sys.argv[1]).read().count(sys.argv[2]) == 1 else 1)' "$repo/bin/lib/tui.sh" "$2"
  python3 -c 'import sys; p, o, a, b = sys.argv[1:]; open(o, "w").write(open(p).read().replace(a, b))' "$repo/bin/lib/tui.sh" "$dir/bin/lib/tui.sh" "$2" "$3"
  check "the $1 mutant differs" test "$(cmp -s "$repo/bin/lib/tui.sh" "$dir/bin/lib/tui.sh"; echo $?)" == 1
  control_bin="$dir/bin/vgsh-tui"
}
control_lib stdout-prompt '"$(vgs_tui_sgr "${VGS_TUI_DANGER:-}" 31)" "$code" >/dev/tty' '"$(vgs_tui_sgr "${VGS_TUI_DANGER:-}" 31)" "$code"'
prompt_on_tty "$control_bin"
check "the stdout-prompt mutant keeps the prompt off the terminal" test "$(grep -c 'Failed (' "$tmp/out")" == 0
check "the stdout-prompt mutant writes the prompt to stdout" grep -q 'Failed (exit code 1)' "$tmp/stdout"

control shell-string vgsh-tui 'else "${argv[@]}"; fi' 'else bash -c "${argv[*]}"; fi'
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

control tui-only-copy vgsh-tui 'cp -R -- "$plugin_dir/." "$copy_dir/"' 'cp -R -- "$plugin_dir/tui" "$copy_dir/tui"'
plugin_snapshot
on_tty "$control_bin" present --plugin acme.tui --dir "$snap" -- tui/run.sh
check "the tui-only-copy mutant loses the snapshot's root file" test "$(grep -c root-data-sourced "$tmp/out")" == 0

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

control runner-marker vgsh-tui $'  unset VGSH_RUNNER_PID\n' ''
rm -f -- "$tmp/term-env"
plain_run env VGSH_RUNNER_PID=4242 "$control_bin" launch --title t -- exits 0
check "the runner-marker mutant hands the terminal the shell's marker" test "$(cat "$tmp/term-env" 2>/dev/null)" == 4242

control unchecked-terminal vgsh-tui 'bad_invocation "argument=$1"; require_terminal ;;' 'bad_invocation "argument=$1"; : ;;'
plain_run env PATH="$bare" "$control_bin" check
check "the unchecked-terminal mutant answers check without a terminal launcher" test "$plain_status" == 0

# A launcher whose terminal never starts the presenter reports it silent,
# on a copy with a one-second ceiling behind the stub terminal that starts
# nothing; the no-wait mutant returns at once with no record.
control short-ceiling vgsh-tui 'start_ceiling=30' 'start_ceiling=1'
plain_run "$control_bin" launch --title t --record acme.tui/hello --run 3-1 -- exits 0
check "a launch whose presenter never writes exits 1" test "$plain_status" == 1
check "a launch whose presenter never writes names the terminal silent" test "$(err_first)" == "vgsh-tui: refused: terminal=silent run=3-1"
control no-wait vgsh-tui '  [[ -z $record_key ]] || await_record' '  :'
plain_run "$control_bin" launch --title t --record acme.tui/hello --run 3-1 -- exits 0
check "the no-wait mutant returns 0 with no record" test "$plain_status:$(ls "$rdir" | grep -c '3-1')" == "0:0"
control unended-record vgsh-tui '  if [[ $record_active == 1 ]]; then record_end "${ran_code:-$status}"; fi' '  :'
plain_run "$control_bin" present --presentation plain "${record_opts[@]}" -- exits 0
check "the unended-record mutant leaves no ended record" test ! -e "$rdir/acme.tui@hello@1-1.ended.json"
rm -f -- "$rdir"/*.json
control inherited-lock vgsh-tui 'then "${argv[@]}" {record_fd}>&- {run_fd}>&-; else' 'then "${argv[@]}" {run_fd}>&-; else'
plain_run "$control_bin" present --presentation plain "${record_opts[@]}" -- leaver
check "the inherited-lock mutant leaves the key held by the process left behind" test "$(key_free && echo free || echo held)" == held
[[ -s $tmp/leaver ]] && kill "$(cat "$tmp/leaver")" 2>/dev/null
rm -f -- "$rdir"/*.json
control inherited-run-lock vgsh-tui 'then "${argv[@]}" {record_fd}>&- {run_fd}>&-; else' 'then "${argv[@]}" {record_fd}>&-; else'
plain_run "$control_bin" present --presentation plain "${record_opts[@]}" -- fdlocks
check "the inherited-run-lock mutant hands the command the run lock" test "$(cat "$tmp/fdlocks")" == 1
rm -f -- "$rdir"/*.json
control kept-run-lock vgsh-tui '  [[ -z $run_lock ]] || rm -f -- "$run_lock"' '  :'
plain_run "$control_bin" present --presentation plain "${record_opts[@]}" -- exits 0
check "the kept-run-lock mutant leaves the run lock's name" test -e "$rdir/acme.tui@hello@1-1.lock"
rm -f -- "$rdir"/*.json "$rdir"/*@*@*.lock
control unlocked vgsh-tui 'flock -n -E 75 "$record_fd" || status=$?' ':'
exec {held}>>"$rdir/acme.tui@hello.lock"
flock "$held"
plain_run "$control_bin" present --presentation plain "${record_opts[@]}" -- exits 0
check "the unlocked mutant runs a second presenter of a held key" test "$plain_status" == 0
exec {held}>&-
rm -f -- "$rdir"/*.json
control stale-kept vgsh-tui '    if [[ -e $stale ]]; then rm -f -- "$stale"; fi' '    :'
printf '{}\n' >"$rdir/acme.tui@hello@0-1.running.json"
: >"$rdir/acme.tui@hello@0-4.lock"
plain_run "$control_bin" present --presentation plain "${record_opts[@]}" -- exits 0
check "the stale-kept mutant keeps a dead presenter's running record" test -e "$rdir/acme.tui@hello@0-1.running.json"
check "the stale-kept mutant keeps an earlier run's lock" test -e "$rdir/acme.tui@hello@0-4.lock"
rm -f -- "$rdir"/*.json "$rdir"/*@*@*.lock
control reap-held vgsh-tui '      75) continue ;;' '      75) ;;'
printf '%s\n' '{"key":"acme.tui/hello","run":"6-1","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/acme.tui@hello@6-1.running.json"
exec {held}>>"$rdir/acme.tui@hello.lock"
flock "$held"
plain_run "$control_bin" reap
check "the reap-held mutant ends a live presenter's record" test -e "$rdir/acme.tui@hello@6-1.ended.json"
exec {held}>&-
rm -f -- "$rdir"/*.json
control reap-ended vgsh-tui '    if [[ -e $record_dir/$stem@$run.ended.json ]]; then' '    if false; then'
printf '%s\n' '{"key":"core/doctor","run":"8-1","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@8-1.running.json"
printf '%s\n' '{"key":"core/doctor","run":"8-1","state":"ended","code":2,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":"2026-09-29T07:00:01.000Z","window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@8-1.ended.json"
plain_run "$control_bin" reap
check "the reap-ended mutant replaces a run's code with null" test "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["code"])' "$rdir/core@doctor@8-1.ended.json")" == None
rm -f -- "$rdir"/*.json
control wait-unlocked vgsh-tui '  flock "$run_fd" || {' '  : || {'
printf '%s\n' '{"key":"core/doctor","run":"13-1","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@13-1.running.json"
exec {held}>>"$rdir/core@doctor@13-1.lock"
flock "$held"
plain_run "$control_bin" wait --record core/doctor --run 13-1
check "the wait-unlocked mutant returns before the presenter releases the run lock" test "$plain_status" == 0
check "the wait-unlocked mutant ends a live presenter's record" test -e "$rdir/core@doctor@13-1.ended.json"
exec {held}>&-
rm -f -- "$rdir"/*.json "$rdir"/*@*@*.lock
control wait-dead-run vgsh-tui '      end_running_record "$file" "$stem" "$record_run" "wait=$record_key run=$record_run" || status=$?' '      return 1'
printf '%s\n' '{"key":"core/doctor","run":"14-1","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@14-1.running.json"
plain_run "$control_bin" wait --record core/doctor --run 14-1
check "the wait-dead-run mutant does not end a dead presenter" test "$plain_status" == 1
check "the wait-dead-run mutant writes no ended record" test ! -e "$rdir/core@doctor@14-1.ended.json"
rm -f -- "$rdir"/*.json "$rdir"/*@*@*.lock
control wait-no-recheck vgsh-tui $'    if [[ ! -e $ended && -e $file ]]; then\n      end_running_record' $'    if true; then\n      end_running_record'
recheck_under_key "$control_bin" 18-1 reap_ends 18-1
check "the wait-no-recheck mutant writes over the ended record reap wrote" test "$recheck_status:$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["endedAt"])' "$tmp/out")" != "0:2026-09-29T07:00:01.000Z"
rm -f -- "$rdir"/*.json "$rdir"/*@*@*.lock
control wait-kept-lock vgsh-tui $'  rm -f -- "$lock"\n' $'  :\n'
plain_run "$control_bin" wait --record core/doctor --run 15-1
check "the wait-kept-lock mutant leaves the run lock's name" test -e "$rdir/core@doctor@15-1.lock"
rm -f -- "$rdir"/*@*@*.lock
control reap-kept-lock vgsh-tui $'    rm -f -- "$record_dir/$stem@$run.lock"\n    printf \'reaped=' $'    :\n    printf \'reaped='
printf '%s\n' '{"key":"core/doctor","run":"16-1","state":"running","code":null,"startedAt":"2026-09-29T07:00:00.000Z","endedAt":null,"window":{"appId":"org.vgs.tui","title":"t"}}' >"$rdir/core@doctor@16-1.running.json"
: >"$rdir/core@doctor@16-1.lock"
plain_run "$control_bin" reap
check "the reap-kept-lock mutant leaves a reaped run's lock" test -e "$rdir/core@doctor@16-1.lock"
rm -f -- "$rdir"/*.json "$rdir"/*@*@*.lock
# Key-only matching: a wait that blocks on the key lock, as before run
# locks, stays blocked while a later run of the key holds it.
control wait-key-lock vgsh-tui '  lock="$record_dir/$stem@$record_run.lock"' '  lock="$record_dir/$stem.lock"'
b2b_live "$control_bin" 200-1 200-2
check "the wait-key-lock mutant stays blocked past the ceiling while a later run holds the key" test "$b2b_result" == blocked
rm -f -- "$rdir"/acme.tui@b2b*
# A gone run that exits 1, the code of every other refusal, is the failure
# the shell logged before.
control wait-gone-failed vgsh-tui 'wait_gone=3' 'wait_gone=1'
b2b_gone "$control_bin" 201-1 201-2
check "the wait-gone-failed mutant exits 1 for a run a later run removed" test "${b2b_result%%|*}" == 1
rm -f -- "$rdir"/acme.tui@b2b*
rows_done test-vgsh-tui
