#!/usr/bin/env bash
# Canonical VGS QML smoke.
#
# Never launches a VGS shell into the live session. A second full VGS instance
# competes with the session shell for session-global resources (WlSessionLock,
# the fade-to-lock overlay, idle/DPMS tiers) and leaves orphaned full-screen
# layer surfaces behind, which is how a validation run can black out a working
# Hyprland session.
#
#   scripts/qml-smoke.sh                 static QML parse check (always safe)
#   scripts/qml-smoke.sh --nested        + run the real shell inside an isolated
#                                          nested compositor sandbox
#   scripts/qml-smoke.sh --require-nested fail instead of skipping when the
#                                          sandbox cannot be built
#   scripts/qml-smoke.sh --require-static fail instead of skipping when qmllint
#                                          is unavailable
#
# The default mode is a *parse* check: it catches syntax errors across the QML
# tree, not runtime faults. Unresolved qs.* imports and missing properties only
# surface when the shell actually runs, which is what --nested is for.
#
# --nested loads bundled plugins from config/vshell/plugins and waits for EVERY
# one of them to report loaded before it stops observing, so plugin-owned QML is
# inside the checked window. It fails if any of them never loads.
#
# Both modes assert that they leave the live session byte-for-byte alone: same
# VGS Quickshell instances, same VGS layer surfaces. Cleanup is process-group
# scoped and runs on success, failure, timeout, and interrupt. This script never
# uses a broad `pkill quickshell` — other Quickshell applications on the seat
# are legitimate.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
qml_roots=("$repo_root/quickshell/vshell" "$repo_root/config/vshell/plugins")

nested=false
require_nested=false
require_static=false
static_ran=false
nested_timeout=40
compositor_timeout=15
# Bundled plugins are scanned asynchronously after the core tree loads, so they
# appear well after the first core IPC target does. Waiting for them is what
# makes plugin-owned QML part of the observed window.
plugin_timeout=30

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nested) nested=true ;;
    --require-nested) nested=true; require_nested=true ;;
    --require-static) require_static=true ;;
    --timeout) shift; nested_timeout="${1:?--timeout needs a value}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "qml-smoke: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

status=0
note() { printf 'qml-smoke: %s\n' "$*"; }
fail() { printf 'qml-smoke: FAIL: %s\n' "$*" >&2; status=1; }

# --- live-session snapshots -------------------------------------------------

# shellcheck source=scripts/lib/session-snapshot.sh
source "$repo_root/scripts/lib/session-snapshot.sh"
vgs_snapshot_prefix="qml-smoke: "

instances_before="$(vgs_snapshot_instances)" && instances_before_status=0 || instances_before_status=$?
layers_before="$(vgs_snapshot_layers)" && layers_before_status=0 || layers_before_status=$?

# --- deterministic cleanup --------------------------------------------------

declare -a tracked_pgids=()
declare -a scratch_dirs=()
spawn_launcher_pid=""
spawn_pgid=""

track_pgid() { tracked_pgids+=("$1"); }
track_dir() { scratch_dirs+=("$1"); }

# Launches a command in its own session/process group and records the group so
# cleanup can signal exactly what this script started. The inner shell reports
# its own pid (== the new process group id) before exec'ing the real command.
spawn_group() {
  local pidfile="$1" launcher waited
  shift
  rm -f -- "$pidfile"
  setsid --wait sh -c 'echo $$ >"$1"; shift; exec "$@"' _ "$pidfile" "$@" &
  launcher=$!
  spawn_launcher_pid="$launcher"
  spawn_pgid=""
  for waited in $(seq 1 100); do
    if [[ -s "$pidfile" ]]; then
      spawn_pgid="$(tr -d '[:space:]' <"$pidfile")"
      break
    fi
    kill -0 "$launcher" 2>/dev/null || break
    sleep 0.05
  done
  if [[ -z "$spawn_pgid" ]]; then
    # The pid file never appeared, but the command may be running anyway.
    # Nothing may be left behind unsupervised, so adopt whatever setsid forked
    # (parent-scoped, never a name match) before reporting the failure.
    local child
    for child in $(pgrep -P "$launcher" 2>/dev/null || true); do
      track_pgid "$child"
    done
    kill "$launcher" 2>/dev/null || true
    return 1
  fi
  track_pgid "$spawn_pgid"
}

