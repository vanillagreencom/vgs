#!/usr/bin/env bash
# Refuse the `hyprctl dispatch` forms below in a bin/ shell script other than
# bin/vshell-hyprctl-dispatch. That program checks the reply of every dispatch, so a call
# routed around it can lose a refused dispatch with no diagnostic. Selection is by resolved
# interpreter name: a bin/ file is a shell script when its shebang, after a leading `env`
# with its options and assignments is dropped, names a POSIX shell. Interpreter options
# after that name are ignored by construction, so no spelling needs its own arm. The Python
# helper modules resolve to python3 and stay outside this rule.
# Forms matched: the word `hyprctl`, then the word `dispatch` with no `|`, `;` or `&`
# between them; `hyprctl` with a `--batch` flag and `dispatch` anywhere after it on the
# command, past `;`; either form continued across lines by an unescaped trailing backslash,
# reported at the command's first line. A command name held in a variable or run through
# eval is not followed. Whole-line comments are skipped.
# Usage: scripts/check-hyprctl-dispatch.sh [ROOT], where ROOT defaults to this checkout.
#
# Output protocol: one `hyprctl-dispatch-unchecked bin/<name>:<line>` line on stderr per
# finding, then exit 1; `check-hyprctl-dispatch: ok (<N> shell scripts)` and exit 0 when
# none; exit 2 when bin/ cannot be listed or holds no shell script to scan.
set -euo pipefail

root="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
owner="vshell-hyprctl-dispatch"
# hyprctl, then its flags within the same command, then the dispatch word.
pattern='(^|[^[:alnum:]_-])hyprctl[[:space:]][^|;&]*dispatch([^[:alnum:]_]|$)'
# A batch string separates its commands with `;`, so a dispatch may follow another command.
batch_pattern='(^|[^[:alnum:]_-])hyprctl([[:space:]]+[^[:space:]]+)*[[:space:]]+--batch([[:space:]]|=).*dispatch([^[:alnum:]_]|$)'

# Resolve one shebang line to the interpreter's basename in REPLY. `env` runs the command
# named after its own options, its `-S` string and any VAR=value assignments, so those are
# dropped first. Returns nonzero when the line names no command.
shell_interpreter() {
  local line="$1" word
  local -a words=()
  [[ $line == '#!'* ]] || return 1
  IFS=' ' read -r -a words <<<"${line#\#!}" || true
  ((${#words[@]} > 0)) || return 1
  if [[ ${words[0]##*/} == env ]]; then
    words=("${words[@]:1}")
    while ((${#words[@]} > 0)); do
      word="${words[0]}"
      case "$word" in
        -S?*) words[0]="${word#-S}"; break ;;
        --split-string=?*) words[0]="${word#--split-string=}"; break ;;
        # Every other option, its separate argument included, and every assignment.
        -* | *=*) words=("${words[@]:1}") ;;
        *) break ;;
      esac
    done
    ((${#words[@]} > 0)) || return 1
  fi
  REPLY="${words[0]##*/}"
  [[ -n $REPLY ]]
}

listing="$(mktemp)"
trap 'rm -f -- "${listing:?}"' EXIT
if ! find "$root/bin" -maxdepth 1 -type f -print0 >"$listing"; then
  printf 'hyprctl-dispatch-listing-failed %s/bin\n' "$root" >&2
  exit 2
fi

scanned=0
status=0
while IFS= read -r -d '' file; do
  shebang=""
  IFS= read -r shebang <"$file" || true
  interpreter=""
  shell_interpreter "$shebang" && interpreter="$REPLY"
  case "$interpreter" in
    sh | bash | dash | ksh | zsh) ;;
    *) continue ;;
  esac
  scanned=$((scanned + 1))
  [[ ${file##*/} == "$owner" ]] && continue
  line_no=0
  command_text=""
  command_start=0
  while IFS= read -r line || [[ -n $line ]]; do
    line_no=$((line_no + 1))
    if [[ -z $command_text ]]; then
      [[ $line =~ ^[[:space:]]*# ]] && continue
      command_start=$line_no
    fi
    # An odd run of trailing backslashes escapes the newline, continuing the command.
    if [[ $line =~ (\\+)$ ]] && ((${#BASH_REMATCH[1]} % 2 == 1)); then
      command_text+="${line%\\} "
      continue
    fi
    command_text+="$line"
    if [[ $command_text =~ $pattern || $command_text =~ $batch_pattern ]]; then
      printf 'hyprctl-dispatch-unchecked bin/%s:%d\n' "${file##*/}" "$command_start" >&2
      status=1
    fi
    command_text=""
  done <"$file"
done <"$listing"

if [[ $scanned -eq 0 ]]; then
  printf 'hyprctl-dispatch-no-scripts %s/bin\n' "$root" >&2
  exit 2
fi
if [[ $status -ne 0 ]]; then
  printf 'Route each dispatch through bin/%s.\n' "$owner" >&2
  exit 1
fi
printf 'check-hyprctl-dispatch: ok (%d shell scripts)\n' "$scanned"
