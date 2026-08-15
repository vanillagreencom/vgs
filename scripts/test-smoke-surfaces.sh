#!/usr/bin/env bash
# Branch coverage for `scripts/smoke-surfaces.sh`'s `require_own_shell`
# precondition (VGS-69).
#
# That precondition is the thing standing between "the smoke could not run" and
# "the smoke passed", on the one step AGENTS.md tells everyone to run before
# finishing QML work. Every branch of it — skip, own shell, foreign checkout,
# unreadable registry, unparsable registry — was proven by hand and by nothing
# committed, so it could regress into passing without checking.
#
# The script under test is exercised from a THROWAWAY COPY of the repo layout:
# a temp dir holding `scripts/smoke-surfaces.sh`, a stub `bin/vshell` and an
# empty `quickshell/vshell/`. `repo_root` is derived from the script's own
# location, so the copy makes this checkout's identity, the `qs` registry, the
# process table and `hyprctl` all fixtures. Nothing here can reach the live
# session: `qs`, `hyprctl` and `vshell` are all stubs, and `VSHELL_PROC_ROOT`
# points at a fabricated procfs.
set -euo pipefail

# The status smoke-surfaces.sh exits on a skip path (VGS-123): "nothing was
# checked", distinct from both its pass (0) and its failures (1). Asserting the
# literal here is what keeps a skip from regressing back into a pass.
SKIP_STATUS=77

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_repo="$tmp/repo"
bin_dir="$tmp/bin"
mkdir -p "$fake_repo/scripts" "$fake_repo/bin" "$fake_repo/quickshell/vshell" "$bin_dir" "$tmp/empty-proc"
cp "$repo_root/scripts/smoke-surfaces.sh" "$fake_repo/scripts/smoke-surfaces.sh"
chmod +x "$fake_repo/scripts/smoke-surfaces.sh"

own_config="$fake_repo/quickshell/vshell"
foreign_root="$tmp/other-checkout"
foreign_config="$foreign_root/quickshell/vshell"
mkdir -p "$foreign_config"

# Stub `vshell`: every ipc call succeeds and touches nothing.
cat >"$fake_repo/bin/vshell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_repo/bin/vshell"

# Stub `qs`: FAKE_QS_JSON on stdout, FAKE_QS_STDERR on stderr, FAKE_QS_EXIT as
# the status. Keeping the two streams independent is what lets the "warning on
# a successful listing" case exist at all.
cat >"$bin_dir/qs" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_QS_STDERR:-}" ]]; then printf '%s\n' "$FAKE_QS_STDERR" >&2; fi
if [[ "${FAKE_QS_EXIT:-0}" != 0 ]]; then exit "${FAKE_QS_EXIT}"; fi
printf '%s\n' "${FAKE_QS_JSON:-[]}"
EOF
chmod +x "$bin_dir/qs"

# Stub `hyprctl`: one monitor whose largest layer sets the screen size, with
# every namespace the smoke asserts on present and content-sized.
cat >"$bin_dir/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_LAYERS_JSON"
EOF
chmod +x "$bin_dir/hyprctl"

# A curated PATH holding nothing but the coreutils the script shells out to,
# so a case can control exactly which Quickshell CLI is visible. Without this,
# "no CLI installed" and "only `quickshell` installed" cannot be tested on a
# machine that has a real `qs` on /usr/bin — it would answer from the live
# registry. `bash` and `env` are here because the shebang is `/usr/bin/env
# bash`, which resolves bash through PATH.
min_path="$tmp/bin-min"
mkdir -p "$min_path"
for tool in bash env dirname python3 mktemp cat rm sleep grep; do
  ln -sf "$(command -v "$tool")" "$min_path/$tool"
done

