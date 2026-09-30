import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "AutomationsLogic.js" as Engine
import "AutomationsViewLogic.js" as View

// The Automations application window. It edits drafts and reads history
// through bin/automations only; the engine remains the store, scheduler and
// run-record owner.
FocusScope {
    id: root

    property var shell: null
    readonly property var screen: shell === null ? null : shell.screens.current
    property string place: "automations"
    property bool editorOpen: false
    property var automations: []
    property var historyRows: []
    property var draft: View.blankDraft(Date.now(), Engine)
    property var previewRows: []
    property string previewSummary: ""
    property var notice: ({ tone: "neutral", text: "", detail: "" })
    property string confirmAction: ""
    property string confirmTarget: ""
    property string confirmName: ""
    property var testRun: null
    property string testTranscript: ""
    property string testTranscriptPath: ""
    property real testStartedAt: 0
    property string listStoreFile: ""
    property string listRunsDir: ""
    property int draftRevision: 0

    readonly property var templates: View.TEMPLATES
    readonly property var validationResult: View.validation(draft, Engine, Date.now())
    readonly property string previewFirst: previewRows.length > 0 ? String(previewRows[0]) : ""
    readonly property int listCurrent: automationList.current

    implicitWidth: screen === null ? Theme.size.window.width : Math.floor(Math.min(Theme.size.window.width, screen.width - 2 * Theme.size.window.gutter))
    implicitHeight: screen === null ? Theme.size.panel.maxHeight : Math.floor(Math.min(Theme.size.panel.maxHeight, screen.height - 2 * Theme.size.window.gutter))
    focus: true

    function open(payloadJson) {
        const payload = payloadJson ? JSON.parse(payloadJson) : {};
        if (payload === null || typeof payload !== "object" || Array.isArray(payload)) throw new Error("payload must be an object");
        place = "automations";
        if (payload.new === true) newDraft();
        else if (payload.id !== undefined) selectAutomation(payload.id);
        else {
            editorOpen = false;
            Qt.callLater(() => automationList.focusList());
        }
        refreshAll();
    }

    function close() {}

    // A tab or a page change hands the keys to the page it shows, so the
    // keyboard follows what the pointer chose.
    function focusPage() {
        if (place === "history") history.forceActiveFocus();
        else if (editorOpen) editor.focusName();
        else automationList.focusList();
    }
    onPlaceChanged: Qt.callLater(focusPage)

    function setNotice(tone, text, detail) {
        notice = { tone: tone, text: text, detail: detail || "" };
    }

    function friendlyFailure(failure) {
        if (failure.indexOf("definition=not-json") !== -1) return "The automation draft could not be read.";
        if (failure.indexOf("schedule") !== -1) return "Check the recurrence fields.";
        if (failure.indexOf("id: unknown") !== -1 || failure.indexOf("unknown=") !== -1) return "That automation no longer exists.";
        if (failure.indexOf("systemctl=failed") !== -1) return "The scheduler refused the change.";
        return "The automation engine refused the request.";
    }

    function run(args, done) {
        client.request(args, (ok, stdoutText, stderrText, failure) => {
            if (!ok) setNotice("danger", friendlyFailure(failure), failure);
            if (done !== undefined) done(ok, stdoutText, stderrText, failure);
        });
    }

    function runJson(args, done) {
        client.requestJson(args, (ok, doc, failure) => {
            if (!ok) {
                setNotice("danger", failure.indexOf("answer=not-json") !== -1 ? "The engine returned invalid JSON." : friendlyFailure(failure), failure);
                if (done) done(false, null);
            }
            else if (done) done(true, doc);
        });
    }

    function refreshAll() {
        refreshList();
        refreshHistory();
        updatePreview();
    }

    function refreshList() {
        runJson(["list", "--json"], (ok, doc) => {
            if (!ok) return;
            automations = doc.automations;
            listStoreFile = doc.storeFile || "";
            listRunsDir = doc.runsDir || "";
            // The shown automation left the store, through this window's
            // Remove or any other caller: its draft goes, and the editor
            // returns to the list rather than opening a blank draft.
            if (draft.saved && !automations.some(row => row.id === draft.id)) {
                replaceDraft(View.blankDraft(Date.now(), Engine));
                if (editorOpen) {
                    editorOpen = false;
                    Qt.callLater(() => automationList.focusList());
                }
            }
            if (notice.tone === "danger") notice = { tone: "neutral", text: "", detail: "" };
        });
    }

    function refreshHistory() {
        runJson(["history", "--json"], (ok, doc) => {
            if (!ok) return;
            historyRows = doc.rows;
            followTestRun();
        });
    }

    function filteredHistoryGroups(id) {
        const rows = id === "" ? historyRows : historyRows.filter(row => row.automation === id);
        return View.historyGroups(rows, Date.now() - Engine.HISTORY_DAYS_MAX * Engine.DAY_MS);
    }

    function replaceDraft(next) {
        draftRevision += 1;
        draft = next;
        previewSoon.restart();
    }

    function updateDraft(key, value) {
        const next = View.clone(draft);
        next[key] = value;
        if (key === "start" && next.yearlyEdited !== true) {
            const parts = View.startDateParts(value, Engine);
            if (parts !== null) {
                next.yearlyMonth = parts.month;
                next.yearlyDay = parts.day;
            }
        } else if (key === "yearlyMonth" || key === "yearlyDay") {
            next.yearlyEdited = true;
        }
        replaceDraft(next);
    }

    function newDraft() {
        place = "automations";
        editorOpen = true;
        testRun = null;
        testTranscript = "";
        testStartedAt = 0;
        setNotice("neutral", "", "");
        replaceDraft(View.blankDraft(Date.now(), Engine));
        Qt.callLater(() => editor.focusName());
    }

    function selectAutomation(id) {
        const row = automations.find(item => item.id === id);
        if (row === undefined) return "unknown: " + id;
        place = "automations";
        editorOpen = true;
        testRun = null;
        testTranscript = "";
        testStartedAt = 0;
        setNotice("neutral", "", "");
        replaceDraft(View.draftFromAutomation(row, Engine));
        Qt.callLater(() => editor.focusName());
        return "ok";
    }

    function duplicateAutomation(id) {
        const row = automations.find(item => item.id === id);
        if (row === undefined) return "unknown: " + id;
        place = "automations";
        editorOpen = true;
        replaceDraft(View.duplicateDraft(row, automations.map(item => item.name), Engine));
        setNotice("info", "Duplicated " + row.name + ".", "The copy starts paused until you save it.");
        return "ok";
    }

    function applyTemplate(key) {
        const template = View.TEMPLATES.find(item => item.key === key);
        if (template === undefined) return "unknown: " + key;
        place = "automations";
        editorOpen = true;
        replaceDraft(View.templateDraft(template, Date.now(), Engine));
        setNotice("info", "Template loaded.", template.label);
        return "ok";
    }

    function saveDraft() {
        const checked = validationResult;
        if (!checked.ok) {
            setNotice("danger", "Fix the highlighted fields before saving.", Object.keys(checked.errors).map(key => checked.errors[key]).join(" "));
            return "refused: draft=invalid";
        }
        const requestDraft = View.clone(draft);
        const requestRevision = draftRevision;
        const definition = JSON.stringify(View.definitionFromDraft(requestDraft, Engine));
        const args = requestDraft.saved ? ["edit", requestDraft.id, "--definition", definition] : ["add", "--definition", definition];
        run(args, (ok, out) => {
            if (!ok) return;
            const next = View.saveCompletionDraft(draft, requestDraft, requestRevision, draftRevision, out);
            if (next === null) {
                refreshAll();
                return;
            }
            draft = next;
            setNotice("success", "Saved " + draft.name + ".", "");
            refreshAll();
        });
        return "ok";
    }

    function runNow(id) {
        const target = id || draft.id;
        if (target === "") {
            setNotice("danger", "Save before Test run.", "The engine runs stored automations by id.");
            return "refused: unsaved";
        }
        testStartedAt = Date.now();
        testRun = { outcome: "running", exitCode: null, transcript: "" };
        testTranscript = "";
        testTranscriptPath = "";
        run(["run-now", target], ok => {
            if (!ok) return;
            setNotice("info", "Test run started.", "Waiting for the newest history row.");
            historyFollow.restart();
        });
        return "ok";
    }

    function followTestRun() {
        if (testStartedAt === 0 || draft.id === "") return;
        const rows = historyRows.filter(row => row.automation === draft.id && row.startedAt >= testStartedAt - 1000);
        if (rows.length === 0) return;
        const row = rows[0];
        testRun = row;
        if (row.transcript !== "") {
            if (row.transcript !== testTranscriptPath) {
                testTranscriptPath = row.transcript;
                transcriptReader.path = row.transcript;
            }
            transcriptReader.reload();
        }
        if (row.outcome === "running") historyFollow.restart();
        else setNotice(row.tone === "danger" ? "danger" : "success", "Test run " + row.outcome + ".", row.exitCode === null ? "" : "Exit " + row.exitCode);
    }

    function toggleEnabled(id, enabled) {
        run([enabled ? "enable" : "disable", id], ok => { if (ok) refreshList(); });
    }

    function removeAutomation(id) {
        const row = automations.find(item => item.id === id);
        confirmAction = "remove";
        confirmTarget = id;
        confirmName = row === undefined ? id : row.name;
    }

    function clearHistory(id) {
        confirmAction = "clear";
        confirmTarget = id === undefined ? "" : id;
        const row = automations.find(item => item.id === confirmTarget);
        confirmName = confirmTarget === "" ? "all automations" : row === undefined ? confirmTarget : row.name;
    }

    function acceptConfirm() {
        const action = confirmAction;
        const target = confirmTarget;
        confirmAction = "";
        confirmTarget = "";
        if (action === "remove") {
            run(["remove", target], ok => {
                if (!ok) return;
                setNotice("success", "Removed " + confirmName + ".", "");
                editorOpen = false;
                refreshAll();
            });
        } else if (action === "clear") {
            run(["clear", target === "" ? "--all" : target], ok => {
                if (!ok) return;
                setNotice("success", "History cleared for " + confirmName + ".", "");
                refreshHistory();
            });
        }
    }

    function openTranscript(path) {
        if (path === "") return "refused: transcript=missing";
        const reply = shell === null ? "refused: shell=none" : shell.tui.run("transcript", [path]);
        if (reply !== "ok") setNotice("danger", "The transcript TUI did not open.", reply);
        return reply;
    }

    function copyCommand() {
        commandCopy.copy();
        setNotice("success", "Command copied.", "");
    }

    function updatePreview() {
        const checked = validationResult;
        previewSummary = View.summary(draft, Engine);
        if (checked.schedule === null || Engine.scheduleError(checked.schedule) !== "") {
            previewRows = [];
            return;
        }
        runJson(["preview", "--schedule", JSON.stringify(checked.schedule), "--count", "5"], (ok, doc) => {
            if (!ok) { previewRows = []; return; }
            previewSummary = doc.summary;
            previewRows = doc.occurrences;
        });
    }

    // Ctrl+N and Ctrl+S reach the window from whichever control holds the
    // keys, since no field takes them, as every VGS window takes its keys.
    Keys.onPressed: event => {
        if (event.modifiers !== Qt.ControlModifier) return;
        if (event.key === Qt.Key_N) {
            newDraft();
            event.accepted = true;
        } else if (event.key === Qt.Key_S && editorOpen) {
            saveDraft();
            event.accepted = true;
        }
    }
    Keys.onEscapePressed: event => {
        if (confirmAction !== "") {
            confirmAction = "";
            event.accepted = true;
        } else if (editorOpen) {
            editorOpen = false;
            automationList.focusList();
            event.accepted = true;
        } else {
            event.accepted = false;
        }
    }

    Component.onCompleted: refreshAll()


    EngineClient { id: client }

    Timer { id: previewSoon; interval: 200; onTriggered: root.updatePreview() }
    Timer { id: historyFollow; interval: 500; onTriggered: root.refreshHistory() }
    Timer { id: listSoon; interval: 250; onTriggered: root.refreshList() }

    FolderListModel {
        folder: root.listRunsDir === "" ? "" : "file://" + root.listRunsDir
        nameFilters: ["*.json"]
        showDirs: false
        onCountChanged: if (root.listRunsDir !== "" && String(folder) === "file://" + root.listRunsDir) { root.refreshHistory(); root.refreshList(); }
    }

    LazyLoader {
        active: root.listStoreFile !== ""
        WatchedFile {
            path: root.listStoreFile
            onChanged: listSoon.restart()
            onLoaded: content => listSoon.restart()
            onLoadFailed: error => listSoon.restart()
        }
    }

    FileView {
        id: transcriptReader
        printErrors: false
        onLoaded: root.testTranscript = text()
        onLoadFailed: error => root.testTranscript = "Transcript could not be read: " + error
    }

    Column {
        anchors.fill: parent
        spacing: 0

        Pane {
            id: tabsPane
            width: parent.width
            height: tabsContent.implicitHeight + 2 * Theme.inset.window
            container: "window"
            bodySpacing: Theme.space.sm

            Column {
                id: tabsContent
                width: parent.width
                spacing: Theme.space.sm
                Tabs {
                    width: parent.width
                    model: ["Automations", "History"]
                    currentIndex: root.place === "history" ? 1 : 0
                    onCurrentIndexChanged: {
                        root.place = currentIndex === 0 ? "automations" : "history";
                        if (root.place === "history") root.editorOpen = false;
                    }
                }
                Label {
                    width: parent.width
                    role: "hint"
                    text: root.notice.text + (root.notice.detail === "" ? "" : " " + root.notice.detail)
                    color: root.notice.tone === "danger" ? Theme.color.danger : root.notice.tone === "success" ? Theme.color.success : Theme.color.textMuted
                    visible: root.notice.text !== ""
                    wrapMode: Text.Wrap
                }
            }
        }

        Item {
            width: parent.width
            height: parent.height - tabsPane.height
            clip: true

            AutomationListPage {
                id: automationList
                anchors.fill: parent
                visible: root.place === "automations" && !root.editorOpen
                focus: visible
                panel: root
                onNewRequested: root.newDraft()
                onTemplateRequested: key => root.applyTemplate(key)
                onOpenRequested: id => root.selectAutomation(id)
                onDuplicateRequested: id => root.duplicateAutomation(id)
                onRemoveRequested: id => root.removeAutomation(id)
                onRunRequested: id => root.runNow(id)
                onToggleRequested: (id, enabled) => root.toggleEnabled(id, enabled)
            }

            AutomationEditorPage {
                id: editor
                anchors.fill: parent
                visible: root.place === "automations" && root.editorOpen
                focus: visible
                panel: root
                draft: root.draft
                validation: root.validationResult
                summary: root.previewSummary
                previewRows: root.previewRows
                testRun: root.testRun
                testTranscript: root.testTranscript
                onBackRequested: { root.editorOpen = false; automationList.focusList(); }
                onSaveRequested: root.saveDraft()
                onTestRequested: root.runNow(root.draft.id)
                onCopyRequested: root.copyCommand()
                onRemoveRequested: root.removeAutomation(root.draft.id)
                onOpenTranscriptRequested: path => root.openTranscript(path)
                onChange: (key, value) => root.updateDraft(key, value)
            }

            HistoryPage {
                id: history
                anchors.fill: parent
                visible: root.place === "history"
                focus: visible
                panel: root
                onClearRequested: id => root.clearHistory(id)
                onOpenRequested: transcript => root.openTranscript(transcript)
            }
        }
    }

    CodeLine {
        id: commandCopy
        visible: false
        text: root.draft.command
        copyLabel: "Copy command"
    }

    ConfirmFlow {
        action: root.confirmAction
        subject: root.confirmAction === "remove" ? "Remove " + root.confirmName + "?" : "Clear history for " + root.confirmName + "?"
        message: root.confirmAction === "remove" ? "This removes the automation and its finished transcripts." : "This removes finished runs and transcripts. Running jobs stay."
        onRejected: root.confirmAction = ""
        onAccepted: root.acceptConfirm()
    }
}
