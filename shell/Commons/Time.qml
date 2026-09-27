pragma Singleton
import QtQuick
import Quickshell

// The one wall clock every surface reads. It ticks once a minute, and once
// a second only while some item that shows seconds holds it, so an idle
// desktop does no work it does not display and a clock on every screen
// costs one timer.
Singleton {
    id: root

    // Items that show seconds, held by identity: a repeated claim or
    // release from the same item changes nothing.
    property var secondsHolders: []
    readonly property bool ticksSeconds: secondsHolders.length > 0
    readonly property date now: clock.date

    // Claim or release second precision for `holder`. A holder releases on
    // its own destruction; a holder that never does keeps seconds ticking.
    function holdSeconds(holder, wanted) {
        const held = secondsHolders.indexOf(holder) !== -1;
        if (wanted && !held) secondsHolders = secondsHolders.concat([holder]);
        else if (!wanted && held) secondsHolders = secondsHolders.filter(h => h !== holder);
    }

    SystemClock {
        id: clock
        precision: root.ticksSeconds ? SystemClock.Seconds : SystemClock.Minutes
    }
}
