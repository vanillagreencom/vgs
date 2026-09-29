#!/usr/bin/env bash
# Controls for `vgsh self status [--json]` and `vgsh self update`: one tree
# per install method, each a copy under $tmp, never this repository's own
# checkout. A checkout clones a local bare repository; a curl install is a
# versioned directory under a fixture XDG_DATA_HOME with a `current` link; a
# package tree is owned by a stub pacman under a fixture Arch os-release,
# bound over /etc/os-release under `unshare -rm`; a Nix tree lies under a
# fixture NIX_STORE_DIR. The newest release is a local release fixture
# served on 127.0.0.1, and main's commit for vgs-git comes from the bare
# repository through the fixture home's url.insteadOf. Every row runs with a
# PATH of the tools vgsh, its judges and the installer call, and no real
# package manager. Expected values come from the fixtures' own git and
# files, never from vgsh. The controls at the end run copies of self.js
# with one rule removed.
set -euo pipefail

# shellcheck source=scripts/vgsh-rows.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/vgsh-rows.sh"

unshare_bin="$(command -v unshare)" || { echo "test-vgsh-self: status=not-measured missing=unshare"; exit 77; }
"$unshare_bin" -rm true 2>/dev/null || { echo "test-vgsh-self: status=not-measured missing=user-namespaces"; exit 77; }
mount_bin="$(command -v mount)" || { echo "test-vgsh-self: status=not-measured missing=mount"; exit 77; }

# The rows' PATH: stubs first, then the tools bin/vgsh, bin/lib/self.js,
# bin/vgsh-pkg and packaging/install-system.sh call.
stubs="$tmp/stubs"; tools="$tmp/tools"; mkdir -p "$stubs" "$tools"
for tool in bash sh readlink dirname mkdir flock awk git mktemp mv rm head cat setsid timeout env tar gzip python3 cp ln sed; do
  tool_bin="$(command -v "$tool")" || { echo "test-vgsh-self: status=not-measured missing=$tool"; exit 77; }
  ln -s -- "$tool_bin" "$tools/$tool"
done
ln -s -- "$node_bin" "$tools/node"
INST_PATH="$stubs:$tools"; export INST_PATH

version_text="0.1.0"
release="0.2.0"
cfg="$tmp/cfg-self"
data="$tmp/data"

# Install source DIR's tree with the shared installer and move its runtime
# tree to TARGET, as every channel lays it out.
install_tree() { # SOURCE TARGET
  local stage
  stage="$(mktemp -d "$tmp/stage.XXXXXX")"
  DESTDIR="$stage" PREFIX=/p TMPDIR="$tmp" bash "$1/packaging/install-system.sh" >/dev/null
  mkdir -p "$(dirname -- "$2")"
  mv -T -- "$stage/p/share/vgs" "$2"
}

