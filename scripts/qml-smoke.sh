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
# The sandbox's HOME is built from the repo alone — nothing is read out of
# `~/.config/vshell`, so no run's outcome can depend on the operator's VGS
# configuration (docs/decisions/D008-nested-sandbox-state-seeding.md; the
# machine still supplies the compositor and the installed binaries). A phase
# asserts the seed is in EFFECT by reading sentinels back out of the running
# shell (VGS-92), gating the popout and override phases below. Theme state is
# deliberately OUT OF SCOPE (D008 § Scope). No failure withholds its own
# evidence: from teardown on, every diagnostic precedes every verdict, and of
# the two failures that can end a run earlier, the launch failure prints the log
# tail and "no bundled plugins in the repo" has no log evidence to print.
#
# It then drives two things that loading alone never reaches (VGS-81):
#
#   * a plugin POPOUT is opened through `widget toggle` and dismissed with
#     Escape, because everything inside popoutContent is only instantiated when
#     the popout opens — the extracted meter delegates and the in-surface pager
#     had never been executed by anything. A ReferenceError in that content
#     passes a full nested run with the popout closed. The surface's SIZE is not
#     treated as evidence about the content; see the note above popout_check.
#   * a user OVERRIDE of a bundled id is planted in the sandbox's own HOME and
#     put through scan, rescan, reload and removal, asserting on markers only
#     the override's own component can emit. "The load succeeded" is not
#     evidence here: the VGS-75 defect reported PLUGIN_RELOAD_SUCCESS and logged
#     a clean "Plugin loaded" for what was really the bundled copy.
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
  local pidfile="$1" launcher
  shift
  rm -f -- "$pidfile"
  # shellcheck disable=SC2016  # $$ and "$@" must expand in the inner sh, not here
  setsid --wait sh -c 'echo $$ >"$1"; shift; exec "$@"' _ "$pidfile" "$@" &
  launcher=$!
  spawn_launcher_pid="$launcher"
  spawn_pgid=""
  for _ in $(seq 1 100); do
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
  local pgid="$1"
  kill -0 -- "-$pgid" 2>/dev/null || return 0
  kill -TERM -- "-$pgid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 -- "-$pgid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL -- "-$pgid" 2>/dev/null || true
}

# A signal handler inherits $? from whatever finished last, which is usually 0,
# so an interrupted run would otherwise report success to CI.
# shellcheck disable=SC2329  # invoked via the trap registrations below
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

# shellcheck disable=SC2329  # called from cleanup(), which only the traps reach
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

# nested_unavailable <reason> [no-host-socket]
#
# The second argument is what makes option 4 appear, and it is an ARGUMENT
# rather than a test of the environment on purpose. This function has six call
# sites and only one of them is the missing-host-socket case; the Hyprland, qs
# and python3 preconditions are checked first, so a headless agent shell hits
# those with WAYLAND_DISPLAY equally unset. Gating on WAYLAND_DISPLAY offered
# "point the sandbox at the session socket" as the fix for a missing Hyprland
# binary — the same keying-on-a-proxy defect that moving this remedy out of
# scripts/validate was meant to end. Only the call site that knows the cause
# passes the flag, and a reword of the reason string cannot break it.
nested_unavailable() {
  local reason="$1" cause="${2:-}"
  if [[ "$require_nested" == true ]]; then
    fail "isolated runtime check unavailable: $reason"
  else
    note "isolated runtime check skipped: $reason"
  fi
  # The WAYLAND_DISPLAY test stays as a SECONDARY guard: with one set, pointing
  # the sandbox at "the session socket" is not the advice the reader needs.
  local nest_remedy=""
  if [[ "$cause" == no-host-socket && -z "${WAYLAND_DISPLAY:-}" ]]; then
    nest_remedy="qml-smoke:   4. point the sandbox at the session's own socket (it keeps its own runtime
qml-smoke:      dir, HOME and bus, so the live session is untouched). Use the value
qml-smoke:      a session shell reports for WAYLAND_DISPLAY — the basename is
qml-smoke:      session-dependent, so this cannot name it for you (VGS-70 will make
qml-smoke:      --nested discover it). Export WAYLAND_DISPLAY to that value and
qml-smoke:      XDG_RUNTIME_DIR to /run/user/\$(id -u), then re-run scripts/validate qml"
  fi
  cat >&2 <<EOF
qml-smoke: a runtime check must run inside its own compositor. Safe options:
qml-smoke:   1. install a nested compositor (Hyprland is enough) and re-run with --nested
qml-smoke:   2. validate on a spare TTY/VM session that has no live VGS shell
qml-smoke:   3. read the live shell's own QML errors: vshell logs -n 200
${nest_remedy:+$nest_remedy
}qml-smoke: never run 'qs -c vshell' or 'qs -p quickshell/vshell' in a live session.
EOF
}

