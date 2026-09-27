#!/usr/bin/env bash
# Exercise live-smoke prerequisites in a temporary layout with stubbed shell, compositor,
# and instance registry commands. VSHELL_PROC_ROOT supplies fixture process data.
# This permits checkout-ownership and unreadable-registry cases without the live session.
# Exit 1 covers three unrelated failures, so each row pins the sentinel of its outcome
# class; the per-entry detail lines under it are diagnostics, not a contract.
set -euo pipefail

# Require skip status 77 so an unmet prerequisite cannot report success.
SKIP_STATUS=77

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
case_failed=0
out=""
err=""
rc=0
fail() {
  {
    printf 'FAIL [%s]: %s\n' "$1" "$2"
    printf '  exit: %s\n  --- stdout ---\n%s\n  --- stderr ---\n%s\n' "$rc" "$out" "$err"
  } >&2
  failures=$((failures + 1))
  case_failed=1
}
ok() {
  if [[ $case_failed -eq 0 ]]; then
    printf '  ok    %s\n' "$1"
  fi
  case_failed=0
}

fake_repo="$tmp/repo"
bin_dir="$tmp/bin"
mkdir -p "$fake_repo/scripts" "$fake_repo/bin" "$fake_repo/quickshell/vshell" "$bin_dir" "$tmp/empty-proc"
cp "$repo_root/scripts/smoke-surfaces.sh" "$fake_repo/scripts/smoke-surfaces.sh"
chmod +x "$fake_repo/scripts/smoke-surfaces.sh"

own_config="$fake_repo/quickshell/vshell"
foreign_root="$tmp/other-checkout"
foreign_config="$foreign_root/quickshell/vshell"
other_config="$tmp/somebody-else/quickshell/caelestia"
mkdir -p "$foreign_config"

printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_repo/bin/vshell"
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
only_quickshell="$tmp/bin-quickshell-only"
mkdir -p "$only_quickshell"
cp -a "$min_path/." "$only_quickshell/"
cp "$bin_dir/qs" "$only_quickshell/quickshell"
cp "$bin_dir/hyprctl" "$only_quickshell/hyprctl"
no_cli="$tmp/bin-no-cli"
mkdir -p "$no_cli"
cp -a "$min_path/." "$no_cli/"
cp "$bin_dir/hyprctl" "$no_cli/hyprctl"
declare -A PATHS=(
  [full]="$bin_dir:$PATH"
  [only-quickshell]="$only_quickshell"
  [no-cli]="$no_cli"
  [no-hyprctl]="$min_path"
)

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

# Run the smoke with a chosen PATH and Hyprland signature ("-" leaves the signature unset),
# followed by the row's own environment assignments.
run_smoke() {
  local path="$1" signature="$2"
  shift 2
  rc=0
  if [[ "$signature" == - ]]; then
    out="$(env -u HYPRLAND_INSTANCE_SIGNATURE "$@" \
      PATH="$path" \
      FAKE_LAYERS_JSON="$layers_json" \
      "$fake_repo/scripts/smoke-surfaces.sh" 2>"$tmp/stderr")" || rc=$?
  else
    out="$(env "$@" \
      PATH="$path" \
      HYPRLAND_INSTANCE_SIGNATURE="$signature" \
      FAKE_LAYERS_JSON="$layers_json" \
      "$fake_repo/scripts/smoke-surfaces.sh" 2>"$tmp/stderr")" || rc=$?
  fi
  err="$(cat "$tmp/stderr")"
}

expect_rc() {
  [[ "$rc" == "$1" ]] || fail "$2" "expected exit $1, got $rc"
}

