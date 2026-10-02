#!/usr/bin/env bash
# Controls for the checks scripts/validate makes itself, run as
# `scripts/validate repo`, or `scripts/validate tools` for the document byte
# ceiling row, in a scratch repository: a copy of the script and
# the kendex settings loader, a base branch `trunk` with its remote-tracking
# ref, and a feature branch on top. Each row plants one defect in a fresh
# copy and asserts the exit status and the keyed lines the script's header
# promises; one row plants nothing and passes.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
# One row removes a file's permission bits, which bind only a non-root uid;
# a run that could not measure it is not a pass.
if [[ $(id -u) == 0 ]]; then
  echo "test-validate: status=not-measured reason=euid-0"
  exit 77
fi
tmp="$(mktemp -d)"
trap 'chmod -R u+rwx -- "${tmp:?}" 2>/dev/null; rm -rf -- "${tmp:?}"' EXIT

# Every git and validate call runs with this environment and nothing else.
# Fixed identities and dates make every fixture's trunk the same commit, so
# one trunk id names the base of every row.
# Resolve node before replacing HOME: a version-manager shim may need the
# developer's configuration, which does not belong in the test environment.
node_bin="$(node -e 'process.stdout.write(process.execPath)')"
mkdir -p "$tmp/home/.config" "$tmp/home/.cache" "$tmp/home/.local/share" "$tmp/home/.local/state" "$tmp/runtime"
chmod 700 "$tmp/runtime"
base_env=(env -i PATH="$(dirname -- "$node_bin"):$PATH" HOME="$tmp/home" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  JARVIS_TEST_SCRATCH_ROOT="$repo/tmp"
  XDG_CONFIG_HOME="$tmp/home/.config" XDG_CACHE_HOME="$tmp/home/.cache" XDG_DATA_HOME="$tmp/home/.local/share" XDG_STATE_HOME="$tmp/home/.local/state" XDG_RUNTIME_DIR="$tmp/runtime"
  TMPDIR="$tmp"
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z)

failures=0
test_args=()
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# A fresh scratch repository at $1: trunk holds the script, the loader, the
# md-refs checker with an exclusion list that keeps its own copy out of its
# scope, a settings file naming trunk as the base branch and one clean file;
# refs/remotes/origin/trunk points at it; HEAD is a feature branch on top.
fresh() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/.agents/skills/orch/scripts/lib" "$dir/.agents/skills/commit-guards" "$dir/tools"
  cp -- "$repo/scripts/validate" "$dir/scripts/validate"
  cp -- "$repo/.agents/skills/orch/scripts/lib/kendex-env.sh" "$dir/.agents/skills/orch/scripts/lib/kendex-env.sh"
  cp -R -- "$repo/.agents/skills/commit-guards/scripts" "$dir/.agents/skills/commit-guards/"
  printf '# kendex-guard-dialect: legacy-glob\n.agents/*\tcopies of checkers, whose citations name their own repository\n' >"$dir/tools/md-excludes"
  printf '[env]\nWORKTREE_DEFAULT_BRANCH = "trunk"\n' >"$dir/kendex.settings.toml"
  printf 'clean\n' >"$dir/clean.txt"
  "${base_env[@]}" git -C "$dir" init -q -b trunk
  "${base_env[@]}" git -C "$dir" add -A
  "${base_env[@]}" git -C "$dir" commit -q -m base
  "${base_env[@]}" git -C "$dir" update-ref refs/remotes/origin/trunk HEAD
  "${base_env[@]}" git -C "$dir" checkout -q -b feature
}

# row NAME DIR WANT_EXIT EXTRA_ENV LINE...: run `scripts/validate repo` in
# DIR under EXTRA_ENV (words of NAME=VALUE, or "") and assert its exit
# status and that each LINE is a whole line of its output. A LINE written
# !TEXT asserts instead that TEXT appears nowhere in the output.
row() {
  local name="$1" dir="$2" want_exit="$3" extra="$4" out status=0 line missing="" present=""
  shift 4
  # shellcheck disable=SC2086
  out="$(cd -- "$dir" && "${base_env[@]}" $extra bash scripts/validate "${test_area:-repo}" "${test_args[@]}" 2>&1)" || status=$?
  for line in "$@"; do
    if [[ $line == '!'* ]]; then
      ! grep -qF -e "${line:1}" <<<"$out" || present+="[${line:1}]"
    else
      grep -qxF -e "$line" <<<"$out" || missing+="[$line]"
    fi
  done
  if [[ $status == "$want_exit" && -z $missing && -z $present ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit missing=$missing present=$present"; printf '%s\n' "$out" | sed 's/^/        /'; fi
}

row_re() {
  local name="$1" dir="$2" want_exit="$3" extra="$4" out status=0 line missing="" present=""
  shift 4
  # shellcheck disable=SC2086
  out="$(cd -- "$dir" && "${base_env[@]}" $extra bash scripts/validate "${test_area:-repo}" "${test_args[@]}" 2>&1)" || status=$?
  for line in "$@"; do
    if [[ ${line:0:1} == '!' ]]; then
      ! grep -qF -e "${line:1}" <<<"$out" || present+="[${line:1}]"
    elif [[ ${line:0:1} == '~' ]]; then
      grep -qF -e "${line:1}" <<<"$out" || missing+="[${line:1}]"
    else
      grep -qxF -e "$line" <<<"$out" || missing+="[$line]"
    fi
  done
  if [[ $status == "$want_exit" && -z $missing && -z $present ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit missing=$missing present=$present"; printf '%s\n' "$out" | sed 's/^/        /'; fi
}

plan_case() {
  local name="$1" changed="$2" want_scope="$3" want_runs="$4" want_total="$5" out status=0 run_count skip_count
  out="$(printf '%s\0' "$changed" >"$tmp/qml-plan.paths" && VGS_VALIDATE_CHANGED="$tmp/qml-plan.paths" "$repo/scripts/test-qml-unit.sh" --plan 2>&1)" || status=$?
  run_count="$(grep -c '^run ' <<<"$out" || true)"
  skip_count="$(grep -c '^skip ' <<<"$out" || true)"
  if [[ $status == 0 ]] &&
     grep -qxF "test-qml-unit: scope=changed mutations=$want_scope" <<<"$out" &&
     [[ $run_count == "$want_runs" && $((run_count + skip_count)) == "$want_total" ]]; then
    ok "$name"
  else
    fail "$name: status=$status runs=$run_count total=$((run_count + skip_count))"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

# The mutation total, read from the table itself rather than from --plan:
# every line of the `mutations=(...)` array is one quoted row, and a line of
# another shape there means the read no longer matches the table. The floor
# names a broken read, not a short table.
qml_total="$(awk '/^mutations=\($/ { inside = 1; next } inside && /^\)$/ { inside = 0 } inside' "$repo/scripts/test-qml-unit.sh")" || qml_total=""
qml_odd="$(grep -cv '^  "[^"].*"$' <<<"$qml_total" || true)"
qml_total="$(grep -c '^  "' <<<"$qml_total" || true)"
if [[ $qml_odd != 0 || $qml_total -lt 100 ]]; then
  fail "qml mutation table read: rows=$qml_total other-lines=$qml_odd; the array read in test-validate.sh no longer matches scripts/test-qml-unit.sh"
  qml_total=unread
fi
if out="$(env -u VGS_VALIDATE_CHANGED "$repo/scripts/test-qml-unit.sh" --plan 2>&1)" &&
   grep -qxF "test-qml-unit: scope=all mutations=$qml_total/$qml_total" <<<"$out" &&
   [[ "$(grep -c '^run ' <<<"$out")" == "$qml_total" ]]; then
  ok "qml mutation planning runs every row when the changed list is unset"
else
  fail "qml mutation planning with no changed list: table rows=$qml_total"
  printf '%s\n' "$out" | sed 's/^/        /'
fi
plan_case "qml mutation planning narrows to a changed Radio target" "shell/Ui/controls/Radio.qml" "3/$qml_total" 3 "$qml_total"
plan_case "qml mutation planning runs every row for a harness change" "scripts/qml-unit.sh" "$qml_total/$qml_total" "$qml_total" "$qml_total"
status=0
out="$(VGS_VALIDATE_CHANGED="$tmp/missing-qml-plan.paths" "$repo/scripts/test-qml-unit.sh" --plan 2>&1)" || status=$?
if [[ $status == 1 && $out == "test-qml-unit: refused: changed-list=unreadable path=$tmp/missing-qml-plan.paths" ]]; then
  ok "qml mutation planning refuses an unreadable changed list"
else
  fail "qml mutation planning unreadable list: status=$status output=$out"
fi

d="$tmp/clean"; fresh "$d"
trunk="$("${base_env[@]}" git -C "$d" rev-parse refs/remotes/origin/trunk)"
row "a clean tree passes against the base the settings file names" "$d" 0 "" \
  "whitespace: base=$trunk" "validate: ok"

d="$tmp/tracked"; fresh "$d"; printf 'clean \n' >"$d/clean.txt"
row "trailing whitespace in a tracked change fails" "$d" 1 "" \
  "whitespace: findings scope=tracked" "whitespace: failed base=$trunk"

# A committed defect: the feature branch holds its own commit, so HEAD is
# ahead of the merge base and only a diff from the merge base sees the line.
d="$tmp/committed"; fresh "$d"; printf 'feature \n' >"$d/feature.txt"
"${base_env[@]}" git -C "$d" add feature.txt
"${base_env[@]}" git -C "$d" commit -q -m feature
if [[ "$("${base_env[@]}" git -C "$d" rev-parse HEAD)" != "$trunk" ]]; then ok "the committed fixture's HEAD is ahead of trunk"; else fail "the committed fixture's HEAD is trunk"; fi
row "trailing whitespace in a committed change on the branch fails" "$d" 1 "" \
  "whitespace: findings scope=tracked" "whitespace: failed base=$trunk"

d="$tmp/quoted"; fresh "$d"; mkdir -p "$d/dé"; printf 'x \n' >"$d/dé/f.txt"
row "trailing whitespace in an untracked file whose name git quotes fails" "$d" 1 "" \
  "whitespace: findings scope=untracked path=dé/f.txt" "whitespace: failed base=$trunk"

d="$tmp/unreadable"; fresh "$d"; printf 'x\n' >"$d/locked.txt"; chmod 000 "$d/locked.txt"
row "an unreadable untracked file is an error, not a pass" "$d" 1 "" \
  "whitespace: unreadable scope=untracked path=locked.txt status=128" "whitespace: failed base=$trunk"

d="$tmp/no-base"; fresh "$d"
row "no resolvable base exits 77" "$d" 77 "WORKTREE_DEFAULT_BRANCH=absent" \
  "validate: status=not-measured reason=no-base missing=base-ref branch=absent remote-refs=0"

d="$tmp/orphan"; fresh "$d"; printf 'true\n' >"$d/scripts/test-orphan.sh"
row "a scripts/test-* file named by no row is refused" "$d" 1 "" \
  "validate: refused: test-without-row=scripts/test-orphan.sh"

# A suite whose name is a proper prefix of a listed one: the fixture's
# validate lists scripts/test-validate.sh, and scripts/test-validate is
# covered by no row.
d="$tmp/prefix"; fresh "$d"; printf 'true\n' >"$d/scripts/test-validate"
row "a scripts/test-* file whose name prefixes a listed suite is refused" "$d" 1 "" \
  "validate: refused: test-without-row=scripts/test-validate"

# The runtime boundary: one file planted per row, untracked unless the row
# says committed. A load of scripts/ under bin/ or shell/ is refused with the
# count and the line; prose, markdown, a scripts directory under another
# name and a file outside bin/ and shell/ pass.
runtime_cases=(
  'path.join component|bin/judge|untracked|1|const l = require(path.join(repo, "scripts", "qml-library.js"));'
  'committed path.join component|bin/judge|committed|1|const l = require(path.join(repo, "scripts", "qml-library.js"));'
  'variable expansion|bin/vgsh|untracked|1|check="$root/scripts/check-manifests.js"'
  'braced expansion|bin/tool|untracked|1|. "${repo}/scripts/lib.sh"'
  'relative climb|bin/tool|untracked|1|node "$(dirname -- "$0")/../scripts/x.js"'
  'QML import|shell/Core/X.qml|untracked|1|import "../../scripts"'
  'python component|shell/plugins/acme.p/helper.py|untracked|1|ROOT = os.path.join(HERE, '"'"'scripts'"'"', "x.py")'
  'comment naming a test|bin/judge|untracked|0|// scripts/test-plugin-logic.js runs this under node.'
  'markdown|shell/AGENTS.md|untracked|0|node reads "$root/scripts/qml-library.js".'
  'scripts under another name|shell/plugins/acme.p/Run.qml|untracked|0|property url run: Qt.resolvedUrl("helpers/scripts/run.sh")'
  'outside bin and shell|scripts/tool.sh|untracked|0|. "$root/scripts/lib.sh"'
)
for spec in "${runtime_cases[@]}"; do
  IFS='|' read -r name file state want text <<<"$spec"
  d="$tmp/runtime-${name// /-}"; fresh "$d"
  mkdir -p -- "$d/$(dirname -- "$file")"
  printf '%s\n' "$text" >"$d/$file"
  if [[ $state == committed ]]; then
    "${base_env[@]}" git -C "$d" add -- "$file"
    "${base_env[@]}" git -C "$d" commit -q -m planted
  fi
  if [[ $want == 1 ]]; then
    row "a $name under $file is refused" "$d" 1 "" \
      "validate: refused: runtime-reads-scripts=1" "$file:1:$text"
  else
    row "a $name under $file passes" "$d" 0 "" "validate: the runtime loads nothing under scripts/"
  fi
done

d="$tmp/runtime-unreadable"; fresh "$d"; mkdir -p "$d/bin"; printf 'x\n' >"$d/bin/locked"; chmod 000 "$d/bin/locked"
row "a file under bin/ the boundary check cannot read is an error, not a pass" "$d" 1 "" \
  "validate: unreadable: runtime-reads-scripts status=1"

# The private-key check: one PEM key planted per row, header, a body marker
# and footer, untracked unless the row says committed or ignored. An ignored
# row lists tmp/ in the fixture's .gitignore. The shape is a block of three
# lines, a one-line JSON string joined by literal backslash-n, or a JS
# template literal whose header sits partway along its first line. A
# private-key header of any type is refused with the count and the header
# alone, and the body marker appears nowhere in the output; a certificate, a
# public key, a line that spells the check's pattern and an ignored key pass.
# The armor is assembled here and never written whole, so this file holds no
# header the check or a secret scanner would match.
pem_begin='-----BEGIN'
pem_end='-----END'
key_cases=(
  'private key|keys/test.pem|untracked|1|PRIVATE KEY|block'
  'committed private key|keys/committed.pem|committed|1|PRIVATE KEY|block'
  'RSA private key|id_rsa|untracked|1|RSA PRIVATE KEY|block'
  'OpenSSH private key|shell/plugins/acme.p/key|untracked|1|OPENSSH PRIVATE KEY|block'
  'PGP private key block|docs/key.asc|untracked|1|PGP PRIVATE KEY BLOCK|block'
  'one-line JSON private key|keys/service-account.json|untracked|1|PRIVATE KEY|json'
  'private key partway along a line|scripts/fixture.js|untracked|1|PRIVATE KEY|inline'
  'certificate|keys/cert.pem|untracked|0|CERTIFICATE|block'
  'public key|keys/key.pub|untracked|0|PUBLIC KEY|block'
  'line naming the pattern|notes.txt|untracked|0|[A-Z ]*PRIVATE KEY( BLOCK)?|block'
  'git-ignored private key|tmp/key.pem|ignored|0|PRIVATE KEY|block'
)
for spec in "${key_cases[@]}"; do
  IFS='|' read -r name file state want type shape <<<"$spec"
  d="$tmp/key-${name// /-}"; fresh "$d"
  mkdir -p -- "$d/$(dirname -- "$file")"
  header="$pem_begin $type-----"
  footer="$pem_end $type-----"
  case "$shape" in
    block) printf '%s\nBODYMARKER\n%s\n' "$header" "$footer" ;;
    json) printf '{"private_key": "%s\\nBODYMARKER\\n%s\\n"}\n' "$header" "$footer" ;;
    inline) printf 'const KEY = `%s\nBODYMARKER\n%s`;\n' "$header" "$footer" ;;
    *) echo "test-validate: key-case shape=$shape unknown" >&2; exit 1 ;;
  esac >"$d/$file"
  case "$state" in
    untracked) ;;
    committed)
      "${base_env[@]}" git -C "$d" add -- "$file"
      "${base_env[@]}" git -C "$d" commit -q -m planted ;;
    ignored) printf 'tmp/\n' >"$d/.gitignore" ;;
    *) echo "test-validate: key-case state=$state unknown" >&2; exit 1 ;;
  esac
  if [[ $want == 1 ]]; then
    row "a $name in $file is refused" "$d" 1 "" \
      "validate: refused: private-key=1" "$file:1:$header" '!BODYMARKER'
  else
    row "a $name in $file passes" "$d" 0 "" "validate: no private key in the tree"
  fi
