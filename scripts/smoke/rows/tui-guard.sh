# The stand-in terminal's rule (terminal_stand_in in harness.sh): it runs
# no plugin script but a fixture's, so no row reaches a script that could
# change the host. Runs after every row that opens a TUI, before
# rows/auth-sentinel.sh. It reads that the stand-in on the shell's PATH is
# the text terminal_stand_in last wrote, that the frozen fixture index
# still matches the tree's fixtures and cannot be written, and that every
# script the stand-in refused during the run is one a shipped plugin
# declares: a refusal of anything else is a row that pointed the stand-in
# at a script that is neither a fixture nor a shipped TUI. The controls
# call the stand-in with the argv the real launcher hands it: an exact copy
# of acme.tui's wait.sh runs and ends with its code, while a planted
# script, a changed copy of wait.sh, the copy under another plugin's id
# and a path that leaves tui/ each run nothing, end with code 0 and add one
# refusal line each. A planted refusal log naming a made-up script fails
# the shipped-script reading once.
set -euo pipefail
guard_dir="$sandbox/tui-guard"
guard_records="$sandbox/tui-guard-records"
guard_marker="$sandbox/tui-guard-marker"
guard_open="$sandbox/tui-guard-open"
mkdir -p -- "$guard_dir" "$guard_records"
: >"$guard_open"
# Classes are spelled out, since a range follows the locale.
guard_name='[0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ]'

# The stand-in itself: no row wrote its own terminal, and the shell finds
# this one first.
same_stand_in() { if cmp -s -- "$tui_terminal" "$tui_terminal_written"; then echo same; else echo differs; fi; }
expect "the stand-in terminal is the text terminal_stand_in last wrote" same same_stand_in
expect "the terminal command resolves to the stand-in on the shell's PATH" "$tui_terminal" shell_resolves "${tui_terminal##*/}"
held() { if [[ -e $sandbox/run-hold ]]; then echo held; else echo released; fi; }
expect "no row left its runs held" released held

# The fixture index: the tree's fixtures as the harness froze them.
rm -rf -- "${guard_dir:?}/fresh"
if tui_fixtures_assemble "$source_repo" "$guard_dir/fresh"; then
  expect "the fixture index holds the tree's fixtures, byte for byte" "" diff -r -- "$guard_dir/fresh" "$tui_fixtures"
else
  fail "the tree's fixtures could not be assembled again"
fi
expect "no file or directory of the fixture index is writable" "" find "$tui_fixtures" -perm /222 -print

# refusals_shipped LABEL LOG: every line of LOG, `<key> <plugin id>
# <script>`, names a script under that shipped plugin's tui/. Prints each
# refused line and fails once per line that names anything else.
refusals_shipped() { # LABEL LOG
  local label="$1" log="$2" key id script bad=0
  if [[ ! -f $log || ! -r $log ]]; then fail "$label: $log is unreadable"; return 0; fi
  while read -r key id script; do
    if [[ $id =~ ^$guard_name($guard_name|[._-])*$ && $script =~ ^tui/$guard_name($guard_name|[._-])*$ &&
      -f $source_repo/shell/plugins/$id/$script ]]; then
      printf '        refused %s %s %s\n' "$key" "$id" "$script"
    else
      fail "$label: the refusal [$key $id $script] names no shipped plugin's TUI script"
      bad=1
    fi
  done <"$log"
  if [[ $bad == 0 ]]; then ok "$label"; fi
}
refusals_shipped "every script the stand-in refused during the run is a shipped plugin's TUI" "$tui_refused"

