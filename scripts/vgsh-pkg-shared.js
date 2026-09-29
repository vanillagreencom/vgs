// Shared paths for the vgsh package-manager suites.
"use strict";
const path = require("node:path");

const repo = path.join(__dirname, "..");
const TABLE = path.join(repo, "shell", "Core", "PackageManagers.js");
const FIXTURES = path.join(repo, "scripts", "fixtures", "pkg");

module.exports = { repo, TABLE, FIXTURES };
