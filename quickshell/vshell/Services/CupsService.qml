pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("CupsService")

    property int refCount: 0

    onRefCountChanged: {
        if (refCount > 0) {
            ensureSubscription();
        } else if (refCount === 0 && VGSBackendService.activeSubscriptions.includes("cups")) {
            VGSBackendService.removeSubscription("cups");
        }
    }

    function ensureSubscription() {
        if (refCount <= 0)
            return;
        if (!VGSBackendService.isConnected)
            return;
        if (VGSBackendService.activeSubscriptions.includes("cups"))
            return;
        if (VGSBackendService.activeSubscriptions.includes("all"))
            return;
        VGSBackendService.addSubscription("cups");
        if (cupsAvailable) {
            getState();
        }
    }

    property var printerNames: []
    property var printers: []
    property string selectedPrinter: ""
    property string expandedPrinter: ""

    property bool cupsAvailable: false
    property bool stateInitialized: false

    property var devices: []
    property var ppds: []
    property var printerClasses: []

    readonly property var discoveredPrinters: CupsDiscovery.groupDevices(devices)
    readonly property var allJobs: CupsDiscovery.collectJobs(printers, printerNames)
    // lpstat -o reports every queued job as "pending", so held state is
    // tracked client-side from successful hold/resume calls.
    property var heldJobIds: Object.create(null)
    // A printer refresh blanks every queue's jobs before the per-printer fetch
    // replies, so allJobs is transiently empty on every refresh. Pruning held
    // ids from that empty window would drop a job's held marker seconds after
    // it was set; ids are only pruned once the outstanding fetches have all
    // answered and the queue is known.
    property int pendingJobFetches: 0

    onAllJobsChanged: root.pruneHeldJobIds()

    function pruneHeldJobIds() {
        if (pendingJobFetches > 0)
            return;
        const next = Object.create(null);
        for (var i = 0; i < allJobs.length; i++) {
            if (heldJobIds[allJobs[i].id])
                next[allJobs[i].id] = true;
        }
        for (const id in heldJobIds) {
            if (!next[id]) {
                heldJobIds = next;
                return;
            }
        }
    }

    function setJobHeld(jobID, held) {
        const next = Object.create(null);
        for (const id in heldJobIds)
            next[id] = true;
        if (held)
            next[jobID] = true;
        else
            delete next[jobID];
        heldJobIds = next;
    }

    function isJobHeld(job) {
        if (!job)
            return false;
        if (job.state === "pending-held" || job.state === "held")
            return true;
        return heldJobIds[job.id] === true;
    }

    function decodeUri(str) {
        return CupsDiscovery.decodeUri(str);
    }

    function getDeviceDisplayName(device) {
        return CupsDiscovery.getDeviceDisplayName(device);
    }

    function getDeviceSubtitle(device) {
        return CupsDiscovery.getDeviceSubtitle(device);
    }

    function suggestPrinterName(device) {
        return CupsDiscovery.suggestPrinterName(device);
    }

    property bool loadingDevices: false
    property bool loadingPPDs: false
    property bool loadingClasses: false
    property bool creatingPrinter: false
    property string devicesError: ""
    property string printersError: ""

    signal cupsStateUpdate

    readonly property string socketPath: Quickshell.env("VGS_SOCKET")

    Component.onCompleted: {
        if (socketPath && socketPath.length > 0) {
            checkVGSCapabilities();
        }
    }

    Connections {
        target: VGSBackendService

        function onConnectionStateChanged() {
            if (VGSBackendService.isConnected) {
                checkVGSCapabilities();
                ensureSubscription();
            }
        }
    }

    Connections {
        target: VGSBackendService
        enabled: VGSBackendService.isConnected

        function onCupsStateUpdate(data) {
            log.debug("Subscription update received");
            applyPrinterSnapshot(data);
        }

        function onCapabilitiesChanged() {
            checkVGSCapabilities();
        }
    }

    function checkVGSCapabilities() {
        if (!VGSBackendService.isConnected)
            return;
        if (VGSBackendService.capabilities.length === 0)
            return;
        cupsAvailable = VGSBackendService.capabilities.includes("cups");

        if (cupsAvailable && !stateInitialized) {
            stateInitialized = true;
            getState();
        }
    }

    function applyPrinterSnapshot(data) {
        if (!data)
            return;
        if (data.error) {
            // Failed snapshot ({printers: [], error}): keep the last good list.
            printersError = String(data.error);
            log.warn("CUPS snapshot failed:", printersError);
            return;
        }
        if (!data.printers) {
            // Mutation broadcasts carry {changed: true} with no printer list.
            getState();
            return;
        }
        printersError = "";
        updatePrinters(data.printers);
        fetchAllJobs();
    }

    function getState() {
        if (!cupsAvailable)
            return;
        VGSBackendService.sendRequest("cups.getPrinters", null, response => {
            if (response.error) {
                printersError = String(response.error);
                log.warn("cups.getPrinters failed:", printersError);
                return;
            }
            applyPrinterSnapshot({ printers: response.result || [] });
        });
    }

    function updatePrinters(printersData) {
        printerNames = printersData.map(p => p.name);

        let printersObj = {};
        for (var i = 0; i < printersData.length; i++) {
            let printer = printersData[i];
            printersObj[printer.name] = {
                "name": printer.name,
                "uri": printer.uri || "",
                "state": printer.state,
                "stateReason": printer.stateReason,
                "location": printer.location || "",
                "info": printer.info || "",
                "makeModel": printer.makeModel || "",
                "accepting": printer.accepting !== false,
                "jobs": []
            };
        }
        printers = printersObj;

        if (printerNames.length > 0) {
            if (selectedPrinter.length > 0) {
                if (!printerNames.includes(selectedPrinter)) {
                    selectedPrinter = printerNames[0];
                }
            } else {
                selectedPrinter = printerNames[0];
            }
        }
    }

    function fetchAllJobs() {
        for (var i = 0; i < printerNames.length; i++) {
            fetchJobsForPrinter(printerNames[i]);
        }
    }

    function fetchJobsForPrinter(printerName) {
        const params = {
            "printerName": printerName
        };

        pendingJobFetches = pendingJobFetches + 1;
        VGSBackendService.sendRequest("cups.getJobs", params, response => {
            if (response.result && printers[printerName]) {
                let updatedPrinters = Object.assign({}, printers);
                updatedPrinters[printerName].jobs = response.result;
                printers = updatedPrinters;
            }
            pendingJobFetches = Math.max(0, pendingJobFetches - 1);
            if (pendingJobFetches === 0)
                root.pruneHeldJobIds();
        });
    }

    function getSelectedPrinter() {
        return selectedPrinter;
    }

    function setSelectedPrinter(printerName) {
        if (printerNames.length > 0) {
            if (printerNames.includes(printerName)) {
                selectedPrinter = printerName;
            } else {
                selectedPrinter = printerNames[0];
            }
        }
    }

    function getPrintersNum() {
        return cupsAvailable ? printerNames.length : 0;
    }

    function getPrintersNames() {
        return cupsAvailable ? printerNames : [];
    }

    function getTotalJobsNum() {
        return cupsAvailable ? allJobs.length : 0;
    }

    function getCurrentPrinterState() {
        if (!cupsAvailable || !selectedPrinter)
            return "";

        var printer = printers[selectedPrinter];
        if (!printer)
            return "";
        return printer.state;
    }

    function getCurrentPrinterStatePrettyShort() {
        if (!cupsAvailable || !selectedPrinter)
            return "";

        var printer = printers[selectedPrinter];
        if (!printer)
            return "";
        return getPrinterStateTranslation(printer.state) + " (" + getPrinterStateReasonTranslation(printer.stateReason) + ")";
    }

    function getCurrentPrinterStatePretty() {
        if (!cupsAvailable || !selectedPrinter)
            return "";

        var printer = printers[selectedPrinter];
        if (!printer)
            return "";
        return getPrinterStateTranslation(printer.state) + " (" + I18n.tr("Reason") + ": " + getPrinterStateReasonTranslation(printer.stateReason) + ")";
    }

    function getCurrentPrinterJobs() {
        if (!cupsAvailable || !selectedPrinter)
            return [];

        return getJobs(selectedPrinter);
    }

    function getJobs(printerName) {
        if (!cupsAvailable)
            return "";

        var printer = printers[printerName];
        return printer.jobs;
    }

    function getJobsNum(printerName) {
        if (!cupsAvailable)
            return 0;

        var printer = printers[printerName];
        return printer.jobs.length;
    }

    function pausePrinter(printerName) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName
        };

        VGSBackendService.sendRequest("cups.pausePrinter", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to pause printer"), response.error);
            } else {
                getState();
            }
        });
    }

    function resumePrinter(printerName) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName
        };

        VGSBackendService.sendRequest("cups.resumePrinter", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to resume printer"), response.error);
            } else {
                getState();
            }
        });
    }

    function cancelJob(printerName, jobID) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName,
            "jobID": jobID
        };

        VGSBackendService.sendRequest("cups.cancelJob", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to cancel selected job"), response.error);
            } else {
                fetchJobsForPrinter(printerName);
            }
        });
    }

    function purgeJobs(printerName) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName
        };

        VGSBackendService.sendRequest("cups.purgeJobs", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to cancel all jobs"), response.error);
            } else {
                fetchJobsForPrinter(printerName);
            }
        });
    }

    function getDevices() {
        if (!cupsAvailable)
            return;
        loadingDevices = true;
        devicesError = "";
        VGSBackendService.sendRequest("cups.getDevices", null, response => {
            loadingDevices = false;
            if (response.error) {
                devices = [];
                devicesError = String(response.error);
                ToastService.showError(I18n.tr("Failed to scan for printers"), devicesError);
                return;
            }
            devices = response.result || [];
        });
    }

    function getPPDs() {
        if (!cupsAvailable)
            return;
        loadingPPDs = true;
        VGSBackendService.sendRequest("cups.getPPDs", null, response => {
            loadingPPDs = false;
            if (response.result) {
                ppds = response.result;
            }
        });
    }

    function getClasses() {
        if (!cupsAvailable)
            return;
        loadingClasses = true;
        VGSBackendService.sendRequest("cups.getClasses", null, response => {
            loadingClasses = false;
            if (response.result) {
                printerClasses = response.result;
            }
        });
    }

    function testConnection(host, port, protocol, queue, callback) {
        if (!cupsAvailable)
            return;
        const params = {
            "host": host,
            "port": port,
            "protocol": protocol
        };
        if (queue)
            params.queue = queue;

        VGSBackendService.sendRequest("cups.testConnection", params, response => {
            if (callback)
                callback(response);
        });
    }

    function createPrinter(name, deviceURI, ppd, options, callback) {
        if (!cupsAvailable)
            return;
        creatingPrinter = true;
        const params = {
            "name": name,
            "deviceURI": deviceURI,
            "ppd": ppd
        };
        if (options) {
            if (options.shared !== undefined)
                params.shared = options.shared;
            if (options.location)
                params.location = options.location;
            if (options.information)
                params.information = options.information;
            if (options.errorPolicy)
                params.errorPolicy = options.errorPolicy;
        }

        VGSBackendService.sendRequest("cups.createPrinter", params, response => {
            creatingPrinter = false;
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to create printer"), response.error);
            } else {
                ToastService.showInfo(I18n.tr("Printer created successfully"));
                getState();
            }
            if (callback)
                callback(response);
        });
    }

    function deletePrinter(printerName) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName
        };

        VGSBackendService.sendRequest("cups.deletePrinter", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to delete printer"), response.error);
            } else {
                ToastService.showInfo(I18n.tr("Printer deleted"));
                if (selectedPrinter === printerName) {
                    selectedPrinter = "";
                }
                getState();
            }
        });
    }

    function acceptJobs(printerName) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName
        };

        VGSBackendService.sendRequest("cups.acceptJobs", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to enable job acceptance"), response.error);
            } else {
                getState();
            }
        });
    }

    function rejectJobs(printerName) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName
        };

        VGSBackendService.sendRequest("cups.rejectJobs", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to disable job acceptance"), response.error);
            } else {
                getState();
            }
        });
    }

    function setPrinterShared(printerName, shared) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName,
            "shared": shared
        };

        VGSBackendService.sendRequest("cups.setPrinterShared", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to update sharing"), response.error);
            } else {
                getState();
            }
        });
    }

    function setPrinterLocation(printerName, location) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName,
            "location": location
        };

        VGSBackendService.sendRequest("cups.setPrinterLocation", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to update location"), response.error);
            } else {
                getState();
            }
        });
    }

    function setPrinterInfo(printerName, info) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName,
            "info": info
        };

        VGSBackendService.sendRequest("cups.setPrinterInfo", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to update description"), response.error);
            } else {
                getState();
            }
        });
    }

    function printTestPage(printerName) {
        if (!cupsAvailable)
            return;
        const params = {
            "printerName": printerName
        };

        VGSBackendService.sendRequest("cups.printTestPage", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to print test page"), response.error);
            } else {
                ToastService.showInfo(I18n.tr("Test page sent to printer"));
                fetchJobsForPrinter(printerName);
            }
        });
    }

    function moveJob(jobID, destPrinter) {
        if (!cupsAvailable)
            return;
        const params = {
            "jobID": jobID,
            "destPrinter": destPrinter
        };

        VGSBackendService.sendRequest("cups.moveJob", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to move job"), response.error);
            } else {
                fetchAllJobs();
            }
        });
    }

    function restartJob(jobID) {
        if (!cupsAvailable)
            return;
        const params = {
            "jobID": jobID
        };

        VGSBackendService.sendRequest("cups.restartJob", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to restart job"), response.error);
            } else {
                fetchAllJobs();
            }
        });
    }

    function holdJob(jobID, holdUntil) {
        if (!cupsAvailable)
            return;
        const params = {
            "jobID": jobID
        };
        if (holdUntil) {
            params.holdUntil = holdUntil;
        }
        const resuming = holdUntil === "resume" || holdUntil === "no-hold" || holdUntil === "immediate";

        VGSBackendService.sendRequest("cups.holdJob", params, response => {
            if (response.error) {
                ToastService.showError(resuming ? I18n.tr("Failed to resume job") : I18n.tr("Failed to hold job"), response.error);
            } else {
                setJobHeld(jobID, !resuming);
                fetchAllJobs();
            }
        });
    }

    function addPrinterToClass(className, printerName) {
        if (!cupsAvailable)
            return;
        const params = {
            "className": className,
            "printerName": printerName
        };

        VGSBackendService.sendRequest("cups.addPrinterToClass", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to add printer to class"), response.error);
            } else {
                getClasses();
            }
        });
    }

    function removePrinterFromClass(className, printerName) {
        if (!cupsAvailable)
            return;
        const params = {
            "className": className,
            "printerName": printerName
        };

        VGSBackendService.sendRequest("cups.removePrinterFromClass", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to remove printer from class"), response.error);
            } else {
                getClasses();
            }
        });
    }

    function deleteClass(className) {
        if (!cupsAvailable)
            return;
        const params = {
            "className": className
        };

        VGSBackendService.sendRequest("cups.deleteClass", params, response => {
            if (response.error) {
                ToastService.showError(I18n.tr("Failed to delete class"), response.error);
            } else {
                getClasses();
            }
        });
    }

    function getPrinterData(printerName) {
        if (!printers || !printers[printerName])
            return null;
        return printers[printerName];
    }

    function getJobStateTranslation(state) {
        switch (state) {
        case "pending":
            return I18n.tr("Pending");
        case "pending-held":
            return I18n.tr("Held");
        case "processing":
            return I18n.tr("Processing");
        case "processing-stopped":
            return I18n.tr("Stopped");
        case "canceled":
            return I18n.tr("Canceled");
        case "aborted":
            return I18n.tr("Aborted");
        case "completed":
            return I18n.tr("Completed");
        default:
            return state;
        }
    }

    readonly property var states: ({
            "idle": I18n.tr("Idle"),
            "printing": I18n.tr("Printing"),
            "processing": I18n.tr("Processing"),
            "stopped": I18n.tr("Stopped")
        })

    readonly property var reasonsGeneral: ({
            "none": I18n.tr("None"),
            "other": I18n.tr("Other")
        })

    readonly property var reasonsSupplies: ({
            "toner-low": I18n.tr("Toner Low"),
            "toner-empty": I18n.tr("Toner Empty"),
            "marker-supply-low": I18n.tr("Marker Supply Low"),
            "marker-supply-empty": I18n.tr("Marker Supply Empty"),
            "marker-waste-almost-full": I18n.tr("Marker Waste Almost Full"),
            "marker-waste-full": I18n.tr("Marker Waste Full")
        })

    readonly property var reasonsMedia: ({
            "media-low": I18n.tr("Media Low"),
            "media-empty": I18n.tr("Media Empty"),
            "media-needed": I18n.tr("Media Needed"),
            "media-jam": I18n.tr("Media Jam")
        })

    readonly property var reasonsParts: ({
            "cover-open": I18n.tr("Cover Open"),
            "door-open": I18n.tr("Door Open"),
            "interlock-open": I18n.tr("Interlock Open"),
            "output-tray-missing": I18n.tr("Output Tray Missing"),
            "output-area-almost-full": I18n.tr("Output Area Almost Full"),
            "output-area-full": I18n.tr("Output Area Full")
        })

    readonly property var reasonsErrors: ({
            "paused": I18n.tr("Paused"),
            "shutdown": I18n.tr("Shutdown"),
            "connecting-to-device": I18n.tr("Connecting to Device"),
            "timed-out": I18n.tr("Timed Out"),
            "stopping": I18n.tr("Stopping"),
            "stopped-partly": I18n.tr("Stopped Partly")
        })

    readonly property var reasonsService: ({
            "spool-area-full": I18n.tr("Spool Area Full"),
            "cups-missing-filter-warning": I18n.tr("CUPS Missing Filter Warning"),
            "cups-insecure-filter-warning": I18n.tr("CUPS Insecure Filter Warning")
        })

    readonly property var reasonsConnectivity: ({
            "offline-report": I18n.tr("Offline Report"),
            "moving-to-paused": I18n.tr("Moving to Paused")
        })

    readonly property var severitySuffixes: ({
            "-error": I18n.tr("Error"),
            "-warning": I18n.tr("Warning"),
            "-report": I18n.tr("Report")
        })

    function getPrinterStateTranslation(state) {
        return states[state] || state;
    }

    function getPrinterStateReasonTranslation(reason) {
        let allReasons = Object.assign({}, reasonsGeneral, reasonsSupplies, reasonsMedia, reasonsParts, reasonsErrors, reasonsService, reasonsConnectivity);

        let basReason = reason;
        let suffix = "";

        for (let s in severitySuffixes) {
            if (reason.endsWith(s)) {
                basReason = reason.slice(0, -s.length);
                suffix = severitySuffixes[s];
                break;
            }
        }

        let translation = allReasons[basReason] || basReason;
        return suffix ? translation + " (" + suffix + ")" : translation;
    }
}
