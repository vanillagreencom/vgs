#!/usr/bin/env bash
# The vgs.devtools engine, shell/plugins/vgs.devtools/bin/devtools, and its
# floating TUI scripts, tui/devtools.sh and the entry scripts that run it.
# Every command a row reaches is a
# stub on a PATH that holds nothing else but the tools the engine and
# `vgsh pkg run` need: mise keeps its installs in a scratch state and data
# directory and records each call that changes something, with the
# MISE_MINIMUM_RELEASE_AGE it ran under; pacman records its argv; sudo runs
# the rest of its argv; uname answers the machine a row names; gum's
# filter records the lines it was offered and answers the one $GUM_PICK
# names, or exits $GUM_STATUS. No row
# reaches a real package manager, the owner's mise config or a live session.
#
# Rows run under `unshare -rm` with a fixture os-release bound over
# /etc/os-release, so pacman is the primary whatever the host; without user
# namespaces the suite exits 77. A verb that changes the system runs on a
# pseudo-terminal script(1) opens, as the floating TUI's is.
#
# Controls run a row against a copy of the plugin with one rule removed
# from the engine or CatalogLogic.js, and that row must fail.
set -euo pipefail

source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"
for tool in script setsid timeout unshare; do
  command -v "$tool" >/dev/null || { echo "test-devtools: status=not-measured missing=$tool"; exit 77; }
done
unshare -rm true 2>/dev/null || { echo "test-devtools: status=not-measured missing=user-namespaces"; exit 77; }
script_bin="$(command -v script)"

tools="$tmp/tools"; mkdir -p "$tools"
for tool in bash sh readlink dirname sleep cat env mkdir rm mktemp mv; do
  found="$(command -v "$tool")" || { echo "test-devtools: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$found" "$tools/$tool"
done
ln -s -- "$node_bin" "$tools/node"

stubs="$tmp/stubs"; mkdir -p "$stubs"
# pacman writes one line per call to $LOG: its name, then each argument in
# brackets.
printf '#!/bin/sh\nprintf "pacman" >>"$LOG"; for a; do printf " [%%s]" "$a" >>"$LOG"; done; echo >>"$LOG"\n' >"$stubs/pacman"
printf '#!/bin/sh\ncase "$1" in -k) exit 0 ;; -n) shift ;; esac\nexec "$@"\n' >"$stubs/sudo"
printf '#!/bin/sh\necho "$STUB_MACHINE"\n' >"$stubs/uname"
printf '#!/bin/sh\n[ "$1" = filter ] || exit 64\ncat >"$GUM_OFFERED"\n[ -z "${GUM_STATUS-}" ] || exit "$GUM_STATUS"\nprintf "%%s\\n" "$GUM_PICK"\n' >"$stubs/gum"
# mise: $MISE_STATE/installed holds one installed key per line,
# $MISE_STATE/global-extra the global config's keys no install backs,
# $MISE_STATE/auto_prune the setting, and $MISE_STATE/which/<command> what
# `mise which` answers. A call that changes something is
# logged as `mise [arg]... {age=<MISE_MINIMUM_RELEASE_AGE>}`.
cat >"$stubs/mise" <<'EOF'
#!/bin/bash
set -u
st="$MISE_STATE"
log() { printf 'mise' >>"$LOG"; for a; do printf ' [%s]' "$a" >>"$LOG"; done; printf ' {age=%s}\n' "${MISE_MINIMUM_RELEASE_AGE-unset}" >>"$LOG"; }
key() { local k="${1/\[*\]/}"; printf '%s' "${k%%@*}"; }
dir() { printf '%s/installs/%s' "$MISE_DATA_DIR" "$(key "$1" | tr ':/' '--')"; }
entries() { # FILE...
  local first=1 k
  printf '{'
  for f in "$@"; do
    [ -f "$f" ] || continue
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      [ $first = 1 ] || printf ','
      first=0
      printf '"%s":[{"version":"1.0.0","installed":%s,"active":true,"source":{"type":"mise.toml","path":"g"}}]' "$k" "$([ "$f" = "$st/installed" ] && echo true || echo false)"
    done <"$f"
  done
  printf '}\n'
}
case "$1" in
  --version) echo "2026.9.9 linux-x64 (stub)" ;;
  ls) if [ "$2" = --global ]; then entries "$st/installed" "$st/global-extra"; else entries "$st/installed"; fi ;;
  settings)
    if [ "$2" = get ]; then cat "$st/auto_prune" 2>/dev/null || echo true; exit 0; fi
    log "$@"
    [ "$3" != upgrade.auto_prune ] || echo "$4" >"$st/auto_prune" ;;
  use)
    log "$@"
    spec="${!#}"
    [ "${MISE_FAIL-}" != "$spec" ] || exit 3
    k="$(key "$spec")"
    grep -qxF -- "$k" "$st/installed" 2>/dev/null || echo "$k" >>"$st/installed"
    mkdir -p "$(dir "$spec")" ;;
  uninstall)
    log "$@"
    k="$3"
    # grep exits 1 when no key is left, which is an answer; 2 is a failure.
    s=0; grep -vxF -- "$k" "$st/installed" >"$st/installed.new" || s=$?
    [ $s -le 1 ] || exit 90
    mv "$st/installed.new" "$st/installed"
    rm -rf "$(dir "$k")" ;;
  where) dir "$2"; echo ;;
  which)
    if [ -f "$st/which/$2" ]; then cat "$st/which/$2"; exit 0; fi
    printf 'mise ERROR %s is not a mise bin. Perhaps you need to install it first.\n' "$2" >&2
    exit 1 ;;
  x)
    # What a step run through a tool leaves: a gem's executable only
    # under mise's ruby, and Composer's global bin-dir and launcher.
    log "$@"
    while [ "$1" != -- ]; do shift; done
    shift
    mkdir -p "$st/which"
    case "$*" in
      # rails is a metapackage: its rails executable belongs to railties,
      # so only uninstalling railties takes the command away.
      "gem install rails "*)
        printf '%s/installs/ruby/bin/rails\n' "$MISE_DATA_DIR" >"$st/which/rails"
        echo rails >"$st/which/.owner-railties" ;;
      "gem uninstall "*)
        for g; do
          [ -f "$st/which/.owner-$g" ] || continue
          rm -f "$st/which/$(cat "$st/which/.owner-$g")" "$st/which/.owner-$g"
        done ;;
      "composer global config bin-dir "*) echo "$5" >"$st/composer-bin" ;;
      "composer global require laravel/installer")
        bin="$(cat "$st/composer-bin" 2>/dev/null || echo "$HOME/.config/composer/vendor/bin")"
        mkdir -p "$bin"; : >"$bin/laravel" ;;
      "composer global remove laravel/installer")
        bin="$(cat "$st/composer-bin" 2>/dev/null || echo "$HOME/.config/composer/vendor/bin")"
        rm -f "$bin/laravel" ;;
    esac ;;
  *) log "$@" ;;
