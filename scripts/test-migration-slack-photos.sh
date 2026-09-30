#!/usr/bin/env bash
# Controls for the Slack photos migration,
# bin/migrations/1790801764-slack-photos-extra.sh, and the judge verb it
# writes through, `vgsh-plugin-judge seed-setting`. Every row runs with a
# HOME of its own under $tmp and a PATH whose secret-tool is this suite's
# stub, which logs its argv and answers as the row sets it; the suite
# refuses to run when that PATH resolves any other secret-tool, and the
# migration refuses one outside the stub's directory. No row reaches a
# keyring, a session bus or the user's configuration. Expected values are
# written out by hand. The controls at the end run copies of the migration
# and of the judge with one rule removed, and a row must fail on each.
set -euo pipefail

repo="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo "test-migration-slack-photos: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-migration-slack-photos: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-migration-slack-photos: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
node_bin="$(node -e 'process.stdout.write(process.execPath)')" || { echo "test-migration-slack-photos: status=not-measured missing=node"; exit 77; }

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

migration_name=1790801764-slack-photos-extra.sh
token="xoxp-migration-secret-4f2a"
stubs="$TMP_ROOT/stubs"; mkdir -p "$stubs"
# The stub answers `search` as STUB_KEYRING says: `empty` finds nothing,
# `present` finds an item, `locked` finds one in a locked collection,
# `stdout-only` prints item-like text on stdout alone, `failed` prints an
# item's attributes and exits 1. A found item's secret goes to stdout, as
# secret-tool prints it.
cat >"$stubs/secret-tool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$STUB_LOG"
[[ \${1:-} == search ]] || exit 2
case "\${STUB_KEYRING:?}" in
  empty) ;;
  present) printf '[/1]\nlabel = VGS notifications Slack token slack:T1\nsecret = $token\n'; printf 'attribute.service = vgs-notifications\nattribute.account = slack:T1\n' >&2 ;;
  locked) printf '[/1]\nlabel = VGS notifications Slack token\n'; printf 'secret-tool: Cannot get secret of a locked object\nattribute.service = vgs-notifications\nattribute.account = slack\n' >&2 ;;
  stdout-only) printf 'attribute.account = slack:T1\nsecret = $token\n' ;;
  failed) printf 'attribute.service = vgs-notifications\n' >&2; exit 1 ;;
  timeout) exit 124 ;;