# The release fixture: the GitHub API's latest-release document and its two
# assets, served from $www on 127.0.0.1. The server writes its port once it
# listens; the EXIT trap stops it.
www="$tmp/www"; mkdir -p "$www/dl" "$www/repos/vanillagreencom/vgs/releases"
ready="$tmp/www-port"
python3 -c '
import functools, http.server, os, sys
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=sys.argv[2]))
with open(sys.argv[1] + ".part", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(sys.argv[1] + ".part", sys.argv[1])
server.serve_forever()
' "$ready" "$www" </dev/null >/dev/null 2>&1 &
www_pid=$!
trap 'kill "$www_pid" 2>/dev/null || true; rm -rf -- "${tmp:?}"' EXIT
for _ in $(seq 1 100); do
  [[ -s $ready ]] && break
  sleep 0.1 # the server binds in its own process; poll for its port file
done
port="$(cat -- "$ready" 2>/dev/null)" || port=""
[[ $port =~ ^[0-9]+$ ]] || { echo "test-vgsh-self: release-server=not-listening" >&2; exit 1; }
api="http://127.0.0.1:$port"
archive="vgs-$release.tar.gz"
source_tree "$tmp/rel/vgs-$release" "$release"
tar -C "$tmp/rel" -czf "$www/dl/$archive" "vgs-$release"
good_sum="$(sha256sum "$www/dl/$archive" | cut -d' ' -f1)"
printf '%s  %s\n' "$good_sum" "$archive" >"$www/dl/SHA256SUMS"
printf '{"tag_name":"v%s","assets":[{"name":"%s","browser_download_url":"%s/dl/%s"},{"name":"SHA256SUMS","browser_download_url":"%s/dl/SHA256SUMS"}]}\n' \
  "$release" "$archive" "$api" "$archive" "$api" >"$www/repos/vanillagreencom/vgs/releases/latest"
inst_env=(VGS_RELEASE_API="$api" XDG_DATA_HOME="$data" NIX_STORE_DIR="$tmp/nix/store")

status_json() { # VERSION METHOD PACKAGE CURRENT LATEST BEHIND ERROR: null for an absent value
  python3 -c 'import json, sys
v = [None if a == "null" else a for a in sys.argv[1:]]
b = {"true": True, "false": False, None: None}[v[5]]
print(json.dumps({"version": v[0], "method": v[1], "package": v[2], "current": v[3], "latest": v[4], "behind": b, "error": v[6]}, separators=(",", ":")))' "$@"
}

# Checkout. The upstream is a bare repository; git hooks are live for every
# git call from here on through the fixture home's core.hooksPath, whose
# reference-transaction hook leaves a marker when a ref moves.
seed="$tmp/seed"; source_tree "$seed" "$version_text"
g init -q "$seed"; g -C "$seed" add -A; g -C "$seed" commit -q -m one
upstream="$tmp/up.git"; g init -q --bare "$upstream"; g -C "$seed" push -q "$upstream" main
co="$tmp/co"; g clone -q "$upstream" "$co"
hooks="$tmp/hooks"; mkdir -p "$hooks"; marker="$hooks/reference-transaction.marker"
printf '#!/bin/sh\nprintf "" >"$0.marker"\n' >"$hooks/reference-transaction"; chmod +x "$hooks/reference-transaction"
g config --global core.hooksPath "$hooks"
g -C "$seed" commit -q --allow-empty -m probe; g -C "$seed" push -q "$upstream" main
rm -f -- "$marker"; g -C "$co" fetch -q
check "a plain fetch under the fixture configuration runs the reference-transaction hook" test -e "$marker"
g -C "$co" merge -q --ff-only origin/main
describe() { printf '%s.r%s.g%s' "$version_text" "$(g -C "$1" rev-list --count "$2")" "$(g -C "$1" rev-parse --short "$2")"; }
here="$(describe "$co" HEAD)"
rm -f -- "$marker"
INST_BIN="$co/bin/vgsh" inst "a current checkout is not behind" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" checkout null "$here" "$here" false null)" "" self status --json
check "status runs no git hook" test ! -e "$marker"
g -C "$seed" commit -q --allow-empty -m two; g -C "$seed" push -q "$upstream" main; rm -f -- "$marker"
there="$(describe "$seed" HEAD)"
INST_BIN="$co/bin/vgsh" inst "a checkout behind its upstream names the upstream's describe form" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" checkout null "$here" "$there" true null)" "" self status --json
check "the behind status runs no git hook either" test ! -e "$marker"
INST_BIN="$co/bin/vgsh" inst "the text form is one line of fields" "$cfg" "$rt_empty" 0 "version=$version_text method=checkout current=$here latest=$there behind=true" "" self status
check "status leaves HEAD where it was" test "$(g -C "$co" rev-parse --short HEAD)" == "${here##*.g}"

printf 'local\n' >"$co/LOCAL"
INST_BIN="$co/bin/vgsh" inst "update refuses a modified checkout" "$cfg" "$rt_empty" 1 "" "vgsh: refused: modified=$co" self update
rm -- "$co/LOCAL"
old="$(g -C "$co" rev-parse HEAD)" new="$(g -C "$upstream" rev-parse main)"
INST_BIN="$co/bin/vgsh" inst "update fast-forwards the checkout and names no running shell" "$cfg" "$rt_empty" 0 "shell=not-running" "" self update
check "update prints the commits it moved between" has_line "ok updated=vgs from=${old:0:12} to=${new:0:12}"
check "the checkout is at its upstream" test "$(g -C "$co" rev-parse HEAD)" == "$new"
check "update runs no git hook" test ! -e "$marker"
INST_BIN="$co/bin/vgsh" inst "a current checkout is up to date" "$cfg" "$rt_empty" 0 "ok up-to-date=vgs" "" self update
g -C "$co" remote set-url origin "$tmp/gone.git"
INST_BIN="$co/bin/vgsh" inst "an unreachable upstream is the report's error, exit 0" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" checkout null "$there" null null "fetch=vgs")" "$any_out" self status --json
# A stop during the checkout's fetch: status ends the fetch, returns once
# it ended and exits 128 plus the signal, printing no report. The stop
# controls are test-vgsh-outdated.sh's.
stop_git slow
INST_BIN="$co/bin/vgsh" stop_run TERM self status --json
check "TERM during a checkout's fetch ends self status with exit 143" test "$stop_status" == 143
check "self status stopped during a checkout's fetch prints no report" test ! -s "$tmp/out"
check "self status returns after the checkout's fetch TERM stopped has ended" test "$stop_ended/$stop_alive" == yes/no

# Curl: a versioned directory with a `current` link, an older version to
# prune, and the command through the link as ~/.local/bin/vgsh reaches it.
install_tree "$seed" "$data/vgs/$version_text"
install_tree "$seed" "$data/vgs/0.0.9"
ln -s -- "$version_text" "$data/vgs/current"
curl_bin="$data/vgs/current/bin/vgsh"
INST_BIN="$curl_bin" inst "a curl install compares VERSION with the newest release" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" curl null "$version_text" "$release" true null)" "" self status --json
saved_env=("${inst_env[@]}")
inst_env=(VGS_RELEASE_API="$api/elsewhere" XDG_DATA_HOME="$data")
INST_BIN="$curl_bin" inst "a repository with no release is the report's error" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" curl null "$version_text" null null "release=none repository=vanillagreencom/vgs")" "" self status --json
inst_env=(VGS_RELEASE_API="http://example.invalid" XDG_DATA_HOME="$data")
INST_BIN="$curl_bin" inst "a release API other than loopback is refused" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" curl null "$version_text" null null 'release-api=refused value="http://example.invalid"')" "$any_out" self status --json
inst_env=("${saved_env[@]}")
INST_TEST_RUN="" INST_BIN="$curl_bin" inst "a loopback release API outside a test run is refused" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" curl null "$version_text" null null "release-api=refused value=\"$api\"")" "$any_out" self status --json

