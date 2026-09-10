# D015: Theme imagery ships as per-theme release archives; the repository keeps definitions and thumbnails

[← Decision Index](INDEX.md)

**Date**: 2026-09-09 **Status**: Active **Research**: —

**Applies to**: `themes/`, `scripts/gen-theme-catalog.py`, `bin/vshell-helper` theme-catalog functions, `packaging/`, `.github/workflows/release.yml`

**Context**: `themes/` holds 1,072,264,046 bytes of wallpapers across 409 files and 23,199,264 bytes of screenshots across 79 `preview.png` files. `git count-objects -vH` reports `size-pack` at 1018.88 MiB, because every past revision of those binaries is retained. A contributor changing a QML panel pays all of it.

The download machinery for uninstalled themes already exists and ships. `catalog_download_theme()` in `bin/vshell-helper` stages, verifies and swaps a theme directory under the mutation lock; `_catalog_fetch_verified()` refuses bytes whose size or sha256 misses the manifest; `_catalog_check_relpath()` confines every manifest path to the theme-package shape. What that machinery downloads *from* is this repository's own raw content: `themes/catalog.json` declares `baseUrl` as `https://raw.githubusercontent.com/vanillagreencom/vgs/v0.4.0/themes`, built by `base_url_for()` in `scripts/gen-theme-catalog.py`. Removing the imagery from the tree removes the download source, so the store has to move before the pixels can.

`scripts/gen-theme-catalog.py` also derives the manifest by walking the working tree and hashing every file (`build_catalog()` and `theme_entry()`). With no pixels on disk it cannot produce a `size` or a `sha256`, so the catalog needs a second input.

## Decision

### 1. The store is a numbered theme-asset release, one archive per theme

Theme imagery publishes to GitHub Releases on `vanillagreencom/vgs` under tags `themes-v1`, `themes-v2`, and so on. One asset per theme, named `vgs-theme-<name>-r<rev>.tar.gz`, holding that theme's complete package: `theme.json`, `colors.toml`, `apps/*`, `backgrounds/` and `preview.png`. `<rev>` is a per-theme integer that increases only when that archive's content changes, and it increases to the first revision the release does not already carry, which is not always by one.

**The archive carries the definitions too, not the imagery alone.** Installing a theme is then one request against one checksum, with no second fetch from a git ref: `raw.githubusercontent.com` leaves the download path entirely, which is what makes the history rewrite in §6 safe for downloads. The cost is that editing a theme's colours republishes that theme's archive; `scripts/gen-theme-catalog.py --check` fails until it does, so the two cannot drift apart silently.

A publish uploads only the archives whose content moved, and the first archive to upload is what opens the next `themes-vN` release, so a run with nothing to publish creates none. Opening it up front would leave an empty release behind, and a git tag on the default branch that every clone fetches, on the ordinary "did I publish everything?" rerun. A theme unchanged since `themes-v1` stays pinned to `themes-v1`. **No asset is ever deleted from a past `themes-vN` release**, so a checksum pinned by an older shell stays fetchable. An upload never replaces a name already on a release *with different bytes*; a name already there at the identical sha256 is an interrupted run resuming, not a collision.

**The lock records publication, not intent.** Each theme's entry is written and the file saved the moment that theme's own upload returns, so an upload that fails at archive 40 of 79 leaves a lock describing exactly the 39 that are on the release, and the rerun continues from there. `--no-upload` writes the entry with `"published": false`, so a dry run can never leave a permanent pin to a release nobody created.

Because each entry is recorded as its own upload returns, a run that uploaded some themes and then failed leaves no unpublished pin naming the release it was filling. The lock's top-level `publishing` field is that name: it is written before the first upload and cleared when the batch finishes, so the rerun continues into that release instead of opening the next number and stranding a partly filled one.

Theme imagery and the shell version are therefore independent in both directions: replacing a wallpaper publishes a theme-asset release and touches no shell version, and cutting a shell release republishes nothing.

### 2. `themes/catalog.json` stays generated, from two inputs

`scripts/gen-theme-catalog.py` keeps ownership of the file. It reads:

