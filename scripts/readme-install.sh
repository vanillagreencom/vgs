#!/usr/bin/env bash
# Run the commands of README.md § Install, as written, in clean containers.
#
# Usage: scripts/readme-install.sh
#
# The release check of the README's install section, run by hand like
# scripts/fedora-container.sh: docs/architecture/install-guide.md § The runner.
# The commands come from `node scripts/check-readme.js --commands` alone, so
# a README that check refuses is refused here first. Each command runs as
# the README prints it, so it installs from GitHub, the AUR and the Nix
# flake at their published state, never from this working tree: the curl
# and checkout commands read `main`.
#
# A command whose needs are unpublished is not measured: `release:<tag>`
# while `git ls-remote --tags` of the repository has no such tag, and
# `aur:<pkg>` while the AUR RPC info query finds no such package. The rest
# of its block still runs. A probe that fails is not measured either, never
# read as unpublished.
#
# Each bash fence of the section runs top to bottom in one fresh container,
# in the home directory, with an empty line on stdin for every prompt, so
# each prompt takes its default answer. A command runs under pipefail, so a
# `curl ... | bash` whose download fails fails, though bash exits 0 on the
# empty script. Alternatives the README offers, such as the two AUR
# packages, sit in separate fences:
#   - aur, curl and checkout commands in an archlinux:latest image prepared
#     once per run: base-devel, git, sudo, quickshell, hyprland, nodejs and
#     python, the unprivileged user `user` with passwordless sudo inside the
#     container alone, and yay built from the AUR's yay-bin when an aur
#     command is measured. The commands run as `user`, with HOME and the
#     XDG_RUNTIME_DIR a login session sets: Hyprland --version, which
#     install.sh's floor runs, aborts without it.
#   - nix commands as root in docker.io/nixos/nix:2.35.2 with flakes on and
#     scripts/test-flake.sh's store volume, so the two share downloads.
# A command passes on exit 0. A command whose vgsh arguments are `run`
# passes when it exits 78 refusing `preflight=hyprland`, since no Hyprland
# runs in a container: with `have=unknown` in the Arch image, where hyprctl
# is installed, and `have=none` in the Nix image, whose package leaves
# Hyprland to the session. Quickshell's row comes first in the floor, so
# that refusal proves the installed Quickshell met it.
#
# Each command is ended after `command_seconds`, a bound for a prompt the
# empty answers do not satisfy, not a budget. On 2026-09-29, with podman
# 6.1.2 on the owner's workstation, the slowest command this script
# measured took 5 s: the checkout's `git clone` and the curl `--git`
# install. A yay build and install of the AUR package shellcheck-bin in the
# same image, with the same empty answers, took under 20 s.
#
# Nothing runs against the host's packages, /etc or the live session. The
# script writes under this repository's tmp/ only: tmp/readme-install.<pid>/
# holds the logs and is removed on exit, and tmp/readme-install-cache/ holds
# the prepared image's pacman downloads, kept so a rerun downloads no
# package it already has. The prepared image and every container are
# removed on exit.
#
# Output, one keyed line each: `readme-install: ok line=<n> channel=<c>
# exit=<status> seconds=<n>` per passing command, and last `readme-install:
# ok commands=<n>`, exit 0. `readme-install: refused: <key>=<value> ...`
# first, then the command's output, exit 1: a command failed, or
# check-readme refused the README. `readme-install: status=not-measured
# reason=<key> ...`, exit 77: podman-missing, image-pull, container-setup,
# container-start, release-probe, aur-probe, or `unpublished` with the
# command's line and needs, one line each and then a count; that is not a
# pass. Exit 2: an argument.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)"
arch_image='docker.io/library/archlinux:latest'
nix_image='docker.io/nixos/nix:2.35.2'
nix_volume='vgs-validate-nix-2.35.2'
repo_url='https://github.com/vanillagreencom/vgs'
command_seconds=1200