# guard_run KEY ID DIR SCRIPT ARGS...: the stand-in handed the argv the
# launcher hands it for SCRIPT of plugin ID from the snapshot DIR, then the
# code of the run's ended record, or absent. The stand-in's own status is
# its window's, not the run's.
guard_run() { # KEY ID DIR SCRIPT ARGS...
  local key="$1" id="$2" dir="$3"
  shift 3
  "${shell_env[@]}" "$tui_terminal" --app-id=org.vgs.tui "--title=VGS · Guard" -- \
    "$tui_self" present --presentation plain --plugin "$id" --dir "$dir" --record "$key" --run guard \
    --record-dir "$guard_records" --app-id org.vgs.tui --window-title "VGS · Guard" -- "$@" || true
  python3 -c 'import json, os, sys
path = sys.argv[1]
print(json.load(open(path)).get("code") if os.path.exists(path) else "absent")' "$guard_records/${key/\//@}@guard.ended.json"
}
marker_state() { if [[ -e $guard_marker ]]; then echo present; else echo absent; fi; }
wait_fixture="$source_repo/scripts/smoke/fixtures/plugins/acme.tui/tui/wait.sh"
mkdir -p -- "$guard_dir/exact/tui" "$guard_dir/probe/tui" "$guard_dir/altered/tui"
cp -- "$wait_fixture" "$guard_dir/exact/tui/wait.sh"
printf '#!/bin/sh\ntouch "$1"\n' >"$guard_dir/probe/tui/probe.sh"
{ head -n 1 -- "$wait_fixture"; printf 'touch %q\n' "$guard_marker"; tail -n +2 -- "$wait_fixture"; } >"$guard_dir/altered/tui/wait.sh"
chmod 755 "$guard_dir/exact/tui/wait.sh" "$guard_dir/probe/tui/probe.sh" "$guard_dir/altered/tui/wait.sh"
rm -f -- "${guard_marker:?}"
refused_before="$(wc -l <"$tui_refused")"

expect "an exact copy of a fixture runs and ends with its code" 7 guard_run acme.tui/guard-exact acme.tui "$guard_dir/exact" tui/wait.sh "$guard_open" 7
expect "a planted script runs nothing and its run ends with 0" 0 guard_run acme.tui/guard-probe acme.tui "$guard_dir/probe" tui/probe.sh "$guard_marker"
expect "the planted script left no marker" absent marker_state
expect "a changed copy of a fixture runs nothing and its run ends with 0" 0 guard_run acme.tui/guard-altered acme.tui "$guard_dir/altered" tui/wait.sh "$guard_open" 7
expect "the changed copy left no marker" absent marker_state
expect "a fixture's copy under another plugin's id runs nothing" 0 guard_run acme.status/guard-other-id acme.status "$guard_dir/exact" tui/wait.sh "$guard_open" 7
expect "a path that leaves tui/ runs nothing" 0 guard_run acme.tui/guard-escape acme.tui "$guard_dir/exact" tui/../tui/wait.sh "$guard_open" 7
guard_new_refusals() { tail -n "+$((refused_before + 1))" -- "$tui_refused"; }
expect "the refusal log holds one line per refused control, the exact copy none" \
  "$(printf '%s\n' 'acme.tui/guard-probe acme.tui tui/probe.sh' 'acme.tui/guard-altered acme.tui tui/wait.sh' \
    'acme.status/guard-other-id acme.status tui/wait.sh' 'acme.tui/guard-escape acme.tui tui/../tui/wait.sh')" guard_new_refusals

# Control for refusals_shipped: a log naming a made-up script fails once,
# and a log of shipped scripts fails nothing. Each runs in a subshell whose
# failure count is its answer.
printf '%s\n' 'acme.made-up/nothing acme.made-up tui/nothing.sh' >"$guard_dir/unshipped.calls"
printf '%s\n' 'vgs.themes/browser-policy vgs.themes tui/browser-policy.sh' 'vgs.updates/update vgs.updates tui/update.sh' >"$guard_dir/shipped.calls"
refusals_failures() { (failures=0 behaviour_failures=0; refusals_shipped "the planted log" "$1" >"$guard_dir/control.log"; echo "$failures"); }
expect "a refusal of a script no shipped plugin holds fails once" 1 refusals_failures "$guard_dir/unshipped.calls"
expect "the failure names the refused line" 1 grep -c -F -- "[acme.made-up/nothing acme.made-up tui/nothing.sh]" "$guard_dir/control.log"
expect "refusals of shipped scripts fail nothing" 0 refusals_failures "$guard_dir/shipped.calls"
forget_record
