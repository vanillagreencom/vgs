"""Run the shipped setup main/roots/probe path with synthetic inference only.

Source: setup-local entry and measure-local consumer contract, 2026-09-30.
The outer J09 world owns isolation. The real declaration, fixture and model
verifiers remain active. No vendor package or audio device is opened.
"""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
program, tier, expected_file = sys.argv[1:]
expected = json.loads(Path(expected_file).read_text())
loader = importlib.machinery.SourceFileLoader("installed_setup", program)
spec = importlib.util.spec_from_loader(loader.name, loader)
setup = importlib.util.module_from_spec(spec)
loader.exec_module(setup)
judge = setup.measurement()


def inference(value, artifacts, models, provider, seconds, scope):
    """Stand in for vendor execution, not for the setup entry or input judge."""
    judge.clip(value)
    judge.verify(value, models, artifacts)
    state, data = setup.roots()
    assert str(models) == expected["models"]
    assert str(state) == expected["state"]
    assert str(data) == expected["data"]
    assert provider == expected["provider"] and seconds is None and scope == tier
    assert [a["id"] for a in artifacts] == expected["artifacts"]
    assert not {"API_KEY", "DBUS_SESSION_BUS_ADDRESS", "PULSE_SERVER"} & os.environ.keys()
    (data / "probed").write_text(tier)
    (data / "probe-observed.json").write_text(json.dumps({
        "models": str(models), "state": str(state), "data": str(data)}))


judge.run = inference
sys.argv = [program, "probe", tier]
try:
    setup.main()
except judge.Unavailable as error:
    print(f"fixture-probe: unavailable={error}", file=sys.stderr)
    sys.exit(77)