refuse() { # STATUS KEY [DETAIL...]
  local status="$1"
  printf 'readme-install: refused: %s\n' "$2"
  shift 2
  [[ $# -eq 0 ]] || printf '%s\n' "$@"
  exit "$status"
}
not_measured() { # REASON [DETAIL...]
  printf 'readme-install: status=not-measured reason=%s\n' "$1"
  shift
  [[ $# -eq 0 ]] || printf '%s\n' "$@"
  exit 77
}

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,64{s/^# \{0,1\}//;p}' "$self"; exit 0 ;;
  *) refuse 2 "argument=$1" ;;
esac
[[ $# -le 1 ]] || refuse 2 "argument=$2"

commands_out="$(node "$repo/scripts/check-readme.js" --commands)" || refuse 1 "check-readme=refused" "$commands_out"
# One tab-separated row per command: block, line, channel, needs, vgsh
# arguments (`-` for none), command.
rows_out="$(node -e '
for (const line of require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean)) {
    const c = JSON.parse(line);
    console.log([c.block, c.line, c.channel, c.needs, c.vgsh === null ? "-" : c.vgsh, c.command].join("\t"));
}' <<<"$commands_out")" || refuse 1 "commands=unreadable" "$commands_out"
mapfile -t rows <<<"$rows_out"
[[ ${#rows[@]} -gt 0 && -n ${rows[0]} ]] || refuse 1 "commands=none" "check-readme printed no command"

command -v podman >/dev/null 2>&1 || not_measured podman-missing "install podman to run the README's commands in containers"

scratch="$repo/tmp/readme-install.$$"
cache="$repo/tmp/readme-install-cache"
prepared="localhost/vgs-readme-install:$$"
containers=()
prepared_made=false
cleanup() {
  local name
  for name in "${containers[@]}"; do podman rm -f -t 0 -- "$name" >/dev/null 2>&1 || true; done
  [[ $prepared_made == false ]] || podman rmi -f -- "$prepared" >/dev/null 2>&1 || true
  rm -rf -- "$scratch" 2>/dev/null || podman unshare rm -rf -- "$scratch"
}
trap cleanup EXIT
rm -rf -- "$scratch"
mkdir -p -- "$scratch" "$cache"

# Whether each needs value is published: `yes` or `no`.
declare -A published=()
probe() { # NEEDS
  local out
  case "$1" in
    none) published[$1]=yes ;;
    release:*)
      out="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags -- "$repo_url" "refs/tags/${1#release:}" 2>&1)" ||
        not_measured "release-probe tag=${1#release:}" "$out"
      if [[ -n $out ]]; then published[$1]=yes; else published[$1]=no; fi ;;
    aur:*)
      out="$(curl -fsS --max-time 20 "https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=${1#aur:}" 2>&1)" ||
        not_measured "aur-probe package=${1#aur:}" "$out"
      out="$(node -e '
const [answer, name] = [JSON.parse(process.argv[1]), process.argv[2]];
if (!Array.isArray(answer.results)) throw new Error("no results list");
console.log(answer.results.some(r => r.Name === name) ? "yes" : "no");' "$out" "${1#aur:}" 2>&1)" ||
        not_measured "aur-probe package=${1#aur:}" "$out"
      published[$1]="$out" ;;
    *) refuse 1 "needs=$1" "check-readme printed a needs value this runner does not know" ;;
  esac
}

# Each block's image, `nix` or `arch`; a fence that mixes them is refused
# before anything runs.
declare -A block_image=()
with_yay=false
for row in "${rows[@]}"; do
  IFS=$'\t' read -r block line channel needs vgsh command <<<"$row"
  image=arch
  [[ $channel != nix ]] || image=nix
  [[ ${block_image[$block]:-$image} == "$image" ]] ||
    refuse 1 "block=mixed line=$line channel=$channel" "a fence mixes nix commands with others, which run in another image"
  block_image[$block]="$image"
  [[ -v published[$needs] ]] || probe "$needs"
  [[ $channel != aur || ${published[$needs]} != yes ]] || with_yay=true
done

pull() { # IMAGE
  local out
  podman image exists "$1" && return 0
  out="$(podman pull -q "$1" 2>&1)" || not_measured "image-pull image=$1" "$out"
}

# The Arch image every aur, curl and checkout block starts from, made once.
prepare_arch() {
  [[ $prepared_made == false ]] || return 0
  pull "$arch_image"
  cat >"$scratch/prepare.sh" <<'PREPARE'
#!/usr/bin/env bash
# Runs as root in the preparing container. Argument: whether to build yay.
set -euo pipefail
with_yay="$1"
# The cache is the host's tmp/readme-install-cache, and root here is the
# host user, so pacman downloads as root.
sed -i 's/^DownloadUser/#DownloadUser/' /etc/pacman.conf
if grep -q '^DownloadUser' /etc/pacman.conf; then echo 'pacman.conf keeps DownloadUser' >&2; exit 1; fi
pacman -Syu --noconfirm --needed base-devel git sudo quickshell hyprland nodejs python
rm -rf /var/cache/pacman/pkg/download-*
useradd -m -u 1000 user
printf 'user ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/user
chmod 440 /etc/sudoers.d/user
if [[ $with_yay == true ]]; then
  runuser -u user -- bash -c 'cd && git clone -q https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm && cd && rm -rf yay-bin'
fi
PREPARE
  chmod 755 "$scratch/prepare.sh"
  local name="vgs-readme-install-prepare.$$"
  containers+=("$name")
  podman run --name "$name" -v "$scratch/prepare.sh:/prepare.sh:ro" -v "$cache:/var/cache/pacman/pkg" \
    "$arch_image" /prepare.sh "$with_yay" >"$scratch/prepare.log" 2>&1 ||
    not_measured "container-setup image=$arch_image" "$(tail -n 20 -- "$scratch/prepare.log")"
  podman commit -q -- "$name" "$prepared" >/dev/null || not_measured "container-setup step=commit"
  prepared_made=true
  podman rm -f -t 0 -- "$name" >/dev/null
}

measured=0
unpublished=()
current_block=""
container=""
user=""
want_have=""
run_block_start() { # BLOCK
  local image
  if [[ ${block_image[$1]} == nix ]]; then
    pull "$nix_image"
    image="$nix_image" user=root want_have=none
  else
    prepare_arch
    image="$prepared" user=user want_have=unknown
  fi
  container="vgs-readme-install-$1.$$"
  containers+=("$container")
  local run_args=(-d --name "$container")
  [[ ${block_image[$1]} != nix ]] || run_args+=(-v "$nix_volume:/nix" -e 'NIX_CONFIG=experimental-features = nix-command flakes')
  podman run "${run_args[@]}" "$image" sleep infinity >/dev/null 2>"$scratch/start.log" ||
    not_measured "container-start image=$image" "$(cat -- "$scratch/start.log")"
  # A login session's runtime directory, which Hyprland --version needs.
  [[ $user == root ]] || podman exec -- "$container" install -d -m 700 -o user -g user /run/user/1000 >/dev/null 2>"$scratch/start.log" ||
    not_measured "container-setup step=runtime-dir" "$(cat -- "$scratch/start.log")"
}

for row in "${rows[@]}"; do
  IFS=$'\t' read -r block line channel needs vgsh command <<<"$row"
  if [[ ${published[$needs]} != yes ]]; then
    unpublished+=("line=$line needs=$needs")
    continue
  fi
  if [[ $block != "$current_block" ]]; then
    [[ -z $container ]] || podman rm -f -t 0 -- "$container" >/dev/null
    run_block_start "$block"
    current_block="$block"
  fi
  home="/home/$user" runtime=/run/user/1000
  [[ $user != root ]] || home=/root runtime=/run/user/0
  log="$scratch/line-$line.log"
  started=$SECONDS
  status=0
  podman exec --user "$user" --workdir "$home" -e HOME="$home" -e XDG_RUNTIME_DIR="$runtime" -- "$container" \
    bash -c 'yes "" | timeout "$1" bash -o pipefail -c "$2"' _ "$command_seconds" "$command" >"$log" 2>&1 || status=$?
  seconds=$((SECONDS - started))
  if [[ $vgsh == run ]]; then
    grep -q -E "^vgsh: refused: preflight=hyprland have=$want_have need=" -- "$log" && [[ $status -eq 78 ]] ||
      refuse 1 "line=$line exit=$status want=78-preflight=hyprland-have=$want_have command=$command" "$(tail -n 40 -- "$log")"
  elif [[ $status -eq 124 ]]; then
    refuse 1 "line=$line timeout=$command_seconds command=$command" "$(tail -n 40 -- "$log")"
  else
    [[ $status -eq 0 ]] || refuse 1 "line=$line exit=$status command=$command" "$(tail -n 40 -- "$log")"
  fi
  echo "readme-install: ok line=$line channel=$channel exit=$status seconds=$seconds"
  measured=$((measured + 1))
done

if [[ ${#unpublished[@]} -gt 0 ]]; then
  for entry in "${unpublished[@]}"; do echo "readme-install: status=not-measured reason=unpublished $entry"; done
  echo "readme-install: status=not-measured measured=$measured unpublished=${#unpublished[@]}"
  exit 77
fi
echo "readme-install: ok commands=$measured"
