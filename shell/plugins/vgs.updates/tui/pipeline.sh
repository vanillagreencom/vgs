# shellcheck shell=bash
# tui/pipeline.sh: the Updates pipeline, sourced by tui/update.sh, which
# runs every source, and tui/update-source.sh, which runs one. Both hold one
# lock and one log and run the same steps in the same order; a source the
# run leaves out is skipped where its step would stand. bin/vgsh-tui runs
# both from a private copy of the plugin's snapshot, so bin/facts is beside
# this file's directory, and the VGS tree is the one VGS_TUI_LIB lies in.
# The order is omarchy-update's (basecamp/omarchy e332dc97):
#
#   1. the log, script(1) into $XDG_STATE_HOME/vgs/updates/update.log, then
#      the lock vgs-tui-updates; the run writes a file of its own that
#      becomes update.log once it holds the lock, so a second run refused
#      busy never truncates the log of the run it found
#   2. a warning when / has less than 10 GiB free
#   3. the plan box, then one question unless -y
#   4. one sudo session, when the package layer's elevation command is
#      sudo and a snapshot or the system step needs root. That command is
#      the one `vgsh pkg plan upgrade <primary>` names, from shell.json's
#      `packages.elevate`, else the first of sudo, doas and run0 on PATH;
#      doas and run0 ask as their own rules say, as bin/lib/pkg-run.sh does
#   5. a snapshot through snapper or timeshift behind that command, before
#      any step that replaces a package: the system's, the AUR's or the
#      vgs-git rebuild. None is taken when the plugin's `snapshot` setting
#      is off, when neither tool is on PATH or when no elevation command
#      resolves, and the plan box says which; a failed snapshot warns and
#      the update goes on
#   6. VGS itself: `vgsh self update` for a checkout or a curl install
#   7. the system: `vgsh pkg run upgrade --manager <primary>`, which joins
#      the session
#   8. Flatpak and mise: `vgsh pkg run upgrade --manager flatpak|mise`
#   9. each plugin, then each theme, behind its upstream:
#      `vgsh plugin|theme update <id>`, which shows its diff and asks
#      [y/N]; `--yes` only when the `trustPluginUpdates` setting is on
#  10. the end of the sudo session, which drops the credential
#  11. the AUR, last, so no PKGBUILD runs under the update's credential:
#      the `aurCommand` setting's words, else `vgsh pkg run upgrade
#      --manager aur`, then `<helper> -S vgs-git` when VGS is that package
#      and behind, since an AUR helper rebuilds a -git package only when
#      its recipe's version changes. The helper asks sudo itself, so the
#      phase runs under tui.sh's sudo guard: the credential it caches is
#      dropped when the phase ends, fails or is interrupted
#  12. pacman's orphaned packages, removed only on a yes, default no, after
#      a system or AUR upgrade
#  13. a shell restart when a package step or the rebuild replaced the VGS
#      package
#  14. a reboot question when the kernel or the running Hyprland was
#      replaced (tui.sh's vgs_tui_reboot_check)
#
# The package steps are the package-manager table's own plans, read with
# `vgsh pkg plan` and run with `vgsh pkg run`: they take no -y, so each
# manager asks its own questions in this terminal. -y answers only the
# pipeline's own start question; the orphan and reboot questions are then
# reported instead of asked. A plugin or theme update that fails or is
# declined warns and the run goes on. Any other failing step ends the run:
# the ERR trap prints `updates: failed exit=<n> log=<file>` and how to
# recover, and the session's or the guard's EXIT trap drops the credential.
#
# Every refusal prints `updates: refused: <key>=<value>` first. A bad
# invocation exits 2; a held lock exits 75.

# The ERR trap needs errtrace, so the file sets the mode its steps rely on
# whichever entry script sources it.
set -Eeuo pipefail
# Character classes spelled out: the user's locale collates a range.
_updates_digits='^[0123456789]+$'
_updates_usage="usage: update.sh [-y] | update-source.sh <source> [-y]"

