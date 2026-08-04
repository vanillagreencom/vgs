import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets.Tooltip

// The tooltip for content inside a window large enough to contain it: Settings
// and the Changelog (FloatingWindow), and the big popouts (Dash, Control
// Center, Notification Center).
//
// It must be an in-window popup rather than its own layer surface, because a
// Wayland client cannot learn where its own XDG toplevel sits on screen, so
// screen-absolute anchoring — what VgsTooltip does — cannot be computed for
// anything inside a FloatingWindow. Positions are therefore relative to the
// host window's contentItem, and the side is chosen from the room available
// inside it.
//
// For a bar/dock/pill surface too small to contain a tooltip, use VgsTooltip
// instead — see docs/architecture/design-language.md § Tooltips.
Item {
    id: root

    property string text: ""

    function show(text, item, offsetX, offsetY, preferredSide) {
        if (!item)
            return;

        let windowContentItem = item.Window?.window?.contentItem;
        if (!windowContentItem) {
            let current = item;
            while (current) {
                if (current.Window?.window?.contentItem) {
                    windowContentItem = current.Window.window.contentItem;
                    break;
                }
                current = current.parent;
            }
        }
        if (!windowContentItem)
            return;

        tooltip.parent = windowContentItem;
        tooltip.text = text;

        const itemPos = item.mapToItem(windowContentItem, 0, 0);
        const parentWidth = windowContentItem.width;
        const parentHeight = windowContentItem.height;
        const tooltipWidth = tooltip.implicitWidth;
        const tooltipHeight = tooltip.implicitHeight;

        const side = preferredSide || _determineBestSide(itemPos, item, parentWidth, parentHeight, tooltipWidth, tooltipHeight);

        let targetX = 0;
        let targetY = 0;

        switch (side) {
        case "left":
            targetX = itemPos.x - tooltipWidth - 8;
            targetY = itemPos.y + (item.height - tooltipHeight) / 2;
            break;
        case "right":
            targetX = itemPos.x + item.width + 8;
            targetY = itemPos.y + (item.height - tooltipHeight) / 2;
            break;
        case "top":
            targetX = itemPos.x + (item.width - tooltipWidth) / 2;
            targetY = itemPos.y - tooltipHeight - 8;
            break;
        case "bottom":
        default:
            targetX = itemPos.x + (item.width - tooltipWidth) / 2;
            targetY = itemPos.y + item.height + 8;
            break;
        }

        tooltip.x = Math.max(4, Math.min(parentWidth - tooltipWidth - 4, targetX + (offsetX || 0)));
        tooltip.y = Math.max(4, Math.min(parentHeight - tooltipHeight - 4, targetY + (offsetY || 0)));

        tooltip.open();
    }

    function _determineBestSide(itemPos, item, parentWidth, parentHeight, tooltipWidth, tooltipHeight) {
        const itemCenterX = itemPos.x + item.width / 2;
        const itemCenterY = itemPos.y + item.height / 2;

        const spaceLeft = itemPos.x;
        const spaceRight = parentWidth - (itemPos.x + item.width);
        const spaceTop = itemPos.y;
        const spaceBottom = parentHeight - (itemPos.y + item.height);

        if (spaceRight >= tooltipWidth + 16) {
            return "right";
        }
        if (spaceLeft >= tooltipWidth + 16) {
            return "left";
        }
        if (spaceBottom >= tooltipHeight + 16) {
            return "bottom";
        }
        if (spaceTop >= tooltipHeight + 16) {
            return "top";
        }

        if (itemCenterX > parentWidth / 2) {
            return "left";
        }
        return "right";
    }

    function hide() {
        tooltip.close();
    }

    Popup {
        id: tooltip

        property string text: ""

        // TooltipBody carries its own padding, so the Popup adds none, and
        // maxWidth reproduces the previous gutter: the text run is still capped
        // at 500.
        //
        // One metric does change, deliberately. The cap used to apply to the
        // Text's `width` but not its `implicitWidth`, and Popup sizes itself
        // from the latter — so text past 500px was elided at 500 inside a box
        // that kept growing, leaving the label stranded in a too-wide surface.
        // Capping the body caps the box with it. Only strings long enough to
        // elide are affected.
        padding: 0
        closePolicy: Popup.NoAutoClose
        modal: false
        dim: false

        background: null

        contentItem: TooltipBody {
            text: tooltip.text
            maxWidth: 500 + Theme.spacingM * 2
            // A Popup inside its host window has no backdrop of its own — there
            // is no WindowBlur behind it, unlike the layer-surface tooltip. So
            // it takes the opaque treatment every other backdrop-less surface
            // here takes (context menus, the OSD, the slideout), rather than
            // painting glass over nothing.
            blurAvailable: false
        }

        enter: Transition {
            NumberAnimation {
                property: "opacity"
                from: 0
                to: 1
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        exit: Transition {
            NumberAnimation {
                property: "opacity"
                from: 1
                to: 0
                duration: Theme.shorterDuration
                easing.type: Theme.standardEasing
            }
        }
    }
}
