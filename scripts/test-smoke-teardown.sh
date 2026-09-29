#!/usr/bin/env bash
# Drive scripts/smoke/teardown.sh, the smoke sandbox's teardown, through the
# exits a run of the read-only prefix row can take. Each case starts a child
# bash in its own process group that sources the teardown the way harness.sh
# does, makes a sandbox, a runtime dir and an export under this suite's
# scratch directory, builds a nested prefix tree, records one process group
# as spawn does, and takes the write bits off the tree as
# scripts/smoke/rows/read-only-prefix.sh does. The child then fails under
# set -e, or waits for the signals the case sends to its process group. Each
# case pins the exit status, whether the sandbox and the runtime dir are gone
# or kept, that the export and the recorded process group are gone, and that
# stderr is empty. The controls at the end plant one defect per rule in a
# copy of the teardown and require the case that rule owns to go red.
#
# The child gets an explicit environment. Its sandbox and runtime dir are
# never under the host's XDG_RUNTIME_DIR. The suite signals only the process
# groups it started and those its children recorded.
#
# Exit 0 when every case and control holds, 1 otherwise.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
teardown="$repo/scripts/smoke/teardown.sh"

# The EXIT trap is armed only on the directory mktemp made: an empty or
# non-directory answer never reaches rm -rf.
tmp="$(mktemp -d)" || { echo "test-smoke-teardown: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $tmp && ! -L $tmp ]] || { echo "test-smoke-teardown: scratch=not-a-directory value=[$tmp]" >&2; exit 1; }
tmp="$(cd -- "$tmp" && pwd -P)"
# Process groups this suite started or its children recorded. A control's
# case leaves a non-writable tree, so the owner bits come back before rm.
groups=()
finish() {
  local pg
  for pg in "${groups[@]}"; do kill -KILL -- "-$pg" 2>/dev/null || true; done
  chmod -R u+rwX -- "${tmp:?}" 2>/dev/null || true
  rm -rf -- "${tmp:?}"
}
trap finish EXIT
failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# The process group the child records. TERM from the teardown writes the
# marker the second-signal cases wait for.
cat >"$tmp/group.sh" <<'SH'
trap ': >"$1"; exit 0' TERM
while :; do sleep 0.1; done
SH

# The child: TEARDOWN MODE CASE_DIR GROUP_SCRIPT. MODE abort fails under
# set -e after the chmod, keep does the same with keep=true, wait idles
# until a signal ends it.
cat >"$tmp/child.sh" <<'SH'
set -euo pipefail
teardown="$1" mode="$2" case_dir="$3" group_script="$4"
sandbox="" rt_dir="" pgids=() keep=false
[[ $mode != keep ]] || keep=true
source_tree="$case_dir/export"
mkdir -- "$source_tree"
source "$teardown"
sandbox="$case_dir/sandbox"
mkdir -- "$sandbox"
rt_dir="$case_dir/runtime"
mkdir -- "$rt_dir"
readonly_dest="$sandbox/read-only-prefix"
mkdir -p -- "$readonly_dest/usr/bin" "$readonly_dest/usr/share/vgs/shell/Core" "$readonly_dest/usr/share/vgs/themes/targets/kitty"
printf '#!/bin/sh\n' >"$readonly_dest/usr/bin/vgsh"
chmod 755 -- "$readonly_dest/usr/bin/vgsh"
echo 'Item {}' >"$readonly_dest/usr/share/vgs/shell/Core/Config.qml"
echo '{}' >"$readonly_dest/usr/share/vgs/themes/targets/kitty/target.json"
setsid bash "$group_script" "$case_dir/group-termed" &
pgids+=("$!")
printf '%s\n' "$!" >"$case_dir/group"
chmod -R a-w -- "$readonly_dest/usr"
case $mode in
  abort|keep) false ;;
  wait) : >"$case_dir/ready"; while :; do sleep 0.1; done ;;
esac
SH

# wait_for PATH: true once PATH exists. A real wait: the child makes it
# asynchronously; 10 s is far past the milliseconds it takes.
wait_for() {
  local _
  for _ in $(seq 1 500); do [[ -e $1 ]] && return 0; sleep 0.02; done
  return 1
}

# gone PID_OR_GROUP TRIES: true once kill -0 finds nothing, polled every
# 20 ms. A real wait: the teardown takes half a second, and a killed process
# lingers until its parent or the reaper collects it.
gone() {
  local _
  for _ in $(seq 1 "$2"); do kill -0 -- "$1" 2>/dev/null || return 0; sleep 0.02; done
  return 1
}

