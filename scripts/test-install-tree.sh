#!/usr/bin/env bash
# Controls for the shared system installer and the install tree manifest
# checker. The suite installs into repo-local scratch directories, never the
# live prefix. Each refusal row asserts the keyed first line a packager acts on.
set -euo pipefail

if ! node_bin="$(node -e 'process.stdout.write(process.execPath)')"; then
  echo 'test-install-tree: status=not-measured missing=node'
  exit 77
fi
[[ $node_bin == /* && -x $node_bin ]] || {
  echo 'test-install-tree: status=not-measured missing=node-binary'
  exit 77
}
repo="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)"
tmp="$repo/tmp/test-install-tree.$$"
failures=0
unavailable=false
cleanup() { chmod -R u+rwx -- "$tmp" 2>/dev/null || true; rm -rf -- "$tmp"; }
trap cleanup EXIT
rm -rf -- "$tmp"
mkdir -p -- "$tmp"
export TMPDIR="$tmp"

ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }
check() { # NAME CMD...
  local name="$1"; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
run_capture() { # OUT ERR STATUS_VAR CMD...
  local out_file="$1" err_file="$2" status_var="$3" rc=0
  shift 3
  "$@" >"$out_file" 2>"$err_file" || rc=$?
  printf -v "$status_var" '%s' "$rc"
}
grep_out() { grep -qxF -- "$1" "$2"; }
voice_command=(env -i PATH=/usr/bin:/bin "$node_bin" "$repo/scripts/fixtures/jarvis-voice/installed.js")

dest="$tmp/install"
run_capture "$tmp/install.out" "$tmp/install.err" status env DESTDIR="$dest" PREFIX=/usr "$repo/packaging/install-system.sh"
check "the installer succeeds into a staged /usr prefix" test "$status" = 0
check "the installer reports the staged root" grep_out "install-system: ok prefix=/usr root=$dest/usr" "$tmp/install.out"
run_capture "$tmp/check.out" "$tmp/check.err" status "$repo/scripts/check-install-tree.sh" "$dest" /usr
check "the committed manifest matches the installed tree" test "$status" = 0
check "the checker reports the manifest it used" grep_out "install-tree=ok root=$dest/usr manifest=$repo/packaging/install-tree.manifest" "$tmp/check.out"
check "the command link points into share/vgs" test "$(readlink -- "$dest/usr/bin/vgsh")" = "../share/vgs/bin/vgsh"
check "the installed command reads VERSION from the install tree" test "$("$dest/usr/bin/vgsh" --version)" = "vgs $(<"$repo/VERSION")"
check "shell AGENTS.md is not installed" test ! -e "$dest/usr/share/vgs/shell/AGENTS.md"
check "shell CLAUDE.md is not installed" test ! -e "$dest/usr/share/vgs/shell/CLAUDE.md"
check "shell plugin README.md is not installed" test ! -e "$dest/usr/share/vgs/shell/plugins/vgs.bar/README.md"
check "a plugin's other Markdown is not installed" test ! -e "$dest/usr/share/vgs/shell/plugins/vgs.updates/pipeline.md"
check "the core input resolver is installed" test -e "$dest/usr/share/vgs/bin/lib/xkb-keys.py"
check "Jarvis input guidance is installed" test -e "$dest/usr/share/vgs/shell/plugins/vgs.jarvis/backend/skills/computer/input.md"
check "Jarvis screen guidance is installed" test -e "$dest/usr/share/vgs/shell/plugins/vgs.jarvis/backend/skills/computer/vision.md"
check "installed computer help reads its packaged files" "$node_bin" -e 'const h=require(process.argv[1]).create(); if(JSON.stringify(h.topics)!==JSON.stringify(["input","vision"]))process.exit(1); h.start({id:"help",args:{topic:"input"}},r=>{if(r.outcome!=="completed"||!r.content.includes("input.text"))process.exit(1)}); h.start({id:"help",args:{topic:"vision"}},r=>{if(r.outcome!=="completed"||!r.content.includes("vision.area"))process.exit(1)});' "$dest/usr/share/vgs/shell/plugins/vgs.jarvis/backend/ComputerHelp.js"
check "Jarvis runtime guidance is installed" test -e "$dest/usr/share/vgs/shell/plugins/vgs.jarvis/backend/skills/voice/core.md"
browser_standins="$tmp/browser-standins"
mkdir -p -- "$browser_standins"
cp -- "$repo/scripts/fixtures/jarvis/browser.py" "$browser_standins/agent-browser"
cp -- "$repo/scripts/fixtures/jarvis/browser-gum.py" "$browser_standins/gum"
chmod 700 "$browser_standins/agent-browser" "$browser_standins/gum"
run_capture "$tmp/browser.out" "$tmp/browser.err" status env -i PATH=/usr/bin:/bin \
  JARVIS_TEST_SCRATCH_ROOT="${JARVIS_TEST_SCRATCH_ROOT:-$repo/tmp}" \
  "$repo/scripts/lib/jarvis-env.sh" "$browser_standins" -- node \
  "$repo/scripts/test-jarvis-browser-setup.js" --inside "$dest/usr/share/vgs"
if [[ $status == 77 ]]; then
  unavailable=true
  echo "test-install-tree: browser=unavailable exit=77"
else
  if [[ $status != 0 ]]; then cat -- "$tmp/browser.err" >&2; fi
  check "installed browser setup and stub reach their real consumer" test "$status" = 0
fi
run_capture "$tmp/guidance.out" "$tmp/guidance.err" status "${voice_command[@]}" "$dest/usr/share/vgs"
check "installed guidance composes every consumer without source-tree files" test "$status" = 0
setup_standins="$tmp/setup-standins"
mkdir -p -- "$setup_standins"
run_capture "$tmp/setup.out" "$tmp/setup.err" status env -i PATH=/usr/bin:/bin \
  JARVIS_TEST_SCRATCH_ROOT="${JARVIS_TEST_SCRATCH_ROOT:-$repo/tmp}" \
  "$repo/scripts/lib/jarvis-env.sh" "$setup_standins" -- python3 \
  "$repo/scripts/fixtures/jarvis-setup/installed.py" "$dest/usr/share/vgs"
if [[ $status != 0 ]]; then cat -- "$tmp/setup.err" >&2; fi
if [[ $status == 77 ]]; then
  unavailable=true
  echo "test-install-tree: local-readiness=unavailable exit=77"
else
  check "installed local readiness reads without source-tree files" test "$status" = 0
  check "installed local readiness is not inferred from packaged inputs" grep_out "jarvis-setup-installed=ok" "$tmp/setup.out"
fi
private_node="$tmp/private node/bin/node"
empty_path="$tmp/no-node-on-path"
mkdir -p -- "$(dirname -- "$private_node")" "$empty_path"
cp -- "$node_bin" "$private_node"
run_capture "$tmp/private-node.out" "$tmp/private-node.err" status env -i PATH=/usr/bin:/bin "$private_node" -e 'process.stdout.write(process.execPath)'
check "a non-system Node executable resolves its real path" test "$status" = 0
check "the resolved runtime stays outside the system directories" grep_out "$private_node" "$tmp/private-node.out"
private_voice=("${voice_command[@]}")
private_voice[2]="PATH=$empty_path"
private_voice[3]="$(<"$tmp/private-node.out")"
run_capture "$tmp/private-voice.out" "$tmp/private-voice.err" status "${private_voice[@]}" "$dest/usr/share/vgs"
check "the installed consumer uses resolved Node with no Node on PATH" test "$status" = 0
check "the non-system runtime reaches the real installed consumer" grep_out "jarvis-voice-installed=ok" "$tmp/private-voice.out"
private_voice[3]=node
run_capture "$tmp/private-voice-mutant.out" "$tmp/private-voice-mutant.err" status "${private_voice[@]}" "$dest/usr/share/vgs"
check "control: replacing resolved Node with a PATH lookup fails the consumer" test "$status" = 127

# A version-manager shim can fail or return no runtime. Each copy changes
# only that refusal, and the same keyed assertion must reject the copy.
for node_case in failed empty; do
  guard_root="$tmp/node-$node_case"
  mkdir -p -- "$guard_root/bin" "$guard_root/scripts"
  if [[ $node_case == failed ]]; then
    printf '#!/usr/bin/env bash\nexit 23\n' >"$guard_root/bin/node"
    missing=node
  else
    printf '#!/usr/bin/env bash\nexit 0\n' >"$guard_root/bin/node"
    missing=node-binary
  fi
  chmod 755 -- "$guard_root/bin/node"
  node_env=(env -i PATH="$guard_root/bin:/usr/bin:/bin" HOME="$guard_root" TMPDIR="$tmp" VGS_TEST_RUN=1)
  run_capture "$tmp/node-$node_case.out" "$tmp/node-$node_case.err" status "${node_env[@]}" bash "$repo/scripts/test-install-tree.sh"
  check "Node resolution ($node_case) is not verified" test "$status" = 77
  check "Node resolution ($node_case) names its cause" grep_out "test-install-tree: status=not-measured missing=$missing" "$tmp/node-$node_case.out"
  python3 - "$repo/scripts/test-install-tree.sh" "$guard_root/scripts/test-install-tree.sh" "$node_case" <<'PY'
import pathlib
import sys

source, target = map(pathlib.Path, sys.argv[1:3])
text = source.read_text()
if sys.argv[3] == "failed":
    needle = 'if ! node_bin="$(node -e \'process.stdout.write(process.execPath)\')"; then'
    replacement = needle.replace("if ! ", "if ")
else:
    needle = '[[ $node_bin == /* && -x $node_bin ]] || {\n'
    replacement = '[[ true ]] || {\n'
if text.count(needle) != 1:
    raise SystemExit("install-control: Node guard did not occur once")
changed = text.replace(needle, replacement)
if changed == text or target.is_symlink():
    raise SystemExit("install-control: Node guard copy did not change")
target.write_text(changed)
PY
  run_capture "$tmp/node-$node_case-mutant.out" "$tmp/node-$node_case-mutant.err" status "${node_env[@]}" bash "$guard_root/scripts/test-install-tree.sh"
  if [[ $status == 77 ]] && grep_out "test-install-tree: status=not-measured missing=$missing" "$tmp/node-$node_case-mutant.out"; then
    fail "control: a removed $node_case Node guard still passes its assertion"
  else
    ok "control: a removed $node_case Node guard fails its keyed assertion"
  fi
done
check "root README.md is installed under doc" test -e "$dest/usr/share/doc/vgs/README.md"
check "LICENSE is installed under licenses" test -e "$dest/usr/share/licenses/vgs/LICENSE"

run_capture "$tmp/rerun.out" "$tmp/rerun.err" status env DESTDIR="$dest" PREFIX=/usr "$repo/packaging/install-system.sh"
check "rerunning over a non-empty runtime tree is refused" test "$status" = 1
check "the rerun refusal names the runtime tree" grep_out "install-system: refused: target=not-empty path=$dest/usr/share/vgs" "$tmp/rerun.err"

link_dest="$tmp/link-target"
mkdir -p "$link_dest/usr/bin"
printf 'wrong\n' >"$link_dest/usr/bin/vgsh"
run_capture "$tmp/link-target.out" "$tmp/link-target.err" status env DESTDIR="$link_dest" PREFIX=/usr "$repo/packaging/install-system.sh"
check "an existing non-link command path is refused" test "$status" = 1
check "the command path refusal is keyed" grep_out "install-system: refused: link=unexpected path=$link_dest/usr/bin/vgsh" "$tmp/link-target.err"

enum_dest="$tmp/enumerator"
git_stub="$tmp/git-stub"; mkdir -p -- "$git_stub"
real_git="$(command -v git)"
cat >"$git_stub/git" <<SH
#!/usr/bin/env bash
root=""
if [[ \${1:-} == -C ]]; then root="\$2"; shift 2; fi
if [[ \${1:-} == rev-parse && \${2:-} == --show-toplevel ]]; then
  printf '%s\n' "\$root"
  exit 0
fi
if [[ \${1:-} == ls-files ]]; then
  echo 'git-stub=ls-files-failed' >&2
  exit 23
fi
exec "$real_git" "\$@"
SH
chmod 755 "$git_stub/git"
run_capture "$tmp/enumerator.out" "$tmp/enumerator.err" status env PATH="$git_stub:$PATH" DESTDIR="$enum_dest" PREFIX=/usr "$repo/packaging/install-system.sh"
check "a failing git enumerator is refused" test "$status" = 1
check "the git enumerator refusal is keyed" grep_out "install-system: refused: enumerate=failed path=$repo" "$tmp/enumerator.err"
check "a failing git enumerator prints no success line" test ! -s "$tmp/enumerator.out"
check "a failing git enumerator creates no DESTDIR file" test ! -e "$enum_dest"

archive_source="$tmp/archive-source"
mkdir -p -- "$archive_source"
cp -R -- "$repo/bin" "$repo/shell" "$repo/config" "$repo/themes" "$repo/packaging" "$archive_source/"
cp -- "$repo/VERSION" "$repo/LICENSE" "$repo/README.md" "$archive_source/"
mkdir -p -- "$archive_source/shell/unreadable"
chmod 000 -- "$archive_source/shell/unreadable"
run_capture "$tmp/archive-enumerator.out" "$tmp/archive-enumerator.err" status env DESTDIR="$tmp/archive-enumerator" PREFIX=/usr "$archive_source/packaging/install-system.sh"
chmod 755 -- "$archive_source/shell/unreadable"
check "a failing archive enumerator is refused" test "$status" = 1
check "the archive enumerator refusal is keyed" grep_out "install-system: refused: enumerate=failed path=$archive_source" "$tmp/archive-enumerator.err"
check "a failing archive enumerator prints no success line" test ! -s "$tmp/archive-enumerator.out"
check "a failing archive enumerator creates no DESTDIR file" test ! -e "$tmp/archive-enumerator"

readonly_source="$tmp/readonly-source"
mkdir -p -- "$readonly_source"
cp -R -- "$repo/bin" "$repo/shell" "$repo/config" "$repo/themes" "$repo/packaging" "$readonly_source/"
cp -- "$repo/VERSION" "$repo/LICENSE" "$repo/README.md" "$readonly_source/"
chmod -R a-w -- "$readonly_source"
run_capture "$tmp/readonly-source.out" "$tmp/readonly-source.err" status env DESTDIR="$tmp/readonly-source-install" PREFIX=/usr "$readonly_source/packaging/install-system.sh"
check "installing from a read-only source succeeds" test "$status" = 0
check "the read-only source install reports success" grep_out "install-system: ok prefix=/usr root=$tmp/readonly-source-install/usr" "$tmp/readonly-source.out"
chmod -R u+w -- "$readonly_source"

case_dest="$tmp/missing"
cp -a -- "$dest" "$case_dest"
rm -- "$case_dest/usr/share/vgs/VERSION"
run_capture "$tmp/missing.out" "$tmp/missing.err" status "$repo/scripts/check-install-tree.sh" "$case_dest" /usr
check "a missing manifest entry fails the checker" test "$status" = 1
check "the missing line names the entry" grep_out "install-tree=missing entry=f share/vgs/VERSION" "$tmp/missing.out"

case_dest="$tmp/extra"
cp -a -- "$dest" "$case_dest"
printf 'extra\n' >"$case_dest/usr/share/vgs/EXTRA"
run_capture "$tmp/extra.out" "$tmp/extra.err" status "$repo/scripts/check-install-tree.sh" "$case_dest" /usr
check "an extra installed file fails the checker" test "$status" = 1
check "the extra line names the entry" grep_out "install-tree=extra entry=f share/vgs/EXTRA" "$tmp/extra.out"

case_dest="$tmp/link"
cp -a -- "$dest" "$case_dest"
rm -- "$case_dest/usr/bin/vgsh"
ln -s -- wrong "$case_dest/usr/bin/vgsh"
run_capture "$tmp/link.out" "$tmp/link.err" status "$repo/scripts/check-install-tree.sh" "$case_dest" /usr
check "a wrong command link fails the checker" test "$status" = 1
check "the checker reports the wanted link missing" grep_out "install-tree=missing entry=l bin/vgsh -> ../share/vgs/bin/vgsh" "$tmp/link.out"
check "the checker reports the wrong link as extra" grep_out "install-tree=extra entry=l bin/vgsh -> wrong" "$tmp/link.out"

writer="$tmp/writer"
mkdir -p -- "$writer/scripts" "$writer/packaging"
cp -- "$repo/scripts/check-install-tree.sh" "$writer/scripts/check-install-tree.sh"
cp -- "$repo/packaging/install-tree.manifest" "$writer/packaging/install-tree.manifest"
"$writer/scripts/check-install-tree.sh" --write "$dest" /usr >"$tmp/write.out"
check "--write regenerates the committed manifest shape" cmp -s -- "$repo/packaging/install-tree.manifest" "$writer/packaging/install-tree.manifest"
check "--write reports the manifest path" grep_out "install-tree=manifest-updated path=$writer/packaging/install-tree.manifest" "$tmp/write.out"

source_copy="$tmp/source"
mkdir -p -- "$source_copy"
cp -R -- "$repo/bin" "$repo/shell" "$repo/config" "$repo/themes" "$repo/packaging" "$source_copy/"
cp -- "$repo/VERSION" "$repo/LICENSE" "$repo/README.md" "$source_copy/"
python3 - "$source_copy/packaging/install-system.sh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
needle = '  skip_shell_markdown "$rel" && continue\n'
if text.count(needle) != 1:
    raise SystemExit("install-control: skip line did not occur once")
path.write_text(text.replace(needle, '  false && skip_shell_markdown "$rel" && continue\n'))
PY
mutant_dest="$tmp/mutant"
run_capture "$tmp/mutant-install.out" "$tmp/mutant-install.err" status env DESTDIR="$mutant_dest" PREFIX=/usr "$source_copy/packaging/install-system.sh"
check "the markdown-dropping mutant still installs" test "$status" = 0
run_capture "$tmp/mutant-check.out" "$tmp/mutant-check.err" status "$repo/scripts/check-install-tree.sh" "$mutant_dest" /usr
check "the manifest catches a mutant that installs shell markdown" test "$status" = 1
check "the mutant's shell AGENTS.md is reported as extra" grep_out "install-tree=extra entry=f share/vgs/shell/AGENTS.md" "$tmp/mutant-check.out"

python3 - "$source_copy/packaging/install-system.sh" "$repo/packaging/install-system.sh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = pathlib.Path(sys.argv[2]).read_text()
needle = '  [[ $1 == shell/plugins/vgs.jarvis/backend/skills/voice/*.md ]] && return 1\n'
if text.count(needle) != 1:
    raise SystemExit("install-control: voice exception did not occur once")
changed = text.replace(needle, '  [[ $1 == shell/plugins/vgs.jarvis/backend/skills/voice/*.md ]] && return 0\n')
if changed == text:
    raise SystemExit("install-control: voice exception did not change")
path.write_text(changed)
PY
mutant_dest="$tmp/voice-mutant"
run_capture "$tmp/voice-install.out" "$tmp/voice-install.err" status env DESTDIR="$mutant_dest" PREFIX=/usr "$source_copy/packaging/install-system.sh"
check "the guidance-dropping mutant still installs" test "$status" = 0
run_capture "$tmp/voice-check.out" "$tmp/voice-check.err" status "$repo/scripts/check-install-tree.sh" "$mutant_dest" /usr
check "the manifest catches dropped runtime guidance" test "$status" = 1
check "the dropped core layer is reported as missing" grep_out "install-tree=missing entry=f share/vgs/shell/plugins/vgs.jarvis/backend/skills/voice/core.md" "$tmp/voice-check.out"
run_capture "$tmp/voice-compose.out" "$tmp/voice-compose.err" status "${voice_command[@]}" "$mutant_dest/usr/share/vgs"
check "the dropped-guidance mutant breaks the installed consumer" test "$status" = 1

READ_ONLY_PREFIX_SOURCE_ONLY=true source "$repo/scripts/smoke/rows/read-only-prefix.sh"
signal_dest="$tmp/signal-install"
run_capture "$tmp/signal-install.out" "$tmp/signal-install.err" status env DESTDIR="$signal_dest" PREFIX=/usr "$repo/packaging/install-system.sh"
check "the target guard control install succeeds" test "$status" = 0
installed_targets="$signal_dest/usr/share/vgs/themes/targets"
check "the pristine install carries production targets" test -e "$installed_targets/kitty/target.json"
fixture_tree="$tmp/fixture-target-tree"
mkdir -p -- "$fixture_tree/themes/targets/fixture-only"
printf '{"app":"fixture-only","runsCode":false,"encoder":"hex8","files":[],"detect":[],"wiring":null,"reload":null}\n' >"$fixture_tree/themes/targets/fixture-only/target.json"
printf 'fixture\n' >"$fixture_tree/themes/targets/fixture-only/fixture.conf"
signal_shim="$tmp/signal-shim"
read_only_prefix_prepare_tree "$signal_dest/usr" "$fixture_tree" "$signal_shim"
check "the read-only prefix guard removes production targets" test ! -e "$installed_targets/kitty/target.json"
check "the read-only prefix guard installs exactly the fixture targets" diff -r -- "$fixture_tree/themes/targets" "$installed_targets"
mutant_dest="$tmp/target-mutant"
run_capture "$tmp/target-mutant.out" "$tmp/target-mutant.err" status env DESTDIR="$mutant_dest" PREFIX=/usr "$repo/packaging/install-system.sh"
check "the target mutant install succeeds" test "$status" = 0
if diff -r -- "$fixture_tree/themes/targets" "$mutant_dest/usr/share/vgs/themes/targets" >/dev/null 2>&1; then
  fail "the guardless target mutant matched the fixture targets"
else
  ok "the guardless target mutant fails the fixture-target comparison"
fi

log_failures=0
check_unexpected_log() { # LABEL LOG
  if grep -q 'ERROR qml:' "$2"; then log_failures=$((log_failures + 1)); else ok "$1 holds no unexpected error ($2)"; fi
}
shell_qs_pid=12345
bad_log="$tmp/installed-error.log"
printf 'ERROR qml: planted\n' >"$bad_log"
read_only_prefix_check_installed_log "$bad_log"
check "the installed log checker fails on an unexpected error" test "$log_failures" -gt 0

if [[ $failures -gt 0 ]]; then echo "test-install-tree: failed=$failures"; exit 1; fi
if [[ $unavailable == true ]]; then
  echo "test-install-tree: status=not-measured reason=jarvis-isolation"
  exit 77
fi
echo "test-install-tree: ok"
