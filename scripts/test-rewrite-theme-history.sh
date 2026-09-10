#!/usr/bin/env bash
# Exercise every refusal in scripts/rewrite-theme-history.sh, and its one
# success path, against throwaway repositories under a temporary directory.
#
# Each case pins the message clause that only its own refusal emits, plus the
# exit status. Nothing is faked: the fixtures are real git repositories with
# blobs under both imagery globs. Every refusal returns before git-filter-repo
# is invoked, so only the cases that rewrite history need the tool installed.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/rewrite-theme-history.sh"
base="$(mktemp -d)"
trap 'rm -rf -- "${base:?}"' EXIT

failures=0
cases=0
skipped=0

quiet() { "$@" >/dev/null 2>&1; }

# fixture NAME [side] -- a bare remote plus a clone of it. "side" gives the
# remote a second branch. Prints the clone's path.
fixture() {
  local name="$1" side="${2:-}" origin="$base/$1.git" work="$base/$1-work" theme
  git init -q --bare -b main "$origin"
  git init -q -b main "$work"
  git -C "$work" config user.email test@example.invalid
  git -C "$work" config user.name Test
  git -C "$work" config commit.gpgsign false
  printf '*.orig\n' > "$work/.gitignore"
  for theme in bauhaus roseofdune tokyo-night; do
    mkdir -p "$work/themes/$theme/backgrounds"
    printf 'wall-%s\n' "$theme" > "$work/themes/$theme/backgrounds/1-$theme.jpg"
    printf 'shot-%s\n' "$theme" > "$work/themes/$theme/preview.png"
    printf '{"name":"%s"}\n' "$theme" > "$work/themes/$theme/theme.json"
  done
  git -C "$work" add -A >/dev/null
  git -C "$work" commit -qm seed
  local refs=(main)
  if [[ "$side" == side ]]; then
    git -C "$work" branch -q side
    refs+=(side)
  fi
  # The deletion this series makes: every non-bundled theme loses its imagery.
  git -C "$work" rm -rq themes/tokyo-night/backgrounds themes/tokyo-night/preview.png
  git -C "$work" commit -qm "delete imagery"
  git -C "$work" push -q "$origin" "${refs[@]}"
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git clone -q "$origin" "$base/$name-clone"
  git -C "$base/$name-clone" config user.email test@example.invalid
  git -C "$base/$name-clone" config user.name Test
  git -C "$base/$name-clone" config commit.gpgsign false
  echo "$base/$name-clone"
}

# expect LABEL CLONE WANT_STATUS WANT_CLAUSE [ARG...]
expect() {
  local label="$1" clone="$2" want_status="$3" want_clause="$4"
  shift 4
  cases=$((cases + 1))
  local output status=0
  output="$( (cd "$clone" && bash "$script" "$@") 2>&1 )" || status=$?
  if [[ "$status" -ne "$want_status" ]]; then
    echo "FAIL $label: exit $status, expected $want_status" >&2
    printf '%s\n' "$output" >&2
    failures=$((failures + 1))
    return 0
  fi
  case "$output" in
    *"$want_clause"*) echo "ok $label" ;;
    *)
      echo "FAIL $label: output does not carry '$want_clause'" >&2
      printf '%s\n' "$output" >&2
      failures=$((failures + 1))
      ;;
  esac
}

# says TEXT HAYSTACK -- for check, so an output assertion reads like the others.
says() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
lacks() { ! says "$@"; }

# check LABEL COMMAND [ARG...] -- the command's own status is the verdict.
check() {
  local label="$1"
  shift
  cases=$((cases + 1))
  if "$@"; then
    echo "ok $label"
  else
    echo "FAIL $label" >&2
    failures=$((failures + 1))
  fi
}

have_filter_repo=1
command -v git-filter-repo >/dev/null || have_filter_repo=0

# --- refusals, none of which reach git-filter-repo -------------------------

clone="$(fixture unknown)"
expect "an unknown option is refused" "$clone" 2 "unknown option --nope" --nope
expect "--help prints the whole comment block" "$clone" 0 "-h, --help: print this help." --help

clone="$(fixture branch)"
git -C "$clone" checkout -qb feature/x
expect "a branch other than main is refused" "$clone" 1 "HEAD is feature/x, not main"

clone="$(fixture dirty)"
printf 'edit\n' >> "$clone/themes/bauhaus/theme.json"
expect "a dirty working tree is refused" "$clone" 1 "the working tree is not clean"

clone="$(fixture ignored)"
printf 'junk\n' > "$clone/themes/bauhaus/backgrounds/1-bauhaus.jpg.orig"
expect "an ignored leftover under themes/ is refused" "$clone" 1 "themes/ holds ignored files"

git clone -q --depth 1 "file://$base/ignored.git" "$base/shallow-clone"
expect "a shallow clone is refused" "$base/shallow-clone" 1 "this is a shallow clone"

git clone -q --single-branch "$base/ignored.git" "$base/single-clone"
expect "a clone that tracks one branch is refused" "$base/single-clone" 1 "does not track every branch"

