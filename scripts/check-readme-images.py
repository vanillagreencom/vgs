#!/usr/bin/env python3
"""Check the screenshots the first-party plugin READMEs show.

Every directory under shell/plugins/ with a manifest.json is a first-party
plugin. docs/images/plugins/ holds the images, and its shots.tsv is the
table scripts/readme-shots.sh makes them from: the header line
`image<TAB>scene<TAB>shot<TAB>crop`, then one row per image with those four
fields: the image's file name, the scripts/sandbox-shots.sh scene and shot
it is cut from, and the crop, one of CROPS. An image is a markdown
`![alt](path)` or an HTML `<img src="path">` outside code.

Rules, each a finding key:
  readme-missing      a plugin directory has no README.md.
  no-image            a plugin README shows no image.
  no-own-image        a plugin README shows images, and none of them is
                      its own: a file with a table row whose name starts
                      with the plugin's id and `-`, the longest id that
                      fits naming the owner, as for row-unreferenced.
  image-form          an image is a reference-style `![alt][ref]`, which
                      this check does not resolve; write it inline.
  image-not-relative  an image path has a scheme or a leading `/`.
  image-outside       an image path resolves outside docs/images/plugins/.
  image-missing       an image path names no file.
  image-format        an image file is not WebP by its magic bytes and
                      its `.webp` name.
  image-size          an image file is over BUDGET_BYTES.
  command-unnamed     a README that shows an image does not name
                      scripts/readme-shots.sh, the command that makes it.
  table-row           a table row is not four well-formed fields, names an
                      unknown crop, or repeats an image; or the header
                      differs, which leaves the table unjudged and ends
                      the check there.
  row-plugin          a row's image name starts with no plugin id and `-`.
  row-image-missing   a row's image file does not exist.
  row-unreferenced    a row's image is not shown by the README of the
                      plugin its name starts with.
  orphan              a file under docs/images/plugins/ other than
                      shots.tsv has no row, whether a README shows it or
                      not.

Usage: check-readme-images.py [--table]
With no argument it checks the tree this file sits in. Each finding is one
line `check-readme-images: <key>=<value>`; the pass is
`check-readme-images: ok plugins=<n> images=<n>`. With --table it judges
the table alone and prints each row, tab-separated, for
scripts/readme-shots.sh. Exit 0 when clean, 1 on any finding, 2 when the
check cannot judge: an unreadable file or directory, printed as
`check-readme-images: unreadable=<path>`, or no plugin found, printed as
`check-readme-images: plugins=none`, since an empty walk certifies nothing.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGINS = "shell/plugins"
IMAGES = "docs/images/plugins"
TABLE = IMAGES + "/shots.tsv"
COMMAND = "scripts/readme-shots.sh"
HEADER = "image\tscene\tshot\tcrop"
CROPS = ("full", "bar", "content")
# The largest image scripts/readme-shots.sh made from the table on host
# cachy on 2026-09-30, ImageMagick 7.1.2-32 with libwebp 1.6.0, was the Dev
# Tools window at 54,996 bytes (docs/architecture/readme-images.md
# § Encoding). The budget leaves near twice that for a larger surface and
# stays under the 200 KB commit-guards byte ceiling.
BUDGET_BYTES = 100 * 1024
NAME = re.compile(r"^[a-z0-9][a-z0-9.-]*\.webp$")
SCENE = re.compile(r"^[a-z][a-z-]*$")
SHOT = re.compile(r"^[A-Za-z0-9._-]+$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"(`+).*?\1")
INLINE_IMAGE = re.compile(r"!\[[^\]]*\]\(\s*<?([^)\s>]*)>?(?:\s+\"[^\"]*\")?\s*\)")
REFERENCE_IMAGE = re.compile(r"!\[[^\]]*\]\[[^\]]*\]")
HTML_IMAGE = re.compile(r"<img\b[^>]*?\bsrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))", re.IGNORECASE)
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


class Unreadable(Exception):
    def __init__(self, path):
        super().__init__(path)
        self.path = path


def read(path):
    try:
        with open(os.path.join(ROOT, path), "rb") as handle:
            return handle.read()
    except OSError as error:
        raise Unreadable(path) from error


def listdir(path):
    try:
        return sorted(os.listdir(os.path.join(ROOT, path)))
    except OSError as error:
        raise Unreadable(path) from error


def prose(text):
    """TEXT with fenced code blocks and code spans blanked, line for line."""
    out, fence = [], None
    for line in text.split("\n"):
        match = FENCE.match(line)
        if fence is not None:
            if match and match.group(1)[0] == fence[0] and len(match.group(1)) >= len(fence):
                fence = None
            out.append("")
        elif match:
            fence = match.group(1)
            out.append("")
        else:
            out.append(CODE_SPAN.sub("", line))
    return "\n".join(out)


def images_of(text):
    """The image paths TEXT shows, in order, and whether it holds a
    reference-style image."""
    body = prose(text)
    paths = [m.group(1) for m in INLINE_IMAGE.finditer(body)]
    paths += [next(g for g in m.groups() if g is not None) for m in HTML_IMAGE.finditer(body)]
    return paths, REFERENCE_IMAGE.search(body) is not None


def table(findings):
    """The table's rows as (image, scene, shot, crop), each a well-formed
    row; a malformed one is a finding and is left out. None when the header
    is wrong."""
    try:
        lines = read(TABLE).decode("utf-8").split("\n")
    except UnicodeDecodeError as error:
        raise Unreadable(TABLE) from error
    if lines and lines[-1] == "":
        lines.pop()
    if not lines or lines[0] != HEADER:
        findings.append(("table-row", "1 reason=header"))
        return None
    rows, seen = [], set()
    for number, line in enumerate(lines[1:], start=2):
        fields = line.split("\t")
        if len(fields) != 4:
            reason = "fields=%d" % len(fields)
        elif not NAME.match(fields[0]):
            reason = "image"
        elif not SCENE.match(fields[1]):
            reason = "scene"
        elif not SHOT.match(fields[2]):
            reason = "shot"
        elif fields[3] not in CROPS:
            reason = "crop"
        elif fields[0] in seen:
            reason = "repeated"
        else:
            seen.add(fields[0])
            rows.append(tuple(fields))
            continue
        findings.append(("table-row", "%d reason=%s" % (number, reason)))
    return rows


def plugins():
    """The first-party plugin ids, each a directory holding manifest.json."""
    found = [name for name in listdir(PLUGINS) if os.path.isfile(os.path.join(ROOT, PLUGINS, name, "manifest.json"))]
    if not found:
        print("check-readme-images: plugins=none")
        print("no directory under %s holds a manifest.json; the plugin walk is broken" % PLUGINS)
        sys.exit(2)
    return found


def owner(image, ids):
    """The plugin id IMAGE's name starts with, followed by `-`: the longest
    when ids share a prefix, so vgs.one-two-shot.webp is vgs.one-two's.
    None when no id fits."""
    owners = [plugin for plugin in ids if image.startswith(plugin + "-")]
    return max(owners, key=len) if owners else None


def judge_image(path, findings):
    """Findings for the image file at PATH, repository-relative."""
    data = read(path)
    if not (path.endswith(".webp") and len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP"):
        findings.append(("image-format", path))
    if len(data) > BUDGET_BYTES:
        findings.append(("image-size", "%s bytes=%d budget=%d" % (path, len(data), BUDGET_BYTES)))


def report(findings):
    for key, value in findings:
        print("check-readme-images: %s=%s" % (key, value))


def check():
    findings = []
    ids = plugins()
    rows = table(findings)
    if rows is None:
        report(findings)
        return 1
    listed = {row[0] for row in rows}
    shown = {}
    image_dir = os.path.normpath(IMAGES)
    for plugin in ids:
        readme = "%s/%s/README.md" % (PLUGINS, plugin)
        if not os.path.exists(os.path.join(ROOT, readme)):
            findings.append(("readme-missing", "%s/%s" % (PLUGINS, plugin)))
            continue
        try:
            text = read(readme).decode("utf-8")
        except UnicodeDecodeError as error:
            raise Unreadable(readme) from error
        paths, reference = images_of(text)
        if reference:
            findings.append(("image-form", readme))
        if not paths:
            if not reference:
                findings.append(("no-image", readme))
            continue
        if COMMAND not in text:
            findings.append(("command-unnamed", readme))
        own = False
        for target in paths:
            where = "%s:%s" % (readme, target)
            if SCHEME.match(target) or target.startswith("/"):
                findings.append(("image-not-relative", where))
                continue
            resolved = os.path.normpath(os.path.join(os.path.dirname(readme), target))
            if os.path.dirname(resolved) != image_dir:
                findings.append(("image-outside", where))
                continue
            if not os.path.isfile(os.path.join(ROOT, resolved)):
                findings.append(("image-missing", where))
                continue
            name = os.path.basename(resolved)
            shown.setdefault(name, set()).add(plugin)
            own = own or (name in listed and owner(name, ids) == plugin)
        if not own:
            findings.append(("no-own-image", readme))
    for image, _scene, _shot, _crop in rows:
        path = "%s/%s" % (IMAGES, image)
        if not os.path.isfile(os.path.join(ROOT, path)):
            findings.append(("row-image-missing", path))
            continue
        judge_image(path, findings)
        image_owner = owner(image, ids)
        if image_owner is None:
            findings.append(("row-plugin", path))
        elif image_owner not in shown.get(image, set()):
            findings.append(("row-unreferenced", path))
    for name in listdir(IMAGES):
        if name != os.path.basename(TABLE) and name not in listed:
            findings.append(("orphan", "%s/%s" % (IMAGES, name)))
    report(findings)
    if findings:
        return 1
    print("check-readme-images: ok plugins=%d images=%d" % (len(ids), len(rows)))
    return 0


def print_table():
    findings = []
    rows = table(findings)
    if findings:
        for key, value in findings:
            print("check-readme-images: %s=%s" % (key, value), file=sys.stderr)
        return 1
    for row in rows:
        print("\t".join(row))
    return 0


def main(argv):
    if argv not in ([], ["--table"]):
        print("check-readme-images: argument=%s" % " ".join(argv), file=sys.stderr)
        return 2
    try:
        return print_table() if argv == ["--table"] else check()
    except Unreadable as error:
        # --table's stdout carries rows, so its refusals go to stderr.
        print("check-readme-images: unreadable=%s" % error.path, file=sys.stderr if argv else sys.stdout)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
