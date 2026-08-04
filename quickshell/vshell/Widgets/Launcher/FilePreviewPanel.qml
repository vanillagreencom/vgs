pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Rectangle {
    id: root

    property var item: null
    property var preview: ({})
    property bool loading: false
    property string matchQuery: ""
    readonly property string path: item?.data?.path || ""
    readonly property string previewIdentity: path + "\n" + (item?.data?.line || 0) + "\n" + matchQuery

    function escapeMarkup(value) {
        return String(value || "").replace(/&/g, "&amp;")
            .replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function highlightedMarkup(value, ranges) {
        const source = String(value || "");
        const matches = Array.isArray(ranges) ? ranges.slice() : [];
        if (matches.length === 0)
            return escapeMarkup(source);
        matches.sort((left, right) => (left.start || 0) - (right.start || 0));
        let markup = "";
        let position = 0;
        for (let i = 0; i < matches.length; i++) {
            const start = Math.max(position, Math.min(source.length, Number(matches[i].start) || 0));
            const end = Math.max(start, Math.min(source.length, Number(matches[i].end) || start));
            if (end <= start)
                continue;
            markup += escapeMarkup(source.slice(position, start));
            markup += "<font color=\"" + String(Theme.primary) + "\"><b>"
                + escapeMarkup(source.slice(start, end)) + "</b></font>";
            position = end;
        }
        return markup + escapeMarkup(source.slice(position));
    }

    function reload() {
        preview = {};
        loading = !!path;
        if (!path) {
            DSearchService.preview("", 0, "", null);
            return;
        }
        DSearchService.preview(path, item?.data?.line || 0, matchQuery, result => {
            if (path !== (result?.path || path))
                return;
            preview = result || {};
            loading = false;
            previewFlick.contentY = 0;
        });
    }

    function scrollBy(amount) {
        previewFlick.contentY = Math.max(0, Math.min(previewFlick.contentHeight - previewFlick.height, previewFlick.contentY + amount));
    }

    onPreviewIdentityChanged: reload()

    color: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
    border.color: Theme.borderColor
    border.width: 1
    radius: Theme.containerRadius
    clip: true

    Column {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingXXS

        Row {
            width: parent.width
            spacing: Theme.spacingS

            VgsIcon {
                name: root.item?.data?.is_dir ? "folder" : "preview"
                size: 18
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                width: parent.width - 18 - Theme.spacingS
                text: root.item?.name || I18n.tr("Preview")
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                elide: Text.ElideMiddle
                wrapMode: Text.NoWrap
                maximumLineCount: 1
                clip: true
            }
        }

        StyledText {
            width: parent.width
            text: root.item?.subtitle || ""
            visible: text.length > 0
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideMiddle
            wrapMode: Text.NoWrap
            maximumLineCount: 1
            clip: true
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: Theme.spacingM
        height: 1
        color: Theme.separatorColor
    }

    VgsFlickable {
        id: previewFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: footer.top
        anchors.margins: Theme.spacingM
        anchors.topMargin: Theme.spacingL
        clip: true
        contentWidth: width
        contentHeight: previewContent.height

        Item {
            id: previewContent
            width: previewFlick.width
            height: Math.max(previewFlick.height, previewImage.visible ? previewImage.implicitHeight : previewText.implicitHeight)
            clip: true

            Image {
                id: previewImage
                width: parent.width
                height: visible ? Math.min(implicitHeight, 900) : 0
                visible: root.preview?.kind === "image"
                source: visible ? "file://" + root.path : ""
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                sourceSize.width: Math.round(width * 2)
            }

            StyledText {
                id: previewText
                width: parent.width
                visible: !previewImage.visible
                text: {
                    if (root.loading)
                        return root.escapeMarkup(I18n.tr("Loading preview…"));
                    if (!root.path)
                        return root.escapeMarkup(I18n.tr("Select a result to preview it"));
                    if (!root.preview?.ok)
                        return root.escapeMarkup(root.preview?.error || I18n.tr("Preview unavailable"));
                    if (root.preview?.kind === "media")
                        return root.escapeMarkup(I18n.tr("Media file\nOpen it to play"));
                    return root.highlightedMarkup(
                        root.preview?.text || I18n.tr("No preview available"),
                        root.preview?.submatches || []
                    );
                }
                textFormat: Text.StyledText
                font.family: Theme.monoFontFamily
                font.pixelSize: Theme.fontSizeSmall
                color: root.preview?.ok === false ? Theme.error : Theme.surfaceTextMedium
                wrapMode: Text.WrapAnywhere
                lineHeight: 1.25
                clip: true
            }
        }
    }

    StyledText {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 28
        text: "Shift+↑↓  " + I18n.tr("scroll preview")
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.surfaceVariantText
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