- **The repository tree**, for everything the definitions carry: `name`, `mode`, `pair`, `source`, the 16 colours, `background`, `foreground`, `accent`, and a `files[]` entry with size and sha256 for each *definition* file that remains in the tree (`theme.json`, `colors.toml`, `apps/*`). 517 of the current 1005 file entries are definition files and survive unchanged.
- **`themes/asset-lock.json`**, a checked-in file written only by the publish script, holding a top-level `publishing` while a run is in flight, and per theme `{release, archive, rev, size, sha256, definitions, preview, published}`. `definitions` is the digest below; `preview` is the sha256 of the screenshot the theme's thumbnail was derived from; `published` records whether the archive reached the release. Generation refuses an entry with no `definitions`, and the CI gate reports one without `published` as never published.

The 488 imagery entries in `files[]` collapse into one `assets` object per theme carrying one checksum for one archive. `source` becomes `{type: "github-release", repo, ref, baseUrl}`, where `baseUrl` is the release download root and a theme's archive resolves as `<baseUrl>/<release>/<archive>`. `source.refs` and `source.baseUrls` are gone; `source.ref` stays because `--check-release-pin` names the shell release the catalog ships with. The entry's `size` becomes the archive's compressed size, which is what a download actually transfers.

Each lock entry also carries `definitions`, one digest over the `(path, sha256)` set of the definition files that archive packed. The publish script reads every member exactly once, while packing, and returns those bytes; the `definitions` digest, the `preview` digest and the browser thumbnail are all functions of them, and no consumer takes a path. Reading a file again would describe or display content the release does not carry, for any file edited during a run that takes minutes over roughly a gigabyte. `--check` and `--write` both recompute it from the tree and refuse when it disagrees, naming the theme and `scripts/publish-theme-assets.py`. Without that binding a maintainer could edit a theme's `colors.toml`, regenerate, and ship a catalog advertising definitions the pinned archive does not carry — the install path verifies the archive, so the user would silently get the old ones.

`--check` runs with no pixels present: it re-derives the tree half and requires a lock entry for every theme. `--check-assets-published` asks GitHub whether each entry's *archive* is an asset of a release that exists; a tag alone proves nothing, because a dry run or an interrupted upload leaves a pin whose archive was never uploaded and every install of that theme is a 404. CI runs that check, so an unpublished pin cannot merge. `--check-release-pin` keeps its release-gate job for the definition ref and runs the same asset check. A `gh` failure that is not "release not found" — an unauthenticated shell exits 4 — is reported as "could not confirm", never as "not published". `check_source_drift()` is deleted; the drift it guarded against was a raw-content ref serving different bytes than the tree, and a release asset pinned by sha256 cannot drift.

**Where the pixels live for a maintainer adding a theme**: a working directory outside the repository at `$VGS_THEME_ASSET_ROOT`, default `../vgs-theme-assets`, laid out as `<name>/{backgrounds/,preview.png}`. `scripts/publish-theme-assets.py` reads it, builds the archives, uploads them with `gh release upload`, writes `themes/asset-lock.json` and the thumbnails, and regenerates the catalog. The published releases, not the maintainer's disk, are the copy of record: `scripts/publish-theme-assets.py --pull` rebuilds that working directory from them.

### 3. The browser paints a checked-in 480-pixel thumbnail, with the colour swatch as fallback

`themes/thumbnails/<name>.jpg` ships in the repository and with the package every install carries: 480 pixels wide, JPEG quality 82, derived from the full-size preview at publish time. Measured over the current 79 previews as generated by `scripts/publish-theme-assets.py`: 1,548,721 bytes in total.

**This is a deliberate departure from "previews move out of the repository".** The full-size 1920×1080 `preview.png` files do leave, all 23,199,264 bytes of them. What stays is this derived set, because `ThemeCatalogBrowser.qml` paints at exactly 480 px and shipping it removes both the 79-request first paint and the blank-browser-offline case for under 1.5 MB.

`ThemeCatalogBrowser.qml:322` already requests `sourceSize.width: 480`, so the thumbnail is the exact resolution the browser paints, and today's 1920×1080 `preview.png` was being downscaled at paint time anyway.

**First paint offline**: every catalog tile paints its thumbnail from local disk with no network call, because the package every install carries holds them. A catalog entry with no thumbnail keeps the existing swatch treatment — `ThemeCatalogBrowser.qml:315` fills the frame with `cell.modelData.background`, `:330` labels it "No screenshot", and `:394` renders eight colour chips from the catalog's own palette.