# One sentinel per outcome class, on the channel that class reports through. The failing
# classes also carry the cause the reader acts on (the foreign checkout, the entry the
# classifier refused, the registry command's own diagnostic), because the FAILED header
# alone is printed by a catch-all arm for any classifier exit.
verdict_check() {
  local label="$1" verdict="$2" sentinel channel cause=""
  case "$verdict" in
    passed)
      sentinel="surface smoke passed"
      channel="$out"
      ;;
    no-live)
      sentinel="surface smoke skipped: no live VGS shell on this session"
      channel="$out"
      ;;
    no-cli)
      sentinel="no Quickshell CLI (qs, quickshell) on PATH"
      channel="$out"
      ;;
    no-hyprland)
      sentinel="surface smoke skipped: Hyprland session not available"
      channel="$out"
      ;;
    foreign)
      sentinel="surface smoke FAILED: a live VGS shell belongs to a different checkout"
      cause="$foreign_root (pid 202)"
      channel="$err"
      ;;
    malformed)
      sentinel="surface smoke FAILED: could not classify the instance registry"
      cause="registry entries this script does not understand:"
      channel="$err"
      ;;
    unparsable)
      sentinel="surface smoke FAILED: could not classify the instance registry"
      cause="unparsable qs list output"
      channel="$err"
      ;;
    not-a-list)
      sentinel="surface smoke FAILED: could not classify the instance registry"
      cause="unexpected qs list output"
      channel="$err"
      ;;
    unreadable)
      sentinel="surface smoke FAILED: could not read the Quickshell instance registry"
      cause="qs: could not open the instance directory"
      channel="$err"
      ;;
    *)
      fail "$label" "unknown verdict column: $verdict"
      return
      ;;
  esac
  grep -qF -- "$sentinel" <<<"$channel" || fail "$label" "no verdict sentinel: $sentinel"
  [[ -z "$cause" ]] || grep -qF -- "$cause" <<<"$channel" || fail "$label" "no cause reported: $cause"
}

