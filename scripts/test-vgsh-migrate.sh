#!/usr/bin/env bash
# Controls for bin/vgsh-migrate, VGS's one-time migrations
# (docs/decisions/D076-one-time-migrations.md), and for its two callers in
# bin/vgsh: `vgsh run`, which runs them with a notice once it holds the
# instance lock and starts the shell whatever they answer, and
# `vgsh migrate [--pending]`. Every tree is a copy under $tmp holding
# fixture migrations, never this repository's; each row has a HOME and a
# state directory of its own. Hyprland and Quickshell are stubs first on
# PATH: hyprctl answers the preflight and records every `notify`, and qs
# answers `--version` and, run as the shell, records what the fixture
# migrations had written when it started, then sleeps until the row stops
# the runner. The controls at the end run copies of bin/vgsh-migrate and
# bin/vgsh with one rule removed, and a row must fail against each.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
for tool in setpriv flock timeout; do
  command -v "$tool" >/dev/null || { echo "test-vgsh-migrate: status=not-measured missing=$tool"; exit 77; }
done

cat >"$tmp/hyprctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "-j version") echo '{"version": "0.56.2"}' ;;
  notify*) printf '%s\n' "$*" >>"${STUB_HYPR_LOG:?}"; echo ok ;;
  *) echo "stub hyprctl: unexpected: $*" >&2; exit 1 ;;
esac
EOF
cat >"$tmp/qs" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then echo "Quickshell 0.3.1"; exit 0; fi
log="$(cat -- "$HOME/log" 2>/dev/null | paste -sd, -)" || log=""
printf 'started log=%s\n' "$log" >"${STUB_RECORD:?}.part"
mv -- "$STUB_RECORD.part" "$STUB_RECORD"
exec sleep 20
EOF
chmod +x "$tmp/hyprctl" "$tmp/qs"

# A migration that appends its own name to $HOME/log, and one that fails.
passes='printf "%s\n" "${VGS_MIGRATION%.sh}" >>"$HOME/log"'
fails='printf "%s\n" "${VGS_MIGRATION%.sh}-tried" >>"$HOME/log"; exit 3'

# make_tree NAME [MIGRATE] [VGSH]: a tree under $tmp/trees/NAME with
# copies of MIGRATE and VGSH, bin/vgsh-migrate and bin/vgsh by default,
# bin/lib and shell linked, and an empty bin/migrations; sets
# `tree`.
make_tree() {
  tree="$tmp/trees/$1"
  rm -rf -- "${tree:?}"
  mkdir -p -- "$tree/bin/migrations"
  cp -- "${2:-$repo/bin/vgsh-migrate}" "$tree/bin/vgsh-migrate"
  cp -- "${3:-$repo/bin/vgsh}" "$tree/bin/vgsh"
  chmod +x "$tree/bin/vgsh-migrate" "$tree/bin/vgsh"
  ln -s -- "$repo/bin/lib" "$tree/bin/lib"
  ln -s -- "$repo/shell" "$tree/shell"
}
migration() { printf '%s\n' "$3" >"$1/bin/migrations/$2"; } # TREE NAME BODY

# migrate TREE ARGS...: bin/vgsh-migrate of TREE under a HOME of its own
# per call of fresh_home, stdin a line of text; stdout in $tmp/out, stderr
# in $tmp/err, the exit status in $status.
fresh_home() { home="$(mktemp -d "$tmp/home-XXXXXX")"; }
migrate() {
  local bin="$1"
  shift
  status=0
  "${base_env[@]}" HOME="$home" STUB_HYPR_LOG="$home/hyprctl.log" "$bin/bin/vgsh-migrate" "$@" <<<"text on stdin" >"$tmp/out" 2>"$tmp/err" || status=$?
}
out() { paste -sd';' - <"$tmp/out"; }
err() { paste -sd';' - <"$tmp/err"; }
log() { if [[ -e $home/log ]]; then paste -sd, - <"$home/log"; fi; }
notices() { if [[ -e $home/hyprctl.log ]]; then paste -sd';' - <"$home/hyprctl.log"; else echo none; fi; }
markers() { ls -- "$home/.local/state/vgs/migrations" 2>/dev/null | paste -sd, - || true; }

