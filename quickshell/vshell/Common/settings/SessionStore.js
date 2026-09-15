.pragma library

    .import "./SessionSpec.js" as SpecModule

// Apply `mapRef` to a `ref` key's value or to every value of a `refMap` key.
// SessionData's _parseSession passes Paths.resolveRef on the way in and its
// _sessionJson passes Paths.wallpaperRef on the way out, so the store itself stays
// free of QML and of the path rule. `mapRef` has no default: a caller that omits it
// throws on the first marked key rather than quietly persisting an absolute path.
function mapped(spec, value, mapRef) {
    if (value === undefined || value === null) return value;
    if (spec.ref) return mapRef(value);
    if (!spec.refMap) return value;
    var out = {};
    for (var key in value) out[key] = mapRef(value[key]);
    return out;
}

function parse(root, jsonObj, mapRef) {
    var SPEC = SpecModule.SPEC;

    if (!jsonObj) return;

    for (var k in SPEC) {
        if (!(k in jsonObj)) {
            root[k] = SPEC[k].def;
        }
    }

    for (var k in jsonObj) {
        if (!SPEC[k]) continue;
        var raw = jsonObj[k];
        var spec = SPEC[k];
        var coerce = spec.coerce;
        var value = coerce ? (coerce(raw) !== undefined ? coerce(raw) : root[k]) : raw;
        root[k] = mapped(spec, value, mapRef);
    }
}

function toJson(root, mapRef) {
    var SPEC = SpecModule.SPEC;
    var out = {};
    for (var k in SPEC) {
        if (SPEC[k].persist === false) continue;
        out[k] = mapped(SPEC[k], root[k], mapRef);
    }
    out.configVersion = root.sessionConfigVersion;
    return out;
}

function migrateToVersion(obj, targetVersion, settingsData) {
    if (!obj) return null;

    var session = JSON.parse(JSON.stringify(obj));
    var currentVersion = session.configVersion || 0;

    if (currentVersion >= targetVersion) {
        return null;
    }

    if (currentVersion < 2) {
        console.info("SessionData: Migrating session from version", currentVersion, "to version 2");
        console.info("SessionData: Importing weather location and coordinates from settings");

        if (settingsData && typeof settingsData !== "undefined") {
            if (session.weatherLocation === undefined || session.weatherLocation === "New York, NY") {
                var settingsWeatherLocation = settingsData._legacyWeatherLocation;
                if (settingsWeatherLocation && settingsWeatherLocation !== "New York, NY") {
                    session.weatherLocation = settingsWeatherLocation;
                    console.info("SessionData: Migrated weatherLocation:", settingsWeatherLocation);
                }
            }

            if (session.weatherCoordinates === undefined || session.weatherCoordinates === "40.7128,-74.0060") {
                var settingsWeatherCoordinates = settingsData._legacyWeatherCoordinates;
                if (settingsWeatherCoordinates && settingsWeatherCoordinates !== "40.7128,-74.0060") {
                    session.weatherCoordinates = settingsWeatherCoordinates;
                    console.info("SessionData: Migrated weatherCoordinates:", settingsWeatherCoordinates);
                }
            }
        }

        session.configVersion = 2;
    }

    if (currentVersion < 3) {
        console.info("SessionData: Migrating session to version 3");
        session.configVersion = 3;
    }

    return session;
}

function cleanup(fileText) {
    var getValidKeys = SpecModule.getValidKeys;
    if (!fileText || !fileText.trim()) return null;

    try {
        var session = JSON.parse(fileText);
        var validKeys = getValidKeys();
        var needsSave = false;

        for (var key in session) {
            if (validKeys.indexOf(key) < 0) {
                delete session[key];
                needsSave = true;
            }
        }

        return needsSave ? JSON.stringify(session, null, 2) : null;
    } catch (e) {
        console.warn("SessionData: Failed to cleanup unused keys:", e.message);
        return null;
    }
}
