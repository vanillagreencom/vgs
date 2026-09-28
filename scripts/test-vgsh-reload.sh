#!/usr/bin/env bash
# Controls for the reload hooks of `vgsh theme apply` and for `vgsh theme
# reload`. Each row pins an exit status, the structured result, the keyed
# stderr line, the hook's run record and the pending file. Every hook is a
# stub on the rows' PATH under a temporary XDG_RUNTIME_DIR, so no hook
# reaches the developer's session.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
theme_tree
readlink_bin="$(command -v readlink)"; sleep_bin="$(command -v sleep)"
pending="$state/reload-pending.json"; runs="$tmp/hook-runs"

# The hook appends one line per run to $runs: its first argument, what its
# descriptor 9 names, its XDG_RUNTIME_DIR and the pending file's line while
# it runs. It writes to stdout and stderr, then exits with the status
# $tmp/hook-exit-<arg> holds (0 when absent), sleeps well past any timeout
# here for `sleep`, or kills itself with SIGTERM for `signal`.
cat >"$stubs/vgs-hook" <<EOF
#!/bin/sh
p=none
[ -f "$pending" ] && read -r p <"$pending"
printf '%s fd9=%s rt=%s pending=%s\n' "\$1" "\$($readlink_bin /proc/self/fd/9 2>/dev/null || echo none)" "\$XDG_RUNTIME_DIR" "\$p" >>"$runs"
echo "hook noise"; echo "hook noise" >&2
st=0
[ -f "$tmp/hook-exit-\$1" ] && read -r st <"$tmp/hook-exit-\$1"
case "\$st" in
  sleep) exec $sleep_bin 5 ;;
  signal) kill -TERM \$\$ ;;
esac
exit "\$st"
EOF
chmod +x "$stubs/vgs-hook"
export THEME_PATH="$stubs:$theme_path"

