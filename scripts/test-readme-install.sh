#!/usr/bin/env bash
# Controls for the host side of scripts/readme-install.sh. The containers
# themselves are the runner's own hand run; here stub podman, git and curl
# on a PATH of only the tools the runner calls answer instead. Each row
# runs a copy of the runner in a scratch tree holding the files
# scripts/check-readme.js reads, and pins the exit status and the keyed
# first line. The rows: an unknown argument, a README check-readme refuses,
# no podman, an AUR probe that fails or answers no result list, a release
# probe that fails, a curl download that fails with no output, and the two
# AUR fences in two containers. Under STUB_PODMAN_WORKS the stub podman runs
# each `exec` on the host in a scratch home, where every command the README
# names is a stub, and records each container it starts and each command it
# runs. The controls: a runner copy that reads a failed release probe as an
# answer must fail the release-probe row, and one without pipefail must
# fail the download row.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)"
tmp="$(mktemp -d)" || { echo "test-readme-install: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $tmp && ! -L $tmp ]] || { echo "test-readme-install: scratch=not-a-directory value=[$tmp]" >&2; exit 1; }
tmp="$(cd -- "$tmp" && pwd -P)"
trap 'rm -rf -- "${tmp:?}"' EXIT
failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# --- the tree ---------------------------------------------------------------
tree="$tmp/tree"
files=(README.md VERSION bin/vgsh bin/vgsh-scan install.sh docs/architecture/runtime.md
  packaging/arch/vgs/PKGBUILD packaging/arch/vgs-git/PKGBUILD
  scripts/readme-install.sh scripts/check-readme.js scripts/preflight-floor.js)
for dir in "$repo"/shell/plugins/*/; do
  dir="${dir%/}"
  [[ -f $dir/manifest.json ]] || continue
  files+=("shell/plugins/${dir##*/}/manifest.json")
  [[ ! -f $dir/README.md ]] || files+=("shell/plugins/${dir##*/}/README.md")
done
for rel in "${files[@]}"; do
  mkdir -p -- "$tree/$(dirname -- "$rel")"
  cp -p -- "$repo/$rel" "$tree/$rel"
done
version="$(<"$tree/VERSION")"

# --- PATH -------------------------------------------------------------------
# The farm holds only what the runner and check-readme call; stubs/ adds
# podman, git and curl, each answering from STUB_* in its environment.
farm="$tmp/farm"
stubs="$tmp/stubs"
mkdir -p -- "$farm" "$stubs"
for tool in bash env readlink dirname mkdir rm cat tail sed grep python3 yes timeout chmod; do
  found="$(command -v -- "$tool")" || { echo "test-readme-install: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$(readlink -f -- "$found")" "$farm/$tool"
done
# node on PATH may be a version-manager shim that reads the developer's own
# configuration; the farm links the binary it resolves to.
node_bin="$(node -e 'process.stdout.write(process.execPath)')" || { echo "test-readme-install: status=not-measured missing=node"; exit 77; }
ln -s -- "$node_bin" "$farm/node"
cat >"$stubs/podman" <<'EOF'
#!/usr/bin/env bash
# Without STUB_PODMAN_WORKS every image is absent and every pull fails.
[[ -n ${STUB_PODMAN_WORKS:-} ]] || exit 1
case "$1" in
  image|commit|rm|rmi) exit 0 ;;
  run)
    shift
    [[ $1 == -d ]] || exit 0
    printf 'start %s\n' "$3" >>"$STUB_RECORD"
    exit 0 ;;
  exec)
    while [[ $1 != -- ]]; do shift; done
    container="$2"
    shift 2
    [[ $1 != install ]] || exit 0
    printf 'exec %s %s\n' "$container" "${@: -1}" >>"$STUB_RECORD"
    cd -- "$STUB_HOME" && exec "$@" ;;
  *) exit 64 ;;
esac
EOF
cat >"$stubs/curl" <<'EOF'
#!/usr/bin/env bash
# The AUR probe answers from STUB_CURL_*; a README download from
# STUB_FETCH_EXIT, failing with no output, else an empty script.
if [[ $* == *aur.archlinux.org* ]]; then
  [[ -z ${STUB_CURL_EXIT:-} ]] || { echo "curl: (7) stub failure" >&2; exit "$STUB_CURL_EXIT"; }
  printf '%s\n' "$STUB_CURL_OUT"
  exit 0
