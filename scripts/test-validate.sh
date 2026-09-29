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
base_env=(env -i PATH="$(dirname -- "$node_bin"):$PATH" HOME="$tmp/home" LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z)

failures=0
test_args=()
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# A fresh scratch repository at $1: trunk holds the script, the loader, a
# settings file naming trunk as the base branch and one clean file;
# refs/remotes/origin/trunk points at it; HEAD is a feature branch on top.
fresh() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/.agents/skills/orch/scripts/lib"
  cp -- "$repo/scripts/validate" "$dir/scripts/validate"
  cp -- "$repo/.agents/skills/orch/scripts/lib/kendex-env.sh" "$dir/.agents/skills/orch/scripts/lib/kendex-env.sh"
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
# status and that each LINE is a whole line of its output.
row() {
  local name="$1" dir="$2" want_exit="$3" extra="$4" out status=0 line missing=""
  shift 4
  # shellcheck disable=SC2086
  out="$(cd -- "$dir" && "${base_env[@]}" $extra bash scripts/validate "${test_area:-repo}" "${test_args[@]}" 2>&1)" || status=$?
  for line in "$@"; do
    grep -qxF -e "$line" <<<"$out" || missing+="[$line]"
  done
  if [[ $status == "$want_exit" && -z $missing ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit missing=$missing"; printf '%s\n' "$out" | sed 's/^/        /'; fi
}

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
repo_plan=$'whitespace_check\nrows_cover_tests\nruntime_reads_no_scripts'
install_plan=$'scripts/test-install-tree.sh\n'"$repo_plan"
installer_plan=$'scripts/test-install-tree.sh\nscripts/test-vgsh-self.sh\nscripts/test-install-sh.sh\nscripts/test-release.sh\n'"$repo_plan"
# The README check reads VERSION, bin/vgsh, install.sh, the Arch recipes,
# the plugins, README.md and docs/architecture/runtime.md.
readme_rows=$'node scripts/check-readme.js\nnode scripts/test-check-readme.js\nscripts/test-readme-install.sh\n'
readme_plan="$readme_rows$repo_plan"
curl_installer_plan="$readme_rows"$'scripts/test-install-sh.sh\nscripts/test-release.sh\n'"$repo_plan"
heap_plan=$'python3 scripts/test-attribute-heap-profile.py\n'"$repo_plan"
dispatch_plan=$'node scripts/test-dispatch.js\nscripts/test-install-tree.sh\npython3 scripts/check-plugin-boundary.py\npython3 scripts/check-design-tokens.py\n'"$repo_plan"
fixture_plan=$'node bin/lib/check-manifests.js --base scripts/smoke/fixtures/plugins\npython3 scripts/check-plugin-boundary.py --shell scripts/smoke/fixtures\npython3 scripts/check-design-tokens.py\n'"$repo_plan"$'\nscripts/test-validate.sh\nscripts/qml-smoke.sh'
smoke_plan="$repo_plan"$'\nscripts/qml-smoke.sh'
fedora_plan=$'scripts/test-fedora-srpm.sh\n'
version_plan=$'scripts/test-vgsh-version.sh\nscripts/test-install-tree.sh\n'"$fedora_plan"$'node scripts/check-packaging.js\nnode scripts/test-check-packaging.js\n'"$readme_rows"$'scripts/test-release.sh\nscripts/test-publish-aur.sh\n'"$repo_plan"
# A recipe change runs the recipe check and its controls, never the product
# smoke; the container build runs only where the area admits it, never
# offline.
recipe_plan=$'node scripts/check-packaging.js\nnode scripts/test-check-packaging.js\nscripts/test-publish-aur.sh\n'"$repo_plan"
# An Arch recipe is also the README's source for the AUR commands.
arch_recipe_plan=$'node scripts/check-packaging.js\nnode scripts/test-check-packaging.js\n'"$readme_rows"$'scripts/test-publish-aur.sh\n'"$repo_plan"
cases=(
  "docs|docs/architecture/overview.md|offline|$repo_plan"$'\ndoc_limits_check'
  "runtime-doc|docs/architecture/runtime.md|offline|$readme_plan"$'\ndoc_limits_check'
  "docs-html|docs/guide.html|offline|$repo_plan"$'\ndoc_limits_check'
  "root-markdown|NOTES.md|offline|$repo_plan"$'\ndoc_limits_check'
  "version|VERSION|offline|$version_plan"
  "licence|LICENSE|all|$install_plan"$'\nscripts/test-flake.sh\nscripts/qml-smoke.sh'
  "flake|flake.nix|all|$repo_plan"$'\nscripts/test-flake.sh'
  "flake-offline|flake.nix|offline|$repo_plan"
  "installer|packaging/install-system.sh|offline|$installer_plan"
  "curl-installer|install.sh|offline|$curl_installer_plan"
  "recipe|packaging/arch/vgs/PKGBUILD|offline|$arch_recipe_plan"
  "recipe-all|packaging/arch/vgs-git/.SRCINFO|all|$arch_recipe_plan"$'\nscripts/arch-packages.sh'
  "recipe-package|packaging/arch/vgs/PKGBUILD|package|scripts/arch-packages.sh"
  "requirements|config/requirements.json|offline|node scripts/test-plugin-logic.js"$'\nscripts/test-install-tree.sh\nnode scripts/check-packaging.js\nnode scripts/test-check-packaging.js\nscripts/test-vgsh-requirements.sh\nscripts/test-install-sh.sh\nscripts/test-publish-aur.sh\n'"$repo_plan"
  "install-manifest|packaging/install-tree.manifest|offline|scripts/test-install-tree.sh"$'\nscripts/test-release.sh\n'"$repo_plan"
  "fedora-recipe|packaging/fedora/vgs.spec|all|$fedora_plan$recipe_plan"
  "copr-entry|.copr/Makefile|all|scripts/test-fedora-srpm.sh"$'\n'"$repo_plan"
  "heap|scripts/attribute-heap-profile.py|offline|$heap_plan"
  "suite|scripts/test-attribute-heap-profile.py|offline|$heap_plan"
  "dispatch|shell/Core/Dispatch.js|offline|$dispatch_plan"
  "fixture|scripts/smoke/fixtures/plugins/acme.contention/Background.qml|all|$fixture_plan"
  "smoke-row|scripts/smoke/rows/example.sh|all|$smoke_plan"
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
rename_plan=$'node scripts/test-dispatch.js\nscripts/test-install-tree.sh\n'"$readme_rows"$'python3 scripts/check-plugin-boundary.py\npython3 scripts/check-design-tokens.py\n'"$repo_plan"
if out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --changed HEAD --list 2>"$tmp/plan.err")" && [[ $out == "$rename_plan"$'\ndoc_limits_check' ]]; then ok "a rename selects consumers of the removed source path"; else fail "rename omitted the old path's consumers: $out"; fi

d="$tmp/plan-shared"; fresh "$d"
mkdir -p "$d/bin/lib"; printf 'changed\n' >"$d/bin/lib/qml-library.js"
out="$(cd -- "$d" && "${base_env[@]}" bash scripts/validate offline --changed HEAD --list 2>"$tmp/plan.err")"
for consumer in 'node scripts/test-plugin-logic.js' 'node scripts/test-dispatch.js' 'node scripts/test-lifetime.js' 'node scripts/test-qml-library.js' 'node bin/lib/check-manifests.js' 'node scripts/test-check-manifests.js' 'scripts/test-vgsh.sh' 'scripts/test-install-tree.sh' 'python3 scripts/test-vgs-plugin.py' 'scripts/test-validate.sh'; do
  if grep -qxF "$consumer" <<<"$out"; then ok "shared loader selects $consumer"; else fail "shared loader omitted $consumer"; fi
done
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

# The document byte ceiling row. Its fixture carries the doc-limits checker,
# a 1 KiB class for every Markdown file and a committed 900-byte grown.md,
# all in the base; only the documents a row plants differ from it.
doc_fixture() {
  local dir="$1"
  fresh "$dir"
  mkdir -p "$dir/.agents/skills/doc-limits/scripts" "$dir/.agents/skills/commit-guards/scripts/lib"
  cp -R "$repo/.agents/skills/doc-limits/scripts/." "$dir/.agents/skills/doc-limits/scripts/"
  cp -- "$repo/.agents/skills/commit-guards/scripts/lib/generated-paths.sh" "$repo/.agents/skills/commit-guards/scripts/lib/messages.sh" "$dir/.agents/skills/commit-guards/scripts/lib/"
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
doc_control scratch-index 'GIT_INDEX_FILE="$scratch" "$checker"' '"$checker"'
head -c 2000 /dev/zero | tr '\0' x >"$d/big.md"
row "control: on the real index an untracked document over its ceiling escapes" "$d" 0 "" "validate: ok"
doc_control margin '"$checker" --against "$base"' '"$checker"'
head -c 1010 /dev/zero | tr '\0' x >"$d/grown.md"
row "control: without --against a growth into the margin escapes" "$d" 0 "" "validate: ok"
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
