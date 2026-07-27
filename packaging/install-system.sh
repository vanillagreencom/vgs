#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${DESTDIR:-}"
prefix="${PREFIX:-/usr}"
lib="$dest$prefix/lib/vshell"

install -d "$lib" "$dest$prefix/bin" "$dest$prefix/lib/systemd/user"
cp -a "$root/quickshell" "$root/config" "$root/themes" "$root/third_party" "$lib/"
while IFS= read -r -d '' file; do
  [[ "$(basename "$file")" == "vshell-asdcontrol" ]] && continue
  install -Dm755 "$file" "$lib/bin/$(basename "$file")"
done < <(find "$root/bin" -maxdepth 1 -type f -print0)
install -Dm644 "$root/README.md" "$root/LICENSE" "$root/VERSION" -t "$lib"
install -Dm755 "${VGS_BACKEND_BINARY:?set VGS_BACKEND_BINARY}" "$lib/bin/vshell-backend"
if [[ -n "${VGS_ASDCONTROL_BINARY:-}" ]]; then
  install -Dm755 "$VGS_ASDCONTROL_BINARY" "$lib/bin/vshell-asdcontrol"
fi
ln -s ../lib/vshell/bin/vshell "$dest$prefix/bin/vshell"
sed 's|ExecStart=%h/.local/bin/vshell run|ExecStart=/usr/bin/vshell run|' \
  "$root/systemd/user/vshell.service" > "$dest$prefix/lib/systemd/user/vshell.service"