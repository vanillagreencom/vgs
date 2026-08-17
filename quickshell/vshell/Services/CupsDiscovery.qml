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

    function hasBonjourSuffix(host) {
        const lower = (host || "").toLowerCase();
        return lower.includes("._ipp._tcp") || lower.includes("._ipps._tcp") || lower.includes("._printer._tcp") || lower.includes("._pdl-datastream._tcp");
    }

    function usbSerial(uri) {
        const match = (uri || "").match(/[?&]serial=([^&]+)/i);
        return match ? root.decodeUri(match[1]) : "";
    }

    function instanceName(device) {
        if (!device)
            return "";
        const uri = device.uri || "";
        const host = root.decodeUri(device.ip || "");
        if (root.hasBonjourSuffix(host))
            return root.stripServiceSuffix(host);
        const info = root.decodeUri(device.info || "");
        if (info && info !== uri && !info.includes("://") && info !== host)
            return info;
        if (device.makeModel) {
            const model = root.decodeUri(device.makeModel);
            const serial = root.usbSerial(uri);
            return serial ? model + " " + serial : model;
        }
        const serial = root.usbSerial(uri);
        if (serial)
            return serial;
        const path = uri.replace(/^[^:]+:\/\/[^/]*/, "");
        if (path && path !== "/" && !path.startsWith("?"))
            return root.decodeUri(path.replace(/^\//, "").split("?")[0]);
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
        const host = root.decodeUri(device.ip || "");
        if (root.hasBonjourSuffix(host))
            return root.stripServiceSuffix(host).toLowerCase();
        return device.uri || "";
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
            const usedLabels = {};
            const alts = candidates.filter(d => d.uri !== recommended.uri).map(d => {
                let label = root.transportLabel(root.deviceScheme(d.uri));
                if (usedLabels[label]) {
                    usedLabels[label] += 1;
                    label = label + " " + usedLabels[label];
                } else {
                    usedLabels[label] = 1;
                }
                return {
                    uri: d.uri,
                    label: label,
                    device: d
                };
            });
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

    function collectJobs(printers, names) {
        const jobs = [];
        const list = names || [];
        for (var i = 0; i < list.length; i++) {
            const printer = printers ? printers[list[i]] : null;
            const queued = printer && printer.jobs ? printer.jobs : [];
            for (var j = 0; j < queued.length; j++)
                jobs.push(queued[j]);
        }
        return jobs;
    }
}