_updates_diagnostic() { # RAW_LINE
  local dir
  dir="$(updates_state_dir)"
  mkdir -p -- "$dir"
  printf '%s\n' "$1" >>"$dir/diagnostics.log"
}

_updates_refuse() { # STATUS FIRST_LINE [ENGLISH...]
  local status="$1"
  if [[ -z ${VGS_TUI_LIB:-} ]]; then
    printf 'updates: refused: %s\n' "$2" >&2
  else
    _updates_diagnostic "updates: refused: $2"
    case "$2" in
      log=absent*) printf 'No update has run yet. There is no log to show.\n' >&2 ;;
      pager=missing) printf 'The log reader is unavailable. Open Updates to try again.\n' >&2 ;;
      source=missing) printf 'No update source was selected. Open Updates and choose a source.\n' >&2 ;;
      *reason=absent) printf 'This update source is not installed. Choose another source.\n' >&2 ;;
      *reason=no-plan) printf 'VGS cannot update this source. Choose another source.\n' >&2 ;;
      *) printf 'This update request is invalid. Open Updates and try again.\n' >&2 ;;
    esac
  fi
  exit "$status"
}

# The recovery message, printed once by the pipeline's own process: with
# errtrace a failing command inside a substitution runs the trap there too.
_updates_failed() { # STATUS
  [[ $BASHPID == "${_updates_pid:-}" ]] || return 0
  printf '\n' >&2
  _updates_diagnostic "updates: failed exit=$1 log=$_updates_log"
  vgs_tui_error "The update stopped. Read the output above and try again from Updates."
  vgs_tui_error "Select Open last log in Updates to read this run's output."
}

# Runs ARGV from $HOME after a step line, as vgsh pkg run runs its steps,
# so a project's configuration in the caller's directory changes nothing.
_updates_run() { # LABEL ARGV...
  vgs_tui_step "$1"
  shift
  (cd -- "$HOME" && "$@")
}

# The directory a run writes its log in, and the last run's log in it,
# which tui/log.sh shows.
updates_state_dir() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/vgs/updates"
}
updates_log_file() {
  printf '%s\n' "$(updates_state_dir)/update.log"
}

# bin/facts VERB [SOURCE] on the answer on stdin.
_updates_facts() {
  "$_updates_facts_bin" "$_updates_loader" "$@"
}

# `vgsh pkg plan upgrade ID`: sets _updates_plan_text, the steps joined by
# `; `, and _updates_plan_elevator, the elevation command the steps run
# behind, empty when they need none or none resolves; or returns 1 with the
# refusal's first line in _updates_plan_text. A refusal that leaves no
# elevator, the elevator's or the plan's own, is in
# _updates_plan_elevator_refused.
_updates_plan() { # ID
  local out facts key value
  _updates_plan_text=""
  _updates_plan_elevator=""
  _updates_plan_elevator_refused=""
  if ! out="$("$_updates_vgsh" pkg plan upgrade "$1" 2>&1)"; then
    _updates_plan_text="${out%%$'\n'*}"
    _updates_plan_elevator_refused="$_updates_plan_text"
    return 1
  fi
  facts="$(_updates_facts plan <<<"$out")"
  while read -r key value; do
    case "$key" in
      elevator) _updates_plan_elevator="$value" ;;
      elevator-refused) _updates_plan_elevator_refused="$value" ;;
      step) _updates_plan_text+="${_updates_plan_text:+; }$value" ;;
    esac
  done <<<"$facts"
}

# The snapshot tool on PATH: snapper, else timeshift; 1 when neither is.
_updates_snapshot_tool() {
  if command -v snapper >/dev/null; then echo snapper
  elif command -v timeshift >/dev/null; then echo timeshift
  else return 1
  fi
}

