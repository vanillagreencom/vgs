import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

import "MercuryLogic.js" as Logic
import "MercuryFormat.js" as Fmt

// One line of recent activity: who, when, how much, and what stands between
// it and a filed receipt.
//
// The receipt control is the only part with a decision in it. A transaction
// that already carries a receipt opens it; an outflow without one opens the
// file picker; money coming IN gets no control at all, because there is no
// counterpart receipt to chase. While any upload is in flight every row's
// control is disabled, so a second click cannot start a second POST.
Item {
    id: root

    required property var transaction
    // The organisation's own accounts, so a transfer between two of them can be
    // told apart from money actually spent.
    property var accounts: []
    // An upload is running for THIS row, so it shows a spinner instead.
    property bool busy: false
    // An upload is running for some row, so no row may start another.
    property bool locked: false

    signal openRequested(string url)
    signal attachRequested(string transactionId)

    readonly property string dashboardLink: String(root.transaction.dashboardLink || "")

    readonly property var receipt: Logic.receiptState(root.transaction, root.accounts)
    readonly property string kindIcon: Logic.transactionIcon(root.transaction, root.accounts)
    readonly property var statusView: Logic.statusView(root.transaction.status)

    implicitHeight: 50
    height: 50

    StyledRect {
        anchors.fill: parent
        anchors.topMargin: 1
        anchors.bottomMargin: 1
        radius: Theme.cornerRadius
        color: rowHover.hovered ? Theme.surfaceContainerHigh : "transparent"

        // The rest of the row opens this transaction in Mercury, where the
        // things this popout deliberately does not carry live: the memo, the
        // card, the full counterparty record. Declared on the background so
        // the buttons layered above it keep their own clicks.
        TapHandler {
            enabled: root.dashboardLink.length > 0
            onTapped: root.openRequested(root.dashboardLink)
        }
    }

    HoverHandler {
        id: rowHover
        cursorShape: root.dashboardLink.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.spacingM
        anchors.rightMargin: Theme.spacingS
        spacing: Theme.spacingS

        // What KIND of movement this is: a card charge, a transfer between the
        // organisation's own accounts, money it earned. Deliberately muted --
        // the amount already carries direction in its sign and its colour, and
        // the receipt column owns the only colour in the row that means "act
        // on this".
        VgsIcon {
            name: root.kindIcon
            size: Theme.iconSizeSmall
            color: Theme.surfaceVariantText
            Layout.alignment: Qt.AlignVCenter
        }

        Column {
            Layout.fillWidth: true
            spacing: 1

            StyledText {
                width: parent.width
                text: root.transaction.counterparty.length > 0
                    ? root.transaction.counterparty
                    : I18n.tr("Transaction")
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceText
                // StyledText word-wraps by default, and a counterparty name can
                // be a whole sentence ("Boeing Employees Credit Union - Personal
                // Online Banking - Checking ••7082"), which grew this
                // fixed-height row straight into the one below it.
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                elide: Text.ElideRight
            }

            Row {
                spacing: Theme.spacingXS

                StyledText {
                    text: Fmt.txDate(root.transaction.createdAt, Date.now())
                    visible: text.length > 0
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    text: "·"
                    visible: root.statusView.tone !== ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                // A posted transaction is the ordinary case and says nothing;
                // only the states worth acting on carry a label.
                StyledText {
                    text: root.statusView.label
                    visible: root.statusView.tone !== ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: {
                        switch (root.statusView.tone) {
                        case "error":
                            return Theme.error;
                        case "pending":
                            return Theme.warning;
                        default:
                            return Theme.surfaceVariantText;
                        }
                    }
                }
            }
        }

        StyledText {
            // A fixed column so the figures line up against each other rather
            // than against the names.
            Layout.preferredWidth: 96
            horizontalAlignment: Text.AlignRight
            text: (root.transaction.amount > 0 ? "+" : "") + Fmt.moneyPopout(root.transaction.amount)
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            wrapMode: Text.NoWrap
            color: root.transaction.amount > 0 ? Theme.success : Theme.surfaceText
        }

        Item {
            Layout.preferredWidth: 28
            Layout.preferredHeight: 28
            Layout.alignment: Qt.AlignVCenter

            VgsSpinner {
                anchors.centerIn: parent
                size: 18
                visible: root.busy
                running: root.busy
            }

            // ONE control, because there is one question: does this charge
            // have paperwork. A row used to be able to show a paperclip that
            // opened an invoice beside a grey icon asking for a receipt, which
            // is a contradiction -- and taking the offer filed a second copy of
            // the document that was already there.
            VgsActionButton {
                anchors.centerIn: parent
                visible: !root.busy && (root.receipt.documented || root.receipt.uploadable)
                iconName: root.receipt.documented ? "receipt_long" : "upload_file"
                iconFilled: root.receipt.documented
                iconSize: Theme.iconSizeSmall
                buttonSize: 28
                // Green for filed, grey for outstanding: the column reads as a
                // checklist at a glance, without anyone having to tell the two
                // glyphs apart.
                iconColor: root.receipt.documented ? Theme.success : Theme.surfaceVariantText
                enabled: !root.locked
                tooltipText: {
                    if (!root.receipt.documented)
                        return I18n.tr("Attach a receipt");
                    return root.receipt.count > 1
                        ? I18n.tr("Open the first of %1 attachments").arg(root.receipt.count)
                        : I18n.tr("Open the attachment");
                }
                onClicked: {
                    if (root.receipt.documented) {
                        root.openRequested(root.receipt.url);
                        return;
                    }
                    root.attachRequested(root.transaction.id);
                }
            }
        }
    }
}
