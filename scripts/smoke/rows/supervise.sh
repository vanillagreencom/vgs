# Supervision, D069: the runner starts the shell again after it dies, and
# gives up with a Hyprland notice after a streak of quick deaths. The row
# reads, in the nested sandbox:
# - SIGKILL to the shell's qs: the same runner starts a new shell, which
#   answers as the guarded instance, and the bar maps again. The time from
#   the kill to the new shell answering ping is printed as
#   latency_relaunch_ms and held under relaunch_budget_ms, below.
# - a crash loop from a fresh runner: each new shell killed as soon as the
#   lock file names it. After five relaunches the runner gives up: it exits
#   with the killed shell's status, 137, its log holds its gave-up line,
#   and it asked Hyprland for one error notice, which Hyprland answered ok.
#   The runner resolves hyprctl through the shell's stand-in directory, the
#   first entry of its PATH, where a stand-in logs each notify call and
#   Hyprland's reply and execs the real hyprctl for every call.
# Controls start copies of the tree: a runner that reads Hyprland as gone
# after every exit brings no shell back within the budget; a runner whose
# give-up limit is out of reach still runs after the same six kills. The
# row ends with a fresh shell of the tree for the rows after it, and the
# real hyprctl in the stand-in directory.
set -euo pipefail
ipc() { ipc_via "$repo/bin/vgsh" "$@"; }

# The ceiling on latency_relaunch_ms, the time from the SIGKILL to the new
# shell answering ping, read through harness.sh's adopt_shell, which polls
# the lock file every 50 ms and ping every 200 ms, so the reading carries
# at most 250 ms of polling. It holds the runner's first delay, 0.5 s.
# Twice the highest of six readings of this row on host cachy on
# 2026-09-30, at load average 5 to 8: 733 to 757 ms.
relaunch_budget_ms=1514

notify_log="$sandbox/supervise-notify.log"
real_hyprctl="$(command -v hyprctl)"
cat >"$shim/hyprctl.notify-log" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == notify ]]; then
  printf '%s\n' "\$*" >>$(printf %q "$notify_log")
  reply="\$($(printf %q "$real_hyprctl") "\$@")"
  status=\$?
  printf 'reply=%s status=%s\n' "\$reply" "\$status" >>$(printf %q "$notify_log")
  printf '%s\n' "\$reply"
  exit "\$status"
fi
exec $(printf %q "$real_hyprctl") "\$@"
EOF
chmod 755 "$shim/hyprctl.notify-log"
parent_of() { awk '$1 == "PPid:" { print $2 }' "/proc/$1/status"; } # PID

# SIGKILL to the shell's qs, by pid; killed names it and killed_at_ms the
# time. harness.sh's relaunched_within then reads whether the runner brings
# a shell back within the budget, for the tree and its control alike.
kill_shell() { # LABEL
  killed="$shell_qs_pid"
  kill -KILL "$killed" || fail "$1: SIGKILL to the shell pid $killed failed"
  killed_at_ms="$(now_ms)"
}

bars_before="$(bar_count)" || bars_before=unreadable
runner="$shell_pid"
kill_shell "the kill"
expect "a killed shell is back within the budget" back relaunched_within "$killed" "$relaunch_budget_ms"
if adopt_shell "$killed"; then
  relaunch_ms=$(( $(now_ms) - killed_at_ms ))
  echo "  latency_relaunch_ms=$relaunch_ms budget_ms=$relaunch_budget_ms"
  if [[ $relaunch_ms -le $relaunch_budget_ms ]]; then ok "the relaunched shell answers within the budget"; else fail "relaunch latency $relaunch_ms ms over budget $relaunch_budget_ms ms"; fi
  expect "the relaunched shell is the same runner's child" "$runner" parent_of "$shell_qs_pid"
  expect "the relaunched shell answers as the guarded instance" true ipc shell guarded
  expect_poll "the relaunched shell maps the bar again" "$bars_before" bar_count
  expect "the runner logged the relaunch" 1 grep -c -x -F -- "vgsh: shell=exited status=137 relaunch=1 delay=0.5 session=unlocked" "$shell_log"