done

d="$tmp/key-unreadable"; fresh "$d"; printf 'x\n' >"$d/locked.pem"; chmod 000 "$d/locked.pem"
row "a file the private-key check cannot read is an error, not a pass" "$d" 1 "" \
  "validate: unreadable: private-key status=1"

# Exercise the real manifest rows, including the static smoke fixtures. The
# checker controls run unchanged; this control proves validate includes the
# fixture tree, so removing that row makes the planted defect pass wrongly.
d="$tmp/smoke-fixtures"; fresh "$d"
cp -R "$repo/scripts/." "$d/scripts/"
cp -R "$repo/shell" "$repo/bin" "$repo/config" "$repo/themes" "$repo/packaging" "$d/"
cp -- "$repo/VERSION" "$repo/LICENSE" "$repo/README.md" "$d/"
# The token check walks the skill templates beside the shell tree.
mkdir -p "$d/.agents/skills/vgs-plugin"
cp -R "$repo/.agents/skills/vgs-plugin/templates" "$d/.agents/skills/vgs-plugin/"
test_area=manifests
row "the smoke fixtures pass the offline manifest area" "$d" 0 "" "validate: ok"
python3 - "$d/scripts/smoke/fixtures/plugins/acme.tick/manifest.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as source:
    manifest = json.load(source)
manifest["schemaVersion"] = 0
with open(path, "w") as target:
    json.dump(manifest, target)
PY
row "a broken smoke fixture manifest fails the offline manifest area" "$d" 1 "" \
  "validate: failed=smoke fixture manifests (exit 1)"

