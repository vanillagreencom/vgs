pragma Singleton
import QtQuick

// The shared loader of the local images `ImageText` draws inline. An entry
// is one asynchronous `Image` per URL and device-pixel size, shared by every
// holder in the shell and destroyed once the last holder releases it; Qt's
// own pixmap cache keeps the decoded image a while after.
//
// The entry is what makes the inline image load off the GUI thread. A
// StyledText `<img>` loads its image synchronously, and first looks for it
// in Qt's pixmap cache under its URL, its request size in device pixels,
// no clip region, frame 0 and default provider options. An asynchronous
// `Image` with those values puts its entry into that cache before its
// reader thread decodes it, so a text that names the image after the entry
// exists waits for that load instead of decoding it itself
// (docs/architecture/runtime-qml.md). An entry's `Image` therefore keeps
// the default fill mode and no clip, and sets `sourceSize` before its
// `source`.
//
// `acquire` answers the entry's `Image`, whose `status` the holder watches;
// every `acquire` is matched by one `release` of the same image.
QtObject {
    id: pool

    // "<device size>@<url>" -> { image, holders }.
    property var entries: ({})

    readonly property Component loader: Component {
        Image {
            property string poolKey: ""
            asynchronous: true
            cache: true
            visible: false
        }
    }

    function keyOf(url, deviceSize) {
        return deviceSize + "@" + url;
    }

    function acquire(url, deviceSize) {
        const key = keyOf(url, deviceSize);
        let entry = entries[key];
        if (entry === undefined) {
            const image = loader.createObject(null, { poolKey: key, sourceSize: Qt.size(deviceSize, deviceSize), source: url });
            if (image === null) {
                console.error("ImagePool: image not created url=" + url);
                return null;
            }
            entry = { image: image, holders: 0 };
            entries[key] = entry;
        }
        entry.holders += 1;
        return entry.image;
    }

    function release(image) {
        const key = image.poolKey;
        const entry = entries[key];
        if (entry === undefined || entry.image !== image) {
            console.error("ImagePool: release of an image the pool does not hold url=" + image.source);
            return;
        }
        entry.holders -= 1;
        if (entry.holders > 0) return;
        delete entries[key];
        image.destroy();
    }
}