layers_json='{"DP-1":{"levels":{"2":[
  {"namespace":"vshell:wallpaper","w":1920,"h":1080},
  {"namespace":"vshell:capture","w":400,"h":300},
  {"namespace":"vshell:capture:clickcatcher","w":1920,"h":1080},
  {"namespace":"vshell:power-menu","w":400,"h":300},
  {"namespace":"vshell:power-menu:clickcatcher","w":1920,"h":1080},
  {"namespace":"vshell:vgs-menu","w":400,"h":300},
  {"namespace":"vshell:vgs-menu:clickcatcher","w":1920,"h":1080}
]}}}'

# --- fabricated procfs -------------------------------------------------------
# make_proc <root> <pid> <state> <comm> [exe-target]
# `exe` is omitted where the case needs the comm fallback: /proc/<pid>/exe is
# readable only for our own processes, so a foreign shell is normally
# confirmed through comm alone.
make_proc() {
  local root="$1" pid="$2" state="$3" comm="$4" exe="${5:-}"
  mkdir -p "$root/$pid"
  printf '%s (%s) %s 1 1 0 -1 0 0 0 0 0 0 0\n' "$pid" "$comm" "$state" >"$root/$pid/stat"
  printf '%s\n' "$comm" >"$root/$pid/comm"
  if [[ -n "$exe" ]]; then ln -sf "$exe" "$root/$pid/exe"; fi
}

proc="$tmp/proc"
make_proc "$proc" 101 S quickshell /usr/bin/quickshell   # own shell, live
make_proc "$proc" 202 S quickshell ""                    # foreign shell, live (comm only)
make_proc "$proc" 303 Z quickshell /usr/bin/quickshell   # foreign shell, zombie
make_proc "$proc" 404 S bash ""                          # foreign pid, reused by something else

entry() { printf '{"pid":%s,"config_path":"%s"}' "$1" "$2"; }

# --- harness -----------------------------------------------------------------
out=""
err=""
rc=0
case_name=""

run_smoke() {
  run_smoke_on "$bin_dir:$PATH" "$@"
}

# run_smoke_on <PATH> <case name> [VAR=VAL ...] — the PATH is spelled out for
# the cases that turn on which Quickshell CLI is visible.
run_smoke_on() {
  local path="$1"
  case_name="$2"
  shift 2
  rc=0
  out="$(env "$@" \
    PATH="$path" \
    HYPRLAND_INSTANCE_SIGNATURE=test \
    FAKE_LAYERS_JSON="$layers_json" \
    "$fake_repo/scripts/smoke-surfaces.sh" 2>"$tmp/stderr")" || rc=$?
  err="$(cat "$tmp/stderr")"
}

# run_smoke_bare <PATH> <case name> [VAR=VAL ...] — like run_smoke_on, but it
# does NOT inject HYPRLAND_INSTANCE_SIGNATURE. That injection is what made the
# Hyprland precondition itself untestable: every other case satisfies it, so
# reverting that arm to exit 0 left the whole suite green (VGS-123 review).
# `env -u` runs before the assignments in "$@", so a case that wants the
# signature SET can still pass it and have it stick.
run_smoke_bare() {
  local path="$1"
  case_name="$2"
  shift 2
  rc=0
  out="$(env -u HYPRLAND_INSTANCE_SIGNATURE "$@" \
    PATH="$path" \
    FAKE_LAYERS_JSON="$layers_json" \
    "$fake_repo/scripts/smoke-surfaces.sh" 2>"$tmp/stderr")" || rc=$?
  err="$(cat "$tmp/stderr")"
}

fail() {
  {
    echo "FAIL [$case_name]: $*"
    echo "  exit: $rc"
    echo "  --- stdout ---"
    printf '%s\n' "$out"
    echo "  --- stderr ---"
    printf '%s\n' "$err"
  } >&2
  exit 1
}

expect_rc() {
  [[ "$rc" == "$1" ]] || fail "expected exit $1, got $rc"
}

expect_stdout() {
  grep -qF -- "$1" <<<"$out" || fail "stdout does not mention: $1"
}

expect_stderr() {
  grep -qF -- "$1" <<<"$err" || fail "stderr does not mention: $1"
}