`themes/catalog-previews/` is deleted along with both sites that derived it (`scripts/build-release.sh`, `install_catalog_previews()` in `packaging/install-system.sh`). `thumbnails` replaces `catalog-previews` in `RESERVED_THEME_SUBDIRS`, and the shipped branch of the browser's screenshot lookup reads the thumbnail instead (`theme_shipped_preview()` since the imagery left the tree).

### 4. Archives cache in `~/.cache/vshell/theme-assets/`; installed themes stay in the config directory

A downloaded archive streams into `~/.cache/vshell/theme-assets/<sha256>.tar.gz` in fixed chunks, beside the existing wallpaper thumbnail cache at `~/.cache/vshell/wallpaper-thumbs/`. **The sha256 is computed over those chunks as they are written**, so the digest covers the bytes that landed on disk and the unpack step reads back exactly what was verified. The catalogued size is the read cap. The archive is never held whole in memory: the peak cost of an install is one chunk, not the 52,077,778 bytes of the largest catalogued theme. It is unpacked into the existing `.catalog-<name>-*` staging directory beside `~/.config/vshell/themes/`, and deleted once the install finishes. The cache holds in-flight downloads only, so the finished disk cost is exactly the theme tree, and no eviction policy is needed.

**"A second switch is offline and instant" means**: `vshell theme apply <name>` for an installed theme makes zero network calls. It reads `~/.config/vshell/themes/<name>/` and `/usr/lib/vshell/themes/<name>/` and nothing else, because `compose_theme_files()` in `bin/vshell-helper` composes from those two directories only. `theme catalog install` is the sole command that reaches the network.

### 5. Degradation, per path

| Path | Behaviour |
|---|---|
| `blueprint_from_wallpaper()` in `bin/vshell-helper` | Keeps raising. Its two callers, `theme extract-wallpaper` and `theme set-wallpaper --extract`, act on a path the user typed. A silent fallback there hides a typo. |
| Greeter sync, in `publish_greeter_wallpaper()` | Stops raising. Both sync paths, privileged and unprivileged, share this one branch: a missing greeter wallpaper removes the override, prints the path and says the greeter falls back to its built-in background, and records `greeterWallpaperMissing` with the path in `sync-manifest.json`. The settings tab folds that stderr line into its toast. A greeter that refuses to sync over a missing image is a lock-out. |
| A theme whose imagery never arrived | Stays applied. `load_theme_package()` lists only files present, so `wallpaper` becomes `""` and `WallpaperBackground.qml:606-613` activates the `VgsBackdrop` gradient. The reason is stated by the failed install: `VGSThemeCatalogService.qml` already carries `lastError`. |
| Fastfetch fallback logo (`bin/vshell-helper`, `apply_fastfetch_logo_hook`) | Moves off `themes/coppernight/backgrounds/4-cats-anime.jpg` to `config/vshell/branding/fastfetch-logo.jpg`, a 600×600 crop of 18,856 bytes, so it no longer depends on a theme that may not be installed. |

### 6. History rewrite with `git-filter-repo`, `main` and every tag force-pushed

`git filter-repo --path-glob 'themes/*/backgrounds/*' --path-glob 'themes/*/preview.png' --invert-paths` over all refs, then a fresh commit re-adding the current imagery of the bundled default themes. `git-filter-repo` is installed at `/usr/bin/git-filter-repo`.

`main` and every `v*` tag are force-pushed with rewritten commit SHAs. Uploaded release assets survive, because they attach to the release object and not to the commit.

The rewrite is executed separately, once, against a fresh clone, after the deletion has merged. It is not part of the deletion's own change: issue #270 carries the tooling and the procedure.

**What breaks**: every existing clone and open branch; GitHub's auto-generated "Source code" tarballs for old tags; `raw.githubusercontent.com/vanillagreencom/vgs/v0.4.0/themes/...`, which is the download base URL a shipped v0.4.0 install reads, so that install stops downloading themes; and `pkgver()` in `packaging/arch/vgs-shell-git/PKGBUILD:94`, which counts commits with `git rev-list --count HEAD`. The upstream SHAs in `docs/ATTRIBUTION.md:10,14,16` name other repositories and are unaffected.

### 7. `vgs-shell-assets` is retired; `VGS_THEME_BUNDLE` disappears

`packaging/install-system.sh` installs one theme set. Its `core`/`extras`/`all` branch, the bundle-caller gate in `scripts/check-package-assets.sh`, and `scripts/build-assets.sh` all go.