esac
EOF
chmod +x "$stubs"/*
# grep and tr for the stub mise alone.
for tool in grep tr; do ln -s -- "$(command -v "$tool")" "$tools/$tool"; done

printf 'NAME="Arch Linux"\nID=arch\n' >"$tmp/os-release"
log="$tmp/log"; home="$tmp/home"; cfg="$tmp/cfg"; state="$tmp/mise-state"; data="$tmp/mise-data"
plugin="$repo/shell/plugins/vgs.devtools"
lines() { printf '%s\n' "$@"; }

# A fresh world: an empty HOME, mise state and log.
reset_world() {
  rm -rf -- "$home" "$state" "$data" "$log" "$cfg"
  mkdir -p "$home" "$state" "$data" "$cfg"
  : >"$log"
}

# in_world [VAR=VALUE...] -- WORDS...: WORDS in the stub world with the
# fixture os-release. ENGINE_TTY=pty runs them on a pseudo-terminal, none
# with no controlling terminal, and plain (the default) with neither.
# Output lands in $tmp/out, stripped of carriage returns, the exit status
# in $status.
in_world() {
  local extra=() cmd words
  while [[ $1 != -- ]]; do extra+=("$1"); shift; done
  shift
  words=(env -i PATH="$stubs:$tools" HOME="$home" XDG_CONFIG_HOME="$cfg" XDG_RUNTIME_DIR="$rt_empty"
    LC_ALL=C LOG="$log" MISE_STATE="$state" MISE_DATA_DIR="$data" STUB_MACHINE="${MACHINE:-x86_64}"
    GUM_OFFERED="$tmp/offered" VGS_TEST_RUN=1 TMPDIR="$tmp" "${extra[@]}" "$@")
  status=0
  case "${ENGINE_TTY:-plain}" in
    pty)
      cmd="$(printf '%q ' "${words[@]}")"
      SHELL="$BASH" timeout 60 unshare -rm sh -c 'mount --bind "$1" /etc/os-release && shift && exec "$@"' sh "$tmp/os-release" \
        "$script_bin" -qec "$cmd" /dev/null </dev/null >"$tmp/out.raw" 2>&1 || status=$? ;;
    none)
      timeout 60 unshare -rm sh -c 'mount --bind "$1" /etc/os-release && shift && exec setsid -w "$@"' sh "$tmp/os-release" \
        "${words[@]}" </dev/null >"$tmp/out.raw" 2>&1 || status=$? ;;
    plain)
      timeout 60 unshare -rm sh -c 'mount --bind "$1" /etc/os-release && shift && exec "$@"' sh "$tmp/os-release" \
        "${words[@]}" </dev/null >"$tmp/out.raw" 2>&1 || status=$? ;;
  esac
  tr -d '\r' <"$tmp/out.raw" >"$tmp/out"
}
# engine PLUGIN_DIR [VAR=VALUE...] -- ARGS: the plugin's engine against
# this repository's tree, as `devtools --tree <repo> ARGS`.
engine() {
  local at="$1" extra=()
  shift
  while [[ $1 != -- ]]; do extra+=("$1"); shift; done
  shift
  in_world "${extra[@]}" -- "$node_bin" "$at/bin/devtools" --tree "$repo" "$@"
}
# tui PLUGIN_DIR SCRIPT [VAR=VALUE...] -- ARGS: the plugin's TUI script
# tui/SCRIPT as the presenter runs it, with VGS_TUI_LIB this repository's
# library and VGS_PLUGIN_DIR the plugin.
tui() {
  local at="$1" script="$2" extra=()
  shift 2
  while [[ $1 != -- ]]; do extra+=("$1"); shift; done
  shift
  in_world VGS_TUI_LIB="$repo/bin/lib/tui.sh" VGS_PLUGIN_DIR="$at" "${extra[@]}" -- "$at/tui/$script" "$@"
}
out_has() { grep -qF -- "$1" "$tmp/out"; }
log_is() { [[ "$(cat "$log")" == "$1" ]] || { printf '    log:\n%s\n    want:\n%s\n' "$(cat "$log")" "$1"; return 1; }; }
list_has() { json_is "$tmp/out" "$1"; }

# Each row takes the plugin copy it runs and answers 0 when every
# expectation holds; the named checks report each expectation.
row_arch() { # PLUGIN
  reset_world
  MACHINE=aarch64 engine "$1" -- list --json
  [[ $status == 0 ]] && list_has 'd["machine"] == "aarch64" and "t3code" not in [r["id"] for r in d["sections"]["apps"]] and "herdr" in [r["id"] for r in d["sections"]["apps"]]'
}
row_foreign() { # PLUGIN
  reset_world
  mkdir -p "$home/.local/bin"
  printf '#!/bin/sh\n# the owner'"'"'s own wrapper\nexec agent-cli claude "$@"\n' >"$home/.local/bin/claude"
  cp -- "$home/.local/bin/claude" "$tmp/claude.orig"
  engine "$1" -- launchers refresh
  [[ $status == 0 ]] && cmp -s "$home/.local/bin/claude" "$tmp/claude.orig" && out_has "launcher=foreign command=claude path=$home/.local/bin/claude"
}
row_install_order() { # PLUGIN
  reset_world
  ENGINE_TTY=pty engine "$1" -- install ruby
  [[ $status == 0 ]] && log_is "$(lines \
    "mise [settings] [set] [upgrade.auto_prune] [false] {age=0}" \
    "pacman [-S] [--needed] [--] [libyaml]" \
    "mise [settings] [set] [ruby.compile] [false] {age=0}" \
    "mise [settings] [add] [idiomatic_version_file_enable_tools] [ruby] {age=0}" \
    "mise [use] [-g] [ruby] {age=0}")"
}
row_rails_install() { # PLUGIN: the rails command exists only under mise's ruby
  reset_world
  ENGINE_TTY=pty engine "$1" -- install rails
  [[ $status == 0 ]] && log_is "$(lines \
    "mise [settings] [set] [upgrade.auto_prune] [false] {age=0}" \
    "pacman [-S] [--needed] [--] [libyaml]" \
    "mise [settings] [set] [ruby.compile] [false] {age=0}" \
    "mise [settings] [add] [idiomatic_version_file_enable_tools] [ruby] {age=0}" \
    "mise [use] [-g] [ruby] {age=0}" \
    "mise [x] [ruby] [--] [gem] [install] [rails] [--no-document] {age=0}")"
}
row_rails_update() { # PLUGIN: after row_rails_install
  : >"$log"
  ENGINE_TTY=pty engine "$1" -- update rails
  [[ $status == 0 ]] && log_is "$(lines \
    "mise [up] [ruby] {age=0}" \
    "mise [x] [ruby] [--] [gem] [install] [rails] [--no-document] {age=0}")"
}
row_rails_remove_kept() { # PLUGIN: rails installed, and with it ruby, which stays
  row_rails_install "$plugin" || return 1
  : >"$log"
  ENGINE_TTY=pty engine "$1" -- remove rails
  [[ $status == 0 ]] && out_has "devtools: kept=ruby reason=declared-by-installed-row" && log_is \
    "mise [x] [ruby] [--] [gem] [uninstall] [rails] [railties] [--all] [--executables] [--ignore-dependencies] {age=0}"
}
# The rows remove offers with claude installed: the catalog row by id and
# the other tool by --mise and its key, and no row it cannot remove.
row_targets() { # PLUGIN
  reset_world
  printf 'claude\ngithub:owner/extra\n' >"$state/installed"
  engine "$1" -- targets remove
  [[ $status == 0 ]] && [[ "$(cat "$tmp/out")" == "$(lines "Claude Code · Agents"$'\t'"claude" "github:owner/extra · Other mise tools"$'\t'"--mise"$'\t'"github:owner/extra")" ]]
}
# The install entry opened with no row offers the absent rows and installs
# the one picked, which is not the first offered.
row_picker() { # PLUGIN
  reset_world
  echo false >"$state/auto_prune"
  ENGINE_TTY=pty tui "$1" install.sh GUM_PICK="Codex · Agents" --
  [[ $status == 0 ]] && grep -qxF "Claude Code · Agents" "$tmp/offered" && log_is "mise [use] [-g] [codex] {age=0}"
}
row_remove_mirror() { # PLUGIN: after row_install_order's install
  : >"$log"
  ENGINE_TTY=pty engine "$1" -- remove ruby
  [[ $status == 0 ]] && log_is "$(lines \
    "mise [uninstall] [--all] [ruby] {age=0}" \
    "mise [rm] [-g] [ruby] {age=0}" \
    "pacman [-Rns] [--] [libyaml]")"
}

reset_world
engine "$plugin" -- list --json
check "list exits 0" test "$status" == 0
check "list names the machine, mise and the primary manager" list_has 'd["machine"] == "x86_64" and d["mise"] == {"present": True, "version": "2026.9.9"} and d["manager"] == "pacman"'
check "list holds every section" list_has 'sorted(d["sections"]) == sorted(["agents","apps","tools","envs","editors","terminals","databases"])'
check "an x86_64-only row shows on x86_64" list_has '"t3code" in [r["id"] for r in d["sections"]["apps"]]'
check "an absent row offers install" list_has '[r for r in d["sections"]["agents"] if r["id"] == "claude"][0]["actions"] == ["install"]'
check "a row with channels lists its default first" list_has '[r for r in d["sections"]["apps"] if r["id"] == "herdr"][0]["channels"] == ["stable", "preview"]'
check "no container runtime offers no database install" list_has 'all(r["actions"] == [] for r in d["sections"]["databases"])'

check "an x86_64-only row is hidden on an aarch64 fixture, and others stay" row_arch "$plugin"
MACHINE=aarch64 ENGINE_TTY=pty engine "$plugin" -- install t3code
check "install of a row built for another machine is refused" out_has "devtools: refused: id=t3code arch=aarch64 reason=unsupported"
check "that refusal runs nothing" log_is ""

check "install runs packages, settings, then mise use, after auto_prune" row_install_order "$plugin"
check "the present probe holds after install" test -d "$data/installs/ruby"
engine "$plugin" -- list --json
check "the installed row reads installed from mise with update and remove" list_has '[(r["installed"], r["origin"], r["version"], r["actions"]) for r in d["sections"]["envs"] if r["id"] == "ruby"] == [(True, "mise", "1.0.0", ["update", "remove"])]'
ENGINE_TTY=pty engine "$plugin" -- install ruby
check "a second install is refused as installed" out_has "devtools: refused: id=ruby state=installed"
check "remove takes back the tool, then the packages, in install's reverse" row_remove_mirror "$plugin"
check "the present probe no longer holds after remove" test ! -e "$data/installs/ruby"

# rails: its command lives only under mise's ruby, update installs the
# current gem again, and remove takes the gem back while ruby stays.
check "install of rails ends with its command found through mise" row_rails_install "$plugin"
engine "$plugin" -- list --json
check "list reads rails installed from mise, with update and remove" list_has '[(r["installed"], r["origin"], r["actions"]) for r in d["sections"]["envs"] if r["id"] == "rails"] == [(True, "mise", ["update", "remove"])]'
check "update runs mise up, then the postInstall steps again" row_rails_update "$plugin"
check "remove takes back the rails gem through postRemove while ruby stays" row_rails_remove_kept "$plugin"
engine "$plugin" -- list --json
check "rails lists absent and ruby installed after that removal" list_has '[(r["id"], r["installed"]) for r in d["sections"]["envs"] if r["id"] in ("ruby", "rails")] == [("ruby", True), ("rails", False)]'

# laravel: Composer's global bin-dir is set before the installer lands, so
# its launcher is at the row's probe; remove takes the installer back first.
reset_world
echo false >"$state/auto_prune"
php="github:nunomaduro/static-php-builds"
ENGINE_TTY=pty engine "$plugin" -- install laravel
check "install of laravel sets Composer's bin-dir before requiring the installer" log_is "$(lines \
  "mise [use] [-g] [$php] {age=0}" \
  "mise [use] [-g] [node] {age=0}" \
  "mise [x] [$php] [--] [composer] [global] [config] [bin-dir] [$home/.local/bin] {age=0}" \
  "mise [x] [$php] [--] [composer] [global] [require] [laravel/installer] {age=0}")"
check "the laravel install ends with its probe holding" test "$status" == 0
: >"$log"
ENGINE_TTY=pty engine "$plugin" -- remove laravel
# Its install made the php and node rows read installed, so their tools stay.
check "remove of laravel takes the installer back" log_is "mise [x] [$php] [--] [composer] [global] [remove] [laravel/installer] {age=0}"
check "remove of laravel keeps the tools the php and node rows hold" out_has "devtools: kept=node reason=declared-by-installed-row"
check "the laravel removal ends with its probe gone" test "$status" == 0

# auto_prune is set once: a later install leaves it.
reset_world
echo false >"$state/auto_prune"
ENGINE_TTY=pty engine "$plugin" -- install claude
check "install with auto_prune already false leaves it and uses the package" log_is "mise [use] [-g] [claude] {age=0}"
check "install writes no launcher without --launchers" test ! -e "$home/.local/bin/claude"
: >"$log"
ENGINE_TTY=pty engine "$plugin" -- update claude --launchers
check "update runs mise up on the row's key without the cooldown" log_is "mise [up] [claude] {age=0}"
check "update --launchers writes the row's launcher" out_has "launcher=written command=claude"
check "the launcher carries VGS's mark and installs on first run" grep -qxF "mise where 'claude' >/dev/null 2>&1 || mise use -g --quiet 'claude' || exit 1" "$home/.local/bin/claude"
: >"$log"
ENGINE_TTY=pty engine "$plugin" -- remove claude
check "remove of a package row uninstalls and forgets its key" log_is "$(lines "mise [uninstall] [--all] [claude] {age=0}" "mise [rm] [-g] [claude] {age=0}")"
check "remove deletes the launcher VGS wrote" out_has "launcher=removed command=claude"

# An exec row: installed with an empty bin_path=, its launcher written
# whatever the setting, running the exec file under mise's root.
reset_world
echo false >"$state/auto_prune"
ENGINE_TTY=pty engine "$plugin" -- install cursor
check "an exec row installs with an empty bin_path=" log_is "mise [use] [-g] [cursor-agent[bin_path=]] {age=0}"
check "an exec row gets its launcher without --launchers" out_has "launcher=written command=cursor-agent"
check "the exec launcher runs the exec file under mise's root" grep -qxF "exec \"\$root\"/'dist-package/cursor-agent' \"\$@\"" "$home/.local/bin/cursor-agent"
engine "$plugin" -- launchers remove
check "launchers remove keeps an installed exec row's launcher" test -e "$home/.local/bin/cursor-agent"

check "launchers refresh leaves the owner's file untouched" row_foreign "$plugin"
check "launchers refresh writes the other rows' launchers" out_has "launcher=written command=codex"
printf '#!/bin/sh\n%s\n' "# vgs.devtools launcher" >"$home/.local/bin/retired-tool"
engine "$plugin" -- launchers refresh
check "launchers refresh retires a VGS launcher no row offers" out_has "launcher=retired command=retired-tool"
engine "$plugin" -- launchers remove
check "launchers remove deletes VGS's launchers" test ! -e "$home/.local/bin/codex"
check "launchers remove keeps the owner's file" cmp -s "$home/.local/bin/claude" "$tmp/claude.orig"

# Other mise tools: what the global config declares and no row does.
reset_world
printf 'claude\ngithub:owner/extra\n' >"$state/installed"
echo false >"$state/auto_prune"
engine "$plugin" -- list --json
check "other lists the global tool no row declares, alone" list_has 'd["other"] == [{"id": "github:owner/extra", "installed": True, "version": "1.0.0", "actions": ["update", "remove"]}]'
ENGINE_TTY=pty engine "$plugin" -- update --mise github:owner/extra
check "update --mise runs mise up on the key" log_is "mise [up] [github:owner/extra] {age=0}"
ENGINE_TTY=pty engine "$plugin" -- remove --mise claude
check "remove --mise refuses a key a row declares" out_has "devtools: refused: mise-tool=claude reason=not-other"

# Where a change may run.
reset_world
ENGINE_TTY=none engine "$plugin" -- install claude
check "install without a terminal is refused" out_has "devtools: refused: install=no-terminal"
ENGINE_TTY=pty engine "$plugin" VGSH_RUNNER_PID=1 -- install claude
check "install in a process the shell started is refused" out_has "devtools: refused: caller=shell verb=install"
check "neither refusal runs anything" log_is ""
ENGINE_TTY=pty engine "$plugin" -- install claude --channel preview
check "a channel the row does not offer is refused" out_has "devtools: refused: channel=preview id=claude offers=none"
ENGINE_TTY=pty engine "$plugin" -- install no-such-row
check "an unknown id is refused" out_has "devtools: refused: id=no-such-row reason=unknown"
engine "$plugin" -- list
check "list without --json is a bad invocation" test "$status" == 2

# The targets a picker offers.
check "targets lists what remove takes for each row it offers" row_targets "$plugin"
engine "$plugin" -- targets list
check "targets of a verb the TUI does not run is a bad invocation" test "$status" == 2

# The floating TUI scripts: each entry script runs devtools.sh with its
# verb, which hands a row to the engine of the copy it runs from, against
# the tree VGS_TUI_LIB lies in, or offers the rows the verb takes.
reset_world
echo false >"$state/auto_prune"
ENGINE_TTY=pty tui "$plugin" install.sh -- claude
check "the install entry installs the row it is handed" log_is "mise [use] [-g] [claude] {age=0}"
: >"$log"
ENGINE_TTY=pty tui "$plugin" update.sh -- claude
check "the update entry updates the row it is handed" log_is "mise [up] [claude] {age=0}"
: >"$log"
ENGINE_TTY=pty tui "$plugin" remove.sh -- claude
check "the remove entry removes the row it is handed" log_is "$(lines "mise [uninstall] [--all] [claude] {age=0}" "mise [rm] [-g] [claude] {age=0}")"
check "an entry opened with no row installs the row picked" row_picker "$plugin"
check "the picker offers no row the verb does not take" test "$(grep -c -F "Other mise tools" "$tmp/offered" || true)" == 0
reset_world
echo false >"$state/auto_prune"
printf 'github:owner/extra\n' >"$state/installed"
ENGINE_TTY=pty tui "$plugin" update.sh GUM_PICK="github:owner/extra · Other mise tools" --
check "the update picker updates an other mise tool by its key" log_is "mise [up] [github:owner/extra] {age=0}"
: >"$log"
ENGINE_TTY=pty tui "$plugin" install.sh GUM_STATUS=1 --
check "leaving the filter with Esc exits 0" test "$status" == 0
check "leaving the filter runs nothing" log_is ""
ENGINE_TTY=pty tui "$plugin" install.sh GUM_STATUS=130 --
check "a Ctrl-C in the filter exits 130" test "$status" == 130
ENGINE_TTY=pty tui "$plugin" install.sh GUM_PICK="Not offered" --
check "a pick the filter was not offered is refused" out_has "devtools: refused: picked=Not offered reason=unlisted"
check "that refusal runs nothing" log_is ""
ENGINE_TTY=pty tui "$plugin" requirement.sh -- --manager pacman libyaml
check "the requirement entry installs the package through vgsh pkg run" log_is "pacman [-S] [--needed] [--] [libyaml]"
tui "$plugin" requirement.sh -- libyaml
check "the requirement entry without --manager is refused" out_has "devtools: refused: requirement=arguments"
check "that refusal exits 2" test "$status" == 2
tui "$plugin" devtools.sh -- list --json
check "the TUI script refuses a verb it does not run" out_has "devtools: refused: verb=list"
in_world -- "$plugin/tui/install.sh" claude
check "the TUI script outside the presenter is refused" out_has "devtools: refused: tui=missing"
check "that refusal exits 2" test "$status" == 2

# The keeps-packages control installs through the shipped engine, then
# removes through its copy.
row_remove_mirror_after_install() { row_install_order "$plugin" && row_remove_mirror "$1"; }
row_rails_update_after_install() { row_rails_install "$plugin" && row_rails_update "$1"; }

# Controls: each copy removes one rule, and the row that holds it must fail.
# control NAME FILE NEEDLE REPLACEMENT ROW: FILE relative to the plugin.
control() {
  local dir="$tmp/control-$1"
  cp -R -- "$plugin" "$dir"
  check "the $1 control's text occurs once in $2" \
    python3 -c 'import sys; sys.exit(0 if open(sys.argv[1]).read().count(sys.argv[2]) == 1 else 1)' "$plugin/$2" "$3"
  python3 -c 'import sys; p, a, b = sys.argv[1:]; s = open(p).read(); open(p, "w").write(s.replace(a, b))' "$dir/$2" "$3" "$4"
  check "the $1 mutant differs from $2" test "$(cmp -s "$plugin/$2" "$dir/$2"; echo $?)" == 1
  if "row_$5" "$dir" >/dev/null; then fail "the $1 mutant passes row $5"; else ok "the $1 mutant fails row $5"; fi
}
control overwrites-foreign bin/devtools '    if (state === "foreign") return launcherLine("foreign", row.command);' '' foreign
control ignores-arch CatalogLogic.js '    return !Array.isArray(row.arch) || listHas(row.arch, machine);' '    return true;' arch
control packages-last bin/devtools $'    if (row.packages !== undefined) {\n        const picked = PackageManagers.packageFor(row.packages, surveyed.found);' $'    if (false) {\n        const picked = PackageManagers.packageFor(row.packages, surveyed.found);' install_order
control no-mise-which bin/devtools '        for (const finder of [resolveCommand, miseWhich])' '        for (const finder of [resolveCommand])' rails_install
control update-skips-postinstall bin/devtools $'    runSteps((row.postInstall || []).map(step => stepArgv(catalog, step)), env);\n    verifyPresent(row);\n    if (spec !== null) settleLauncher(row, spec, launchers);' $'    verifyPresent(row);\n    if (spec !== null) settleLauncher(row, spec, launchers);' rails_update_after_install
control rails-only-postremove catalog.json $'"rails",\n            "railties",' '"rails",' rails_remove_kept
control skips-postremove bin/devtools '    runSteps((row.postRemove || []).map(step => stepArgv(catalog, step)), buildEnv(row));' '' rails_remove_kept
control targets-every-row bin/devtools '            if (row.actions.includes(verb)) lines.push(row.name' '            lines.push(row.name' targets
control picks-first tui/devtools.sh '  [[ ${labels[i]} == "$picked" ]] || continue' '  :' picker
control keeps-packages bin/devtools $'            runPackages("remove", picked.manager,' $'            if (false) runPackages("remove", picked.manager,' remove_mirror_after_install

if [[ $failures -gt 0 ]]; then echo "test-devtools: $failures failure(s)"; exit 1; fi
echo "test-devtools: ok"
