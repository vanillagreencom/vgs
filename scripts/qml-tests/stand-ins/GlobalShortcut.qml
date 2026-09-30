import QtQml

// Type stand-in only. Core registrations create objects without reaching
// the compositor; the registry tests deliver native edges by hand.
QtObject {
    property string appid: ""
    property string name: ""
    property string description: ""
    signal pressed()
    signal released()
}
