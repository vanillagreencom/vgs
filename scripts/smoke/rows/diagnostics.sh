# Every QML warning and error the shell logged, minus the lines rows
# provoked on purpose, plus the engine's own error classes.
set -euo pipefail
error_pattern=' ERROR |WARN qml: |WARN scene:|WARN quickshell\.hyprland|TypeError|ReferenceError|is not defined|Cannot read|Cannot assign'
unexpected_errors() {
  python3 - "$instance_log" "$error_pattern" "${expected_errors[@]}" <<'PY'
import re, sys
path, pattern, expected = sys.argv[1], re.compile(sys.argv[2]), [re.compile(e) for e in sys.argv[3:]]
for line in open(path, errors="replace"):
    if pattern.search(line) and not any(e.search(line) for e in expected):
        print(line.rstrip())
PY
}
if ! log_errors="$(unexpected_errors)"; then
  fail "shell log unreadable: $instance_log"
elif [[ -n $log_errors ]]; then
  fail "shell log holds errors:"
  head -n 20 <<<"$log_errors"
else
  ok "shell log holds no unexpected error ($instance_log)"
fi

echo "  latency_first_bar_ms=${first_bar_ms:-unmeasured} budget_ms=$first_bar_budget_ms"
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

rss_kib=0; hwm_kib=0
if ! rss_kib="$(awk '/^VmRSS:/ { print $2 }' "/proc/$shell_qs_pid/status")"; then fail "resident size unreadable for pid $shell_qs_pid"; fi
if ! hwm_kib="$(awk '/^VmHWM:/ { print $2 }' "/proc/$shell_qs_pid/status")"; then fail "high-water mark unreadable for pid $shell_qs_pid"; fi
echo "  rss_kib=$rss_kib hwm_kib=$hwm_kib ceiling_kib=$rss_ceiling_kib"
if [[ $rss_kib -gt 0 && $rss_kib -le $rss_ceiling_kib ]]; then ok "resident size under the ceiling"; else fail "resident size $rss_kib KiB over ceiling $rss_ceiling_kib KiB"; fi
