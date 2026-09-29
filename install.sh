#!/usr/bin/env bash
# Install VGS into your home directory. No root, no package, no sudo.
#
#   curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh | bash -s -- [OPTIONS]
#
#   install.sh [--version X.Y.Z] [--force]   the newest release, or release X.Y.Z
#   install.sh --git [--force]               a clone of main
#   install.sh --uninstall [--force]         remove what this script installed
#
# A release lands in ${XDG_DATA_HOME:-~/.local/share}/vgs/X.Y.Z. The link
# vgs/current names it and is replaced by rename alone, and ~/.local/bin/vgsh
# links to vgs/current/bin/vgsh: the curl layout `vgsh self status` detects
# and `vgsh self update` keeps (docs/architecture/distribution.md § Curl
# installer). --git clones main into vgs/git and links ~/.local/bin/vgsh to
# it. Every write under vgs/ holds flock on vgs/.self.lock.
#
# Before it writes anything it refuses root, a system other than Linux, an
# installed system package (/usr/bin/vgsh, or vgs or vgs-git in the pacman,
# rpm or dpkg database) and a ~/.local/bin/vgsh it did not make; --force
# skips the last two. It checks the floor: Quickshell 0.3.1, Hyprland 0.56,
# node 18, python3, git and flock, plus curl, tar, gzip and sha256sum for a
# release. Each version probe runs under a private runtime directory, so a
# shell with no login session reads the true floor. On a miss it names each
# tool and the command that installs it on this distribution, and exits 78.
# A tool it finds but whose version it cannot read is named with the
# probe's exit status and last error lines instead of an install command.
# It never runs sudo.
#
# A release is read from the GitHub API and downloaded over HTTPS into a
# temporary directory. The archive must match its one line in SHA256SUMS;
# SHA256SUMS must carry a good signature from the release key when the
# release has SHA256SUMS.asc and gpg holds that key. Only a verified archive
# reaches vgs/: it is unpacked in a staging directory there, installed by
# its own packaging/install-system.sh and moved into place. A failure leaves
# vgs/current and ~/.local/bin/vgsh as they were. No version directory is
# removed here; `vgsh self update` prunes them.
#
# --uninstall removes the version directories, vgs/current, vgs/git and the
# link, and keeps ${XDG_CONFIG_HOME:-~/.config}/vgs,
# ${XDG_STATE_HOME:-~/.local/state}/vgs and vgs/.self.lock. It refuses while
# the running shell was started from a tree it would remove, and, unless
# --force, a vgs/git holding changes, a stash or commits no remote branch
# has.
#
# It never starts the shell, writes a service unit or edits hyprland.lua. It
# prints the line that starts VGS with Hyprland.
#
# Every refusal is one line on stderr, `install.sh: refused: <key>=<value>`,
# then English. Exit 1 for a refusal, 2 for a bad argument, 75 while another
# writer holds vgs/.self.lock, 78 below the floor.
#
# The whole script is one brace group: main's definition, then its call
# with the script's arguments. A download cut short ends inside the group,
# which bash reads as a syntax error, so it runs none of it; not even a cut
# after the word `main` runs main without its arguments.
{
main() {
  set -euo pipefail
  umask 022

  repository=vanillagreencom/vgs
  api_base=https://api.github.com
  git_url="https://github.com/$repository.git"
  # The OpenPGP fingerprint of the key that signs a release's SHA256SUMS.
  # Empty while VGS publishes no release signing key.
  release_key=""
  # The seconds and bytes each fetch may take, as bin/lib/self.js bounds a
  # curl update's: the release query, then each download.
  api_seconds=10
  download_seconds=120
  max_document=$((1024 * 1024))
  max_archive=$((128 * 1024 * 1024))
  max_sums=$((64 * 1024))
  # curl's protocol for every fetch and redirect, and the prefix every
  # asset URL must carry.
  proto="=https"
  scheme="https://"

  # The floor, one row per tool: the name a refusal carries, the version it
  # needs (`present`: any version the pattern reads), the extended regex
  # whose first group reads the version from the probe's stdout, and the
  # probe. The rows repeat bin/vgsh's preflight_floor, whose figures
  # docs/architecture/runtime.md § Process states, and add flock, a required
  # row of config/requirements.json. Hyprland is probed through its binary,
  # which answers with no compositor running; bin/vgsh asks the running
  # compositor through hyprctl. floor_check runs every probe under a private
  # XDG_RUNTIME_DIR, which the binary needs even for --version, so a shell
  # with no login session reads the true floor. scripts/test-install-sh.sh
  # fails when a row drifts from those sources.
  floor='
quickshell 0.3.1   ^Quickshell[[:space:]]([0-9]+(\.[0-9]+)*)                                  qs --version
hyprland   0.56    ^Hyprland[[:space:]]([0-9]+(\.[0-9]+)*)                                    Hyprland --version
node       18      ^v([0-9]+(\.[0-9]+)*)                                                       node --version
python3    present ^Python[[:space:]]([0-9]+(\.[0-9]+)*)                                       python3 --version
git        present ^git[[:space:]]version[[:space:]]([0-9]+(\.[0-9]+)*)                         git --version
flock      present ^flock[[:space:]]from[[:space:]]util-linux[[:space:]]([0-9]+(\.[0-9]+)*)     flock --version
'
  # The tools a release install runs besides the floor: presence alone.
  release_tools=(curl tar gzip sha256sum)

  # The package that provides each floor tool, per primary manager. The rows
  # for node, python3, git and flock are config/requirements.json's. A
  # manager with no entry for quickshell or hyprland has no package in its
  # own repositories that meets the floor (docs/architecture/distribution.md
  # § Curl installer).
  packages='
quickshell pacman=quickshell nix=quickshell
hyprland   pacman=hyprland nix=hyprland
node       pacman=nodejs apt=nodejs dnf=nodejs xbps=nodejs emerge=net-libs/nodejs nix=nodejs
python3    pacman=python apt=python3 dnf=python3 xbps=python3 emerge=dev-lang/python nix=python3
git        pacman=git apt=git dnf=git xbps=git emerge=dev-vcs/git nix=git
flock      pacman=util-linux apt=util-linux dnf=util-linux-core xbps=util-linux emerge=sys-apps/util-linux nix=util-linux
'
  # The primary package managers, as the primary rows of
  # shell/Core/PackageManagers.js state them: id, the os-release identifiers
  # it serves, its binaries (preferred first), whether an install needs
  # root, and the install arguments before the package names, `-` where VGS
  # plans no install.
  managers='
pacman arch          pacman       root -S --needed --
apt    debian,ubuntu apt-get      root install
dnf    fedora        dnf5,dnf     root install
xbps   void          xbps-install root -S
emerge gentoo        emerge       root --ask --noreplace
nix    nixos         nix          user -
'

  refuse() { # STATUS KEY [ENGLISH...]
    local status="$1"
    printf 'install.sh: refused: %s\n' "$2" >&2
    shift 2
    if (($# > 0)); then printf '%s\n' "$@" >&2; fi
    exit "$status"
  }

  usage() {
    cat <<'EOF'
usage: install.sh [--version X.Y.Z] [--force]
       install.sh --git [--force]
       install.sh --uninstall [--force]
EOF
  }

  # True when HAVE >= NEED, compared as numbers component by component; a
  # missing component is 0, so 0.56 equals 0.56.0 and 0.10 exceeds 0.3.1.
  version_at_least() { # HAVE NEED: dotted decimal integers
    local -a have need
    local i h w
    IFS=. read -ra have <<<"$1"
    IFS=. read -ra need <<<"$2"
    for ((i = 0; i < ${#have[@]} || i < ${#need[@]}; i++)); do
      h=$((10#${have[i]:-0}))
      w=$((10#${need[i]:-0}))
      ((h > w)) && return 0
      ((h < w)) && return 1
    done
    return 0
  }

  # The value os-release(5) assigns KEY in FILE, or nothing, read as
  # PackageManagers.osReleaseValue reads it: the last assignment wins, and
  # a quoted value loses its quotes.
  os_release_value() { # FILE KEY
    local line value="" raw
    while IFS= read -r line || [[ -n $line ]]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ $line == "$2="* ]] || continue
      raw="${line#*=}"
      if ((${#raw} >= 2)) && [[ ($raw == \"*\" || $raw == \'*\') ]]; then
        if [[ ${raw:0:1} == \" ]]; then
          raw="${raw:1:${#raw}-2}"
          raw="$(sed -E 's/\\([\\"$`])/\1/g' <<<"$raw")"
        else
          raw="${raw:1:${#raw}-2}"
        fi
      fi
      value="$raw"
    done <"$1"
    printf '%s' "$value"
  }

  # Prints `<manager> <binary>` for this system's primary package manager,
  # as PackageManagers.detect picks it: the first os-release identifier, ID
  # then each ID_LIKE token, that a row's family holds while one of the
  # row's binaries is on PATH. Prints nothing when no row serves.
  primary_manager() {
    local file="" candidate token id like m family bins rest b
    local -a tokens binaries
    for candidate in /etc/os-release /usr/lib/os-release; do
      if [[ -r $candidate ]]; then file="$candidate"; break; fi
    done
    [[ -n $file ]] || return 0
    id="$(os_release_value "$file" ID)"
    like="$(os_release_value "$file" ID_LIKE)"
    read -ra tokens <<<"$id $like"
    for token in "${tokens[@]}"; do
      while read -r m family bins rest; do
        [[ -n $m && ",$family," == *",$token,"* ]] || continue
        IFS=, read -ra binaries <<<"$bins"
        for b in "${binaries[@]}"; do
          if command -v -- "$b" >/dev/null; then
            printf '%s %s\n' "$m" "$b"
            return 0
          fi
        done
      done <<<"$managers"
    done
  }

  # Prints TOOL's package for MANAGER, or fails when the table names none.
  package_for() { # TOOL MANAGER
    local tool pairs pair
    while read -r tool pairs; do
      [[ $tool == "$1" ]] || continue
      for pair in $pairs; do
        if [[ ${pair%%=*} == "$2" ]]; then
          printf '%s\n' "${pair#*=}"
          return 0
        fi
      done
    done <<<"$packages"
    return 1
  }

  # Checks the floor and EXTRA tools. On a miss, prints one refusal line
  # per tool, then why each installed tool's version could not be read,
  # then what installs the others on this system, and exits 78. A tool on
  # PATH whose probe fails or prints no version is `have=unknown` and gets
  # no install command: installing it again would not change the probe.
  #
  # Each probe runs under a private, empty XDG_RUNTIME_DIR in $tmp.
  # Hyprland --version throws before it reads its arguments when that
  # variable is unset, so a shell with no login session (su -, ssh without
  # systemd-logind, a container) would otherwise read an installed Hyprland
  # as unreadable.
  floor_check() { # EXTRA_TOOL...
    local tool need pattern probe out line have status start manager="" binary="" m family bins elevate args pkg
    local -a argv lines misses=() names=() unread=() unpackaged=()
    mkdir -m 700 -- "$tmp/runtime" || refuse 1 "runtime=failed path=$tmp/runtime"
    while read -r tool need pattern probe; do
      [[ -n $tool ]] || continue
      read -ra argv <<<"$probe"
      if ! command -v -- "${argv[0]}" >/dev/null; then
        misses+=("$tool none $need")
        continue
      fi
      status=0
      out="$(XDG_RUNTIME_DIR="$tmp/runtime" "${argv[@]}" 2>"$tmp/probe.err" </dev/null)" || status=$?
      if ((status == 0)) && [[ $out =~ $pattern ]]; then
        have="${BASH_REMATCH[1]}"
        [[ $need == present ]] || version_at_least "$have" "$need" || misses+=("$tool $have $need")
        continue
      fi
      misses+=("$tool unknown $need")
      if ((status != 0)); then
        unread+=("$tool is installed, but its version could not be read: $probe exited $status:")
      else
        unread+=("$tool is installed, but its version could not be read: $probe printed no version:")
      fi
      # The probe's last lines: stderr, else stdout.
      mapfile -t lines <"$tmp/probe.err"
      if ((${#lines[@]} == 0)) && [[ -n $out ]]; then mapfile -t lines <<<"$out"; fi
      start=$((${#lines[@]} > 5 ? ${#lines[@]} - 5 : 0))
      for line in "${lines[@]:start}"; do unread+=("  $line"); done
    done <<<"$floor"
    for tool in "$@"; do
      command -v -- "$tool" >/dev/null || misses+=("$tool none present")
    done
    ((${#misses[@]} > 0)) || return 0
    for tool in "${misses[@]}"; do
      read -r tool have need <<<"$tool"
      printf 'install.sh: refused: floor=%s have=%s need=%s\n' "$tool" "$have" "$need" >&2
      [[ $have == unknown ]] || names+=("$tool")
    done
    if ((${#unread[@]} > 0)); then printf '%s\n' "${unread[@]}" >&2; fi
    ((${#names[@]} > 0)) || exit 78
    read -r manager binary <<<"$(primary_manager)" || true
    if [[ -z $manager ]]; then
      printf 'No supported package manager found: install %s with your distribution'"'"'s package manager.\n' "${names[*]}" >&2
      exit 78
    fi
    local -a wanted=()
    for tool in "${names[@]}"; do
      if pkg="$(package_for "$tool" "$manager")"; then wanted+=("$pkg"); else unpackaged+=("$tool"); fi
    done
    while read -r m family bins elevate args; do
      [[ $m == "$manager" ]] || continue
      if ((${#wanted[@]} == 0)); then
        :
      elif [[ $args == - ]]; then
        printf 'Add these %s packages to your system configuration: %s\n' "$manager" "${wanted[*]}" >&2
      elif [[ $elevate == root ]]; then
        printf 'Install them as root: %s %s %s\n' "$binary" "$args" "${wanted[*]}" >&2
      else
        printf 'Install them: %s %s %s\n' "$binary" "$args" "${wanted[*]}" >&2
      fi
    done <<<"$managers"
    for tool in "${unpackaged[@]}"; do
      printf '%s: %s has no package VGS knows of that meets the floor; see https://github.com/%s/blob/main/docs/architecture/distribution.md#curl-installer\n' "$tool" "$manager" "$repository" >&2
    done
    exit 78
  }

  # Refuses when a system package installed VGS: /usr/bin/vgsh exists, or
  # the pacman, rpm or dpkg database holds vgs or vgs-git. A database a
  # query cannot read counts as not holding it.
  system_package() {
    local name status
    if [[ -e /usr/bin/vgsh || -L /usr/bin/vgsh ]]; then
      refuse 1 "system=package path=/usr/bin/vgsh" \
        "a system package installed VGS: update it with its package manager, or pass --force for a second, user-local copy"
    fi
    for name in vgs vgs-git; do
      if command -v pacman >/dev/null && pacman -Q -- "$name" >/dev/null 2>&1; then
        refuse 1 "system=package manager=pacman package=$name" "pass --force for a second, user-local copy"
      fi
      if command -v rpm >/dev/null && rpm -q --quiet -- "$name" 2>/dev/null; then
        refuse 1 "system=package manager=rpm package=$name" "pass --force for a second, user-local copy"
      fi
      if command -v dpkg-query >/dev/null && status="$(dpkg-query -W -f='${Status}' -- "$name" 2>/dev/null)" &&
        [[ $status == "install ok installed" ]]; then
        refuse 1 "system=package manager=dpkg package=$name" "pass --force for a second, user-local copy"
      fi
    done
  }

  # Prints `absent`, `ours` for a link this script makes, or `foreign`.
  link_state() {
    local target
    if [[ ! -e $link && ! -L $link ]]; then
      echo absent
    elif [[ -L $link ]] && target="$(readlink -- "$link")" &&
      [[ $target == "$data/current/bin/vgsh" || $target == "$data/git/bin/vgsh" ]]; then
      echo ours
    else
      echo foreign
    fi
  }

  # Takes vgs/.self.lock on descriptor 9 until this process exits, then
  # removes the staging directories a dead writer left behind.
  take_lock() {
    local dir
    mkdir -p -- "$data" 2>/dev/null && { exec 9>>"$lock"; } 2>/dev/null ||
      refuse 1 "lock=failed path=$lock"
    flock -n 9 || refuse 75 "self=busy path=$lock" "another install.sh or vgsh self update is writing $data"
    shopt -s nullglob dotglob
    for dir in "$data"/.self-update-*; do rm -rf -- "$dir"; done
    shopt -u nullglob dotglob
  }

  new_stage() {
    stage="$(mktemp -d "$data/.self-update-XXXXXX")" || refuse 1 "stage=failed path=$data"
  }

  # Points ~/.local/bin/vgsh at TARGET through a rename.
  write_link() { # TARGET
    local next="$bin_dir/.vgsh.install-$$"
    mkdir -p -- "$bin_dir" 2>/dev/null || refuse 1 "link=failed path=$bin_dir"
    rm -f -- "$next"
    if ! ln -s -- "$1" "$next" 2>/dev/null || ! mv -T -- "$next" "$link" 2>/dev/null; then
      rm -f -- "$next"
      refuse 1 "link=failed path=$link"
    fi
  }

  # Fetches URL into FILE, at most MAX bytes within SECONDS.
  fetch() { # KEY URL FILE MAX SECONDS
    local status=0
    [[ $2 == "$scheme"* ]] || refuse 1 "$1=insecure url=$2"
    curl --proto "$proto" --proto-redir "$proto" --tlsv1.2 -fsSL --max-time "$5" --max-filesize "$4" -o "$3" "$2" 2>"$tmp/curl.err" || status=$?
    ((status == 0)) || refuse 1 "$1=failed url=$2 curl=$status" "$(cat -- "$tmp/curl.err")"
  }

  # Prints the URL of asset NAME in the release, or fails.
  asset_url() { # NAME
    local name url
    while read -r name url; do
      if [[ $name == "$1" ]]; then
        printf '%s\n' "$url"
        return 0
      fi
    done <<<"$assets"
    return 1
  }

  # Prints the sha256 SUMS lists for NAME: exactly one `<hex>  <name>` or
  # `<hex> *<name>` line.
  listed_sum() { # SUMS NAME
    local line hex="" count=0 pattern='^([0-9a-f]{64}) [ *](.+)$'
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line =~ $pattern && ${BASH_REMATCH[2]} == "$2" ]]; then
        hex="${BASH_REMATCH[1]}"
        count=$((count + 1))
      fi
    done <"$1"
    ((count == 1)) || refuse 1 "checksum=unlisted name=$2 count=$count"
    printf '%s\n' "$hex"
  }

  # Checks SUMS against SHA256SUMS.asc when the release has one, gpg is on
  # PATH and holds release_key; prints why it did not otherwise. A signature
  # that is not a good one by release_key refuses.
  signature_check() { # SUMS
    local url line
    local -a field
    if ! url="$(asset_url SHA256SUMS.asc)"; then
      echo "signature=unchecked reason=no-signature"
      return 0
    fi
    if [[ -z $release_key ]]; then
      echo "signature=unchecked reason=no-release-key"
      return 0
    fi
    if ! command -v gpg >/dev/null; then
      echo "signature=unchecked reason=no-gpg"
      return 0
    fi
    if ! gpg --batch --list-keys -- "$release_key" >/dev/null 2>&1; then
      echo "signature=unchecked reason=key-not-imported key=$release_key"
      return 0
    fi
    fetch download "$url" "$tmp/SHA256SUMS.asc" "$max_sums" "$download_seconds"
    gpg --batch --status-fd 1 --verify -- "$tmp/SHA256SUMS.asc" "$1" >"$tmp/gpg.status" 2>/dev/null ||
      refuse 1 "signature=bad name=SHA256SUMS key=$release_key"
    while IFS= read -r line; do
      read -ra field <<<"$line"
      [[ ${field[0]:-} == "[GNUPG:]" && ${field[1]:-} == VALIDSIG ]] || continue
      if [[ ${field[2]} == "$release_key" || ${field[${#field[@]} - 1]} == "$release_key" ]]; then
        echo "signature=good key=$release_key"
        return 0
      fi
    done <"$tmp/gpg.status"
    refuse 1 "signature=bad name=SHA256SUMS key=$release_key" "SHA256SUMS is signed, but not by the VGS release key"
  }

  # Resolves the release (VERSION, or the newest), then sets version and
  # assets: one `<name> <url>` line per asset.
  resolve_release() {
    local url tag parsed
    if [[ -n $version ]]; then
      url="$api_base/repos/$repository/releases/tags/v$version"
    else
      url="$api_base/repos/$repository/releases/latest"
    fi
    fetch release "$url" "$tmp/release.json" "$max_document" "$api_seconds"
    parsed="$(node -e '
const fs = require("fs");
let doc;
try { doc = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.exit(1); }
if (doc === null || typeof doc !== "object" || typeof doc.tag_name !== "string" || !Array.isArray(doc.assets)) process.exit(1);
const lines = [doc.tag_name.replace(/\s/g, "?")];
for (const a of doc.assets)
    if (a !== null && typeof a.name === "string" && typeof a.browser_download_url === "string" && /^[A-Za-z0-9._+-]+$/.test(a.name) && !/\s/.test(a.browser_download_url))
        lines.push(a.name + " " + a.browser_download_url);
process.stdout.write(lines.join("\n") + "\n");
' "$tmp/release.json")" || refuse 1 "release=malformed url=$url"
    tag="${parsed%%$'\n'*}"
    assets="${parsed#*$'\n'}"
    [[ $tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]] || refuse 1 "tag=$tag reason=not-a-version"
    if [[ -n $version && ${BASH_REMATCH[1]} != "$version" ]]; then
      refuse 1 "tag=$tag want=v$version"
    fi
    version="${BASH_REMATCH[1]}"
  }

  install_release() {
    local archive="vgs-$version.tar.gz" sums_url archive_url want got target="$data/$version" unpacked
    local -a top
    if [[ -e $target || -L $target ]] && [[ -L $data/current && $(readlink -- "$data/current") == "$version" ]]; then
      echo "ok up-to-date=vgs version=$version path=$target"
      return 0
    fi
    sums_url="$(asset_url SHA256SUMS)" || refuse 1 "asset=missing name=SHA256SUMS release=v$version"
    archive_url="$(asset_url "$archive")" || refuse 1 "asset=missing name=$archive release=v$version"
    fetch download "$sums_url" "$tmp/SHA256SUMS" "$max_sums" "$download_seconds"
    fetch download "$archive_url" "$tmp/$archive" "$max_archive" "$download_seconds"
    want="$(listed_sum "$tmp/SHA256SUMS" "$archive")" || exit 1
    got="$(sha256sum -- "$tmp/$archive")" || refuse 1 "checksum=failed name=$archive"
    got="${got%% *}"
    [[ $got == "$want" ]] || refuse 1 "checksum=mismatch name=$archive want=$want got=$got"
    signature_check "$tmp/SHA256SUMS"

    take_lock
    if [[ -e $data/current && ! -L $data/current ]]; then
      refuse 1 "current=not-a-link path=$data/current" "remove it and run install.sh again"
    fi
    if [[ -e $target || -L $target ]]; then
      refuse 1 "target=exists path=$target" "remove it and run install.sh again"
    fi
    new_stage
    mkdir -- "$stage/source"
    tar -xzf "$tmp/$archive" -C "$stage/source" --no-same-owner 2>"$stage/tar.err" ||
      refuse 1 "archive=unpack name=$archive" "$(cat -- "$stage/tar.err")"
    shopt -s nullglob dotglob
    top=("$stage/source"/*)
    shopt -u nullglob dotglob
    unpacked="$stage/source/vgs-$version"
    if ((${#top[@]} != 1)) || [[ ${top[0]} != "$unpacked" || -L $unpacked || ! -d $unpacked ]]; then
      refuse 1 "archive=layout name=$archive top=${top[*]##*/}"
    fi
    [[ -f $unpacked/VERSION ]] || refuse 1 "archive=layout name=$archive version=missing"
    [[ "$(cat -- "$unpacked/VERSION"; echo .)" == "$version"$'\n.' ]] || refuse 1 "archive=version name=$archive"
    DESTDIR="$stage/tree" PREFIX=/vgs bash "$unpacked/packaging/install-system.sh" >/dev/null 2>"$stage/install.err" ||
      refuse 1 "install=failed name=$archive" "$(cat -- "$stage/install.err")"
    mv -T -- "$stage/tree/vgs/share/vgs" "$target" 2>/dev/null || refuse 1 "target=failed path=$target"
    ln -s -- "$version" "$stage/current" && mv -T -- "$stage/current" "$data/current" 2>/dev/null ||
      refuse 1 "current=failed path=$data/current"
    echo "ok installed=vgs version=$version path=$target"
  }

  install_git() {
    [[ ! -e $data/git && ! -L $data/git ]] ||
      refuse 1 "git=exists path=$data/git" "update it with vgsh self update, or remove it with install.sh --uninstall"
    take_lock
    [[ ! -e $data/git && ! -L $data/git ]] || refuse 1 "git=exists path=$data/git"
    new_stage
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
      GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS_REQUIRE=never GCM_INTERACTIVE=false \
      git -c core.hooksPath=/dev/null -c core.fsmonitor=false clone --quiet --branch main -- "$git_url" "$stage/git" 2>"$stage/git.err" ||
      refuse 1 "git=clone url=$git_url" "$(cat -- "$stage/git.err")"
    mv -T -- "$stage/git" "$data/git" 2>/dev/null || refuse 1 "git=failed path=$data/git"
    echo "ok installed=vgs git=$data/git"
  }

  # Refuses while the running shell was started from a tree under vgs/: its
  # command line, `qs -p <tree>/shell`, names the tree, as `vgsh self
  # update` reads it.
  shell_guard() {
    local rt="${XDG_RUNTIME_DIR:-/run/user/$EUID}" pid arg previous="" tree=""
    [[ -r $rt/vgsh.lock ]] || return 0
    pid="$(head -n 1 -- "$rt/vgsh.lock" 2>/dev/null)" || return 0
    [[ $pid =~ ^[0-9]+$ && -d /proc/$pid ]] || return 0
    while IFS= read -r -d '' arg; do
      if [[ $previous == -p && $arg == */shell ]]; then
        tree="${arg%/shell}"
        break
      fi
      previous="$arg"
    done <"/proc/$pid/cmdline" || true
    [[ -n $tree ]] || refuse 1 "shell=unreadable pid=$pid" "the running shell's command line names no tree; stop it before uninstalling"
    tree="$(readlink -f -- "$tree")" || return 0
    if [[ $tree == "$(readlink -f -- "$data")"/* ]]; then
      refuse 1 "shell=running pid=$pid path=$tree" "stop the shell, which runs from a tree this would remove, then run install.sh --uninstall again"
    fi
  }

  # Refuses a vgs/git that holds work found nowhere else: changes in the
  # work tree or index, a stash, or commits on HEAD or a local branch that
  # no remote-tracking branch holds.
  git_guard() {
    local out
    local -a git_in=(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$data/git" -c core.fsmonitor=false)
    [[ -d $data/git ]] || return 0
    out="$("${git_in[@]}" status --porcelain 2>&1)" ||
      refuse 1 "git=unreadable path=$data/git" "$out" "pass --force to remove it anyway"
    [[ -z $out ]] || refuse 1 "modified=$data/git" "it holds changes; pass --force to remove them"
    if "${git_in[@]}" rev-parse -q --verify refs/stash >/dev/null; then
      refuse 1 "stash=present path=$data/git" "it holds stashed changes; pass --force to remove them"
    fi
    out="$("${git_in[@]}" rev-list --count HEAD --branches --not --remotes 2>&1)" ||
      refuse 1 "git=unreadable path=$data/git" "$out" "pass --force to remove it anyway"
    ((out == 0)) || refuse 1 "unpublished=$out path=$data/git" "it holds commits no remote branch has; pass --force to remove them"
  }

  # Removes what this script installed. vgs/.self.lock stays: a writer that
  # opened it before the removal must still meet the lock this run holds.
  uninstall() {
    local state entry
    local -a rest=()
    state="$(link_state)"
    if [[ -d $data ]]; then
      take_lock
      shell_guard
      [[ $force == true ]] || git_guard
      shopt -s nullglob dotglob
      for entry in "$data"/*; do
        if [[ ${entry##*/} =~ ^(current|git|\.self-update-.*|[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
          rm -rf -- "$entry"
        elif [[ ${entry##*/} != .self.lock ]]; then
          rest+=("$entry")
        fi
      done
      shopt -u nullglob dotglob
    fi
    [[ $state != ours ]] || rm -f -- "$link"
    echo "ok uninstalled=vgs path=$data"
    if ((${#rest[@]} > 0)); then echo "kept=$data reason=not-vgs-files"; fi
    if [[ $state == foreign ]]; then echo "kept=$link reason=foreign"; fi
    echo "kept=$config_dir"
    echo "kept=$state_dir"
  }

  mode=release version="" force=false
  while (($# > 0)); do
    case "$1" in
      --version | --version=*)
        if [[ $1 == --version=* ]]; then
          version="${1#--version=}"
          shift
        else
          (($# >= 2)) || refuse 2 "argument=--version value=missing"
          version="$2"
          shift 2
        fi
        version="${version#v}"
        [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse 2 "version=$version" "--version takes X.Y.Z or vX.Y.Z"
        ;;
      --git | --uninstall)
        [[ $mode == release ]] || refuse 2 "argument=$1 conflict=--$mode"
        mode="${1#--}"
        shift
        ;;
      --force) force=true; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; refuse 2 "argument=$1" ;;
    esac
  done
  [[ -z $version || $mode == release ]] || refuse 2 "argument=--version conflict=--$mode"

  ((EUID != 0)) || refuse 1 "user=root" "install.sh installs into your home directory: run it as yourself, without sudo"
  os="$(uname -s)" || refuse 1 "os=unreadable"
  [[ $os == Linux ]] || refuse 1 "os=$os" "VGS runs on Linux, under Hyprland"
  [[ ${HOME:-} == /* ]] || refuse 1 "home=${HOME:-unset}" "HOME must be an absolute path"
  data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  [[ $data_home == /* ]] || refuse 1 "xdg-data-home=$data_home" "XDG_DATA_HOME must be an absolute path"
  data="$data_home/vgs"
  lock="$data/.self.lock"
  bin_dir="$HOME/.local/bin"
  link="$bin_dir/vgsh"
  config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/vgs"
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vgs"

  if [[ -n ${VGS_RELEASE_API:-} ]]; then
    [[ -n ${VGS_TEST_RUN:-} && $VGS_RELEASE_API == file:///* ]] ||
      refuse 1 "release-api=refused value=$VGS_RELEASE_API" "VGS_RELEASE_API is a file:// base for a test run alone"
    api_base="${VGS_RELEASE_API%/}"
    proto="=file"
    scheme="file://"
  fi

  if [[ $mode == uninstall ]]; then
    uninstall
    exit 0
  fi

  [[ $force == true ]] || system_package
  if [[ $force != true && $(link_state) == foreign ]]; then
    refuse 1 "link=foreign path=$link" "$link is not a link install.sh made: remove it, or pass --force to replace it"
  fi

  stage="" tmp=""
  trap 'rm -rf -- ${stage:+"$stage"} ${tmp:+"$tmp"}' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/vgs-install.XXXXXX")" || refuse 1 "temp=failed dir=${TMPDIR:-/tmp}"

  if [[ $mode == git ]]; then floor_check; else floor_check "${release_tools[@]}"; fi

  if [[ $mode == git ]]; then
    install_git
    write_link "$data/git/bin/vgsh"
  else
    resolve_release
    install_release
    write_link "$data/current/bin/vgsh"
  fi
  echo "command=$link"
  case ":${PATH:-}:" in
    *":$bin_dir:"*) ;;
    *) echo "path=missing dir=$bin_dir: add it to PATH to run vgsh by name" ;;
  esac
  echo "To start VGS with Hyprland, add this line to ${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua:"
  printf '  hl.on("hyprland.start", function () hl.exec_cmd("%s run") end)\n' "$link"
}
main "$@"
}