# Selection is checked through the command the caller will run. Expected
# plans name consumers independently of the dependency table under test.
repo_plan=$'whitespace_check\nrows_cover_tests\nruntime_reads_no_scripts\nprivate_keys_check\nmd_refs_check'
install_plan=$'scripts/test-install-tree.sh\n'"$repo_plan"
installer_plan=$'scripts/test-install-tree.sh\nscripts/test-vgsh-self.sh\nscripts/test-install-sh.sh\nscripts/test-release.sh\n'"$repo_plan"
# The README check reads VERSION, bin/vgsh, install.sh, the Arch recipes,
# the plugins, README.md and docs/architecture/runtime.md.
readme_rows=$'node scripts/check-readme.js\nnode scripts/test-check-readme.js\nscripts/test-readme-install.sh\n'
readme_rows_trimmed="${readme_rows%$'\n'}"
readme_plan="$readme_rows$repo_plan"
curl_installer_plan="$readme_rows"$'scripts/test-install-sh.sh\nscripts/test-release.sh\n'"$repo_plan"
heap_plan=$'python3 scripts/test-attribute-heap-profile.py\n'"$repo_plan"
jarvis_local_rows=$'python3 scripts/test-jarvis-local.py\nscripts/check-jarvis-local.sh\n'
jarvis_local_tools_plan=$'python3 scripts/check-readme-images.py\npython3 scripts/test-jarvis-local.py\npython3 scripts/test-jarvis-setup.py\nscripts/check-jarvis-local.sh'
jarvis_env_plan=$'node scripts/test-jarvis-env.js\n'"$repo_plan"
jarvis_helper_plan=$'node scripts/test-jarvis-env.js\npython3 scripts/test-jarvis-local.py\npython3 scripts/test-jarvis-setup.py\nscripts/check-jarvis-local.sh\n'"$repo_plan"
jarvis_policy_rows=$'node scripts/test-jarvis-tools.js\nnode scripts/test-jarvis-policy.js\nnode scripts/test-jarvis-redact.js\nnode scripts/test-jarvis-release.js\nnode scripts/test-jarvis-net.js\nnode scripts/test-jarvis-brain-openai.js\nnode scripts/test-jarvis-brain-anthropic.js\nnode scripts/test-jarvis-live.js\nnode scripts/test-jarvis-denied.js\nnode scripts/test-jarvis-audit.js\nnode scripts/test-jarvis-router.js\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-desktop.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-browser-setup.js\nnode scripts/test-jarvis-mcp.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex-protocol.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-sandbox.js\nnode scripts/test-jarvis-child.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\n'
jarvis_audio_rows=$'node scripts/test-jarvis-audio.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nnode scripts/test-jarvis-playback.js\nnode scripts/test-jarvis-playback-pipewire.js\n'
jarvis_accounts_rows=$'node scripts/test-jarvis-accounts.js\nnode scripts/test-jarvis-accounts-tui.js\nnode scripts/test-jarvis-account-verify.js\n'
jarvis_secrets_plan=$'node scripts/test-jarvis-net.js\nnode scripts/test-jarvis-secrets.js\n'"$jarvis_accounts_rows$repo_plan"
jarvis_owner_plan="$jarvis_policy_rows"$'node scripts/test-jarvis-tasks.js\nnode scripts/test-jarvis-daemon.js\n'"$jarvis_audio_rows"$'node scripts/test-task-event.js\nnode scripts/test-jarvis-task-runner.js\nnode scripts/test-jarvis-secrets.js\n'"$jarvis_accounts_rows"$'scripts/test-install-tree.sh\n'"$jarvis_helper_plan"
jarvis_daemon_plan=$'node scripts/test-jarvis-daemon.js\n'"$repo_plan"
jarvis_live_plan=$'node scripts/test-jarvis-live.js\n'"$repo_plan"
jarvis_fixture_plan=$'node scripts/test-jarvis-protocol.js\nnode scripts/test-jarvis-tasks.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-task-event.js\nnode scripts/test-jarvis-task-runner.js\n'"$repo_plan"
jarvis_guidance_plan=$'node scripts/test-jarvis-guidance.js\n'"$repo_plan"
jarvis_speakable_plan=$'node scripts/test-jarvis-speakable.js\n'"$repo_plan"
jarvis_language_plan=$'node scripts/test-jarvis-guidance.js\nnode scripts/test-jarvis-speakable.js\nnode scripts/test-jarvis-speech-language.js\n'"$repo_plan"
keyboard_rows=$'python3 scripts/check-keyboard.py shell\npython3 scripts/test-check-keyboard.py\n'
keyboard_check=$'python3 scripts/check-keyboard.py shell\n'
dispatch_plan=$'node scripts/test-input-facts.js\nnode scripts/test-dispatch.js\nnode scripts/test-jarvis-desktop.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\npython3 scripts/check-plugin-boundary.py\npython3 scripts/check-design-tokens.py\npython3 scripts/check-pointer-cursor.py\npython3 scripts/test-check-pointer-cursor.py\npython3 scripts/check-user-commands.py\n'"$keyboard_check$repo_plan"
session_plan=$'scripts/test-install-tree.sh\npython3 scripts/check-plugin-boundary.py\npython3 scripts/check-design-tokens.py\npython3 scripts/check-pointer-cursor.py\npython3 scripts/test-check-pointer-cursor.py\npython3 scripts/check-user-commands.py\n'"$keyboard_check$repo_plan"$'\nscripts/qml-unit.sh\nscripts/test-qml-unit.sh\nscripts/test-session-lock.sh\nscripts/test-flake.sh\nscripts/qml-smoke.sh'
fixture_plan=$'node bin/lib/check-manifests.js --base scripts/smoke/fixtures/plugins\npython3 scripts/check-plugin-boundary.py --shell scripts/smoke/fixtures\npython3 scripts/check-design-tokens.py\n'"$repo_plan"$'\nscripts/test-validate.sh\nscripts/qml-smoke.sh'
smoke_plan=$'python3 scripts/check-smoke-readers.py\npython3 scripts/test-check-smoke-readers.py\npython3 scripts/check-smoke-terminal.py\npython3 scripts/test-check-smoke-terminal.py\n'"$repo_plan"$'\nscripts/qml-smoke.sh'
orb_shader_plan=$'scripts/test-install-tree.sh\npython3 scripts/check-plugin-boundary.py\npython3 scripts/check-design-tokens.py\npython3 scripts/check-voiceorb-shader.py\npython3 scripts/test-check-voiceorb-shader.py\npython3 scripts/test-measure-shader.py\npython3 scripts/check-pointer-cursor.py\npython3 scripts/test-check-pointer-cursor.py\npython3 scripts/check-user-commands.py\n'"$keyboard_rows$repo_plan"$'\nscripts/qml-unit.sh\nscripts/test-qml-unit.sh\nscripts/test-flake.sh\nscripts/qml-smoke.sh\nscripts/measure-shader.sh'
orb_check_plan=$'python3 scripts/check-voiceorb-shader.py\npython3 scripts/test-check-voiceorb-shader.py\npython3 scripts/test-measure-shader.py\n'"$repo_plan"
shader_measure_plan=$'python3 scripts/test-measure-shader.py\n'"$repo_plan"$'\nscripts/measure-shader.sh'
keyboard_plan="$repo_plan"$'\nscripts/qml-smoke.sh\nscripts/measure-shader.sh'
fedora_plan=$'scripts/test-fedora-srpm.sh\n'
version_plan=$'scripts/test-vgsh-version.sh\nscripts/test-install-tree.sh\n'"$fedora_plan"$'node scripts/check-packaging.js\nnode scripts/test-check-packaging.js\n'"$readme_rows"$'scripts/test-release.sh\nscripts/test-publish-aur.sh\n'"$repo_plan"
# A recipe change runs the recipe check and its controls, never the product
# smoke; the container build runs only where the area admits it, never
# offline.
recipe_plan=$'node scripts/check-packaging.js\nnode scripts/test-check-packaging.js\nscripts/test-publish-aur.sh\n'"$repo_plan"
# An Arch recipe is also the README's source for the AUR commands.
# The release suite's parity rows build the Arch recipes' host side.
arch_recipe_plan=$'node scripts/check-packaging.js\nnode scripts/test-check-packaging.js\n'"$readme_rows"$'scripts/test-release.sh\nscripts/test-publish-aur.sh\n'"$repo_plan"
settings_core_prefix=$'node scripts/test-plugin-logic.js\nnode scripts/test-plugin-status.js\nnode scripts/test-plugin-extras.js\nnode scripts/test-key-capture.js\nnode scripts/test-tui-logic.js\nnode scripts/test-ipc-logic.js\nnode scripts/test-notice-logic.js\nnode scripts/test-hyprland-layer.js\nnode scripts/test-hyprland-state.js\nnode scripts/test-input-facts.js\n'
settings_theme_rows=$'bin/vgsh-theme-judge packages themes\nbin/vgsh-theme-judge catalog-check themes\n'
settings_plugin_rows=$'node scripts/test-themes-setup.js\nnode scripts/test-notifications-logic.js\n'
settings_catalog_rows=$'node scripts/check-devtools-catalog.js\nnode scripts/test-check-devtools-catalog.js\n'
settings_reply_row='node scripts/test-settings-reply.js'
cases=(
  "devtools-window|shell/plugins/vgs.devtools/Window.qml|logic|node scripts/test-devtools-view.js"
  "settings-reply-window|shell/plugins/vgs.settings/Window.qml|logic|node scripts/test-settings-reply.js"
  "settings-reply-page|shell/plugins/vgs.settings/PluginPage.qml|logic|node scripts/test-settings-reply.js"
  "settings-reply-input|shell/plugins/vgs.settings/Reply.js|logic|node scripts/test-settings-reply.js"
  "settings-reply-suite|scripts/test-settings-reply.js|logic|node scripts/test-settings-reply.js"
  "settings-reply-key-label|shell/plugins/vgs.settings/KeyField.qml|logic|$settings_reply_row"
  "settings-reply-launcher|shell/plugins/vgs.launcher/Service.qml|logic|$settings_reply_row"
  "settings-reply-probe|scripts/smoke/Probe.qml|logic|$settings_reply_row"
  "settings-reply-shots|scripts/sandbox-shots.sh|logic|$settings_reply_row"
  "settings-reply-fixture|scripts/smoke/fixtures/plugins/acme.hyprland/manifest.json|logic|$settings_reply_row"
  "settings-reply-layer-binding|shell/Core/HyprlandLayer.qml|logic|$settings_reply_row"
  "settings-reply-producer|shell/Core/PluginLogic.js|logic|$settings_core_prefix$settings_theme_rows$settings_plugin_rows$settings_reply_row"
  "settings-reply-layer|shell/Core/HyprlandLayer.js|logic|$settings_core_prefix"$'node scripts/test-dispatch.js\n'"$settings_theme_rows$settings_plugin_rows$settings_reply_row"
  "settings-reply-values|shell/Commons/SettingValues.js|logic|$settings_core_prefix"$'node scripts/test-setting-values.js\n'"$settings_theme_rows$settings_plugin_rows$settings_reply_row"
  "settings-reply-packages|shell/Core/PackageManagers.js|logic|$settings_core_prefix$settings_theme_rows$settings_plugin_rows$settings_catalog_rows$settings_reply_row"
  "settings-reply-icons|shell/Ui/icons/Lucide.js|logic|$settings_core_prefix"$'node scripts/test-icon-bounds.js\n'"$settings_theme_rows"$'node scripts/test-lucide-data.js\n'"$settings_plugin_rows"$'node scripts/test-jarvis-widget.js\n'"$settings_catalog_rows"$'node scripts/test-agent-warden-view.js\n'"$settings_reply_row"
  "orb-source|shell/Ui/feedback/shaders/voiceorb.frag|all|$orb_shader_plan"
  "orb-pack|shell/Ui/feedback/shaders/voiceorb.frag.qsb|all|$orb_shader_plan"
  "orb-compiler|scripts/check-voiceorb-shader.py|offline|$orb_check_plan"
  "shader-instrument|scripts/measure-shader.sh|all|$shader_measure_plan"
  "shader-reader|scripts/shader/readings.py|all|$shader_measure_plan"
  "shader-ceilings|scripts/shader/ceilings.json|all|$shader_measure_plan"
  "shader-scene|scripts/shader/Scene.qml|all|$shader_measure_plan"
  "shader-tests|scripts/test-measure-shader.py|offline|python3 scripts/test-measure-shader.py"$'\n'"$repo_plan"
  "keyboard-source|scripts/smoke/keyboard/keyboard.c|all|$keyboard_plan"
  "keyboard-protocol|scripts/smoke/keyboard/virtual-keyboard-unstable-v1.xml|all|$keyboard_plan"
  "device-fakes-harness|scripts/smoke/devices.sh|all|$keyboard_plan"
  "device-fakes-fixture|scripts/smoke/fixtures/devices/stand-in.py|all|python3 scripts/test-displays-brightness.py"$'\n'"$fixture_plan"$'\nscripts/measure-shader.sh'
  "docs|docs/architecture/overview.md|offline|$repo_plan"$'\ndoc_limits_check'
  "runtime-doc|docs/architecture/runtime.md|offline|$readme_plan"$'\ndoc_limits_check'
  "docs-html|docs/guide.html|offline|$repo_plan"$'\ndoc_limits_check'
  "root-markdown|NOTES.md|offline|$repo_plan"$'\ndoc_limits_check'
  "version|VERSION|offline|$version_plan"
  "licence|LICENSE|all|$install_plan"
  "flake|flake.nix|all|$repo_plan"$'\nscripts/test-flake.sh'
  "flake-offline|flake.nix|offline|$repo_plan"
  "installer|packaging/install-system.sh|offline|$installer_plan"
  "curl-installer|install.sh|offline|$curl_installer_plan"
  "recipe|packaging/arch/vgs/PKGBUILD|offline|$arch_recipe_plan"
  "recipe-all|packaging/arch/vgs-git/.SRCINFO|all|$arch_recipe_plan"$'\nscripts/arch-packages.sh'
  "recipe-package|packaging/arch/vgs/PKGBUILD|package|scripts/arch-packages.sh"
  "requirements|config/requirements.json|offline|node scripts/test-plugin-logic.js"$'\nscripts/test-install-tree.sh\nnode scripts/check-packaging.js\nnode scripts/test-check-packaging.js\nscripts/test-vgsh-requirements.sh\nscripts/test-install-sh.sh\nscripts/test-publish-aur.sh\npython3 scripts/check-user-commands.py\npython3 scripts/test-check-user-commands.py\n'"$repo_plan"
  "install-manifest|packaging/install-tree.manifest|offline|scripts/test-install-tree.sh"$'\nscripts/test-release.sh\n'"$repo_plan"
  "fedora-recipe|packaging/fedora/vgs.spec|all|$fedora_plan$recipe_plan"
  "copr-entry|.copr/Makefile|all|scripts/test-fedora-srpm.sh"$'\n'"$repo_plan"
  # test-validate.sh runs the mutation planner of the QML unit controls.
  "qml-unit-planner|scripts/test-qml-unit.sh|tools|scripts/test-validate.sh"
  "heap|scripts/attribute-heap-profile.py|offline|$heap_plan"
  "suite|scripts/test-attribute-heap-profile.py|offline|$heap_plan"
  "jarvis-env|scripts/lib/jarvis-env.sh|all|$jarvis_owner_plan"$'\nscripts/qml-smoke.sh'
  "jarvis-env-suite|scripts/test-jarvis-env.js|offline|$jarvis_env_plan"
  "jarvis-env-fixture|scripts/fixtures/jarvis-env/probe.py|all|$jarvis_env_plan"
  "jarvis-daemon-suite|scripts/test-jarvis-daemon.js|offline|$jarvis_daemon_plan"
  "jarvis-secrets-suite|scripts/test-jarvis-secrets.js|offline|node scripts/test-jarvis-secrets.js"$'\n'"$repo_plan"
  "jarvis-key-tui-fixture|scripts/fixtures/jarvis/key-tui.py|offline|node scripts/test-jarvis-net.js"$'\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-secrets.js\n'"$repo_plan"
  "jarvis-key-fixture|scripts/fixtures/jarvis/keys-world.js|offline|node scripts/test-jarvis-net.js"$'\nnode scripts/test-jarvis-brain-openai.js\nnode scripts/test-jarvis-brain-anthropic.js\nnode scripts/test-jarvis-live.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-secrets.js\n'"$repo_plan"
  "jarvis-task-suite|scripts/test-jarvis-tasks.js|offline|node scripts/test-jarvis-tasks.js"$'\n'"$repo_plan"
  "jarvis-audio-task-input|shell/plugins/vgs.jarvis/backend/Tasks.js|cli|node scripts/test-jarvis-files.js"$'\n'"node scripts/test-jarvis-browser.js"$'\n'"node scripts/test-jarvis-daemon.js"$'\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-task-event.js\nnode scripts/test-jarvis-task-runner.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "task-event-suite|scripts/test-task-event.js|offline|node scripts/test-task-event.js"$'\n'"$repo_plan"
  "task-event-prefix|scripts/test-task-event.js|all|node scripts/test-task-event.js"$'\n'"$repo_plan"$'\nscripts/qml-smoke.sh'
  "jarvis-audio-suite|scripts/test-jarvis-audio.js|offline|node scripts/test-jarvis-audio.js"$'\n'"$repo_plan"
  "jarvis-engine-suite|scripts/test-jarvis-engine.js|offline|node scripts/test-jarvis-engine.js"$'\n'"$repo_plan"
  "jarvis-engine-input|shell/plugins/vgs.jarvis/backend/ChainedEngine.js|cli|node scripts/test-jarvis-files.js"$'\n'"node scripts/test-jarvis-browser.js"$'\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-engine-fixture|scripts/fixtures/jarvis/engine.js|offline|node scripts/test-jarvis-codex.js"$'\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-engine.js\n'"$repo_plan"
  "jarvis-brain-frames|scripts/fixtures/jarvis-brain/openai-chat-frames.js|offline|node scripts/test-jarvis-brain-openai.js"$'\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-engine.js\n'"$repo_plan"
  "jarvis-audio-daemon-suite|scripts/test-jarvis-audio-daemon.js|offline|node scripts/test-jarvis-audio-daemon.js"$'\n'"$repo_plan"
  "jarvis-playback-suite|scripts/test-jarvis-playback.js|offline|node scripts/test-jarvis-playback.js"$'\n'"$repo_plan"
  "jarvis-pipewire-suite|scripts/test-jarvis-playback-pipewire.js|offline|node scripts/test-jarvis-playback-pipewire.js"$'\n'"$repo_plan"
  "jarvis-playback-fixture|scripts/fixtures/jarvis/playback.js|offline|node scripts/test-jarvis-daemon.js"$'\nnode scripts/test-jarvis-engine.js\nnode scripts/test-jarvis-playback.js\nnode scripts/test-jarvis-playback-pipewire.js\n'"$repo_plan"
  "jarvis-playback-config|scripts/fixtures/jarvis/playback.conf|offline|node scripts/test-jarvis-daemon.js"$'\nnode scripts/test-jarvis-playback-pipewire.js\n'"$repo_plan"
  "jarvis-audio-fixture|scripts/fixtures/jarvis/audio-tool.py|offline|node scripts/test-jarvis-browser.js"$'\n'"node scripts/test-jarvis-daemon.js"$'\n'"$jarvis_audio_rows$repo_plan"
  "jarvis-accounts-suite|scripts/test-jarvis-accounts.js|offline|node scripts/test-jarvis-accounts.js"$'\n'"$repo_plan"
  "jarvis-accounts-tui-suite|scripts/test-jarvis-accounts-tui.js|offline|node scripts/test-jarvis-accounts-tui.js"$'\n'"$repo_plan"
  "jarvis-account-verify-suite|scripts/test-jarvis-account-verify.js|offline|node scripts/test-jarvis-account-verify.js"$'\n'"$repo_plan"
  "jarvis-accounts-fixture|scripts/fixtures/jarvis/accounts-world.js|offline|node scripts/test-jarvis-daemon.js"$'\n'"$jarvis_accounts_rows$repo_plan"
  "jarvis-accounts-terminal-fixture|scripts/fixtures/jarvis/accounts-tui.py|offline|node scripts/test-jarvis-browser-setup.js"$'\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-accounts-tui.js\n'"$repo_plan"
  "jarvis-fixture|scripts/fixtures/jarvis/prepare.js|offline|$jarvis_fixture_plan"
  "jarvis-scripted-fixture|scripts/fixtures/jarvis/scripted.js|offline|node scripts/test-jarvis-protocol.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\n'"$repo_plan"
  "jarvis-bubble-input|shell/plugins/vgs.jarvis/Bubble.qml|qml|scripts/qml-smoke.sh"
  "jarvis-bubble-row|scripts/smoke/rows/jarvis-bubble.sh|qml|scripts/qml-smoke.sh"
  "jarvis-fixture-all|scripts/fixtures/jarvis/prepare.js|all|$jarvis_fixture_plan"$'\nscripts/qml-smoke.sh'
  "jarvis-protocol-suite|scripts/test-jarvis-protocol.js|offline|node scripts/test-jarvis-protocol.js"$'\n'"$repo_plan"
  "jarvis-local-suite|scripts/test-jarvis-local.py|all|python3 scripts/test-jarvis-local.py"$'\n'"$repo_plan"
  "jarvis-setup-suite|scripts/test-jarvis-setup.py|all|python3 scripts/test-jarvis-setup.py"$'\n'"$repo_plan"
  "jarvis-setup-probe-fixture|scripts/fixtures/jarvis-setup/installed-probe.py|all|python3 scripts/test-jarvis-setup.py"$'\n'"$repo_plan"
  "install-tree-suite|scripts/test-install-tree.sh|all|node scripts/test-jarvis-browser-setup.js"$'\nscripts/test-install-tree.sh'$'\npython3 scripts/test-jarvis-setup.py\n'"$repo_plan"
  "jarvis-setup-fixture|scripts/fixtures/jarvis-setup/installer.py|all|python3 scripts/test-jarvis-setup.py"$'\n'"$repo_plan"
  "jarvis-setup-status-fixture|scripts/fixtures/jarvis-setup/status.py|all|python3 scripts/test-jarvis-setup.py"$'\n'"$repo_plan"$'\nscripts/qml-smoke.sh'
  "jarvis-setup-installed-fixture|scripts/fixtures/jarvis-setup/installed.py|all|scripts/test-install-tree.sh"$'\npython3 scripts/test-jarvis-setup.py\n'"$repo_plan"$'\nscripts/qml-smoke.sh'
  "jarvis-local-runner|scripts/check-jarvis-local.sh|all|$jarvis_local_rows$repo_plan"
  "jarvis-local-fixture|scripts/fixtures/jarvis-local/run.py|all|$jarvis_local_rows$repo_plan"
  "jarvis-unbounded-probe|scripts/fixtures/jarvis-local/probe-moonshine.py|all|$jarvis_local_rows$repo_plan"
  "jarvis-artifacts|shell/plugins/vgs.jarvis/artifacts.json|tools|$jarvis_local_tools_plan"
  "jarvis-measure|shell/plugins/vgs.jarvis/measure-local|tools|$jarvis_local_tools_plan"
  "jarvis-clip|shell/plugins/vgs.jarvis/fixtures/probe.wav|tools|$jarvis_local_tools_plan"
  "jarvis-browser-daemon-input|shell/plugins/vgs.jarvis/backend/jarvisd.js|cli|node scripts/test-jarvis-files.js"$'\n'"node scripts/test-jarvis-browser.js"$'\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-browser-suite|scripts/test-jarvis-browser.js|offline|node scripts/test-jarvis-browser.js"$'\n'"$repo_plan"
  "jarvis-browser-setup-suite|scripts/test-jarvis-browser-setup.js|offline|node scripts/test-jarvis-browser-setup.js"$'\n'"$repo_plan"
  "jarvis-input-owner|shell/plugins/vgs.jarvis/backend/Input.js|cli|node scripts/test-jarvis-input.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-computer-help|shell/plugins/vgs.jarvis/backend/ComputerHelp.js|cli|node scripts/test-jarvis-router.js"$'\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-browser-setup.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-input-help|shell/plugins/vgs.jarvis/backend/skills/computer/input.md|cli|node scripts/test-jarvis-router.js"$'\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-browser-input|shell/plugins/vgs.jarvis/backend/Browser.js|cli|node scripts/test-jarvis-router.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-browser-setup.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-browser-setup-input|shell/plugins/vgs.jarvis/backend/browser-setup.js|cli|node scripts/test-jarvis-files.js"$'\n'"node scripts/test-jarvis-browser.js"$'\n'"node scripts/test-jarvis-browser-setup.js"$'\nnode scripts/test-jarvis-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-browser-fixture|scripts/fixtures/jarvis/browser.py|offline|node scripts/test-jarvis-router.js"$'\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-browser-setup.js\nnode scripts/test-jarvis-daemon.js\n'"$repo_plan"
  "jarvis-tools-suite|scripts/test-jarvis-tools.js|offline|node scripts/test-jarvis-tools.js"$'\n'"$repo_plan"
  "jarvis-policy-suite|scripts/test-jarvis-policy.js|offline|node scripts/test-jarvis-policy.js"$'\n'"$repo_plan"
  "jarvis-release-suite|scripts/test-jarvis-release.js|offline|node scripts/test-jarvis-release.js"$'\n'"$repo_plan"
  "jarvis-net-suite|scripts/test-jarvis-net.js|offline|node scripts/test-jarvis-net.js"$'\n'"$repo_plan"
  "jarvis-sse-suite|scripts/test-jarvis-sse.js|offline|node scripts/test-jarvis-sse.js"$'\n'"$repo_plan"
  "jarvis-providers-suite|scripts/test-jarvis-providers.js|offline|node scripts/test-jarvis-providers.js"$'\n'"$repo_plan"
  "jarvis-brain-suite|scripts/test-jarvis-brain-openai.js|offline|node scripts/test-jarvis-brain-openai.js"$'\n'"$repo_plan"
  "jarvis-brain-scripts|scripts/fixtures/jarvis-brain/openai-chat-scripts.json|offline|node scripts/test-jarvis-brain-openai.js"$'\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-engine.js\n'"$repo_plan"
  "jarvis-brain-schema|scripts/fixtures/jarvis-brain/openai-chat.schema.json|offline|node scripts/test-jarvis-brain-openai.js"$'\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-engine.js\nnode scripts/test-schema-check.js\n'"$repo_plan"
  "jarvis-anthropic-suite|scripts/test-jarvis-brain-anthropic.js|offline|node scripts/test-jarvis-brain-anthropic.js"$'\n'"$repo_plan"
  "jarvis-anthropic-scripts|scripts/fixtures/jarvis-brain/anthropic-messages-scripts.json|offline|node scripts/test-jarvis-brain-anthropic.js"$'\n'"$repo_plan"
  "jarvis-anthropic-schema|scripts/fixtures/jarvis-brain/anthropic-messages.schema.json|offline|node scripts/test-jarvis-brain-anthropic.js"$'\n'"$repo_plan"
  "jarvis-live-suite|scripts/test-jarvis-live.js|offline|$jarvis_live_plan"
  "jarvis-live-scripts|scripts/fixtures/jarvis-live/gpt-live-scripts.json|offline|$jarvis_live_plan"
  "jarvis-live-schema|scripts/fixtures/jarvis-live/gpt-live.schema.json|offline|$jarvis_live_plan"
  "jarvis-live-input|shell/plugins/vgs.jarvis/backend/GptLive.js|cli|node scripts/test-jarvis-live.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-websocket-fixture|scripts/fixtures/jarvis/websocket.js|offline|node scripts/test-jarvis-net.js"$'\nnode scripts/test-jarvis-live.js\n'"$jarvis_daemon_plan"
  "jarvis-session-cli|shell/plugins/vgs.jarvis/Session.js|cli|node scripts/test-jarvis-live.js"$'\nnode scripts/test-jarvis-router.js\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-desktop.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\n'"$jarvis_audio_rows"$'scripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "schema-check-suite|scripts/test-schema-check.js|offline|node scripts/test-schema-check.js"$'\n'"$repo_plan"
  "schema-check|scripts/fixtures/schema-check.js|offline|node scripts/test-jarvis-brain-openai.js"$'\nnode scripts/test-jarvis-brain-anthropic.js\nnode scripts/test-jarvis-live.js\nnode scripts/test-jarvis-mcp.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex-protocol.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-engine.js\nnode scripts/test-schema-check.js\n'"$repo_plan"
  "jarvis-sse-input|shell/plugins/vgs.jarvis/backend/Sse.js|logic|node scripts/test-jarvis-sse.js"
  "jarvis-sse-cli-input|shell/plugins/vgs.jarvis/backend/Sse.js|cli|node scripts/test-jarvis-brain-openai.js"$'\nnode scripts/test-jarvis-brain-anthropic.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-providers-input|shell/plugins/vgs.jarvis/backend/Providers.js|logic|node scripts/test-jarvis-providers.js"
  "jarvis-brain-input|shell/plugins/vgs.jarvis/backend/OpenAIChat.js|cli|node scripts/test-jarvis-brain-openai.js"$'\nnode scripts/test-jarvis-brain-anthropic.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-wire-input|shell/plugins/vgs.jarvis/backend/WireBrain.js|cli|node scripts/test-jarvis-brain-openai.js"$'\nnode scripts/test-jarvis-brain-anthropic.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-anthropic-input|shell/plugins/vgs.jarvis/backend/AnthropicMessages.js|cli|node scripts/test-jarvis-brain-anthropic.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-denied-suite|scripts/test-jarvis-denied.js|offline|node scripts/test-jarvis-denied.js"$'\n'"$repo_plan"
  "jarvis-redact-suite|scripts/test-jarvis-redact.js|offline|node scripts/test-jarvis-redact.js"$'\n'"$repo_plan"
  "jarvis-audit-suite|scripts/test-jarvis-audit.js|offline|node scripts/test-jarvis-audit.js"$'\n'"$repo_plan"
  "jarvis-router-suite|scripts/test-jarvis-router.js|offline|node scripts/test-jarvis-router.js"$'\n'"$repo_plan"
  "jarvis-router-input|shell/plugins/vgs.jarvis/backend/ToolRouter.js|cli|node scripts/test-jarvis-router.js"$'\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nnode scripts/test-jarvis-task-runner.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-policy-fixture|scripts/fixtures/jarvis/policy.js|offline|$jarvis_policy_rows$jarvis_daemon_plan"
  "jarvis-tools-input|shell/plugins/vgs.jarvis/backend/Tools.js|logic|node scripts/test-jarvis-tools.js"$'\nnode scripts/test-jarvis-policy.js\nnode scripts/test-jarvis-redact.js'
  "jarvis-audit-input|shell/plugins/vgs.jarvis/backend/Audit.js|cli|node scripts/test-jarvis-audit.js"$'\nnode scripts/test-jarvis-router.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\n'"${jarvis_daemon_plan%$repo_plan}"$'node scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\n'"$jarvis_accounts_rows"$'scripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-redact-input|shell/plugins/vgs.jarvis/backend/Redact.js|logic|node scripts/test-jarvis-redact.js"
  "jarvis-redact-router-input|shell/plugins/vgs.jarvis/backend/Redact.js|cli|node scripts/test-jarvis-audit.js"$'\nnode scripts/test-jarvis-router.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\n'"$jarvis_accounts_rows"$'scripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-policy-input|shell/plugins/vgs.jarvis/backend/Policy.js|logic|node scripts/test-jarvis-policy.js"$'\nnode scripts/test-jarvis-release.js'
  "jarvis-policy-net-input|shell/plugins/vgs.jarvis/backend/Policy.js|cli|node scripts/test-jarvis-net.js"$'\nnode scripts/test-jarvis-brain-openai.js\nnode scripts/test-jarvis-brain-anthropic.js\nnode scripts/test-jarvis-live.js\nnode scripts/test-jarvis-router.js\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-sandbox.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nnode scripts/test-jarvis-task-runner.js\n'"$jarvis_accounts_rows"$'scripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-net-input|shell/plugins/vgs.jarvis/backend/net.js|logic|node scripts/test-jarvis-release.js"$'\nnode scripts/test-jarvis-providers.js'
  "jarvis-net-cli-input|shell/plugins/vgs.jarvis/backend/net.js|cli|node scripts/test-jarvis-net.js"$'\nnode scripts/test-jarvis-brain-openai.js\nnode scripts/test-jarvis-brain-anthropic.js\nnode scripts/test-jarvis-live.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nnode scripts/test-jarvis-secrets.js\n'"$jarvis_accounts_rows"$'scripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-add-key-input|shell/plugins/vgs.jarvis/backend/keys.js|cli|node scripts/test-jarvis-net.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-secrets.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-denied-input|shell/plugins/vgs.jarvis/backend/Denied.js|logic|node scripts/test-jarvis-policy.js"
  "jarvis-denied-cli-input|shell/plugins/vgs.jarvis/backend/Denied.js|cli|node scripts/test-jarvis-denied.js"$'\nnode scripts/test-jarvis-router.js\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-sandbox.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-sandbox-input|shell/plugins/vgs.jarvis/backend/Sandbox.js|cli|node scripts/test-jarvis-files.js"$'\n'"node scripts/test-jarvis-browser.js"$'\nnode scripts/test-jarvis-sandbox.js'$'\nnode scripts/test-jarvis-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-child-input|shell/plugins/vgs.jarvis/backend/Child.js|cli|node scripts/test-jarvis-desktop.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-sandbox.js\nnode scripts/test-jarvis-child.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-desktop-input|shell/plugins/vgs.jarvis/backend/Desktop.js|cli|node scripts/test-jarvis-desktop.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-desktop-session-input|shell/plugins/vgs.jarvis/backend/DesktopSession.js|cli|node scripts/test-jarvis-desktop.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-executors-input|shell/plugins/vgs.jarvis/backend/Executors.js|cli|node scripts/test-jarvis-desktop.js"$'\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-desktop-fixture|scripts/fixtures/jarvis/desktop-tool.py|cli|node scripts/test-jarvis-desktop-tools.js"$'\nnode scripts/test-jarvis-daemon.js'
  "jarvis-forbidden-input|scripts/fixtures/jarvis/forbidden.js|logic|"
  "jarvis-forbidden-cli-input|scripts/fixtures/jarvis/forbidden.js|cli|node scripts/test-jarvis-sandbox.js"$'\nnode scripts/test-jarvis-daemon.js'
  "jarvis-sandbox-datagram-input|scripts/fixtures/jarvis/sandbox-datagram.py|cli|node scripts/test-jarvis-sandbox.js"$'\nnode scripts/test-jarvis-daemon.js'
  "jarvis-session-suite|scripts/test-jarvis-session.js|offline|node scripts/test-jarvis-session.js"$'\n'"$repo_plan"
  "jarvis-owner-suite|scripts/test-jarvis-session-runner.js|offline|node scripts/test-jarvis-session-runner.js"$'\n'"$repo_plan"
  "jarvis-session|shell/plugins/vgs.jarvis/Session.js|logic|node scripts/test-jarvis-session.js"$'\nnode scripts/test-jarvis-session-runner.js\nnode scripts/test-jarvis-widget.js\nnode scripts/test-jarvis-protocol.js\nnode scripts/test-jarvis-requests.js'
  "jarvis-session-router|shell/plugins/vgs.jarvis/Session.js|cli|node scripts/test-jarvis-live.js"$'\nnode scripts/test-jarvis-router.js\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-desktop.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\n'"$jarvis_audio_rows"$'scripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-owner|shell/plugins/vgs.jarvis/backend/session-runner.js|logic|node scripts/test-jarvis-session-runner.js"
  "jarvis-owner-router|shell/plugins/vgs.jarvis/backend/session-runner.js|cli|node scripts/test-jarvis-live.js"$'\nnode scripts/test-jarvis-router.js\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nscripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-tools-router|shell/plugins/vgs.jarvis/backend/Tools.js|cli|node scripts/test-jarvis-brain-openai.js"$'\nnode scripts/test-jarvis-brain-anthropic.js\nnode scripts/test-jarvis-live.js\nnode scripts/test-jarvis-audit.js\nnode scripts/test-jarvis-router.js\nnode scripts/test-jarvis-input.js\nnode scripts/test-jarvis-desktop.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-browser-setup.js\nnode scripts/test-jarvis-bridge.js\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-codex.js\nnode scripts/test-jarvis-sandbox.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nnode scripts/test-jarvis-engine.js\nnode scripts/test-jarvis-task-runner.js\n'"$jarvis_accounts_rows"$'scripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-claude-input|shell/plugins/vgs.jarvis/backend/ClaudeCode.js|cli|node scripts/test-jarvis-files.js"$'\n'"node scripts/test-jarvis-browser.js"$'\nnode scripts/test-jarvis-claude.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\n'"$jarvis_accounts_rows"$'scripts/test-install-tree.sh\n'"$readme_rows_trimmed"
  "jarvis-claude-standin|scripts/fixtures/jarvis-claude/claude|cli|node scripts/test-jarvis-claude.js"
  "jarvis-guidance-suite|scripts/test-jarvis-guidance.js|offline|$jarvis_guidance_plan"
  "jarvis-guidance-fixture|scripts/fixtures/jarvis-voice/guidance.json|offline|$jarvis_guidance_plan"
  "jarvis-speakable-suite|scripts/test-jarvis-speakable.js|offline|$jarvis_speakable_plan"
  "jarvis-speakable-fixture|scripts/fixtures/jarvis-voice/speakable.json|offline|$jarvis_speakable_plan"
  "jarvis-language-suite|scripts/test-jarvis-speech-language.js|offline|node scripts/test-jarvis-speech-language.js"$'\n'"$repo_plan"
  "jarvis-voice-assertions|scripts/fixtures/jarvis-voice/assertions.js|offline|node scripts/test-jarvis-sse.js"$'\nnode scripts/test-jarvis-providers.js\n'"${jarvis_language_plan%$repo_plan}"$'node scripts/test-schema-check.js\n'"$repo_plan"
  "jarvis-voice-installed|scripts/fixtures/jarvis-voice/installed.js|all|$install_plan"$'\nscripts/qml-smoke.sh'
  "dispatch|shell/Core/Dispatch.js|offline|$dispatch_plan"
  "session|shell/Core/SessionLock.qml|all|$session_plan"
  "fixture|scripts/smoke/fixtures/plugins/acme.contention/Background.qml|all|$fixture_plan"
  "smoke-row|scripts/smoke/rows/example.sh|all|$smoke_plan"
  "jarvis-key-smoke|scripts/smoke/rows/jarvis-keys.sh|all|node scripts/test-jarvis-daemon.js"$'\n'"$smoke_plan"
  "jarvis-poll-harness|scripts/smoke/harness.sh|all|node scripts/test-jarvis-daemon.js"$'\nscripts/test-smoke-teardown.sh\nscripts/test-sandbox-shots.sh\nnode scripts/test-jarvis-env.js\n'"$repo_plan"$'\nscripts/qml-smoke.sh\nscripts/measure-shader.sh'
  "shortcut-provider|shell/Core/ShortcutRegistry.qml|unit|scripts/qml-unit.sh"$'\nscripts/test-qml-unit.sh'
  "key-capture-owner|shell/Core/KeyCapture.qml|unit|scripts/qml-unit.sh"$'\nscripts/test-qml-unit.sh'
  "harness-render|.agents/skills/review-gate/scripts/review-policy|all|$repo_plan"
  "harness-hook|.claude/hooks/example.sh|all|$repo_plan"
  "harness-settings|kendex.local.toml|all|$repo_plan"
  "workflow|.github/workflows/example.yml|all|$repo_plan"
)
for spec in "${cases[@]}"; do
  name="${spec%%|*}"; rest="${spec#*|}"
  file="${rest%%|*}"; rest="${rest#*|}"
  area="${rest%%|*}"; wanted="${rest#*|}"
  d="$tmp/plan-$name"; fresh "$d"
  mkdir -p -- "$d/$(dirname -- "$file")"
  printf 'changed\n' >"$d/$file"
  for state in untracked staged committed deleted; do
    case "$state" in
      staged) "${base_env[@]}" git -C "$d" add -- "$file" ;;
      committed) "${base_env[@]}" git -C "$d" commit -q -m change ;;
      deleted)
        # Compare the deletion against a base that actually contains it.
        "${base_env[@]}" git -C "$d" update-ref refs/remotes/origin/trunk HEAD
        rm -- "${d:?}/$file" ;;
    esac
    status=0
    out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate "$area" --changed refs/remotes/origin/trunk --list 2>"$tmp/plan.err")" || status=$?
    if [[ $status == 0 && $out == "$wanted" ]]; then ok "$name selects its consumers when $state"; else fail "$name $state plan: $out"; fi
    if out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate "$area" --list 2>"$tmp/plan.err")" && [[ $out == "$wanted" ]]; then
      ok "$name defaults to its consumers when $state"
    else
      fail "$name $state default plan: $out"
    fi
  done
