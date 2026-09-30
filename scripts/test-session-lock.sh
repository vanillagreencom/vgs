#!/usr/bin/env bash
# Exercise the real SessionLock owner through qml-unit. Each control changes
# a disposable core copy, keeps the matched code, and must fail this suite.
set -euo pipefail
self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo "test-session-lock: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "test-session-lock: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "test-session-lock: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# qml-unit supplies an empty environment and a private HOME to Qt.
"$repo/scripts/qml-unit.sh" "$repo/scripts/qml-tests/tst_session_lock.qml"
python3 - "$repo/shell/Core" "$TMP_ROOT" <<'PY'
import pathlib, shutil, sys
source_dir, root = map(pathlib.Path, sys.argv[1:])
source = (source_dir / "SessionLock.qml").read_text()
controls = [
    ("request", "return root.lockRequested || root.lockSecure;",
     "return (false && root.lockRequested) || root.lockSecure;"),
    ("secure", "return root.lockRequested || root.lockSecure;",
     "return root.lockRequested || (false && root.lockSecure);"),
    ("frozen", "return Object.freeze({", "return Object.assign({"),
    ("unload", "        lockContentOwner = null;",
     "        lockContentOwner = null;\n        lockRequested = false;")
]
for name, needle, replacement in controls:
    assert source.count(needle) == 1, (name, "control match count")
    changed = source.replace(needle, replacement)
    assert changed != source, (name, "control unchanged")
    target = root / name
    shutil.copytree(source_dir, target)
    path = target / "SessionLock.qml"
    assert not path.is_symlink(), (name, "control symlink")
    path.write_text(changed)
PY
for rule in request secure frozen unload; do
  status=0
  out="$("$repo/scripts/qml-unit.sh" --core "$TMP_ROOT/$rule" "$repo/scripts/qml-tests/tst_session_lock.qml" 2>&1)" || status=$?
  if [[ $status == 1 && $out == *"::session-lock::"* && $out == *"FAIL!  :"* ]]; then
    printf '  ok    session-lock control=%s exit=%s\n' "$rule" "$status"
  else
    printf '  FAIL  session-lock control=%s exit=%s\n%s\n' "$rule" "$status" "$out"
    exit 1
  fi
done