host_wayland_socket() {
  local display="${WAYLAND_DISPLAY:-}"
  [[ -n "$display" ]] || return 1
  [[ "$display" == /* ]] && { printf '%s\n' "$display"; return 0; }
  printf '%s/%s\n' "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set}" "$display"
}

# --- plugin phases run inside the sandbox -----------------------------------
# Both read `sandbox_env`, `repo_root`, `sandbox`, `log` and `qs_group` from
# nested_check; bash scopes dynamically, so they are visible here.
#
# `popout_namespace`, `popout_plugin` and `override_plugin` are defined once,
# below `wait_layer_state`, next to the evidence that picked them.

sandbox_ipc() {
  "${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" --any-display call "$@" 2>&1 || true
}

# `hyprctl -i 0` resolves to the NESTED compositor: sandbox_env is built with
# `env -i`, so no HYPRLAND_INSTANCE_SIGNATURE from the live session leaks in and
# XDG_RUNTIME_DIR points at the sandbox's own runtime dir.
# The exit status is PROPAGATED. Swallowing it with `|| true` fed an empty
# string to the parser, which then reported "no such surface" — a failed query
# becoming a negative answer, which is the defect this harness exists to refuse.
sandbox_layers() {
  "${sandbox_env[@]}" hyprctl -i 0 layers -j 2>/dev/null
}

# The OUTPUTS, so their size is measured rather than inferred. Same status
# propagation as sandbox_layers, and for the same reason.
sandbox_monitors() {
  "${sandbox_env[@]}" hyprctl -i 0 monitors -j 2>/dev/null
}

# THE OUTPUT SIZE IS MEASURED, NOT INFERRED.
#
# This used to take the largest OTHER layer on the monitor as a proxy for the
# output, which is wrong in three ways at once and they are one defect, not
# three: with no other layer the proxy was 0x0 and every comparison ran against
# zero; with only small layers (the bar is full WIDTH but ~32px tall) the proxy
# was simply the wrong number; and either way the verdict - pass or fail - was
# reached against a figure the compositor never reported. Patching the empty
# case alone leaves the wrong-number case, and patching both leaves the fact
# that a proxy was being asserted at all.
#
# `hyprctl monitors` reports it directly. Its `width`/`height` are the MODE, in
# physical pixels, while layer geometry is LOGICAL, so the two are not
# comparable raw - but the conversion is exact, not a guess: logical = mode /
# scale, with width and height swapped for the quarter-turn transforms (1, 3, 5,
# 7). Verified against a live two-monitor session: 6016x3384 @ scale 2,
# transform 0 -> 3008x1692, and 5120x2880 @ scale 2, transform 1 -> 1440x2560,
# both matching the full-output layers on those monitors exactly.
#
# 0 = a non-degenerate surface with that namespace exists, measured against its
#     own output. NOT "content-sized": every popout is output-tall since VGS-133.
# 1 = absent
# 2 = present but degenerate (zero-sized, or as large as the output)
# 3 = A QUERY FAILED - hyprctl errored or produced something unparsable.
#     Distinct from 1 deliberately: "I could not look" is not "it is not there".
# 4 = present, but its output's size is unavailable, so there is nothing to
#     grade it against. Distinct from 2 for the reason 3 is distinct from 1:
#     "I could not measure it" is not "it measured wrong". Never a fallback to
#     zero and never a fallback to a proxy - an unmeasurable output is a hard
#     failure naming the cause.
# 5 = mapped more than once. A popout binds to exactly ONE screen
#     (VgsPopoutStandalone `screen: root.screen`, from PluginPopout's
#     `triggerScreen`), and both its windows follow it, so a second surface is a
#     duplicate-mapping defect, not a reply to be averaged over.
#
# EXACTLY ONE LINE, "<w>x<h> <screen_w>x<screen_h>". The old contract was one
# line per matching layer per monitor, which contradicted the single consumer
# that parsed it; the emitter is what was wrong, because the thing it describes
# can only exist once. Callers must branch on the status BEFORE reading the
# text: on 1, 2, 3, 4 and 5 it is absent or misleading.
sandbox_layer_state() {
  local namespace="$1" layers monitors rc=0
  layers="$(sandbox_layers)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return 3
  fi
  monitors="$(sandbox_monitors)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return 3
  fi
  MONITORS_JSON="$monitors" LAYERS_JSON="$layers" python3 - "$namespace" <<'PY'
import json
import math
import os
import sys

namespace = sys.argv[1]


def main():
    def parsed(name):
        raw = os.environ[name]
        if not raw.strip():
            raise SystemExit(3)
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            raise SystemExit(3)


    data = parsed("LAYERS_JSON")
    if not isinstance(data, dict):
        raise SystemExit(3)
    monitors = parsed("MONITORS_JSON")
    if not isinstance(monitors, list):
        raise SystemExit(3)

    # Logical output size per monitor name. `width`/`height` are the MODE in
    # physical pixels; layer geometry is logical, so the mode is divided by the
    # scale, and the quarter-turn transforms (1, 3, 5, 7) swap the axes. A monitor
    # whose numbers do not survive that conversion is left OUT of the map rather
    # than entered with a zero: absent means "unmeasurable" below, and a zero would
    # be the proxy problem again in a new costume.
    outputs = {}
    for monitor in monitors:
        if not isinstance(monitor, dict) or monitor.get("disabled"):
            continue
        name = monitor.get("name")
        # EVERY arithmetic step is inside the guard, and the guard rejects values
        # that are merely WELL-TYPED. A NaN scale survives `float()` and survives
        # `scale <= 0` (every comparison with NaN is False), then reaches
        # `int(round(mode_w / scale))` and raises ValueError from OUTSIDE any
        # handler - which exits this interpreter 1, and 1 is the caller's code for
        # "the surface is not there". Malformed metadata would have read as absence:
        # a present popout reported as gone, and a `wait_layer_state ... 1` proving
        # absence off a crash. An unusable monitor is left OUT of the map instead,
        # so the join below misses and the caller gets the "cannot measure" status.
        try:
            mode_w = int(monitor.get("width") or 0)
            mode_h = int(monitor.get("height") or 0)
            scale = float(monitor.get("scale") or 0)
            transform = int(monitor.get("transform") or 0)
            if not (math.isfinite(scale) and scale > 0):
                continue
            if not name or mode_w <= 0 or mode_h <= 0:
                continue
            # Hyprland's transform enum is 0-7; anything else means the axes cannot
            # be resolved, and guessing "no swap" would measure against the wrong
            # dimensions rather than admit that.
            if transform not in range(8):
                continue
            logical_w = int(round(mode_w / scale))
            logical_h = int(round(mode_h / scale))
        except (TypeError, ValueError, OverflowError, ZeroDivisionError):
            continue
        if transform in (1, 3, 5, 7):
            logical_w, logical_h = logical_h, logical_w
        if logical_w <= 0 or logical_h <= 0:
            continue
        outputs[name] = (logical_w, logical_h)

    # STRUCTURE IS VALIDATED, AND A SURPRISE IS A QUERY FAILURE, NEVER AN ABSENCE.
    # `hyprctl` returning parseable JSON says nothing about its SHAPE. A `levels`
    # that is a list, a monitor entry that is a string, a layer that is not an
    # object - each of those raises out of `.values()`, `extend()` or `.get()`, and
    # an uncaught exception exits this interpreter 1, which is the caller's code for
    # "the surface is not there". `wait_layer_state ... 1` would then succeed off a
    # crash and the nested smoke would report clean having collected nothing. Same
    # defect the monitor parse above had; this is the other half of it.
    def _shape_error(what):
        sys.stderr.write(
            "sandbox_layer_state: `hyprctl layers -j` parsed as JSON but %s, so no layer data was "
            "collected - that is a failed query, not an absent surface\n" % what
        )
        raise SystemExit(3)


    matches = []
    collected = 0
    for monitor_name, monitor in data.items():
        if not isinstance(monitor, dict):
            _shape_error("monitor %r is not an object" % monitor_name)
        levels = monitor.get("levels")
        # NOT defaulted to {}. A monitor with no layers still reports `levels: {}`,
        # so a missing or null one is a malformed payload - and defaulting it made
        # the namespace "not found", which is status 1, which is ABSENCE. That is
        # the same fail-open one layer up from the shapes below.
        if not isinstance(levels, dict):
            _shape_error("monitor %r has a missing or non-object `levels`" % monitor_name)
        layers = []
        for level_name, level in levels.items():
            if not isinstance(level, list):
                _shape_error("monitor %r level %r is not a list" % (monitor_name, level_name))
            layers.extend(level)
        for layer in layers:
            if not isinstance(layer, dict):
                _shape_error("monitor %r holds a layer that is not an object" % monitor_name)
            collected += 1
            if layer.get("namespace") == namespace:
                matches.append((monitor_name, layer))

    # THE COLLECTION STEP ASSERTS IT COLLECTED SOMETHING.
    # `{}`, or monitors whose levels are all empty, is well-formed at every level
    # the shape checks look at - so it slid past them and left `matches` empty,
    # which is status 1, ABSENCE. Both `wait_layer_state ... 1` calls in
    # popout_check would then succeed having observed not one layer, INCLUDING
    # the bar, which is always mapped by the time they run. An empty read is a
    # failure of the check, never a clean result
    # (.github/instructions/validation-scripts.instructions.md).
    if collected == 0:
        _shape_error("it reported no layers at all across %d monitor(s)" % len(data))

    if not matches:
        raise SystemExit(1)

    # A popout binds to exactly one screen, so a second surface is a duplicate, not
    # a second reading to reconcile. Reported rather than collapsed: picking one of
    # them would hide the defect, and averaging them would invent a number.
    if len(matches) > 1:
        sys.stderr.write(
            "sandbox_layer_state: %s is mapped %d times (%s), but a popout binds to exactly "
            "one screen - that is a duplicate-mapping defect, not a geometry reading\n"
            % (namespace, len(matches), ", ".join(name for name, _ in matches))
        )
        raise SystemExit(5)

    monitor_name, layer = matches[0]
    if monitor_name not in outputs:
        sys.stderr.write(
            "sandbox_layer_state: %s is mapped on monitor %s, but `hyprctl monitors` reports "
            "no usable size for it, so there is nothing to measure it against - that is not "
            "evidence about its geometry\n" % (namespace, monitor_name)
        )
        raise SystemExit(4)

    screen_w, screen_h = outputs[monitor_name]
    try:
        w = int(layer.get("w") or 0)
        h = int(layer.get("h") or 0)
    except (TypeError, ValueError, OverflowError):
        _shape_error("the matched layer has a non-numeric size")
    print("%dx%d %dx%d" % (w, h, screen_w, screen_h))
    if w <= 0 or h <= 0:
        raise SystemExit(2)
    # Unguarded, because the output size is measured by the time it runs. A popout
    # that covers the whole output is a layout failure, not an open popout.
    if w >= screen_w and h >= screen_h:
        raise SystemExit(2)
    raise SystemExit(0)


# Every deliberate outcome above is a SystemExit, which is a BaseException and
# passes straight through this. Anything else - a shape nobody predicted, a
# conversion nobody guarded - is a failed query, NEVER an absent surface. That
# is the invariant; the explicit checks above only exist to name the cause.
try:
    main()
except Exception as exc:
    sys.stderr.write(
        "sandbox_layer_state: unexpected %s reading the compositor payloads (%s) - "
        "no usable layer data was collected, so this is a failed query, not an absent "
        "surface\n" % (type(exc).__name__, exc)
    )
    raise SystemExit(3)

PY
}

# Waits for a state, and fails LOUDLY on a query error rather than spinning to
# the timeout and then reporting the wrong thing.
wait_layer_state() {
  local namespace="$1" want="$2" state=1
  for _ in $(seq 1 30); do
    state=0
    sandbox_layer_state "$namespace" >/dev/null || state=$?
    if [[ "$state" -eq 3 ]]; then
      fail "could not read the sandbox compositor's layer list (hyprctl query failed) - that is not evidence '$namespace' is absent"
      return 2
    fi
    # Also terminal, and for the same reason: retrying cannot turn "this output
    # has no reported size" or "it is mapped twice" into the wanted state, so
    # spinning to the timeout would report either as the state never arriving.
    if [[ "$state" -eq 4 ]]; then
      fail "'$namespace' is mapped on an output whose size hyprctl does not report - that is not evidence about its geometry"
      return 2
    fi
    if [[ "$state" -eq 5 ]]; then
      fail "'$namespace' is mapped on more than one output, but a popout binds to exactly one screen - that is a duplicate-mapping defect"
      return 2
    fi
    [[ "$state" == "$want" ]] && return 0
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.2
  done
  return 1
}

# WHAT THE POPOUT CHECK WITNESSES, AND WHAT IT DOES NOT.
#
# It opens a plugin popout and asserts a `vshell:plugins:plugin` layer surface
# appears where there was none, is not degenerate, and goes away again on
# Escape. That proves the popout was created, mapped and dismissed.
#
# It does NOT prove `popoutContent` rendered correctly, and the surface's SIZE
# is not evidence that it did. That was measured rather than assumed: a fixture
# plugin was planted with three different content shapes (a bare `Item`, a
# `Column`, a `Rectangle`) at two declared heights (140px and 340px), and all
# six combinations settled to an identical 573px surface. Since VGS-133 the
# surface is the output height for every popout, so "the surface is
# content-sized" would now measure the OUTPUT and before that it measured the
# popout chrome. Either way, not the content.
#
# Two things DO witness the content, and both are already load-bearing here:
#
#   * a plugin with no `popoutContent` produces NO surface at all, so the
#     presence assertion below fails (proven by mutation);
#   * a ReferenceError inside `popoutContent` reaches the log scan at the end of
#     nested_check, and that error class is only reachable because the popout is
#     opened — the same defect passes a full nested run with the popout closed
#     (proven by mutation).
#
# Navigating the pager would be a third and better witness, but it needs a
# pointer click on the gear affordance. `wtype` is keyboard-only and
# `hyprctl dispatch` cannot address a layer surface, so there is no pointer
# route from here; that is a real gap, not an oversight.
popout_namespace="vshell:plugins:plugin"
# aiUsage, because its popoutContent is the code with no coverage at all: the
# extracted MeterRow/MeterCard delegates and the in-surface pager (VGS-72/73)
# live entirely inside it, and it is only instantiated when the popout opens.
popout_plugin="aiUsage"
# A different bundled id for the override phase, so the two cannot mask each
# other. It has to be one the shipped bar layout hosts - a plugin no bar hosts
# never instantiates its component, and the marker below would never fire.
override_plugin="tailscale"

# --- the seeded settings are in effect (VGS-92, D008 rule 4) ----------------
#
# Why a sentinel rather than any seeded value: D008 § Rationale. Each seeded
# file carries one matching neither the shipped file nor the fallback used
# without it, read back out of the RUNNING shell. Both carriers are inert:
# `customAnimationDuration` is read only when `animationSpeed` selects Custom
# (Common/MethodTheme.qml), and `sysUpdate.aurUpdateCommand` runs only on a
# user-initiated update.
settings_sentinel_key="customAnimationDuration"
settings_sentinel_value=4242
plugin_sentinel_plugin="sysUpdate"
plugin_sentinel_key="aurUpdateCommand"
plugin_sentinel_value="{vshell} update run aur --vgs92-seed-sentinel"

# EXACT matchers, never substring: `*4242*` would accept 14242, and searching
# the whole `pluginSettings` blob for a `"key":"value"` pair would accept it
# under the wrong section. Both are the pass-without-checking shape this branch
# removes. Each takes the reply as $1.
# shellcheck disable=SC2329  # invoked by name through await_sentinel's $matcher
sentinel_is_exactly() { [[ "$1" == "$2" ]]; }

# reply, plugin, key, value. An unparsable reply is a miss, not an error: the
# poll may simply have caught the shell mid-answer.
# shellcheck disable=SC2329  # invoked by name through await_sentinel's $matcher
sentinel_at_path() {
  python3 -c 'import json, sys
try: data = json.loads(sys.argv[1])
except ValueError: sys.exit(1)
section = data.get(sys.argv[2])
sys.exit(0 if isinstance(section, dict) and section.get(sys.argv[3]) == sys.argv[4] else 1)' "$@"
}

# Polls `settings get $key` until `$matcher` accepts the reply; bounded, because
# SettingsData loads asynchronously. Prints the last reply a call returned, and
# never folds one failure reason into another - misattribution is what this
# split exists to prevent:
#   1 = answered a real value, the matcher rejected it -> the seed
#   2 = process group gone, or nothing answered        -> a dead shell, saying
#                                                         nothing about the seed
#   3 = answered `undefined`, or answered empty        -> the KEY is gone from
#       SettingsData, so the sentinel needs repointing. VGSIPC's `get` is
#       JSON.stringify(SettingsData?.[key]), so a rename exits 0 and would
#       otherwise read as 1. The caller reports the two separately.
await_sentinel() {
  local key="$1" matcher="$2"
  shift 2
  local reply="" last_good="" answered=false gone=false
  for _ in $(seq 1 40); do
    # NOT `sandbox_ipc`: that folds stderr into stdout and ends in `|| true`, so
    # a transport failure would arrive as a reply and be blamed on the seed.
    if reply="$("${sandbox_env[@]}" qs ipc -p "$repo_root/quickshell/vshell" \
        --any-display call settings get "$key" 2>/dev/null)"; then
      answered=true
      last_good="$reply"
      "$matcher" "$reply" "$@" && { printf '%s' "$reply"; return 0; }
    fi
    # Liveness decides state 2, NOT whether the final attempt happened to
    # answer: a shell that answered the wrong value all window and missed only
    # the last call is a seed failure, not a dead shell.
    if ! kill -0 -- "-$qs_group" 2>/dev/null; then
      gone=true
      break
    fi
    sleep 0.25
  done
  printf '%s' "$last_good"
  { [[ "$gone" == true ]] || [[ "$answered" != true ]]; } && return 2
  { [[ -z "$last_good" ]] || [[ "$last_good" == "undefined" ]]; } && return 3
  return 1
}

# One probe: the IPC key, a human-readable statement of what the matcher demands
# (printed on failure, so the message and the assertion say the same thing),
# then the matcher and its arguments.
seed_probe() {
  local key="$1" want="$2" reply state=0
  shift 2
  reply="$(await_sentinel "$key" "$@")" || state=$?
  case "$state" in
    0) return 0 ;;
    2)
      # Whatever it managed to say is kept: the best evidence about a shell that
      # then died.
      # shellcheck disable=SC2016  # the quotes inside ${reply:+...} are literal text; $reply does expand
      fail "the sandboxed shell stopped answering \`settings get $key\` - the shell or its IPC is gone, so nothing was learned about the seed${reply:+ (last reply: '$reply')}" ;;
    3)
      if [[ "$reply" == "undefined" ]]; then
        fail "'$key' is not a SettingsData property any more - the SENTINEL needs repointing, and this says nothing about the seed"
      else
        fail "\`settings get $key\` answered nothing - VGSIPC returns JSON for any live property, so this is a change in the IPC itself, not a seed failure"
      fi ;;
    *)
      fail "the sandboxed shell is NOT running on the state it seeded: \`settings get $key\` answered '$reply', and the sandbox stamped $want (VGS-92, D008)" ;;
  esac
  return 1
}

seeded_settings_check() {
  seed_probe "$settings_sentinel_key" "$settings_sentinel_value" \
    sentinel_is_exactly "$settings_sentinel_value" || return 1
  seed_probe pluginSettings "$plugin_sentinel_plugin.$plugin_sentinel_key=$plugin_sentinel_value" \
    sentinel_at_path "$plugin_sentinel_plugin" "$plugin_sentinel_key" "$plugin_sentinel_value" || return 1

  note "seeded settings check passed (the running shell reports both sandbox sentinels: $settings_sentinel_key and $plugin_sentinel_plugin.$plugin_sentinel_key)"
  return 0
}

# Plugin widgets are registered with BarWidgetService by the bar's WidgetHost,
# which mounts them some time AFTER the plugin itself reports loaded. A single
# read here failed about one run in eight with WIDGET_NOT_FOUND.
wait_widget_registered() {
  local widget="$1" reply=""
  for _ in $(seq 1 60); do
    reply="$(sandbox_ipc widget list)"
    printf '%s\n' "$reply" | grep -q "^${widget}\b" && return 0
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.25
  done
  # shellcheck disable=SC2016  # the backticks are literal quoting in the message
  printf 'qml-smoke: `widget list` reported:\n%s\n' "$reply" >&2
  return 1
}

# Asserts the VGS-133 height invariant on the ONE line sandbox_layer_state
# emits. The emitter used to promise one line per matching layer per monitor
# while this consumer rejected anything multi-line - a function and its own
# contract disagreeing. The emitter was the wrong half: a popout binds to
# exactly one screen, so the thing being described can only exist once, and a
# second surface is now the emitter's own status 5 rather than an extra line to
# parse here. Fixing it on this side instead would have papered over a
# duplicate-mapping defect by quietly accepting it as normal output.
#
# An empty reply is a FAILURE, not a pass: the caller reached here only because
# the surface was reported present, so no geometry to check means the evidence
# went missing, and passing on no evidence is the shape this file exists to
# refuse (VGS-154).
assert_popout_geometry() {
  local geometry="$1" label="$2" surface_size screen_size
  if [[ -z "${geometry//[[:space:]]/}" ]]; then
    fail "no layer geometry to check for '$label', though its surface was reported present - refusing to pass on no evidence"
    return 1
  fi
  # Shape-guarded before splitting, because `${g%% *}` and `${g##* }` both
  # return the WHOLE string when it holds no space: a single field would compare
  # equal to itself and pass vacuously. The `$` anchor also rejects a multi-line
  # reply, which now means the emitter broke its own one-line contract - a
  # reason to stop, not to start parsing lines.
  if [[ ! "$geometry" =~ ^[0-9]+x[0-9]+\ [0-9]+x[0-9]+$ ]]; then
    fail "could not parse the '$label' layer geometry: '$geometry'"
    return 1
  fi
  surface_size="${geometry%% *}"
  screen_size="${geometry##* }"
  if [[ "${surface_size#*x}" != "${screen_size#*x}" ]]; then
    fail "'$label' popout surface is '$surface_size' on a '$screen_size' output - it must span the output height (VGS-133)"
    return 1
  fi
  return 0
}

popout_check() {
  local reply state=0 geometry geo_rc

  wait_widget_registered "$popout_plugin" || {
    fail "the sandbox bar never registered '$popout_plugin', so its popout could not be opened - the seeded settings.default.json is supposed to host it"
    return 1
  }

  # Start from a known state: no popout surface open. Without this, a surface
  # left over from something else would satisfy the assertion below.
  if ! wait_layer_state "$popout_namespace" 1; then
    fail "a plugin popout surface was already open before '$popout_plugin' was toggled"
    return 1
  fi

  reply="$(sandbox_ipc widget toggle "$popout_plugin")"
  if [[ "$reply" != "WIDGET_TOGGLE_SUCCESS: $popout_plugin" ]]; then
    fail "widget toggle $popout_plugin answered '$reply'"
    return 1
  fi

  # NOT "the call returned success" - that is what the old coverage would have
  # been. This waits for the compositor to show the surface.
  wait_layer_state "$popout_namespace" 0 || state=$?
  if [[ "$state" -ne 0 ]]; then
    sandbox_layer_state "$popout_namespace" >&2 || true
    if [[ "$state" -eq 2 ]]; then
      fail "'$popout_plugin' opened a degenerate popout surface (zero-sized or full-screen)"
    else
      fail "'$popout_plugin' popout never produced a '$popout_namespace' surface"
    fi
    return 1
  fi

  # VGS-133: the surface must span the OUTPUT height, not the content's, or a
  # resize re-commits wl_surface geometry every frame - the flash. Nothing else
  # here notices: a content-sized surface opens and closes the same way.
  #
  # The STATUS is the diagnosis, so it is captured, not discarded. Reporting a
  # failed query or a vanished surface as "wrong height" sends the next reader
  # after the wrong defect, and a degenerate 0x0 on a 0x0 output would pass a
  # bare height comparison outright.
  geometry="$(sandbox_layer_state "$popout_namespace")" && geo_rc=0 || geo_rc=$?
  case "$geo_rc" in
    3) fail "could not read the sandbox compositor's layer list (hyprctl query failed) - that is not evidence about the '$popout_plugin' popout's height"; return 1 ;;
    4) fail "'$popout_plugin' opened on an output whose size hyprctl does not report, so there is nothing to measure the popout against - that is not a height mismatch"; return 1 ;;
    5) fail "'$popout_plugin' is mapped on more than one output, but a popout binds to exactly one screen - that is a duplicate-mapping defect, not a height mismatch"; return 1 ;;
    1) fail "the '$popout_plugin' popout surface disappeared before its height could be read"; return 1 ;;
    2) fail "'$popout_plugin' opened a degenerate popout surface ($geometry) - that is not a height mismatch"; return 1 ;;
  esac
  assert_popout_geometry "$geometry" "$popout_plugin" || return 1

  # Escape, through the virtual-keyboard protocol. `hyprctl dispatch
  # sendshortcut` targets a WINDOW and answers "window not found" for a layer
  # surface, so it cannot reach a popout at all; wtype goes to whatever holds
  # keyboard focus, which is the popout's own focus grab.
  if command -v wtype >/dev/null 2>&1; then
    # The popout grabs keyboard focus asynchronously (PluginPopout defers
    # forceActiveFocus through Qt.callLater), so a key sent the instant the
    # surface appears can land before anything is listening for it.
    sleep 1.5
    "${sandbox_env[@]}" WAYLAND_DISPLAY="$nested_socket" wtype -k Escape >/dev/null 2>&1 || true
    if ! wait_layer_state "$popout_namespace" 1; then
      sandbox_layer_state "$popout_namespace" >&2 || true
      fail "Escape did not close the '$popout_plugin' popout"
      return 1
    fi
    note "plugin popout check passed ($popout_plugin opened a $popout_namespace surface and Escape closed it)"
  else
    # Named, never silent: a skip that reads as a pass is what this file exists
    # to prevent.
    note "NOT CHECKED: Escape-to-close - wtype is not installed"
    reply="$(sandbox_ipc widget toggle "$popout_plugin")"
    if [[ "$reply" != "WIDGET_TOGGLE_SUCCESS: $popout_plugin" ]]; then
      fail "closing the $popout_plugin popout answered '$reply'"
      return 1
    fi
    if ! wait_layer_state "$popout_namespace" 1; then
      fail "the '$popout_plugin' popout surface outlived its close"
      return 1
    fi
    note "plugin popout check passed ($popout_plugin opened a $popout_namespace surface and closed cleanly)"
  fi
  return 0
}

# How many times the override fixture's OWN component has been instantiated.
# This is the assertion the original VGS-75 defect defeats: it reported
# PLUGIN_RELOAD_SUCCESS and logged a clean "Plugin loaded" for what was really
# the bundled copy, so anything checking that a load *succeeded* passed
# throughout. Only the override's own QML can emit this.
override_marker_count() {
  grep -c "VGS81-OVERRIDE-LOADED-$override_nonce" "$log" 2>/dev/null || true
}

override_unloaded_count() {
  grep -c "VGS81-OVERRIDE-UNLOADED-$override_nonce" "$log" 2>/dev/null || true
}

wait_marker() {
  local counter="$1" want="$2" seen=0
  for _ in $(seq 1 60); do
    seen="$($counter)"
    [[ "$seen" -ge "$want" ]] && return 0
    kill -0 -- "-$qs_group" 2>/dev/null || break
    sleep 0.25
  done
  return 1
}

plugin_is_loaded() {
  sandbox_ipc plugins list | grep -q "^$1 \[loaded\]\$"
}

override_check() {
  local dir reply live loads teardowns loads_before teardowns_before
  local strays strays_dir strays_rc=0

  # HERE, not at sandbox prep, where nothing could have created one yet: by now
  # the shell has been running in that HOME. A second package under this id
  # would make "which copy loaded?" — the question this phase answers —
  # unanswerable. An empty `plugins/` directory is fine; a package is not.
  # Three states, not two: the directory is normally ABSENT, so a scan that
  # swallowed find's status would look identical on a healthy run and on "I
  # could not look" — the failed-query-reads-as-absence class this file has
  # already had three times. No `-printf` either; it is GNU-only, and a BSD
  # find would degrade the guard to an unconditional pass.
  strays_dir="$sandbox/home/.config/vshell/plugins"
  if [[ -d "$strays_dir" ]]; then
    strays="$(find "$strays_dir" -mindepth 1 -maxdepth 1 -type d)" || strays_rc=$?
    if [[ "${strays_rc:-0}" -ne 0 ]]; then
      fail "could not enumerate '$strays_dir' (find exit $strays_rc) — 'I could not look' is not 'nothing is there'"
      return 1
    fi
    if [[ -n "$strays" ]]; then
      fail "user plugin package(s) already in the sandbox before the override fixture was planted:"$'\n'"$strays"
      return 1
    fi
  fi

  dir="$sandbox/home/.config/vshell/plugins/$override_plugin"
  mkdir -p "$dir"
  # A fixture, not a copy of the bundled component: the marker has to come from
  # QML that only the override has, and authoring it here keeps a test-only
  # hook out of the shipped tree entirely. `overrides` is the opt-in that lets
  # a user package take a bundled id (VGS-26); requires_shell is satisfied, so
  # the version gate is not what is under test here.
  cat >"$dir/plugin.json" <<EOF
{
    "id": "$override_plugin",
    "name": "VGS-81 override fixture",
    "description": "Throwaway override planted by scripts/qml-smoke.sh inside its sandbox.",
    "version": "9.9.9",
    "license": "MIT",
    "author": "qml-smoke",
    "icon": "science",
    "component": "./Component.qml",
    "overrides": "$override_plugin",
    "requires_shell": ">=0.0.1"
}
EOF
  cat >"$dir/Component.qml" <<EOF
import QtQuick
import qs.Modules.Plugins

PluginComponent {
    id: root

    // Deliberately minimal, but with a pill of its own so a bar genuinely
    // hosts and instantiates it rather than merely compiling it.
    horizontalBarPill: Component {
        Rectangle {
            implicitWidth: 8
            implicitHeight: 8
            color: "transparent"
        }
    }
    Component.onCompleted: console.info("VGS81-OVERRIDE-LOADED-$override_nonce")
    Component.onDestruction: console.info("VGS81-OVERRIDE-UNLOADED-$override_nonce")
}
EOF

  reply="$(sandbox_ipc plugin-scan scan)"
  if [[ "$reply" != SCAN_TRIGGERED:* ]]; then
    fail "plugin-scan scan answered '$reply'"
    return 1
  fi
  if ! wait_marker override_marker_count 1; then
    fail "the planted override of '$override_plugin' never loaded its own component — a scan that reports success while the bundled copy stays installed is exactly the VGS-75 defect"
    return 1
  fi
  if ! override_state_settles 1; then
    return 1
  fi

  # A rescan re-reads every manifest claiming the id. It deliberately does NOT
  # assert a reload: when the record re-read for a path is the one already
  # installed, _relinkLoadedRecord hands it the registration and reloading
  # would be pointless work. Whether a reload happens depends on which manifest
  # the rescan reaches first, so counting loads here asserts an artefact — it
  # was observed failing about one run in five before this was corrected. What
  # must hold is the invariant: exactly one live instance of the override, and
  # the id owned.
  reply="$(sandbox_ipc plugin-scan rescan "$override_plugin")"
  if [[ "$reply" != RESCAN_TRIGGERED:* ]]; then
    fail "plugin-scan rescan answered '$reply'"
    return 1
  fi
  sleep 2
  if ! override_state_settles 1; then
    return 1
  fi

  # A reload IS a defined contract: unload, then load. This is the step VGS-75
  # was reproduced on — after a rescan, `unloadPlugin` cleared the flag on the
  # record in `loadedPlugins` while `loadPlugin` read the other record, which
  # still claimed `loaded`, and early-returned true having installed nothing.
  # Live, that produced two "Plugin unloaded" lines and no matching load while
  # `plugin-scan status` still answered "loaded".
  loads_before="$(override_marker_count)"
  teardowns_before="$(override_unloaded_count)"
  reply="$(sandbox_ipc plugins reload "$override_plugin")"
  if [[ "$reply" != "PLUGIN_RELOAD_SUCCESS: $override_plugin" ]]; then
    fail "plugins reload answered '$reply'"
    return 1
  fi
  # PLUGIN_RELOAD_SUCCESS is exactly what the defect reported while installing
  # nothing, so the reply is not evidence. Only the override's own component
  # saying it was torn down and instantiated again is.
  if ! wait_marker override_marker_count $((loads_before + 1)); then
    loads="$(override_marker_count)"
    fail "plugins reload reported success but the override's own component was never re-instantiated (own-component loads $loads, expected $((loads_before + 1)))"
    return 1
  fi
  sleep 1
  loads="$(override_marker_count)"
  teardowns="$(override_unloaded_count)"
  if [[ "$loads" -ne $((loads_before + 1)) || "$teardowns" -ne $((teardowns_before + 1)) ]]; then
    fail "the reload was not exactly one unload followed by one load (loads $loads_before -> $loads, teardowns $teardowns_before -> $teardowns)"
    return 1
  fi
  if ! override_state_settles 1; then
    return 1
  fi

  # Removing the override must hand the id back to the shipped package rather
  # than leaving a package that no longer exists on disk installed under it.
  rm -rf -- "$dir"
  reply="$(sandbox_ipc plugin-scan rescan "$override_plugin")"
  if [[ "$reply" != RESCAN_TRIGGERED:* ]]; then
    fail "plugin-scan rescan after removing the override answered '$reply'"
    return 1
  fi
  if ! wait_marker override_unloaded_count $((teardowns + 1)); then
    fail "the override's component was never torn down after its manifest was removed — it is still the package installed under '$override_plugin' while its files no longer exist"
    return 1
  fi
  sleep 1
  # `plugins list` saying "[loaded]" is NOT evidence that the shipped package
  # took the id back: it is exactly what the id reported while the wrong
  # package's components were installed. The evidence is that the id is loaded
  # AND no instance of the override survives, which leaves only the shipped
  # package. Reverting VGS-75 ends this run with one override instance still
  # live after its manifest was deleted.
  if ! override_state_settles 0; then
    return 1
  fi
  loads="$(override_marker_count)"
  teardowns="$(override_unloaded_count)"
  note "plugin override check passed ($override_plugin: the override loaded its own component, kept exactly one live instance across a rescan and a reload, and left none behind when its manifest was removed — own-component loads $loads, teardowns $teardowns)"
  return 0
}

# The two things that must hold after every step: the id is owned by something,
# and the override has exactly `want` live instances (loads minus teardowns).
override_state_settles() {
  local want="$1" loads teardowns live
  loads="$(override_marker_count)"
  teardowns="$(override_unloaded_count)"
  live=$((loads - teardowns))
  if [[ "$live" -ne "$want" ]]; then
    fail "'$override_plugin' has $live live override instance(s), expected $want (own-component loads $loads, teardowns $teardowns)"
    return 1
  fi
  if ! plugin_is_loaded "$override_plugin"; then
    fail "'$override_plugin' is owned by nobody — no package is installed under the id"
    return 1
  fi
  return 0
}

nested_check() {
  local host_socket sandbox rt_dir conf log nested_socket candidate exit_code findings
  local compositor_pgid qs_launcher qs_group loaded targets plugins_loaded plugin_report candidate
  local seeded
  local -a expected_plugins=() missing_plugins=()
  local -a sandbox_env=() dbus_wrapper=()
  # Per-run, so a stale log from an earlier invocation can never satisfy a
  # marker assertion in this one.
  override_nonce="$$-${RANDOM}"

  command -v Hyprland >/dev/null 2>&1 || { nested_unavailable "Hyprland not installed"; return; }
  command -v qs >/dev/null 2>&1 || { nested_unavailable "quickshell (qs) not installed"; return; }
  # The layer-geometry assertions parse hyprctl's JSON with it. Without this the
  # first parse would fail as a command-not-found and be read as "no surface".
  command -v python3 >/dev/null 2>&1 || { nested_unavailable "python3 not installed (needed to read the compositor's layer list)"; return; }
  if ! host_socket="$(host_wayland_socket)" || [[ ! -S "$host_socket" ]]; then
    # Without a host Wayland socket a nested compositor would fall back to DRM
    # and fight the real session for the GPU/VT. Refuse rather than risk it.
    nested_unavailable "no host Wayland socket to nest inside (WAYLAND_DISPLAY unset)" no-host-socket
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
  # The sandbox's user state comes from the REPO ALONE: two seeded files, no
  # read of `~/.config/vshell` at all, and `plugins/` left absent for
  # override_check. Why, and which narrower shapes were tried and rejected:
  # docs/decisions/D008-nested-sandbox-state-seeding.md.
  #
  # NOT seeded, deliberately: `theme.json`. The shell renders on MethodTheme's
  # fallback palette, so THEME STATE IS OUT OF THIS SMOKE'S SCOPE and a
  # theme-load regression passes here unseen. The repo has no runtime
  # theme.json to copy and generating one runs hooks that reach the live
  # session — measurements and the revisit condition: D008 § Scope.
  #
  # Every step below either succeeds or SAYS SO. A swallowed prep failure leaves
  # the run measuring a sandbox that is not the one it describes — the same
  # defect as a failed layer query reading as absence, which this file has now
  # had three times, twice of them here.
  prep_fail() {
    fail "sandbox preparation failed at: $1"
    return 1
  }

  mkdir -p "$sandbox/home/.config/vshell" || { prep_fail "creating the sandbox config directory"; return; }
  cp -- "$repo_root/config/vshell/settings.default.json" \
        "$sandbox/home/.config/vshell/settings.json" || { prep_fail "seeding settings.json from the shipped default"; return; }
  cp -- "$repo_root/config/vshell/plugin_settings.default.json" \
        "$sandbox/home/.config/vshell/plugin_settings.json" || { prep_fail "seeding plugin_settings.json from the shipped default"; return; }

  # Stamp the sentinels `seeded_settings_check` reads back. Each key must
  # ALREADY EXIST in the shipped default: one that does not is a rename this
  # check was never told about, and inventing it would seed a setting the shell
  # ignores and then assert on it.
  python3 - "$sandbox/home/.config/vshell" \
            "$settings_sentinel_key" "$settings_sentinel_value" \
            "$plugin_sentinel_plugin" "$plugin_sentinel_key" "$plugin_sentinel_value" \
            <<'PY' || { prep_fail "stamping the seed sentinels into the seeded settings"; return; }
import json
import sys

root, skey, svalue, pplugin, pkey, pvalue = sys.argv[1:7]


def stamp(name, path, value):
    full = f"{root}/{name}"
    with open(full) as fh:
        data = json.load(fh)
    node = data
    for key in path[:-1]:
        if key not in node:
            sys.exit(f"{name}: no {key!r} section in the shipped default")
        node = node[key]
    if path[-1] not in node:
        sys.exit(f"{name}: {path[-1]!r} is not in the shipped default")
    # A sentinel equal to what the shipped file already holds -- which is also
    # what the shell falls back to -- would pass in both worlds and witness
    # nothing. That is the one way to pick a sentinel that cannot discriminate,
    # so it fails here rather than passing quietly for years.
    if node[path[-1]] == value:
        sys.exit(f"{name}: the sentinel for {'.'.join(path)} equals the shipped value {value!r}")
    node[path[-1]] = value
    with open(full, "w") as fh:
        json.dump(data, fh, indent=2)


stamp("settings.json", (skey,), int(svalue))
stamp("plugin_settings.json", (pplugin, pkey), pvalue)
PY

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
  for _ in $(seq 1 $((compositor_timeout * 10))); do
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
    # stdout and stderr are already redirected into $log, so there can be a
    # reason to show even this early. Same rule as the post-teardown block:
    # never report a failure while withholding its evidence.
    tail -n 40 "$log" >&2 || true
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
  for _ in $(seq 1 $((nested_timeout * 2))); do
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

  # Needs nothing but the shell's IPC, and goes first because a missed seed is
  # otherwise INVISIBLE until deep inside popout_check: bundled plugins are
  # force-enabled regardless of settings.json (see the plugin diagnostics
  # below), so they all load on fallback defaults — which is why VGS-92 survived
  # every run in the `cp -a` window. The first phase that would notice is
  # wait_widget_registered, answering WIDGET_NOT_FOUND much later and pointing
  # at the wrong thing.
  seeded=false
  if [[ "$loaded" == true ]] && seeded_settings_check; then
    seeded=true
  fi

  plugins_loaded=false
  plugin_report=""
  # Gated on `loaded`, NOT on the seed: plugin loading does not depend on
  # settings, so this verdict is independent evidence worth having even when
  # the seed check failed.
  if [[ "$loaded" == true ]]; then
    for _ in $(seq 1 $((plugin_timeout * 2))); do
      # The `plugins` IPC target, NOT `plugin-scan`. Both expose a `list`, and
      # they format differently: this one emits "<id> [loaded|disabled]"
      # (VGSIPC.qml), while PluginService's own `plugin-scan list` emits
      # tab-separated "<id>\tloaded\t<type>\t<name>\t<withheld-reason>".
      # Matching the wrong
      # emitter's shape would make every row miss, which reads as "no plugin
      # ever loaded" — so the target and the pattern have to be quoted together.
      # This one is used because it is the view that distinguishes "not scanned
      # yet" (absent) from "scanned and failed to load" (present, [disabled]).
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

  # These two drive the shell that is still running, so they come before the
  # teardown, and they stop at the first failure. Gated on the seed (D008 rule
  # 4): both read state the seeded settings supply, so on fallback defaults they
  # would be measuring a configuration nobody described.
  if [[ "$seeded" == true && "$plugins_loaded" == true ]]; then
    if popout_check; then
      override_check || true
    fi
  fi

  kill_pgid "$qs_group"
  exit_code=0
  wait "$qs_launcher" || exit_code=$?

  # EVERY DIAGNOSTIC IS EMITTED FIRST, then the verdicts, with no `return` in
  # between: each early return here used to withhold evidence for the very
  # failure it reported — a shell that died before exposing IPC got a raw `tail`
  # and no error classification; a plugin failure with log errors lost its report.
  #
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
  local grep_rc=0 scan_error=""
  findings="$(grep -nE "^[[:space:]]*ERROR|is not a type|Cannot assign|Unable to assign|Failed to start process|Type .* unavailable|$error_classes" "$log")" || grep_rc=$?
  if [[ "$grep_rc" -gt 1 ]]; then
    scan_error="could not scan the sandbox log for runtime errors (grep exit $grep_rc, log '$log')"
    findings=""
  else
    findings="$(printf '%s\n' "$findings" | grep -vE "$sandbox_noise")" || grep_rc=$?
    if [[ "$grep_rc" -gt 1 ]]; then
      scan_error="could not filter sandbox noise out of the runtime findings (grep exit $grep_rc)"
      findings=""
    fi
  fi
  [[ -n "$findings" ]] && printf '%s\n' "$findings" >&2
  # The scan matches error CLASSES; a shell that died before logging one leaves
  # it nothing, so the raw tail is what carries the reason in that case.
  [[ "$loaded" != true ]] && { tail -n 40 "$log" >&2 || true; }

  local -a not_loaded=() never_seen=()
  if [[ "$loaded" == true && "$plugins_loaded" != true ]]; then
    # Say WHICH failure this is. "Discovered but not loaded" and "never appeared
    # at all" have different causes, and a timeout listing names without
    # distinguishing them sends the reader to the wrong place. Printed here
    # rather than beside its verdict, so a run that also has log findings keeps
    # it.
    for candidate in "${missing_plugins[@]}"; do
      if printf '%s\n' "$plugin_report" | grep -q "^${candidate} \["; then
        not_loaded+=("$candidate")
      else
        never_seen+=("$candidate")
      fi
    done
    # shellcheck disable=SC2016  # the backticks are literal quoting in the message
    printf 'qml-smoke: `plugins list` reported after %ss:\n%s\n' "$plugin_timeout" \
      "${plugin_report:-<no response from the plugins IPC target>}" >&2
  fi

  # Verdicts, most upstream first: the first true one is the honest cause, and
  # everything needed to act on it is already on stderr above.
  if grep -q "refusing to start a duplicate shell" "$log"; then
    fail "the duplicate-instance guard misfired inside the sandbox"
    return
  fi
  if [[ -n "$scan_error" ]]; then
    fail "$scan_error"
    return
  fi
  if [[ "$loaded" != true ]]; then
    fail "sandboxed shell never exposed its IPC targets (exit code $exit_code)"
    return
  fi
  if [[ -n "$findings" ]]; then
    # Ahead of the plugin verdict: when both fire, the QML error is the cause.
    fail "QML/runtime errors in the sandboxed shell"
    return
  fi
  if [[ "$seeded" != true ]]; then
    # `seeded_settings_check` already failed the run and named the reason.
    return
  fi
  if [[ "$plugins_loaded" != true ]]; then
    if [[ ${#not_loaded[@]} -gt 0 ]]; then
      # Every bundled plugin is force-enabled by PluginService (a bundled id
      # backs product UI, so it loads whether or not a user setting names it)
      # and none declares a startupCheck, so there is no legitimate way for one
      # to sit here disabled. If that ever changes, this is where the expected
      # set has to learn about it — a deliberately-disabled plugin must not
      # look like a broken one.
      fail "bundled plugin(s) scanned but NOT loaded: ${not_loaded[*]} — a bundled id is force-enabled and declares no startup gate, so this is a load failure, not a disabled plugin"
      return
    fi
    fail "bundled plugin(s) never appeared in the sandbox within ${plugin_timeout}s: ${never_seen[*]} (of ${#expected_plugins[@]} under config/vshell/plugins) — the scan never reached them"
    return
  fi

  # Only when nothing has failed. A phase that called `fail` set the exit status
  # but does not stop the run, so an unconditional pass line here sits directly
  # under a FAIL line and reads as a summary that contradicts it.
  [[ "$status" -eq 0 ]] || return
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