done

d="$tmp/plan-rename"; fresh "$d"
mkdir -p "$d/shell/Core"
printf 'source\n' >"$d/shell/Core/Dispatch.js"
"${base_env[@]}" git -C "$d" add shell/Core/Dispatch.js
"${base_env[@]}" git -C "$d" commit -q -m source
"${base_env[@]}" git -C "$d" mv shell/Core/Dispatch.js README.md
# The removed path's consumers, and README.md's: the install tree and the
# README check, and the ceiling row, since README.md is a document.
rename_plan=$'node scripts/test-input-facts.js\nnode scripts/test-dispatch.js\nnode scripts/test-jarvis-desktop.js\nnode scripts/test-jarvis-files.js\nnode scripts/test-jarvis-browser.js\nnode scripts/test-jarvis-desktop-tools.js\nnode scripts/test-jarvis-vision.js\nnode scripts/test-jarvis-daemon.js\nnode scripts/test-jarvis-audio-daemon.js\nscripts/test-install-tree.sh\n'"$readme_rows"$'python3 scripts/check-plugin-boundary.py\npython3 scripts/check-design-tokens.py\npython3 scripts/check-pointer-cursor.py\npython3 scripts/test-check-pointer-cursor.py\npython3 scripts/check-user-commands.py\n'"$keyboard_check$repo_plan"
if out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --changed HEAD --list 2>"$tmp/plan.err")" && [[ $out == "$rename_plan"$'\ndoc_limits_check' ]]; then ok "a rename selects consumers of the removed source path"; else fail "rename omitted the old path's consumers: $out"; fi

