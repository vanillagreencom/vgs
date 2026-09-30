#!/usr/bin/env python3
"""The controls of check-readme-images.py: one planted defect per rule on a
passing scratch tree, each turning the check red with exactly its own
finding, the discovery floor, the --table mode and the argument refusal.

Each case copies the check into a fresh scratch tree, seeds the passing
world below, applies its defect and runs the copy, whose root is the tree
it sits in. The world holds two plugins whose ids share a prefix, vgs.one
and vgs.one-two, so an image named for vgs.one-two belongs to it alone; a
README with a fenced block and a code span naming a remote image, which is
no image; and an HTML <img>, which is one. The walk's floor is the case
with no manifest; both seeded plugins are required members, since the
passing world fails when either README goes unread, and a directory with
no manifest is the forbidden one."""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK = os.path.join(HERE, "check-readme-images.py")
ENV = {"PATH": os.environ.get("PATH", ""), "LC_ALL": "C"}
WEBP = b"RIFF\x1c\x00\x00\x00WEBPVP8 \x10\x00\x00\x00" + b"\x00" * 16
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 24
IMAGES = "docs/images/plugins"
LINK = "../../../" + IMAGES + "/"
HEADER = "image\tscene\tshot\tcrop\n"
ROWS = (
    "vgs.one-panel.webp\tpanels\tpanels-dark-one\tcontent\n"
    "vgs.one-two-shot.webp\tbar\tbar-dark\tbar\n"
    "vgs.one-two-extra.webp\tlock\tlock-dark\tfull\n"
)
README_ONE = (
    "# One\n\nThe first plugin.\n\n"
    "![The panel](" + LINK + "vgs.one-panel.webp)\n\n"
    "Screenshots from `scripts/readme-shots.sh`.\n\n"
    "```markdown\n![remote](https://example.com/in-a-fence.webp)\n```\n\n"
    "Write `![remote](https://example.com/in-a-span.webp)` inline.\n"
)
README_TWO = (
    "# One Two\n\n"
    "![The bar](" + LINK + "vgs.one-two-shot.webp)\n"
    "<img src=\"" + LINK + "vgs.one-two-extra.webp\" alt=\"The lock\">\n\n"
    "Screenshots from scripts/readme-shots.sh.\n"
)


# The per-image budget docs/architecture/readme-images.md § Budget states,
# written here rather than read from the check, so the cases pin the figure
# and not only the comparison.
BUDGET = 100 * 1024


def write(root, path, data):
    full = os.path.join(root, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "wb" if isinstance(data, bytes) else "w") as handle:
        handle.write(data)


def append(root, path, text):
    with open(os.path.join(root, path), "a") as handle:
        handle.write(text)


def replace(root, path, old, new):
    full = os.path.join(root, path)
    text = open(full).read()
    assert text.count(old) == 1, "the planted text must match once in %s: %r" % (path, old)
    with open(full, "w") as handle:
        handle.write(text.replace(old, new))


def plugin(root, plugin_id, readme):
    write(root, "shell/plugins/%s/manifest.json" % plugin_id, "{}\n")
    if readme is not None:
        write(root, "shell/plugins/%s/README.md" % plugin_id, readme)


def seed(root):
    write(root, "scripts/check-readme-images.py", open(CHECK).read())
    plugin(root, "vgs.one", README_ONE)
    plugin(root, "vgs.one-two", README_TWO)
    for name in ("vgs.one-panel.webp", "vgs.one-two-shot.webp", "vgs.one-two-extra.webp"):
        write(root, "%s/%s" % (IMAGES, name), WEBP)
    write(root, IMAGES + "/shots.tsv", HEADER + ROWS)



ONE = "shell/plugins/vgs.one/README.md"
TWO = "shell/plugins/vgs.one-two/README.md"
TABLE = IMAGES + "/shots.tsv"


def remove_manifests(root):
    for plugin_id in ("vgs.one", "vgs.one-two"):
        os.remove(os.path.join(root, "shell/plugins/%s/manifest.json" % plugin_id))


def move_shot_to_one(root):
    replace(root, TWO, "![The bar](" + LINK + "vgs.one-two-shot.webp)\n", "")
    append(root, ONE, "\n![The bar](" + LINK + "vgs.one-two-shot.webp)\n")


