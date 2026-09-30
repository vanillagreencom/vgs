# No row authenticates against the host user. The nested sandbox shares the
# host's PAM, polkit and faillock, so a sudo, a polkit authentication, a
# keyring unlock or a failed password a row caused would count against the
# owner's own account. harness.sh stands a sentinel for every command that
# asks for one in the PATH directory every sandbox shell starts with, and
# replaces the sandbox tree's bin/vgsh-browser-policy, which runs sudo from
# the system directories alone, and every bundled plugin's TUI script in
# the sandbox tree with more. This row, the last, reads that each sentinel
# resolves first on that PATH, or a stub a row stood over it that never
# authenticates, that the tree's writer and TUI scripts are still
# sentinels, that the stand-in terminal ran no plugin script but a smoke
# fixture or a row's registered stand-in, and that no sentinel was called
# during the run. Its controls: a call through a sentinel and a run of a
# tree TUI script after that reading are each logged, so an empty log is a
# run that called none, not a sentinel that logs nothing; and the stand-in
# terminal, asked for a script that is no fixture, refuses it and runs
# nothing, while the same script registered as a row's stand-in runs, so
# the refusal is the gate's and not a script that could not run.
set -euo pipefail
for name in "${auth_sentinels[@]}"; do
  expect "$name resolves to the sandbox's own stand-in on every shell's PATH" "$shim/$name" shell_resolves "$name"
done
tree_writer() { if grep -q -F -- "$auth_log" "$repo/bin/vgsh-browser-policy"; then echo sentinel; else echo real; fi; }
expect "the sandbox tree's browser-policy writer is the sentinel" sentinel tree_writer
tree_tui_scripts() {
  local n=0 file
  while IFS= read -r file; do
    grep -q -F -- "$auth_log" "$file" || { echo "real: $file"; return; }
    n=$((n + 1))
  done <"$tree_tui_sentinels"
  echo "$n sentinels"
}
expect "every bundled plugin's TUI script in the sandbox tree is a sentinel" "$(wc -l <"$tree_tui_sentinels") sentinels" tree_tui_scripts
# The kinds the stand-in terminal ran, each fixture line checked against
# the checkout's fixtures by name: the lines that fail, and the kinds that
# ran, as one JSON object.
tui_ran_kinds() { python3 -c 'import json, os, sys
fixtures, path = sys.argv[1], sys.argv[2]
bad, kinds = [], set()
for line in (open(path).read().split("\n")[:-1] if os.path.exists(path) else []):
    kind, plugin, rel = line.split(" ")[:3]
    kinds.add(kind)
    if kind == "fixture" and not os.path.isfile(os.path.join(fixtures, plugin, rel)): bad.append(line)
    if kind not in ("fixture", "stand-in", "refused"): bad.append(line)
print(json.dumps({"bad": bad, "ran": sorted(kinds - {"refused"})}))' "$tui_fixtures" "$tui_log"; }
expect "the stand-in terminal ran only smoke fixtures and rows' stand-ins, and refused the rest" '{"bad": [], "ran": ["fixture", "stand-in"]}' tui_ran_kinds
auth_calls() { if [[ -e $auth_log ]]; then cat -- "$auth_log"; fi; }
expect "no row reached sudo, doas, run0, pkexec, su, a mutating loginctl or secret-tool, the privileged writer or a bundled TUI script" "" auth_calls
auth_count() { if [[ -e $auth_log ]]; then wc -l <"$auth_log"; else echo 0; fi; }
auth_before="$(auth_count)"
expect "the control's sudo through the shell's PATH runs nothing" 1 bash -c 'PATH="$1" sudo -n true; echo $?' _ "$shell_start_path"
expect "the control's sudo is logged" "$((auth_before + 1))" auth_count
expect "the control's call is the one logged" "sudo -n true" tail -n 1 -- "$auth_log"

first_tree_tui="$(head -n 1 -- "$tree_tui_sentinels")"
expect "the control's run of a tree TUI script runs nothing" 1 bash -c '"$1" control; echo $?' _ "$first_tree_tui"
expect "the control's run is logged" "$((auth_before + 2))" auth_count
tree_tui_logged() { tail -n 1 -- "$auth_log" | cut -d ' ' -f 1,3; }
expect "the control's run is the one logged" "tui-script control" tree_tui_logged

# The gate's control: a plugin script that is no fixture, handed to the
# stand-in terminal as the core hands one, marks a file if it runs.
gate_dir="$sandbox/gate-control"
gate_mark="$sandbox/gate-control.ran"
mkdir -p -- "$gate_dir/tui"
printf '#!/bin/sh\n: >%q\n' "$gate_mark" >"$gate_dir/tui/leak.sh"
chmod 755 "$gate_dir/tui/leak.sh"
gate_run() {
  "${shell_env[@]}" "${shell_start_words[@]}" "$shim/xdg-terminal-exec" --app-id=org.vgs.tui "--title=Gate control" -- \
    "$tui_self" present --presentation plain --plugin vgs.gate-control --dir "$gate_dir" -- tui/leak.sh one
  if [[ -e $gate_mark ]]; then echo ran; else echo "not run"; fi
}
expect "the stand-in terminal runs no plugin script that is no fixture" "not run" gate_run
expect "it logs the request refused, with its arguments" '["refused", "one"]' tui_decision vgs.gate-control tui/leak.sh
tui_script_stand_in vgs.gate-control tui/leak.sh <"$gate_dir/tui/leak.sh"
expect "the same script registered as a row's stand-in runs" ran gate_run
expect "it logs the request as the stand-in's" '["stand-in", "one"]' tui_decision vgs.gate-control tui/leak.sh
tui_script_forget vgs.gate-control tui/leak.sh
