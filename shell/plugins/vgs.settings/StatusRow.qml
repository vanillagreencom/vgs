import QtQuick
import qs.Commons
import qs.Ui

// One read-only Status row of a plugin's page, drawn from one entry of its
// manager row's `status` (PluginLogic.statusRows): the label beside the
// value, the manifest's hint under it, and the manifest's command, when it
// names one, in a CodeLine the reader copies and the page never runs. A
// presence or a state draws as a Badge in the tone the entry carries; a
// text, a count or a time as one line of text; an entry the plugin has not
// published, or published while disabled, as "Not reported". Nothing here
// writes.
Column {
    id: row

    // One entry of a manager row's `status`, or null for a row whose entry
    // left the page's manager row before the row itself goes.
    required property var entry

    readonly property var presenceWords: ({ present: "Present", absent: "Absent", locked: "Locked", unavailable: "Unavailable", unsafe: "Unsafe" })
    // What the row draws: { label, hint, command, tone, text, reported },
    // `tone` "" for a value drawn as text.
    readonly property var view: {
        if (entry === null) return { label: "", hint: "", command: "", tone: "", text: "", reported: false };
        const out = { label: entry.label, hint: entry.hint, command: entry.command, tone: "", text: "Not reported", reported: entry.report === "reported" };
        if (!out.reported) return out;
        out.tone = entry.tone;
        switch (entry.type) {
        case "presence": out.text = presenceWords[entry.value]; return out;
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
    spacing: Theme.field.gap

    Field {
        width: row.width
        label: row.view.label
        inline: true
        hint: row.view.hint
        Loader {
            width: parent.width
            sourceComponent: row.view.tone !== "" ? badge : line
        }
    }

    CodeLine {
        x: Theme.field.paddingX
        width: row.width - 2 * Theme.field.paddingX
        visible: row.view.command !== ""
        text: row.view.command
        copyLabel: "Copy the command"
    }

    Component {
        id: badge
        Item {
            implicitHeight: chip.height
            Badge { id: chip; text: row.view.text; tone: row.view.tone }
        }
    }

    Component {
        id: line
        Label {
            role: row.view.reported ? "item" : "itemHint"
            text: row.view.text
            elide: Text.ElideRight
        }
    }
}