fi
exit "${STUB_FETCH_EXIT:-0}"
EOF
cat >"$stubs/yay" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
home="$tmp/home"
mkdir -p -- "$home/vgs/bin"
cat >"$home/vgs/bin/vgsh" <<'EOF'
#!/usr/bin/env bash
echo 'vgsh: refused: preflight=hyprland have=unknown need=0.56' >&2
exit 78
EOF
chmod 755 "$home/vgs/bin/vgsh"
record="$tmp/record"
cat >"$stubs/git" <<'EOF'
#!/usr/bin/env bash
[[ -z ${STUB_GIT_EXIT:-} ]] || { echo "fatal: stub failure" >&2; exit "$STUB_GIT_EXIT"; }
printf '%s' "${STUB_GIT_OUT:-}"
EOF
chmod 755 "$stubs"/*

# row NAME WANT_EXIT WANT_FIRST PATH [VAR=VALUE...] -- ARGS...
# Runs TREE's runner under env -i with PATH and the variables.
row() {
  local name="$1" want_exit="$2" want_first="$3" path="$4" status=0 out first
  shift 4
  local vars=()
  while [[ $1 != -- ]]; do vars+=("$1"); shift; done
  shift
  : >"$record"
  out="$(env -i PATH="$path" HOME="$tmp" LC_ALL=C STUB_RECORD="$record" STUB_HOME="$home" "${vars[@]}" "$tree/scripts/readme-install.sh" "$@" 2>&1)" || status=$?
  first="${out%%$'\n'*}"
  # WANT_FIRST is a glob pattern: only the timing row uses `*`.
  # shellcheck disable=SC2053
  if [[ $status == "$want_exit" && $first == $want_first ]]; then
    ok "$name"
  else
    fail "$name: exit=$status want=$want_exit first=[$first] want=[$want_first]"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
}

stubbed="$stubs:$farm"
empty_aur='{"results":[]}'

row "an unknown argument is refused" 2 "readme-install: refused: argument=--bogus" "$stubbed" -- --bogus
row "no podman is not measured" 77 "readme-install: status=not-measured reason=podman-missing" "$farm" --
row "a failed AUR probe is not measured" 77 "readme-install: status=not-measured reason=aur-probe package=vgs" "$stubbed" STUB_CURL_EXIT=7 --
row "an AUR answer with no result list is not measured" 77 "readme-install: status=not-measured reason=aur-probe package=vgs" "$stubbed" STUB_CURL_OUT='{}' --
curl_url='https://raw.githubusercontent.com/vanillagreencom/vgs/main/install.sh'
git_line="$(grep -n -F -x -- "curl -fsSL $curl_url | bash -s -- --git" "$tree/README.md")" || { echo "test-readme-install: readme=no-git-line"; exit 1; }
git_line="${git_line%%:*}"
download_first="readme-install: refused: line=$git_line exit=22 command=curl -fsSL $curl_url | bash -s -- --git"
both_aur='{"results":[{"Name":"vgs"},{"Name":"vgs-git"}]}'
row "a curl download that fails with no output is refused" 1 "$download_first" "$stubbed" STUB_PODMAN_WORKS=1 STUB_CURL_OUT="$empty_aur" STUB_FETCH_EXIT=22 --
aur_first="$(grep -n -F -x -- "yay -S vgs" "$tree/README.md")" || { echo "test-readme-install: readme=no-yay-line"; exit 1; }
row "the published AUR commands run" 77 "readme-install: ok line=${aur_first%%:*} channel=aur exit=0 seconds=*" "$stubbed" STUB_PODMAN_WORKS=1 STUB_CURL_OUT="$both_aur" --
if grep -q -E '^start vgs-readme-install-1\.[0-9]+$' "$record" && grep -q -E '^start vgs-readme-install-2\.[0-9]+$' "$record" &&
  grep -q -E '^exec vgs-readme-install-1\.[0-9]+ yay -S vgs$' "$record" && grep -q -E '^exec vgs-readme-install-2\.[0-9]+ yay -S vgs-git$' "$record"; then
  ok "the two AUR fences run in two containers"
else
  fail "the two AUR fences run in two containers"
  sed 's/^/        /' "$record"
fi
row "a failed release probe is not measured" 77 "readme-install: status=not-measured reason=release-probe tag=v$version" "$stubbed" STUB_CURL_OUT="$empty_aur" STUB_GIT_EXIT=128 --

cp -p -- "$tree/README.md" "$tmp/README.md.orig"
python3 - "$tree/README.md" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = ", python3 and git."
if text.count(old) != 1:
    raise SystemExit(f"README edit: matches={text.count(old)}")
path.write_text(text.replace(old, " and git."))
PY
row "a README check-readme refuses is refused" 1 "readme-install: refused: check-readme=refused" "$stubbed" --
cp -p -- "$tmp/README.md.orig" "$tree/README.md"

# --- controls ---------------------------------------------------------------
# control NAME OLD NEW ROW_ARGS...: the row, run on a runner copy with OLD
# replaced by NEW once, must fail.
control() {
  local name="$1" old="$2" new="$3" before=$failures
  shift 3
  cp -p -- "$tree/scripts/readme-install.sh" "$tmp/readme-install.sh.orig"
  python3 - "$tree/scripts/readme-install.sh" "$old" "$new" <<'PY'
import pathlib, sys
path, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
if text.count(old) != 1:
    raise SystemExit(f"runner edit: matches={text.count(old)}")
path.write_text(text.replace(old, new))
PY
  row "$@" >/dev/null
  cp -p -- "$tmp/readme-install.sh.orig" "$tree/scripts/readme-install.sh"
  if ((failures == before + 1)); then
    failures=$before
    ok "control: $name fails its row"
  else
    failures=$((before + 1))
    fail "control: $name passed its row"
  fi
}
# The OLD and NEW texts are the runner's own shell, never expanded here.
# shellcheck disable=SC2016
control "a runner that reads a failed release probe as an answer" \
  '2>&1)" ||
        not_measured "release-probe tag=${1#release:}" "$out"' '2>&1)" || true' \
  "release probe" 77 "readme-install: status=not-measured reason=release-probe tag=v$version" "$stubbed" STUB_CURL_OUT="$empty_aur" STUB_GIT_EXIT=128 --
# shellcheck disable=SC2016
control "a runner without pipefail" 'bash -o pipefail -c "$2"' 'bash -c "$2"' \
  "download" 1 "$download_first" "$stubbed" STUB_PODMAN_WORKS=1 STUB_CURL_OUT="$empty_aur" STUB_FETCH_EXIT=22 --

if ((failures > 0)); then
  echo "test-readme-install: failed=$failures"
  exit 1
fi
echo "test-readme-install: ok"
