// Test-side validator for pinned protocol schema excerpts. It implements the
// JSON Schema keywords those excerpts keep and refuses any other keyword, so
// an excerpt cannot rely on a rule this checker would silently skip.
//
// An excerpt file is {source, rule, omitted, schemas}; $ref names
// "#/schemas/<name>". Two rules are stricter than the published schemas:
// - Every object is closed. A property an object schema does not name fails
//   unless its additionalProperties is true or a schema. A misspelt request
//   field or an unpinned fixture field must fail, not pass as an extension.
// - nullable (OpenAPI 3.0) admits null beside the schema's type.
// errors() returns ["<path>: <rule>", ...]; an empty list is a valid value.
"use strict";

const KEYWORDS = new Set(["$ref", "type", "nullable", "enum", "required", "properties",
    "additionalProperties", "items", "minItems", "oneOf", "anyOf"]);

function instrument(reason) { throw new Error("schema-check: " + reason); }

function typeOf(value) {
    if (value === null) return "null";
    if (Array.isArray(value)) return "array";
    if (typeof value === "number") return Number.isInteger(value) ? "integer" : "number";
    return typeof value;
}

function same(left, right) {
    return JSON.stringify(left) === JSON.stringify(right);
}

function errors(excerpt, name, value) {
    if (!excerpt || typeof excerpt.schemas !== "object" || !Object.hasOwn(excerpt.schemas, name))
        instrument("schema=" + name);
    const found = [];
    function check(schema, current, where) {
        if (schema === null || typeof schema !== "object" || Array.isArray(schema)) instrument("schema-shape path=" + where);
        for (const keyword of Object.keys(schema))
            if (!KEYWORDS.has(keyword)) instrument("keyword=" + keyword + " path=" + where);
        if (Object.hasOwn(schema, "$ref")) {
            const match = /^#\/schemas\/(.+)$/.exec(schema.$ref);
            if (!match || !Object.hasOwn(excerpt.schemas, match[1])) instrument("ref=" + schema.$ref);
            check(excerpt.schemas[match[1]], current, where);
        }
        const actual = typeOf(current);
        if (Object.hasOwn(schema, "type")) {
            const allowed = [schema.type].flat();
            if (schema.nullable === true) allowed.push("null");
            if (!allowed.includes(actual) && !(actual === "integer" && allowed.includes("number")))
                found.push(where + ": type " + actual + " not " + allowed.join("|"));
        }
        if (Object.hasOwn(schema, "enum") && !schema.enum.some(option => same(option, current)))
            found.push(where + ": enum");
        if (actual === "object" && (Object.hasOwn(schema, "properties") || [schema.type].flat().includes("object"))) {
            const properties = schema.properties ?? {};
            for (const key of schema.required ?? [])
                if (!Object.hasOwn(current, key)) found.push(where + ": required " + key);
            for (const [key, item] of Object.entries(current)) {
                if (Object.hasOwn(properties, key)) check(properties[key], item, where + "." + key);
                else if (schema.additionalProperties === true) continue;
                else if (typeof schema.additionalProperties === "object") check(schema.additionalProperties, item, where + "." + key);
                else found.push(where + ": property " + key + " not pinned");
            }
        }
        if (actual === "array") {
            if (Object.hasOwn(schema, "minItems") && current.length < schema.minItems) found.push(where + ": minItems");
            if (Object.hasOwn(schema, "items")) current.forEach((item, index) => check(schema.items, item, where + "[" + index + "]"));
        }
        for (const keyword of ["oneOf", "anyOf"]) {
            if (!Object.hasOwn(schema, keyword)) continue;
            const matches = schema[keyword].filter(member => {
                const mark = found.length;
                check(member, current, where);
                const ok = found.length === mark;
                found.length = mark;
                return ok;
            }).length;
            if (keyword === "oneOf" ? matches !== 1 : matches === 0)
                found.push(where + ": " + keyword + " matched " + matches);
        }
    }
    check(excerpt.schemas[name], value, "$");
    return found;
}

module.exports = { errors };