d="$tmp/plan-shared"; fresh "$d"
mkdir -p "$d/bin/lib"; printf 'changed\n' >"$d/bin/lib/qml-library.js"
out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --changed HEAD --list 2>"$tmp/plan.err")"
for consumer in 'node scripts/test-plugin-logic.js' 'node scripts/test-dispatch.js' 'node scripts/test-lifetime.js' 'node scripts/test-qml-library.js' 'node scripts/test-key-nav-logic.js' 'node bin/lib/check-manifests.js' 'node scripts/test-check-manifests.js' 'node scripts/test-jarvis-audio-daemon.js' 'scripts/test-vgsh.sh' 'scripts/test-install-tree.sh' 'python3 scripts/test-vgs-plugin.py' 'scripts/test-validate.sh'; do
  if grep -qxF "$consumer" <<<"$out"; then ok "shared loader selects $consumer"; else fail "shared loader omitted $consumer"; fi
done
if grep -qxF 'node scripts/test-inset.js' <<<"$out"; then ok "shared loader selects node scripts/test-inset.js"; else fail "shared loader omitted node scripts/test-inset.js"; fi
if grep -qxF 'node scripts/test-setting-values.js' <<<"$out"; then ok "shared loader selects node scripts/test-setting-values.js"; else fail "shared loader omitted node scripts/test-setting-values.js"; fi
if grep -qF 'heap-profile' <<<"$out"; then fail "shared loader selected unrelated heap tests"; else ok "shared loader omits unrelated heap tests"; fi

