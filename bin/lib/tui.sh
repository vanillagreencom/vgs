# shellcheck shell=bash
# bin/lib/tui.sh: the floating TUI presentation library. A script that
# bin/vgsh-tui runs sources it as `source "$VGS_TUI_LIB"`; bin/vgsh-tui
# sources it for its own colours. It defines functions and sets no shell
# option. Colours are the #rrggbb values `vgsh-tui present` exports from
# gum.env (VGS_TUI_ACCENT, VGS_TUI_SUCCESS, VGS_TUI_WARNING, VGS_TUI_DANGER),
# each with an ANSI fallback when absent. docs/architecture/tui.md.
#
# Every refusal prints one keyed line on stderr first:
# `vgs-tui: refused: <key>=<value>`. A function that refuses returns 2 for a
# missing terminal or a bad argument, 75 for a held lock, 1 otherwise.
#
#   vgs_tui_header TITLE [LINE...]   a bordered box: TITLE, then each LINE
#   vgs_tui_step TEXT                a bold accent line after a blank line
#   vgs_tui_warn TEXT                a warning line on stderr
#   vgs_tui_error TEXT               an error line on stderr
#   vgs_tui_confirm QUESTION [GUM_FLAG...]
#                                    gum confirm; yes under VGS_TUI_UNATTENDED=1
#   vgs_tui_choose|input|filter [GUM_ARG...]
#                                    gum choose, input or filter
#   vgs_tui_sudo_session start|end   one sudo authorization kept alive for this script,
#                                    joined by a nested run's session
#   vgs_tui_lock NAME                hold $XDG_RUNTIME_DIR/vgs-tui-NAME.lock until exit
#   vgs_tui_log FILE [ARG...]        run this script again under script(1) into FILE
#   vgs_tui_reboot_check             print why a reboot is needed; 1 when none is

# Character classes spelled out: a range such as [a-z] follows the collation
# of the user's locale, which the script under the presentation keeps.
_vgs_tui_hex='[0123456789abcdefABCDEF]'
_vgs_tui_lower='[abcdefghijklmnopqrstuvwxyz0123456789]'

