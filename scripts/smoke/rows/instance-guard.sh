# Control: a bare qs beside the runner must refuse to draw, to write and to
# follow the applied theme package, and the runner's CLI must keep
# addressing the guarded instance.
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

# A follow writes the theme and application files, so an unguarded
# instance never follows. The runner applies a package and the package
# changes before an unguarded instance starts, so the scan it runs at start
# meets a due follow; the theme file keeps the bytes the apply wrote. The
# control starts from the same state: a copy of the shell whose follow is
# not gated on the guard follows the changed package. The copy's bin,
# config, themes and scripts are the sandbox's own.
theme_file="$home/.config/vgs/theme.json"
guard_pkg="$home/.config/vgs/themes/guardfollow"
guard_doc() { printf '{ "schemaVersion": 1, "name": "guardfollow", "tokens": { "palette": { "accent": "%s" } } }\n' "$1" >"$guard_pkg/theme.json"; }
same_bytes() { cmp -s -- "$1" "$2" && echo same || echo differ; }
scanned_at() { "${shell_env[@]}" qs ipc --pid "$1" call shell listPlugins 2>/dev/null | tail -n 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["scanned"])'; }
# Start a qs on SHELL_DIR, logging to LOG, set unguarded_pid, and pass the
# row NAME once it answers that it is unguarded.
start_unguarded() { # LOG SHELL_DIR NAME
  local answer=""
  spawn "$1" "${shell_env[@]}" qs -p "$2"
  unguarded_pid="$spawn_pid"
  for _ in $(seq 1 100); do
    answer="$("${shell_env[@]}" qs ipc --pid "$unguarded_pid" call shell guarded 2>/dev/null | tail -n 1)" && [[ $answer == false ]] && { ok "$3"; return; }
    sleep 0.2
  done
  fail "$3: guarded=$answer"
}
mkdir -p -- "$guard_pkg"; guard_doc '#12ab38'
expect "no theme job runs before the follow guard rows" idle theme_idle
expect "the runner applies a package for the follow guard" "ok theme=guardfollow state=applied shell=applied" "${shell_env[@]}" "$repo/bin/vgsh" theme apply guardfollow
cp -- "$theme_file" "$sandbox/guard-applied.json"
guard_doc '#12ab39'
start_unguarded "$sandbox/bare-follow.log" "$repo/shell" "a bare qs started over a due follow is unguarded"
expect_poll "the bare qs's scan completes" True scanned_at "$unguarded_pid"
# A follow's judge run takes well under a second; two seconds leave one the
# scan queued time to write.
sleep 2
expect "the bare qs follows no changed package" same same_bytes "$sandbox/guard-applied.json" "$theme_file"
kill -TERM "$unguarded_pid" 2>/dev/null || true

guard_mutant="$sandbox/guard-mutant"; mkdir -p -- "$guard_mutant"
cp -R -- "$repo/shell" "$guard_mutant/shell"
for dir in bin config themes scripts; do ln -s -- "$repo/$dir" "$guard_mutant/$dir"; done
gate='        target: root.guarded ? Registry : null'
if [[ $(grep -c -F -- "$gate" "$guard_mutant/shell/shell.qml") == 1 ]]; then
  python3 -c 'import sys; p, a, b = sys.argv[1:]; s = open(p).read(); open(p, "w").write(s.replace(a, b))' "$guard_mutant/shell/shell.qml" "$gate" '        target: Registry'
  start_unguarded "$sandbox/guard-mutant.log" "$guard_mutant/shell" "the ungated mutant started over the same due follow is unguarded"
  expect_poll "the ungated mutant's scan completes" True scanned_at "$unguarded_pid"
  expect_poll "the ungated mutant follows the changed package" same same_bytes "$guard_pkg/theme.json" "$theme_file"
  kill -TERM "$unguarded_pid" 2>/dev/null || true
else
  fail "the follow gate's text occurs once in $guard_mutant/shell/shell.qml"
fi
rm -r -- "$guard_pkg"
expect "vgs applies after the follow guard rows" "ok theme=vgs state=applied shell=applied" "${shell_env[@]}" "$repo/bin/vgsh" theme apply vgs