fi

# The control: a runner that reads Hyprland as gone after every exit.
if copy_tree no-relaunch && edit_tree no-relaunch bin/vgsh \
    'if ! monitors="$(compositor_monitors)"; then' 'if ! monitors="$(false)"; then' \
  && stop_shell && start_shell "$sandbox/tree-no-relaunch" "$sandbox/supervise-no-relaunch-qs.log"; then
  kill_shell "control"
  got="$(relaunched_within "$killed" "$relaunch_budget_ms")" || got=unreadable
  if [[ $got != back ]]; then ok "control: a runner that relaunches nothing brings no shell back ($got)"; else fail "control: the no-relaunch copy brought a shell back"; fi
fi

# The crash loop, from a fresh runner of TREE: every shell the lock file
# names is killed, by pid, until six kills were made. loop_result then
# holds the kills and `ended status=<n>` once the runner ended, `running`
# once it logged a sixth relaunch line, or `undecided` after 40 s. It runs
# in the row's own shell, which started the runner and reaps it.
crash_loop() { # TREE LOG
  local tree="$1" log="$2" last pid kills=0 stat status=0 relaunches
  loop_result=unstarted
  stop_shell || return 0
  rm -f -- "${notify_log:?}"
  start_shell "$tree" "$log" || return 0
  last="$shell_qs_pid"
  kill -KILL "$last"
  kills=1
  for _ in $(seq 1 800); do
    if ! stat="$(ps -o stat= -p "$shell_pid")" || [[ $stat == Z* ]]; then
      wait "$shell_pid" || status=$?
      loop_result="kills=$kills ended status=$status"
      return 0
    fi
    if ((kills >= 6)); then
      relaunches="$(grep -c -E '^vgsh: shell=exited .* relaunch=' -- "$log" || :)"
      if ((relaunches >= 6)); then loop_result="kills=$kills running"; return 0; fi
    elif IFS= read -r pid 2>/dev/null <"$rt_dir/vgsh.lock" && [[ $pid =~ ^[0-9]+$ && $pid != "$last" ]] && kill -KILL "$pid" 2>/dev/null; then
      last="$pid"
      kills=$((kills + 1))
    fi
    sleep 0.05
  done
  loop_result="kills=$kills undecided"
}
notify_calls() { grep -c -E '^notify ' -- "$notify_log" || :; }
notify_words() { grep -E '^notify ' -- "$notify_log" | cut -d' ' -f1-4; }
shim_hyprctl notify-log
loop_log="$sandbox/supervise-loop-qs.log"
crash_loop "$repo" "$loop_log"
expect "after six quick deaths the runner gives up with the killed shell's status" "kills=6 ended status=137" echo "$loop_result"
expect "the runner logged its give-up" 1 grep -c -x -F -- "vgsh: shell=gave-up exits=6 status=137" "$loop_log"
expect "the runner asked Hyprland for one notice" 1 notify_calls
expect "the notice is an error in Hyprland's colour for it" "notify 3 600000 0" notify_words
expect "Hyprland answered the notice ok" 1 grep -c -x -F -- "reply=ok status=0" "$notify_log"
expect "the notice is dismissed for the rows after this one" ok hypr dismissnotify

# The control: a runner whose give-up limit is out of reach.
if copy_tree no-give-up && edit_tree no-give-up bin/vgsh \
    '((streak > ${#supervise_delays[@]})) && [[ $session == unlocked ]]; then' \
    '((streak > 1000)) && [[ $session == unlocked ]]; then'; then
  crash_loop "$sandbox/tree-no-give-up" "$sandbox/supervise-no-give-up-qs.log"
  if [[ $loop_result == "kills=6 running" ]]; then ok "control: a runner with no reachable limit still runs after six kills"; else fail "control: the no-give-up copy read $loop_result"; fi
fi
shim_hyprctl real
stop_shell || :
start_shell "$repo" "$sandbox/supervise-qs.log" || fail "the supervision row leaves a live shell"
