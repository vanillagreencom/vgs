#!/usr/bin/env bash
# Controls for scripts/qml-unit.sh and the unit tests under
# scripts/qml-tests/: a table of mutations, one per guarantee a test pins,
# each applied to a copy of shell/Ui with its match counted, and the runner
# is required to fail on every copy and to pass on the unmutated copy. Two
# rows pin the runner itself: a missing qmltestrunner is not a pass, and an
# unknown argument is refused.
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
  "the menu stays open after a trigger|overlay/Menu.qml|function onTriggered() { root.close(); }|function onTriggered() {}|tst_overlays.qml"
  "the menu keys move no highlight|overlay/Menu.qml|item.highlighted = index === currentIndex;|item.highlighted = false;|tst_overlays.qml"
  "the menu window stays at the minimum width|overlay/Menu.qml|implicitWidth: Math.max(Theme.menu.minWidth, root.widest + 2 * Theme.menu.padding)|implicitWidth: Theme.menu.minWidth|tst_overlays.qml"
  "the select accepts an index past its end|controls/Select.qml|index >= count) return;|index >= count + 100) return;|tst_overlays.qml"
  "the select ignores its text role|controls/Select.qml|return String(entry[textRole]);|return String(entry);|tst_overlays.qml"
  "the select breaks its index binding on the current choice|controls/Select.qml|if (index !== currentIndex) currentIndex = index;|currentIndex = index;|tst_overlays.qml"
  "the toast ignores its tone|feedback/Toast.qml|const found = Theme.badge.tone[name];|const found = undefined;|tst_overlays.qml"
  "a destroyed overlay keeps its count|overlay/Popover.qml|Component.onDestruction: share(false)|Component.onDestruction: {}|tst_overlays.qml"
  "the menu keys reach a disabled entry|overlay/Menu.qml|function reachable(item) { return item.enabled && item.visible; }|function reachable(item) { return true; }|tst_overlays.qml"
  "the menu triggers a disabled entry|overlay/Menu.qml|if (currentIndex >= 0 && currentIndex < all.length && reachable(all[currentIndex])) all[currentIndex].triggered();|if (currentIndex >= 0 && currentIndex < all.length) all[currentIndex].triggered();|tst_overlays.qml"
  "the menu starts upward at the penultimate entry|overlay/Menu.qml|currentIndex = step > 0 ? reach[0] : reach[reach.length - 1]; return;|currentIndex = reach[(step + reach.length) % reach.length]; return;|tst_overlays.qml"
  "a shown tooltip stays under a new overlay|overlay/Tooltip.qml|function onOpenChanged() { if (OverlayState.open > 0) window.visible = false; }|function onOpenChanged() {}|tst_overlays.qml"
  "enter leaves the select closed|controls/Select.qml|Keys.onReturnPressed: openList()|Keys.onReturnPressed: {}|tst_overlays.qml"
  "the list row prefers no width of its own|layout/ListItem.qml|Math.max(title.implicitWidth, secondaryLabel.implicitWidth)|0|tst_layout.qml"
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
  "a theme change does not reach a group|../Commons/Theme.qml|readonly property var color: published.color|readonly property var color: convert(source.defaults.values, []).color|tst_theme.qml"
  "an appearance reads the whole theme|../Commons/Theme.qml|return convertTree(table, accepted.values, accepted.values, []);|return convertTree(table, Object.assign({}, accepted.values, { card: Object.assign({}, accepted.values.card, { fill: source.values.color.surface }) }), accepted.values, []);|tst_appearance.qml"
  "a read a change overtook is reported|../Commons/WatchedFile.qml|if (operation === \"stale\") {|if (false) {|tst_watched_file.qml"
  "a change during a read is not marked stale|../Commons/WatchedFile.qml|if (file.operation === \"reading\" || file.operation === \"stale\") file.operation = \"stale\";|if (false) file.operation = \"stale\";|tst_watched_file.qml"
  "a change during a write is lost|../Commons/WatchedFile.qml|if (file.operation === \"reading\" || file.operation === \"stale\") file.operation = \"stale\";|if (file.operation !== \"idle\") file.operation = \"stale\";|tst_watched_file.qml"
  "a read asked during a read starts nothing more|../Commons/WatchedFile.qml|            operation = \"stale\";|            return;|tst_watched_file.qml"
  "the reading view watches the file|../Commons/WatchedFile.qml|        id: view|        id: view; watchChanges: true|tst_watched_file.qml"
  "the watching view reads the file|../Commons/WatchedFile.qml|        preload: false|        preload: true|tst_watched_file.qml"
  "a read asked from a result handler is lost|../Commons/WatchedFile.qml|Qt.callLater(reloadView);|reloadView();|tst_watched_file.qml"
  "a write asked from a result handler is lost|../Commons/WatchedFile.qml|Qt.callLater(() => view.setText(content));|view.setText(content);|tst_watched_file.qml"
  "an appearance never applies its light overrides|../Commons/Theme.qml|ThemeLogic.acceptAppearance(table, light, source.values)|ThemeLogic.acceptAppearance(table, light, Object.assign({}, source.values, { scheme: { mode: \"dark\" } }))|tst_appearance.qml"
)

copy="$tmp/ui"
fresh "$copy"
if out="$("$runner" --ui "$copy" 2>&1)"; then ok "the unmutated copy passes"; else fail "the unmutated copy fails"; printf '%s\n' "$out" | tail -n 20; fi

for row in "${mutations[@]}"; do
  IFS='|' read -r label file needle replacement test <<<"$row"
  fresh "$copy"
  target="$copy/$file"
  commons_args=()
  if [[ $file == ../Commons/* ]]; then
    rm -rf -- "$tmp/commons"
    cp -R -- "$repo/shell/Commons" "$tmp/commons"
    target="$tmp/commons/${file#../Commons/}"
    commons_args=(--commons "$tmp/commons")
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
  if out="$("$runner" --ui "$copy" "${commons_args[@]}" "$repo/scripts/qml-tests/$test" 2>&1)"; then
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

if [[ $failures -eq 0 ]]; then
  echo "test-qml-unit: ok mutations=${#mutations[@]}"
  exit 0
fi
echo "test-qml-unit: failed=$failures"
exit 1