# --- cases -------------------------------------------------------------------

# The precondition is satisfied: the live shell is this checkout's, so the smoke
# proceeds and the assertions run to completion.
run_smoke "own shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$own_config")]"
expect_rc 0
expect_stdout "surface smoke passed"

# A warning on stderr must not corrupt a perfectly good listing. Folding the
# streams together made this case a hard failure on a successful `qs list`.
run_smoke "own shell, qs warns on stderr" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_STDERR="warning: some deprecated thing" \
  FAKE_QS_JSON="[$(entry 101 "$own_config")]"
expect_rc 0
expect_stdout "surface smoke passed"

# Nothing running: a named skip, never a silent abort.
run_smoke "no VGS shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"

# Some other Quickshell app on the seat is none of this script's business. This
# case is the counterweight to the malformed-entry failures below: a WELL-FORMED
# entry that simply is not a VGS tree must keep taking the skip, or the smoke
# becomes unusable on any machine running another Quickshell app.
run_smoke "unrelated quickshell shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$tmp/somebody-else/quickshell/caelestia")]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"

# ...and it must still skip when it sits beside our own live shell, rather than
# being mistaken for something the registry got wrong.
run_smoke "unrelated quickshell shell beside our own" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$tmp/somebody-else/quickshell/caelestia"), $(entry 101 "$own_config")]"
expect_rc 0
expect_stdout "surface smoke passed"

# A live shell owned by another checkout: loud failure naming that checkout,
# because the requested assertions did not run.
run_smoke "foreign checkout" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 202 "$foreign_config")]"
expect_rc 1
expect_stderr "surface smoke FAILED: a live VGS shell belongs to a different checkout"
expect_stderr "$foreign_root (pid 202)"
expect_stderr "this run:      $fake_repo"

# THE ONE THAT MATTERS. With our own shell live AND another checkout's live,
# `hyprctl layers` aggregates both, so a foreign shell's surfaces can satisfy
# every assertion and the smoke would report success on somebody else's
# evidence. A false pass is worse than the silent death this precondition
# replaced, because it gets acted on. Foreign must beat mine.
run_smoke "own shell AND a foreign shell both live" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$own_config"), $(entry 202 "$foreign_config")]"
expect_rc 1
expect_stderr "surface smoke FAILED: a live VGS shell belongs to a different checkout"
expect_stderr "$foreign_root (pid 202)"
expect_stderr "hyprctl layers"

# `shell.qml` in config_path resolves to the same runtime tree.
run_smoke "foreign checkout, shell.qml config path" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 202 "$foreign_config/shell.qml")]"
expect_rc 1
expect_stderr "$foreign_root (pid 202)"

# A zombie keeps a readable /proc entry while owning no surfaces. Treating
# /proc/<pid> existence as liveness turned this into the foreign-checkout
# failure above — the exact false failure the precondition exists to prevent.
run_smoke "foreign entry whose process is a zombie" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 303 "$foreign_config")]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"

# After PID reuse the number belongs to something unrelated.
run_smoke "foreign entry whose pid was reused" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 404 "$foreign_config")]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"

# The pid is gone from the process table entirely.
run_smoke "foreign entry whose process is gone" \
  VSHELL_PROC_ROOT="$tmp/empty-proc" \
  FAKE_QS_JSON="[$(entry 202 "$foreign_config")]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"

# Garbage in the registry must FAIL. Falling back to the skip here would be a
# check that passes without checking.
run_smoke "unparsable registry" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="not json at all"
expect_rc 1
expect_stderr "surface smoke FAILED: could not classify the instance registry"
expect_stderr "unparsable qs list output"

# A syntactically valid listing whose ENTRIES are not the shape this script
# reads must fail too. Skipping them was the same false green as the original
# bug, one layer in: a registry schema change or a corrupt entry would come back
# as "no live VGS shell" and the smoke would exit 0 having checked nothing.
run_smoke "entry missing config_path" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON='[{"pid":101}]'
expect_rc 1
expect_stderr "surface smoke FAILED: could not classify the instance registry"
expect_stderr "entry 0: no usable config_path"