# Each row prints one verdict line; its want is written out beside it.
row_order_once() { # TREE
  migration "$1" 0000000002-second.sh "$passes"
  migration "$1" 0000000001-first.sh "$passes"
  fresh_home
  migrate "$1" run
  printf 'status=%s out=[%s] log=%s markers=%s' "$status" "$(out)" "$(log)" "$(markers)"
  migrate "$1" run
  printf ' again=%s out=[%s] log=%s\n' "$status" "$(out)" "$(log)"
}
want_order_once="status=0 out=[vgsh-migrate: ran=0000000001-first.sh;vgsh-migrate: ran=0000000002-second.sh;vgsh-migrate: ok ran=2] log=0000000001-first,0000000002-second markers=0000000001-first.sh,0000000002-second.sh again=0 out=[vgsh-migrate: ok ran=0] log=0000000001-first,0000000002-second"
row_failure_stops() { # TREE
  migration "$1" 0000000001-first.sh "$passes"
  migration "$1" 0000000002-broken.sh "$fails"
  migration "$1" 0000000003-later.sh "$passes"
  fresh_home
  migrate "$1" run
  printf 'status=%s err=[%s] log=%s markers=%s' "$status" "$(err)" "$(log)" "$(markers)"
  migration "$1" 0000000002-broken.sh "$passes"
  migrate "$1" run
  printf ' retried=%s log=%s markers=%s\n' "$status" "$(log)" "$(markers)"
}
want_failure_stops="status=1 err=[vgsh-migrate: failed=0000000002-broken.sh status=3] log=0000000001-first,0000000002-broken-tried markers=0000000001-first.sh retried=0 log=0000000001-first,0000000002-broken-tried,0000000002-broken,0000000003-later markers=0000000001-first.sh,0000000002-broken.sh,0000000003-later.sh"
row_bad_name() { # TREE
  migration "$1" 0000000001-first.sh "$passes"
  migration "$1" 0000000002_Second.sh "$passes"
  fresh_home
  migrate "$1" run
  printf 'status=%s err=[%s] log=%s markers=%s\n' "$status" "$(err)" "$(log)" "$(markers)"
}
want_bad_name="status=2 err=[vgsh-migrate: refused: migration=0000000002_Second.sh want=<10 digits>-<slug>.sh] log= markers="
# What a migration runs with: no new privileges, stdin from /dev/null, the
# tree's root and its own name.
row_environment() { # TREE
  migration "$1" 0000000001-probe.sh 'printf "%s|%s|%s|%s\n" "$(grep NoNewPrivs /proc/self/status | tr -d "[:space:]")" "$(readlink /proc/self/fd/0)" "$VGS_ROOT" "$VGS_MIGRATION" >>"$HOME/log"'
  fresh_home
  migrate "$1" run
  printf 'status=%s log=%s\n' "$status" "$(log)"
}
row_pending() { # TREE
  migration "$1" 0000000001-first.sh "$passes"
  migration "$1" 0000000002-second.sh "$passes"
  fresh_home
  migrate "$1" pending
  printf 'status=%s out=[%s]' "$status" "$(out)"
  migrate "$1" run
  migrate "$1" pending
  printf ' after=%s out=[%s] log=%s\n' "$status" "$(out)" "$(log)"
}
want_pending="status=0 out=[0000000001-first.sh;0000000002-second.sh] after=0 out=[] log=0000000001-first,0000000002-second"
row_lock_busy() { # TREE
  migration "$1" 0000000001-first.sh "$passes"
  fresh_home
  mkdir -p -- "$home/.local/state/vgs/migrations"
  exec 7>>"$home/.local/state/vgs/migrations/.lock"
  flock 7
  migrate "$1" run
  exec 7>&-
  printf 'status=%s err=[%s] log=%s\n' "$status" "$(err | sed "s|$home|HOME|g")" "$(log)"
}
row_notice() { # TREE
  migration "$1" 0000000001-broken.sh "$fails"
  fresh_home
  migrate "$1" run
  printf 'plain=%s notices=%s' "$status" "$(notices)"
  migrate "$1" run --notice
  printf ' notice=%s notices=[%s]\n' "$status" "$(notices)"
}
want_notice="plain=1 notices=none notice=1 notices=[notify 0 600000 0 VGS could not finish updating your settings: migration 0000000001-broken failed. It runs again the next time VGS starts.]"
row_timeout() { # TREE
  migration "$1" 0000000001-stuck.sh 'sleep 5; printf "%s\n" "${VGS_MIGRATION%.sh}" >>"$HOME/log"'
  fresh_home
  migrate "$1" run
  printf 'status=%s err=[%s] log=%s markers=%s\n' "$status" "$(err)" "$(log)" "$(markers)"
}
want_timeout="status=1 err=[vgsh-migrate: failed=0000000001-stuck.sh status=124] log= markers="
# `vgsh run` runs the migrations before it starts the shell, shows the
# notice of a failed one and starts the shell all the same.
row_runner() { # TREE
  migration "$1" 0000000001-first.sh "$passes"
  migration "$1" 0000000002-broken.sh "$fails"
  fresh_home
  local rt="$home/rt" runner record="$home/record"
  mkdir -p -- "$rt"
  "${base_env[@]}" HOME="$home" XDG_RUNTIME_DIR="$rt" STUB_HYPR_LOG="$home/hyprctl.log" STUB_RECORD="$record" "$1/bin/vgsh" run </dev/null >"$home/out" 2>&1 &
  runner=$!
  for _ in $(seq 1 100); do [[ -s $record ]] && break; sleep 0.1; done # the runner starts the shell after its preflight and the migrations
  kill -TERM "$runner" 2>/dev/null || :
  wait "$runner" 2>/dev/null || :
  printf 'shell=[%s] lines=[%s] notices=%s\n' "$(cat -- "$record" 2>/dev/null || echo none)" \
    "$(grep -E '^vgsh(-migrate)?: (failed|migrate)=' -- "$home/out" | paste -sd';' - || :)" \
    "$(grep -c '^notify 0 600000 0 VGS could not finish updating your settings: migration 0000000002-broken failed' -- "$home/hyprctl.log" 2>/dev/null || :)"
}
want_runner="shell=[started log=0000000001-first,0000000002-broken-tried] lines=[vgsh-migrate: failed=0000000002-broken.sh status=3;vgsh: migrate=failed status=1] notices=1"
row_cli() { # TREE
  migration "$1" 0000000001-first.sh "$passes"
  fresh_home
  status=0
  "${base_env[@]}" HOME="$home" "$1/bin/vgsh" migrate --pending >"$tmp/out" 2>"$tmp/err" </dev/null || status=$?
  printf 'pending=%s out=[%s]' "$status" "$(out)"
  status=0
  "${base_env[@]}" HOME="$home" "$1/bin/vgsh" migrate >"$tmp/out" 2>"$tmp/err" </dev/null || status=$?
  printf ' run=%s out=[%s] log=%s\n' "$status" "$(out)" "$(log)"
}
want_cli="pending=0 out=[0000000001-first.sh] run=0 out=[vgsh-migrate: ran=0000000001-first.sh;vgsh-migrate: ok ran=1] log=0000000001-first"