# One snapshot per snapper configuration, or one timeshift snapshot, each
# command behind ELEVATOR. A tool with nothing configured takes none and
# says so: a quiet success would read as a snapshot the next update could
# roll back to.
_updates_snapshot() { # snapper|timeshift ELEVATOR
  local tool="$1" elevator="$2" csv config configs=() first=1
  case "$tool" in
    snapper)
      csv="$("$elevator" snapper --csvout list-configs)" || return
      while IFS=, read -r config _; do
        if [[ $first == 1 ]]; then first=0; continue; fi
        [[ -z $config ]] || configs+=("$config")
      done <<<"$csv"
      if [[ ${#configs[@]} -eq 0 ]]; then
        vgs_tui_warn "snapper has no configuration, so no snapshot was taken."
        return 1
      fi
      vgs_tui_step "Taking a snapshot"
      for config in "${configs[@]}"; do
        "$elevator" snapper -c "$config" create -c number -d "VGS update" || return
        "$elevator" snapper -c "$config" cleanup number || return
      done
      ;;
    timeshift)
      if [[ ! -f /etc/timeshift/timeshift.json ]]; then
        vgs_tui_warn "timeshift is not set up, so no snapshot was taken."
        return 1
      fi
      vgs_tui_step "Taking a snapshot"
      "$elevator" timeshift --create --comments "VGS update" --scripted || return
      ;;
    *) _updates_diagnostic "updates: snapshot-tool=$tool"; vgs_tui_error "The snapshot tool is not supported."; return 1 ;;
  esac
}

# The version of the package that owns the VGS tree, or nothing when no
# package owns it, as for a checkout, a curl install or a Nix tree, whose
# owner query refuses.
_updates_vgs_package_version() {
  local out facts key value
  out="$("$_updates_vgsh" pkg owner "$_updates_tree/VERSION" 2>/dev/null)" || return 0
  facts="$(_updates_facts owner <<<"$out")"
  while read -r key value; do
    if [[ $key == version ]]; then printf '%s' "$value"; fi
  done <<<"$facts"
}

# The plugins or themes behind their upstream, into _updates_behind; a
# checkout whose probe failed warns, and a probe that failed as a whole
# skips the source.
_updates_outdated() { # plugin|theme SOURCE
  local out facts key value
  _updates_behind=()
  if ! out="$("$_updates_vgsh" "$1" outdated --json)"; then
    _updates_diagnostic "updates: skipped=$2 reason=outdated-failed"; vgs_tui_warn "Could not check $2 for updates. This step was skipped."
    return 0
  fi
  facts="$(_updates_facts outdated "$2" <<<"$out")"
  while read -r key value; do
    case "$key" in
      update) _updates_behind+=("$value") ;;
      error) _updates_diagnostic "$2: $value"; vgs_tui_warn "Could not check one of the $2 for updates." ;;
    esac
  done <<<"$facts"
}

_updates_update_each() { # plugin|theme ID...
  local kind="$1" id status
  shift
  for id in "$@"; do
    vgs_tui_step "Updating the $kind $id"
    status=0
    "$_updates_vgsh" "$kind" update "${_updates_yes_flag[@]}" "$id" || status=$?
    if [[ $status -ne 0 ]]; then _updates_diagnostic "updates: $kind=$id exit=$status"; vgs_tui_warn "Could not update $id. The update continues."; fi
  done
}

