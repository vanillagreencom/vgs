#!/usr/bin/env bash
# The launcher's file search helper, shell/plugins/vgs.launcher/file-search.sh,
# run against a throwaway home: the index and its place, name and path
# matching, the result limit, names no line can hold, hidden roots, vanished
# files, a refresh that meets a running build, and every keyed refusal.
# The 200000-entry index ceiling is not reached here: planting that many
# files costs more than the suite is worth, so the ceiling's truncation line
# is unexercised.
#
# The controls at the end edit a copy of the helper, one rule at a time, and
# require the suite to fail on each copy.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
helper="$repo/shell/plugins/vgs.launcher/file-search.sh"
# The EXIT trap is armed only on the directory mktemp made: an empty or
# non-directory answer never reaches rm -rf.
TMP_ROOT="$(mktemp -d)" || { echo "test-launcher-file-search: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-launcher-file-search: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
for tool in fd fzf file flock awk stat gio xdg-mime; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'test-launcher-file-search: status=not-measured missing=%s\n' "$tool"
    exit 77
  fi
done

home="$TMP_ROOT/home"
mkdir -p "$home/docs/a" "$home/docs/b" "$home/.config/app" "$home/.secret" "$home/many"
touch "$home/docs/a/report.txt" "$home/docs/b/report.txt" "$home/.config/app/settings.ini" "$home/.secret/hidden-report.txt"
touch "$home/docs/tab	report.txt" "$home/docs/line
report.txt"
for i in $(seq 1 45); do touch "$home/many/bulk-$i.log"; done

# run HELPER ARGS...: the helper under a clean environment; prints its
# stdout, then `stderr=<first line>` and `exit=<status>`.
run() {
  local script="$1" out err status=0
  shift
  out="$(env -i PATH="$PATH" HOME="$home" XDG_CACHE_HOME="$TMP_ROOT/cache" bash "$script" "$@" 2>"$TMP_ROOT/err")" || status=$?
  err="$(head -n 1 "$TMP_ROOT/err")"
  printf '%s\nstderr=%s\nexit=%s\n' "$out" "$err" "$status"
}

# Paths of a query's output, one per line, with the home replaced.
paths() { awk -F'\t' -v home="$home" 'NF == 3 { sub("^" home, "~", $3); print $3 }'; }

failures=0
check() { # LABEL WANT GOT
  if [[ $2 == "$3" ]]; then return 0; fi
  failures=$((failures + 1))
  printf '  FAIL  %s\n        want %q\n        got  %q\n' "$1" "$2" "$3"
}

suite() {
  local script="$1" before=$failures got
  rm -rf -- "${TMP_ROOT:?}/cache"
  got="$(run "$script" query f report)"
  check "a name query lists both same-named files, and no name a line cannot hold" $'~/docs/a/report.txt\n~/docs/b/report.txt' "$(paths <<<"$got" | sort)"
  check "a name query leaves hidden files outside the hidden roots" 0 "$(grep -c 'hidden-report' <<<"$got" || true)"
  check "the index lives in the launcher's cache" yes "$([[ -s $TMP_ROOT/cache/vgs/launcher/f.idx ]] && echo yes || echo no)"
  check "the index holds one line per name and no tab or newline name" 0 "$(grep -c 'tab\|^report.txt.*line' "$TMP_ROOT/cache/vgs/launcher/f.idx" || true)"
  got="$(run "$script" query f settings)"
  check "hidden roots are searched" "~/.config/app/settings.ini" "$(paths <<<"$got")"
  got="$(run "$script" query f docs/a)"
  check "a slash matches against the whole path" "~/docs/a/report.txt" "$(paths <<<"$got")"
  got="$(run "$script" query f bulk)"
  check "a query shows at most 40 results" 40 "$(paths <<<"$got" | wc -l | tr -d ' ')"
  check "every result is mtime, mime and path" 40 "$(awk -F'\t' '$1 ~ /^[0-9]+$/ && $2 ~ /\// && $3 ~ /^\// { n++ } END { print n + 0 }' <<<"$got")"
  got="$(run "$script" query d docs)"
  check "a folder query lists folders as directories" $'inode/directory\t~/docs' "$(awk -F'\t' -v home="$home" 'NF == 3 { sub("^" home, "~", $3); print $2 "\t" $3 }' <<<"$got" | grep -x $'inode/directory\t~/docs')"
  mv -- "$home/docs/a/report.txt" "$home/docs/a/moved.txt"
  got="$(run "$script" query f report)"
  check "a file gone since the index was built is not listed" "~/docs/b/report.txt" "$(paths <<<"$got")"
  check "a vanished file is counted" "stderr=file-search: vanished=1" "$(grep '^stderr=' <<<"$got")"
  mv -- "$home/docs/a/moved.txt" "$home/docs/a/report.txt"
  got="$(run "$script" query f "")"
  check "an empty query prints nothing" $'\nstderr=\nexit=0' "$got"
  got="$(run "$script" refresh f)"
  check "a refresh rebuilds quietly" $'\nstderr=\nexit=0' "$got"
  exec 8>"$TMP_ROOT/cache/vgs/launcher/.f.lock"
  flock 8
  got="$(run "$script" refresh f)"
  check "a refresh that meets a running build leaves it" $'\nstderr=file-search: refresh=busy type=f\nexit=0' "$got"
  exec 8>&-
  got="$(env -i PATH="$TMP_ROOT/nobin" HOME="$home" /usr/bin/env bash "$script" query f report 2>&1; echo "exit=$?")"
  check "a missing helper is named" $'file-search: missing=fzf,stat,flock\nexit=3' "$got"
  got="$(run "$script" query x report)"
  check "an unknown type is a usage refusal" $'\nstderr=file-search: refused: usage\nexit=2' "$got"
  got="$(run "$script" apps "$home/nowhere")"
  check "open-with on a vanished path is refused" $'\nstderr=file-search: vanished='"$home"$'/nowhere\nexit=5' "$got"
  # gio translates its heading; under a German caller the default must
  # still lead, read from gio's C output.
  got="$(env -i PATH="$stubs:$PATH" HOME="$home" LC_ALL=de_DE.UTF-8 XDG_DATA_HOME="$TMP_ROOT/data" XDG_DATA_DIRS="$TMP_ROOT/none" bash "$script" apps "$home/docs/b/report.txt" 2>"$TMP_ROOT/err")"
  check "open-with names the default first under a translated locale" $'default\t'"$TMP_ROOT"$'/data/applications/b.desktop\nother\t'"$TMP_ROOT"$'/data/applications/a.desktop' "$got"
  rm -rf -- "${TMP_ROOT:?}/cache"
  mkdir -p "$TMP_ROOT/cache/vgs"
  touch "$TMP_ROOT/cache/vgs/launcher"
  got="$(run "$script" query f report)"
  check "an index that cannot be made is refused by its step" $'\nstderr=file-search: index=f error=mkdir\nexit=4' "$got"
  rm -f -- "${TMP_ROOT:?}/cache/vgs/launcher"
  [[ $failures -eq $before ]]
}

# A gio that answers in the caller's language, as the real one does, and
# an xdg-mime that names one type; two applications that open it.
stubs="$TMP_ROOT/stubs"
mkdir -p "$stubs" "$TMP_ROOT/data/applications"
printf '#!/bin/bash\nif [[ ${LC_ALL:-} == C ]]; then echo "Default application for \\"text/plain\\": b.desktop"; echo "Registered applications:"; else echo "Standardanwendung f\\u00fcr \\"text/plain\\": b.desktop"; echo "Registrierte Anwendungen:"; fi\nprintf "\\ta.desktop\\n\\tb.desktop\\n"\n' >"$stubs/gio"
printf '#!/bin/bash\necho text/plain\n' >"$stubs/xdg-mime"
chmod 755 "$stubs/gio" "$stubs/xdg-mime"
printf '[Desktop Entry]\nType=Application\nName=A\nExec=true\n' >"$TMP_ROOT/data/applications/a.desktop"
printf '[Desktop Entry]\nType=Application\nName=B\nExec=true\n' >"$TMP_ROOT/data/applications/b.desktop"
mkdir -p "$TMP_ROOT/nobin"
ln -s "$(command -v bash)" "$TMP_ROOT/nobin/bash"
ln -s "$(command -v env)" "$TMP_ROOT/nobin/env"
if ! suite "$helper"; then
  echo "test-launcher-file-search: failing=$failures"
  exit 1
fi

# One control per rule: a copy with that rule removed and the text around it
# kept. The suite must fail on each.
mkdir -p "$TMP_ROOT/controls"
python3 - "$helper" "$TMP_ROOT/controls" <<'CONTROLS'
import os, sys
source, out = sys.argv[1:]
text = open(source).read()
controls = [
    ("result limit", "((shown < limit)) || break", "true"),
    ("tab and newline names", 'index($0, "\\t") || index($0, "\\n") { next }', "0 { next }"),
    ("whole path on a slash", "[[ $text == */* ]] && nth=2", "true"),
    ("vanished files", 'if ! mtime=$(stat -c %Y -- "$path" 2>/dev/null); then', 'if ! mtime=$(stat -c %Y -- / 2>/dev/null); then'),
    ("busy refresh", "if ! flock -n 9; then", "if false; then"),
    ("missing helpers", 'command -v -- "$command" >/dev/null 2>&1 || missing+=("$command")', "true"),
    ("hidden roots", 'for root in "${hidden_roots[@]}"; do [[ -d $root ]] && roots+=("$root"); done', "true"),
    ("cache place", 'cache="${XDG_CACHE_HOME:-$HOME/.cache}/vgs/launcher"', 'cache="$HOME/.launcher-cache"'),
    ("gio read in C", 'listing=$(LC_ALL=C gio mime "$mime")', 'listing=$(gio mime "$mime")'),
]
for n, (label, needle, replacement) in enumerate(controls):
    assert text.count(needle) == 1, "control needle must occur once: " + label
    with open(os.path.join(out, "%02d.sh" % n), "w") as fh:
        fh.write(text.replace(needle, replacement))
    with open(os.path.join(out, "%02d.label" % n), "w") as fh:
        fh.write(label)
CONTROLS
passed=0
for copy in "$TMP_ROOT"/controls/*.sh; do
  label="$(<"${copy%.sh}.label")"
  saved=$failures
  if suite "$copy" >/dev/null 2>&1; then
    echo "  FAIL  control \"$label\": the suite passed on a helper without that rule"
    exit 1
  fi
  failures=$saved
  passed=$((passed + 1))
done
if [[ $passed -ne 9 ]]; then
  echo "test-launcher-file-search: controls=$passed want 9; the control table is broken"
  exit 1
fi
echo "test-launcher-file-search: ok controls=$passed"