# The timeout row runs on a copy whose bound is 1 s, not 20 s.
copy_with fast-timeout "$repo/bin/vgsh-migrate" 'migrate_timeout=20' 'migrate_timeout=1'
fast_timeout="$tmp/vgsh-migrate.fast-timeout"
mv -- "$copy" "$fast_timeout"

# rows: each `row LABEL FUNCTION WANT [MIGRATE]`, MIGRATE the
# bin/vgsh-migrate the row's tree copies in place of the one under test.
# @ROOT@ in WANT stands for the row's tree.
labels=() fns=() wants=() sources=()
row() { labels+=("$1") fns+=("$2") wants+=("$3") sources+=("${4:-}"); }
row "migrations run once each, in name order" row_order_once "$want_order_once"
row "a failed migration stops the later ones, gets no marker and runs again next time" row_failure_stops "$want_failure_stops"
row "a name outside the pattern refuses the run before any migration runs" row_bad_name "$want_bad_name"
row "a migration runs with no new privileges, stdin from /dev/null, the tree's root and its name" row_environment "status=0 log=NoNewPrivs:1|/dev/null|@ROOT@|0000000001-probe.sh"
row "pending lists the migrations not yet run" row_pending "$want_pending"
row "a held lock refuses a second run, which runs nothing" row_lock_busy "status=75 err=[vgsh-migrate: refused: lock=busy path=HOME/.local/state/vgs/migrations/.lock] log="
row "a failure shows a Hyprland notice only with --notice" row_notice "$want_notice"
row "a migration past the bound is stopped and fails" row_timeout "$want_timeout" "$fast_timeout"
row "vgsh run migrates before the shell starts, shows the notice of a failure and starts the shell" row_runner "$want_runner"
row "vgsh migrate runs the migrations and --pending lists them" row_cli "$want_cli"