# Cases: label, defect, expected exit, expected finding lines in order.
# Every finding line of the run is compared, so a defect that reaches a
# second rule fails its case.
CASES = [
    ("the seeded world passes", lambda r: None, 0, ["check-readme-images: ok plugins=2 images=3"]),
    ("a plugin with no README", lambda r: plugin(r, "vgs.three", None), 1,
     ["check-readme-images: readme-missing=shell/plugins/vgs.three"]),
    ("a README with no image", lambda r: plugin(r, "vgs.three", "# Three\n\nNo picture.\n"), 1,
     ["check-readme-images: no-image=shell/plugins/vgs.three/README.md"]),
    ("a README whose only picture sits in a fence", lambda r: plugin(r, "vgs.three", "# Three\n\n```\n![x](" + LINK + "vgs.one-panel.webp)\n```\n"), 1,
     ["check-readme-images: no-image=shell/plugins/vgs.three/README.md"]),
    ("a reference-style image", lambda r: append(r, ONE, "\n![The panel][panel]\n\n[panel]: " + LINK + "vgs.one-panel.webp\n"), 1,
     ["check-readme-images: image-form=" + ONE]),
    ("a remote image", lambda r: append(r, ONE, "\n![Remote](https://example.com/a.webp)\n"), 1,
     ["check-readme-images: image-not-relative=" + ONE + ":https://example.com/a.webp"]),
    ("a remote HTML image", lambda r: append(r, ONE, "\n<img src='https://example.com/b.webp'>\n"), 1,
     ["check-readme-images: image-not-relative=" + ONE + ":https://example.com/b.webp"]),
    ("an absolute image path", lambda r: append(r, ONE, "\n![Root](/docs/images/plugins/vgs.one-panel.webp)\n"), 1,
     ["check-readme-images: image-not-relative=" + ONE + ":/docs/images/plugins/vgs.one-panel.webp"]),
    ("an image outside the image directory", lambda r: append(r, ONE, "\n![Other](../../../docs/other.webp)\n"), 1,
     ["check-readme-images: image-outside=" + ONE + ":../../../docs/other.webp"]),
    ("an image in a directory below the image directory", lambda r: append(r, ONE, "\n![Deep](" + LINK + "deep/a.webp)\n"), 1,
     ["check-readme-images: image-outside=" + ONE + ":" + LINK + "deep/a.webp"]),
    ("an image path that names no file", lambda r: append(r, ONE, "\n![Gone](" + LINK + "vgs.one-gone.webp)\n"), 1,
     ["check-readme-images: image-missing=" + ONE + ":" + LINK + "vgs.one-gone.webp"]),
    ("a README with an image that names no command", lambda r: replace(r, ONE, "Screenshots from `scripts/readme-shots.sh`.\n", ""), 1,
     ["check-readme-images: command-unnamed=" + ONE]),
    ("an image that is PNG under a .webp name", lambda r: write(r, IMAGES + "/vgs.one-panel.webp", PNG), 1,
     ["check-readme-images: image-format=" + IMAGES + "/vgs.one-panel.webp"]),
    ("an image at the budget", lambda r: write(r, IMAGES + "/vgs.one-panel.webp", WEBP + b"\x00" * (BUDGET - len(WEBP))), 0,
     ["check-readme-images: ok plugins=2 images=3"]),
    ("an image one byte over the budget", lambda r: write(r, IMAGES + "/vgs.one-panel.webp", WEBP + b"\x00" * (BUDGET + 1 - len(WEBP))), 1,
     ["check-readme-images: image-size=%s/vgs.one-panel.webp bytes=%d budget=%d" % (IMAGES, BUDGET + 1, BUDGET)]),
    ("a table with another header", lambda r: write(r, TABLE, "image\tscene\tshot\n" + ROWS), 1,
     ["check-readme-images: table-row=1 reason=header"]),
    ("a row of three fields", lambda r: append(r, TABLE, "vgs.one-x.webp\tpanels\tshot\n"), 1,
     ["check-readme-images: table-row=5 reason=fields=3"]),
    ("a row whose image is not a WebP name", lambda r: append(r, TABLE, "vgs.one-x.png\tpanels\tshot\tfull\n"), 1,
     ["check-readme-images: table-row=5 reason=image"]),
    ("a row whose scene is no scene name", lambda r: append(r, TABLE, "vgs.one-x.webp\tPanels 2\tshot\tfull\n"), 1,
     ["check-readme-images: table-row=5 reason=scene"]),
    ("a row whose shot is no shot name", lambda r: append(r, TABLE, "vgs.one-x.webp\tpanels\tshot/x\tfull\n"), 1,
     ["check-readme-images: table-row=5 reason=shot"]),
    ("a row with an unknown crop", lambda r: append(r, TABLE, "vgs.one-x.webp\tpanels\tshot\tzoom\n"), 1,
     ["check-readme-images: table-row=5 reason=crop"]),
    ("a row that repeats an image", lambda r: append(r, TABLE, "vgs.one-panel.webp\tpanels\tpanels-dark-one\tfull\n"), 1,
     ["check-readme-images: table-row=5 reason=repeated"]),
    ("a row whose image names no plugin", lambda r: (append(r, TABLE, "acme.z-x.webp\tpanels\tshot\tfull\n"), write(r, IMAGES + "/acme.z-x.webp", WEBP)), 1,
     ["check-readme-images: row-plugin=" + IMAGES + "/acme.z-x.webp"]),
    ("a row whose image is gone", lambda r: append(r, TABLE, "vgs.one-gone.webp\tpanels\tshot\tfull\n"), 1,
     ["check-readme-images: row-image-missing=" + IMAGES + "/vgs.one-gone.webp"]),
    ("a row no README shows", lambda r: (append(r, TABLE, "vgs.one-spare.webp\tpanels\tshot\tfull\n"), write(r, IMAGES + "/vgs.one-spare.webp", WEBP)), 1,
     ["check-readme-images: row-unreferenced=" + IMAGES + "/vgs.one-spare.webp"]),
    ("a row shown only by the plugin whose id is its name's shorter prefix", move_shot_to_one, 1,
     ["check-readme-images: row-unreferenced=" + IMAGES + "/vgs.one-two-shot.webp"]),
    ("a file with no row", lambda r: write(r, IMAGES + "/notes.txt", "x\n"), 1,
     ["check-readme-images: orphan=" + IMAGES + "/notes.txt"]),
    ("a shown file with no row", lambda r: (write(r, IMAGES + "/vgs.one-extra.webp", WEBP), append(r, ONE, "\n![Extra](" + LINK + "vgs.one-extra.webp)\n")), 1,
     ["check-readme-images: orphan=" + IMAGES + "/vgs.one-extra.webp"]),
    ("a directory with no manifest is no plugin", lambda r: write(r, "shell/plugins/notes/todo.txt", "x\n"), 0,
     ["check-readme-images: ok plugins=2 images=3"]),
    ("no plugin to walk", remove_manifests, 2,
     ["check-readme-images: plugins=none"]),
]