# Signals the process group we created and nothing else. Every pid here came
# from a setsid launch in this script, so the group can never contain a
# pre-existing shell or an unrelated Quickshell application.
kill_pgid() {
  local pgid="$1" waited
  kill -0 -- "-$pgid" 2>/dev/null || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for waited in $(seq 1 40); do
    kill -0 -- "-$pgid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

# A signal handler inherits $? from whatever finished last, which is usually 0,
# so an interrupted run would otherwise report success to CI.
cleanup() {
  local code=$? signal="${1:-}" pgid dir index
  trap - EXIT INT TERM HUP
  case "$signal" in
    INT) code=130 ;;
    TERM) code=143 ;;
    HUP) code=129 ;;
  esac
  for ((index = ${#tracked_pgids[@]} - 1; index >= 0; index--)); do
    pgid="${tracked_pgids[index]}"
    kill_pgid "$pgid"
    if kill -0 -- "-$pgid" 2>/dev/null; then
      printf 'qml-smoke: FAIL: process group %s survived cleanup\n' "$pgid" >&2
      code=1
    fi
  done
  for dir in "${scratch_dirs[@]:-}"; do
    [[ -n "$dir" && -d "$dir" ]] && rm -rf -- "$dir"
  done
  assert_live_session_untouched || code=1
  exit "$code"
}

assert_live_session_untouched() {
  local ok=0 instances_after layers_after instances_after_status layers_after_status
  instances_after="$(vgs_snapshot_instances)" && instances_after_status=0 || instances_after_status=$?
  layers_after="$(vgs_snapshot_layers)" && layers_after_status=0 || layers_after_status=$?

  if ! vgs_compare_snapshots "live VGS instances" \
    "$instances_before" "$instances_before_status" \
    "$instances_after" "$instances_after_status" exact; then
    ok=1
  fi
  if ! vgs_compare_snapshots "live VGS layer surfaces" \
    "$layers_before" "$layers_before_status" \
    "$layers_after" "$layers_after_status" growth \
  "$(printf '%s' "$instances_after" | grep -c . || true)"; then
    ok=1
  fi
  return "$ok"
}

trap 'cleanup' EXIT
trap 'cleanup INT' INT
trap 'cleanup TERM' TERM
trap 'cleanup HUP' HUP

# --- static QML parse check -------------------------------------------------

find_qmllint() {
  local candidate bindir
  for candidate in qmllint qmllint-qt6 /usr/lib/qt6/bin/qmllint /usr/lib/qt/bin/qmllint; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  if command -v qtpaths6 >/dev/null 2>&1; then
    bindir="$(qtpaths6 --query QT_INSTALL_BINS 2>/dev/null || true)"
    if [[ -n "$bindir" && -x "$bindir/qmllint" ]]; then
      printf '%s\n' "$bindir/qmllint"
      return 0
    fi
  fi
  return 1
}

static_check() {
  local linter files=() findings output rc
  mapfile -t files < <(find "${qml_roots[@]}" -name '*.qml' -type f 2>/dev/null | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    fail "no QML files found under ${qml_roots[*]}"
    return
  fi
  if ! linter="$(find_qmllint)"; then
    if [[ "$require_static" == true ]]; then
      fail "qmllint not installed (pacman -S qt6-declarative)"
    else
      note "static parse check skipped: qmllint not installed (pacman -S qt6-declarative)"
    fi
    return
  fi
  # The linter's own exit status has to be inspected separately: piping into
  # grep would let a linter that cannot run at all (missing library, wrong
  # architecture) look identical to a clean scan.
  rc=0
  output="$("$linter" "${files[@]}" 2>&1)" || rc=$?
  # qmllint exits 0 when nothing is reported and 255 when it reports something,
  # including the semantic warnings this check deliberately ignores. Any other
  # status means the linter itself failed.
  if [[ "$rc" != 0 && "$rc" != 255 ]]; then
    printf '%s\n' "$output" | tail -n 20 >&2
    fail "qmllint could not run (exit $rc)"
    return
  fi

  # Semantic warnings (unqualified access, uncreatable types, unresolved
  # qs.* module imports) are expected outside a Quickshell engine, so only
  # parse-level findings are treated as failures. syntax.duplicate-ids is
  # dropped as well: qmllint keeps one id table per document, but two inline
  # delegates are separate component scopes and may legally reuse an id.
  findings="$(printf '%s\n' "$output" |
    grep -E '\[syntax(\.[a-z-]+)?\]' |
    grep -v '\[syntax\.duplicate-ids\]' || true)"
  if [[ -n "$findings" ]]; then
    printf '%s\n' "$findings" >&2
    fail "QML parse errors in ${#files[@]} scanned files"
    return
  fi
  static_ran=true
  note "static parse check passed (${#files[@]} QML files)"
}

# --- isolated nested runtime check ------------------------------------------

nested_unavailable() {
  local reason="$1"
  if [[ "$require_nested" == true ]]; then
    fail "isolated runtime check unavailable: $reason"
  else
    note "isolated runtime check skipped: $reason"
  fi
  cat >&2 <<EOF
qml-smoke: a runtime check must run inside its own compositor. Safe options:
qml-smoke:   1. install a nested compositor (Hyprland is enough) and re-run with --nested
qml-smoke:   2. validate on a spare TTY/VM session that has no live VGS shell
qml-smoke:   3. read the live shell's own QML errors: vshell logs -n 200
qml-smoke: never run 'qs -c vshell' or 'qs -p quickshell/vshell' in a live session.
EOF
}

host_wayland_socket() {
  local display="${WAYLAND_DISPLAY:-}"
  [[ -n "$display" ]] || return 1
  [[ "$display" == /* ]] && { printf '%s\n' "$display"; return 0; }
  printf '%s/%s\n' "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set}" "$display"
}

nested_check() {
  local host_socket sandbox rt_dir conf log nested_socket candidate waited exit_code findings
  local compositor_pgid qs_launcher qs_group loaded targets plugins_loaded plugin_report candidate
  local -a expected_plugins=() missing_plugins=()
  local -a sandbox_env=() dbus_wrapper=()

  command -v Hyprland >/dev/null 2>&1 || { nested_unavailable "Hyprland not installed"; return; }
  command -v qs >/dev/null 2>&1 || { nested_unavailable "quickshell (qs) not installed"; return; }
  if ! host_socket="$(host_wayland_socket)" || [[ ! -S "$host_socket" ]]; then
    # Without a host Wayland socket a nested compositor would fall back to DRM
    # and fight the real session for the GPU/VT. Refuse rather than risk it.
    nested_unavailable "no host Wayland socket to nest inside (WAYLAND_DISPLAY unset)"
    return
  fi

  sandbox="$(mktemp -d -t vshell-smoke.XXXXXX)"
  track_dir "$sandbox"
  # Hyprland's IPC socket path is XDG_RUNTIME_DIR + a 60-char instance
  # signature; keep the runtime dir short or it exceeds sun_path.
  rt_dir="${XDG_RUNTIME_DIR:?}/vs.$$"
  rm -rf -- "$rt_dir"
  mkdir -p -- "$rt_dir"
  chmod 700 -- "$rt_dir"
  track_dir "$rt_dir"

  mkdir -p "$sandbox/home/.config" "$sandbox/home/.local/share" "$sandbox/home/.local/state" "$sandbox/home/.cache"
  # Seed a realistic (but throwaway) copy of user state so the smoke exercises
  # the real theme/settings paths without any chance of writing to live state.
  if [[ -d "$HOME/.config/vshell" ]]; then
    cp -a -- "$HOME/.config/vshell" "$sandbox/home/.config/vshell"
  fi

  conf="$sandbox/hyprland.conf"
  cat >"$conf" <<'EOF'
# Minimal throwaway config: no autostart, no user includes, no keybinds.
monitor = , preferred, auto, 1
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
    force_default_wallpaper = 0
    disable_autoreload = true
}
animations {
    enabled = false
}
EOF

  log="$sandbox/qs.log"

  # env -i: nothing from the live session leaks in. No VGS_SOCKET (the
  # sandboxed shell must not reach the live backend daemon), no
  # HYPRLAND_INSTANCE_SIGNATURE (hyprctl resolves to the nested compositor in
  # $rt_dir, never the live one), no DBUS_SESSION_BUS_ADDRESS (a private bus is
  # provided below instead of the live one).
  sandbox_env=(
    env -i
    HOME="$sandbox/home"
    PATH="$PATH"
    USER="${USER:-$(id -un)}"
    LOGNAME="${LOGNAME:-${USER:-$(id -un)}}"
    TERM="${TERM:-dumb}"
    XDG_RUNTIME_DIR="$rt_dir"
    XDG_CONFIG_HOME="$sandbox/home/.config"
    XDG_DATA_HOME="$sandbox/home/.local/share"
    XDG_STATE_HOME="$sandbox/home/.local/state"
    XDG_CACHE_HOME="$sandbox/home/.cache"
  )
  if command -v dbus-run-session >/dev/null 2>&1; then
    dbus_wrapper=(dbus-run-session --)
  else
    dbus_wrapper=()
    sandbox_env+=(DBUS_SESSION_BUS_ADDRESS="unix:path=$rt_dir/absent-bus")
  fi

  note "starting nested compositor sandbox (runtime dir $rt_dir)"
  if ! spawn_group "$sandbox/hyprland.pgid" \
    "${sandbox_env[@]}" WAYLAND_DISPLAY="$host_socket" \
    Hyprland --config "$conf" >"$sandbox/hyprland.log" 2>&1; then
    nested_unavailable "nested compositor failed to launch"
    return
  fi
  compositor_pgid="$spawn_pgid"

  nested_socket=""
  for waited in $(seq 1 $((compositor_timeout * 10))); do
    for candidate in "$rt_dir"/wayland-*; do
      [[ -S "$candidate" ]] || continue
      nested_socket="${candidate##*/}"
      break
    done
    [[ -n "$nested_socket" ]] && break
    kill -0 -- "-$compositor_pgid" 2>/dev/null || break
    sleep 0.1
  done

  if [[ -z "$nested_socket" ]]; then
    tail -n 20 "$sandbox/hyprland.log" >&2 || true
    nested_unavailable "nested compositor did not come up"
    return
  fi

  note "running the shell inside the sandbox (timeout ${nested_timeout}s)"
  if ! spawn_group "$sandbox/qs.pgid" \
    "${sandbox_env[@]}" \
    WAYLAND_DISPLAY="$nested_socket" \
    VSHELL_ROOT="$repo_root" \
    VSHELL_DISABLE_HOT_RELOAD=1 \
    "${dbus_wrapper[@]}" \
    timeout --signal=TERM --kill-after=5 "$nested_timeout" \
    qs --no-color -p "$repo_root/quickshell/vshell" >"$log" 2>&1; then
    fail "sandboxed shell failed to launch"
    return
  fi
  qs_launcher="$spawn_launcher_pid"
  qs_group="$spawn_pgid"

  # A live IPC target list is the proof that VGS itself came up: those handlers
  # only exist once the shell tree loaded. Waiting on the timeout instead would
  # also "pass" for a shell that exited immediately.
  loaded=false
  targets=""
  for waited in $(seq 1 $((nested_timeout * 2))); do
    targets="$("${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" --any-display show 2>/dev/null || true)"
    if printf '%s\n' "$targets" | grep -q '^target '; then
      loaded=true
      break
    fi
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.5
  done

  # Bundled plugins load asynchronously, several seconds after the core targets
  # answer. Stopping at the first core target ends observation before any plugin
  # QML has run, so plugin load failures, duplicate IpcHandler registrations and
  # broken entry points were invisible here — and passed as full coverage.
  #
  # EVERY bundled plugin, not one of them. Waiting on a single plugin's IPC
  # target proved only that plugin loaded: the seven load through independent
  # asynchronous FileViews with no ordering guarantee, so six could still be
  # pending when the shell was killed, and their QML was never observed while
  # the run reported full plugin coverage. That is the original VGS-19 defect
  # wearing a different hat.
  #
  # The expected set is derived from the tree rather than hardcoded, so adding a
  # bundled plugin extends this check automatically instead of silently not
  # covering the new one.
  mapfile -t expected_plugins < <(
    find "$repo_root/config/vshell/plugins" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort
  )
  if [[ ${#expected_plugins[@]} -eq 0 ]]; then
    fail "no bundled plugins found under config/vshell/plugins"
    return
  fi

  plugins_loaded=false
  plugin_report=""
  if [[ "$loaded" == true ]]; then
    for waited in $(seq 1 $((plugin_timeout * 2))); do
      # `plugins list` reports one line per plugin as "<id> [loaded|disabled]",
      # which is the only view that distinguishes "not scanned yet" from
      # "scanned and failed to load".
      plugin_report="$("${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" \
        --any-display call plugins list 2>/dev/null || true)"
      missing_plugins=()
      for candidate in "${expected_plugins[@]}"; do
        printf '%s\n' "$plugin_report" | grep -q "^${candidate} \[loaded\]\$" || missing_plugins+=("$candidate")
      done
      if [[ ${#missing_plugins[@]} -eq 0 ]]; then
        plugins_loaded=true
        break
      fi
      kill -0 -- "-$qs_group" 2>/dev/null || break
      sleep 0.5
    done
  fi

  kill_pgid "$qs_group"
  exit_code=0
  wait "$qs_launcher" || exit_code=$?

  if grep -q "refusing to start a duplicate shell" "$log"; then
    fail "the duplicate-instance guard misfired inside the sandbox"
    return
  fi
  if [[ "$loaded" != true ]]; then
    tail -n 40 "$log" >&2 || true
    fail "sandboxed shell never exposed its IPC targets (exit code $exit_code)"
    return
  fi
  if [[ "$plugins_loaded" != true ]]; then
    printf 'qml-smoke: plugins list reported:\n%s\n' "${plugin_report:-<no response>}" >&2
    fail "bundled plugins not loaded in the sandbox within ${plugin_timeout}s: ${missing_plugins[*]} (of ${#expected_plugins[@]} under config/vshell/plugins)"
    return
  fi

  # Services the sandbox deliberately cannot reach (the live PipeWire socket
  # lives in the session's runtime dir, and the private bus has no peers) are
  # environment gaps, not QML defects.
  local sandbox_noise='quickshell\.service\.pipewire|Failed to connect pipewire'
  # Error classes, each verified against a paired positive/negative control:
  #   ReferenceError  undefined identifier in a binding or handler body
  #   TypeError       property/method access on undefined, calling a non-function
  #   SyntaxError     JS parse failure inside a .js import or a handler body
  # These are prefixed by the QML file path, not by 'ERROR', so the leading
  # anchor below never saw them.
  #
  # Deliberately NOT matched:
  #   'Binding loop detected'  a warning, benign in several existing surfaces,
  #                            and it would make the gate noisy rather than
  #                            catching a class of defect the shell cannot run
  #                            through.
  #   bare 'Error:'            over-matches process output and third-party
  #                            library chatter (ffmpeg, dbus) piped into the log.
  local error_classes='ReferenceError|TypeError|SyntaxError'
  # `|| true` here would treat a MISSING or unreadable log exactly like a clean
  # one: grep exits 1 for "no match" and 2 for "could not read the file", and
  # collapsing both into an empty result reports success over a log that was
  # never scanned. Distinguish them.
  local grep_rc=0
  findings="$(grep -nE "^[[:space:]]*ERROR|is not a type|Cannot assign|Unable to assign|Failed to start process|Type .* unavailable|$error_classes" "$log")" || grep_rc=$?
  if [[ "$grep_rc" -gt 1 ]]; then
    fail "could not scan the sandbox log for runtime errors (grep exit $grep_rc, log '$log')"
    return
  fi
  findings="$(printf '%s\n' "$findings" | grep -vE "$sandbox_noise")" || grep_rc=$?
  if [[ "$grep_rc" -gt 1 ]]; then
    fail "could not filter sandbox noise out of the runtime findings (grep exit $grep_rc)"
    return
  fi
  if [[ -n "$findings" ]]; then
    printf '%s\n' "$findings" >&2
    fail "QML/runtime errors in the sandboxed shell"
    return
  fi
  note "isolated runtime check passed (shell loaded, all ${#expected_plugins[@]} bundled plugins loaded, answered IPC in the sandbox)"
}

# --- run --------------------------------------------------------------------

static_check
if [[ "$nested" == true ]]; then
  nested_check
else
  note "runtime check not requested (pass --nested for the sandboxed shell run)"
fi

if [[ "$status" -eq 0 ]]; then
  if [[ "$static_ran" == false && "$nested" == false ]]; then
    note "nothing was checked (no qmllint, and --nested was not requested)"
  else
    note "ok"
  fi
fi
exit "$status"
