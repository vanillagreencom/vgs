#!/usr/bin/env python3
"""Real compiler controls for each rule of check-voiceorb-shader.py."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("shader_check", HERE / "check-voiceorb-shader.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
TOOL = checker.qsb_tool()
if TOOL is None:
    print("test-voiceorb-shader: status=not-measured missing=qsb")
    raise SystemExit(77)


class ShaderControls(unittest.TestCase):
    def run_check(self, source, tool=TOOL, script=HERE / "check-voiceorb-shader.py", write=False):
        cmd = [sys.executable, str(script), "--source", str(source)]
        if write:
            cmd.append("--write")
        return subprocess.run(cmd, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "QSB": tool},
                              capture_output=True, text=True, check=False)

    def test_rules(self):
        original = checker.SOURCE.read_text()
        rows = [
            ("clean", None, 0, "voiceorb-shader: ok"),
            ("invalid", "not glsl;", 1, "voiceorb-shader: compile-failed"),
            ("source-changed", original.replace("max(ring, arcs)", "min(ring, arcs)"), 1, "voiceorb-shader: stale"),
            ("pack-changed", None, 1, "voiceorb-shader: stale"),
            ("missing-pack", None, 1, "voiceorb-shader: unreadable"),
            ("loop", original.replace("float ring =", "for (int i = 0; i < 5; ++i) { radius += pixel; }\n    float ring ="), 1, "voiceorb-shader: refused rule=loop"),
            ("texture", original + "\nlayout(binding=1) uniform sampler2D source;\n", 1, "voiceorb-shader: refused rule=texture"),
            ("missing-source", None, 1, "voiceorb-shader: unreadable"),
            ("missing-tool", None, 77, "voiceorb-shader: status=not-measured missing=qsb"),
        ]
        for name, text, status, key in rows:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as scratch:
                source = Path(scratch) / "voiceorb.frag"
                source.write_text(original if text is None else text)
                pack = source.with_suffix(".frag.qsb")
                shutil.copyfile(checker.SOURCE.with_suffix(".frag.qsb"), pack)
                if name == "pack-changed":
                    pack.write_bytes(b"invalid pack")
                if name == "missing-pack":
                    pack.unlink()
                if name == "missing-source":
                    source.unlink()
                result = self.run_check(source, "/absent/qsb" if name == "missing-tool" else TOOL)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertTrue(result.stdout.startswith(key), result.stdout)
                if name == "source-changed":
                    self.assertNotEqual(text, original)
                    self.assertEqual(self.run_check(source, write=True).returncode, 0)
                    self.assertEqual(self.run_check(source).returncode, 0)

    def test_freshness_guard_control(self):
        # Edit only the guard's behavior, not its matching source or the test.
        with tempfile.TemporaryDirectory() as scratch:
            script = Path(scratch) / "check.py"
            text = (HERE / "check-voiceorb-shader.py").read_text()
            needle = "elif compiled.read_bytes() != fresh:"
            self.assertEqual(text.count(needle), 1)
            changed = text.replace(needle, "elif False:")
            self.assertNotEqual(text, changed)
            script.write_text(changed)
            source = Path(scratch) / "voiceorb.frag"
            source.write_text(checker.SOURCE.read_text())
            source.with_suffix(".frag.qsb").write_bytes(b"invalid pack")
            result = self.run_check(source, script=script)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
