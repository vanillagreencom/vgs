import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // --- Settings-backed config ---
    property string provider: pluginData.provider || "claude"
    property int refreshSeconds: pluginData.refreshSeconds || 300

    // --- Live state ---
    property bool loading: true
    property bool ok: false
    property string errorText: ""
    property string plan: ""
    property string usageClass: "low"
    property int sessionPct: 0
    property string sessionReset: ""
    property double sessionResetAt: 0
    property bool hasSession: true  // absent when the provider reports no ~5h window (e.g. weekly-only Codex accounts)
    property int weeklyPct: 0
    property string weeklyReset: ""
    property double weeklyResetAt: 0
    property bool hasWeekly: true
    property string thirdLabel: ""
    property int thirdPct: 0
    property string thirdReset: ""
    property double thirdResetAt: 0
    property bool hasThird: true   // model-scoped weekly (Claude) / extra lane (Codex); hidden when the API omits it

    // --- Multi-account state ---
    // People run several subscriptions side by side (one config dir per wrapper
    // script). With a single account this stays a one-entry list and every path
    // below falls back to the flat fields above, so nothing changes for them.
    property var accounts: []
    property var aggregate: null
    readonly property bool multiAccount: (root.accounts || []).length > 1
    property string expandedAccountId: ""

    // Consumption across the whole pool: each account contributes one 100%
    // allowance, so this is consumed/available — four accounts at 50% read as
    // 50%, not 200%. Prefers the session window like the single-account pill.
    readonly property int aggregatePct: {
        if (!root.aggregate)
            return root.primaryPct;
        // `pct` is the mean of each account's tightest window. The older
        // session/weekly means are kept for compatibility but must not be the
        // headline: averaging the 5h window alone read 8% on a pool whose
        // weeklies were at 96-100%.
        if (root.aggregate.pct !== null && root.aggregate.pct !== undefined)
            return root.aggregate.pct;
        if (root.aggregate.weekly !== null && root.aggregate.weekly !== undefined)
            return root.aggregate.weekly;
        if (root.aggregate.session !== null && root.aggregate.session !== undefined)
            return root.aggregate.session;
        return 0;
    }
    readonly property int headlinePct: root.multiAccount ? root.aggregatePct : root.primaryPct

    // Meters for one account entry, in the same order the single-account view
    // uses: session, weekly, then every per-model lane the provider reported.
    function metersFor(account) {
        if (!account)
            return [];
        let out = [];
        if (account.session)
            out.push({ label: "Session (5h)", pct: account.session.pct || 0, reset: account.session.reset || "", resetAt: account.session.resetAt || 0 });
        if (account.weekly)
            out.push({ label: "Weekly (7d)", pct: account.weekly.pct || 0, reset: account.weekly.reset || "", resetAt: account.weekly.resetAt || 0 });
        const models = account.models || [];
        for (let i = 0; i < models.length; i++)
            out.push({ label: models[i].label || "Model", pct: models[i].pct || 0, reset: models[i].reset || "", resetAt: models[i].resetAt || 0 });
        // Credit-billed seats have no rate-limit windows at all — their monthly
        // spend pool is the only usage there is, so it stands in for them.
        if (account.spend)
            out.push({ label: "Credits", pct: account.spend.pct || 0, reset: "", resetAt: 0,
                       detail: account.spend.detail || "",
                       used: account.spend.used, limit: account.spend.limit, currency: account.spend.currency || "USD" });
        return out;
    }

    // Meters for the single-account view. Prefers the accounts list so lanes the
    // flat fields can't express (a credit pool, a second model) still show up,
    // and falls back to the flat fields if an older helper omits accounts.
    readonly property var primaryMeters: {
        const list = root.accounts || [];
        if (list.length > 0)
            return root.metersFor(list[0]);
        let out = [];
        if (root.hasSession)
            out.push({ label: "Session (5h)", pct: root.sessionPct, reset: root.sessionReset, resetAt: root.sessionResetAt, detail: "" });
        if (root.hasWeekly)
            out.push({ label: "Weekly (7d)", pct: root.weeklyPct, reset: root.weeklyReset, resetAt: root.weeklyResetAt, detail: "" });
        if (root.hasThird)
            out.push({ label: root.thirdLabel, pct: root.thirdPct, reset: root.thirdReset, resetAt: root.thirdResetAt, detail: "" });
        return out;
    }

    // Absolute reset instant as wall-clock text. A countdown alone ("4d 17h")
    // makes you do the arithmetic; the clock time is what you actually plan
    // around. Same day -> just the time, otherwise the weekday, and the date
    // once it is far enough out that the weekday is ambiguous. Kept short and
    // lowercase ("tom 02:59", "thu 04:00") — these sit in a narrow column
    // beside the bar, so every character costs bar width.
    function formatResetAt(epoch) {
        if (!epoch || epoch <= 0)
            return "";
        const when = new Date(epoch * 1000);
        if (isNaN(when.getTime()))
            return "";
        const now = new Date();
        // Past instants are stale data (a window that already rolled over);
        // showing them would be worse than showing nothing.
        if (when.getTime() <= now.getTime())
            return "";
        // 24h, explicitly — the locale short format drags in AM/PM, which is
        // three more characters in a column that is already fighting the bar.
        const time = when.toLocaleTimeString(Qt.locale(), "HH:mm");
        const startOfDay = d => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
        const days = Math.round((startOfDay(when) - startOfDay(now)) / 86400000);
        if (days === 0)
            return time;
        if (days === 1)
            return "tom " + time;
        if (days < 7)
            return when.toLocaleDateString(Qt.locale(), "ddd").toLowerCase() + " " + time;
        return when.toLocaleDateString(Qt.locale(), "d MMM").toLowerCase() + " " + time;
    }

    // Money for the compact row: no cents, thousands separated. At credit-pool
    // scale the cents are noise, and this column is only as wide as the bar can
    // spare. The expanded card keeps the engine's exact string.
    function formatSpend(meter) {
        if (!meter || meter.used === undefined || meter.limit === undefined)
            return "";
        const sym = meter.currency === "USD" ? "$" : "";
        const round = n => Math.round(n).toLocaleString(Qt.locale(), "f", 0);
        return sym + round(meter.used) + " / " + sym + round(meter.limit);
    }

    // The card has room for the cents. Falls back to the engine's own string
    // if an older helper sent only that.
    function formatSpendExact(meter) {
        if (!meter)
            return "";
        if (meter.used === undefined || meter.limit === undefined)
            return meter.detail || "";
        const sym = meter.currency === "USD" ? "$" : "";
        const money = n => sym + n.toLocaleString(Qt.locale(), "f", 2);
        return money(meter.used) + " of " + money(meter.limit);
    }

    // "Resets in 4d 17h · thu 04:00", degrading to whichever half we have.
    function resetLabel(meter) {
        if (!meter)
            return "";
        const at = root.formatResetAt(meter.resetAt || 0);
        const inn = meter.reset && meter.reset !== "\u2014" ? meter.reset : "";
        if (inn && at)
            return "Resets in " + inn + " \u00b7 " + at;
        if (at)
            return "Resets " + at;
        if (inn)
            return "Resets in " + inn;
        return "";
    }

    function providerIcon() {
        return root.provider === "codex" ? "terminal" : "smart_toy";
    }
    function providerName() {
        return root.provider === "codex" ? "Codex" : "Claude";
    }
    function classColor(c) {
        switch (c) {
        case "critical":
            return Theme.error;
        case "high":
            return Theme.tempWarning;
        case "mid":
            return Theme.warning;
        default:
            return Theme.success;
        }
    }
    readonly property color accentColor: root.ok ? classColor(root.worstClass) : Theme.error

    // Headline percentage: the tightest lane this account has. Same reasoning as
    // aggregatePct — the 5h session is usually the emptiest window and says
    // nothing about whether the weekly is about to block you.
    readonly property int primaryPct: {
        const lanes = root.primaryMeters || [];
        let peak = 0;
        for (let i = 0; i < lanes.length; i++)
            peak = Math.max(peak, lanes[i].pct || 0);
        if (lanes.length > 0)
            return peak;
        return root.hasSession ? root.sessionPct : root.weeklyPct;
    }

    // Headline for each provider, kept side by side so the pill can show both
    // without the popout having to be on that tab. {pct, cls} or null when the
    // provider has no signed-in accounts.
    property var claudeHead: null
    property var codexHead: null

    function noteHeadline(provider, data) {
        const ok = data && data.ok === true;
        const agg = ok ? data.aggregate : null;
        const pct = agg && agg.pct !== undefined && agg.pct !== null
            ? agg.pct
            : (ok ? (data.session ? data.session.pct : (data.weekly ? data.weekly.pct : 0)) : 0);
        const head = ok ? { pct: pct, cls: (agg && agg.class) || data.class || "low" } : null;
        if (provider === "codex")
            root.codexHead = head;
        else
            root.claudeHead = head;
    }

    // "78% / 100%" — Claude on the left, Codex on the right, always in that
    // order regardless of which tab the popout is showing. A provider you are
    // not signed in to is dropped rather than rendered as an error.
    function pillText() {
        const parts = [];
        if (root.claudeHead)
            parts.push(root.claudeHead.pct + "%");
        if (root.codexHead)
            parts.push(root.codexHead.pct + "%");
        if (parts.length > 0)
            return parts.join(" / ");
        if (root.loading && !root.ok && root.errorText === "")
            return "…";
        if (!root.ok)
            return "!";
        return root.headlinePct + "%";
    }

    // The pill takes the worse of the two — it is a warning light, and a healthy
    // Claude must not hide an exhausted Codex.
    readonly property string worstClass: {
        const rank = { low: 0, mid: 1, high: 2, critical: 3 };
        let worst = root.usageClass;
        const heads = [root.claudeHead, root.codexHead];
        for (let i = 0; i < heads.length; i++) {
            if (heads[i] && (rank[heads[i].cls] || 0) > (rank[worst] || 0))
                worst = heads[i].cls;
        }
        return worst;
    }

    function refresh() {
        if (!otherProc.running)
            otherProc.running = true;
        if (usageProc.running)
            return;
        usageProc.running = true;
    }

    function setProvider(p) {
        if (root.provider === p)
            return;
        root.provider = p;
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", "provider", p);
        root.loading = true;
        root.refresh();
    }

    readonly property string aiUsageCommand: Paths.vshellCli

    Process {
        id: usageProc
        command: [root.aiUsageCommand, "ai-usage", root.provider]
        running: false
        stdout: StdioCollector {
            id: usageOut
            onStreamFinished: root.parseOutput(usageOut.text)
        }
    }

    // The provider the popout is NOT showing. Only its headline is kept, so the
    // pill can read "claude / codex" without doubling the popout's state.
    readonly property string otherProvider: root.provider === "codex" ? "claude" : "codex"

    Process {
        id: otherProc
        command: [root.aiUsageCommand, "ai-usage", root.otherProvider]
        running: false
        stdout: StdioCollector {
            id: otherOut
            onStreamFinished: {
                try {
                    root.noteHeadline(root.otherProvider, JSON.parse((otherOut.text || "").trim()));
                } catch (e) {
                    root.noteHeadline(root.otherProvider, null);
                }
            }
        }
    }

    function parseOutput(txt) {
        root.loading = false;
        try {
            const d = JSON.parse((txt || "").trim());
            root.ok = d.ok === true;
            root.noteHeadline(root.provider, d);
            root.accounts = d.accounts || [];
            root.aggregate = d.aggregate || null;
            if (!root.ok) {
                root.errorText = d.error || "usage unavailable";
                return;
            }
            root.errorText = "";
            root.plan = d.plan || "";
            root.usageClass = d.class || "low";
            root.hasSession = !!d.session;
            root.sessionPct = (d.session && d.session.pct) || 0;
            root.sessionReset = (d.session && d.session.reset) || "";
            root.sessionResetAt = (d.session && d.session.resetAt) || 0;
            root.hasWeekly = !!d.weekly;
            root.weeklyPct = (d.weekly && d.weekly.pct) || 0;
            root.weeklyReset = (d.weekly && d.weekly.reset) || "";
            root.weeklyResetAt = (d.weekly && d.weekly.resetAt) || 0;
            root.hasThird = !!d.third;
            root.thirdLabel = (d.third && d.third.label) || "";
            root.thirdPct = (d.third && d.third.pct) || 0;
            root.thirdReset = (d.third && d.third.reset) || "";
            root.thirdResetAt = (d.third && d.third.resetAt) || 0;
        } catch (e) {
            root.ok = false;
            root.errorText = "parse error";
        }
    }

    Timer {
        id: pollTimer
        // Each refresh walks every account in turn, so the floor scales with how
        // many there are: one account may poll every 60s, five no faster than
        // every 300s. The configured interval still wins when it is longer.
        interval: Math.max(60 * Math.max(1, (root.accounts || []).length), root.refreshSeconds) * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            VgsIcon {
                name: root.providerIcon()
                size: root.iconSize
                color: root.accentColor
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.pillText()
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            VgsIcon {
                name: root.providerIcon()
                size: root.iconSize
                color: root.accentColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.ok ? (root.headlinePct + "%") : (root.loading ? "…" : "!")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 360
    popoutContent: Component {
        PopoutComponent {
            id: popout

            headerText: root.providerName() + " Usage"
            detailsText: {
                if (!root.ok)
                    return root.errorText || "Unavailable";
                if (!root.multiAccount)
                    return root.plan || "";
                const live = root.aggregate ? root.aggregate.count : root.accounts.length;
                const total = root.aggregate ? root.aggregate.total : root.accounts.length;
                const suffix = (total > live) ? (" · " + (total - live) + " unavailable") : "";
                return live + " accounts · " + root.aggregatePct + "% used" + suffix;
            }
            showCloseButton: true

            Column {
                width: parent.width
                spacing: Theme.spacingM

                // The tabs sat flush against the header and the first card.
                // Wrapping rather than adding Column spacers keeps the gap to
                // the neighbouring cards unchanged.
                Item {
                    width: parent.width
                    height: providerRow.implicitHeight + 10

                    Row {
                        id: providerRow
                        width: parent.width
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                    VgsButton {
                        text: "Claude"
                        iconName: "smart_toy"
                        width: (providerRow.width - Theme.spacingS) / 2
                        backgroundColor: root.provider === "claude" ? Theme.primary : Theme.surfaceContainerHigh
                        textColor: root.provider === "claude" ? Theme.primaryText : Theme.surfaceText
                        onClicked: root.setProvider("claude")
                    }

                    VgsButton {
                        text: "Codex"
                        iconName: "terminal"
                        width: (providerRow.width - Theme.spacingS) / 2
                        backgroundColor: root.provider === "codex" ? Theme.primary : Theme.surfaceContainerHigh
                        textColor: root.provider === "codex" ? Theme.primaryText : Theme.surfaceText
                        onClicked: root.setProvider("codex")
                    }
                    }
                }

                // Single account: unchanged full-detail cards.
                Repeater {
                    model: (root.ok && !root.multiAccount) ? root.primaryMeters : []

                    StyledRect {
                        width: parent.width
                        height: rowCol.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            id: rowCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingXS

                            Item {
                                width: parent.width
                                height: Math.max(labelText.implicitHeight, pctText.implicitHeight)

                                StyledText {
                                    id: labelText
                                    text: modelData.label
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    id: pctText
                                    text: modelData.pct + "%"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: root.accentColor
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 6
                                radius: 3
                                color: Theme.surfaceContainerHighest

                                Rectangle {
                                    width: parent.width * Math.max(0, Math.min(modelData.pct, 100)) / 100
                                    height: parent.height
                                    radius: 3
                                    color: root.accentColor
                                }
                            }

                            StyledText {
                                // A credit pool reports an amount, not a countdown.
                                text: root.formatSpendExact(modelData) || root.resetLabel(modelData)
                                visible: text.length > 0
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }
                }

                // Several accounts: one compact row each, expanding in place to
                // the same full-detail cards a single account gets.
                Repeater {
                    model: root.multiAccount ? root.accounts : []

                    StyledRect {
                        id: accountCard

                        required property var modelData

                        readonly property bool expanded: root.expandedAccountId === modelData.id
                        readonly property var meters: root.metersFor(modelData)
                        readonly property color accountAccent: modelData.ok ? root.classColor(modelData.class) : Theme.error

                        width: parent.width
                        height: accountCol.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Behavior on height {
                            NumberAnimation {
                                duration: Theme.shortDuration
                                easing.type: Easing.OutCubic
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.expandedAccountId = accountCard.expanded ? "" : accountCard.modelData.id
                        }

                        Column {
                            id: accountCol
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingXS

                            Item {
                                width: parent.width
                                // +5 with the text pinned to the top, so the extra
                                // height reads as space under the account line
                                // rather than padding on both sides of it.
                                height: Math.max(emailText.implicitHeight, planText.implicitHeight) + 5

                                StyledText {
                                    id: emailText
                                    anchors.left: parent.left
                                    anchors.right: planText.left
                                    anchors.rightMargin: Theme.spacingS
                                    anchors.top: parent.top
                                    text: accountCard.modelData.label || accountCard.modelData.id
                                    elide: Text.ElideMiddle
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    id: planText
                                    anchors.right: parent.right
                                    anchors.verticalCenter: emailText.verticalCenter
                                    text: accountCard.modelData.ok ? (accountCard.modelData.plan || "") : "unavailable"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }

                            // Collapsed: slim one-line-per-window summary.
                            Repeater {
                                model: accountCard.expanded ? [] : accountCard.meters

                                Item {
                                    required property var modelData

                                    width: accountCol.width
                                    height: compactLabel.implicitHeight + 5

                                    StyledText {
                                        id: compactLabel
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        width: 74
                                        text: modelData.label
                                        elide: Text.ElideRight
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    Rectangle {
                                        anchors.left: compactLabel.right
                                        anchors.leftMargin: Theme.spacingXS
                                        anchors.right: compactReset.left
                                        anchors.rightMargin: Theme.spacingXS
                                        anchors.verticalCenter: compactLabel.verticalCenter
                                        height: 4
                                        radius: 2
                                        color: Theme.surfaceContainerHighest

                                        Rectangle {
                                            width: parent.width * Math.max(0, Math.min(modelData.pct, 100)) / 100
                                            height: parent.height
                                            radius: 2
                                            color: accountCard.accountAccent
                                        }
                                    }

                                    StyledText {
                                        id: compactPct
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        width: 32
                                        horizontalAlignment: Text.AlignRight
                                        text: modelData.pct + "%"
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: Font.Medium
                                        color: accountCard.accountAccent
                                    }

                                    // The reset clock time belongs on the collapsed row too —
                                    // otherwise it is only readable one account at a time, and
                                    // comparing windows across accounts is the point of this view.
                                    StyledText {
                                        id: compactReset
                                        anchors.right: compactPct.left
                                        anchors.rightMargin: Theme.spacingS
                                        anchors.top: parent.top
                                        text: root.formatSpend(modelData) || root.formatResetAt(modelData.resetAt || 0)
                                        visible: text.length > 0
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }

                            // Expanded: the full card treatment, one per window.
                            Repeater {
                                model: accountCard.expanded ? accountCard.meters : []

                                Column {
                                    required property var modelData

                                    width: accountCol.width
                                    spacing: 2
                                    topPadding: Theme.spacingXS

                                    Item {
                                        width: parent.width
                                        height: Math.max(fullLabel.implicitHeight, fullPct.implicitHeight)

                                        StyledText {
                                            id: fullLabel
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeMedium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            id: fullPct
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.pct + "%"
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Bold
                                            color: accountCard.accountAccent
                                        }
                                    }

                                    Rectangle {
                                        width: parent.width
                                        height: 6
                                        radius: 3
                                        color: Theme.surfaceContainerHighest

                                        Rectangle {
                                            width: parent.width * Math.max(0, Math.min(modelData.pct, 100)) / 100
                                            height: parent.height
                                            radius: 3
                                            color: accountCard.accountAccent
                                        }
                                    }

                                    StyledText {
                                        text: modelData.detail ? modelData.detail : root.resetLabel(modelData)
                                        visible: text.length > 0
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }

                            StyledText {
                                visible: !accountCard.modelData.ok
                                width: parent.width
                                text: accountCard.modelData.error || "Usage unavailable"
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }
                }

                StyledText {
                    visible: !root.ok
                    width: parent.width
                    text: root.errorText || "No data"
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
