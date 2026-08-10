#!/usr/bin/env python3
"""Validate .coderabbit.yaml against CodeRabbit's own published schema.

CodeRabbit rejects an invalid config and reviews with DEFAULT settings instead.
It reports that nowhere a PR can see it: the review still happens, still posts,
and still says nothing about the configuration having been discarded. VGS shipped
a `tone_instructions` of 376 characters against a documented 250-character limit,
so the whole file had been inert on every PR for as long as it had been that
long — a configuration that reports nothing and quietly does not apply, which is
the same class as the checks the rest of VGS-42 fixes.

The schema is vendored at third_party/coderabbit-schema/ (see its README for
why it is not fetched at check time).

WHY A HAND-WRITTEN VALIDATOR. `jsonschema` is not a VGS dependency and adding
one to run a single check would be a worse trade than implementing the fifteen
keywords this schema actually uses. The trade is only safe because of the
unsupported-keyword guard below: if a refreshed schema introduces a keyword this
does not implement, the check FAILS and names it. Silently ignoring an unknown
constraint would under-validate the config while reporting success — which is
the defect this file exists to catch, one level up.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    print(
        "check-coderabbit-config: FAIL: PyYAML is not installed, so .coderabbit.yaml\n"
        "could not be parsed and NOTHING was validated (pacman -S python-yaml).",
        file=sys.stderr,
    )
    raise SystemExit(1)

REPO_ROOT = Path(__file__).resolve().parents[1]
CONFIG = REPO_ROOT / ".coderabbit.yaml"
SCHEMA = REPO_ROOT / "third_party" / "coderabbit-schema" / "schema.v2.json"

# Keywords this validator implements. Anything else in the schema is a hole.
# `description`, `default`, `enumNames` and `$schema` are annotations that
# constrain nothing, so they are known-and-ignored rather than unimplemented.
ENFORCED = {
    "type", "properties", "items", "enum", "required", "additionalProperties",
    "minLength", "maxLength", "minimum", "maximum", "minItems", "maxItems",
    "propertyNames", "anyOf", "pattern",
}
ANNOTATIONS = {"description", "default", "enumNames", "$schema", "title", "examples"}

JSON_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "null": type(None),
}


def unsupported_keywords(schema) -> set[str]:
    """Every keyword in the schema that this validator neither enforces nor ignores."""
    found: set[str] = set()

    def walk(node):
        if isinstance(node, dict):
            for key, value in node.items():
                if key not in ENFORCED and key not in ANNOTATIONS:
                    found.add(key)
                if key in ("properties", "patternProperties", "$defs", "definitions"):
                    if isinstance(value, dict):
                        for sub in value.values():
                            walk(sub)
                elif key in ("items", "additionalProperties", "propertyNames", "not", "if", "then", "else"):
                    walk(value)
                elif key in ("anyOf", "oneOf", "allOf"):
                    if isinstance(value, list):
                        for sub in value:
                            walk(sub)
        elif isinstance(node, list):
            for sub in node:
                walk(sub)

    walk(schema)
    return found


def validate(value, schema, path: str, errors: list[str]) -> None:
    if not isinstance(schema, dict):
        return

    if "anyOf" in schema:
        branches = schema["anyOf"]
        for branch in branches:
            attempt: list[str] = []
            validate(value, branch, path, attempt)
            if not attempt:
                break
        else:
            errors.append(f"{path}: matches none of the {len(branches)} allowed shapes")
        return

    expected = schema.get("type")
    if expected:
        names = expected if isinstance(expected, list) else [expected]
        # bool is a subclass of int in Python; JSON Schema treats them apart.
        ok = False
        for name in names:
            python_type = JSON_TYPES.get(name)
            if python_type is None:
                continue
            if name in ("integer", "number") and isinstance(value, bool):
                continue
            if isinstance(value, python_type):
                ok = True
                break
        if not ok:
            errors.append(f"{path}: expected {'/'.join(names)}, got {type(value).__name__}")
            return

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is not one of {schema['enum']}")

    if isinstance(value, str):
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(
                f"{path}: {len(value)} characters, limit is {schema['maxLength']}"
            )
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(
                f"{path}: {len(value)} characters, minimum is {schema['minLength']}"
            )
        if "pattern" in schema:
            import re

            if not re.search(schema["pattern"], value):
                errors.append(f"{path}: {value!r} does not match /{schema['pattern']}/")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: {value} is below the minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: {value} is above the maximum {schema['maximum']}")

    if isinstance(value, list):
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path}: {len(value)} items, limit is {schema['maxItems']}")
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path}: {len(value)} items, minimum is {schema['minItems']}")
        if "items" in schema:
            for index, item in enumerate(value):
                validate(item, schema["items"], f"{path}[{index}]", errors)

    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for name in schema.get("required", []):
            if name not in value:
                errors.append(f"{path}: missing required key {name!r}")
        additional = schema.get("additionalProperties", True)
        for key, item in value.items():
            child = f"{path}.{key}" if path else key
            if key in properties:
                validate(item, properties[key], child, errors)
            elif additional is False:
                errors.append(f"{child}: not a recognised setting")
            elif isinstance(additional, dict):
                validate(item, additional, child, errors)
            if "propertyNames" in schema:
                validate(key, schema["propertyNames"], f"{child} (key)", errors)


def main() -> int:
    if not CONFIG.is_file():
        print(f"check-coderabbit-config: FAIL: {CONFIG} does not exist", file=sys.stderr)
        return 1
    if not SCHEMA.is_file():
        print(
            f"check-coderabbit-config: FAIL: {SCHEMA} is missing, so nothing was validated.\n"
            "Restore it (see third_party/coderabbit-schema/README.md).",
            file=sys.stderr,
        )
        return 1

    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))

    holes = unsupported_keywords(schema)
    if holes:
        print(
            "check-coderabbit-config: FAIL: the vendored schema uses JSON Schema "
            "keyword(s) this validator does not implement: " + ", ".join(sorted(holes)),
            file=sys.stderr,
        )
        print(
            "Implement them in validate(), or the config is checked against fewer\n"
            "constraints than the schema states while this still reports success.",
            file=sys.stderr,
        )
        return 1

    try:
        config = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        print(f"check-coderabbit-config: FAIL: .coderabbit.yaml is not valid YAML: {exc}", file=sys.stderr)
        return 1
    if config is None:
        config = {}

    errors: list[str] = []
    validate(config, schema, "", errors)

    if errors:
        print("check-coderabbit-config: FAIL: .coderabbit.yaml violates CodeRabbit's schema", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        print(
            "\nCodeRabbit rejects an invalid config and reviews with DEFAULT settings,\n"
            "reporting nothing on the PR. Every setting in this file is inert until\n"
            "these are fixed.",
            file=sys.stderr,
        )
        return 1

    print("check-coderabbit-config: ok (.coderabbit.yaml validates against the vendored schema)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