# bin/vgsh holds the preflight floors the recipe check and the README check
# read.
d="$tmp/plan-floors"; fresh "$d"
mkdir -p "$d/bin"; printf 'changed\n' >"$d/bin/vgsh"
out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --changed HEAD --list 2>"$tmp/plan.err")"
for consumer in 'node scripts/check-packaging.js' 'node scripts/test-check-packaging.js' 'node scripts/check-readme.js' 'node scripts/test-check-readme.js' 'scripts/test-readme-install.sh'; do
  if grep -qxF "$consumer" <<<"$out"; then ok "a bin/vgsh change selects $consumer"; else fail "a bin/vgsh change omitted $consumer"; fi
done

d="$tmp/plan-full"; fresh "$d"
full_plan="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --full --list 2>"$tmp/plan.err")"
for reason in unknown unreadable; do
  base=HEAD
  case "$reason" in
    unknown) printf 'new\n' >"$d/new-source.rs" ;;
    unreadable) rm -- "${d:?}/new-source.rs"; base=missing-ref ;;
  esac
  if out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --changed "$base" --list 2>"$tmp/plan.err")" && [[ $out == "$full_plan" ]]; then ok "$reason input selects the full area"; else fail "$reason input omitted a suite: $out"; fi
done

d="$tmp/plan-selector"; fresh "$d"
printf '\n' >>"$d/scripts/validate"
selector_plan="$repo_plan"$'\nscripts/test-validate.sh'
if out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate --list 2>"$tmp/plan.err")" && [[ $out == "$selector_plan" ]]; then
  ok "selector changes run their control without unrelated product suites"
else
  fail "selector change plan: $out"
fi

# The Jarvis row must select the real environment helper, not only its suite.
# A harmless row fixture fails on a planted helper defect. Removing only the
# dependency edge lets that defect escape, without starting any test daemon.
d="$tmp/plan-jarvis-edge"; fresh "$d"
mkdir -p "$d/scripts/lib"
printf '# neutral selector fixture\n' >"$d/scripts/test-jarvis-local.py"
printf '# neutral selector fixture\n' >"$d/scripts/test-jarvis-setup.py"
printf '#!/usr/bin/env bash\nexit 0\n' >"$d/scripts/check-jarvis-local.sh"
chmod +x "$d/scripts/check-jarvis-local.sh"
printf 'const fs = require("node:fs"); process.exit(fs.readFileSync("scripts/lib/jarvis-env.sh", "utf8") === "clean\\n" ? 0 : 1);\n' >"$d/scripts/test-jarvis-env.js"
printf 'clean\n' >"$d/scripts/lib/jarvis-env.sh"
"${base_env[@]}" git -C "$d" add -A
"${base_env[@]}" git -C "$d" commit -q -m jarvis-row
printf 'defect\n' >"$d/scripts/lib/jarvis-env.sh"
test_area=tools
test_args=(--changed HEAD)
row "a Jarvis helper change runs its row and fails on the defect" "$d" 1 "" \
  "validate: failed=Jarvis test environment controls (exit 1)"
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old = 'node scripts/test-jarvis-env.js|scripts/lib/jarvis-env.sh scripts/fixtures/jarvis-env/*'
assert source.count(old) == 1
changed = source.replace(old, old.replace('scripts/lib/jarvis-env.sh ', ''))
assert changed != source
path.write_text(changed)
PY
"${base_env[@]}" git -C "$d" add scripts/validate
"${base_env[@]}" git -C "$d" commit -q -m control
# An unknown source would select the whole area. Keep the input known to
# another area, so this control isolates the lost tools dependency edge.
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old = 'logic|plugin logic table|node scripts/test-plugin-logic.js|'
assert source.count(old) == 1
changed = source.replace(old, old + 'scripts/lib/jarvis-env.sh ')
assert changed != source
path.write_text(changed)
PY
"${base_env[@]}" git -C "$d" add scripts/validate
"${base_env[@]}" git -C "$d" commit -q -m known-input
row "control: losing the Jarvis helper edge skips its failing row" "$d" 0 "" "validate: ok"
test_area=offline
test_args=()