esac
EOF
chmod +x "$stubs/secret-tool"
tools="$TMP_ROOT/tools"; mkdir -p "$tools"
for tool in bash readlink timeout grep cat mkdir mv rm dirname; do
  found="$(command -v "$tool")" || { echo "test-migration-slack-photos: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$found" "$tools/$tool"
done
ln -s -- "$node_bin" "$tools/node"
path="$stubs:$tools"
[[ "$(PATH="$path" command -v secret-tool)" == "$stubs/secret-tool" ]] || { echo "test-migration-slack-photos: secret-tool=not-the-stub" >&2; exit 1; }

# One run of MIGRATION, a copy or the shipped one, as vgsh-migrate runs it,
# with VGS_ROOT ROOT, a tree holding JUDGE as bin/vgsh-plugin-judge; the
# row's HOME is $home. Stdout in $home/out, stderr in $home/err, the status
# in $status.
fresh_home() { home="$(mktemp -d "$TMP_ROOT/home-XXXXXX")"; mkdir -p "$home/.config/vgs"; }
root_with() { # JUDGE: a tree whose judge is JUDGE, the rest the repository's
  local root="$TMP_ROOT/root-$(basename -- "$1")-$RANDOM"
  mkdir -p "$root/bin"
  ln -s -- "$repo/bin/lib" "$root/bin/lib"
  ln -s -- "$repo/shell" "$root/shell"
  ln -s -- "$repo/config" "$root/config"
  cp -- "$1" "$root/bin/vgsh-plugin-judge"
  printf '%s\n' "$root"
}
run_migration() { # MIGRATION ROOT KEYRING [PATH]
  status=0
  env -i PATH="${4:-$path}" HOME="$home" VGS_ROOT="$2" VGS_MIGRATION="$migration_name" STUB_LOG="$home/secret-tool.log" STUB_KEYRING="$3" \
    VGS_NOTIFICATIONS_SLACK_TEST_SECRET_TOOL_DIR="$stubs" bash -euo pipefail "$1" </dev/null >"$home/out" 2>"$home/err" || status=$?
}
user_row() { # the vgs.notifications row of the user file, or `absent`
  if [[ ! -e $home/.config/vgs/shell.json ]]; then echo absent; return; fi
  node -e 'const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const r = (d.plugins || []).find(p => p.id === "vgs.notifications"); process.stdout.write(JSON.stringify(r === undefined ? null : r));' "$home/.config/vgs/shell.json"
}
calls() { if [[ -e $home/secret-tool.log ]]; then paste -sd';' - <"$home/secret-tool.log"; else echo none; fi; }
leaks() { grep -rlF --exclude=secret-tool.log -- "$token" "$home" | wc -l; }

# Each row sets up $home and prints one verdict line.
row_fresh() { fresh_home; run_migration "$1" "$2" empty; printf 'status=%s out=%s row=%s calls=%s\n' "$status" "$(cat "$home/out")" "$(user_row)" "$(calls)"; }
row_present() {
  fresh_home
  printf '{ "version": 1, "plugins": [ { "id": "vgs.notifications", "duration": 12 } ] }\n' >"$home/.config/vgs/shell.json"
  run_migration "$1" "$2" present
  printf 'status=%s out=%s row=%s calls=%s leaks=%s\n' "$status" "$(cat "$home/out")" "$(user_row)" "$(calls)" "$(leaks)"
}
row_locked() { fresh_home; run_migration "$1" "$2" locked; printf 'status=%s out=%s row=%s\n' "$status" "$(cat "$home/out")" "$(user_row)"; }
row_stdout_only() { fresh_home; run_migration "$1" "$2" stdout-only; printf 'status=%s out=%s row=%s leaks=%s\n' "$status" "$(cat "$home/out")" "$(user_row)" "$(leaks)"; }
row_cache() {
  fresh_home
  mkdir -p "$home/.cache/vgs/notifications/slack-photos"
  printf '{"slack:T1": {}}\n' >"$home/.cache/vgs/notifications/slack-photos/accounts.json"
  run_migration "$1" "$2" empty
  printf 'status=%s out=%s row=%s calls=%s\n' "$status" "$(cat "$home/out")" "$(user_row)" "$(calls)"
}
row_cache_empty() {
  fresh_home
  mkdir -p "$home/.cache/vgs/notifications/slack-photos"
  printf '{}\n' >"$home/.cache/vgs/notifications/slack-photos/accounts.json"
  run_migration "$1" "$2" empty
  printf 'status=%s out=%s calls=%s\n' "$status" "$(cat "$home/out")" "$(calls)"
}
row_explicit() {
  fresh_home
  printf '{ "version": 1, "plugins": [ { "id": "vgs.notifications", "slackPhotos": false } ] }\n' >"$home/.config/vgs/shell.json"
  run_migration "$1" "$2" present
  printf 'status=%s out=%s row=%s\n' "$status" "$(cat "$home/out")" "$(user_row)"
}
row_no_tool() { fresh_home; run_migration "$1" "$2" present "$tools"; printf 'status=%s out=%s row=%s\n' "$status" "$(cat "$home/out")" "$(user_row)"; }
row_timeout() { fresh_home; run_migration "$1" "$2" timeout; printf 'status=%s err=%s row=%s\n' "$status" "$(cat "$home/err")" "$(user_row)"; }
row_utf8() {
  fresh_home
  printf '{ "version": 1, "plugins": [ { "id": "vgs.notifications", "duration": 12 } ], "bar": { "layout": { "center": [ { "id": "acme.clock", "format": "Z\xc3\xbcrich \xe2\x86\x92 %%H" } ] } } }\n' >"$home/.config/vgs/shell.json"
  run_migration "$1" "$2" present
  printf 'status=%s format=%s\n' "$status" "$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).bar.layout.center[0].format)' "$home/.config/vgs/shell.json")"
}
row_failed() { fresh_home; run_migration "$1" "$2" failed; printf 'status=%s out=%s row=%s\n' "$status" "$(cat "$home/out")" "$(user_row)"; }
row_foreign_tool() {
  fresh_home
  local other="$TMP_ROOT/other-bin"; mkdir -p "$other"
  cp -- "$stubs/secret-tool" "$other/secret-tool"
  run_migration "$1" "$2" present "$other:$tools"
  printf 'status=%s err=%s calls=%s\n' "$status" "$(cat "$home/err")" "$(calls)"
}
row_symlink() {
  fresh_home
  mkdir -p "$home/dotfiles"
  printf '{ "version": 1 }\n' >"$home/dotfiles/shell.json"
  ln -s -- ../../dotfiles/shell.json "$home/.config/vgs/shell.json"
  run_migration "$1" "$2" present
  printf 'status=%s link=%s row=%s\n' "$status" "$(readlink -- "$home/.config/vgs/shell.json")" "$(user_row)"
}
# The judge verb's refusals, run directly: an undeclared key, a value of
# another type than its default and a schema key's value outside its
# bounds.
row_judge_refusals() { # MIGRATION ROOT
  fresh_home
  local judge="$2/bin/vgsh-plugin-judge" plugin="$repo/shell/plugins/vgs.notifications" user="$home/.config/vgs/shell.json" out=()
  local key value
  for key_value in 'nope true' 'slackPhotos "yes"' 'duration 99'; do
    read -r key value <<<"$key_value"
    status=0
    env -i PATH="$tools" HOME="$home" node "$judge" seed-setting "$repo/config/shell.json" "$user" "$plugin" "$key" "$value" >/dev/null 2>"$home/err" || status=$?
    out+=("$status:$(cat "$home/err")")
  done
  printf '%s|' "${out[@]}"
  printf 'file=%s\n' "$(user_row)"
}

rows=(
  "a fresh profile with no token leaves the extra off and writes nothing|row_fresh|status=0 out=slack-photos: extra=off evidence=none row=absent calls=search service vgs-notifications"
  "a token in the keyring turns the extra on in the user's row, keeping its other keys, and reads no token|row_present|status=0 out=slack-photos: extra=written evidence=keyring row={\"id\":\"vgs.notifications\",\"duration\":12,\"slackPhotos\":true} calls=search service vgs-notifications leaks=0"
  "a token in a locked collection counts, with no unlock|row_locked|status=0 out=slack-photos: extra=written evidence=keyring row={\"id\":\"vgs.notifications\",\"slackPhotos\":true}"
  "text on the search's stdout, where a secret prints, is never read|row_stdout_only|status=0 out=slack-photos: extra=off evidence=none row=absent leaks=0"
  "the photo cache's record of a served account turns the extra on without asking the keyring|row_cache|status=0 out=slack-photos: extra=written evidence=cache row={\"id\":\"vgs.notifications\",\"slackPhotos\":true} calls=none"
  "an empty cache record is no evidence, so the keyring is asked|row_cache_empty|status=0 out=slack-photos: extra=off evidence=none calls=search service vgs-notifications"
  "a row that names the extra keeps the user's choice|row_explicit|status=0 out=slack-photos: extra=unchanged evidence=keyring row={\"id\":\"vgs.notifications\",\"slackPhotos\":false}"
  "no secret-tool leaves the extra off|row_no_tool|status=0 out=slack-photos: extra=off evidence=none keyring=no-secret-tool row=absent"
  "a failed search is no evidence|row_failed|status=0 out=slack-photos: extra=off evidence=none keyring=failed status=1 row=absent"
  "a secret-tool outside the test stub's directory is refused before it runs|row_foreign_tool|status=5 err=slack-photos: secret-tool=test-stub-required calls=none"
  "a symlinked user file stays a link|row_symlink|status=0 link=../../dotfiles/shell.json row={\"id\":\"vgs.notifications\",\"slackPhotos\":true}"
  "a search that times out fails the migration, so it runs again|row_timeout|status=1 err=slack-photos: keyring=timeout row=absent"
  "the user file's other text keeps its UTF-8|row_utf8|status=0 format=Zürich → %H"
  "the judge refuses an undeclared key, a value of another type and one outside its bounds|row_judge_refusals|1:vgsh: refused: setting=nope undeclared|1:vgsh: refused: setting=slackPhotos want=boolean|1:vgsh: refused: setting=duration want=at-most:30|file=absent"
)
shipped_root="$(root_with "$repo/bin/vgsh-plugin-judge")"
# run_row INDEX MIGRATION ROOT: 0 when the row's verdict is its want.
run_row() {
  local fn="${rows[$1]#*|}" want got
  want="${fn#*|}"; fn="${fn%%|*}"
  got="$("$fn" "$2" "$3")"
  [[ $got == "$want" ]] && return 0
  printf 'got:  %s\nwant: %s\n' "$got" "$want" >"$TMP_ROOT/why"
  return 1
}
for i in "${!rows[@]}"; do
  if run_row "$i" "$repo/bin/migrations/$migration_name" "$shipped_root"; then ok "${rows[i]%%|*}"; else fail "${rows[i]%%|*}: $(cat -- "$TMP_ROOT/why")"; fi
done

# controls: label, the file, its text, the replacement and the index of the
# row that must fail, five entries per control.
controls=(
  "the search's stdout is discarded" "bin/migrations/$migration_name" '2>&1 >/dev/null)' '2>&1)' 3
  "the search unlocks nothing" "bin/migrations/$migration_name" 'secret-tool search service' 'secret-tool search --unlock service' 0
  "the cache is read first" "bin/migrations/$migration_name" 'if cache_served; then' 'if false; then' 4
  "an empty cache record is no evidence" "bin/migrations/$migration_name" 'Object.keys(d).length > 0' 'true' 5
  "a found item turns the extra on" "bin/migrations/$migration_name" "elif grep -q '^attribute\.' <<<\"\$err\"; then" 'elif false; then' 1
  "a failed search is no evidence" "bin/migrations/$migration_name" '  elif [[ $status -ne 0 ]]; then' '  elif false; then' 8
  "a secret-tool outside the stub's directory is refused" "bin/migrations/$migration_name" '[[ -z $stub_dir || -z $real_tool || $real_tool != "$stub_dir"/* ]]' 'false' 9
  "the user's choice stays" bin/vgsh-plugin-judge 'if (row !== undefined && logic.hasOwn(row, key)) return null;' '' 6
  "the row keeps its other keys" bin/vgsh-plugin-judge 'logic.withSetting(user, manifest, key, value, effective, ["plugins"])' 'logic.withSetting(null, manifest, key, value, {}, ["plugins"])' 1
  "a link stays a link" bin/vgsh-plugin-judge 'const failure = editFile("user-config", userPath, true, current => {' 'const failure = ((key, file, create, edit) => { const next = edit(require("fs").existsSync(file) ? "" : undefined); if (next !== null) { require("fs").rmSync(file, { force: true }); require("fs").writeFileSync(file, next); } return null; })("user-config", userPath, true, current => {' 10
  "an undeclared key is refused" bin/vgsh-plugin-judge 'if (!logic.hasOwn(manifest.settings, key)) refuse(' 'if (false) refuse(' 13
  "a value of another type is refused" bin/vgsh-plugin-judge '} else if (value === null || typeof value !== typeof manifest.settings[key]) {' '} else if (false) {' 13
  "a schema key's value is judged" bin/vgsh-plugin-judge 'const refusal = logic.settingRefusal(manifest, key, value);' 'const refusal = "";' 13
  "a search that times out fails" "bin/migrations/$migration_name" '  if [[ $status -eq 124 ]]; then' '  if false; then' 11
  "the user file is written as UTF-8" bin/vgsh-plugin-judge '"utf8").toString("latin1");' '"latin1").toString("latin1");' 12
)
mkdir -p "$TMP_ROOT/copies"
for ((c = 0; c < ${#controls[@]}; c += 5)); do
  label="${controls[c]}" file="${controls[c + 1]}" needle="${controls[c + 2]}" index="${controls[c + 4]}"
  copy="$TMP_ROOT/copies/$((c / 5))-$(basename -- "$file")"
  count="$(grep -cF -- "$needle" "$repo/$file" || true)"
  if [[ $count != 1 ]]; then fail "control: $label: the text occurs $count times, want 1"; continue; fi
  NEEDLE="$needle" REPLACEMENT="${controls[c + 3]}" python3 -c 'import os, sys
text = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(text.replace(os.environ["NEEDLE"], os.environ["REPLACEMENT"], 1))' "$repo/$file" "$copy"
  migration="$repo/bin/migrations/$migration_name" root="$shipped_root"
  if [[ $file == bin/vgsh-plugin-judge ]]; then root="$(root_with "$copy")"; else migration="$copy"; fi
  if run_row "$index" "$migration" "$root"; then fail "control: $label: the row passes without the rule"; else ok "control: the row fails without the rule: $label"; fi
done

if [[ $failures -gt 0 ]]; then echo "test-migration-slack-photos: failed=$failures"; exit 1; fi
echo "test-migration-slack-photos: ok controls=$((${#controls[@]} / 5))"
