import QtQuick
import qs.Ui

// A button that stays pressed: a tertiary button with `checkable` on, so
// a click toggles `checked` and the checked fill of the theme draws.
Button {
    checkable: true
    variant: "tertiary"
}
