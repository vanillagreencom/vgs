# Theme wallpapers

Covers: bin/lib/theme-download.js, scripts/test-theme-download.js, scripts/tar-fixture.js, scripts/test-vgsh-wallpapers.sh

`vgsh theme wallpapers [--json] <name> [--update]` downloads the wallpaper archive a catalog install's index entry pins and lands its images in the package's `backgrounds/`. It is the one theme command that reaches the network. `bin/lib/theme-download.js` holds the fetch and the tar reader, which the v1 converter shares ([theme-catalog.md § Conversion](theme-catalog.md#conversion)). The catalog and its marker are [theme-catalog.md](theme-catalog.md). `bin/vgsh-theme-judge` holds the member rules and the land.

## Scope

- **What it acts on.** `<name>` must be a catalog install, else `not-catalog`. The index must still name it, else `not-in-catalog`, and pin an archive, else `no-imagery`. When the marker's `imagery` has the index pin's `sha256`, the command prints `up-to-date` and downloads nothing.
- **Ownership of `backgrounds/`.** A catalog install's `backgrounds/` belongs to its wallpaper download. A first download refuses a `backgrounds/` that is already there as `exists`, because the download did not place it. The user's own images belong in the user folder, `${XDG_CONFIG_HOME:-~/.config}/vgs/backgrounds/` ([theme-backgrounds.md](theme-backgrounds.md)). When the marker records another archive, the command refuses `installed`, and `--update` replaces the images.

## Fetch and read

- **Fetch.** `bin/vgsh` holds `download.lock` in the cache directory with `flock -n` on descriptor 8, and not the theme lock, so a download never holds up an apply. A held lock is `busy`, exit 75. The URL is `<repo>/releases/download/<release>/<archive>`. `VGS_THEME_ASSET_BASE` replaces `<repo>/releases/download`. The URL must be HTTPS, and every redirect too, else `not-https` or `redirect-not-https`. A `file://` URL is accepted only while `VGS_TEST_RUN` is set. The pin, not the URL, decides which bytes are accepted.
- **Cache.** The archive streams into `${XDG_CACHE_HOME:-~/.cache}/vgs/theme-assets/<sha256>.tar.gz.part`. Each chunk is hashed as it is written, and the transfer is cut off once it passes the pinned size. A transfer idle for 60 s ends as `download error=timeout`. The part is then refused unless its size and sha256 are the pin's. The command removes the part once it has unpacked it, so the cache holds in-flight downloads only, as v1's did ([v1 D015](https://github.com/vanillagreencom/vgs/blob/v1/docs/decisions/D015-theme-imagery-release-assets.md) § 4). A verified `<sha256>.tar.gz` there, which the converter keeps, is used and kept. The archive is never held whole in memory.
- **Members.** The reader verifies each tar header's checksum and reads its size as octal. It reads a pax `path` and a GNU long name for the next member, refuses a pax `size`, and accepts a global pax header only without a `path`. It refuses a name with an empty, `.` or `..` segment, an absolute name included, as `path`. A member lands only as a regular file named `backgrounds/<file>`, where `<file>` ends in `.png`, `.jpg` or `.jpeg` in any case and does not start with `.`, the rule `vgsh theme background` reads images by. The judge refuses a member over 128 MiB from its header, before it writes a byte.

## Land

- **Stage.** The images unpack into `backgrounds/` of a staging directory beside `themes/`, with the pin in `pin.json`. `bin/vgsh` removes the staging directory on exit.
- **Land.** `bin/vgsh` releases the download lock and takes the theme lock. The judge runs `recover`, then judges the install again, because the package or the index can change during the download. An install that is now up to date stays. Otherwise the stage must hold the archive the index still pins, else `changed`. An update first renames the old `backgrounds/` into the stage. The staged `backgrounds/` is then renamed into the package. Last, the marker records the pin with `markerText`, its `digest` kept. `packageDigest` covers neither `backgrounds/` nor the marker, so `applied.json` and a follow see no change.
- **Interruption.** A refusal leaves no part, no staging directory, and the package and its marker as they were. An interruption before the first rename leaves the package as it was. One between the renames of an update leaves the package without images and its marker naming the old archive, and the next `--update` downloads again. One between the second rename and the marker leaves the images with the old marker. The next first download then refuses `exists` and the next update replaces them, and nothing the user placed is lost.

## Output

The text form prints `progress state=<state> bytes=<n> total=<t>` lines on stderr, then `ok wallpapers=<name> state=installed|updated|up-to-date images=<n> archive=<sha256, 12 digits>`. `--json` prints `{ "state", "bytes", "total" }` lines on stdout, then one result line `{ "state": "ok"|"failed", "theme", "wallpapers": "installed"|"updated"|"up-to-date"|null, "images": <n|null>, "sha256": <pin sha256|null>, "reason": <key|null> }`, a refusal's included.

A progress `state` is `downloading`, `verifying` or `unpacking`, and `bytes` counts the archive's bytes, so `total` is its size. Each state prints its first line, a line each time `bytes` passes another twentieth of `total`, and its line at `total`.

Exit 0 on success, 1 on a refusal, 2 on a bad invocation, 75 when either lock is busy.

## Refusals

Each refusal prints `vgsh: refused: wallpapers=<name> reason=<key>` and its fields, and the member refusals name the member as `member=<JSON name>`.

| `reason` | Refused |
|---|---|
| `not-catalog`, `not-in-catalog`, `no-imagery` | An install or entry the command cannot act on. |
| `exists`, `installed` | A `backgrounds/` the download did not place, and another archive's images without `--update`. Each prints an English line after it. |
| `busy`, `lock-failed` | The download lock at the fetch, the theme lock at the land. |
| `changed` | A pin the index no longer holds at the land. |
| `not-https`, `redirect-not-https` | A URL or a redirect that is not HTTPS, a `file://` URL outside a test run included. |
| `download` | A transfer that failed: `error=<code>`, `error=timeout` or `status=<n>`. |
| `size`, `sha256` | An archive of another size or digest, with `got=` and `want=`. |
| `cache`, `unwritable`, `unreadable` | A cache entry that is not a file, and a local file that cannot be written or read. |
| `archive`, `header` | A gzip error, and a tar header defect named by `defect=`. |
| `path`, `link`, `type`, `not-an-image`, `oversize`, `duplicate`, `no-image` | A member name outside `backgrounds/<file>`, a link, any other kind, a name that is no image, a member over 128 MiB, a name held twice, and an archive with no image. |

## Omarchy

Omarchy (basecamp/omarchy, e332dc9, read 2026-09-28) ships each theme's `backgrounds/` inside the theme's git repository, and `omarchy-theme-set` reads user images from `~/.config/omarchy/backgrounds/<theme>`. VGS keeps v1's split model instead: pinned per-theme archives in `vgs-themes` releases, sha256-verified and streamed, under v1's acceptance rules. The 81 themes' `themes-v1` archives total 1.05 GB ([v2-platform-roadmap.md](../plans/v2-platform-roadmap.md)), and a definition install needs none of them.

## Invariants

1. The fetch accepts HTTPS only and `file://` only when its caller allows it, refuses a bad pin, a symlinked or other cache entry, and a transfer of another size or sha256, reports no byte past the pinned size, and leaves no part after a refusal. The tar reader refuses a bad checksum, a size that is no octal, a pax `size`, a global pax `path`, a name with an empty, `.` or `..` segment, a stream that ends inside a member and a long name with no member, reads pax paths, GNU long names and ustar prefixes whatever the chunking, and closes an open sink on a failed read. Enforced by `scripts/test-theme-download.js`, with a library copy per rule as its controls.
2. `vgsh theme wallpapers` lands only regular `backgrounds/<image>` members of at most 128 MiB, refuses every other member, a changed pin at the land, a `backgrounds/` it did not place and another archive's images without `--update`, takes `file://` only in a test run, and leaves nothing after a refusal. The download holds the download lock and the land the theme lock. A landed archive's pin is in the marker, and the next apply shows its first image. Enforced by `scripts/test-vgsh-wallpapers.sh`, with judge copies that take a link for another kind, accept any name, accept any path, skip the size ceiling, skip the staged pin's check and accept `file://` anywhere, and `bin/vgsh` copies that skip the download lock and the theme lock at the land, as its controls.