# run_row INDEX MIGRATE VGSH: one row against a fresh tree from MIGRATE and
# VGSH; answers 0 when its verdict is its want, and leaves the two in
# $tmp/why otherwise.
run_row() {
  local got want
  make_tree "row-$1" "${sources[$1]:-$2}" "$3"
  got="$("${fns[$1]}" "$tree")"
  want="${wants[$1]//@ROOT@/$tree}"
  [[ $got == "$want" ]] && return 0
  printf 'got:  %s\nwant: %s\n' "$got" "$want" >"$tmp/why"
  return 1
}
for i in "${!labels[@]}"; do
  if run_row "$i" "$repo/bin/vgsh-migrate" "$repo/bin/vgsh"; then ok "${labels[i]}"; else fail "${labels[i]}: $(cat -- "$tmp/why")"; fi
done

# controls: label, the file under bin/, its text, the replacement and the
# index of the row that must fail, five entries per control. The copy
# stands in for that file in the row's tree.
controls=(
  "the name pattern is enforced" vgsh-migrate '[[ $name =~ $name_pattern ]] || refuse' 'true || refuse' 2
  "a migration with a marker is not run again" vgsh-migrate '[[ -n $name && ! -e $state/$name ]] && printf' '[[ -n $name ]] && printf' 0
  "a failure stops the run" vgsh-migrate '    if [[ $status -ne 0 ]]; then' '    if false; then' 1
  "no new privileges" vgsh-migrate 'setpriv --no-new-privs --' 'env --' 3
  "stdin from /dev/null" vgsh-migrate '</dev/null 8>&-' '8>&-' 3
  "the root is handed over" vgsh-migrate 'VGS_ROOT="$root" ' 'VGS_ROOT= ' 3
  "one run at a time" vgsh-migrate 'flock -n 8 || refuse' 'true || refuse' 5
  "the notice" vgsh-migrate 'if [[ $1 == true ]]; then' 'if false; then' 6
  "the notice only with --notice" vgsh-migrate 'if [[ $1 == true ]]; then' 'if true; then' 6
  "the bound" vgsh-migrate 'timeout "$migrate_timeout" \' 'env \' 7
  "the runner migrates" vgsh '    "$root/bin/vgsh-migrate" run --notice 9>&- ||' '    : ||' 8
  "the runner starts the shell after a failed migration" vgsh "run --notice 9>&- || printf 'vgsh: migrate=failed" "run --notice 9>&- || exit 1; printf 'vgsh: migrate=failed" 8
  "vgsh migrate reaches the runner" vgsh '      "") exec "$root/bin/vgsh-migrate" run ;;' '      "") exit 0 ;;' 9
)
for ((c = 0; c < ${#controls[@]}; c += 5)); do
  label="${controls[c]}" file="${controls[c + 1]}" index="${controls[c + 4]}"
  copy_with "control-$((c / 5))" "$repo/bin/$file" "${controls[c + 2]}" "${controls[c + 3]}"
  migrate_src="$repo/bin/vgsh-migrate" vgsh_src="$repo/bin/vgsh"
  if [[ $file == vgsh-migrate ]]; then migrate_src="$copy"; else vgsh_src="$copy"; fi
  # The bound's row runs its own copy with the short bound, so the bound's
  # control needs that bound in its copy too.
  saved="${sources[index]}"
  if [[ -n $saved && $file == vgsh-migrate ]]; then
    sed -i 's/^migrate_timeout=20$/migrate_timeout=1/' "$copy"
    sources[index]="$copy"
  fi
  if run_row "$index" "$migrate_src" "$vgsh_src"; then fail "control: $label: the row passes without the rule"; else ok "control: the row fails without the rule: $label"; fi
  sources[index]="$saved"
done

rows_done test-vgsh-migrate