printf '%s  %s\n' "$(printf '0%.0s' $(seq 1 64))" "$archive" >"$www/dl/SHA256SUMS"
INST_BIN="$curl_bin" inst "update refuses an archive its SHA256SUMS does not list" "$cfg" "$rt_empty" 1 "" \
  "vgsh: refused: checksum=mismatch name=$archive want=$(printf '0%.0s' $(seq 1 64)) got=$good_sum" self update
check "a refused update keeps the current link" test "$(readlink -- "$data/vgs/current")" == "$version_text"
check "a refused update leaves no new version and no staging directory" test -z "$(find "$data/vgs" -maxdepth 1 \( -name "$release" -o -name '.self-update-*' \))"
printf '%s  %s\n' "$good_sum" "$archive" >"$www/dl/SHA256SUMS"
exec 7>>"$data/vgs/.self.lock"; flock 7
INST_BIN="$curl_bin" inst "a held self lock refuses the update busy" "$cfg" "$rt_empty" 75 "" "vgsh: refused: self=busy path=$data/vgs/.self.lock" self update
exec 7>&-
INST_BIN="$curl_bin" inst "update installs the newest release and names no running shell" "$cfg" "$rt_empty" 0 "shell=not-running" "" self update
check "update prints the versions and the new tree" has_line "ok updated=vgs from=$version_text to=$release path=$data/vgs/$release"
check "the current link names the new version" test "$(readlink -- "$data/vgs/current")" == "$release"
check "the new tree is the release's" test "$(<"$data/vgs/$release/VERSION")" == "$release"
check "the new tree's command runs" test -x "$data/vgs/$release/bin/vgsh"
check "the tree that was current stays" test -d "$data/vgs/$version_text"
check "every other version is removed" test ! -e "$data/vgs/0.0.9"
check "no staging directory stays" test -z "$(find "$data/vgs" -maxdepth 1 -name '.self-update-*')"
INST_BIN="$curl_bin" inst "the new tree is current" "$cfg" "$rt_empty" 0 "$(status_json "$release" curl null "$release" "$release" false null)" "" self status --json
INST_BIN="$curl_bin" inst "a current curl install is up to date" "$cfg" "$rt_empty" 0 "ok up-to-date=vgs version=$release" "" self update