# The SGR escape that selects colour HEX (#rrggbb) as the foreground, or the
# ANSI colour FALLBACK (30-37) when HEX is not one.
vgs_tui_sgr() { # HEX FALLBACK
  local hex="$1"
  if [[ $hex =~ ^#($_vgs_tui_hex$_vgs_tui_hex)($_vgs_tui_hex$_vgs_tui_hex)($_vgs_tui_hex$_vgs_tui_hex)$ ]]; then
    printf '\033[38;2;%d;%d;%dm' "0x${BASH_REMATCH[1]}" "0x${BASH_REMATCH[2]}" "0x${BASH_REMATCH[3]}"
  else
    printf '\033[%sm' "$2"
  fi
}

_vgs_tui_refuse() { # STATUS FIRST_LINE [ENGLISH...]
  local status="$1"
  printf 'vgs-tui: refused: %s\n' "$2" >&2
  shift 2
  [[ $# -gt 0 ]] && printf '%s\n' "$@" >&2
  return "$status"
}

# gum draws on the controlling terminal and reads the keyboard there, even
# when stdin carries a list and stdout is captured, so the terminal is
# /dev/tty. The device node exists without one, so only opening it tells.
_vgs_tui_terminal() { # KEY
  : 2>/dev/null <>/dev/tty || _vgs_tui_refuse 2 "$1=no-terminal" "run this in a terminal"
}

vgs_tui_header() { # TITLE [LINE...]
  gum style --border normal --padding "1 2" -- "$@"
}

vgs_tui_step() { # TEXT
  printf '\n%s\033[1m%s\033[0m\n' "$(vgs_tui_sgr "${VGS_TUI_ACCENT:-}" 32)" "$*"
}

vgs_tui_warn() { # TEXT
  printf '%s%s\033[0m\n' "$(vgs_tui_sgr "${VGS_TUI_WARNING:-}" 33)" "$*" >&2
}

vgs_tui_error() { # TEXT
  printf '%s%s\033[0m\n' "$(vgs_tui_sgr "${VGS_TUI_DANGER:-}" 31)" "$*" >&2
}

# Answers yes without asking under VGS_TUI_UNATTENDED=1 and prints the
# question with that answer. Otherwise gum asks; its status is the answer:
# 0 yes, 1 no, 130 cancelled.
vgs_tui_confirm() { # QUESTION [GUM_FLAG...]
  local question="$1"
  shift
  if [[ ${VGS_TUI_UNATTENDED:-} == 1 ]]; then
    printf '%s yes (unattended)\n' "$question"
    return 0
  fi
  _vgs_tui_terminal confirm || return
  gum confirm "$@" -- "$question"
}

vgs_tui_choose() { _vgs_tui_terminal choose || return; gum choose "$@"; }
vgs_tui_input() { _vgs_tui_terminal input || return; gum input "$@"; }
vgs_tui_filter() { _vgs_tui_terminal filter || return; gum filter "$@"; }

_vgs_tui_keepalive_pid=""
_vgs_tui_lock_fd=""
_vgs_tui_sudo_joined=""

# start drops any cached sudo credential, asks for the password once through
# `sudo /usr/bin/true` (sudo -v would prompt under a passwordless rule too)
# and keeps the credential fresh with `sudo -n /usr/bin/true` every 60 s
# while this script's process lives. It exports VGS_TUI_SUDO_SESSION, this
# process's pid, to every command the script runs. From then on EXIT, HUP,
# INT and TERM end the session: those traps replace any the caller set
# before. end stops the keepalive, clears those traps, drops the credential
# and unexports the pid.
#
# A start in a process whose VGS_TUI_SUDO_SESSION names a live process joins
# that session: it drops nothing, starts no keepalive and sets no trap, and
# its `sudo /usr/bin/true` answers from the owner's credential, asking only
# when it lapsed; its end drops nothing. The Updates pipeline runs
# `vgsh pkg run upgrade` inside its own session, and that run's end would
# otherwise revoke the credential the pipeline's later steps use. A pid that
# names no live process, as a command a step started that outlives the
# owner carries, starts a session of its own.
vgs_tui_sudo_session() { # start|end
  case "${1:-}" in
    start)
      local outer="${VGS_TUI_SUDO_SESSION:-}"
      if [[ $outer =~ ^[123456789][0123456789]*$ ]] && kill -0 "$outer" 2>/dev/null; then
        sudo /usr/bin/true || _vgs_tui_refuse 1 "sudo=not-authorized" || return
        _vgs_tui_sudo_joined=1
        return 0
      fi
      sudo -k || _vgs_tui_refuse 1 "sudo=reset-failed" || return
      sudo /usr/bin/true || _vgs_tui_refuse 1 "sudo=not-authorized" || return
      local owner=$$
      (
        [[ -z $_vgs_tui_lock_fd ]] || exec {_vgs_tui_lock_fd}>&-
        sleeper=""
        trap '[[ -z $sleeper ]] || kill "$sleeper" 2>/dev/null; exit 0' TERM
        while :; do
          sleep 60 &
          sleeper=$!
          wait "$sleeper"
          kill -0 "$owner" 2>/dev/null || exit 0
          sudo -n /usr/bin/true 2>/dev/null || exit 0
        done
      ) </dev/null &
      _vgs_tui_keepalive_pid=$!
      export VGS_TUI_SUDO_SESSION=$$
      trap 'vgs_tui_sudo_session end' EXIT
      trap 'exit 129' HUP
      trap 'exit 130' INT
      trap 'exit 143' TERM
      ;;
    end)
      if [[ -n $_vgs_tui_sudo_joined ]]; then
        _vgs_tui_sudo_joined=""
        return 0
      fi
      unset VGS_TUI_SUDO_SESSION
      # The keepalive may have exited already, when sudo -n refused.
      if [[ -n $_vgs_tui_keepalive_pid ]]; then
        kill "$_vgs_tui_keepalive_pid" 2>/dev/null || :
        wait "$_vgs_tui_keepalive_pid" 2>/dev/null || :
        _vgs_tui_keepalive_pid=""
      fi
      trap - EXIT HUP INT TERM
      sudo -k || _vgs_tui_refuse 1 "sudo=revoke-failed" "the sudo credential may still be cached; run sudo -k"
      ;;
    *) _vgs_tui_refuse 2 "sudo-session=${1:-missing}" ;;
  esac
}

# NAME is lower case letters, digits and dashes. The lock is held on a
# descriptor until this process exits; a second holder is refused busy.
# Call vgs_tui_log first: its script(1) run would inherit the descriptor
# and hold the lock against the script it runs.
vgs_tui_lock() { # NAME
  local name="${1:-}" path status=0
  [[ $name =~ ^$_vgs_tui_lower($_vgs_tui_lower|-)*$ ]] || _vgs_tui_refuse 2 "lock-name=$name" || return
  path="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vgs-tui-$name.lock"
  { exec {_vgs_tui_lock_fd}>>"$path"; } 2>/dev/null || _vgs_tui_refuse 1 "lock=$name reason=open path=$path" || return
  flock -n -E 75 "$_vgs_tui_lock_fd" || status=$?
  case "$status" in
    0) ;;
    75) _vgs_tui_refuse 75 "lock=$name reason=busy" "another run holds $path" ;;
    *) _vgs_tui_refuse 1 "lock=$name reason=flock-failed path=$path" ;;
  esac
}

# Runs this script again, with ARGs, under script(1) logging to FILE, so the
# terminal shows the run and FILE keeps a copy, and exits with that run's
# status; inside the run it returns at once. script(1) hands the command
# line to $SHELL, so SHELL is bash there, which reads the %q quoting.
vgs_tui_log() { # FILE [ARG...]
  [[ ${VGS_TUI_LOGGED:-} == 1 ]] && return 0
  local file="${1:-}" cmd
  [[ -n $file ]] || _vgs_tui_refuse 2 "log=missing" || return
  shift
  cmd="$(printf '%q ' "$BASH" "$0" "$@")"
  exec env VGS_TUI_LOGGED=1 SHELL="$BASH" script -qef --log-out "$file" -c "$cmd"
}

# Prints one `reboot=<reason>` line per reason and returns 0 when a reboot
# is needed, 1 when none is: `kernel` when the running kernel's module
# directory is gone, as after a kernel upgrade; `hyprland` when a Hyprland
# of this user runs a binary that was replaced.
vgs_tui_reboot_check() {
  local release pids pid exe status=0 reasons=()
  release="$(uname -r)" || _vgs_tui_refuse 1 "reboot-check=uname" || return
  [[ -d /lib/modules/$release ]] || reasons+=(kernel)
  # pgrep exits 1 when no process matches, and above 1 when it failed.
  pids="$(pgrep -x -u "$(id -u)" Hyprland)" || status=$?
  [[ $status -le 1 ]] || _vgs_tui_refuse 1 "reboot-check=pgrep exit=$status" || return
  for pid in $pids; do
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null)" || continue
    if [[ $exe == *' (deleted)' ]]; then reasons+=(hyprland); break; fi
  done
  [[ ${#reasons[@]} -gt 0 ]] || return 1
  printf 'reboot=%s\n' "${reasons[@]}"
}