# Both daemon consumers select their installed dependencies. Each disposable
# selector loses one edge while another row still knows the changed source.
for owner in 'audio-daemon|Jarvis audio daemon lifetime' 'browser|Jarvis browser executor'; do
  suite="${owner%%|*}"; label="${owner#*|}"
  case "$suite" in
    audio-daemon)
      dependencies=(shell/plugins/vgs.jarvis/backend/{ToolRouter,ToolBridge,Mcp,Audit,Private,Redact,Tools,Policy,ShellRequests,DesktopSession,Executors,Desktop,Child,Input,ComputerHelp}.js
        bin/lib/qml-library.js bin/lib/judge-files.js shell/Commons/DesktopLaunch.js) ;;
    browser)
      dependencies=(
        'shell/plugins/vgs.jarvis/backend/jarvisd.js|shell/plugins/vgs.jarvis/backend/*'
        shell/plugins/vgs.jarvis/Session.js shell/plugins/vgs.jarvis/JarvisProtocol.js shell/plugins/vgs.jarvis/AccountProviders.js
        shell/Core/Dispatch.js shell/Commons/DesktopLaunch.js bin/lib/qml-library.js bin/lib/judge-files.js
        'scripts/fixtures/jarvis/audio-tool.py|scripts/fixtures/jarvis/audio*'
        scripts/fixtures/jarvis/desktop.js
        'shell/plugins/vgs.jarvis/backend/skills/computer/input.md|shell/plugins/vgs.jarvis/backend/*') ;;
  esac
  consumer="node scripts/test-jarvis-$suite.js"
  for spec in "${dependencies[@]}"; do
    file="${spec%%|*}"; edge="${spec#*|}"
    d="$tmp/plan-$suite-edge-$(basename -- "$file")"; fresh "$d"
    mkdir -p -- "$d/$(dirname -- "$file")"
    printf 'changed\n' >"$d/$file"
    out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate cli --changed HEAD --list 2>"$tmp/plan.err")"
    if grep -qxF "$consumer" <<<"$out"; then
      ok "$suite selects dependency $file"
    else
      fail "$suite omitted dependency $file"
    fi
    python3 - "$d/scripts/validate" "$edge" "$label" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
rows = [row for row in source.splitlines() if '"cli|' + sys.argv[3] + '|' in row]
assert len(rows) == 1
row = rows[0]
prefix, inputs = row.rsplit("|", 1)
assert inputs.endswith('"')
edges = inputs[:-1].split()
assert edges.count(sys.argv[2]) == 1
edges.remove(sys.argv[2])
changed = source.replace(row, prefix + "|" + " ".join(edges) + '"')
assert changed != source
path.write_text(changed)
PYTHON
    "${base_env[@]}" git -C "$d" add scripts/validate
    "${base_env[@]}" git -C "$d" commit -q -m control
    out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate cli --changed HEAD --list 2>"$tmp/plan.err")"
    if grep -qxF "$consumer" <<<"$out"; then
      fail "$suite dependency control did not turn red: $file"
    else
      ok "control: losing $file fails the $suite consumer assertion"
    fi
  done
done

# The shader consumer builds the shared keyboard helper too. A stand-in
# consumer fails on a planted source defect, without starting a compositor.
d="$tmp/plan-keyboard-edge"; fresh "$d"
mkdir -p "$d/scripts/smoke/keyboard"
printf '#!/bin/sh\nexit 0\n' >"$d/scripts/qml-smoke.sh"
printf '#!/bin/sh\ngrep -qx clean scripts/smoke/keyboard/keyboard.c\n' >"$d/scripts/measure-shader.sh"
chmod +x "$d/scripts/qml-smoke.sh" "$d/scripts/measure-shader.sh"
printf 'clean\n' >"$d/scripts/smoke/keyboard/keyboard.c"
"${base_env[@]}" git -C "$d" add -A
"${base_env[@]}" git -C "$d" commit -q -m keyboard-consumers
printf 'defect\n' >"$d/scripts/smoke/keyboard/keyboard.c"
test_area=qml
test_args=(--changed HEAD)
row "a keyboard helper defect selects and fails the shader consumer" "$d" 1 "" \
  "validate: failed=shader GPU cost (exit 1)"
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
edge = ' scripts/smoke/keyboard/*'
assert s.count(edge) == 1
changed = s.replace(edge, '')
assert changed != s
p.write_text(changed)
PY
"${base_env[@]}" git -C "$d" add scripts/validate
"${base_env[@]}" git -C "$d" commit -q -m control
row "control: removing the keyboard edge hides the shader failure" "$d" 0 "" "validate: ok"
test_area=offline
test_args=()

d="$tmp/range-whitespace"; fresh "$d"
printf 'old defect \n' >"$d/clean.txt"
"${base_env[@]}" git -C "$d" add clean.txt
"${base_env[@]}" git -C "$d" commit -q -m previous-round
test_area=repo
test_args=(--changed HEAD)
row "a fix round does not recheck whitespace outside its range" "$d" 0 "" "validate: ok"
test_args=()
row "Kendex supplies the fix-round base without shell interpolation" "$d" 0 "DEV_VALIDATE_BASE=HEAD" "validate: ok"
test_args=(--changed HEAD)
printf 'new defect \n' >"$d/clean.txt"
row "a fix round still rejects new whitespace defects" "$d" 1 "" \
  "whitespace: findings scope=tracked"
test_args=()

# Exercise the real selected guard, then remove only its dependency edge.
# The policy mutation is committed into the fixture's base, so selection
# still judges the same changed source rather than its own policy edit.
d="$tmp/selected-guard"; fresh "$d"
cp -R "$repo/scripts/." "$d/scripts/"
cp -R "$repo/shell" "$repo/bin" "$repo/config" "$repo/themes" "$repo/packaging" "$d/"
cp -- "$repo/VERSION" "$repo/LICENSE" "$repo/README.md" "$d/"
# The token check walks the skill templates beside the shell tree.
mkdir -p "$d/.agents/skills/vgs-plugin"
cp -R "$repo/.agents/skills/vgs-plugin/templates" "$d/.agents/skills/vgs-plugin/"
# The copy carries none of the documents its citations name.
printf '*\tproduct copy without docs/\n' >>"$d/tools/md-excludes"
"${base_env[@]}" git -C "$d" add -A
"${base_env[@]}" git -C "$d" commit -q -m fixture
printf 'import "../plugins/vgs.bar"\nQtObject {}\n' >"$d/shell/Core/Bad.qml"
test_area=offline
test_args=(--changed HEAD)
row "a changed core import runs and fails its boundary check" "$d" 1 "" \
  "validate: failed=plugin boundary (exit 1)"
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
edge = 'plugin boundary|python3 scripts/check-plugin-boundary.py|shell/* bin/vgsh-scan scripts/qml_source.py'
assert source.count(edge) == 1
path.write_text(source.replace(edge, edge.replace('shell/* ', '')))
PY
"${base_env[@]}" git -C "$d" add scripts/validate
"${base_env[@]}" git -C "$d" commit -q -m control
row "removing the source dependency makes the planted defect escape" "$d" 0 "" "validate: ok"

# Every row runs under the test-run marker: a planted row fails without it,
# and a copy without the export is caught.
d="$tmp/marker"; fresh "$d"
printf '#!/bin/sh\n[ "$VGS_TEST_RUN" = 1 ]\n' >"$d/scripts/test-marker.sh"; chmod +x "$d/scripts/test-marker.sh"
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
assert source.count('rows=(\n') == 1
path.write_text(source.replace('rows=(\n', 'rows=(\n  "tools|test-run marker|scripts/test-marker.sh|"\n'))
PY
"${base_env[@]}" git -C "$d" commit -q -am marker-row
test_area=tools
test_args=(--changed HEAD)
row "a row runs under the test-run marker" "$d" 0 "" "validate: ok"
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
assert source.count('export VGS_TEST_RUN=1\n') == 1
path.write_text(source.replace('export VGS_TEST_RUN=1\n', ''))
PY
"${base_env[@]}" git -C "$d" commit -q -am control
row "a validate without the marker export fails the planted row" "$d" 1 "" "validate: failed=test-run marker (exit 1)"

# A diff-scoped run exports its NUL-delimited changed-path file to rows.
# A full run unsets even an inherited value, so no stale caller value can
# narrow a row accidentally.
d="$tmp/changed-export"; fresh "$d"
cat >"$d/scripts/changed-list.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'changed-env=%s\n' "${VGS_VALIDATE_CHANGED:-unset}"
if [[ -n ${VGS_VALIDATE_CHANGED:-} ]]; then
  python3 - "$VGS_VALIDATE_CHANGED" <<'PY'
import sys
with open(sys.argv[1], "rb") as source:
    for path in source.read().split(b"\0"):
        if path:
            print("changed-path=" + path.decode())
PY
fi
SH
chmod +x "$d/scripts/changed-list.sh"
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
source = path.read_text()
row = '  "tools|changed list echo|scripts/changed-list.sh|changed.txt"'
source, count = re.subn(r'rows=\(\n.*?\n\)\n', 'rows=(\n' + row + '\n)\n', source, count=1, flags=re.S)
assert count == 1
path.write_text(source)
PY
"${base_env[@]}" git -C "$d" add -A
"${base_env[@]}" git -C "$d" commit -q -m changed-list-row
printf 'changed\n' >"$d/changed.txt"
test_area=tools
test_args=(--changed HEAD)
row_re "a diff-scoped run exports the changed path list to rows" "$d" 0 "" \
  "~changed-env=" "changed-path=changed.txt" "~validate: secs=" "validate: ok"
test_args=(--full)
row "a full run unsets the changed path list inherited from the caller" "$d" 0 "VGS_VALIDATE_CHANGED=/x" \
  "changed-env=unset" "!changed-path=changed.txt" "validate: ok"
test_area=offline
test_args=()

# The vgsh suites read bundled plugins through their manifests. A QML
# plugin edit in the cli area no longer selects them, while a manifest edit
# still does.
d="$tmp/plugin-vgsh-selection"; fresh "$d"
for file in shell/plugins/acme.x/Panel.qml shell/plugins/acme.x/manifest.json; do
  mkdir -p -- "$d/$(dirname -- "$file")"
  printf 'changed\n' >"$d/$file"
  out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate cli --changed HEAD --list 2>"$tmp/plan.err")"
  case "$file" in
    */Panel.qml)
      for consumer in scripts/test-vgsh.sh scripts/test-vgsh-requirements.sh scripts/test-vgsh-outdated.sh; do
        if grep -qxF "$consumer" <<<"$out"; then fail "plugin QML selected $consumer"; else ok "plugin QML omits $consumer"; fi
      done ;;
    */manifest.json)
      for consumer in scripts/test-vgsh.sh scripts/test-vgsh-requirements.sh scripts/test-vgsh-outdated.sh; do
        if grep -qxF "$consumer" <<<"$out"; then ok "plugin manifest selects $consumer"; else fail "plugin manifest omitted $consumer"; fi
      done ;;
  esac
  rm -rf -- "$d/shell/plugins/acme.x"
done

# The document byte ceiling row. Its fixture carries the doc-limits checker,
# a 1 KiB class for every Markdown file and a committed 900-byte grown.md,
# all in the base; only the documents a row plants differ from it.
doc_fixture() {
  local dir="$1"
  fresh "$dir"
  mkdir -p "$dir/.agents/skills/doc-limits/scripts"
  cp -R "$repo/.agents/skills/doc-limits/scripts/." "$dir/.agents/skills/doc-limits/scripts/"
  printf '[env]\nWORKTREE_DEFAULT_BRANCH = "trunk"\nDOC_LIMITS_CLASSES = "*.md=1k"\nDOC_LIMITS_DEFAULT_CLASSES = ""\n' >"$dir/kendex.settings.toml"
  head -c 900 /dev/zero | tr '\0' x >"$dir/grown.md"
  "${base_env[@]}" git -C "$dir" add -A
  "${base_env[@]}" git -C "$dir" commit -q -m docs
  "${base_env[@]}" git -C "$dir" update-ref refs/remotes/origin/trunk HEAD
}
test_area=tools
test_args=()
d="$tmp/doc-small"; doc_fixture "$d"
doc_base="$("${base_env[@]}" git -C "$d" rev-parse HEAD)"
printf 'small\n' >"$d/small.md"
row "an untracked document under its ceiling is measured and passes" "$d" 0 "" \
  "doc-limits: base=$doc_base" "doc-limits: OK: 2 document(s) checked" "validate: ok"