# A shell whose restart was refused still runs from a tree `current` no
# longer names. A stub qs started as `qs -p <tree>/shell`, as `vgsh run`
# execs it, with its pid in the instance lock, stands in for that shell.
# The update keeps its tree; the restart then refuses below the runtime
# floor, since the stub answers no version.
cat >"$stubs/qs" <<'EOF'
#!/bin/sh
[ "$1" = -p ] || exit 1
while :; do sleep 1; done
EOF
chmod +x "$stubs/qs"
running_layout() { # DATA: current 0.1.0, the running shell's 0.0.8, a stale 0.0.7
  install_tree "$seed" "$1/vgs/$version_text"
  install_tree "$seed" "$1/vgs/0.0.8"
  install_tree "$seed" "$1/vgs/0.0.7"
  ln -s -- "$version_text" "$1/vgs/current"
}
rt_running="$tmp/rt-running"; mkdir -p "$rt_running"
running_data="$tmp/data-running"; running_layout "$running_data"
"$stubs/qs" -p "$running_data/vgs/0.0.8/shell" &
fake_shell=$!
trap 'kill "$fake_shell" "$www_pid" 2>/dev/null || true; rm -rf -- "${tmp:?}"' EXIT
printf '%s\n' "$fake_shell" >"$rt_running/vgsh.lock"
inst_env=(VGS_RELEASE_API="$api" XDG_DATA_HOME="$running_data")
INST_BIN="$running_data/vgs/current/bin/vgsh" inst "an update beside a running shell restarts it, refused here below the floor" "$cfg" "$rt_running" 78 \
  "ok updated=vgs from=$version_text to=$release path=$running_data/vgs/$release" "vgsh: refused: preflight=quickshell have=unknown need=0.3.1" self update
check "the running shell's tree stays" test -d "$running_data/vgs/0.0.8/shell"
check "the tree the update ran from stays" test -d "$running_data/vgs/$version_text"
check "a tree nothing runs is removed" test ! -e "$running_data/vgs/0.0.7"
kill "$fake_shell" 2>/dev/null || true
inst_env=("${saved_env[@]}")

# Package: the tree a package recipe installs, owned by a stub pacman
# answering -Qoq and -Q as pacman(8) states, for the file and package the
# row names; any other call exits 99. The os-release fixture names Arch.
pkg_root="$tmp/pkgroot/usr/share/vgs"; install_tree "$seed" "$pkg_root"
cat >"$stubs/pacman" <<'EOF'
#!/bin/sh
case "$1 $2 $3" in
  "-Qoq $STUB_OWNED ") [ -n "$STUB_PACKAGE" ] && { echo "$STUB_PACKAGE"; exit 0; } ;;
  "-Q -- $STUB_PACKAGE") echo "$STUB_PACKAGE $STUB_PKGVER-1"; exit 0 ;;
  *) exit 99 ;;
