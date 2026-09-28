# The assertion library the bin/vgsh suites, scripts/test-vgsh*.sh, source:
# the scratch directory, the child environment, the row helpers, the theme
# tree fixture and the git source fixture. It sets `set -euo pipefail`,
# `repo`, `tmp` (removed on exit), `rt_empty`, `node_bin`, `base_path`,
# `base_env`, `git_env` and `failures`.
set -euo pipefail

repo="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
tmp="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${tmp:?}"' EXIT
rt_empty="$tmp/rt-empty"; mkdir -p "$rt_empty"

# node on PATH may be a version-manager shim that reads the developer's own
# configuration; the rows put the binary it resolves to ahead of it.
if ! node_bin="$(node -e 'process.stdout.write(process.execPath)')"; then
  echo "$(basename -- "$0" .sh): status=not-measured missing=node"
  exit 77
fi
# $tmp first, so a suite's stub qs there answers every call.
base_path="$tmp:$(dirname -- "$node_bin"):$PATH"
base_env=(env -i PATH="$base_path" HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$tmp")

failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# inst NAME CONFIG_HOME RUNTIME_DIR WANT_EXIT WANT_LAST_STDOUT WANT_FIRST_STDERR ARGS...
# Stdout lands in $tmp/out for rows that read more than its last line;
# WANT_LAST_STDOUT is $any_out for a row whose checks after it read that.
# INST_BIN names the vgsh under test; the mutation control runs its copy.
# INST_PATH replaces the rows' PATH. Stdin is /dev/null, so no row reads
# the terminal the suite runs on; on_terminal hands vgsh one.
inst() {
  local name="$1" cfg="$2" rt="$3" want_exit="$4" want_out="$5" want_err="$6" out err status
  shift 6
  set +e
  out="$("${base_env[@]}" PATH="${INST_PATH:-$base_path}" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt" STUB_ARGS="$tmp/args" STUB_REPLY="${INST_REPLY:-ok}" "${INST_BIN:-$repo/bin/vgsh}" "$@" 2>"$tmp/err" </dev/null)"
  status=$?
  set -e
  printf '%s\n' "$out" >"$tmp/out"
  err=""
  [[ -s $tmp/err ]] && IFS= read -r err <"$tmp/err"
  local last="${out##*$'\n'}"
  [[ $want_out == "$any_out" ]] && want_out="$last"
  if [[ $status == "$want_exit" && $last == "$want_out" && $err == "$want_err" ]]; then ok "$name"; else fail "$name: exit=$status want=$want_exit last=[$last] want=[$want_out] stderr=[$err] want=[$want_err]"; fi
}
any_out=$'\x01any'
check() { # NAME CMD...
  local name="$1"; shift
  if "$@"; then ok "$name"; else fail "$name"; fi
}
json_is() { # FILE PYTHON_EXPR_ON_d: the expression must be true
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"
}
has_line() { grep -qxF -- "$1" "$tmp/out"; }
has_prefix() { grep -q "^$1" "$tmp/out"; }
# on_terminal ANSWER ARGS...: vgsh against $cfg on a pseudo-terminal that
# script(1) opens, with ANSWER typed on it. Stdout and stderr together land
# in $tmp/out and the exit status in $term_status. INST_BIN names the vgsh
# under test, as for inst.
on_terminal() {
  local answer="$1"
  shift
  command -v script >/dev/null || { echo "$(basename -- "$0" .sh): status=not-measured missing=script"; exit 77; }
  term_status=0
  "${base_env[@]}" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt_empty" script -qec "$(printf '%q ' "${INST_BIN:-$repo/bin/vgsh}" "$@")" /dev/null <<<"$answer" >"$tmp/out" 2>&1 || term_status=$?
}