| File | Becomes |
|---|---|
| `packaging/arch/vgs-shell-assets/` | Deleted. The AUR package is also removed at aur.archlinux.org, which is a manual step. |
| `packaging/arch/PKGBUILD` | The stable recipe drops `VGS_THEME_BUNDLE=core` and declares `replaces` and `conflicts` on `vgs-shell-assets`: the single install now writes the icons that package owned, and pacman honours `replaces` only for repository packages, so an AUR install needs both. |
| `packaging/arch/vgs-shell-git/PKGBUILD` | One package again: the `pkgname` array, `package_vgs-shell-assets-git()` (`:114-122`) and its `provides`/`conflicts` go. It gains `replaces` and `conflicts` on `vgs-shell-assets` and `vgs-shell-assets-git`, for the same icon-ownership reason as the stable recipe. |
| `packaging/debian/control`, `rules` | The `Package: vgs-shell-assets` stanza and the second `install-system.sh` line (`rules:17`) go. |
| `packaging/fedora/vgs-shell.spec` | The `%package assets` block, `%files assets` (`:177-183`) and the second install line (`:145`) go. |
| `packaging/gentoo/vgs-shell-<v>.ebuild` | `IUSE="+extra-themes"` (`:18`) and the conditional install (`:57-60`) go. |
| `packaging/void/template` | `subpackages` (`:14`), the second distfile and checksum (`:22-36`), the second `do_install` line (`:41`) and `vgs-shell-assets_package()` (`:44-58`) go. |
| `flake.nix:31` | `VGS_THEME_BUNDLE=all` becomes an unqualified install. |
| `scripts/publish-aur.sh:36,43,52`, `.github/workflows/publish-aur.yml:22,30,98,105` | Two packages instead of three. |
| `.github/workflows/release.yml:35-48,51` | The `assets` job and its `needs` entry go. |
| `scripts/check-aur-sync.py:31`, `scripts/check-validation-inventory.py:39` | Their `vgs-shell-assets` and `build-assets.sh` rows go. |

## Rationale

- **The download path is already built, verified and locked.** Moving the store is a change of URL and of manifest shape, not a new subsystem. One archive checksum replaces 488 per-file checksums, which is a smaller manifest and one HTTP request per theme instead of one per wallpaper.
- **A numbered release keeps a pinned checksum fetchable.** A rolling tag would let an asset be replaced under a checksum that a shipped catalog still names, turning every install of that theme into a verification failure. Numbered releases with no deletions make an old pin permanently valid.
- **Thumbnails cost 1,548,721 bytes and remove an entire failure mode.** Fetching a thumbnail per theme on browser open means 79 requests before first paint and a blank browser offline. That measured cost buys never needing them, against a 200 MB working-tree target.
- **A generated catalog with a checked-in lock keeps CI honest without the pixels.** The alternative, hand-editing 79 entries with 16 colours each, is not maintainable; generating at publish time only would leave `--check` unable to run in CI, which is where staleness is currently caught.
- **The greeter must not refuse to start over an image.** It is the path between a powered machine and a logged-in session.

## Alternatives Considered

| Alternative | Why rejected |
|---|---|
| A separate assets repository, or an object store | The owner ruled out new infrastructure and new credentials. GitHub Releases needs neither, and `gh` is already used by the release flow. |
| Attach theme archives to the shell release (`v0.4.0`) | Ties a wallpaper change to a shell version bump, and forces a 1 GB re-upload on every release. Independent versioning was a stated requirement. |
| Keep the imagery in the tree and rely on shallow or partial clone | The issue measures the working tree, not the history. A shallow clone still checks out 1.1 GB of pixels. |
| `git lfs` | Moves the bytes without removing them from a checkout, still needs a rewrite to shrink `size-pack`, and adds a client requirement to every contributor and every distro build. |
| Remote thumbnails as a second release asset | 79 requests before first paint and nothing offline, to save 1,548,721 bytes. |
| Colour swatch only, no thumbnail | The 16-colour block does not distinguish one Rose Pine variant from another; the catalog carries five themes whose names share a prefix. |
| Keep zero wallpapers in git and have `build-release.sh` fetch the default themes' archives in CI | Clears the size target with a wider margin, but the source tarball at `.github/workflows/release.yml:64` is `git archive HEAD`, so Fedora, Gentoo, Void and AUR-git builds — all sandboxed without network — would ship a desktop with no wallpaper. |
| Accept the existing history and reclaim only the working tree | Leaves `size-pack` at 1018.88 MiB, so a fresh clone still transfers about 1 GB. The issue's headline measurement, 50 seconds to clone against 2 to 4 seconds for every other repository in the fleet, is a history cost. |