esac
echo "error: No package owns $2" >&2
exit 1
EOF
chmod +x "$stubs/pacman"
printf 'NAME="Arch Linux"\nID=arch\n' >"$tmp/os-release"
cat >"$tmp/bound-vgsh" <<EOF
#!$tools/sh
exec $unshare_bin -rm $tools/sh -c 'mount_bin=\$1 fixture=\$2; shift 2; "\$mount_bin" --bind "\$fixture" /etc/os-release && exec "\$@"' sh $mount_bin $tmp/os-release $pkg_root/bin/vgsh "\$@"
EOF
chmod +x "$tmp/bound-vgsh"
g config --global "url.$upstream.insteadOf" https://github.com/vanillagreencom/vgs.git
main_commit="$(g -C "$upstream" rev-parse main)"
built="$version_text.r7.g${main_commit:0:7}"
inst_env+=(STUB_OWNED="$pkg_root/VERSION" STUB_PACKAGE=vgs-git STUB_PKGVER="$built")
INST_BIN="$tmp/bound-vgsh" inst "a vgs-git package built from main's commit is not behind" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" package vgs-git "$built" "$main_commit" false null)" "" self status --json
g -C "$seed" commit -q --allow-empty -m three; g -C "$seed" push -q "$upstream" main
main_commit="$(g -C "$upstream" rev-parse main)"
INST_BIN="$tmp/bound-vgsh" inst "a vgs-git package is behind once main moves" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" package vgs-git "$built" "$main_commit" true null)" "" self status --json
# A stop during the ls-remote of main, as during a checkout's fetch.
INST_BIN="$tmp/bound-vgsh" stop_run TERM self status --json
check "TERM during main's ls-remote ends self status with exit 143" test "$stop_status" == 143
check "self status stopped during main's ls-remote prints no report" test ! -s "$tmp/out"
check "self status returns after the ls-remote TERM stopped has ended" test "$stop_ended/$stop_alive" == yes/no
INST_BIN="$tmp/bound-vgsh" inst "update refuses a package and names its manager" "$cfg" "$rt_empty" 1 "" "vgsh: refused: method=package package=vgs-git manager=pacman" self update
inst_env+=(STUB_PACKAGE=vgs STUB_PKGVER="$version_text")
INST_BIN="$tmp/bound-vgsh" inst "a vgs package compares its version with the newest release" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" package vgs "$version_text" "$release" true null)" "" self status --json
inst_env+=(STUB_PACKAGE=vgs-shell)
INST_BIN="$tmp/bound-vgsh" inst "a package that is not vgs is the report's error" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" null null null null null "package=vgs-shell manager=pacman reason=not-vgs")" "" self status --json
inst_env+=(STUB_PACKAGE=)
INST_BIN="$tmp/bound-vgsh" inst "a tree no method claims is method=unknown" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" null null null null null "method=unknown path=$pkg_root")" "$any_out" self status --json
inst_env=("${saved_env[@]}")

# Nix: a tree under the fixture store.
nix_root="$tmp/nix/store/0000-vgs-$version_text/share/vgs"; install_tree "$seed" "$nix_root"
INST_BIN="$nix_root/bin/vgsh" inst "a Nix tree compares VERSION with the newest release" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" nix null "$version_text" "$release" true null)" "" self status --json
INST_BIN="$nix_root/bin/vgsh" inst "update refuses a Nix tree" "$cfg" "$rt_empty" 1 "" "vgsh: refused: method=nix" self update

for args in 'self' 'self sync' 'self status extra' 'self status --json extra' 'self update extra'; do
  read -r -a words <<<"$args"
  case "$args" in
    self) want="self-subcommand=missing" ;;
    'self sync') want="self-subcommand=sync" ;;
    *) want="argument=${words[-1]}" ;;
  esac
  INST_BIN="$co/bin/vgsh" inst "$args is a bad invocation" "$cfg" "$rt_empty" 2 "" "vgsh: refused: $want" "${words[@]}"
