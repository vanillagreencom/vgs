#!/usr/bin/env bash
# Controls for the shared system installer and the install tree manifest
# checker. The suite installs into repo-local scratch directories, never the
# live prefix. Each refusal row asserts the keyed first line a packager acts on.
set -euo pipefail

repo="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)"
tmp="$repo/tmp/test-install-tree.$$"
failures=0
cleanup() { chmod -R u+rwx -- "$tmp" 2>/dev/null || true; rm -rf -- "$tmp"; }
trap cleanup EXIT
rm -rf -- "$tmp"
mkdir -p -- "$tmp"

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
run_capture "$tmp/enumerator.out" "$tmp/enumerator.err" status env DESTDIR="$enum_dest" PREFIX=/usr VGS_INSTALL_ENUMERATOR=false "$repo/packaging/install-system.sh"
check "a failing enumerator is refused" test "$status" = 1
check "the enumerator refusal is keyed" grep_out "install-system: refused: enumerate=failed path=$repo" "$tmp/enumerator.err"
check "a failing enumerator prints no success line" test ! -s "$tmp/enumerator.out"

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

READ_ONLY_PREFIX_SOURCE_ONLY=true source "$repo/scripts/smoke/rows/read-only-prefix.sh"
signal_dest="$tmp/signal-install"
run_capture "$tmp/signal-install.out" "$tmp/signal-install.err" status env DESTDIR="$signal_dest" PREFIX=/usr "$repo/packaging/install-system.sh"
check "the signal control install succeeds" test "$status" = 0
hostile_target="$signal_dest/usr/share/vgs/themes/targets/hostile"
mkdir -p -- "$hostile_target"
cat >"$hostile_target/target.json" <<'JSON'
{ "app": "hostile", "runsCode": false, "encoder": "hex8", "files": [{ "template": "hostile.conf", "destination": "hostile.conf" }], "detect": [], "wiring": null, "reload": { "command": ["pkill", "-USR1", "kitty"], "timeoutMs": 5000 } }
JSON
printf 'accent=@{palette.accent}\n' >"$hostile_target/hostile.conf"
signal_shim="$tmp/signal-shim"
signal_log="$tmp/signal.log"
read_only_prefix_signal_path "$signal_shim"
rm -f -- "$signal_log"
env -i PATH="$signal_shim:$(dirname -- "$(node -e 'process.stdout.write(process.execPath)')"):$PATH" HOME="$tmp/signal-home" XDG_CONFIG_HOME="$tmp/signal-home/.config" VGS_READ_ONLY_SIGNAL_LOG="$signal_log" "$signal_dest/usr/bin/vgsh" theme apply vgs >/dev/null || true
check "the planted hostile target reaches the signalling shim without the guard" test -s "$signal_log"
empty_tree="$tmp/empty-tree"
mkdir -p -- "$empty_tree/themes/targets"
rm -f -- "$signal_log"
read_only_prefix_prepare_tree "$signal_dest/usr" "$empty_tree" "$signal_shim"
env -i PATH="$signal_shim:$(dirname -- "$(node -e 'process.stdout.write(process.execPath)')"):$PATH" HOME="$tmp/signal-home" XDG_CONFIG_HOME="$tmp/signal-home/.config" VGS_READ_ONLY_SIGNAL_LOG="$signal_log" "$signal_dest/usr/bin/vgsh" theme apply vgs >/dev/null || true
check "the read-only prefix guard removes installed reload targets" test ! -e "$hostile_target/target.json"
check "the guarded apply calls no process-signalling shim" test ! -s "$signal_log"

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
echo "test-install-tree: ok"