def run(root, *args):
    result = subprocess.run([sys.executable, os.path.join(root, "scripts/check-readme-images.py"), *args],
                            capture_output=True, text=True, env=ENV, cwd=root, check=False)
    return result.returncode, result.stdout, result.stderr


def findings(stdout):
    return [line for line in stdout.splitlines() if line.startswith("check-readme-images: ")]


def main():
    failures = 0
    for label, defect, want_status, want_lines in CASES:
        with tempfile.TemporaryDirectory() as root:
            seed(root)
            defect(root)
            status, stdout, stderr = run(root)
        got = findings(stdout)
        if status == want_status and got == want_lines:
            print("  ok    " + label)
        else:
            failures += 1
            print("  FAIL  %s: exit=%d want=%d lines=%r want=%r stderr=%r" % (label, status, want_status, got, want_lines, stderr))

    # --table prints the rows for scripts/readme-shots.sh, and refuses a
    # malformed one on stderr with its stdout empty.
    with tempfile.TemporaryDirectory() as root:
        seed(root)
        status, stdout, stderr = run(root, "--table")
        want = ROWS
        if status == 0 and stdout == want and stderr == "":
            print("  ok    --table prints the rows")
        else:
            failures += 1
            print("  FAIL  --table prints the rows: exit=%d stdout=%r stderr=%r" % (status, stdout, stderr))
        append(root, TABLE, "vgs.one-x.webp\tpanels\tshot\tzoom\n")
        status, stdout, stderr = run(root, "--table")
        if status == 1 and stdout == "" and stderr.splitlines()[:1] == ["check-readme-images: table-row=5 reason=crop"]:
            print("  ok    --table refuses a malformed row")
        else:
            failures += 1
            print("  FAIL  --table refuses a malformed row: exit=%d stdout=%r stderr=%r" % (status, stdout, stderr))
        status, stdout, stderr = run(root, "--rows")
        if status == 2 and stderr.splitlines()[:1] == ["check-readme-images: argument=--rows"]:
            print("  ok    an unknown argument is refused")
        else:
            failures += 1
            print("  FAIL  an unknown argument is refused: exit=%d stderr=%r" % (status, stderr))

    if failures:
        print("test-check-readme-images: failures=%d" % failures)
        return 1
    print("test-check-readme-images: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
