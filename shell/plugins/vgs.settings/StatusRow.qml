import QtQuick
import qs.Commons
import qs.Ui

// One read-only Status row of a plugin's page, drawn from one entry of its
// manager row's `status` (PluginLogic.statusRows) as StatusLines: the
// entry's label beside its value, the manifest's hint and command. A
// presence or a state draws as a Badge in the tone the entry carries; a
// text, a count or a time as one line of text; an entry the plugin has not
// published, or published while disabled, as "Not reported". A presence
// list draws its label and hint alone, "None detected" while the list is
// empty, then one line per item: the item's label beside a Badge of its
// presence, its hint and its command. Nothing here writes.
Column {
    id: row

    // One entry of a manager row's `status`, or null for a row whose entry
    // left the page's manager row before the row itself goes.
    required property var entry

    readonly property var presenceWords: ({ present: "Present", absent: "Absent", locked: "Locked", unavailable: "Unavailable", unsafe: "Unsafe" })
    // What the row draws: { label, hint, command, tone, text, muted, items },
    // `tone` "" for a value drawn as text and `items` a presence list's
    // items, each { label, value, hint, command, tone }.
    readonly property var view: {
        if (entry === null) return { label: "", hint: "", command: "", tone: "", text: "", muted: true, items: [] };
        const out = { label: entry.label, hint: entry.hint, command: entry.command, tone: "", text: "Not reported", muted: true, items: [] };
        if (entry.report !== "reported") return out;
        out.muted = false;
        out.tone = entry.tone;
        switch (entry.type) {
        case "presence": out.text = presenceWords[entry.value]; return out;
        case "presenceList":
            out.items = entry.value;
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
    spacing: Theme.space.xs

    StatusLine {
        width: row.width
        label: row.view.label
        hint: row.view.hint
        command: row.view.command
        tone: row.view.tone
        text: row.view.text
        muted: row.view.muted
    }

    Repeater {
        model: row.view.items
        StatusLine {
            required property var modelData
            width: row.width
            label: modelData.label
            hint: modelData.hint
            command: modelData.command
            tone: modelData.tone
            text: row.presenceWords[modelData.value]
        }
    }
}