# run_case FILE ROW: true when the teardown FILE holds the row. What broke
# is in `problems`, the case's directory in `case_dir`, and the first
# teardown failure line the child printed on stderr in `keyed_err`. Bash's
# own job notices, such as `Terminated`, may share stderr.
cases=0
problems=()
case_dir=""
keyed_err=""
run_case() {
  local file="$1" label mode signals want_status want_sandbox pid status=0 sig first=true recorded
  IFS='|' read -r label mode signals want_status want_sandbox <<<"$2"
  cases=$((cases + 1))
  case_dir="$tmp/case-$cases"
  mkdir -- "$case_dir"
  problems=()
  # env restores SIGINT, which bash ignores in a background command.
  setsid env -i --default-signal=INT PATH="$PATH" HOME="$tmp/home" TMPDIR="$tmp" LC_ALL=C \
    bash "$tmp/child.sh" "$file" "$mode" "$case_dir" "$tmp/group.sh" >"$case_dir/out" 2>"$case_dir/err" &
  pid=$!
  groups+=("$pid")
  if [[ -n $signals ]]; then
    if ! wait_for "$case_dir/ready"; then
      problems+=("ready=missing")
    else
      for sig in $signals; do
        # A later signal lands while the teardown waits after the TERM it
        # sent the recorded group, before it removes anything.
        if [[ $first == false ]] && ! wait_for "$case_dir/group-termed"; then
          problems+=("group-termed=missing")
          break
        fi
        kill -"$sig" -- "-$pid"
        first=false
      done
    fi
  fi
  if ! gone "$pid" 500; then
    problems+=("child=still-running")
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  # Bash prints its own notice when the job died of a signal, such as
  # `Hangup`; the status below carries that signal.
  { wait "$pid"; } 2>/dev/null || status=$?
  keyed_err=""
  if [[ ! -r $case_dir/err ]]; then
    problems+=("stderr=unreadable")
  elif ! keyed_err="$(grep -m 1 '^qml-smoke: cleanup=' -- "$case_dir/err")"; then
    keyed_err=""
  fi
  [[ $status -eq $want_status ]] || problems+=("exit=$status want=$want_status")
  if recorded="$(<"$case_dir/group")" 2>/dev/null && [[ -n $recorded ]]; then
    groups+=("$recorded")
    gone "-$recorded" 100 || problems+=("recorded-group=alive")
  else
    problems+=("recorded-group=unrecorded")
  fi
  [[ ! -e $case_dir/export ]] || problems+=("export=left")
  case $want_sandbox in
    gone)
      [[ ! -e $case_dir/sandbox ]] || problems+=("sandbox=left")
      [[ ! -e $case_dir/runtime ]] || problems+=("runtime=left")
      [[ -z $keyed_err ]] || problems+=("teardown=failed")
      ;;
    kept)
      [[ -d $case_dir/sandbox && -d $case_dir/runtime ]] || problems+=("sandbox=not-kept")
      rm -rf -- "$case_dir/sandbox" 2>/dev/null || problems+=("kept-sandbox=not-removable")
      [[ ! -e $case_dir/sandbox ]] || problems+=("kept-sandbox=left-after-rm")
      ;;
    *) problems+=("row=unknown-sandbox-expectation:$want_sandbox") ;;
  esac
  [[ ${#problems[@]} -eq 0 ]]
}

# Rows: label | child mode | signals sent to its process group, in order |
# exit status | sandbox and runtime dir gone or kept.
cases_table=(
  "a set -e failure after the chmod removes the sandbox|abort||1|gone"
  "one TERM removes the sandbox|wait|TERM|143|gone"
  "one HUP removes the sandbox|wait|HUP|129|gone"
  "one INT removes the sandbox|wait|INT|130|gone"
  "a second TERM during the teardown does not cut it|wait|TERM TERM|143|gone"
  "a HUP after a TERM does not cut the teardown|wait|TERM HUP|143|gone"
  "a kept sandbox is removable with plain rm -rf|keep||1|kept"
)
for row in "${cases_table[@]}"; do
  if run_case "$teardown" "$row"; then ok "${row%%|*}"; else fail "${row%%|*}: ${problems[*]}"; fi
done

# mutate OLD NEW OUT: a copy of the teardown with OLD, which must occur
# once, replaced by NEW.
mutate() {
  local text rest count
  text="$(<"$teardown")"
  rest="${text//"$1"/}"
  count=$(( (${#text} - ${#rest}) / ${#1} ))
  if [[ $count -ne 1 ]]; then
    printf '        mutation matched %s times: %s\n' "$count" "$1"
    return 1
  fi
  printf '%s\n' "${text/"$1"/"$2"}" >"$3"
  cmp -s -- "$teardown" "$3" && { printf '        mutation left the file unchanged: %s\n' "$1"; return 1; }
  return 0
}

# Rows: label | text | replacement | the case label that must go red | the
# problem that case must report | the teardown failure line it must print,
# CASE standing for its directory, or empty for any. A field holds no `|`,
# the separator.
controls=(
  "the owner bits are not restored|chmod -R u+rwX -- \"\$sandbox\"|true|a set -e failure after the chmod removes the sandbox|sandbox=left|qml-smoke: cleanup=rm-failed path=CASE/sandbox"
  "the signals are not ignored|trap '' TERM INT HUP|:|a second TERM during the teardown does not cut it|sandbox=left|"
)
for i in "${!controls[@]}"; do
  IFS='|' read -r label old new target want want_err <<<"${controls[i]}"
  mutant="$tmp/mutant-$i.sh"
  if ! mutate "$old" "$new" "$mutant"; then fail "control: $label"; continue; fi
  row=""
  for candidate in "${cases_table[@]}"; do [[ ${candidate%%|*} == "$target" ]] && row="$candidate"; done
  if [[ -z $row ]]; then fail "control: $label names no case: $target"; continue; fi
  if run_case "$mutant" "$row"; then
    fail "control: $label left '$target' green"
  elif [[ " ${problems[*]} " != *" $want "* ]]; then
    fail "control: $label went red without $want: ${problems[*]}"
  elif [[ -n $want_err && $keyed_err != "${want_err//CASE/$case_dir}" ]]; then
    fail "control: $label printed [$keyed_err] as its teardown failure"
  else
    ok "control: $label"
  fi
done

if [[ $failures -gt 0 ]]; then
  echo "test-smoke-teardown: failed=$failures"
  exit 1
fi
echo "test-smoke-teardown: ok"