# The theme commands read the shipped packages and targets beside bin/, so
# theme rows run a copy of the tree they load, $tree, whose themes/ a row
# adds packages and targets to; production code has no knob for its themes
# directory. The copy holds every shipped package and only the shipped
# targets the suite names, so a result's target list is the suite's own and
# a target added elsewhere changes no row. A target is detected by its
# commands on PATH, so the rows run under $theme_path, holding only the
# tools bin/vgsh and its judge call, and a row that wants a target detected
# adds $stubs to it. XDG_STATE_HOME is unset, so the state directory is the
# $HOME fallback, $state.
theme_tree() { # SHIPPED_TARGET...
  tree="$tmp/tree"; mkdir -p "$tree/scripts" "$tree/shell/Commons" "$tree/shell/Core" "$tree/config" "$tree/themes/targets"
  cp -R -- "$repo/bin" "$tree/"
  local entry target
  for entry in "$repo"/themes/*; do
    [[ ${entry##*/} == targets ]] || cp -R -- "$entry" "$tree/themes/"
  done
  for target in "$@"; do cp -R -- "$repo/themes/targets/$target" "$tree/themes/targets/"; done
  cp -- "$repo/config/shell.json" "$tree/config/"
  cp -- "$repo/shell/Core/PluginLogic.js" "$tree/shell/Core/"
  cp -- "$repo/scripts/qml-library.js" "$tree/scripts/"
  cp -- "$repo/shell/Commons/ThemeLogic.js" "$repo/shell/Commons/Tokens.js" "$tree/shell/Commons/"
  theme_path="$tmp/theme-path"; stubs="$tmp/stubs"; mkdir -p "$theme_path" "$stubs"
  local tool tool_bin
  for tool in bash readlink dirname mkdir flock awk git mktemp mv rm; do
    tool_bin="$(command -v "$tool")" || { echo "$(basename -- "$0" .sh): status=not-measured missing=$tool"; exit 77; }
    ln -s -- "$tool_bin" "$theme_path/$tool"
  done
  ln -s -- "$node_bin" "$theme_path/node"
  state="$tmp/home/.local/state/vgs"
}
tinst() { INST_BIN="${THEME_BIN:-$tree/bin/vgsh}" INST_PATH="${THEME_PATH:-$theme_path}" inst "$@"; }
theme_pkg() { # DIR THEME_JSON_TEXT [TERMINAL_JSON_TEXT]
  mkdir -p "$1"
  printf '%s' "$2" >"$1/theme.json"
  [[ -z ${3:-} ]] || printf '%s' "$3" >"$1/terminal.json"
}
slots_json() { # COLOUR: a terminal.json whose sixteen slots are COLOUR
  local i out=""
  for i in $(seq 0 15); do out+="${out:+, }\"color$i\": \"$1\""; done
  printf '{ "schemaVersion": 1, "slots": { %s } }\n' "$out"
}
target_dir() { # NAME TARGET_JSON TEMPLATE_TEXT
  mkdir -p "$tree/themes/targets/$1"
  printf '%s\n' "$2" >"$tree/themes/targets/$1/target.json"
  printf '%s' "$3" >"$tree/themes/targets/$1/$1.conf"
}
target_json() { # NAME ENCODER DETECT_JSON WIRING_LINE CREATE [RELOAD_JSON]
  printf '{ "app": "%s", "runsCode": false, "encoder": "%s", "files": [{ "template": "%s.conf", "destination": "%s.conf" }], "detect": %s, "wiring": { "file": "%s/%s.conf", "line": "%s", "create": %s }, "reload": %s }' "$1" "$2" "$1" "$1" "$3" "$1" "$1" "$4" "$5" "${6:-null}"
}

# A must-fail control on a copy of the tree whose FILE, relative to the
# tree, has NEEDLE, which must occur once, replaced by REPLACEMENT;
# THEME_BIN then names the copy's vgsh until the caller unsets it.
tree_control() { # NAME FILE NEEDLE REPLACEMENT
  local copy="$tmp/tree-$1"
  cp -R -- "$tree" "$copy"
  check "the $1 control's text occurs once in $2" test "$(grep -c -F -- "$3" "$repo/$2")" == 1
  python3 -c 'import sys; p, a, b = sys.argv[1:]; s = open(p).read(); open(p, "w").write(s.replace(a, b))' "$copy/$2" "$3" "$4"
  check "the $1 mutant differs from $2" test "$(cmp -s "$repo/$2" "$copy/$2"; echo $?)" == 1
  THEME_BIN="$copy/bin/vgsh"
}
judge_control() { tree_control "$1" bin/vgsh-theme-judge "$2" "$3"; } # NAME NEEDLE REPLACEMENT

# Theme sources as local git repositories. Every git call here and in vgsh
# reads only the fixture home's own git configuration, never the
# developer's, so a row meets no hook or setting it did not plant itself.
mkdir -p "$tmp/home"
git_env=(env -i PATH="$PATH" HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
  GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid)
g() { "${git_env[@]}" git -c init.defaultBranch=main "$@"; }
# A theme source: a work tree at $tmp/tsrc/NAME and its bare repository at
# $tmp/tsrc/NAME.git, holding one commit.
theme_source() { # NAME THEME_JSON_TEXT [TERMINAL_JSON_TEXT]: an empty THEME_JSON_TEXT writes none
  local work="$tmp/tsrc/$1"
  mkdir -p "$work"
  printf 'fixture\n' >"$work/README"
  [[ -z $2 ]] || theme_pkg "$work" "$2" "${3:-}"
  g init -q "$work"
  g -C "$work" add -A
  g -C "$work" commit -q -m init
  g init -q --bare "$work.git"
  g -C "$work" push -q "$work.git" main
}
theme_commit() { # NAME FILE TEXT: commit TEXT as FILE in source NAME and push it
  printf '%s' "$3" >"$tmp/tsrc/$1/$2"
  g -C "$tmp/tsrc/$1" add -A
  g -C "$tmp/tsrc/$1" commit -q -m change
  g -C "$tmp/tsrc/$1" push -q "$tmp/tsrc/$1.git" main
}
doc() { printf '{ "schemaVersion": 1, "name": "%s", "tokens": %s }' "$1" "${2:-"{}"}"; } # NAME [TOKENS_JSON]

rows_done() { # SUITE
  if [[ $failures -gt 0 ]]; then echo "$1: failed=$failures"; exit 1; fi
  echo "$1: ok"
}