d="$tmp/doc-big"; doc_fixture "$d"
head -c 2000 /dev/zero | tr '\0' x >"$d/big.md"
row "an untracked document over its ceiling fails" "$d" 1 "" \
  "doc-limits FAIL: big.md: 2000 bytes > 1024 bytes (class *.md)" "validate: failed=document byte ceilings (exit 1)"
if [[ -z "$("${base_env[@]}" git -C "$d" ls-files -- big.md)" ]] && "${base_env[@]}" git -C "$d" diff --cached --quiet; then
  ok "the ceiling row leaves the real index as it was"
else
  fail "the ceiling row wrote the real index"
fi
d="$tmp/doc-grown"; doc_fixture "$d"
head -c 1010 /dev/zero | tr '\0' x >"$d/grown.md"
row "an unstaged edit that grows a document into the margin fails" "$d" 1 "" \
  "doc-limits FAIL: grown.md: stored size grown from 900 to 1010 bytes; its 1010 bytes are within the 20-byte margin under 1024 bytes (class *.md)"
d="$tmp/doc-no-checker"; fresh "$d"; printf 'doc\n' >"$d/a.md"
row "a document change with no checker exits 77" "$d" 77 "" \
  "doc-limits: status=not-measured reason=checker-missing path=.agents/skills/doc-limits/scripts/doc-limits" \
  "validate: status=not-measured skipped=document byte ceilings"
# No base: only --full reaches the row without one, so this copy of validate
# holds the ceiling row alone.
d="$tmp/doc-no-base"; doc_fixture "$d"
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
source = path.read_text()
row = next(l for l in source.splitlines() if '|doc_limits_check|' in l)
source, count = re.subn(r'rows=\(\n.*?\n\)\n', 'rows=(\n' + row + '\n)\n', source, count=1, flags=re.S)
assert count == 1
path.write_text(source)
PY
test_args=(--full)
row "the ceiling row with no base exits 77" "$d" 77 "WORKTREE_DEFAULT_BRANCH=absent" \
  "doc-limits: status=not-measured reason=no-base missing=base-ref branch=absent remote-refs=0"
# A fix round after a rebase: the branch holds a commit from before it, the
# base branch then grew grown.md into its margin, and the branch, rebased
# onto it, leaves grown.md alone. --changed names the pre-rebase commit, so
# the base branch's growth selects the row; the row measures growth from
# the branch point and passes. OLD NEW, when given, is a replacement in the
# fixture's validate, committed before the rebase.
rebased_fixture() { # NAME [OLD NEW]
  local dir="$tmp/doc-rebased-$1"
  doc_fixture "$dir"
  if [[ $# -eq 3 ]]; then
    python3 - "$dir/scripts/validate" "$2" "$3" <<'PY'
from pathlib import Path
import sys
path, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
source = path.read_text()
assert source.count(old) == 1, old
path.write_text(source.replace(old, new))
PY
  fi
  printf 'branch\n' >"$dir/branch.txt"
  "${base_env[@]}" git -C "$dir" add -A
  "${base_env[@]}" git -C "$dir" commit -q -m pre-rebase
  pre_rebase="$("${base_env[@]}" git -C "$dir" rev-parse HEAD)"
  "${base_env[@]}" git -C "$dir" checkout -q --detach refs/remotes/origin/trunk
  head -c 1010 /dev/zero | tr '\0' x >"$dir/grown.md"
  "${base_env[@]}" git -C "$dir" commit -q -am upstream-growth
  "${base_env[@]}" git -C "$dir" update-ref refs/remotes/origin/trunk HEAD
  "${base_env[@]}" git -C "$dir" checkout -q feature
  "${base_env[@]}" git -C "$dir" rebase -q refs/remotes/origin/trunk
  d="$dir"
}
rebased_fixture branch-point
test_args=(--changed "$pre_rebase")
row "a fix round after a rebase does not charge the base branch's growth to the branch" "$d" 0 "" \
  "doc-limits: base=$("${base_env[@]}" git -C "$d" rev-parse refs/remotes/origin/trunk)" "validate: ok"
rebased_fixture change-base 'base="$(branch_point)"' 'base="$(whitespace_base)"'
test_args=(--changed "$pre_rebase")
row "control: measured from the fix-round base, the base branch's growth fails the branch" "$d" 1 "" \
  "doc-limits FAIL: grown.md: stored size grown from 900 to 1010 bytes; its 1010 bytes are within the 20-byte margin under 1024 bytes (class *.md)"
# Controls: copies of validate with one rule removed each, committed so the
# plan against HEAD judges the planted documents alone.
test_args=(--changed HEAD)
doc_control() { # NAME OLD NEW: a doc fixture whose validate replaces OLD once
  local dir="$tmp/doc-control-$1"
  doc_fixture "$dir"
  python3 - "$dir/scripts/validate" "$2" "$3" <<'PY'
from pathlib import Path
import sys
path, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
source = path.read_text()
assert source.count(old) == 1, old
path.write_text(source.replace(old, new))
PY
  "${base_env[@]}" git -C "$dir" commit -q -am control
  d="$dir"
}
doc_control scratch-index 'GIT_INDEX_FILE="$scratch" "$checker" --against' '"$checker" --against'
head -c 2000 /dev/zero | tr '\0' x >"$d/big.md"
row "control: on the real index an untracked document over its ceiling escapes" "$d" 0 "" "validate: ok"
doc_control margin '"$checker" --against "$base"' '"$checker"'
head -c 1010 /dev/zero | tr '\0' x >"$d/grown.md"
row "control: without --against a growth into the margin escapes" "$d" 0 "" "validate: ok"

# The markdown reference row. Its fixture commits an AGENTS.md that links
# target.md and its Kept heading; each row plants one defect in the tree the
# change will commit, and md-refs names it.
refs_fixture() {
  local dir="$1"
  fresh "$dir"
  printf '# Target\n\n## Kept\n' >"$dir/target.md"
  printf 'See [target](target.md) and [kept](target.md#kept).\n' >"$dir/AGENTS.md"
  "${base_env[@]}" git -C "$dir" add -A
  "${base_env[@]}" git -C "$dir" commit -q -m refs
  "${base_env[@]}" git -C "$dir" update-ref refs/remotes/origin/trunk HEAD
}
refs_failed="validate: failed=markdown references and source citations (exit 1)"
test_area=repo
test_args=()
d="$tmp/refs-clean"; refs_fixture "$d"
row "live references pass" "$d" 0 "" \
  "md-refs: summary=violations=0 references=2 markdown=1 sources=1 decisions=0:docs/decisions skipped=0"
d="$tmp/refs-untracked"; refs_fixture "$d"
mkdir -p "$d/sub"; printf 'See [gone](gone.md).\n' >"$d/sub/AGENTS.md"
row "a dead link in an untracked document fails" "$d" 1 "" \
  "md-refs: link-target=sub/AGENTS.md:1:](gone.md):sub/gone.md" "$refs_failed"
if [[ -z "$("${base_env[@]}" git -C "$d" ls-files -- sub/AGENTS.md)" ]] && "${base_env[@]}" git -C "$d" diff --cached --quiet; then
  ok "the reference row leaves the real index as it was"
else
  fail "the reference row wrote the real index"
fi
d="$tmp/refs-heading"; refs_fixture "$d"
printf '# Target\n' >"$d/target.md"
row "an unstaged edit that removes a cited heading fails its unchanged caller" "$d" 1 "" \
  "md-refs: anchor-missing=AGENTS.md:1:](target.md#kept):target.md:kept" "$refs_failed"
d="$tmp/refs-deleted"; refs_fixture "$d"
rm -- "$d/target.md"
row "an unstaged deletion of a linked document fails its unchanged caller" "$d" 1 "" \
  "md-refs: link-target=AGENTS.md:1:](target.md):target.md" "$refs_failed"
d="$tmp/refs-source"; refs_fixture "$d"
mkdir -p "$d/bin"; printf '#!/bin/sh\n# The rule is target.md § Gone.\n' >"$d/bin/tool.sh"
row "a dead section citation in an untracked source file fails" "$d" 1 "" \
  "md-refs: heading-prefix=bin/tool.sh:2:target.md § Gone.:target.md:Gone." "$refs_failed"
d="$tmp/refs-config"; refs_fixture "$d"
row "an md-refs configuration error fails the row, not a skip" "$d" 1 "COMMIT_GUARDS_MD_REFS_SOURCE_PATHS=" \
  "md-refs: glob-empty=COMMIT_GUARDS_MD_REFS_SOURCE_PATHS" "md-refs: failed status=2" "$refs_failed"
d="$tmp/refs-no-checker"; refs_fixture "$d"
rm -rf -- "${d:?}/.agents/skills/commit-guards"
row "a tree with no md-refs checker exits 77" "$d" 77 "" \
  "md-refs: status=not-measured reason=checker-missing path=.agents/skills/commit-guards/scripts/md-refs" \
  "validate: status=not-measured skipped=markdown references and source citations"
d="$tmp/refs-unreadable"; refs_fixture "$d"
printf 'x\n' >"$d/locked.txt"; chmod 000 "$d/locked.txt"
row "a tree the scratch index cannot copy is not measured, not a pass" "$d" 1 "" \
  "md-refs: status=not-measured reason=index-copy-failed path=$d/.git/index"
# Control: a copy of validate that runs md-refs on the real index, committed
# so the plan judges the planted document alone.
d="$tmp/refs-control"; refs_fixture "$d"
python3 - "$d/scripts/validate" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
old = 'GIT_INDEX_FILE="$scratch" "$checker" --all'
assert source.count(old) == 1, old
path.write_text(source.replace(old, '"$checker" --all'))
PY
"${base_env[@]}" git -C "$d" commit -q -am control
mkdir -p "$d/sub"; printf 'See [gone](gone.md).\n' >"$d/sub/AGENTS.md"
row "control: on the real index a dead link in an untracked document escapes" "$d" 0 "" "validate: ok"
test_area=offline
test_args=()

d="$tmp/arguments"; fresh "$d"
argument_cases=(
  'missing|--changed|changed-base=missing-or-repeated'
  'empty|--changed|changed-base=missing-or-repeated'
  'dash-prefixed|--changed --list|changed-base=missing-or-repeated'
  'repeated|--changed HEAD --changed HEAD|changed-base=missing-or-repeated'
  'full-and-changed|--full --changed HEAD|scope=conflicting-or-repeated'
  'changed-and-full|--changed HEAD --full|scope=conflicting-or-repeated'
  'repeated-full|--full --full|scope=conflicting-or-repeated'
  'second-area|logic|extra-argument=logic'
)
for spec in "${argument_cases[@]}"; do
  IFS='|' read -r name arguments refusal <<<"$spec"
  read -r -a test_args <<<"$arguments"
  [[ $name == empty ]] && test_args+=("")
  row "invalid $name argument is refused" "$d" 2 "" "validate: refused: $refusal"
done

if [[ $failures -gt 0 ]]; then
  echo "test-validate: failed=$failures"
  exit 1
fi
echo "test-validate: ok"
