#!/usr/bin/env bash
# Exercise live-smoke prerequisites in a temporary layout with stubbed shell, compositor,
# and instance registry commands. VSHELL_PROC_ROOT supplies fixture process data.
# This permits checkout-ownership and unreadable-registry cases without the live session.
set -euo pipefail

# Require skip status 77 so an unmet prerequisite cannot report success.
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


cat >"$fake_repo/bin/vshell" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fake_repo/bin/vshell"

# Keep stub stdout, stderr, and status independent to exercise a successful listing with warnings.
cat >"$bin_dir/qs" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${FAKE_QS_STDERR:-}" ]]; then printf '%s\n' "$FAKE_QS_STDERR" >&2; fi
if [[ "${FAKE_QS_EXIT:-0}" != 0 ]]; then exit "${FAKE_QS_EXIT}"; fi
printf '%s\n' "${FAKE_QS_JSON:-[]}"
EOF
chmod +x "$bin_dir/qs"

# Provide one fixture monitor and the namespaces required by the smoke.
cat >"$bin_dir/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_LAYERS_JSON"
EOF
chmod +x "$bin_dir/hyprctl"

# Use a controlled PATH so absent or quickshell-only CLI cases cannot find the host's real qs.
# Include env and bash for the script shebang.
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

# Create fixture process state and optional exe links. Omit exe where ownership prevents
# reading it in a real process table, leaving the comm fallback.
make_proc() {
  local root="$1" pid="$2" state="$3" comm="$4" exe="${5:-}"
  mkdir -p "$root/$pid"
  printf '%s (%s) %s 1 1 0 -1 0 0 0 0 0 0 0\n' "$pid" "$comm" "$state" >"$root/$pid/stat"
  printf '%s\n' "$comm" >"$root/$pid/comm"
  if [[ -n "$exe" ]]; then ln -sf "$exe" "$root/$pid/exe"; fi
}

proc="$tmp/proc"
make_proc "$proc" 101 S quickshell /usr/bin/quickshell
make_proc "$proc" 202 S quickshell ""
make_proc "$proc" 303 Z quickshell /usr/bin/quickshell
make_proc "$proc" 404 S bash ""

entry() { printf '{"pid":%s,"config_path":"%s"}' "$1" "$2"; }


out=""
err=""
rc=0
case_name=""

run_smoke() {
  run_smoke_on "$bin_dir:$PATH" "$@"
}

# Run smoke with a specified PATH so the fixture controls CLI discovery.
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

# Run without an injected Hyprland signature to exercise its prerequisite.
# Apply explicit fixture assignments after env -u so a case can still set the signature.
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




run_smoke "own shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$own_config")]"
expect_rc 0
expect_stdout "surface smoke passed"

# Warnings on stderr must not corrupt valid registry JSON on stdout.
run_smoke "own shell, qs warns on stderr" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_STDERR="warning: some deprecated thing" \
  FAKE_QS_JSON="[$(entry 101 "$own_config")]"
expect_rc 0
expect_stdout "surface smoke passed"


run_smoke "no VGS shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"

# A well-formed unrelated Quickshell app is outside this smoke's ownership and must be skipped.
run_smoke "unrelated quickshell shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$tmp/somebody-else/quickshell/caelestia")]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"

# An unrelated app beside the owned shell must also remain ignored.
run_smoke "unrelated quickshell shell beside our own" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$tmp/somebody-else/quickshell/caelestia"), $(entry 101 "$own_config")]"
expect_rc 0
expect_stdout "surface smoke passed"

# A live foreign checkout must fail because this checkout cannot validate its shell.
run_smoke "foreign checkout" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 202 "$foreign_config")]"
expect_rc 1
expect_stderr "surface smoke FAILED: a live VGS shell belongs to a different checkout"
expect_stderr "$foreign_root (pid 202)"
expect_stderr "this run:      $fake_repo"

# A foreign live shell must take precedence over an owned one because compositor layers aggregate both.
run_smoke "own shell AND a foreign shell both live" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$own_config"), $(entry 202 "$foreign_config")]"
expect_rc 1
expect_stderr "surface smoke FAILED: a live VGS shell belongs to a different checkout"
expect_stderr "$foreign_root (pid 202)"
expect_stderr "hyprctl layers"


run_smoke "foreign checkout, shell.qml config path" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 202 "$foreign_config/shell.qml")]"
expect_rc 1
expect_stderr "$foreign_root (pid 202)"

# A zombie has a readable process entry but owns no surfaces; existence alone cannot prove liveness.
run_smoke "foreign entry whose process is a zombie" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 303 "$foreign_config")]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"


run_smoke "foreign entry whose pid was reused" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 404 "$foreign_config")]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"


run_smoke "foreign entry whose process is gone" \
  VSHELL_PROC_ROOT="$tmp/empty-proc" \
  FAKE_QS_JSON="[$(entry 202 "$foreign_config")]"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: no live VGS shell on this session"

# Malformed registry data must fail instead of becoming an empty skip.
run_smoke "unparsable registry" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="not json at all"
expect_rc 1
expect_stderr "surface smoke FAILED: could not classify the instance registry"
expect_stderr "unparsable qs list output"

# Invalid entry shapes must fail even when the JSON document parses.
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

# A healthy sibling entry cannot excuse an unreadable entry that might identify a foreign shell.
run_smoke "malformed entry beside our own live shell" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON="[$(entry 101 "$own_config"), {\"pid\":202}]"
expect_rc 1
expect_stderr "entry 1: no usable config_path"


run_smoke "registry is not a list" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_JSON='{"pid":1}'
expect_rc 1
expect_stderr "surface smoke FAILED: could not classify the instance registry"

# Preserve the failed registry command's diagnostic.
run_smoke "qs list exits non-zero" \
  VSHELL_PROC_ROOT="$proc" \
  FAKE_QS_EXIT=3 \
  FAKE_QS_STDERR="qs: could not open the instance directory"
expect_rc 1
expect_stderr "surface smoke FAILED: could not read the Quickshell instance registry (qs list exited 3)"
expect_stderr "qs: could not open the instance directory"

# Control PATH to test both supported Quickshell CLI names independently of host tools.


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


nocli="$tmp/bin-no-cli"
mkdir -p "$nocli"
cp -a "$min_path/." "$nocli/"
cp "$bin_dir/hyprctl" "$nocli/hyprctl"

run_smoke_on "$nocli" "no Quickshell CLI on PATH" \
  VSHELL_PROC_ROOT="$proc"
expect_rc "$SKIP_STATUS"
expect_stdout "no Quickshell CLI (qs, quickshell) on PATH"

# Exercise both Hyprland prerequisite branches so a skip cannot silently become success.
run_smoke_bare "$min_path" "no hyprctl on PATH" HYPRLAND_INSTANCE_SIGNATURE=test
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: Hyprland session not available"

run_smoke_bare "$bin_dir:$PATH" "HYPRLAND_INSTANCE_SIGNATURE unset"
expect_rc "$SKIP_STATUS"
expect_stdout "surface smoke skipped: Hyprland session not available"

echo "smoke-surfaces precondition checks passed"