clone="$(fixture norefspec)"
git -C "$clone" config --unset remote.origin.fetch
expect "an unreadable fetch refspec is refused" "$clone" 1 "cannot read remote.origin.fetch"

clone="$(fixture noimagery)"
git -C "$clone" rm -rq themes/bauhaus/backgrounds
git -C "$clone" commit -qm "drop bundled imagery"
expect "a bundled theme with no imagery is refused" "$clone" 1 \
  "themes/bauhaus has no backgrounds/ or no preview.png"

clone="$(fixture unreachable)"
git -C "$clone" remote set-url origin "$base/does-not-exist.git"
expect "an unreadable remote is refused" "$clone" 1 "cannot list the remote's branches"

clone="$(fixture stale side)"
expect "a second remote branch is refused" "$clone" 1 "branch(es) besides main"
# That refusal has to leave the clone alone, which is what makes re-running it
# in place the whole recovery.
check "the stale-branch refusal leaves the remote in place" \
  quiet git -C "$clone" remote get-url origin
check "the stale-branch refusal rewrites nothing" test '!' -e "$clone/.git/filter-repo"

# --- the paths that need git-filter-repo -----------------------------------

if [[ "$have_filter_repo" -eq 0 ]]; then
  echo "SKIP: git-filter-repo is not installed, so the rewriting cases did not run"
  skipped=1
else
  # A commit that cannot be signed leaves the rewrite done, the remote gone and
  # the staging copy the only place the bundled imagery still exists.
  clone="$(fixture gpg)"
  git -C "$clone" config commit.gpgsign true
  git -C "$clone" config gpg.program /bin/false
  gpg_status=0
  gpg_output="$( (cd "$clone" && bash "$script") 2>&1 )" || gpg_status=$?
  check "a failure after the rewrite exits non-zero" test "$gpg_status" -ne 0
  check "a failure after the rewrite names the state it leaves" \
    says "FAILED AFTER THE REWRITE BEGAN" "$gpg_output"
  if ! kept="$(printf '%s\n' "$gpg_output" | sed -n 's/^    \(\/.*\)$/\1/p')"; then
    echo "FAIL cannot read the staging path out of the failure banner" >&2
    failures=$((failures + 1))
    kept=""
  fi
  check "the staging copy survives a failure after the rewrite" \
    test -d "${kept%%$'\n'*}"

  if ! clone="$(fixture happy)"; then
    echo "FAIL cannot build the happy-path fixture" >&2
    exit 1
  fi
  happy_status=0
  happy_output="$( (cd "$clone" && bash "$script") 2>&1 )" || happy_status=$?
  check "a clean clone rewrites without error" test "$happy_status" -eq 0
  check "the push procedure is printed" \
    says "git push --force origin main" "$happy_output"
  # git clone leaves a small object count loose, so the before figure needs the
  # same packing the after figure does or it reports nothing for a real clone.
  check "the before figure counts the clone it measured" \
    lacks "size-pack before: 0 bytes" "$happy_output"
  check "the bundled wallpapers are restored" \
    test -f "$clone/themes/bauhaus/backgrounds/1-bauhaus.jpg"
  # The size the banner prints counts packed objects only, so the re-add commit
  # has to be packed by the time it is read. Loose objects left behind are the
  # difference between the reported figure and what the clone weighs.
  if ! loose="$(git -C "$clone" count-objects -v | sed -n 's/^count: //p')"; then
    echo "FAIL cannot count the clone's loose objects" >&2
    failures=$((failures + 1))
    loose=-1
  fi
  check "the reported size counts the re-add commit" test "$loose" -eq 0
  check "the restore does not nest the wallpapers" \
    test '!' -e "$clone/themes/bauhaus/backgrounds/backgrounds"
  # Nothing but the bundled themes keeps imagery anywhere in history.
  surviving=""
  while read -r sha; do
    surviving+="$(git -C "$clone" ls-tree -r --name-only "$sha")"$'\n'
  done < <(git -C "$clone" log --all --pretty=%H)
  left=0
  while IFS= read -r path; do
    case "$path" in themes/tokyo-night/backgrounds/*|themes/tokyo-night/preview.png) left=$((left + 1)) ;; esac
  done <<< "$surviving"
  check "no non-bundled imagery survives in history" test "$left" -eq 0

  expect "a second run in the same clone is refused" "$clone" 1 "carries the re-add commit"

  # The same marker with no re-add commit is the opposite state and needs the
  # opposite advice, so it must not be reported as "just push".
  git -C "$clone" rm -rq themes/bauhaus/backgrounds themes/bauhaus/preview.png \
    themes/roseofdune/backgrounds themes/roseofdune/preview.png
  git -C "$clone" commit -qm "simulate a rewrite that never re-added"
  expect "a rewritten clone with no re-add commit is sent to a fresh clone" \
    "$clone" 1 "never made the re-add commit"
fi

echo "test-rewrite-theme-history: $((cases - failures))/$cases check(s) passed, skipped=$skipped"
test "$failures" -eq 0
