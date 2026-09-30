// Audit arguments contain field names, never caller-supplied contents.
// Pattern matching cannot recognize an arbitrary password or private text.
"use strict";
const Tools = require("./Tools.js");

/**
 * Describe an argument envelope without copying its values or unknown keys.
 * The action table supplies field names. Release metadata uses the audit
 * contract's fixed envelope. No text, numeric credential, binary payload,
 * nested value or caller-controlled property name enters the result.
 */
function argumentsFor(kind, tool, args) {
    const fields = kind === "release" ? ["labels", "recipients"]
        : Object.hasOwn(Tools.TABLE, tool) ? Object.keys(Tools.TABLE[tool].schema.properties) : [];
    const result = {};
    if (args === null || typeof args !== "object" || Array.isArray(args)) return "[redacted]";
    for (const field of fields)
        if (Object.hasOwn(args, field)) result[field] = "[redacted]";
    return result;
}

module.exports = { argumentsFor };
