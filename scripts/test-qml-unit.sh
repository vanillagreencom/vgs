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
# behaviour and removes the behaviour.
mutations=(
  "the label's role is not read|foundation/Label.qml|const found = Theme.text[name];|const found = undefined;|tst_label.qml"
  "the label's weight does not reach the axis|foundation/Label.qml|font.variableAxes: ({ wght: typography.weight })|font.variableAxes: ({ wght: 400 })|tst_label.qml"
  "the label's letter spacing is not scaled|foundation/Label.qml|font.letterSpacing: typography.letterSpacing * typography.size|font.letterSpacing: typography.letterSpacing|tst_label.qml"
  "the icon's stroke scales with its size|foundation/Icon.qml|strokeWidth: root.stroke / root.factor|strokeWidth: root.stroke|tst_icon.qml"
  "the icon's path is not scaled|foundation/Icon.qml|transform: Scale { xScale: root.factor; yScale: root.factor }|transform: Scale { xScale: 1; yScale: 1 }|tst_icon.qml"
  "the icon keeps an unknown name's paths|foundation/Icon.qml|return [\"\", \"\"];|return Lucide.ICONS.circle;|tst_icon.qml"
  "the button ignores hover|controls/Button.qml|hovered ? tokens.hover :|false ? tokens.hover :|tst_button.qml"
  "the button ignores press|controls/Button.qml|down ? tokens.pressed :|false ? tokens.pressed :|tst_button.qml"
  "the button ignores checked|controls/Button.qml|checked ? Theme.button.checked.background :|false ? Theme.button.checked.background :|tst_button.qml"
  "the button's text does not follow its fill|../Commons/Tokens.js|foreground: color(\"contrast({\" + path + \".background})\")|foreground: color(\"{color.text}\")|tst_button.qml"
  "the disabled button does not fade|controls/Button.qml|opacity: enabled ? 1 : Theme.opacity.disabled|opacity: 1|tst_button.qml"
  "the focus ring ignores focus|foundation/FocusRing.qml|visible: target.visualFocus|visible: false|tst_button.qml"
  "the icon button is not square|controls/IconButton.qml|implicitWidth: controlHeight|implicitWidth: controlHeight * 2|tst_button.qml"
  "the switch knob does not slide|controls/Switch.qml|x: root.checked ? parent.width - width - inset : inset|x: inset|tst_toggles.qml"
  "the switch track ignores checked|controls/Switch.qml|color: root.checked ? Theme.toggle.on : Theme.toggle.off|color: Theme.toggle.off|tst_toggles.qml"
  "the checkbox mark ignores checked|controls/Checkbox.qml|visible: root.checked|visible: false|tst_toggles.qml"
  "the radio dot ignores checked|controls/Radio.qml|visible: root.checked|visible: true|tst_toggles.qml"
  "the slider fill ignores the value|controls/Slider.qml|width: root.visualPosition * parent.width|width: parent.width|tst_slider.qml"
  "the slider handle ignores the value|controls/Slider.qml|x: root.leftPadding + root.visualPosition * (root.availableWidth - width)|x: root.leftPadding|tst_slider.qml"
  "the text field's outline ignores error|controls/TextField.qml|error ? Theme.textField.error :|false ? Theme.textField.error :|tst_textfield.qml"
  "the text field's placeholder never hides|controls/TextField.qml|visible: root.text === \"\" && root.preeditText === \"\"|visible: true|tst_textfield.qml"
  "the leading icon reserves no space|controls/TextField.qml|leftPadding: Theme.textField.paddingX + (leadingIcon !== \"\" ? Theme.icon.size.sm + Theme.textField.gap : 0)|leftPadding: Theme.textField.paddingX|tst_textfield.qml"
  "the field shows the hint over the error|controls/Field.qml|text: root.error !== \"\" ? root.error : root.hint|text: root.hint|tst_textfield.qml"
  "the inline field ignores the label width|controls/Field.qml|width: parent.width - (root.inline ? Theme.field.labelWidth + parent.spacing : 0)|width: parent.width|tst_textfield.qml"
  "the segmented control ignores a click|controls/SegmentedControl.qml|onClicked: root.choose(index)|onClicked: {}|tst_segmented.qml"
  "the segmented control fires for the same segment|controls/SegmentedControl.qml|index === currentIndex) return;|false) return;|tst_segmented.qml"
  "the spinner turns under reduced motion|feedback/Spinner.qml|running: root.running && Theme.spinner.duration > 0|running: root.running|tst_feedback.qml"
  "the progress fill ignores the value|feedback/ProgressBar.qml|width: root.indeterminate ? span : root.visualPosition * parent.width|width: parent.width|tst_feedback.qml"
  "the badge ignores its tone|feedback/Badge.qml|const found = Theme.badge.tone[name];|const found = undefined;|tst_feedback.qml"
  "the tab does not check on click|layout/Tabs.qml|visible: tab.checked|visible: true|tst_layout.qml"
  "the list item ignores highlight|layout/ListItem.qml|root.highlighted ? Theme.listItem.selected :|false ? Theme.listItem.selected :|tst_layout.qml"
  "the surface ignores its level|foundation/Surface.qml|const found = Theme.surface.level[name];|const found = undefined;|tst_layout.qml"
  "the scroll area's content does not follow its children|layout/ScrollArea.qml|contentHeight: contentItem.childrenRect.height|contentHeight: height|tst_layout.qml"
  "a theme change does not reach a group|../Commons/Theme.qml|readonly property var color: published.color|readonly property var color: convert(source.defaults.values, \"\").color|tst_theme.qml"
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
