# Sourced by harness.sh before it makes the sandbox, and by
# scripts/test-smoke-teardown.sh. Defines cleanup, the smoke's teardown, and
# arms it on EXIT. It reads the caller's pgids (the process groups spawn
# recorded), keep (true under --keep), sandbox and rt_dir (empty until made)
# and the optional source_tree (a caller's export of another tree). It needs
# no Wayland session and no tool the harness checks for.
#
# Bash runs the EXIT trap on TERM, INT and HUP as well. A second of those
# signals that arrives during the trap ends the shell there and leaves the
# sandbox behind, as when a timeout signals the runner and then the stopping
# systemd unit signals every process in it. The trap ignores the three
# signals first, and the commands it starts inherit that. SIGKILL cannot be
# ignored, so a run killed with it leaves the sandbox behind.
set -euo pipefail

# teardown_step KEY PATH CMD...: run CMD. On failure print
# `qml-smoke: cleanup=KEY path=PATH` on stderr, then CMD's own stderr.
teardown_step() {
  local key="$1" path="$2" err
  shift 2
  err="$("$@" 2>&1 >/dev/null)" && return 0
  printf 'qml-smoke: cleanup=%s path=%s\n' "$key" "$path" >&2
  [[ -z $err ]] || printf '%s\n' "$err" >&2
  return 0
}

cleanup() {
  trap '' TERM INT HUP
  local pg path
  for pg in "${pgids[@]}"; do kill -TERM -- "-$pg" 2>/dev/null || true; done
  sleep 0.5
  for pg in "${pgids[@]}"; do kill -KILL -- "-$pg" 2>/dev/null || true; done
  # The read-only prefix row takes the write bits off part of the sandbox
  # and gives them back only at its end, and rm -rf cannot empty a directory
  # without them. A kept sandbox gets them back too, so plain rm -rf
  # removes it.
  [[ -z $sandbox ]] || teardown_step chmod-failed "$sandbox" chmod -R u+rwX -- "$sandbox"
  if [[ $keep == true ]]; then
    echo "qml-smoke: sandbox kept at $sandbox (runtime dir $rt_dir)"
  else
    for path in "$sandbox" "$rt_dir"; do
      [[ -z $path ]] || teardown_step rm-failed "$path" rm -rf -- "$path"
    done
  fi
  # A caller's export of another tree is read only by the sandbox's copy.
  [[ -z ${source_tree:-} ]] || teardown_step rm-failed "$source_tree" rm -rf -- "$source_tree"
}
trap cleanup EXIT
