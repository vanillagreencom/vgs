import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// One Status row of a plugin's page, drawn from one entry of its manager
// row's `status` (PluginLogic.statusRows) as StatusLines: the entry's label
// beside its value, the manifest's hint, its action while offered and its
// command behind "Show command". A presence or a state draws as a Badge in
// the tone the entry carries; a text, a count or a time as one line of
// text; an entry the plugin has not published, or published while disabled,
// as "Not reported". A presence list draws its label and hint alone, "None
// detected" while the list is empty, then one line per item: the item's
// label beside a Badge of its presence, its hint, Connect or Disconnect for
// an item that is a secret's presence, and its command. No row takes an
// edit of a value: a step goes to the manager through `panel` (D061).
Column {
    id: row

    // One entry of a manager row's `status`, or null for a row whose entry
    // left the page's manager row before the row itself goes.
    required property var entry
    // The Settings panel, whose manager calls run each step and whose
    // `stepReplies` and `writing` each line reads, and the plugin's id.
    required property Item panel
    required property string pluginId
    // The plugin's `secrets` label, which a Connect's field asks for.
    property string secretLabel: ""

    // The panel's last refusal or failure under STEP, "" for none and while
    // the page is torn down, when `panel` is already null.
    function replyOf(step) {
        return panel === null ? "" : panel.stepReplies[step] || "";
    }

    // ITEMS, each with the `key` a line keeps across writes, so a status
    // write elsewhere, which hands the page new objects, keeps each line's
    // delegate, an open Connect field and what it holds with it.
    function itemsKeyed(items) {
        const seen = Object.create(null);
        return items.map(item => {
            const name = item.secret !== "" ? "secret " + item.secret : "label " + item.label;
            seen[name] = (seen[name] || 0) + 1;
            return Object.assign({ key: seen[name] === 1 ? name : name + " " + seen[name] }, item);
        });
    }

    readonly property var presenceWords: ({ present: "Present", absent: "Absent", locked: "Locked", unavailable: "Unavailable", unsafe: "Unsafe" })
    // What the row draws: { label, hint, command, tone, text, muted, items },
    // `tone` "" for a value drawn as text and `items` a presence list's
    // items, each { key, label, value, hint, command, tone, secret, access }.
    // `key` names the item across writes: its secret's account, else its
    // label, with its count among earlier equal names after a second one.
    readonly property var view: {
        if (entry === null) return { label: "", hint: "", command: "", tone: "", text: "", muted: true, items: [] };
        const out = { label: entry.label, hint: entry.hint, command: entry.command, tone: "", text: "Not reported", muted: true, items: [] };
        if (entry.report !== "reported") return out;
        out.muted = false;
        out.tone = entry.tone;
        switch (entry.type) {
        case "presence": out.text = presenceWords[entry.value]; return out;
        case "presenceList":
            out.items = itemsKeyed(entry.value);
            out.text = entry.value.length === 0 ? "None detected" : "";
            out.muted = true;
            return out;
        case "state": out.text = entry.value.text; return out;
        case "text": out.text = entry.value; return out;
        case "count": out.text = String(entry.value); return out;
        case "time": out.text = new Date(entry.value).toLocaleString(Qt.locale(), Locale.ShortFormat); return out;
        }
        console.error("StatusRow: no rule for status type " + JSON.stringify(entry.type));
        out.text = "";
        return out;
    }

    visible: entry !== null
    // The rhythm of the rows in a Status section, between the entry's line
    // and each item's.
    spacing: Theme.stack.row

    StatusLine {
        readonly property string stepKey: row.pluginId + "/" + (row.entry === null ? "" : row.entry.key)
        width: row.width
        label: row.view.label
        hint: row.view.hint
        command: row.view.command
        tone: row.view.tone
        text: row.view.text
        muted: row.view.muted
        actionLabel: row.entry === null || row.entry.action === null ? "" : row.entry.action.label
        actionOffered: row.entry !== null && row.entry.action !== null && row.entry.action.offered
        error: row.replyOf(stepKey)
        onAct: row.panel.act(row.pluginId, row.entry.key)
    }

    Repeater {
        model: ScriptModel {
            values: row.view.items
            objectProp: "key"
        }
        StatusLine {
            required property var modelData
            readonly property string stepKey: row.pluginId + "/" + row.entry.key + "/" + modelData.secret
            width: row.width
            label: modelData.label
            hint: modelData.hint
            command: modelData.command
            tone: modelData.tone
            text: row.presenceWords[modelData.value]
            access: modelData.access
            secretLabel: row.secretLabel
            busy: row.panel !== null && row.panel.writing !== ""
            error: row.replyOf(stepKey)
            onStoreSecret: value => row.panel.storeSecret(row.pluginId, row.entry.key, modelData.secret, value)
            onClearSecret: row.panel.clearSecret(row.pluginId, row.entry.key, modelData.secret)
        }
    }
}
