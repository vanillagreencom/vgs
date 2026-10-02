#!/usr/bin/env bash
# The vgs.themes `browser-policy` floating TUI,
# shell/plugins/vgs.themes/tui/browser-policy.sh, the step the Settings
# page's Install browser theming button opens. Against a stand-in VGS tree
# whose bin/vgsh logs its argv and exits with a chosen status, it proves the
# script runs `vgsh theme browser-policy install` of the tree its library
# lies in, once, ends with its status, and refuses by key, running nothing,
# without the presenter and with an argument. Each run has an empty
# environment but PATH, a stand-in gum and a few host tools, so no run
# reaches sudo or the system policy.
#
# The controls at the end edit a copy of the script, one rule at a time,
# and require the suite to fail on each copy.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
script="$repo/shell/plugins/vgs.themes/tui/browser-policy.sh"
TMP_ROOT="$(mktemp -d)" || { echo "test-themes-browser-policy-tui: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-themes-browser-policy-tui: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-themes-browser-policy-tui: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

tools="$TMP_ROOT/tools"
tree="$TMP_ROOT/tree"
mkdir -p "$tools" "$tree/bin/lib"
for tool in bash cat mkdir; do ln -s -- "$(command -v "$tool")" "$tools/$tool"; done
# The library draws its header with gum; the stand-in prints its words.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*"\n' >"$tools/gum"
cp -- "$repo/bin/lib/tui.sh" "$tree/bin/lib/tui.sh"
# The stand-in vgsh: logs its argv, one call per line, and exits with the
# status in $TMP_ROOT/status.
cat >"$tree/bin/vgsh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP_ROOT/calls"
exit "\$(<"$TMP_ROOT/status")"
SH
chmod 755 "$tools/gum" "$tree/bin/vgsh"

# run SCRIPT STATUS LIB ARGS...: SCRIPT with the stand-in exiting STATUS and
# VGS_TUI_LIB set to LIB, "" for none; the exit status in $status, stderr's
# first line in $first, the stand-in's calls in $calls.
run() {
  local file="$1" code="$2" lib="$3"
  shift 3
  printf '%s\n' "$code" >"$TMP_ROOT/status"
  : >"$TMP_ROOT/calls"
  local environment=(PATH="$tools" HOME="$TMP_ROOT")
  [[ -n $lib ]] && environment+=(VGS_TUI_LIB="$lib")
  status=0
  env -i "${environment[@]}" bash "$file" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" </dev/null || status=$?
  first="$(head -n 1 -- "$TMP_ROOT/err")"
  calls="$(<"$TMP_ROOT/calls")"
}

# rows: label | the stand-in's status | lib (tree or none) | argument |
# want status | want first stderr line | want calls.
ROWS=(
  "the install runs once|0|tree||0||theme browser-policy install"
  "a failed install ends with its status|3|tree||3||theme browser-policy install"
  "no presenter refuses|0|none||2|themes: refused: tui=missing|"
  "an argument refuses|0|tree|now|2|This setup request is invalid. Open Themes and try again.|"
)

verify() { # SCRIPT
  local file="$1" row label code lib arg want_status want_first want_calls red=0
  for row in "${ROWS[@]}"; do
    IFS='|' read -r label code lib arg want_status want_first want_calls <<<"$row"
    local libpath=""
    [[ $lib == tree ]] && libpath="$tree/bin/lib/tui.sh"
    if [[ -n $arg ]]; then run "$file" "$code" "$libpath" "$arg"; else run "$file" "$code" "$libpath"; fi
    if [[ $status == "$want_status" && $first == "$want_first" && $calls == "$want_calls" ]]; then
      [[ ${2:-} == quiet ]] || ok "$label"
    else
      red=1
      [[ ${2:-} == quiet ]] || fail "$label: got status=$status first=[$first] calls=[$calls], want status=$want_status first=[$want_first] calls=[$want_calls]"
    fi
  done
  return "$red"
}

verify "$script" || true

# Controls: [label, needle, replacement], each on a copy of the script.
CONTROLS=(
  "the presenter check|[[ -z \$lib ]]|[[ -n \$lib \&\& -z \$lib ]]"
  "the argument check|if [[ \$# -gt 0 ]]; then|if false; then"
  "the install's status|\"\$tree/bin/vgsh\" theme browser-policy install|\"\$tree/bin/vgsh\" theme browser-policy install || true"
)
for control in "${CONTROLS[@]}"; do
  IFS='|' read -r label needle replacement <<<"$control"
  copy="$TMP_ROOT/copy.sh"
  if ! python3 - "$script" "$copy" "$needle" "$replacement" <<'PY'
import sys
src, dst, needle, replacement = sys.argv[1:]
text = open(src).read()
if text.count(needle) != 1:
    sys.exit("needle occurs %d times" % text.count(needle))
open(dst, "w").write(text.replace(needle, replacement.replace("\\&", "&"), 1))
PY
  then
    fail "control $label: the text to replace does not occur once"
    continue
  fi
  if verify "$copy" quiet; then fail "control $label: the suite passed on a copy without it"; else ok "control: the suite fails without $label"; fi
done

if [[ $failures -gt 0 ]]; then
  printf 'test-themes-browser-policy-tui: failing=%d\n' "$failures"
  exit 1
fi
echo "test-themes-browser-policy-tui: ok"
