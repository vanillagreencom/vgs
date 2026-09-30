import QtQml

// Type stand-in only. Core registrations create objects without reaching
// the compositor; key read tests emit no press.
QtObject {
    property string appid: ""
    property string name: ""
    property string description: ""
    signal pressed()
}
