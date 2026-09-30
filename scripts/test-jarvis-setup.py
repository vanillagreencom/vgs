#!/usr/bin/env python3
"""Exercise the shipped installer in J09, with local download/uv/Python doubles.

Controls keep each rule's matched source text while removing its behavior.
They modify only disposable plugin copies. No real package, model, audio,
account, authentication or desktop service is used.
"""
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
PLUGIN = REPO / "shell/plugins/vgs.jarvis"
DOUBLE = REPO / "scripts/fixtures/jarvis-setup/installer.py"


def namespace_entry():
    """Every behavior case runs under the shared private-world owner."""
    if os.environ.get("JARVIS_TEST_ROOT"):
        return
    (REPO / "tmp").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(dir=REPO / "tmp", prefix="setup-standins-") as name:
        child = subprocess.run([str(REPO / "scripts/lib/jarvis-env.sh"), name, "--",
            sys.executable, str(Path(__file__).resolve())],
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, check=False)
    raise SystemExit(child.returncode)


class Setup(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.plugin = self.root / "plugin"
        shutil.copytree(PLUGIN, self.plugin)
        self.home = self.root / "home"
        self.home.mkdir()
        self.state = self.root / "state/vgs/jarvis"
        self.data = self.root / "data/vgs/jarvis/local"
        self.data.mkdir(parents=True)
        self.commands = self.root / "commands"
        self.commands.mkdir()
        # Bootstrap names are private doubles created after entering J09.
        for name in ("uv", "curl", "unshare", "gum"):
            shutil.copyfile(DOUBLE, self.commands / name)
            (self.commands / name).chmod(0o700)
        self.env = {"PATH": str(self.commands) + ":" + os.environ["PATH"],
                    "HOME": str(self.home), "XDG_STATE_HOME": str(self.root / "state"),
                    "XDG_DATA_HOME": str(self.root / "data"), "LC_ALL": "C",
                    "TMPDIR": str(self.root), "VGS_TEST_RUN": "1"}
        self.config = {"tier": "small"}
        self.spec = json.loads((self.plugin / "artifacts.json").read_text())
        self.downloads = self.data / "downloads"
        self.downloads.mkdir()
        # Membership is read from the producer. Each neutral file has a real
        # hash. Keep all engines, archive/direct and auxiliary shapes.
        for artifact in self.spec["artifacts"]:
            files = {}
            if artifact["directory"] == ".":
                payload = b"synthetic direct model"
                name = next(iter(artifact["files"]))
                (self.downloads / name).write_bytes(payload)
                files = {name: hashlib.sha256(payload).hexdigest()}
                filename = name
            else:
                filename = artifact["id"] + ".tar.bz2"
                with tarfile.open(self.downloads / filename, "w:bz2") as bundle:
                    for name in list(artifact["files"]) + [
                            directory + "/data" for directory in artifact.get("auxiliaryDirectories", [])]:
                        payload = ("synthetic " + name).encode()
                        item = tarfile.TarInfo(artifact["directory"] + "/" + name)
                        item.size = len(payload)
                        bundle.addfile(item, io.BytesIO(payload))
                        if name in artifact["files"]:
                            files[name] = hashlib.sha256(payload).hexdigest()
            artifact.update(url="https://fixture.invalid/" + filename, files=files,
                            sha256=hashlib.sha256((self.downloads / filename).read_bytes()).hexdigest())
        (self.plugin / "artifacts.json").write_text(json.dumps(self.spec))
        self.write_config()

    def write_config(self):
        (self.data / "fixture.json").write_text(json.dumps(self.config))

    def run_command(self, *args):
        return subprocess.run([sys.executable, "-I", str(self.plugin / "setup-local"), *args],
                              env=self.env, capture_output=True, text=True, check=False, timeout=30)

    def install(self, code=0):
        result = self.run_command("install", self.config["tier"])
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def report(self):
        result = self.run_command("status")
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def ready(self):
        self.assertEqual(self.report(), {"tone": "ok", "text": "Ready: " + self.config["tier"], "action": False})
        self.assertEqual((self.data / "probed").read_text(), self.config["tier"])

    def not_ready(self):
        self.assertNotEqual(self.report()["tone"], "ok")

    def mutant(self, needle, replacement):
        path = self.plugin / "setup-local"
        text = path.read_text()
        self.assertEqual(text.count(needle), 1, needle)
        changed = text.replace(needle, replacement)
        self.assertNotEqual(changed, text)
        path.write_text(changed)

    def test_setup_and_status(self):
        self.assertEqual(self.report(), {"tone": "warning", "text": "Not set up", "action": True})
        self.install()
        self.ready()
        self.assertEqual((self.state / "local-ready.json").stat().st_mode & 0o777, 0o600)
        calls = [json.loads(line) for line in (self.data / "calls.jsonl").read_text().splitlines()]
        self.assertEqual([call[0] for call in calls if call[0] in ("unshare", "python")], ["unshare", "python"])
        # Retry uses the same venv path, not a relocated environment.
        self.install()
        self.ready()

    def test_each_tier_uses_the_manifest(self):
        for tier in self.spec["tiers"]:
            with self.subTest(tier=tier):
                self.config["tier"] = tier
                self.write_config()
                self.install()
                self.ready()
                calls = [json.loads(line) for line in (self.data / "calls.jsonl").read_text().splitlines()]
                urls = [call[-1] for call in calls if call[0] == "curl"]
                expected = [a["url"] for a in self.spec["artifacts"] if a["id"] in self.spec["tiers"][tier]["artifacts"]]
                self.assertEqual(set(urls[-len(expected):]), set(expected))
                if self.spec["tiers"][tier]["provider"] == "cuda":
                    wheel = self.spec["runtimes"]["sherpa-onnx"]["cudaWheel"]
                    self.assertIn(wheel["url"], (self.data / "requirements-cuda.lock").read_text())
                    self.assertIn(wheel["sha256"], (self.data / "requirements-cuda.lock").read_text())

    def test_hash_and_control(self):
        artifact = next(a for a in self.spec["artifacts"] if a["id"] == "silero")
        path = self.downloads / Path(artifact["url"]).name
        path.write_bytes(b"bad hash")
        result = self.install(1)
        self.assertIn("download=hash-mismatch", result.stderr)
        self.not_ready()
        self.assertFalse((self.state / "local-ready.json").exists())
        self.assertFalse(list((self.data / "models").glob("*.partial")))
        self.mutant("if judge.sha256(partial) != digest:", "if False and judge.sha256(partial) != digest:")
        # The input verifier independently refuses corrupted model bytes.
        result = self.install(1)
        self.assertNotIn("download=hash-mismatch", result.stderr)
        self.assertIn("input=hash-mismatch", result.stderr)

    def test_child_failure_rules_and_controls(self):
        for key, code in (("uv_exit", 6), ("curl_exit", 7), ("probe_exit", 1), ("probe_exit", 77)):
            with self.subTest(key=key, code=code):
                self.install()
                self.ready()
                self.config[key] = code
                self.write_config()
                self.install(code)
                self.not_ready()
                self.assertFalse((self.state / "local-ready.json").exists())
                # Preserve the rule's text while changing its effect.
                self.mutant("if result.returncode != 0:", "if False and result.returncode != 0:")
                self.install()
                self.ready()
                (self.plugin / "setup-local").write_text((PLUGIN / "setup-local").read_text())
                del self.config[key]
                self.write_config()

    def test_marker_invalidation_control(self):
        self.install()
        self.ready()
        self.config["uv_exit"] = 77
        self.write_config()
        self.install(77)
        self.assertFalse((self.state / "local-ready.json").exists())
        self.config["uv_exit"] = 0
        self.write_config()
        self.install()
        self.mutant("marker.unlink(missing_ok=True)", "False and marker.unlink(missing_ok=True)")
        self.config["uv_exit"] = 77
        self.write_config()
        self.install(77)
        self.assertTrue((self.state / "local-ready.json").exists(), "invalidation control did not reach the marker")

    def test_identity_and_controls(self):
        cases = [
            ("requirements-local.lock", "lock"),
            ("measure-local", "probe"),
            ("venv/installed", "runtime"),
        ]
        for filename, name in cases:
            with self.subTest(name=name):
                self.install()
                path = self.data / filename if filename.startswith("venv/") else self.plugin / filename
                original = path.read_bytes()
                path.write_bytes(original + b"\n# changed\n")
                self.not_ready()
                self.mutant("if saved != identity(judge, tier, data):", "if False and saved != identity(judge, tier, data):")
                self.ready()
                path.write_bytes(original)
                (self.plugin / "setup-local").write_text((PLUGIN / "setup-local").read_text())

    def test_changed_during_probe_control(self):
        self.config["change_runtime"] = True
        self.write_config()
        result = self.install(1)
        self.assertIn("runtime=changed-during-probe", result.stderr)
        self.not_ready()
        self.mutant("if ready != identity(judge, tier, data):", "if False and ready != identity(judge, tier, data):")
        self.install()
        # The saved pre-probe identity still makes status refuse.
        self.assertTrue((self.state / "local-ready.json").exists())
        self.not_ready()

    def test_serialization_and_control(self):
        self.install()
        self.ready()
        marker = (self.state / "local-ready.json").read_bytes()
        with (self.state / "local-setup.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.install(1)
            self.assertIn("setup=busy", result.stderr)
            self.assertEqual(self.report(), {"tone": "info", "text": "Setting up", "action": False})
            self.assertEqual((self.state / "local-ready.json").read_bytes(), marker)
            self.mutant("fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)",
                        "False and fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)")
            self.install()

    def test_archive_path_control(self):
        archive = self.root / "unsafe.tar"
        with tarfile.open(archive, "w") as bundle:
            item = tarfile.TarInfo("../escaped")
            item.size = 1
            bundle.addfile(item, io.BytesIO(b"x"))
        # The extractor itself, not a second implementation.
        module = self.load_module()
        with self.assertRaisesRegex(ValueError, "archive=unsafe-member"):
            module.extract(archive, self.root / "models")
        self.mutant('if path.is_absolute() or ".." in path.parts or not (member.isdir() or member.isfile()):',
                    'if False and (path.is_absolute() or ".." in path.parts or not (member.isdir() or member.isfile())):')
        module = self.load_module()
        # Python's data filter remains a separate dependency guard.
        with self.assertRaises(tarfile.OutsideDestinationError):
            module.extract(archive, self.root / "models")

    def test_status_lock_control(self):
        self.install()
        self.ready()
        with (self.state / "local-setup.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.report(), {"tone": "info", "text": "Setting up", "action": False})
        self.mutant("fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)",
                    "False and fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)")
        self.install()
        with (self.state / "local-setup.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.ready()

    def load_module(self):
        loader = importlib.machinery.SourceFileLoader("setup_case", str(self.plugin / "setup-local"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        return module

    def test_probe_delegation_and_control(self):
        module = self.load_module()
        calls = []
        class Judge:
            def run(self, value, artifacts, models, provider, seconds, scope):
                calls.append((artifacts, models, provider, seconds, scope))
        module.probe(Judge(), self.spec, "large", self.data)
        artifacts = [a for a in self.spec["artifacts"] if a["id"] in self.spec["tiers"]["large"]["artifacts"]]
        self.assertEqual(calls, [(artifacts, self.data / "models", "cuda", None, "large")])
        self.mutant('judge.run(value, artifacts, data / "models", provider, None, tier)',
                    'False and judge.run(value, artifacts, data / "models", provider, None, tier)')
        calls.clear()
        self.load_module().probe(Judge(), self.spec, "large", self.data)
        self.assertEqual(calls, [], "probe control must break delegation")

    def test_lock_install_flags_control(self):
        self.install()
        self.ready()
        self.mutant('"--require-hashes", "--only-binary", ":all:", str(requirements)',
                    '"--only-binary", ":all:", str(requirements)')
        self.install(1)
        self.not_ready()

    def test_cancel_and_retry(self):
        self.install()
        self.config["hold_probe"] = True
        self.write_config()
        with subprocess.Popen([sys.executable, "-I", str(self.plugin / "setup-local"), "install", "small"],
                              env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as child:
            # Wait for the private interpreter double to reach inference.
            deadline = time.monotonic() + 10
            while not (self.data / "probe-held").exists():
                self.assertIsNone(child.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=10), 143)
        self.assertFalse((self.state / "local-ready.json").exists())
        self.not_ready()
        # Release the double, not a host interpreter or process by name.
        (self.data / "probe-release").write_text("release")
        self.config["hold_probe"] = False
        self.write_config()
        self.install()
        self.ready()
        # No extra control is needed for Python's process termination.
        # The marker-invalidation and child-exit controls prove the owned
        # readiness mechanism; the OS signal is not a new production guard.

    def test_tui_and_control(self):
        # Neutral core presentation double. The actual TUI still selects
        # from its snapshot and executes the real installer.
        library = self.root / "tui-lib.sh"
        library.write_text('vgs_tui_header() { :; }\nvgs_tui_choose() { printf "%s\\n" "$1"; }\n')
        env = dict(self.env, VGS_TUI_LIB=str(library), VGS_PLUGIN_DIR=str(self.plugin))
        script = self.plugin / "tui/setup-local.sh"
        run = lambda *args: subprocess.run(["bash", str(script), *args],
            env=env, capture_output=True, text=True, check=False, timeout=30)
        result = run()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.ready()
        self.assertEqual(run("unexpected").returncode, 2)
        (self.commands / "uv").unlink()
        self.assertEqual(run().returncode, 77)
        source = script.read_text()
        needle = 'exec python3 -I "$VGS_PLUGIN_DIR/setup-local" install "$tier"'
        self.assertEqual(source.count(needle), 1)
        changed = source.replace(needle, ': python3 -I "$VGS_PLUGIN_DIR/setup-local" install "$tier"')
        self.assertNotEqual(changed, source)
        script.write_text(changed)
        shutil.copyfile(DOUBLE, self.commands / "uv")
        (self.commands / "uv").chmod(0o700)
        (self.state / "local-ready.json").unlink()
        self.assertEqual(run().returncode, 0)
        self.not_ready()

    def test_shipped_lock_runtime_pins(self):
        lines = (PLUGIN / "requirements-local.lock").read_text().splitlines()
        lines += (PLUGIN / "requirements-local-cpu.lock").read_text().splitlines()
        pins = {}
        for line in lines:
            if not line or line.startswith(("#", "-r ")):
                continue
            match = re.fullmatch(r"([a-z0-9-]+)==([0-9.]+) --hash=sha256:([a-f0-9]{64})", line)
            self.assertIsNotNone(match, line)
            self.assertNotIn(match[1], pins)
            pins[match[1]] = match[2]
        for name, runtime in self.spec["runtimes"].items():
            self.assertIn(pins[name], runtime["versions"])
        self.assertIn("sherpa-onnx-core", pins)
        # This data test has no production behavior to mutate. The install
        # fixture separately refuses removing require-hashes from its argv.


if __name__ == "__main__":
    namespace_entry()
    unittest.main()