# label; qs behaviour; registry JSON; process table; expected exit; verdict class.
# A live shell this checkout does not own must fail, because compositor layers aggregate
# every shell on the session and this checkout cannot validate another one's surfaces.
# An entry the reader cannot classify must fail too, never become an empty skip.
REGISTRY="our own live shell;ok;[$(entry 101 "$own_config")];proc;0;passed
warnings on stderr do not corrupt the listing;warn;[$(entry 101 "$own_config")];proc;0;passed
an empty registry;ok;[];proc;$SKIP_STATUS;no-live
an unrelated Quickshell app;ok;[$(entry 101 "$other_config")];proc;$SKIP_STATUS;no-live
an unrelated app beside our own;ok;[$(entry 101 "$other_config"), $(entry 101 "$own_config")];proc;0;passed
a foreign checkout;ok;[$(entry 202 "$foreign_config")];proc;1;foreign
our own shell and a foreign one;ok;[$(entry 101 "$own_config"), $(entry 202 "$foreign_config")];proc;1;foreign
a foreign shell.qml config path;ok;[$(entry 202 "$foreign_config/shell.qml")];proc;1;foreign
a foreign entry whose process is a zombie;ok;[$(entry 303 "$foreign_config")];proc;$SKIP_STATUS;no-live
a foreign entry whose pid was reused;ok;[$(entry 404 "$foreign_config")];proc;$SKIP_STATUS;no-live
a foreign entry whose process is gone;ok;[$(entry 202 "$foreign_config")];empty;$SKIP_STATUS;no-live
an unparsable registry;ok;not json at all;proc;1;unparsable
an entry with no config_path;ok;[{\"pid\":101}];proc;1;malformed
an entry that is not an object;ok;[\"quickshell\"];proc;1;malformed
an entry with no pid;ok;[{\"config_path\":\"$own_config\"}];proc;1;malformed
an entry whose pid is a word;ok;[{\"config_path\":\"$own_config\",\"pid\":\"soon\"}];proc;1;malformed
an entry whose pid is zero;ok;[$(entry 0 "$own_config")];proc;1;malformed
an entry whose pid is negative;ok;[$(entry -1 "$own_config")];proc;1;malformed
an unreadable entry beside our own live shell;ok;[$(entry 101 "$own_config"), {\"pid\":202}];proc;1;malformed
a registry that is not a list;ok;{\"pid\":1};proc;1;not-a-list
a registry command that fails;exit3;-;proc;1;unreadable"

case_registry() {
  local label qs registry proc_key want_rc verdict proc_root rows=0
  while IFS=';' read -r label qs registry proc_key want_rc verdict; do
    [[ -n "$label" ]] || continue
    rows=$((rows + 1))
    case "$proc_key" in
      proc) proc_root="$proc" ;;
      empty) proc_root="$tmp/empty-proc" ;;
      *)
        fail "$label" "unknown process table column: $proc_key"
        continue
        ;;
    esac
    case "$qs" in
      ok) run_smoke "${PATHS[full]}" test VSHELL_PROC_ROOT="$proc_root" FAKE_QS_JSON="$registry" ;;
      warn)
        run_smoke "${PATHS[full]}" test VSHELL_PROC_ROOT="$proc_root" \
          FAKE_QS_JSON="$registry" FAKE_QS_STDERR="warning: some deprecated thing"
        ;;
      exit3)
        run_smoke "${PATHS[full]}" test VSHELL_PROC_ROOT="$proc_root" \
          FAKE_QS_EXIT=3 FAKE_QS_STDERR="qs: could not open the instance directory"
        ;;
      *)
        fail "$label" "unknown qs column: $qs"
        continue
        ;;
    esac
    expect_rc "$want_rc" "$label"
    verdict_check "$label" "$verdict"
  done <<<"$REGISTRY"
  [[ $rows -eq 21 ]] || fail "registry" "expected 21 table rows, drove $rows"
  ok "each registry payload passes, skips or fails in the class it belongs to"
}

# label; PATH; Hyprland signature; registry JSON or -; expected exit; verdict class.
# Both Quickshell CLI names are supported, and a missing prerequisite skips rather than
# reporting success.
DISCOVERY="the quickshell CLI name with our own shell;only-quickshell;test;[$(entry 101 "$own_config")];0;passed
the quickshell CLI name with a foreign shell;only-quickshell;test;[$(entry 202 "$foreign_config")];1;foreign
no Quickshell CLI on PATH;no-cli;test;-;$SKIP_STATUS;no-cli
no hyprctl on PATH;no-hyprctl;test;-;$SKIP_STATUS;no-hyprland
no Hyprland signature in the environment;full;-;-;$SKIP_STATUS;no-hyprland"

case_discovery() {
  local label path_key signature registry want_rc verdict rows=0
  while IFS=';' read -r label path_key signature registry want_rc verdict; do
    [[ -n "$label" ]] || continue
    rows=$((rows + 1))
    if [[ -z "${PATHS[$path_key]+set}" ]]; then
      fail "$label" "no PATH fixture named $path_key"
      continue
    fi
    if [[ "$registry" == - ]]; then
      run_smoke "${PATHS[$path_key]}" "$signature" VSHELL_PROC_ROOT="$proc"
    else
      run_smoke "${PATHS[$path_key]}" "$signature" VSHELL_PROC_ROOT="$proc" FAKE_QS_JSON="$registry"
    fi
    expect_rc "$want_rc" "$label"
    verdict_check "$label" "$verdict"
  done <<<"$DISCOVERY"
  [[ $rows -eq 5 ]] || fail "discovery" "expected 5 table rows, drove $rows"
  ok "each missing prerequisite skips, and either CLI name finds the registry"
}

CASES=(
  case_registry
  case_discovery
)
for surfaces_case in "${CASES[@]}"; do
  "$surfaces_case"
done

if [[ $failures -ne 0 ]]; then
  printf '\ntest-smoke-surfaces: %d failure(s)\n' "$failures" >&2
  exit 1
fi
echo "test-smoke-surfaces: all checks passed"
