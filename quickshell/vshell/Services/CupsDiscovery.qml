pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common

Singleton {
    id: root

    readonly property var bareProtocols: ["ipp", "ipps", "http", "https", "lpd", "socket", "beh", "dnssd", "mdns", "smb", "file", "cups-brf"]

    function decodeUri(str) {
        if (!str)
            return "";
        try {
            return decodeURIComponent(str.replace(/\+/g, " "));
        } catch (e) {
            return str;
        }
    }

    function deviceScheme(uri) {
        if (!uri)
            return "";
        const cut = uri.indexOf(":");
        return cut > 0 ? uri.slice(0, cut).toLowerCase() : "";
    }

    function isBareProtocol(uri) {
        if (!uri)
            return true;
        const lower = uri.toLowerCase();
        for (let proto of root.bareProtocols) {
            if (lower === proto || lower === proto + ":" || lower === proto + "://" || lower === proto + ":///")
                return true;
        }
        return false;
    }

    function isVirtualBackend(device) {
        if (!device)
            return false;
        const uri = (device.uri || "").toLowerCase();
        if (uri.includes("cups-pdf") || uri.startsWith("cups-brf"))
            return true;
        return device.class === "file" && (uri === "file" || uri.startsWith("file:"));
    }

    function instanceName(device) {
        if (!device)
            return "";
        const info = root.decodeUri(device.info || "");
        const host = root.decodeUri(device.ip || "");
        const uri = device.uri || "";
        const fromHost = root.stripServiceSuffix(host);
        if (fromHost && fromHost !== host && !fromHost.includes("://"))
            return fromHost;
        if (info && info !== uri && !info.includes("://") && info !== host)
            return info;
        if (fromHost && !fromHost.includes("://"))
            return fromHost;
        if (device.makeModel)
            return root.decodeUri(device.makeModel);
        return uri;
    }

    function stripServiceSuffix(host) {
        if (!host)
            return "";
        const lower = host.toLowerCase();
        const suffixes = [
            "._ipp._tcp.local", "._ipps._tcp.local", "._printer._tcp.local",
            "._pdl-datastream._tcp.local", "._ipp._tcp", "._ipps._tcp", "._printer._tcp"
        ];
        for (let suffix of suffixes) {
            if (lower.endsWith(suffix))
                return host.slice(0, host.length - suffix.length).trim();
        }
        const svc = host.indexOf("._");
        if (svc > 0)
            return host.slice(0, svc).trim();
        return host;
    }

    function groupKey(device) {
        const name = root.instanceName(device).toLowerCase();
        if (name)
            return name;
        const host = root.stripServiceSuffix(root.decodeUri(device.ip || "")).toLowerCase();
        return host || (device.uri || "");
    }

    function schemeRank(scheme) {
        switch (scheme) {
        case "dnssd":
            return 0;
        case "ipps":
            return 1;
        case "ipp":
            return 2;
        case "usb":
            return 3;
        default:
            return 8;
        }
    }

    function transportLabel(scheme) {
        switch (scheme) {
        case "dnssd":
            return I18n.tr("Bonjour");
        case "ipps":
            return I18n.tr("Secure IPP");
        case "ipp":
            return I18n.tr("Network IPP");
        case "socket":
            return I18n.tr("AppSocket");
        case "lpd":
            return I18n.tr("LPD");
        case "usb":
            return I18n.tr("USB");
        default:
            return scheme || I18n.tr("Network");
        }
    }

    function pickRecommended(candidates) {
        return candidates.slice().sort((a, b) => {
            const rank = root.schemeRank(root.deviceScheme(a.uri)) - root.schemeRank(root.deviceScheme(b.uri));
            if (rank !== 0)
                return rank;
            return (a.uri || "").localeCompare(b.uri || "");
        })[0];
    }

    function groupDevices(devices) {
        if (!devices || devices.length === 0)
            return [];
        const buckets = {};
        for (const device of devices) {
            if (!device || !device.uri || root.isBareProtocol(device.uri) || root.isVirtualBackend(device))
                continue;
            if (device.class === "network" && device.info === "Backend Error Handler")
                continue;
            const key = root.groupKey(device);
            if (!buckets[key])
                buckets[key] = [];
            buckets[key].push(device);
        }
        const grouped = [];
        for (const key of Object.keys(buckets)) {
            const candidates = buckets[key];
            const recommended = root.pickRecommended(candidates);
            const name = root.instanceName(recommended);
            const alts = candidates.filter(d => d.uri !== recommended.uri).map(d => ({
                uri: d.uri,
                label: root.transportLabel(root.deviceScheme(d.uri)),
                device: d
            }));
            grouped.push({
                id: key,
                name: name,
                uri: recommended.uri,
                device: recommended,
                alternatives: alts,
                displayName: name
            });
        }
        grouped.sort((a, b) => a.name.localeCompare(b.name));
        return grouped;
    }

    function getDeviceDisplayName(device) {
        if (!device)
            return "";
        return root.instanceName(device);
    }

    function getDeviceSubtitle(device) {
        if (!device)
            return "";
        const parts = [];
        const scheme = root.deviceScheme(device.uri);
        if (scheme)
            parts.push(root.transportLabel(scheme));
        switch (device.class) {
        case "direct":
            parts.push(I18n.tr("Local"));
            break;
        case "network":
            parts.push(I18n.tr("Network"));
            break;
        }
        if (device.location)
            parts.push(root.decodeUri(device.location));
        return parts.join(" • ");
    }

    function suggestPrinterName(device) {
        if (!device)
            return "";
        let name = root.instanceName(device);
        name = name.replace(/[^a-zA-Z0-9_-]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");
        return name.substring(0, 32) || "Printer";
    }

    function getMatchingPPDs(device, ppds) {
        if (!device || !ppds || ppds.length === 0)
            return [];
        const uri = device.uri || "";
        const isNetwork = uri.startsWith("dnssd://") || uri.startsWith("ipp://") || uri.startsWith("ipps://");
        if (isNetwork) {
            const suggested = ppds.filter(p => p.name === "everywhere" || p.name === "driverless" || p.name.startsWith("driverless:")).sort((a, b) => (a.name !== "everywhere") - (b.name !== "everywhere"));
            if (suggested.length > 0)
                return suggested;
        }
        if (!device.makeModel)
            return [];
        const makeModelLower = device.makeModel.toLowerCase();
        const words = makeModelLower.split(/[\s_-]+/).filter(w => w.length > 2);
        return ppds.filter(p => {
            if (!p.makeModel)
                return false;
            const ppdLower = p.makeModel.toLowerCase();
            return words.some(w => ppdLower.includes(w));
        }).slice(0, 10);
    }
}
