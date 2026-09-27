import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Services
import qs.Widgets

import "MercuryLogic.js" as Logic
import "MercuryFormat.js" as Fmt

// The Mercury dropdown: what the organisation holds, what has moved recently,
// and — on the second page — the settings for both.
//
// It owns no financial state. Every figure is a binding off the one snapshot
// the daemon holds, so this view and every bar pill cannot show different
// numbers.
PopoutComponent {
    id: root

    // The MercuryWidget this popout opened from: file picker and links.
    required property var widget
    // The MercuryDaemon that owns the snapshot and runs the helper.
    required property var daemon

    // 0 = accounts and activity, 1 = settings. The settings used to mean
    // leaving for the settings app; as a page they sit beside the figures in a
    // clipped viewport that slides, and the viewport takes the height of
    // whichever page is showing, so the popout grows TO the settings rather
    // than growing BY them.
    property int page: 0
    readonly property bool onSettings: root.page === 1

    // PluginPopout owns Escape and uses this contract to pop a pushed page
    // before dismissing the surface, and to reset one when the popout closes.
    readonly property bool canPopBack: root.page > 0
    function popBack() {
        root.page = Math.max(0, root.page - 1);
    }

    // Which account has its number revealed, by id. Reset whenever the popout
    // closes: an account number must not be left on screen by a popout that
    // reopens hours later on a shared display.
    property string revealedAccountId: ""

    readonly property var accounts: root.daemon.hasFigures ? root.daemon.snapshot.accounts : []
    readonly property var transactions: root.daemon.hasFigures ? root.daemon.snapshot.transactions : []
    readonly property int outstanding: Logic.outstandingReceipts(root.transactions, root.accounts)

    headerText: (root.daemon.hasFigures && root.daemon.snapshot.orgName)
        ? root.daemon.snapshot.orgName : "Mercury"
    detailsText: {
        if (root.onSettings)
            return I18n.tr("Settings");
        if (root.daemon.loading && !root.daemon.hasFigures)
            return I18n.tr("Loading…");
        if (!root.daemon.hasFigures)
            return "";
        const total = Fmt.moneyPopout(Logic.totalBalance(root.accounts));
        return total + " · " + Fmt.daysLabel(root.daemon.days);
    }
    showCloseButton: true
    spacing: Theme.spacingS

    // The shared header slot, not a hand-rolled button: PopoutComponent owns
    // where a refresh control lives and how it behaves while busy.
    refreshable: !root.onSettings
    refreshBusy: root.daemon.loading
    onRefreshRequested: root.daemon.refresh()

    configurable: true
    settingsBack: root.onSettings
    onSettingsRequested: root.page = root.onSettings ? 0 : 1

    // Opening the popout is the moment the user is looking, so the figures are
    // re-read — but only if they are actually stale, since brushing past the
    // bar must not cost a bank call.
    //
    // Watched as a bound property rather than through Connections:
    // `parentPopout` is a var that PluginPopout assigns after this content
    // loads, so a Connections handler has no target type to resolve its signal
    // against and the whole component fails to build.
    readonly property bool popoutShowing: root.parentPopout ? root.parentPopout.shouldBeVisible : false
    onPopoutShowingChanged: {
        if (root.popoutShowing) {
            root.daemon.refreshIfStale();
            return;
        }
        // Dismissed: forget both transient states, so the next open starts
        // from the figures with nothing revealed.
        root.revealedAccountId = "";
        root.page = 0;
    }
    Component.onCompleted: root.daemon.refreshIfStale()

    headerActions: Component {
        Row {
            spacing: Theme.spacingXS

            VgsActionButton {
                iconName: "open_in_new"
                iconColor: Theme.surfaceText
                visible: !root.onSettings
                tooltipText: I18n.tr("Open the Mercury dashboard")
                onClicked: root.widget.openUrl(Logic.dashboardUrl())
            }

        }
    }

    // ---- pager ----
    Item {
        id: pager

        width: parent.width
        clip: true
        height: root.onSettings ? settingsPage.implicitHeight : mainPage.implicitHeight

        Behavior on height {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Easing.OutCubic
            }
        }

        // Each page at an explicit x rather than laid out by a Row. A
        // positioner SKIPS a child it considers empty, and this front page is
        // empty whenever a fetch fails before any figures have arrived -- which
        // would collapse the strip and slide the settings page out of the
        // clipped viewport instead of into it.
        Item {
            id: pageStrip
            width: pager.width * 2
            height: pager.height
            x: -root.page * pager.width

            Behavior on x {
                NumberAnimation {
                    duration: Theme.mediumDuration
                    easing.type: Easing.OutCubic
                }
            }

            Column {
                id: mainPage
                x: 0
                width: pager.width
                spacing: Theme.spacingS

                // ---- what went wrong, above the figures it applies to ----
                StyledRect {
                    width: parent.width
                    visible: root.daemon.snapshotError !== ""
                    height: visible ? errorRow.implicitHeight + Theme.spacingM * 2 : 0
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.error, 0.12)

                    RowLayout {
                        id: errorRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        VgsIcon {
                            name: "error"
                            size: Theme.iconSize - 4
                            color: Theme.error
                            Layout.alignment: Qt.AlignTop
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: root.daemon.snapshotError
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.error
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                // ---- accounts ----
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.accounts.length > 0

                    Repeater {
                        model: root.accounts

                        MercuryAccountRow {
                            required property var modelData

                            width: parent.width
                            account: modelData
                            revealed: root.revealedAccountId === modelData.id
                            onRevealToggled: {
                                root.revealedAccountId = (root.revealedAccountId === modelData.id)
                                    ? "" : modelData.id;
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.daemon.hasFigures && root.accounts.length === 0
                    text: I18n.tr("This Mercury organisation has no accounts.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                // ---- recent activity ----
                RowLayout {
                    width: parent.width
                    visible: root.transactions.length > 0
                    spacing: Theme.spacingS

                    StyledText {
                        Layout.fillWidth: true
                        topPadding: Theme.spacingS
                        text: I18n.tr("Recent activity")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                    }

                    // The number this widget exists to drive to zero, stated
                    // rather than left for the user to count in grey icons.
                    StyledText {
                        topPadding: Theme.spacingS
                        visible: root.outstanding > 0
                        text: I18n.tr("%1 without a receipt").arg(root.outstanding)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }

                Column {
                    width: parent.width
                    spacing: 0
                    visible: root.transactions.length > 0

                    Repeater {
                        model: root.transactions

                        MercuryTransactionRow {
                            required property var modelData

                            width: parent.width
                            transaction: modelData
                            accounts: root.accounts
                            busy: root.daemon.uploadingTxId === modelData.id
                            locked: root.daemon.uploadingTxId !== ""

                            onOpenRequested: url => root.widget.openUrl(url)
                            onAttachRequested: transactionId => root.widget.askForReceipt(transactionId)
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.daemon.hasFigures && root.transactions.length === 0
                    text: I18n.tr("Nothing in the %1.").arg(Fmt.daysLabel(root.daemon.days))
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
            }

            MercuryPopoutSettings {
                id: settingsPage
                x: pager.width
                width: pager.width
                widget: root.widget
                daemon: root.daemon
            }
        }
    }
}
