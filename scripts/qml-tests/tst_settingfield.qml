import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit
import "../../shell/plugins/vgs.settings"

Item {
    id: root
    width: 480
    height: 160

    property var applied: []

    SettingField {
        id: field
        width: 420
        pluginId: "vgs.bar"
        key: "clockFormat"
        spec: ({
            type: "string",
            label: "Clock format",
            format: "datetime",
            allowCustom: true,
            presets: [
                { value: "HH:mm" },
                { value: "ddd HH:mm" },
                { value: "yyyy-MM-dd HH:mm" }
            ]
        })
        value: "HH:mm"
        onApply: value => root.applied.push(value)
    }

    TestCase {
        name: "settingfield"
        when: windowShown

        function init() {
            UnitTheme.reset();
            root.applied = [];
            field.value = "HH:mm";
            Time.now = new Date(2026, 8, 30, 20, 34, 0);
        }

        function descendants(item) {
            const found = [item];
            for (let i = 0; i < found.length; i++)
                for (const child of found[i].children || []) found.push(child);
            return found;
        }

        function selectOf(item) {
            return descendants(item).find(child => String(child).indexOf("Select") === 0);
        }

        function selectList(owner) {
            let window = null;
            for (let i = 0; i < owner.resources.length; i++)
                if (owner.resources[i].anchor !== undefined) window = owner.resources[i];
            return window.contentItem.children.find(child => child.currentIndex !== undefined);
        }

        function test_open_datetime_list_keeps_highlight_across_clock_tick() {
            const select = selectOf(field);
            verify(select !== undefined, "the preset Select exists");
            select.openList();
            const list = selectList(select);
            tryVerify(() => list.itemAtIndex(0) !== null, 1000, "the preset list builds entries");
            list.Window.window.requestActivate();
            list.forceActiveFocus();
            tryCompare(list.Window, "active", true);
            tryCompare(list, "activeFocus", true);
            wait(50);
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Down);
            compare(list.currentIndex, 2);
            Time.now = new Date(2026, 8, 30, 20, 35, 0);
            compare(list.currentIndex, 2, "a clock tick does not reset the highlighted preset");
            keyClick(Qt.Key_Return);
            tryCompare(select, "listOpen", false);
            compare(root.applied, ["yyyy-MM-dd HH:mm"]);
        }
    }
}