_updates_orphans() {
  local out status=0 orphans=()
  out="$(pacman -Qtdq)" || status=$?
  # pacman -Qtdq exits 1 when no package is orphaned.
  if [[ $status -eq 1 && -z $out ]]; then return 0; fi
  if [[ $status -ne 0 ]]; then
    _updates_diagnostic "updates: orphans=unreadable exit=$status"; vgs_tui_warn "Could not check for unused packages. Package removal was skipped."
    return 0
  fi
  mapfile -t orphans <<<"$out"
  vgs_tui_step "Orphaned packages"
  printf '  %s\n' "${orphans[@]}"
  if [[ $_updates_yes == 1 ]]; then
    printf 'The unused packages were kept. Open Updates to review them.\n'
    return 0
  fi
  status=0
  vgs_tui_confirm "Remove ${#orphans[@]} orphaned package(s)?" --default=false || status=$?
  case "$status" in
    0) "$_updates_vgsh" pkg run remove --manager pacman "${orphans[@]}" || { _updates_diagnostic "updates: orphans=remove-failed exit=$?"; vgs_tui_warn "Could not remove the unused packages. Try again from Updates."; } ;;
    1) echo "Keeping the orphaned packages." ;;
    *) exit "$status" ;;
  esac
}

_updates_reboot() {
  local out status=0 reason reasons=()
  out="$(vgs_tui_reboot_check)" || status=$?
  case "$status" in
    0) ;;
    1) return 0 ;;
    *) _updates_diagnostic "updates: reboot-check=failed exit=$status"; vgs_tui_warn "Could not check whether a restart is needed."; return 0 ;;
  esac
  while read -r reason; do
    case "$reason" in
      reboot=kernel) reasons+=("The kernel was updated.") ;;
      reboot=hyprland) reasons+=("Hyprland was updated.") ;;
    esac
  done <<<"$out"
  if [[ $_updates_yes == 1 ]]; then
    printf '%s Reboot when you are ready.\n' "${reasons[*]}"
    return 0
  fi
  status=0
  vgs_tui_confirm "${reasons[*]} Reboot now?" || status=$?
  case "$status" in
    0) systemctl reboot ;;
    1) echo "Reboot later to run the updated system." ;;
    *) exit "$status" ;;
  esac
}

# Whether WORD is one of the rest.
_updates_in() { # WORD LIST...
  local word="$1" item
  shift
  for item in "$@"; do [[ $item == "$word" ]] && return 0; done
  return 1
}