done

# The must-fail controls: copies of the Nix tree whose self.js lacks one
# rule, each shown to answer what the rows above refuse to accept.
self_control() { # NAME NEEDLE REPLACEMENT: sets control_bin to the copy's vgsh
  local tree_copy="$tmp/nix/store/$1-vgs/share/vgs"
  mkdir -p "$(dirname -- "$tree_copy")"
  cp -R -- "$nix_root" "$tree_copy"
  copy_with "self-$1" "$tree_copy/bin/lib/self.js" "$2" "$3"
  cp -- "$copy" "$tree_copy/bin/lib/self.js"
  control_bin="$tree_copy/bin/vgsh"
}
self_control everycheckout 'if (checkout) return ["checkout"' 'if (true) return ["checkout"'
INST_BIN="$control_bin" inst "the every-tree-a-checkout mutant calls the Nix tree a checkout" "$cfg" "$rt_empty" 0 "$any_out" "$any_out" self status --json
check "so the Nix row would fail on it" json_is "$tmp/out" 'd["method"] == "checkout"'
self_control testrun '!process.env.VGS_TEST_RUN || ' ''
INST_TEST_RUN="" INST_BIN="$control_bin" inst "the marker-blind mutant takes a loopback API outside a test run" "$cfg" "$rt_empty" 0 "$(status_json "$version_text" nix null "$version_text" "$release" true null)" "" self status --json

# The checksum control needs a curl install: the release fixture's sums are
# made wrong and a curl tree whose self.js skips the comparison installs it.
self_control checksum 'if (got !== want) refuse(' 'if (false) refuse('
mut_data="$tmp/data-mut"; mkdir -p "$mut_data/vgs"
cp -R -- "$(dirname -- "$(dirname -- "$control_bin")")" "$mut_data/vgs/$version_text"
ln -s -- "$version_text" "$mut_data/vgs/current"
printf '%s  %s\n' "$(printf '0%.0s' $(seq 1 64))" "$archive" >"$www/dl/SHA256SUMS"
inst_env=(VGS_RELEASE_API="$api" XDG_DATA_HOME="$mut_data")
INST_BIN="$mut_data/vgs/current/bin/vgsh" inst "the checksum-blind mutant installs an archive its sums do not list" "$cfg" "$rt_empty" 0 "shell=not-running" "" self update
inst_env=("${saved_env[@]}")
printf '%s  %s\n' "$good_sum" "$archive" >"$www/dl/SHA256SUMS"

# The running-tree control: a curl tree whose self.js keeps no running
# shell's tree removes it.
self_control shellblind 'if (running !== null && path.dirname(running) === real(data)) kept.push(path.basename(running));' ''
blind_data="$tmp/data-shellblind"; running_layout "$blind_data"
cp -- "$(dirname -- "$(dirname -- "$control_bin")")/bin/lib/self.js" "$blind_data/vgs/$version_text/bin/lib/self.js"
"$stubs/qs" -p "$blind_data/vgs/0.0.8/shell" &
blind_shell=$!
trap 'kill "$fake_shell" "$blind_shell" "$www_pid" 2>/dev/null || true; rm -rf -- "${tmp:?}"' EXIT
printf '%s\n' "$blind_shell" >"$rt_running/vgsh.lock"
inst_env=(VGS_RELEASE_API="$api" XDG_DATA_HOME="$blind_data")
INST_BIN="$blind_data/vgs/current/bin/vgsh" inst "the shell-blind mutant updates beside the running shell" "$cfg" "$rt_running" 78 "$any_out" "$any_out" self update
check "and removes the running shell's tree, which the row above keeps" test ! -e "$blind_data/vgs/0.0.8"
kill "$blind_shell" 2>/dev/null || true
inst_env=("${saved_env[@]}")

rows_done test-vgsh-self
