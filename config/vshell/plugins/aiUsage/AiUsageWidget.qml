import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // Which providers the bar and the popout show. An empty list means every
    // provider, so "All" and a fresh install are the same stored value and a
    // new provider needs no migration to appear.
    readonly property var providerFilter: pluginData.providerFilter || []
    // How the bar number is derived from the pool. "pool" = mean of each
    // account's tightest window, "best" = the account with the most headroom,
    // "worst" = the most exhausted account.
    property string headlineMode: pluginData.headlineMode || "pool"
    // Account keys the user has hidden. They stay out of the list AND out of
    // the headline, so the number never contradicts what is on screen.
    property var hiddenAccounts: pluginData.hiddenAccounts || []

    AiUsageLogic {
        id: logic
    }

    AiUsageFormat {
        id: fmt
    }

    // Persist without assigning the bound property. Each bar instance must
    // continue to receive pluginData updates.
    function saveSetting(key, value) {
        if (root.pluginService)
            root.pluginService.savePluginData("aiUsage", key, value);
    }

    function toggleProvider(p) {
        root.saveSetting("providerFilter", logic.toggleFilter(root.providerFilter, p));
    }
    function selectAllProviders() {
        root.saveSetting("providerFilter", []);
    }
    function toggleHidden(card) {
        root.saveSetting("hiddenAccounts", logic.toggleHiddenCard(root.hiddenAccounts, card));
    }
    function isHidden(card) {
        return logic.isCardHidden(card, root.hiddenAccounts);
    }
    function setHeadlineMode(m) {
        root.saveSetting("headlineMode", m);
    }
    // A source changed on some surface. The stamp travels through the plugin
    // service, so the daemon refetches for every screen, including bars on
    // other screens that never saw the change.
    function stampSources() {
        root.saveSetting("sourcesStamp", Date.now());
    }

    // The plugin's daemon owns every fetch and the filed payloads. This widget,
    // one per screen, renders them.
    PluginDaemonLink {
        id: daemonLink
        pluginService: root.pluginService
        pluginId: root.pluginId
    }
    readonly property var daemon: daemonLink.daemon
    readonly property var providerData: root.daemon ? root.daemon.providerData : ({})
    // The providers with a fetch running, so a slot with no number yet can say
    // "waiting" rather than "nothing".
    readonly property var fetchingProviders: root.daemon ? root.daemon.fetchingProviders : []

    // One object every surface reads. The pill, the popout deck and the header
    // counts cannot disagree about which providers or accounts are in scope
    // because there is only one description of it.
    readonly property var deckState: ({
        providerData: root.providerData,
        filter: root.providerFilter,
        hidden: root.hiddenAccounts,
        mode: root.headlineMode,
        display: { value: root.barValue },
        fetching: root.fetchingProviders
    })

    readonly property var view: logic.deckView(root.deckState)
    readonly property bool ok: root.view.ok
    readonly property bool pending: root.view.pending
    readonly property bool allHidden: root.view.allHidden
    readonly property string errorText: root.view.error
    readonly property bool hasHeadline: root.view.headline !== null
    readonly property int headlinePct: root.view.headline === null ? 0 : root.view.headline

    readonly property int pillFontSize: Theme.barTextSize(
        root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)

    // Whether cards open expanded. Compact shows one row per limit; expanded
    // shows each limit as its own bar with its reset countdown under it.
    readonly property bool expandByDefault: pluginData.cardDetail === "expanded"
    // Absent means on: a fresh install shows the colour, and only a stored
    // false turns it off.
    readonly property bool barColor: pluginData.barColor !== false
    // What the bar draws in front of its numbers. The catalog resolves the
    // stored mode, falling back to whatever the boolean switch this replaced
    // was left on, so nobody's bar changes when they upgrade.
    readonly property string barIconMode: logic.barIconMode(pluginData.barIconMode, pluginData.barIcons)
    readonly property bool barSlotIcons: root.barIconMode === "provider"
    readonly property bool barWidgetIcon: root.barIconMode === "one"
    // Absent means on: a model lane the account has never called is dropped
    // from a compact card, and an expanded card still lists every one.
    readonly property bool hideUnusedLanes: pluginData.hideUnusedLanes !== false
    readonly property string barValue: pluginData.barValue === "left" ? "left" : "used"

    // The one card whose state is the opposite of the default. Storing the
    // exception rather than a set means changing the default flips every card,
    // which is what a default is for.
    property string toggledCardKey: ""

    function cardExpanded(key) {
        return root.expandByDefault !== (root.toggledCardKey === key);
    }
    function toggleCard(key) {
        root.toggledCardKey = root.toggledCardKey === key ? "" : key;
    }
    // Everything the shared display page reads and writes back by key.
    readonly property var displaySettings: ({
        headlineMode: root.headlineMode,
        barValue: root.barValue,
        // Raw, both of them: the page resolves the mode from the stored value or
        // from the switch it replaced, exactly as the settings application's
        // copy does, so the two surfaces cannot disagree about an upgraded
        // setting.
        barIconMode: pluginData.barIconMode || "",
        barIcons: pluginData.barIcons !== false,
        barColor: root.barColor,
        hideUnusedLanes: root.hideUnusedLanes,
        cardDetail: pluginData.cardDetail || "compact",
        providerFilter: root.providerFilter
    })

    function pillHeads() {
        return logic.pillSlots(root.deckState);
    }

    function formatResetAt(epoch) {
        return fmt.formatResetAt(epoch);
    }
    function formatSpend(meter) {
        return fmt.formatSpend(meter);
    }
    function formatSpendExact(meter) {
        return fmt.formatSpendExact(meter);
    }
    function resetLabel(meter) {
        return fmt.resetLabel(meter);
    }
    function metersFor(card, expanded) {
        return fmt.shownMeters(fmt.metersFor(card), expanded, root.hideUnusedLanes);
    }

    // Provider identity for the child surfaces. They reach the catalog through
    // the host rather than holding their own reference to it, so a component
    // property can never shadow the decision module the widget is using.
    function providerOrder() {
        return logic.providerOrder();
    }
    function providerName(p) {
        return logic.providerName(p);
    }
    function providerIcon(p) {
        return logic.providerIcon(p);
    }
    function providerFullName(p) {
        return logic.providerFullName(p);
    }
    function providerAsset(p) {
        return logic.providerAsset(p);
    }
    function accountFooter(card) {
        return logic.accountFooter(card);
    }
    function widgetIcon() {
        return logic.widgetIcon();
    }
    function filterHas(p) {
        return logic.filterHas(root.providerFilter, p);
    }
    // The provider list every filter surface renders: selected first, as
    // arranged, then the rest.
    function filterOrder() {
        return logic.filterOrder(root.providerFilter);
    }
    function canMoveProvider(p, delta) {
        return logic.canMoveProvider(root.providerFilter, p, delta);
    }
    function moveProvider(p, delta) {
        root.saveSetting("providerFilter", logic.moveProvider(root.providerFilter, p, delta));
    }
    function filterIsAll() {
        return logic.filterIsAll(root.providerFilter);
    }
    function filterLabel() {
        return logic.filterLabel(root.providerFilter);
    }
    function accountCountLabel(n) {
        return logic.accountCount(n);
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

    function percentageColor(pct) {
        return classColor(fmt.percentageClass(pct));
    }

    // A slot's colour. Severity is read from CONSUMPTION whichever end the bar
    // counts from, so turning the reading to "left" does not turn a full limit
    // green. `plain` is the neutral this orientation uses when there is no
    // number, or when the user asked for one colour.
    function slotColor(slot, plain) {
        if (slot.error)
            return Theme.error;
        if (slot.pct === null || !root.barColor)
            return plain;
        return root.percentageColor(slot.pct);
    }

    // Keep each provider icon with its slot when another provider has no number.
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            // One mark for the whole widget, ahead of every number. A crowded
            // bar pays for one icon here instead of one per slot; the popout
            // still says which number belongs to whom.
            VgsIcon {
                visible: root.barWidgetIcon
                name: root.widgetIcon()
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.verticalCenter: parent.verticalCenter
            }

            Repeater {
                model: root.pillHeads()

                Row {
                    required property var modelData
                    spacing: 2
                    anchors.verticalCenter: parent.verticalCenter

                    // A setup slot keeps the key glyph and its accent: it is an
                    // invitation, not a reading, and hiding it would leave the
                    // slot empty and the way in unreachable.
                    VgsIcon {
                        visible: modelData.setup
                        name: modelData.icon
                        size: root.iconSize
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    AiUsageProviderIcon {
                        visible: root.barSlotIcons && !modelData.setup
                        host: root
                        provider: modelData.provider
                        size: root.iconSize
                        color: modelData.error ? Theme.error : Theme.widgetIconColor
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: modelData.text
                        visible: text.length > 0
                        font.pixelSize: root.pillFontSize
                        font.weight: Font.Medium
                        color: root.slotColor(modelData, Theme.widgetTextColor)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }

    // The same slots stacked. A vertical bar shows every selected provider too,
    // so the two orientations cannot say different things about one payload.
    verticalBarPill: Component {
        Column {
            spacing: 2

            VgsIcon {
                visible: root.barWidgetIcon
                name: root.widgetIcon()
                size: root.iconSize
                color: Theme.widgetIconColor
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Repeater {
                model: root.pillHeads()

                Column {
                    required property var modelData
                    spacing: 0
                    anchors.horizontalCenter: parent.horizontalCenter

                    VgsIcon {
                        visible: modelData.setup
                        name: modelData.icon
                        size: root.iconSize
                        color: Theme.primary
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    AiUsageProviderIcon {
                        visible: root.barSlotIcons && !modelData.setup
                        host: root
                        provider: modelData.provider
                        size: root.iconSize
                        color: modelData.error ? Theme.error : Theme.widgetIconColor
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    StyledText {
                        text: modelData.text
                        visible: text.length > 0
                        font.pixelSize: root.pillFontSize
                        color: root.slotColor(modelData, Theme.widgetTextColor)
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }
        }
    }

    popoutWidth: 380
    popoutContent: Component {
        PopoutComponent {
            id: popout

            // Transient page state: usage, then display settings, then one
            // provider's setup. Both pushed pages are entered from the usage
            // page, so a step back always lands there.
            property int page: 0
            property string setupProvider: ""
            readonly property bool onSettings: popout.page === 1
            readonly property bool onSetup: popout.page === 2

            function openSetup(provider) {
                popout.setupProvider = provider;
                popout.page = 2;
            }

            // PluginPopout owns keyboard focus and uses this contract for Escape and
            // for resetting a pushed page when the popout closes.
            readonly property bool canPopBack: popout.page > 0
            function popBack() {
                popout.page = 0;
            }

            headerText: {
                if (popout.onSetup)
                    return logic.providerFullName(popout.setupProvider) + " setup";
                if (popout.onSettings)
                    return "Display settings";
                const picked = logic.selectedProviders(root.providerFilter);
                return picked.length === 1 ? logic.providerName(picked[0]) + " Usage" : "AI Usage";
            }
            detailsText: {
                if (popout.onSetup)
                    return "Where this provider's accounts come from.";
                // The settings page says nothing under its title: every control
                // on it is named by what it does. It still has to answer here,
                // or it would fall through and wear the usage page's line.
                if (popout.onSettings)
                    return "";
                if (root.pending)
                    return "Checking usage…";
                // A provider nobody has set up yet is not a fault to report.
                if (root.view.needsSetup)
                    return "Not set up yet";
                if (root.allHidden)
                    return logic.accountCount(root.view.totalCount) + " hidden";
                // Each failing provider still draws its own card with its own
                // cause; the header speaks only when no account answered at all.
                if (!root.ok)
                    return root.errorText || "Unavailable";
                const unavailable = root.view.shownCount - root.view.liveCount;
                let suffix = unavailable > 0 ? (" · " + unavailable + " unavailable") : "";
                if (root.view.hiddenCount > 0)
                    suffix += " · " + root.view.hiddenCount + " hidden";
                const used = root.hasHeadline ? (" · " + root.headlinePct + "% used") : "";
                return logic.accountCount(root.view.liveCount) + used + suffix;
            }
            showCloseButton: true

            // The shared header slot. This surface could always refresh — the
            // popout re-reads on open — but it offered no way to ask for one.
            refreshable: popout.page === 0
            refreshBusy: root.fetchingProviders.length > 0
            onRefreshRequested: {
                if (root.daemon)
                    root.daemon.refresh();
            }

            // The shared header slot, which PopoutComponent owns for every flyout.
            configurable: true
            settingsBack: popout.page > 0
            onSettingsRequested: {
                if (popout.page > 0)
                    popout.popBack();
                else
                    popout.page = 1;
            }

            // The viewport follows the active page height so a pushed page
            // replaces the usage content instead of adding to its total height.
            Item {
                id: pager

                width: parent.width
                clip: true
                height: popout.onSetup ? setupPage.implicitHeight
                    : (popout.onSettings ? settingsPage.implicitHeight : usagePage.implicitHeight)

                Behavior on height {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Easing.OutCubic
                    }
                }

                Row {
                    id: pages
                    spacing: 0
                    x: -popout.page * pager.width

                    Behavior on x {
                        NumberAnimation {
                            duration: Theme.mediumDuration
                            easing.type: Easing.OutCubic
                        }
                    }

                    Column {
                        id: usagePage
                        width: pager.width
                        spacing: Theme.spacingM

                        // The filter owns which providers are on the bar and in
                        // this list, and is the way into each provider's setup.
                        AiUsageFilterMenu {
                            width: parent.width
                            host: root
                            onProviderToggled: p => root.toggleProvider(p)
                            onMoveRequested: (p, delta) => root.moveProvider(p, delta)
                            onAllRequested: root.selectAllProviders()
                            onSetupRequested: p => popout.openSetup(p)
                        }

                        Repeater {
                            model: root.view.sections

                            Column {
                                id: section

                                required property var modelData

                                width: parent.width
                                spacing: Theme.spacingXS

                                // Section headers are noise when one provider is
                                // on screen; the popout title already names it.
                                Item {
                                    width: parent.width
                                    // Room above the header so a provider's group reads as its
                                    // own block rather than as a caption on the card above it.
                                    height: root.view.grouped
                                        ? sectionLabel.implicitHeight + Theme.spacingXS + 10 : 0
                                    visible: root.view.grouped

                                    Row {
                                        anchors.left: parent.left
                                        anchors.bottom: parent.bottom
                                        spacing: Theme.spacingXS

                                        AiUsageProviderIcon {
                                            host: root
                                            provider: section.modelData.provider
                                            size: Theme.iconSizeSmall
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            id: sectionLabel
                                            text: section.modelData.name
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }

                                Repeater {
                                    model: section.modelData.cards

                                    // The gap sits OUTSIDE the card rather than
                                    // as column spacing or card padding. Spacing
                                    // would leave the first card flush against
                                    // its section header, and padding inside the
                                    // card would put the gap inside the card's
                                    // own rectangle, which is its hover wash and
                                    // its click target.
                                    Item {
                                        id: cardSlot

                                        required property var modelData

                                        width: section.width
                                        height: card.height + 5

                                        AiUsageAccountCard {
                                            id: card

                                            y: 5
                                            width: cardSlot.width
                                            host: root
                                            account: cardSlot.modelData
                                            showProviderIcon: !root.view.grouped
                                            expanded: root.cardExpanded(cardSlot.modelData.key)
                                            onToggleExpanded: root.toggleCard(cardSlot.modelData.key)
                                        }
                                    }
                                }

                                // A provider that answered with nothing usable
                                // says so where its cards would have been, so
                                // one failing provider cannot be mistaken for
                                // a failure of the whole widget.
                                AiUsageProviderNotice {
                                    width: section.width
                                    host: root
                                    sectionData: section.modelData
                                    onSetupRequested: popout.openSetup(section.modelData.provider)
                                }
                            }
                        }
                    }

                    Column {
                        id: settingsPage
                        width: pager.width
                        spacing: Theme.spacingM

                        StyledRect {
                            width: parent.width
                            height: settingsCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            Column {
                                id: settingsCol
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                AiUsageDisplaySettings {
                                    width: parent.width
                                    values: root.displaySettings
                                    onChanged: (key, value) => root.saveSetting(key, value)
                                }

                                StyledText {
                                    text: "Accounts"
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Theme.fontWeightSectionHeader
                                    color: Theme.surfaceText
                                    visible: accountVisibility.count > 0
                                    topPadding: Theme.spacingXS
                                }

                                // Every account of every selected provider,
                                // hidden ones included: this is the only place
                                // a hidden account can be brought back.
                                Repeater {
                                    id: accountVisibility
                                    model: logic.allCards(root.deckState)

                                    Item {
                                        required property var modelData
                                        width: settingsCol.width
                                        height: 26

                                        AiUsageProviderIcon {
                                            id: rowIcon
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            host: root
                                            provider: modelData.provider
                                            size: Theme.iconSizeSmall
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            anchors.left: rowIcon.right
                                            anchors.leftMargin: Theme.spacingXS
                                            anchors.right: eyeIcon.left
                                            anchors.rightMargin: Theme.spacingS
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: modelData.label
                                            elide: Text.ElideMiddle
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: root.isHidden(modelData) ? Theme.surfaceVariantText
                                                                            : Theme.surfaceText
                                        }

                                        VgsIcon {
                                            id: eyeIcon
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            name: root.isHidden(modelData) ? "visibility_off" : "visibility"
                                            size: Theme.iconSizeSmall
                                            color: root.isHidden(modelData) ? Theme.surfaceVariantText
                                                                            : Theme.primary
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleHidden(modelData)
                                        }
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    visible: accountVisibility.count === 0
                                    text: "No accounts reported yet."
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }

                    Column {
                        id: setupPage
                        width: pager.width
                        spacing: Theme.spacingM

                        AiUsageProviderSetup {
                            width: parent.width
                            provider: popout.setupProvider
                            // Only mount the processes for the provider being
                            // looked at: this page is one of three in a Row and
                            // is built whether or not it is on screen.
                            active: popout.onSetup
                            onSourcesChanged: root.stampSources()
                        }
                    }
                }
            }
        }
    }
}