# updates_main all ARG... | updates_main source SOURCE ARG...: the pipeline
# over every source, or over SOURCE alone, named as a status row names it:
# the primary manager's id, aur, flatpak, mise, vgs, plugins or themes. The
# ARGs after SOURCE are -y alone; update-source.sh passes its SOURCE twice,
# once here and once among the entry script's own ARGs, which the log runs
# it again with.
updates_main() {
  local mode="$1" only="" arg
  shift
  if [[ $mode == source ]]; then
    only="${1:-}"
    [[ -n $only && $only != -* ]] || _updates_refuse 2 "source=missing" "$_updates_usage"
    shift
  fi
  local entry_args=("$@")
  [[ $mode == all ]] || entry_args=("$only" "$@")
  _updates_yes=0
  for arg in "$@"; do
    case "$arg" in
      -y) _updates_yes=1 ;;
      *) _updates_refuse 2 "argument=$arg" "$_updates_usage" ;;
    esac
  done

  local lib="${VGS_TUI_LIB:-}"
  _updates_tree="${lib%/bin/lib/tui.sh}"
  if [[ -z $lib || $_updates_tree == "$lib" || -z ${VGS_PLUGIN_ID:-} ]]; then
    _updates_refuse 2 "tui=missing" "run this through the vgs.updates floating TUI, which sets VGS_TUI_LIB and VGS_PLUGIN_ID"
  fi
  # shellcheck source=SCRIPTDIR/../../../../bin/lib/tui.sh
  source "$lib"
  _updates_vgsh="$_updates_tree/bin/vgsh"
  _updates_loader="$_updates_tree/bin/lib/qml-library.js"
  _updates_facts_bin="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)/bin/facts"

  local state
  state="$(updates_state_dir)"
  _updates_log="$(updates_log_file)"
  if [[ ${VGS_TUI_LOGGED:-} != 1 ]]; then
    mkdir -p -- "$state"
    export UPDATES_LOG_PART="$state/.update.$$.log"
  fi
  vgs_tui_log "$UPDATES_LOG_PART" "${entry_args[@]}"
  local status=0
  vgs_tui_lock updates || status=$?
  if [[ $status -ne 0 ]]; then
    rm -f -- "$UPDATES_LOG_PART"
    exit "$status"
  fi
  mv -f -- "$UPDATES_LOG_PART" "$_updates_log"
  _updates_pid=$BASHPID
  trap '_updates_failed $?' ERR

  # What the run acts on: the plugin's settings and the system's managers.
  local out facts key value aur_command=() snapshot_setting="" trust=false
  out="$("$_updates_vgsh" plugin settings "$VGS_PLUGIN_ID")"
  facts="$(_updates_facts settings <<<"$out")"
  while read -r key value; do
    case "$key" in
      aur-command) read -r -a aur_command <<<"$value" ;;
      snapshot) snapshot_setting="$value" ;;
      trust) trust="$value" ;;
    esac
  done <<<"$facts"
  _updates_yes_flag=()
  if [[ $trust == true ]]; then _updates_yes_flag=(--yes); fi

  local primary="" present=() aur_binary=""
  out="$("$_updates_vgsh" pkg detect --json)"
  facts="$(_updates_facts detect <<<"$out")"
  while read -r key value; do
    case "$key" in
      primary) primary="$value" ;;
      present)
        present+=("${value%% *}")
        if [[ ${value%% *} == aur ]]; then aur_binary="${value#* }"; fi
        ;;
    esac
  done <<<"$facts"
  local aur_here=0
  if _updates_in aur "${present[@]}" || [[ ${#aur_command[@]} -gt 0 && $primary == pacman ]]; then aur_here=1; fi

  # The sources this run takes, in step order.
  local run=()
  if [[ $mode == all ]]; then
    run=(vgs)
    if [[ -n $primary ]]; then run+=("$primary"); fi
    for arg in flatpak mise; do
      if _updates_in "$arg" "${present[@]}"; then run+=("$arg"); fi
    done
    run+=(plugins themes)
    if [[ $aur_here == 1 ]]; then run+=(aur); fi
  else
    case "$only" in
      vgs|plugins|themes) ;;
      aur) [[ $aur_here == 1 ]] || _updates_refuse 1 "source=aur reason=absent" ;;
      flatpak|mise) _updates_in "$only" "${present[@]}" || _updates_refuse 1 "source=$only reason=absent" ;;
      "$primary") ;;
      *) _updates_refuse 2 "source=$only reason=unknown" "a source is the primary manager's id, aur, flatpak, mise, vgs, plugins or themes" ;;
    esac
    run=("$only")
  fi

  # Each source's plan, for the box and the steps. A package source whose
  # plan the table refuses, as it refuses nix's, leaves the run.
  local plan=() kept=() id label vgs_method="" vgs_package="" vgs_behind=false plugins=() themes=()
  local primary_planned=0 elevator="" elevator_refused=""
  local _updates_plan_text _updates_plan_elevator _updates_plan_elevator_refused
  if _updates_in vgs "${run[@]}"; then
    out="$("$_updates_vgsh" self status --json)"
    facts="$(_updates_facts self <<<"$out")"
    while read -r key value; do
      case "$key" in
        method) vgs_method="$value" ;;
        package) vgs_package="$value" ;;
        behind) vgs_behind="$value" ;;
        error) _updates_diagnostic "VGS: $value"; vgs_tui_warn "Could not check VGS for updates." ;;
      esac
    done <<<"$facts"
    case "$vgs_method:$vgs_behind:$vgs_package" in
      checkout:true:*|curl:true:*) plan+=("VGS: update VGS") ;;
      package:true:vgs-git)
        if [[ -n $aur_binary ]]; then plan+=("VGS: rebuild the VGS package after AUR updates")
        else plan+=("VGS: vgs-git is behind, and no AUR helper is here to rebuild it")
        fi
        ;;
      package:true:*) plan+=("VGS: the $vgs_package package updates with its package manager") ;;
      nix:true:*) plan+=("VGS: its flake updates it") ;;
      *) plan+=("VGS: current") ;;
    esac
  fi
  for id in "${run[@]}"; do
    case "$id" in
      vgs|plugins|themes) kept+=("$id"); continue ;;
      aur) if [[ ${#aur_command[@]} -gt 0 ]]; then kept+=(aur); continue; fi; label="AUR, last" ;;
      flatpak) label=Flatpak ;;
      mise) label=mise ;;
      *) label=System ;;
    esac
    if _updates_plan "$id"; then
      kept+=("$id")
      plan+=("$label: install available updates")
    else
      [[ $mode == all ]] || _updates_refuse 1 "source=$only reason=no-plan" "$_updates_plan_text"
      _updates_diagnostic "$label: $_updates_plan_text"; plan+=("$label: VGS cannot update this source")
    fi
    if [[ $id == "$primary" ]]; then
      primary_planned=1
      elevator="$_updates_plan_elevator"
      elevator_refused="$_updates_plan_elevator_refused"
    fi
  done
  run=("${kept[@]}")
  if [[ ${#aur_command[@]} -gt 0 ]] && _updates_in aur "${run[@]}"; then plan+=("AUR: install updates after system updates"); fi
  if _updates_in plugins "${run[@]}"; then
    _updates_outdated plugin plugins
    plugins=("${_updates_behind[@]}")
    plan+=("Plugins: ${plugins[*]:-current}")
  fi
  if _updates_in themes "${run[@]}"; then
    _updates_outdated theme themes
    themes=("${_updates_behind[@]}")
    plan+=("Themes: ${themes[*]:-current}")
  fi

  # A snapshot and the VGS version check guard every step that replaces
  # packages: the upgrades, the system's and the AUR's, and the vgs-git
  # rebuild. The orphans follow the upgrades alone.
  local upgrades=0 rebuild=0 replaces=0
  if _updates_in aur "${run[@]}" || { [[ -n $primary ]] && _updates_in "$primary" "${run[@]}"; }; then upgrades=1; fi
  if _updates_in vgs "${run[@]}" && [[ $vgs_method:$vgs_behind:$vgs_package == package:true:vgs-git && -n $aur_binary ]]; then rebuild=1; fi
  if [[ $upgrades == 1 || $rebuild == 1 ]]; then replaces=1; fi
  local snapshot_line="" snapshot_tool=""
  if [[ $replaces == 1 ]]; then
    if [[ $snapshot_setting == off ]]; then
      snapshot_line="Snapshot: off in the plugin's settings"
    elif ! snapshot_tool="$(_updates_snapshot_tool)"; then
      snapshot_tool=""
      snapshot_line="Snapshot: none, no snapper or timeshift found"
    else
      # The primary's plan names the elevation command, also when the run
      # leaves the system step out; a refused plan leaves its refusal in
      # elevator_refused, for the box.
      if [[ $primary_planned == 0 && -n $primary ]]; then
        _updates_plan "$primary" || true
        elevator="$_updates_plan_elevator"
        elevator_refused="$_updates_plan_elevator_refused"
      fi
      if [[ -n $elevator ]]; then
        snapshot_line="Snapshot: $snapshot_tool through $elevator, first"
      else
        snapshot_tool=""
        _updates_diagnostic "snapshot: $elevator_refused"; snapshot_line="Snapshot: unavailable because administrator access is not available"
      fi
    fi
  fi
  local session=0
  if [[ $elevator == sudo ]]; then session=1; fi

  # The free space and the plan box.
  local avail
  out="$(df --output=avail --block-size=1 /)"
  avail="${out##*$'\n'}"
  avail="${avail//[[:space:]]/}"
  if [[ ! $avail =~ $_updates_digits ]]; then
    _updates_diagnostic "updates: free-space=unreadable"; vgs_tui_warn "Could not check free disk space."
  elif ((avail < 10 * 1024 * 1024 * 1024)); then
    vgs_tui_warn "Less than 10 GiB is free on /. An update can fail when the disk fills up."
  fi
  local box=("Update ${only:-everything}" "")
  [[ -z $snapshot_line ]] || box+=("$snapshot_line")
  box+=("${plan[@]}")
  if [[ $rebuild == 1 ]] || _updates_in aur "${run[@]}"; then box+=("The AUR runs last, after every step that runs as root."); fi
  box+=("" "Log: $_updates_log")
  vgs_tui_header "${box[@]}"
  if [[ $_updates_yes != 1 ]]; then
    status=0
    vgs_tui_confirm "Start the update?" || status=$?
    case "$status" in
      0) ;;
      1) echo "Update cancelled."; exit 0 ;;
      *) exit "$status" ;;
    esac
  fi

  # The run.
  local vgs_before=""
  if [[ $replaces == 1 ]]; then vgs_before="$(_updates_vgs_package_version)"; fi
  if [[ $session == 1 ]]; then vgs_tui_sudo_session start; fi
  # A failed snapshot said what went wrong; it does not block the update,
  # but it must not pass for one either.
  if [[ -n $snapshot_tool ]]; then
    status=0
    _updates_snapshot "$snapshot_tool" "$elevator" || status=$?
    if [[ $status -ne 0 ]]; then
      _updates_diagnostic "updates: snapshot=failed exit=$status"; vgs_tui_warn "The snapshot failed."
      vgs_tui_warn "Continuing the update without a snapshot."
    fi
  fi
  if _updates_in vgs "${run[@]}" && [[ $vgs_behind == true && ( $vgs_method == checkout || $vgs_method == curl ) ]]; then
    vgs_tui_step "Updating VGS"
    "$_updates_vgsh" self update
  fi
  for id in "${run[@]}"; do
    case "$id" in
      vgs|plugins|themes|aur) ;;
      *) "$_updates_vgsh" pkg run upgrade --manager "$id" ;;
    esac
  done
  if [[ ${#plugins[@]} -gt 0 ]]; then _updates_update_each plugin "${plugins[@]}"; fi
  if [[ ${#themes[@]} -gt 0 ]]; then _updates_update_each theme "${themes[@]}"; fi
  if [[ $session == 1 ]]; then vgs_tui_sudo_session end; fi

  if [[ $rebuild == 1 ]] || _updates_in aur "${run[@]}"; then
    local guarded=0
    if command -v sudo >/dev/null; then
      vgs_tui_sudo_session guard
      guarded=1
    fi
    if _updates_in aur "${run[@]}"; then
      if [[ ${#aur_command[@]} -gt 0 ]]; then
        _updates_run "Updating AUR packages" "${aur_command[@]}"
      else
        "$_updates_vgsh" pkg run upgrade --manager aur
      fi
    fi
    if [[ $rebuild == 1 ]]; then _updates_run "Rebuilding VGS" "$aur_binary" -S vgs-git; fi
    if [[ $guarded == 1 ]]; then vgs_tui_sudo_session end; fi
  fi

  if [[ $primary == pacman ]] && [[ $upgrades == 1 ]]; then _updates_orphans; fi
  if [[ -n $vgs_before ]] && [[ "$(_updates_vgs_package_version)" != "$vgs_before" ]] && "$_updates_vgsh" pid >/dev/null 2>&1; then
    vgs_tui_step "Restarting the shell on the updated VGS"
    "$_updates_vgsh" restart || { _updates_diagnostic "updates: restart=failed exit=$?"; vgs_tui_warn "VGS could not restart. Save your work and restart the computer."; }
  fi
  _updates_reboot
}
