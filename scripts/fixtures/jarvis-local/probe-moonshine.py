"""Test-only unbounded Moonshine failure probe; local inputs and namespace only."""
import importlib.machinery
import importlib.util
import json
import importlib.metadata
from pathlib import Path
import sys

sys.dont_write_bytecode = True
repo, models = map(lambda p: Path(p).resolve(), sys.argv[1:])
program = repo / "shell/plugins/vgs.jarvis/measure-local"
loader = importlib.machinery.SourceFileLoader("unbounded_measure", str(program))
spec = importlib.util.spec_from_loader(loader.name, loader)
measure = importlib.util.module_from_spec(spec)
loader.exec_module(measure)
value = measure.manifest(program.parent / "artifacts.json")
artifact = next(a.copy() for a in value["artifacts"] if a["id"] == "moonshine")
del artifact["maxInputSamples"]
print(json.dumps({"probe": "moonshine-unbounded", "instrument_sha256": measure.sha256(program),
    "manifest_sha256": measure.sha256(program.parent / "artifacts.json"),
    "probe_sha256": measure.sha256(Path(__file__)), "input_seconds": 60,
    "removed_bound": True,
    "versions": {name: importlib.metadata.version(name) for name in value["runtimes"]}}), flush=True)
try:
    measure.run(value, [artifact], models, "cpu", 60, "moonshine-unbounded")
except measure.Unavailable as error:
    print(f"moonshine-probe: unavailable={error}", file=sys.stderr)
    raise SystemExit(77)
except (ValueError, RuntimeError, OSError) as error:
    print(f"moonshine-probe: failed={error}", file=sys.stderr)
    raise SystemExit(1)
