# No row authenticates against the host user. The nested sandbox shares the
# host's PAM, polkit and faillock, so a sudo, a polkit authentication, a
# keyring unlock or a failed password a row caused would count against the
# owner's own account. harness.sh stands a sentinel for every command that
# asks for one in the PATH directory every sandbox shell starts with, and
# replaces the sandbox tree's bin/vgsh-browser-policy, which runs sudo from
# the system directories alone, with one more. This row, the last, reads
# that each sentinel resolves first on that PATH, or a stub a row stood
# over it that never authenticates, that the tree's writer is still the
# sentinel, and that no sentinel was called during the run. Its control:
# a call through a sentinel after that reading is logged, so an empty log
# is a run that called none, not a sentinel that logs nothing.
set -euo pipefail
for name in "${auth_sentinels[@]}"; do
  expect "$name resolves to the sandbox's own stand-in on every shell's PATH" "$shim/$name" shell_resolves "$name"
done
tree_writer() { if grep -q -F -- "$auth_log" "$repo/bin/vgsh-browser-policy"; then echo sentinel; else echo real; fi; }
expect "the sandbox tree's browser-policy writer is the sentinel" sentinel tree_writer
auth_calls() { if [[ -e $auth_log ]]; then cat -- "$auth_log"; fi; }
expect "no row reached sudo, doas, run0, pkexec, su, a mutating loginctl or secret-tool, or the privileged writer" "" auth_calls
auth_count() { if [[ -e $auth_log ]]; then wc -l <"$auth_log"; else echo 0; fi; }
auth_before="$(auth_count)"
expect "the control's sudo through the shell's PATH runs nothing" 1 bash -c 'PATH="$1" sudo -n true; echo $?' _ "$shell_start_path"
expect "the control's sudo is logged" "$((auth_before + 1))" auth_count
expect "the control's call is the one logged" "sudo -n true" tail -n 1 -- "$auth_log"
