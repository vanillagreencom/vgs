.pragma library

// Provider presentation. Material Symbols has no brand glyphs, so providers are
// distinguished by a shape that matches what the backend *is* (consumer drive,
// object store, protocol endpoint) rather than by a logo. The label carries the
// brand.
var PROVIDER_ICONS = {
    "drive": "add_to_drive",
    "dropbox": "cloud",
    "onedrive": "cloud",
    "box": "inbox",
    "pcloud": "cloud",
    "mega": "cloud",
    "iclouddrive": "cloud",
    "protondrive": "encrypted",
    "jottacloud": "cloud",
    "koofr": "cloud",
    "opendrive": "cloud",
    "yandex": "cloud",
    "zoho": "cloud",
    "seafile": "cloud",
    "nextcloud": "cloud",
    "webdav": "dns",
    "sftp": "terminal",
    "ftp": "terminal",
    "smb": "folder_shared",
    "s3": "database",
    "b2": "database",
    "azureblob": "database",
    "googlecloudstorage": "database",
    "google cloud storage": "database",
    "swift": "database",
    "storj": "database",
    "hdfs": "database",
    "sia": "database",
    "internetarchive": "history_edu",
    "putio": "cloud",
    "premiumizeme": "cloud",
    "pikpak": "cloud",
    "gphotos": "photo_library",
    "google photos": "photo_library"
};

function providerIcon(type) {
    if (!type)
        return "cloud";
    var key = String(type).toLowerCase();
    return PROVIDER_ICONS[key] || "cloud";
}

// Sync-mode presentation, shared by the wizard, the folder list and the widget.
var MODE_ICONS = {
    "twoway": "sync_alt",
    "backup": "cloud_upload",
    "restore": "cloud_download",
    "stream": "cloud_sync"
};

function modeIcon(mode) {
    if (!mode)
        return "folder";
    return MODE_ICONS[String(mode)] || "folder";
}

var STATE_ICONS = {
    "syncing": "sync",
    "paused": "pause_circle",
    "error": "error",
    "needsResync": "rule_settings",
    "mounted": "cloud_done",
    "mounting": "cloud_sync",
    "unmounted": "cloud_off",
    "idle": "check_circle"
};

function stateIcon(state) {
    return STATE_ICONS[String(state)] || "check_circle";
}

// Schedule choices offered per folder. The floor is five minutes; anything
// tighter is what the real-time watcher is for.
function intervalOptions(tr) {
    return [
        {
            "value": 0,
            "label": tr("Manual only")
        },
        {
            "value": 300,
            "label": tr("Every 5 minutes")
        },
        {
            "value": 900,
            "label": tr("Every 15 minutes")
        },
        {
            "value": 1800,
            "label": tr("Every 30 minutes")
        },
        {
            "value": 3600,
            "label": tr("Every hour")
        },
        {
            "value": 21600,
            "label": tr("Every 6 hours")
        },
        {
            "value": 86400,
            "label": tr("Once a day")
        }
    ];
}
