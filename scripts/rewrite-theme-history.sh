#!/usr/bin/env bash
# Drop every past revision of the theme imagery from git history, then commit the
# two bundled themes' imagery back as new content (D015 § 6).
#
# Usage: scripts/rewrite-theme-history.sh [--force]
#
# Run this ONCE, from a fresh clone, after the deletion has merged to main.
# It rewrites every commit and tag, so `main` and every `v*` tag must then be
# force-pushed and every existing clone and open branch is invalidated.
# It does not push. It prints the push commands and the new size-pack.
#
# --force: pass git-filter-repo --force, which lets it rewrite a repository that
#          is not a fresh clone. Its refusal is a safeguard; override it only
#          when the clone is disposable.
# -h, --help: print this help.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
readonly BUNDLED=(bauhaus roseofdune)
# The two globs the imagery lives under. filter-repo drops every blob matching
# them from every commit; anything outside them is untouched.
readonly IMAGERY_GLOBS=('themes/*/backgrounds/*' 'themes/*/preview.png')

force=0
for argument in "$@"; do
  case "$argument" in
    --force) force=1 ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "rewrite-theme-history: unknown option $argument" >&2; exit 2 ;;
  esac
done

if ! command -v git-filter-repo >/dev/null; then
  echo "rewrite-theme-history: git-filter-repo is not on PATH. Install it (Arch: git-filter-repo) and run again." >&2
  exit 1
fi

# A rewrite of dirty or partial history silently discards work.
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "rewrite-theme-history: the working tree is not clean. Commit or stash first; a rewrite over uncommitted changes loses them." >&2
  exit 1
fi
if [[ "$(git -C "$root" rev-parse --is-shallow-repository)" != "false" ]]; then
  echo "rewrite-theme-history: this is a shallow clone, so the rewrite would drop the history it cannot see. Clone with full history." >&2
  exit 1
fi

# The bundled imagery is re-added from the tree this script runs against, so it
# has to be there. Refuse rather than rewrite history into a set with no wallpapers.
staged=()
for theme in "${BUNDLED[@]}"; do
  directory="$root/themes/$theme"
  if [[ ! -d "$directory/backgrounds" || ! -f "$directory/preview.png" ]]; then
    echo "rewrite-theme-history: themes/$theme has no backgrounds/ or no preview.png, so the rewrite would leave the bundled themes with no imagery." >&2
    exit 1
  fi
  staged+=("themes/$theme/backgrounds" "themes/$theme/preview.png")
done

# filter-repo removes the imagery from history, including the current commit, so
# the bundled themes' files must survive outside the repository across the run.
keep="$(mktemp -d)"
trap 'rm -rf -- "${keep:?}"' EXIT
for theme in "${BUNDLED[@]}"; do
  mkdir -p -- "$keep/$theme"
  cp -a -- "$root/themes/$theme/backgrounds" "$keep/$theme/backgrounds"
  cp -a -- "$root/themes/$theme/preview.png" "$keep/$theme/preview.png"
done

before="$(git -C "$root" count-objects -vH | sed -n 's/^size-pack: //p')"

filter_args=()
for glob in "${IMAGERY_GLOBS[@]}"; do
  filter_args+=(--path-glob "$glob")
done
if [[ "$force" -eq 1 ]]; then
  filter_args+=(--force)
fi
git -C "$root" filter-repo "${filter_args[@]}" --invert-paths

for theme in "${BUNDLED[@]}"; do
  cp -a -- "$keep/$theme/backgrounds" "$root/themes/$theme/backgrounds"
  cp -a -- "$keep/$theme/preview.png" "$root/themes/$theme/preview.png"
done
git -C "$root" add -- "${staged[@]}"
git -C "$root" commit -m "feat(themes): re-add the bundled themes' imagery after the history rewrite

The imagery of every other theme now ships as a release archive (D015). This
commit restores the wallpapers and screenshot of the two themes the packages
install, as new content with no prior revisions behind it."

# filter-repo drops the remote, so the operator sets it again before pushing.
after="$(git -C "$root" count-objects -vH | sed -n 's/^size-pack: //p')"
cat <<EOF

rewrite-theme-history: done, nothing pushed.
  size-pack before: $before
  size-pack after:  $after

git-filter-repo removed the 'origin' remote. To publish the rewrite:

  git remote add origin git@github.com:vanillagreencom/vgs.git
  git push --force origin main
  git push --force --tags origin

Every existing clone and open branch is invalidated by this push.
EOF
