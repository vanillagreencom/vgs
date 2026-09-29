import QtQuick
import qs.Commons
import qs.Ui

// One read-only Requirements row of a plugin's page, drawn from one entry
// of its manager row's `requirements` (PluginLogic.requirementRows): the
// command beside its state from the last scan as a Badge, Present in the
// success tone, Missing in the danger tone or, for an optional command, the
// warning tone, and the manifest's purpose under it. The page's Install
// button, not the row, installs what is missing.
Column {
    id: row

    // One entry of a manager row's `requirements`.
    required property var requirement

    readonly property var view: {
        switch (requirement.state) {
        case "present": return { text: "Present", tone: "success" };
        case "missing": return requirement.optional ? { text: "Missing, optional", tone: "warning" } : { text: "Missing", tone: "danger" };
        }
        console.error("RequirementRow: no rule for requirement state " + JSON.stringify(requirement.state));
        return { text: "", tone: "neutral" };
    }

    Field {
        width: row.width
        label: row.requirement.command
        inline: true
        contentPaddingX: 0
        hint: row.requirement.purpose
        Item {
            implicitHeight: chip.height
            Badge { id: chip; text: row.view.text; tone: row.view.tone }
        }
    }
}
