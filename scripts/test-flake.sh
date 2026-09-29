#!/usr/bin/env bash
# Builds flake.nix in a nix container and checks the package it ships.
#
# The suite stages the working tree's tracked and untracked files, the way a
# `github:` flake reference sees a commit, and mounts the copy read-only. The
# nix store lives in the podman or docker volume named in `volume` below, so
# later runs reuse the downloads; `podman volume rm` on that name frees it.
#
# Rows, each a keyed `ok` or `FAIL` line:
#   - `nix flake check` passes with the committed flake.lock unchanged.
#   - `nix build` succeeds. The build runs scripts/check-install-tree.sh on the
#     installed tree, so it ships the tree every other channel ships.
#   - `nix run .# -- --version` prints `vgs <VERSION>`.
#   - With only the wrapper's PATH, every command config/requirements.json
#     names resolves, and so does `qs`. `hyprctl` does not: the session
#     supplies Hyprland.
# Controls, each built from a private copy of the source:
#   - flake.nix with the requirements rows cut from the wrapped PATH must fail
#     the PATH row.
#   - packaging/install-tree.manifest with a planted entry must fail the build
#     with that entry's `install-tree=missing` line.
#
# Exit 0 when every row and control hold, 1 otherwise. Exit 77 names what
# could not run: no podman or docker, the image cannot be pulled, or the
# container cannot reach cache.nixos.org.
set -euo pipefail

repo="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd -P)"
image=docker.io/nixos/nix:2.35.2
volume=vgs-validate-nix-2.35.2

not_measured() { # REASON [DETAIL...]
  printf 'test-flake: status=not-measured reason=%s\n' "$1" >&2
  shift
  [[ $# -gt 0 ]] && printf '%s\n' "$@" >&2
  exit 77
}

if command -v podman >/dev/null; then runtime=podman
elif command -v docker >/dev/null; then runtime=docker
else not_measured no-container-runtime
fi
if ! "$runtime" image inspect "$image" >/dev/null 2>&1; then
  pull_error="$("$runtime" pull -q "$image" 2>&1 >/dev/null)" ||
    not_measured "image-unavailable runtime=$runtime image=$image" "$pull_error"
fi

tmp="$repo/tmp/test-flake.$$"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
rm -rf -- "$tmp"
mkdir -p -- "$tmp/src"

# Tracked and untracked files that exist; a deleted tracked file is left out,
# as it is from the commit that deletes it.
while IFS= read -r -d '' path; do
  [[ -e $path || -L $path ]] && printf '%s\0' "$path"
done < <(git -C "$repo" ls-files -z -co --exclude-standard) >"$tmp/files"
tar -C "$repo" --null -T "$tmp/files" -cf - | tar -C "$tmp/src" -xf -

version="$(<"$repo/VERSION")"
commands="$(python3 -c 'import json, sys; print(" ".join(row["command"] for row in json.load(open(sys.argv[1]))))' "$repo/config/requirements.json")"

status=0
"$runtime" run --rm -i \
  -v "$volume:/nix" -v "$tmp/src:/src:ro" \
  -e NIX_CONFIG='experimental-features = nix-command flakes' \
  -e VGS_VERSION="$version" -e VGS_COMMANDS="$commands" \
  "$image" bash -s <<'CONTAINER' || status=$?
set -uo pipefail
nix store info --store https://cache.nixos.org >/dev/null 2>&1 || exit 77
failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }
flags=(--no-update-lock-file --no-link --print-out-paths)

# The wrapper's PATH lines, run with an empty base PATH, answer which of the
# names resolve. Prints each name that does not.
unresolved() { # WRAPPER NAME...
  local wrapper="$1"; shift
  local lines
  lines="$(grep -v -e '^#!' -e '^exec ' "$wrapper")" || return 1
  env -i "$(command -v bash)" -c 'set -e; PATH=; eval "$1"; shift
    for name in "$@"; do command -v -- "$name" >/dev/null || echo "$name"; done' _ "$lines" "$@"
}
path_holds() { # WRAPPER: every command resolves and hyprctl does not
  local missing
  missing="$(unresolved "$1" qs $VGS_COMMANDS)" || return 1
  [[ -z $missing ]] || { echo "flake: unresolved=$(echo $missing | tr ' ' ,)"; return 1; }
  [[ $(unresolved "$1" hyprctl) == hyprctl ]] || { echo 'flake: resolved=hyprctl'; return 1; }
}

if nix flake check --no-update-lock-file path:/src >/tmp/check.log 2>&1; then ok "nix flake check passes"
else cat /tmp/check.log; fail "nix flake check passes"
fi
if out="$(nix build "${flags[@]}" path:/src 2>/tmp/build.log)"; then
  ok "nix build succeeds and checks the install tree"
  if version="$(nix run --no-update-lock-file path:/src -- --version 2>&1)" && [[ $version == "vgs $VGS_VERSION" ]]; then
    ok "nix run -- --version prints vgs $VGS_VERSION"
  else fail "nix run -- --version prints vgs $VGS_VERSION, got [$version]"
  fi
  if path_holds "$out/bin/vgsh"; then ok "the wrapper's PATH resolves qs and every requirement, not hyprctl"
  else fail "the wrapper's PATH resolves qs and every requirement, not hyprctl"
  fi
else
  cat /tmp/build.log; fail "nix build succeeds and checks the install tree"
fi

# Control: the flake with no requirements rows on the wrapped PATH.
cp -r /src /tmp/no-requirements
cut='(builtins.filter (row: !row.optional || row.packages ? nix) requirements)'
if [[ $(grep -cF -- "$cut" /tmp/no-requirements/flake.nix) != 1 ]] || ! flake="$(</src/flake.nix)"; then
  fail "control: the requirements filter appears once in flake.nix"
else
  printf '%s\n' "${flake/"$cut"/[ ]}" >/tmp/no-requirements/flake.nix
  if [[ $(</tmp/no-requirements/flake.nix) == "$flake" ]]; then fail "control: the requirements cut changed flake.nix"
  elif ! mutant="$(nix build "${flags[@]}" path:/tmp/no-requirements 2>/tmp/mutant.log)"; then
    cat /tmp/mutant.log; fail "control: the cut flake builds"
  elif [[ $(path_holds "$mutant/bin/vgsh") == "flake: unresolved=${VGS_COMMANDS// /,}" ]]; then
    ok "control: dropping the requirements fails the PATH row"
  else fail "control: dropping the requirements fails the PATH row on every requirement"
  fi
fi

# Control: a manifest entry the installer never writes.
cp -r /src /tmp/planted
echo 'f share/vgs/planted' >>/tmp/planted/packaging/install-tree.manifest
if nix build "${flags[@]}" path:/tmp/planted >/dev/null 2>/tmp/planted.log; then
  fail "control: a planted manifest entry fails the build"
elif grep -qF 'install-tree=missing entry=f share/vgs/planted' /tmp/planted.log; then
  ok "control: a planted manifest entry fails the build"
else
  cat /tmp/planted.log; fail "control: a planted manifest entry fails the build with its install-tree line"
fi

((failures == 0))
CONTAINER

case "$status" in
  0) echo 'test-flake: ok' ;;
  77) not_measured network-unreachable ;;
  *) echo "test-flake: failed status=$status"; exit 1 ;;
esac