## Impact

**Gates and scripts that break and must change in the same series**: `scripts/check-package-assets.sh` (bundle-caller gate, core and extras assertions, `gen-theme-catalog.py --check`); `scripts/check-release.sh` (assets pkgver, release pin, extras archive, preview-set comparison); `scripts/build-assets.sh` (deleted); `scripts/build-release.sh`; `packaging/install-system.sh`; `scripts/gen-theme-catalog.py`; `scripts/check-aur-sync.py:31`; `scripts/publish-aur.sh:36,43,52`; `.github/workflows/release.yml:35-51`; `.github/workflows/publish-aur.yml:22,30,98,105`; `scripts/check-validation-inventory.py:39,44`; `scripts/check-vshell-helper.py` (`test_theme_catalog_manifest_matches_the_repo` iterates `theme["files"]`, the fastfetch fixture reads coppernight's wallpaper, and `test_shell_only_theme_preview` loads the coppernight package; the restyle sweeps also name coppernight but read only `theme.json` and `colors.toml`, which stay in the tree, so they need no change); `tools/byte-ceiling-excludes:7`; `.agents/skills/vgs-release/SKILL.md:16`.

**The bundled default theme changes.** The owner's set is `roseofdune` (18 MB, `"mode": "light"`) and `bauhaus` (9.7 MB, `"mode": "dark"`), which excludes `coppernight` (19 MB), the current default. **`bauhaus` becomes the default**, the dark member of the pair, so the shell's first paint stays dark. The name is repointed in `config/vshell/settings.default.json`, `quickshell/vshell/Common/MethodTheme.qml`, `quickshell/vshell/Common/SettingsData.qml`, `quickshell/vshell/Common/settings/SettingsSpec.js`, `quickshell/vshell/Modules/Greetd/GreetdSettings.qml`, and `DEFAULT_THEME_NAME` in `bin/vshell-helper`, which is the helper's single spelling of it. The package's theme set becomes both bundled themes, so every install still has its default theme on disk.

**The vendored icon themes need a home.** `config/vshell/icons/` is 50,321,042 bytes across the Yaru set and ships today only in the retired assets package (`packaging/install-system.sh:73`). Retiring that package moves it into the one install. **`config/vshell/icons/` is out of scope for this decision**: it is not theme imagery, and shrinking or relocating it is separate work.

**Measured working tree after the change**: 128,450,541 bytes of non-theme content, 4,076,425 bytes of theme definitions, 27,926,681 bytes of bundled imagery and 1,548,721 bytes of thumbnails, for 162,002,368 bytes.

**The 200 MB figure is a target, not a hard requirement, and 162,002,368 bytes is the measurement that settles it.** A clone transfers file content, not disk blocks, so apparent bytes are the metric the issue's clone timing came from. `du -sh` reports block usage and lands near 211 MiB; the gap is almost entirely `config/vshell/icons/`, which is out of scope above.

**No migration step is needed on the owner's machine.** Verified while implementing: `vgs-shell-assets` is not installed, no VGS package is installed by pacman, and `/usr/lib/vshell/themes` does not exist. The live desktop runs from the checkout, so nothing under `/usr/lib/vshell/themes/` can be removed by retiring the package. A machine that *does* have the distro package keeps its `~/.config/vshell/themes/` untouched and re-downloads only the distro-installed themes it still wants.

**Revisit When**: a theme-asset release approaches GitHub's per-asset or per-release limits; a second maintainer needs write access to theme imagery, which the single `$VGS_THEME_ASSET_ROOT` working directory does not model; or the catalog gains enough themes that one archive per theme makes a browser open slow enough to want an index asset.

**Verification**: `scripts/gen-theme-catalog.py --check` passes in a checkout with no wallpapers present. A `theme catalog install` against a `themes-vN` release lands bytes matching the lock's sha256 and refuses a tampered archive. `theme apply` on an installed theme makes no network call. A greeter sync with a missing configured wallpaper completes and records the reason. `scripts/validate packaging` passes with `VGS_THEME_BUNDLE` gone.

**References**: [D010](D010-single-screen-wallpaper-apply.md) (wallpaper apply path), issue #262, `docs/architecture/theme.md`.