cfg="$tmp/cfg-reload"; mkdir -p "$cfg/vgs"; file="$cfg/vgs/theme.json"
theme_pkg "$tree/themes/dusk" '{ "schemaVersion": 1, "name": "dusk", "tokens": { "palette": { "accent": "#111111" } } }'
theme_pkg "$tree/themes/nord" '{ "schemaVersion": 1, "name": "nord", "tokens": { "palette": { "accent": "#222222" } } }'
# `alpha` has a hook; `plain` has none, so it is never pending.
alpha_hook() { target_dir alpha "$(target_json alpha hex6 '[]' 'include=@{state}/alpha.conf' true "{ \"command\": [\"$1\", \"alpha\"], \"timeoutMs\": $2 }")" 'a=@{palette.accent}'; }
alpha_hook vgs-hook 3000
target_dir plain "$(target_json plain hex6 '[]' 'include=@{state}/plain.conf' true)" 'p=@{palette.accent}'

hook() { rm -f -- "$tmp/hook-exit-alpha"; [[ $1 == 0 ]] || printf '%s\n' "$1" >"$tmp/hook-exit-alpha"; }
fresh() { : >"$runs"; }
ran() { [[ "$(cat "$runs")" == "$1" ]]; }
pending_is() { [[ -f $pending && "$(cat "$pending")" == "{\"schemaVersion\":1,\"targets\":$1}" ]]; }
no_pending() { [[ ! -e $pending && ! -L $pending ]]; }
one_line() { [[ "$(wc -l <"$tmp/out")" == 1 ]]; }
run_line() { printf 'alpha fd9=/dev/null rt=%s pending=%s' "$rt_empty" "$1"; }
alpha_due='{"schemaVersion":1,"targets":["alpha"]}'
result() { # ALPHA_STATE ALPHA_REASON PLAIN_STATE: an apply's targets
  printf '[{"name":"alacritty","state":"skipped","reason":"not-detected"},{"name":"alpha","state":"%s","reason":%s},{"name":"foot","state":"skipped","reason":"not-detected"},{"name":"ghostty","state":"skipped","reason":"not-detected"},{"name":"kitty","state":"skipped","reason":"not-detected"},{"name":"plain","state":"%s","reason":null},{"name":"wezterm","state":"skipped","reason":"not-detected"}]' "$1" "$2" "$3"
}

# Changed bytes run the hook once, after the pending file names it, with
# the rows' environment, its output discarded and no lock descriptor.
fresh
tinst "a hook runs on changed bytes" "$cfg" "$rt_empty" 0 "{\"state\":\"applied\",\"shell\":\"applied\",\"targets\":$(result written null written),\"theme\":\"dusk\",\"reason\":null}" "" theme apply --json dusk
check "the hook ran once, pending while it ran, without the lock descriptor" ran "$(run_line "$alpha_due")"
check "a hook's output never reaches the result line or stderr" one_line
check "a reloaded apply leaves nothing pending" no_pending
fresh
tinst "a hook does not run on unchanged bytes" "$cfg" "$rt_empty" 0 "ok theme=dusk state=unchanged shell=unchanged" "" theme apply dusk
check "unchanged bytes ran no hook" ran ""

# A failing hook leaves its target reload-pending and the apply partial;
# the next apply runs it again though no byte changed.
hook 1; fresh
tinst "a failing hook is reload-pending" "$cfg" "$rt_empty" 3 "{\"state\":\"partial\",\"shell\":\"applied\",\"targets\":$(result reload-pending '"reload-failed"' written),\"theme\":\"nord\",\"reason\":null}" "vgsh: refused: target=alpha reason=reload-failed command=vgs-hook status=1" theme apply --json nord
check "the failing hook ran once" ran "$(run_line "$alpha_due")"
check "the failed reload is pending" pending_is '["alpha"]'
fresh
tinst "a pending reload fails again in text mode" "$cfg" "$rt_empty" 3 "partial theme=nord state=partial shell=unchanged" "vgsh: refused: target=alpha reason=reload-failed command=vgs-hook status=1" theme apply nord
check "text mode prints the reload-pending target" has_line "target=alpha state=reload-pending reason=reload-failed"
hook 0; fresh
tinst "a pending reload runs on unchanged bytes" "$cfg" "$rt_empty" 0 "ok theme=nord state=unchanged shell=unchanged" "" theme apply nord
check "the pending hook ran once" ran "$(run_line "$alpha_due")"
check "a pending reload that succeeds is cleared" no_pending

# A hook past its timeout is killed, failed and pending, well before it
# would have exited.
alpha_hook vgs-hook 200; hook sleep; fresh
started="$(date +%s%N)"
tinst "a hook past its timeout is reload-pending" "$cfg" "$rt_empty" 3 "$any_out" "vgsh: refused: target=alpha reason=reload-timeout command=vgs-hook timeout-ms=200" theme apply --json dusk
elapsed_ms=$(( ($(date +%s%N) - started) / 1000000 ))
tail -n 1 "$tmp/out" >"$tmp/apply.json"
check "the timed-out target is reload-pending with reload-timeout" json_is "$tmp/apply.json" 'd["state"] == "partial" and [t for t in d["targets"] if t["name"] == "alpha"] == [{"name": "alpha", "state": "reload-pending", "reason": "reload-timeout"}]'
check "the timed-out hook is pending" pending_is '["alpha"]'
check "the timeout ends the apply before the hook's own 5 s ($elapsed_ms ms)" test "$elapsed_ms" -lt 3000

# vgsh theme reload runs every pending hook again and nothing else.
fresh
tinst "a reload whose hook still times out is partial" "$cfg" "$rt_empty" 3 '{"state":"partial","targets":[{"name":"alpha","state":"reload-pending","reason":"reload-timeout"}],"reason":null}' "vgsh: refused: target=alpha reason=reload-timeout command=vgs-hook timeout-ms=200" theme reload --json
check "a still-failing reload stays pending" pending_is '["alpha"]'
hook signal
tinst "a hook killed by a signal is reload-failed" "$cfg" "$rt_empty" 3 "partial reload state=partial" "vgsh: refused: target=alpha reason=reload-failed command=vgs-hook signal=SIGTERM" theme reload
alpha_hook vgs-hook 3000; hook 0; fresh
cp -- "$state/theme/alpha.conf" "$tmp/alpha-landed"; cp -- "$file" "$tmp/theme-before"
tinst "a reload runs the pending hook" "$cfg" "$rt_empty" 0 '{"state":"reloaded","targets":[{"name":"alpha","state":"reloaded","reason":null}],"reason":null}' "" theme reload --json
check "the reload ran the hook once" ran "$(run_line "$alpha_due")"
check "a successful reload clears the pending state" no_pending
check "a reload writes no target file" cmp -s "$tmp/alpha-landed" "$state/theme/alpha.conf"
check "a reload writes no theme file" cmp -s "$tmp/theme-before" "$file"
fresh
tinst "a reload with nothing pending is unchanged" "$cfg" "$rt_empty" 0 "ok reload state=unchanged" "" theme reload
check "a reload with nothing pending runs no hook" ran ""
tinst "theme reload takes no argument" "$cfg" "$rt_empty" 2 "" "vgsh: refused: argument=alpha" theme reload alpha

# A pending target whose reload can no longer run is dropped: gone from
# themes/targets, given no hook, or disabled. One whose hook cannot start
# fails and stays pending.
printf '{"schemaVersion":1,"targets":["gone","plain"]}\n' >"$pending"; fresh
tinst "a reload drops a target no longer shipped or without a hook" "$cfg" "$rt_empty" 0 '{"state":"reloaded","targets":[{"name":"gone","state":"skipped","reason":"not-shipped"},{"name":"plain","state":"skipped","reason":"no-reload"}],"reason":null}' "" theme reload --json
check "the dropped targets leave nothing pending" no_pending
alpha_hook vgs-missing-hook 3000
tinst "a hook that cannot start is reload-failed" "$cfg" "$rt_empty" 3 "$any_out" "vgsh: refused: target=alpha reason=reload-failed command=vgs-missing-hook error=ENOENT" theme apply nord
check "a hook that cannot start is pending" pending_is '["alpha"]'
alpha_hook vgs-hook 3000
printf '{ "disabledTargets": ["alpha"] }\n' >"$cfg/vgs/shell.json"; fresh
tinst "a reload drops a disabled target" "$cfg" "$rt_empty" 0 '{"state":"reloaded","targets":[{"name":"alpha","state":"skipped","reason":"disabled"}],"reason":null}' "" theme reload --json
check "a disabled target's hook never runs and it is dropped" test -z "$(cat "$runs")" -a ! -e "$pending"
printf '{}\n' >"$cfg/vgs/shell.json"
hook 1
tinst "alpha is pending again" "$cfg" "$rt_empty" 3 "$any_out" "vgsh: refused: target=alpha reason=reload-failed command=vgs-hook status=1" theme apply dusk
printf '{ "disabledTargets": ["alpha"] }\n' >"$cfg/vgs/shell.json"; fresh
tinst "an apply drops a disabled target's pending reload" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply --json dusk
check "the disabled target's hook never ran and it is dropped" test -z "$(cat "$runs")" -a ! -e "$pending"
printf '{}\n' >"$cfg/vgs/shell.json"; hook 0
tinst "alpha lands again" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord

# The pending file is read before anything moves and never lost in silence.
printf '{"schemaVersion":1,"targets":"alpha"}\n' >"$pending"
cp -- "$file" "$tmp/theme-before"; fresh
tinst "a malformed pending file refuses the apply" "$cfg" "$rt_empty" 1 '{"state":"failed","shell":"unchanged","targets":[],"theme":"dusk","reason":"malformed"}' "vgsh: refused: theme=dusk reason=malformed path=$pending" theme apply --json dusk
check "the refused apply leaves the theme file" cmp -s "$tmp/theme-before" "$file"
check "the refused apply leaves theme.name" test "$(cat "$state/theme.name")" == nord
tinst "a malformed pending file refuses the reload" "$cfg" "$rt_empty" 1 '{"state":"failed","targets":[],"reason":"malformed"}' "vgsh: refused: reload=pending reason=malformed path=$pending" theme reload --json
check "a refused reload runs no hook" ran ""
printf '%s\n' "$alpha_due" >"$pending"
chmod 500 "$state"
tinst "a pending file that cannot be updated refuses the reload" "$cfg" "$rt_empty" 1 "" "vgsh: refused: reload=pending reason=unwritable path=$pending error=EACCES" theme reload
chmod 700 "$state"
check "the unwritable reload keeps the target pending" pending_is '["alpha"]'
rm -f -- "$pending"

# The lock: held here the way a running apply holds it.
exec 7>>"$cfg/vgs/theme.lock"
flock 7
tinst "a reload while the theme lock is held is refused as busy" "$cfg" "$rt_empty" 75 '{"state":"failed","targets":[],"reason":"busy"}' "vgsh: refused: reload=pending reason=busy" theme reload --json
exec 7>&-

# Must-fail controls, each on a judge copy, one per rule. Each starts from
# alpha landed with dusk, nothing pending. A copy without the descriptor
# 9 slot alone stays green here: node marks its inherited descriptors 0 to
# 16 close-on-exec at startup (runtime.md § Process), so the planted defect
# hands the hook the lock descriptor instead.
reset_alpha() { alpha_hook vgs-hook 3000; hook 0; unset THEME_BIN; rm -f -- "$pending"; tinst "$1: alpha lands with dusk" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk; fresh; }
reset_alpha "every-landed control"
judge_control every-landed 'return entry.state === "written" || before.includes(entry.name);' 'return true;'
tinst "the every-landed mutant applies unchanged bytes" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply dusk
check "the every-landed mutant runs a hook on unchanged bytes" test -n "$(cat "$runs")"
reset_alpha "never-pending control"
judge_control never-pending 'writePending(stateDir, stillPending(result.targets, due), due, key);' 'writePending(stateDir, [], due, key);'
hook 1
tinst "the never-pending mutant fails a hook" "$cfg" "$rt_empty" 3 "$any_out" "vgsh: refused: target=alpha reason=reload-failed command=vgs-hook status=1" theme apply nord
hook 0; fresh
tinst "the never-pending mutant applies unchanged bytes" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the never-pending mutant never runs the failed hook again" ran ""
reset_alpha "late-pending control"
judge_control late-pending '    writePending(stateDir, due, before, key);' ''
tinst "the late-pending mutant applies changed bytes" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the late-pending mutant's hook runs with nothing pending" ran "$(run_line none)"
reset_alpha "timeout-kind control"
judge_control timeout-kind 'if (run.error !== undefined && run.error.code === "ETIMEDOUT") {' 'if (false) {'
alpha_hook vgs-hook 200; hook sleep
tinst "the timeout-kind mutant reports a timed-out hook" "$cfg" "$rt_empty" 3 "$any_out" "vgsh: refused: target=alpha reason=reload-failed command=vgs-hook error=ETIMEDOUT" theme apply nord
reset_alpha "unbounded control"
judge_control unbounded 'timeout: reload.timeoutMs, ' ''
alpha_hook vgs-hook 200; hook sleep
started="$(date +%s%N)"
tinst "the unbounded mutant waits for the hook" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
elapsed_ms=$(( ($(date +%s%N) - started) / 1000000 ))
check "the unbounded mutant outlives the timeout ($elapsed_ms ms)" test "$elapsed_ms" -ge 3000
reset_alpha "lock-descriptor control"
judge_control lock-descriptor 'stdio[LOCK_FD] = nul;' 'stdio[LOCK_FD] = LOCK_FD;'
tinst "the lock-descriptor mutant applies changed bytes" "$cfg" "$rt_empty" 0 "$any_out" "" theme apply nord
check "the lock-descriptor mutant's hook holds the theme lock" ran "alpha fd9=$cfg/vgs/theme.lock rt=$rt_empty pending=$alpha_due"
unset THEME_BIN

rows_done test-vgsh-reload
