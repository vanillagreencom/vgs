# Control: a bare qs beside the runner must refuse to draw and to write,
# and the runner's CLI must keep addressing the guarded instance.
set -euo pipefail
spawn "$sandbox/bare.log" "${shell_env[@]}" qs -p "$repo/shell"
bare_pid="$spawn_pid"
instance_count() { "${shell_env[@]}" qs list -p "$repo/shell" -j 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
bare_ipc() { "${shell_env[@]}" qs ipc --pid "$bare_pid" call "$@" 2>/dev/null | tail -n 1; }
bare_guarded=""
for _ in $(seq 1 100); do
  # Wait until the bare instance is registered, then address it by pid.
  if instances="$(instance_count)" && [[ $instances == 2 ]] && bare_guarded="$(bare_ipc shell guarded)" && [[ $bare_guarded == true || $bare_guarded == false ]]; then break; fi
  sleep 0.2
done
if [[ $bare_guarded == false ]]; then ok "a bare qs beside the runner refuses to draw"; else fail "bare qs guarded=$bare_guarded"; fi
sleep 0.5
if bars_after="$(bar_count)" && [[ $bars_after == "$bars" ]]; then ok "the bare qs mapped no bar surface"; else fail "bar surfaces after bare qs: ${bars_after:-unreadable}"; fi
user_before="$(cat "$home/.config/vgs/shell.json")"
expect "the bare qs refuses to write configuration" "refused: guard=unowned pid=$bare_pid" bare_ipc shell setPluginEnabled acme.tick false
expect "the bare qs refuses to reload configuration" "refused: guard=unowned pid=$bare_pid" bare_ipc shell reloadConfig
expect "the bare qs refuses to rescan" "refused: guard=unowned pid=$bare_pid" bare_ipc shell rescanPlugins
expect "the bare qs refuses to summon" "refused: guard=unowned pid=$bare_pid" bare_ipc shell summon panel acme.probe '{}'
if [[ "$(cat "$home/.config/vgs/shell.json")" == "$user_before" ]]; then ok "the refused write left the user file alone"; else fail "the bare qs changed the user file"; fi
expect "the runner's CLI still reaches the guarded instance beside a bare one" true ipc shell guarded
kill -TERM "$bare_pid" 2>/dev/null || true