run_smoke "entry is not an object" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON='["quickshell"]'
expect_rc 1
expect_stderr "entry 0: expected an object, got str"

run_smoke "entry missing pid" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[{\"config_path\":\"$own_config\"}]"
expect_rc 1
expect_stderr "entry 0: pid is not an integer"

run_smoke "entry pid is not a number" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[{\"config_path\":\"$own_config\",\"pid\":\"soon\"}]"
expect_rc 1
expect_stderr "entry 0: pid is not an integer"

run_smoke "entry pid is zero" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 0 "$own_config")]"
expect_rc 1
expect_stderr "entry 0: pid is not a positive integer"

run_smoke "entry pid is negative" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry -1 "$own_config")]"
expect_rc 1
expect_stderr "entry 0: pid is not a positive integer"

# A malformed entry is not excused by a healthy one beside it: the entry that
# could not be read might BE the foreign shell the precondition looks for.
run_smoke "malformed entry beside our own live shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$own_config"), {\"pid\":202}]"
expect_rc 1
expect_stderr "entry 1: no usable config_path"

# Well-formed JSON of the wrong shape is equally unclassifiable.
run_smoke "registry is not a list" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON='{"pid":1}'
expect_rc 1
expect_stderr "surface smoke FAILED: could not classify the instance registry"

# `qs list` itself failing is a failure, and its stderr is what says why.
run_smoke "qs list exits non-zero" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_EXIT=3 \
  FAKE_QS_STDERR="qs: could not open the instance directory"
expect_rc 1
expect_stderr "surface smoke FAILED: could not read the Quickshell instance registry (qs list exited 3)"
expect_stderr "qs: could not open the instance directory"

# --- which Quickshell CLI is on PATH -----------------------------------------
# `bin/vshell-helper`'s QS_BINARIES treats `qs` and `quickshell` as the same
# CLI, and both read the same instance registry. Each case below runs on a
# curated PATH holding only the coreutils, so what the script can see is decided
# here and never by whatever this machine happens to have installed.

# Only `quickshell`: the classifier must still run rather than skipping.
onlyq="$tmp/bin-quickshell-only"
mkdir -p "$onlyq"
cp -a "$min_path/." "$onlyq/"
cp "$bin_dir/qs" "$onlyq/quickshell"
cp "$bin_dir/hyprctl" "$onlyq/hyprctl"

run_smoke_on "$onlyq" "only quickshell on PATH, own shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$own_config")]"
expect_rc 0
expect_stdout "surface smoke passed"

run_smoke_on "$onlyq" "only quickshell on PATH, foreign shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 202 "$foreign_config")]"
expect_rc 1
expect_stderr "$foreign_root (pid 202)"

# Neither: a genuine skip. There is no registry to consult, so there is nothing
# to classify and nothing to claim.
nocli="$tmp/bin-no-cli"
mkdir -p "$nocli"
cp -a "$min_path/." "$nocli/"
cp "$bin_dir/hyprctl" "$nocli/hyprctl"

run_smoke_on "$nocli" "no Quickshell CLI on PATH" \
  VSHELL_PROC_ROOT="$proc"
expect_rc "$SKIP_STATUS"
expect_stdout "no Quickshell CLI (qs, quickshell) on PATH"

# The Hyprland precondition, both arms. This is the skip path that fires most
# often — an agent shell, a headless checkout, CI itself — and until these two
# cases existed it was the one arm of the four with no must-fail control at all.
run_smoke_bare "$min_path" "no hyprctl on PATH" HYPRLAND_INSTANCE_SIGNATURE=test
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: Hyprland session not available"

run_smoke_bare "$bin_dir:$PATH" "HYPRLAND_INSTANCE_SIGNATURE unset"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: Hyprland session not available"

echo "smoke-surfaces precondition checks passed"
