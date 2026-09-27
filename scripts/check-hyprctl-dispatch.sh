#!/usr/bin/env bash
# Refuse the `hyprctl dispatch` forms below in a bin/ shell script other than
# bin/vshell-hyprctl-dispatch. That program checks the reply of every dispatch, so a call
# routed around it can lose a refused dispatch with no diagnostic. Selection fails closed:
# every bin/ file whose first line starts with `#!` is scanned unless that line names
# python, which excludes the Python helper modules. No interpreter name is resolved, so no
# shebang spelling can be read wrongly and skipped; a file with no `#!` first line is not
# a program this rule covers.
# Forms matched: the word `hyprctl`, then the word `dispatch` with no `|`, `;` or `&`
# between them; `hyprctl` with a `--batch` flag and `dispatch` anywhere after it on the
# command, past `;`; either form continued across lines by an unescaped trailing backslash,
# reported at the command's first line. A command name held in a variable or run through
# eval is not followed. Whole-line comments are skipped.
# Usage: scripts/check-hyprctl-dispatch.sh [ROOT], where ROOT defaults to this checkout.
#
# Output protocol: one `hyprctl-dispatch-unchecked bin/<name>:<line>` line on stderr per
# finding, then exit 1; `check-hyprctl-dispatch: ok (<N> scanned files)` and exit 0 when
# none; exit 2 when bin/ cannot be listed or holds no file to scan.
set -euo pipefail

root="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
owner="vshell-hyprctl-dispatch"
# The command word, bounded on both sides. The leading class already admits the quote or
# the path separator a quoted or absolute command word puts there; the trailing class is
# what a closing quote, a command substitution or both need. Neither side admits a letter,
# a digit, `_` or `-`, so myhyprctl and hyprctl-foo stay out. A wider trailing class would
# only add false refusals, which are fail-closed, so no row pins its width.
command_word='(^|[^[:alnum:]_-])hyprctl'"['\"\`)]*"
# The command word, then its flags within the same command, then the dispatch word.
pattern="$command_word"'[[:space:]][^|;&]*dispatch([^[:alnum:]_]|$)'
# A batch string separates its commands with `;`, so a dispatch may follow another command.
batch_pattern="$command_word"'([[:space:]]+[^[:space:]]+)*[[:space:]]+--batch([[:space:]]|=).*dispatch([^[:alnum:]_]|$)'

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
  case "$shebang" in
    '#!'*python*) continue ;;
    '#!'*) ;;
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
printf 'check-hyprctl-dispatch: ok (%d scanned files)\n' "$scanned"
