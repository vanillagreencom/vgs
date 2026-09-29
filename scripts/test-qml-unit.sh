#!/usr/bin/env bash
# Controls for scripts/qml-unit.sh and the unit tests under
# scripts/qml-tests/: a table of mutations, one per guarantee a test pins,
# each applied to a copy of shell/Ui with its match counted, and the runner
# is required to fail on every copy and to pass on the unmutated copy. Two
# rows pin the runner's arguments: a missing qmltestrunner is not a pass,
# and an unknown argument is refused. A second table plants one test file
# per rule of the runner's log check and pins the exit and the line each
# prints.
#
# Exit 0 when every row holds, 1 otherwise, 77 when qmltestrunner is absent,
# since a mutation nothing runs proves nothing.
set -euo pipefail

self="$(readlink -f -- "${BASH_SOURCE[0]}")"
repo="$(cd -- "$(dirname -- "$self")/.." && pwd)"
runner="$repo/scripts/qml-unit.sh"

if ! out="$("$runner" --tests "$repo/scripts/qml-tests" "$repo/scripts/qml-tests/tst_module.qml" 2>&1)"; then
  if [[ $out == *"status=not-measured missing=qmltestrunner"* ]]; then
    echo "test-qml-unit: status=not-measured missing=qmltestrunner"
    exit 77
  fi
  echo "test-qml-unit: the module test does not pass on the shipped tree:"
  printf '%s\n' "$out" | tail -n 20
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf -- "${tmp:?}"' EXIT
failures=0
ok() { printf '  ok    %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf '  FAIL  %s\n' "$*"; }

# One fresh copy of the module under test at $1.
fresh() {
  rm -rf -- "$1"
  cp -R -- "$repo/shell/Ui" "$1"
}

# Rows: label | file under shell/Ui | text to replace | replacement | the
# test file that must go red. The replacement keeps the text around the
# behaviour and removes the behaviour. A field holds no `|`, the separator.
mutations=(
  "the label's role is not read|foundation/Label.qml|const found = Theme.text[name];|const found = undefined;|tst_label.qml"
  "the label's weight does not reach the axis|foundation/Label.qml|font.variableAxes: ({ wght: typography.weight })|font.variableAxes: ({ wght: 400 })|tst_label.qml"
  "the bar role draws at the body metrics|../Commons/Tokens.js|bar: role(\"mono\", 0.8, 500, 0.08, 1, true, \"text\")|bar: role(\"sans\", 1, 400, 0, 1.55, false, \"text\")|tst_label.qml"
  "body text draws in the mono family|../Commons/Tokens.js|body: role(\"sans\", 1, 400, 0, 1.55, false, \"text\")|body: role(\"mono\", 1, 400, 0, 1.55, false, \"text\")|tst_label.qml"
  "an absent family draws the mono family whatever its token|../Commons/Theme.qml|convertLeaf(level[key], node[key], fallback[key], loaded, families, missing)|convertLeaf(level[key], node[key], loaded[0], loaded, families, missing)|tst_label.qml"
  "the label's letter spacing is not scaled|foundation/Label.qml|font.letterSpacing: typography.letterSpacing * typography.size|font.letterSpacing: typography.letterSpacing|tst_label.qml"
  "the icon's stroke scales with its size|foundation/Icon.qml|strokeWidth: root.stroke / root.factor|strokeWidth: root.stroke|tst_icon.qml"
  "the icon's path is not scaled|foundation/Icon.qml|transform: Scale { xScale: root.factor; yScale: root.factor }|transform: Scale { xScale: 1; yScale: 1 }|tst_icon.qml"
  "the icon keeps an unknown name's paths|foundation/Icon.qml|return [\"\", \"\"];|return Lucide.ICONS.circle;|tst_icon.qml"
  "the focus ring ignores a text input's focus|foundation/FocusRing.qml|visible: target.visualFocus === undefined ? target.activeFocus : target.visualFocus|visible: target.visualFocus === true|tst_textfield.qml"
  "the progress fill stays displaced|feedback/ProgressBar.qml|onStopped: fill.x = Qt.binding(() => root.mirrored && !root.indeterminate ? fill.parent.width - fill.width : 0)|onStopped: {}|tst_feedback.qml"
  "the popover does not count as open|overlay/Popover.qml|onVisibleChanged: root.share(visible)|onVisibleChanged: {}|tst_overlays.qml"
  "a hidden anchor leaves its popup open|overlay/AnchorTracker.qml|function onVisibleChanged() { if (!target.visible) tracker.popup.visible = false; }|function onVisibleChanged() {}|tst_overlays.qml"
  "a moved anchor leaves its popup behind|overlay/AnchorTracker.qml|if (popup.visible) popup.anchor.updateAnchor();|return;|tst_overlays.qml"
  "the tooltip opens under an open overlay|overlay/Tooltip.qml|if (root.resting && OverlayState.open === 0) window.visible = true|if (root.resting) window.visible = true|tst_overlays.qml"
  "the tooltip opens again over what a press opened|overlay/Tooltip.qml|onPressedChanged: if (pressed) root.pressedHere = true|onPressedChanged: {}|tst_overlays.qml"
  "the menu stays open after a trigger|overlay/Menu.qml|function onTriggered() { root.close(); }|function onTriggered() {}|tst_overlays.qml"
  "the menu keys move no highlight|overlay/Menu.qml|item.highlighted = index === currentIndex;|item.highlighted = false;|tst_overlays.qml"
  "the menu window stays at the minimum width|overlay/Menu.qml|implicitWidth: Math.max(Theme.menu.minWidth, root.widest + 2 * Theme.menu.padding + Theme.scrollArea.gutter)|implicitWidth: Theme.menu.minWidth|tst_overlays.qml"
  "the menu grows past its maximum height|overlay/Menu.qml|Math.min(column.implicitHeight, root.maxHeight)|column.implicitHeight|tst_overlays.qml"
  "the highlight scrolls out of view|overlay/Menu.qml|else if (item.y + item.height > scroll.contentY + scroll.height) scroll.contentY = item.y + item.height - scroll.height;|else {}|tst_overlays.qml"
  "the menu opens on no entry whatever is checked|overlay/Menu.qml|currentIndex = items().findIndex(item => reachable(item) && item.checked);|currentIndex = -1;|tst_overlays.qml"
  "the menu opens where it was scrolled|overlay/Menu.qml|scroll.contentY = 0;|scroll.contentY = scroll.contentY;|tst_overlays.qml"
  "typing jumps to an entry that holds the letters|overlay/Menu.qml|String(item.text).toLowerCase().indexOf(prefix) === 0|String(item.text).toLowerCase().indexOf(prefix) !== -1|tst_overlays.qml"
  "typing keeps no letters|overlay/Menu.qml|let wanted = typed + letter.toLowerCase();|let wanted = letter.toLowerCase();|tst_overlays.qml"
  "a letter no prefix continues jumps nowhere|overlay/Menu.qml|            found = find(wanted);|            found = -1;|tst_overlays.qml"
  "the typed letters are never cleared|overlay/Menu.qml|onTriggered: root.typed = \"\"|onTriggered: {}|tst_overlays.qml"
  "the checked entry draws no mark|overlay/MenuItem.qml|visible: root.checked|visible: false|tst_overlays.qml"
  "the check mark takes no room|overlay/MenuItem.qml|rightPadding: Theme.menu.item.paddingX + (checked ? Theme.icon.size.sm + spacing : 0)|rightPadding: Theme.menu.item.paddingX|tst_overlays.qml"
  "the scroll area leaves no gutter|layout/ScrollArea.qml|contentWidth: width - Theme.scrollArea.gutter|contentWidth: width|tst_scroll.qml"
  "the scroll area's gutter comes and goes with the overflow|layout/ScrollArea.qml|contentWidth: width - Theme.scrollArea.gutter|contentWidth: overflowing ? width - Theme.scrollArea.gutter : width|tst_scroll.qml"
  "the bar shows without an overflow|layout/ScrollBar.qml|    visible: needed|    visible: true|tst_scroll.qml"
  "the thumb shrinks below its minimum|layout/ScrollBar.qml|Math.max(Theme.scrollArea.minThumb, height * flickable.height / flickable.contentHeight)|height * flickable.height / flickable.contentHeight|tst_scroll.qml"
  "the thumb is not the view's share|layout/ScrollBar.qml|Math.max(Theme.scrollArea.minThumb, height * flickable.height / flickable.contentHeight)|Theme.scrollArea.minThumb|tst_scroll.qml"
  "dragging the thumb scrolls nothing|layout/ScrollBar.qml|if (pressed) root.dragTo(mapToItem(root, 0, mouse.y).y - grab);|if (pressed) {}|tst_scroll.qml"
  "the dragged thumb jumps to the pointer|layout/ScrollBar.qml|root.dragTo(mapToItem(root, 0, mouse.y).y - grab)|root.dragTo(mapToItem(root, 0, mouse.y).y)|tst_scroll.qml"
  "a press on the track pages nothing|layout/ScrollBar.qml|onPressed: mouse => root.page(mouse.y < thumbItem.y ? -1 : 1)|onPressed: mouse => {}|tst_scroll.qml"
  "a press on the track always pages down|layout/ScrollBar.qml|onPressed: mouse => root.page(mouse.y < thumbItem.y ? -1 : 1)|onPressed: mouse => root.page(1)|tst_scroll.qml"
  "the idle bar never fades|layout/ScrollBar.qml|opacity: active ? 1 : Theme.scrollArea.idleOpacity|opacity: 1|tst_scroll.qml"
  "scrolling does not show the bar|layout/ScrollBar.qml|function onContentYChanged() { recent.restart(); }|function onContentYChanged() {}|tst_scroll.qml"
  "hovering does not show the bar|layout/ScrollBar.qml|readonly property bool active: hovered|readonly property bool active: false|tst_scroll.qml"
  "the select list leaves no gutter|controls/Select.qml|width: ListView.view.width - (entries.overflowing ? Theme.scrollArea.gutter : 0)|width: ListView.view.width|tst_scroll.qml"
  "a click leaves the title's menu closed|controls/TitleButton.qml|onClicked: toggleMenu()|onClicked: {}|tst_titlebutton.qml"
  "down leaves the title's menu closed|controls/TitleButton.qml|Keys.onDownPressed: toggleMenu()|Keys.onDownPressed: {}|tst_titlebutton.qml"
  "the title ignores hover|controls/TitleButton.qml|readonly property color foreground: hovered|readonly property color foreground: false && hovered|tst_titlebutton.qml"
  "the underline sits on the text|controls/TitleButton.qml|y: label.height + Theme.titleButton.underlineGap|y: label.height|tst_titlebutton.qml"
  "the caret touches the text|controls/TitleButton.qml|x: label.width + root.spacing|x: label.width|tst_titlebutton.qml"
  "a narrow title overflows its button|controls/TitleButton.qml|width: Math.min(implicitWidth, parent.width - root.spacing - caret.width)|width: implicitWidth|tst_titlebutton.qml"
  "the select accepts an index past its end|controls/Select.qml|index >= count) return;|index >= count + 100) return;|tst_overlays.qml"
  "the select ignores its text role|controls/Select.qml|return String(entry[textRole]);|return String(entry);|tst_overlays.qml"
  "the select breaks its index binding on the current choice|controls/Select.qml|if (index !== currentIndex) currentIndex = index;|currentIndex = index;|tst_overlays.qml"
  "the toast ignores its tone|feedback/Toast.qml|const found = Theme.badge.tone[name];|const found = undefined;|tst_overlays.qml"
  "Return answers no dialog|feedback/Dialog.qml|Keys.onReturnPressed: pressFocused()|Keys.onReturnPressed: {}|tst_dialog.qml"
  "Enter answers no dialog|feedback/Dialog.qml|Keys.onEnterPressed: pressFocused()|Keys.onEnterPressed: {}|tst_dialog.qml"
  "Escape leaves the dialog unanswered|feedback/Dialog.qml|Keys.onEscapePressed: if (!busy) rejected()|Keys.onEscapePressed: {}|tst_dialog.qml"
  "Escape answers a busy dialog|feedback/Dialog.qml|Keys.onEscapePressed: if (!busy) rejected()|Keys.onEscapePressed: rejected()|tst_dialog.qml"
  "the dialog's focus stays on the action last clicked|feedback/Dialog.qml|onActiveFocusChanged: if (activeFocus) focusAccept()|onActiveFocusChanged: {}|tst_dialog.qml"
  "the dialog's first action takes the focus|feedback/Dialog.qml|const button = buttons()[acceptIndex];|const button = buttons()[0];|tst_dialog.qml"
  "Enter presses the accept action whatever holds the focus|feedback/Dialog.qml|trigger(focused !== -1 ? focused : acceptIndex);|trigger(acceptIndex);|tst_dialog.qml"
  "Tab stops at the dialog's last action|feedback/Dialog.qml|reach[(at + step + reach.length) % reach.length]|reach[Math.max(0, Math.min(at + step, reach.length - 1))]|tst_dialog.qml"
  "Tab leaves the dialog from an action|feedback/Dialog.qml|Keys.onTabPressed: root.cycle(1)|Keys.onTabPressed: event => { event.accepted = false; }|tst_dialog.qml"
  "Tab leaves the dialog from the dialog itself|feedback/Dialog.qml|Keys.onTabPressed: cycle(1)|Keys.onTabPressed: event => { event.accepted = false; }|tst_dialog.qml"
  "Tab stops on a disabled action|feedback/Dialog.qml|buttons().filter(button => button.enabled)|buttons()|tst_dialog.qml"
  "Tab focus draws no ring in the dialog|feedback/Dialog.qml|next.forceActiveFocus(step > 0 ? Qt.TabFocusReason : Qt.BacktabFocusReason)|next.forceActiveFocus()|tst_dialog.qml"
  "a pressed dialog action answers nothing|feedback/Dialog.qml|onClicked: root.trigger(index)|onClicked: {}|tst_dialog.qml"
  "a cancel action draws the accept variant|feedback/Dialog.qml|role === \"accept\" ? \"primary\" : \"tertiary\"|\"primary\"|tst_dialog.qml"
  "an unknown action role accepts|feedback/Dialog.qml|role = \"cancel\";|role = \"accept\";|tst_dialog.qml"
  "a busy dialog's actions stay enabled|feedback/Dialog.qml|enabled: modelData.enabled && !root.busy|enabled: modelData.enabled|tst_dialog.qml"
  "a busy dialog answers|feedback/Dialog.qml|const answers = !busy && entry|const answers = entry|tst_dialog.qml"
  "a disabled dialog action answers|feedback/Dialog.qml|entry !== undefined && entry.enabled;|entry !== undefined;|tst_dialog.qml"
  "a busy dialog shows no spinner|feedback/Dialog.qml|visible: root.busy|visible: false|tst_dialog.qml"
  "the dialog's title ignores its role token|feedback/Dialog.qml|role: Theme.dialog.titleRole|role: \"h3\"|tst_dialog.qml"
  "the dialog's message ignores its role token|feedback/Dialog.qml|role: Theme.dialog.bodyRole|role: \"body\"|tst_dialog.qml"
  "the dialog's card ignores its background token|feedback/Dialog.qml|color: Theme.dialog.background|color: Theme.color.surface|tst_dialog.qml"
  "the dialog's content is hidden|feedback/Dialog.qml|visible: children.length > 0|visible: false|tst_dialog.qml"
  "the card leans by a fixed skew|layout/AngledCard.qml|property real skew: Theme.angledCard.skew|property real skew: 28|tst_angledcard.qml"
  "the card's top edge does not lean|layout/AngledCard.qml|Qt.point(Math.max(skew, 0), 0),|Qt.point(0, 0),|tst_angledcard.qml"
  "a negative skew leans the card as a positive one|layout/AngledCard.qml|Qt.point(-Math.min(skew, 0), height)|Qt.point(0, height)|tst_angledcard.qml"
  "the card's outline is left open|layout/AngledCard.qml|readonly property var outline: corners.concat([corners[0]])|readonly property var outline: corners|tst_angledcard.qml"
  "the card's content is not masked|layout/AngledCard.qml|maskEnabled: true|maskEnabled: false|tst_angledcard.qml"
  "the card's mask has no coverage|layout/AngledCard.qml|strokeColor: \"transparent\"|strokeColor: \"transparent\"; fillColor: \"transparent\"|tst_angledcard.qml"
  "a selected card is washed|layout/AngledCard.qml|property bool dimmed: !selected|property bool dimmed: true|tst_angledcard.qml"
  "the card's wash ignores dimmed|layout/AngledCard.qml|visible: root.dimmed|visible: !root.selected|tst_angledcard.qml"
  "the card's wash ignores its token|layout/AngledCard.qml|color: Theme.angledCard.dim|color: Theme.color.scrim|tst_angledcard.qml"
  "a selected card draws the plain outline width|layout/AngledCard.qml|strokeWidth: root.selected ? Theme.angledCard.selectedBorderWidth : Theme.angledCard.borderWidth|strokeWidth: Theme.angledCard.borderWidth|tst_angledcard.qml"
  "a selected card draws the plain outline colour|layout/AngledCard.qml|strokeColor: root.selected ? Theme.angledCard.selectedBorder : Theme.angledCard.border|strokeColor: Theme.angledCard.border|tst_angledcard.qml"
  "the card's wash is not Omarchy's 0.42|../Commons/Tokens.js|dim: color(\"alpha({palette.background}, 0.42)\")|dim: color(\"alpha({palette.background}, 0.5)\")|tst_angledcard.qml"
  "the selected outline is not Omarchy's 3 pixels|../Commons/Tokens.js|selectedBorderWidth: length(3)|selectedBorderWidth: length(\"{border.thick}\")|tst_angledcard.qml"
  "the card's outline is not a hairline|../Commons/Tokens.js|borderWidth: length(\"{border.thin}\")|borderWidth: length(\"{border.thick}\")|tst_angledcard.qml"
  "the carousel's unit ignores its height|layout/CardCarousel.qml|Math.min(tokens.maxScale, root.width / reference, root.height / tokens.expandedHeight)|Math.min(tokens.maxScale, root.width / reference)|tst_carousel.qml"
  "the carousel's unit ignores its width|layout/CardCarousel.qml|Math.min(tokens.maxScale, root.width / reference, root.height / tokens.expandedHeight)|Math.min(tokens.maxScale, root.height / tokens.expandedHeight)|tst_carousel.qml"
  "the carousel's unit falls below its minimum|layout/CardCarousel.qml|Math.max(tokens.minScale, |Math.max(0, |tst_carousel.qml"
  "the carousel's unit rises past its maximum|layout/CardCarousel.qml|Math.min(tokens.maxScale, |Math.min(Infinity, |tst_carousel.qml"
  "the reference rail leaves no margin|layout/CardCarousel.qml| + 2 * tokens.referenceMargin||tst_carousel.qml"
  "the reference rail is not Omarchy's thirteen steps|../Commons/Tokens.js|referenceSteps: number(13, 0, 64)|referenceSteps: number(12, 0, 64)|tst_carousel.qml"
  "the rail is not centred down the carousel|layout/CardCarousel.qml|readonly property real top: (root.height - expandedHeight) / 2|readonly property real top: 0|tst_carousel.qml"
  "the slices are not centred on the expanded card|layout/CardCarousel.qml|sliceTop: top + (expandedHeight - sliceHeight) / 2|sliceTop: top|tst_carousel.qml"
  "the right slices do not overlap the expanded card|layout/CardCarousel.qml|left + expandedWidth - overlap + (offset - 1) * pitch|left + expandedWidth + (offset - 1) * pitch|tst_carousel.qml"
  "the left slices step by their width|layout/CardCarousel.qml|left + offset * pitch|left + offset * sliceWidth|tst_carousel.qml"
  "the overlap does not shorten the slice step|layout/CardCarousel.qml|Math.max(sliceWidth - overlap, 1)|Math.max(sliceWidth, 1)|tst_carousel.qml"
  "a slice that does not fit whole is shown|layout/CardCarousel.qml|Math.floor(left / pitch)|Math.ceil(left / pitch)|tst_carousel.qml"
  "no card past the shown slices is built|layout/CardCarousel.qml|slicesPerSide + tokens.band|slicesPerSide|tst_carousel.qml"
  "every card of the model is built|layout/CardCarousel.qml|active: slot.retained|active: true|tst_carousel.qml"
  "a built card past the shown slices is drawn|layout/CardCarousel.qml|visible: shown|visible: retained|tst_carousel.qml"
  "the card's lean does not scale with the rail|layout/CardCarousel.qml|Theme.angledCard.skew * unit|Theme.angledCard.skew|tst_carousel.qml"
  "the current card is not selected|layout/CardCarousel.qml|selected: slot.offset === 0|selected: false|tst_carousel.qml"
  "the card nearer the current one is not on top|layout/CardCarousel.qml|z: -Math.abs(offset)|z: 0|tst_carousel.qml"
  "a slice decodes in pixels, not device pixels|layout/CardCarousel.qml|Qt.size(Math.round(sliceWidth * root.devicePixelRatio), Math.round(sliceHeight * root.devicePixelRatio))|Qt.size(Math.round(sliceWidth), Math.round(sliceHeight))|tst_carousel.qml"
  "the full decode has no cap|layout/CardCarousel.qml|Math.min(1, tokens.decodeCap / (Math.max(expandedWidth, expandedHeight) * root.devicePixelRatio))|1|tst_carousel.qml"
  "the neighbours decode at the slice size|layout/CardCarousel.qml|Math.abs(offset) <= 1 ? internal.fullDecode|offset === 0 ? internal.fullDecode|tst_carousel.qml"
  "a card's decode size stays as it was built|layout/CardCarousel.qml|content.decodeSize = Qt.binding(() => slot.decodeSize);||tst_carousel.qml"
  "a card's content is not handed its entry|layout/CardCarousel.qml|{ modelData: slot.modelData, |{ modelData: slot.index, |tst_carousel.qml"
  "a click on a slice selects nothing|layout/CardCarousel.qml|else root.currentIndex = slot.index;|else {}|tst_carousel.qml"
  "a click on the current card activates nothing|layout/CardCarousel.qml|if (slot.offset === 0) root.activated(slot.index);|if (slot.offset === 0) {}|tst_carousel.qml"
  "a click lands on a card's bounding box|layout/CardCarousel.qml|return internal.inside(card, point);|return true;|tst_carousel.qml"
  "Left steps forward|layout/CardCarousel.qml|step(-1);|step(1);|tst_carousel.qml"
  "Backtab steps nowhere|layout/CardCarousel.qml|case Qt.Key_Backtab:|case Qt.Key_unknown:|tst_carousel.qml"
  "Right steps back|layout/CardCarousel.qml|step(1);|step(-1);|tst_carousel.qml"
  "Shift+Tab steps forward|layout/CardCarousel.qml|step(event.modifiers & Qt.ShiftModifier ? -1 : 1);|step(1);|tst_carousel.qml"
  "Home stays on the current card|layout/CardCarousel.qml|step(-currentIndex);|step(0);|tst_carousel.qml"
  "End stays on the current card|layout/CardCarousel.qml|step(cards.count - 1 - currentIndex);|step(0);|tst_carousel.qml"
  "a step stops at the ends|layout/CardCarousel.qml|((currentIndex + delta) % count + count) % count|Math.max(0, Math.min(count - 1, currentIndex + delta))|tst_carousel.qml"
  "a part-notch steps|layout/CardCarousel.qml|Math.trunc(internal.wheel / internal.notch)|Math.sign(internal.wheel)|tst_carousel.qml"
  "a part-notch is dropped|layout/CardCarousel.qml|internal.wheel -= notches * internal.notch;|internal.wheel = 0;|tst_carousel.qml"
  "the wheel steps the other way|layout/CardCarousel.qml|root.step(-notches);|root.step(notches);|tst_carousel.qml"
  "a sideways wheel steps nothing|layout/CardCarousel.qml|wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : wheel.angleDelta.x|wheel.angleDelta.y|tst_carousel.qml"
  "a hidden carousel keeps a part-notch|layout/CardCarousel.qml|            wheel = 0;|            wheel = wheel;|tst_carousel.qml"
  "the rail shows before it settles|layout/CardCarousel.qml|visible: internal.settled|visible: true|tst_carousel.qml"
  "a carousel shown again stays settled|layout/CardCarousel.qml|            settled = false;|            settled = settled;|tst_carousel.qml"
  "a seeded index glides before the rail settles|layout/CardCarousel.qml|const glides = settled && |const glides = |tst_carousel.qml"
  "a move past the shown slices glides|layout/CardCarousel.qml| && Math.abs(target - position) <= slicesPerSide;|;|tst_carousel.qml"
  "a move within the shown slices lands at once|layout/CardCarousel.qml|glide.start();|position = target;|tst_carousel.qml"
  "a change of the current index moves nothing|layout/CardCarousel.qml|onCurrentIndexChanged: internal.follow()|onCurrentIndexChanged: {}|tst_carousel.qml"
  "a card the glide leaves is hidden at once|layout/CardCarousel.qml|Math.min(Math.abs(offset), Math.abs(index - internal.position))|Math.abs(offset)|tst_carousel.qml"
  "a card between two places is hidden|layout/CardCarousel.qml|distance < internal.slicesPerSide + 1|distance <= internal.slicesPerSide|tst_carousel.qml"
  "a card between two places is released|layout/CardCarousel.qml|distance < internal.reach + 1|distance <= internal.reach|tst_carousel.qml"
  "the rail draws past the carousel|layout/CardCarousel.qml|clip: true|clip: false|tst_carousel.qml"
  "a delegate without decodeSize is kept|layout/CardCarousel.qml|const built = content !== null && \"decodeSize\" in content;|const built = content !== null;|tst_carousel.qml"
  "a delegate that built nothing is used|layout/CardCarousel.qml|const built = content !== null && \"decodeSize\" in content;|const built = \"decodeSize\" in content;|tst_carousel.qml"
  "a refused content stays in its card|layout/CardCarousel.qml|if (content !== null) content.destroy();||tst_carousel.qml"
  "a card left empty is not named|layout/CardCarousel.qml|console.warn(\"CardCarousel: no content index=\"|void(\"CardCarousel: no content index=\"|tst_carousel.qml"
  "the rail moves over another duration|layout/CardCarousel.qml|duration: Theme.carousel.duration|duration: Theme.motion.duration.normal|tst_carousel.qml"
  "the cards jump to the current index|layout/CardCarousel.qml|internal.place(index - internal.position)|internal.place(offset)|tst_carousel.qml"
  "the cards jump between whole places|layout/CardCarousel.qml|const t = offset - whole;|const t = 0;|tst_carousel.qml"
  "the scrim does not fill its parent|foundation/Scrim.qml|anchors.fill: parent|anchors.centerIn: parent|tst_scrim.qml"
  "the scrim draws another colour|foundation/Scrim.qml|color: Theme.color.scrim|color: Theme.color.background|tst_scrim.qml"
  "a click on the scrim is not reported|foundation/Scrim.qml|onClicked: root.clicked()|onClicked: {}|tst_scrim.qml"
  "hover over the scrim reaches the control under it|foundation/Scrim.qml|hoverEnabled: true|hoverEnabled: false|tst_scrim.qml"
  "the wheel over the scrim scrolls the area under it|foundation/Scrim.qml|onWheel: wheel => { wheel.accepted = true; }|onWheel: wheel => { wheel.accepted = false; }|tst_scrim.qml"
  "a destroyed overlay keeps its count|overlay/Popover.qml|Component.onDestruction: share(false)|Component.onDestruction: {}|tst_overlays.qml"
  "the menu keys reach a disabled entry|overlay/Menu.qml|function reachable(item) { return item.enabled && item.visible; }|function reachable(item) { return true; }|tst_overlays.qml"
  "the menu triggers a disabled entry|overlay/Menu.qml|if (currentIndex >= 0 && currentIndex < all.length && reachable(all[currentIndex])) all[currentIndex].triggered();|if (currentIndex >= 0 && currentIndex < all.length) all[currentIndex].triggered();|tst_overlays.qml"
  "the menu starts upward at the penultimate entry|overlay/Menu.qml|currentIndex = step > 0 ? reach[0] : reach[reach.length - 1]; return;|currentIndex = reach[(step + reach.length) % reach.length]; return;|tst_overlays.qml"
  "a shown tooltip stays under a new overlay|overlay/Tooltip.qml|function onOpenChanged() { if (OverlayState.open > 0) window.visible = false; }|function onOpenChanged() {}|tst_overlays.qml"
  "enter leaves the select closed|controls/Select.qml|Keys.onReturnPressed: openList()|Keys.onReturnPressed: {}|tst_overlays.qml"
  "the list row prefers no width of its own|layout/ListItem.qml|Math.max(title.implicitWidth, secondaryLabel.implicitWidth)|0|tst_layout.qml"
  "the list row's secondary line keeps paragraph leading|layout/ListItem.qml|role: \"itemHint\"|role: \"hint\"|tst_layout.qml"
  "a two-line list row stands at the one-line height|layout/ListItem.qml|secondary !== \"\" ? Theme.listItem.twoLineHeight : Theme.listItem.height|Theme.listItem.height|tst_layout.qml"
  "the list row's title keeps paragraph leading|layout/ListItem.qml|role: \"item\"|role: \"body\"|tst_layout.qml"
  "the icon button's icon sits at the top|controls/IconButton.qml|topPadding: leftPadding|topPadding: 0|tst_button.qml"
  "the button ignores hover|controls/Button.qml|hovered ? tokens.hover :|false ? tokens.hover :|tst_button.qml"
  "the button ignores press|controls/Button.qml|down ? tokens.pressed :|false ? tokens.pressed :|tst_button.qml"
  "the button ignores checked|controls/Button.qml|checked ? Theme.button.checked.background :|false ? Theme.button.checked.background :|tst_button.qml"
  "the button's text does not follow its fill|../Commons/Tokens.js|foreground: color(\"contrast({\" + path + \".background})\")|foreground: color(\"{color.text}\")|tst_button.qml"
  "the disabled button does not fade|controls/Button.qml|opacity: enabled ? 1 : Theme.opacity.disabled|opacity: 1|tst_button.qml"
  "the focus ring ignores focus|foundation/FocusRing.qml|visible: target.visualFocus === undefined ? target.activeFocus : target.visualFocus|visible: false|tst_button.qml"
  "the icon button is not square|controls/IconButton.qml|implicitWidth: controlHeight|implicitWidth: controlHeight * 2|tst_button.qml"
  "the switch knob does not slide|controls/Switch.qml|x: inset + root.visualPosition * (parent.width - width - 2 * inset)|x: inset|tst_toggles.qml"
  "the toggle width counts the gap twice|controls/Checkbox.qml|implicitWidth: text !== \"\" ? implicitContentWidth : implicitIndicatorWidth|implicitWidth: implicitIndicatorWidth + spacing + implicitContentWidth|tst_toggles.qml"
  "a clicked segment leaves the keys elsewhere|controls/SegmentedControl.qml|onClicked: { root.forceActiveFocus(); root.choose(index); }|onClicked: root.choose(index)|tst_segmented.qml"
  "the switch track ignores checked|controls/Switch.qml|color: root.checked ? Theme.toggle.on : Theme.toggle.off|color: Theme.toggle.off|tst_toggles.qml"
  "the checkbox mark ignores checked|controls/Checkbox.qml|visible: root.checked|visible: false|tst_toggles.qml"
  "the radio dot ignores checked|controls/Radio.qml|visible: root.checked|visible: true|tst_toggles.qml"
  "the slider fill ignores the value|controls/Slider.qml|width: root.position * parent.width|width: parent.width|tst_slider.qml"
  "the mirrored slider fills from the left|controls/Slider.qml|x: root.mirrored ? parent.width - width : 0|x: 0|tst_slider.qml"
  "the segments take the tab focus|controls/SegmentedControl.qml|focusPolicy: Qt.NoFocus|focusPolicy: Qt.StrongFocus|tst_segmented.qml"
  "the slider handle ignores the value|controls/Slider.qml|x: root.leftPadding + root.visualPosition * (root.availableWidth - width)|x: root.leftPadding|tst_slider.qml"
  "the text field's outline ignores error|controls/TextField.qml|error ? Theme.textField.error :|false ? Theme.textField.error :|tst_textfield.qml"
  "the text field's placeholder never hides|controls/TextField.qml|visible: root.text === \"\" && root.preeditText === \"\"|visible: true|tst_textfield.qml"
  "the leading icon reserves no space|controls/TextField.qml|leftPadding: Theme.textField.paddingX + (leadingIcon !== \"\" ? Theme.icon.size.sm + Theme.textField.gap : 0)|leftPadding: Theme.textField.paddingX|tst_textfield.qml"
  "the field shows the hint over the error|controls/Field.qml|text: root.error !== \"\" ? root.error : root.hint|text: root.hint|tst_textfield.qml"
  "the inline field ignores the label width|controls/Field.qml|width: parent.width - (root.inline ? Theme.field.labelWidth + parent.spacing : 0)|width: parent.width|tst_textfield.qml"
  "the segmented control ignores a click|controls/SegmentedControl.qml|onClicked: { root.forceActiveFocus(); root.choose(index); }|onClicked: {}|tst_segmented.qml"
  "the segmented control fires for the same segment|controls/SegmentedControl.qml|index === currentIndex) return;|false) return;|tst_segmented.qml"
  "the spinner turns under reduced motion|feedback/Spinner.qml|running: root.running && Theme.spinner.duration > 0|running: root.running|tst_feedback.qml"
  "the progress fill ignores the value|feedback/ProgressBar.qml|width: root.indeterminate ? span : root.position * parent.width|width: parent.width|tst_feedback.qml"
  "the mirrored progress fills from the left|feedback/ProgressBar.qml|x: root.mirrored && !root.indeterminate ? parent.width - width : 0|x: 0|tst_feedback.qml"
  "the key cap draws the code role|feedback/Kbd.qml|role: \"kbd\"|role: \"code\"|tst_feedback.qml"
  "the code line copies nothing|feedback/CodeLine.qml|clipboard.copy();|clipboard.deselect();|tst_codeline.qml"
  "the code line signals no copy|feedback/CodeLine.qml|root.copied();|root.confirming;|tst_codeline.qml"
  "the code line confirms no copy|feedback/CodeLine.qml|iconName: root.confirming ? \"check\" : \"copy\"|iconName: \"copy\"|tst_codeline.qml"
  "the code line keeps the check mark|feedback/CodeLine.qml|interval: Theme.codeLine.confirm|interval: 60000|tst_codeline.qml"
  "the code line does not wrap|feedback/CodeLine.qml|wrapMode: Text.WrapAnywhere|wrapMode: Text.NoWrap|tst_codeline.qml"
  "the code line's text runs under its button|feedback/CodeLine.qml|width: Math.max(0, button.x - Theme.codeLine.gap - x)|width: root.width - x|tst_codeline.qml"
  "the code line ignores its fill token|feedback/CodeLine.qml|color: Theme.codeLine.background|color: Theme.codeLine.borderColor|tst_codeline.qml"
  "the badge ignores its tone|feedback/Badge.qml|const found = Theme.badge.tone[name];|const found = undefined;|tst_feedback.qml"
  "the tab does not check on click|layout/Tabs.qml|visible: tab.checked|visible: true|tst_layout.qml"
  "the list item ignores highlight|layout/ListItem.qml|root.highlighted ? Theme.listItem.selected :|false ? Theme.listItem.selected :|tst_layout.qml"
  "the surface ignores its level|foundation/Surface.qml|const found = Theme.surface.level[name];|const found = undefined;|tst_layout.qml"
  "the scroll area's content does not follow its children|layout/ScrollArea.qml|contentHeight: contentItem.childrenRect.height|contentHeight: height|tst_layout.qml"
  "the segmented control stands at its own height|controls/SegmentedControl.qml|implicitHeight: Theme.segmented.height|implicitHeight: Theme.size.control.lg|tst_spacing.qml"
  "the segments pad off the control rhythm|controls/SegmentedControl.qml|leftPadding: Theme.segmented.paddingX|leftPadding: Theme.space.md|tst_spacing.qml"
  "the button pads off the control rhythm|controls/Button.qml|leftPadding: Theme.button.paddingX|leftPadding: Theme.space.md|tst_spacing.qml"
  "the select pads off the control rhythm|controls/Select.qml|leftPadding: Theme.textField.paddingX|leftPadding: Theme.space.sm|tst_spacing.qml"
  "the text field pads off the control rhythm|controls/TextField.qml|leftPadding: Theme.textField.paddingX + (|leftPadding: Theme.space.sm + (|tst_spacing.qml"
  "the list item pads off the row rhythm|layout/ListItem.qml|leftPadding: Theme.listItem.paddingX|leftPadding: Theme.space.sm|tst_spacing.qml"
  "the menu item pads off the row rhythm|overlay/MenuItem.qml|leftPadding: Theme.menu.item.paddingX|leftPadding: Theme.space.sm|tst_spacing.qml"
  "the field draws its label on the column's edge|controls/Field.qml|leftPadding: Theme.field.paddingX|leftPadding: 0|tst_spacing.qml"
  "the button's icon gap is its own step|controls/Button.qml|spacing: Theme.button.gap|spacing: Theme.space.xs|tst_spacing.qml"
  "the menu item's icon gap is its own step|overlay/MenuItem.qml|spacing: Theme.menu.item.gap|spacing: Theme.space.sm|tst_spacing.qml"
  "the badge's icon gap is its own step|feedback/Badge.qml|spacing: Theme.badge.gap|spacing: Theme.space.xxs|tst_spacing.qml"
  "the toast's icon gap is its own step|feedback/Toast.qml|spacing: Theme.toast.contentGap|spacing: Theme.space.sm|tst_spacing.qml"
  "the inline label stands the stacking gap from its control|controls/Field.qml|spacing: Theme.field.labelGap|spacing: Theme.field.gap|tst_textfield.qml"
  "a padded section header's lines overflow it|layout/SectionHeader.qml|readonly property real bodyWidth: width - leftPadding - rightPadding|readonly property real bodyWidth: width|tst_layout.qml"
  "a click on the disclosure's row toggles nothing|layout/Disclosure.qml|if (root.expandable) root.expanded = !root.expanded|if (root.expandable) {}|tst_disclosure.qml"
  "a disclosure that cannot expand toggles on a click|layout/Disclosure.qml|onClicked: if (root.expandable) |onClicked: if (true) |tst_disclosure.qml"
  "the disclosure shows its content while collapsed|layout/Disclosure.qml|visible: root.expandable && root.expanded|visible: root.expandable|tst_disclosure.qml"
  "the disclosure's chevron ignores the state|layout/Disclosure.qml|name: root.expanded ? \"chevron-up\" : \"chevron-down\"|name: \"chevron-down\"|tst_disclosure.qml"
  "a theme change does not reach a group|../Commons/Theme.qml|readonly property var color: published.color|readonly property var color: convert(source.defaults.values, []).color|tst_theme.qml"
  "an appearance reads the whole theme|../Commons/Theme.qml|return convertTree(table, accepted.values, accepted.values, []);|return convertTree(table, Object.assign({}, accepted.values, { card: Object.assign({}, accepted.values.card, { fill: source.values.color.surface }) }), accepted.values, []);|tst_appearance.qml"
  "a read a change overtook is reported|../Commons/WatchedFile.qml|if (operation === \"stale\") {|if (false) {|tst_watched_file.qml"
  "a change during a read is not marked stale|../Commons/WatchedFile.qml|onFileChanged: file.inRead ? file.read() : file.changed()|onFileChanged: file.changed()|tst_watched_file.qml"
  "a change during a write is lost|../Commons/WatchedFile.qml|onFileChanged: file.inRead ? file.read() : file.changed()|onFileChanged: file.busy ? file.read() : file.changed()|tst_watched_file.qml"
  "a read asked during a read starts nothing more|../Commons/WatchedFile.qml|            operation = \"stale\";|            return;|tst_watched_file.qml"
  "the reading view watches the file|../Commons/WatchedFile.qml|        id: view|        id: view; watchChanges: true|tst_watched_file.qml"
  "the watching view reads the file|../Commons/WatchedFile.qml|        preload: false|        preload: true|tst_watched_file.qml"
  "a read asked from a result handler is lost|../Commons/WatchedFile.qml|Qt.callLater(reloadView);|reloadView();|tst_watched_file.qml"
  "a write asked from a result handler is lost|../Commons/WatchedFile.qml|Qt.callLater(() => view.setText(content));|view.setText(content);|tst_watched_file.qml"
  "an appearance never applies its light overrides|../Commons/Theme.qml|ThemeLogic.acceptAppearance(table, light, source.values)|ThemeLogic.acceptAppearance(table, light, Object.assign({}, source.values, { scheme: { mode: \"dark\" } }))|tst_appearance.qml"
  "a TUI wait result never reaches the records|../Core/TuiRecords.qml|if (outcome.record !== null) {|if (false) {|tst_tui_records.qml"
  "a later run's wait record replaces an earlier run's of the key|../Core/TuiRecords.qml|waitRecords.filter(record => record.run !== outcome.record.run)|waitRecords.filter(record => record.key !== outcome.record.key)|tst_tui_records.qml"
)

copy="$tmp/ui"
fresh "$copy"
if out="$("$runner" --ui "$copy" 2>&1)"; then ok "the unmutated copy passes"; else fail "the unmutated copy fails"; printf '%s\n' "$out" | tail -n 20; fi

for row in "${mutations[@]}"; do
  IFS='|' read -r label file needle replacement test <<<"$row"
  # A `|` inside a field shifts the rest, and a runner handed a test that is
  # not there fails, which would read as a red mutation.
  if [[ ! -f $repo/scripts/qml-tests/$test ]]; then fail "$label: the row's test is not a file: $test"; continue; fi
  fresh "$copy"
  target="$copy/$file"
  commons_args=()
  core_args=()
  if [[ $file == ../Commons/* ]]; then
    rm -rf -- "$tmp/commons"
    cp -R -- "$repo/shell/Commons" "$tmp/commons"
    target="$tmp/commons/${file#../Commons/}"
    commons_args=(--commons "$tmp/commons")
  fi
  if [[ $file == ../Core/* ]]; then
    rm -rf -- "$tmp/core"
    cp -R -- "$repo/shell/Core" "$tmp/core"
    target="$tmp/core/${file#../Core/}"
    core_args=(--core "$tmp/core")
  fi
  count="$(python3 - "$target" "$needle" <<'PY'
import sys
print(open(sys.argv[1], encoding="utf-8").read().count(sys.argv[2]))
PY
)"
  if [[ $count -ne 1 ]]; then fail "$label: the text to replace occurs $count times in $file"; continue; fi
  python3 - "$target" "$needle" "$replacement" <<'PY'
import sys
path, needle, replacement = sys.argv[1:]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace(needle, replacement))
PY
  if out="$("$runner" --ui "$copy" "${commons_args[@]}" "${core_args[@]}" "$repo/scripts/qml-tests/$test" 2>&1)"; then
    fail "$label: $test passed on the mutated copy"
  else
    ok "$label"
  fi
done

if out="$(QML_UNIT_RUNNER=/nonexistent/qmltestrunner "$runner" --ui "$copy" 2>&1)"; then
  fail "a missing runner passed"
elif [[ $out == "qml-unit: status=not-measured missing=qmltestrunner" ]]; then
  ok "a missing runner is not a pass"
else
  fail "a missing runner: got $out"
fi
if out="$("$runner" --nope 2>&1)"; then fail "an unknown argument passed"; elif [[ $out == "qml-unit: refused: argument=--nope" ]]; then ok "an unknown argument is refused"; else fail "an unknown argument: got $out"; fi

# Rows: label | name of the planted tst_<name>.qml | the runner's exit |
# the line it must print | the file's lines after the planted head, whose
# body starts at line 6; printf %b expands the \n.
planted_head='import QtQuick\nimport QtTest\nTestCase {\n    id: planted\n    name: "planted"\n'
logs=(
  "an unexpected console.error fails|error|1|qml-unit: unexpected-log file=tst_error.qml line=QCRITICAL: qmltestrunner::planted::test_a() critical: qml: planted log|    function test_a() { console.error(\"planted log\"); }\n"
  "an unexpected console.warn fails|warn|1|qml-unit: unexpected-log file=tst_warn.qml line=QWARN  : qmltestrunner::planted::test_a() warning: qml: planted log|    function test_a() { console.warn(\"planted log\"); }\n"
  "a declared log passes|declared|0|qml-unit: ok files=1|    // expected-log: planted log -- the row plants it\n    function test_a() { console.error(\"planted log\"); }\n"
  "a declaration that matches nothing fails|stale|1|qml-unit: expected-log unmatched file=tst_stale.qml line=6 message=planted log|    // expected-log: planted log -- the row plants it\n    function test_a() { verify(true); }\n"
  "a declaration covers no other function|other|1|qml-unit: unexpected-log file=tst_other.qml line=QCRITICAL: qmltestrunner::planted::test_b() critical: qml: planted log|    // expected-log: planted log -- the row plants it\n    function test_a() { console.error(\"planted log\"); }\n    function test_b() { console.error(\"planted log\"); }\n"
  "a declaration with no reason is refused|noreason|2|qml-unit: refused: expected-log=no-reason file=tst_noreason.qml line=6|    // expected-log: planted log\n    function test_a() { console.error(\"planted log\"); }\n"
  "a declaration with no function under it is refused|nofunction|2|qml-unit: refused: expected-log=no-function file=tst_nofunction.qml line=6|    // expected-log: planted log -- the row plants it\n    property int n: 0\n    function test_a() { console.error(\"planted log\"); }\n"
  "a log at load fails|load|1|qml-unit: unexpected-log file=tst_load.qml line=critical: qml: planted log|    Component.onCompleted: console.error(\"planted log\")\n    function test_a() { verify(true); }\n"
  "a declaration does not excuse a script error|script|1|qml-unit: warnings file=tst_script.qml|    // expected-log: ReferenceError -- the row plants it\n    function test_a() { Qt.createQmlObject(\"import QtQuick; Item { property int n: noSuchName.x }\", planted); }\n"
)
mkdir -p "$tmp/logs"
for row in "${logs[@]}"; do
  IFS='|' read -r label name want_status want_line body <<<"$row"
  printf '%b%b}\n' "$planted_head" "$body" >"$tmp/logs/tst_$name.qml"
  got_status=0
  out="$("$runner" --tests "$repo/scripts/qml-tests" "$tmp/logs/tst_$name.qml" 2>&1)" || got_status=$?
  if [[ $got_status -ne $want_status ]]; then
    fail "$label: exit $got_status, want $want_status"
    printf '%s\n' "$out" | tail -n 20
  elif ! grep -qFx -- "$want_line" <<<"$out"; then
    fail "$label: no line: $want_line"
    printf '%s\n' "$out" | tail -n 20
  else
    ok "$label"
  fi
done

if [[ $failures -eq 0 ]]; then
  echo "test-qml-unit: ok mutations=${#mutations[@]} logs=${#logs[@]}"
  exit 0
fi
echo "test-qml-unit: failed=$failures"
exit 1
