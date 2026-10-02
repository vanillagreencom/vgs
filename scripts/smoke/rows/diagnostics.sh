# Every QML warning and error the shell logged, minus the lines rows
# provoked on purpose, plus the engine's own error classes.
set -euo pipefail
check_unexpected_log "shell log" "$instance_log"

echo "  latency_first_bar_ms=${first_bar_ms:-unmeasured} budget_ms=$first_bar_budget_ms cpu_some_pct=$first_bar_cpu_some_pct"
if [[ -n $first_bar_ms && $first_bar_ms -le $first_bar_budget_ms ]]; then ok "the first bar maps within its budget"; else fail "first bar latency ${first_bar_ms:-unmeasured} ms over budget $first_bar_budget_ms ms"; fi
echo "  latency_reconcile_ms=${reconcile_ms:-unmeasured} budget_ms=$reconcile_budget_ms"
if [[ -n $reconcile_ms && $reconcile_ms -le $reconcile_budget_ms ]]; then ok "a disable reaches the build records within its budget"; else fail "reconcile latency ${reconcile_ms:-unmeasured} ms over budget $reconcile_budget_ms ms"; fi

# The memory sampler finds the shell `vgsh run` started through the runner's
# lock file and the instance list, and samples it by pid.
sampler_rows() { awk -F'\t' -v pid="$shell_qs_pid" 'NR > 1 && $2 == pid { n++ } END { print n + 0 }' "$sandbox/memory.tsv"; }
if "${shell_env[@]}" "$repo/scripts/sample-shell-memory.sh" --interval 1 --samples 2 --log "$sandbox/memory.tsv" >"$sandbox/sampler.out" 2>"$sandbox/sampler.err"; then
  expect "the memory sampler logged two samples of the runner's shell" 2 sampler_rows
else
  fail "memory sampler exited non-zero: $(head -n 2 "$sandbox/sampler.err")"
fi

# The ceiling holds the largest resident size of the shells the run read up
# to here: each shell a row stopped, read at its stop, and this one.
shell_memory_note
if [[ $rss_kib -gt 0 && $hwm_kib -gt 0 ]]; then ok "this shell's resident size and high-water mark are read"; else fail "resident size unreadable for pid $shell_qs_pid: rss_kib=$rss_kib hwm_kib=$hwm_kib"; fi
expect "every shell the run started was read" none shells_unread
echo "  rss_peak_kib=$rss_peak_kib rss_peak_row=${rss_peak_row:-none} ceiling_kib=$rss_ceiling_kib"
expect "the largest resident size is under the ceiling" under rss_verdict "$rss_peak_kib" "$rss_ceiling_kib"
# The controls: a reading one over the ceiling, no reading, and a larger
# reading that an earlier shell left and a smaller, later one does not
# replace.
peak_after() { # RSS_KIB ROW [RSS_KIB ROW]...
  (
    rss_peak_kib=0
    rss_peak_row=""
    while [[ $# -gt 0 ]]; do shell_memory_keep "$1" "$2"; shift 2; done
    echo "$rss_peak_kib $rss_peak_row $(rss_verdict "$rss_peak_kib" "$rss_ceiling_kib")"
  )
}
expect "control: a resident size one over the ceiling reads over" over rss_verdict "$((rss_ceiling_kib + 1))" "$rss_ceiling_kib"
expect "control: a resident size at the ceiling reads under" under rss_verdict "$rss_ceiling_kib" "$rss_ceiling_kib"
expect "control: no reading reads unread" unread rss_verdict 0 "$rss_ceiling_kib"
expect "control: an earlier shell's reading over the ceiling stays the largest" "$((rss_ceiling_kib + 1)) earlier over" peak_after "$((rss_ceiling_kib + 1))" earlier 1 later
expect "control: a later, larger reading replaces a smaller one" "2 later under" peak_after 1 earlier 2 later
unread_after() { ( shell_pids_started+=("$1"); shells_unread ) } # PID
expect "control: a started shell no note read is named" 1 unread_after 1
