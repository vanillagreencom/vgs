import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit
import "../../shell/plugins/vgs.settings"

// GroupList: the groups it holds sit `groupList.gap` apart with one
// hairline in `groupList.divider` centred in each gap, a hidden group takes
// neither, a group list inside another divides its own groups alike, and a
// theme moves both. The groups are the Settings page's own Status lines
// and Requirements rows, so the page's rhythm is read where it is drawn:
// a line's own lines, its value, its hint and its command, sit `field.gap`
// apart, less than the gap between groups.
Item {
    id: root
    width: 480
    height: 900

    GroupList {
        id: list
        width: 400
        StatusLine { id: warden; width: list.width; label: "Warden"; tone: "success"; text: "Checking"; hint: "Keeps AI agents within their memory and task limits"; command: "systemctl --user start agent-warden.timer" }
        StatusLine { id: agents; width: list.width; label: "Agents running"; text: "3" }
        StatusLine { id: hidden; width: list.width; label: "Hidden"; text: "gone"; visible: false }
        RequirementRow { id: vsys; width: list.width; requirement: ({ command: "vsys", state: "present", optional: false, purpose: "The agent dashboard that ships the warden" }) }
    }

    GroupList {
        id: outer
        y: 520
        width: 400
        StatusLine { id: single; width: outer.width; label: "Scheduler"; text: "systemd" }
        GroupList {
            id: inner
            width: outer.width
            StatusLine { id: tokens; width: inner.width; label: "Slack tokens"; hint: "One token per workspace" }
            StatusLine { id: acme; width: inner.width; label: "Acme"; tone: "success"; text: "Present" }
        }
    }

    TestCase {
        name: "grouplist"
        when: windowShown

        function init() { UnitTheme.reset(); hidden.visible = false; }

        function hairlinesOf(owner) {
            return owner.children.filter(child => child.vertical !== undefined && child.visible);
        }

        function shownGroups(owner) {
            const column = owner.children.find(child => child.spacing !== undefined);
            return column.children.filter(child => child.visible && child.width > 0 && child.height > 0);
        }

        // What breaks the rule that each gap between two shown groups is
        // `groupList.gap`, with one hairline centred in it, in its own
        // colour, across the list; [] when it holds. A positioner lays out
        // a turn after a change, so a check waits for it.
        function dividedProblems(owner) {
            const groups = shownGroups(owner);
            const lines = hairlinesOf(owner);
            const out = [];
            if (lines.length !== groups.length - 1) return ["hairlines=" + lines.length + " groups=" + groups.length];
            for (let i = 1; i < groups.length; i++) {
                const top = groups[i - 1].y + groups[i - 1].height;
                const line = lines[i - 1];
                if (groups[i].y - top !== Theme.groupList.gap) out.push("gap" + i + "=" + (groups[i].y - top));
                if (line.height !== Theme.divider.thickness || line.width !== owner.width) out.push("hairline" + i + ".size=" + line.width + "x" + line.height);
                if (Math.abs(line.y + line.height / 2 - (top + groups[i].y) / 2) > 0.5) out.push("hairline" + i + ".y=" + line.y + " between " + top + " and " + groups[i].y);
                if (String(line.color) !== String(Qt.color(Theme.groupList.divider))) out.push("hairline" + i + ".color=" + line.color);
            }
            return out;
        }
        function checkDivided(owner) {
            tryVerify(() => dividedProblems(owner).length === 0, 1000, "the groups are divided: " + JSON.stringify(dividedProblems(owner)));
        }

        function test_groups_are_divided() {
            compare(shownGroups(list).length, 3);
            checkDivided(list);
            verify(Theme.groupList.gap > Theme.field.gap, "groups sit farther apart than the lines of one");
        }

        // A hidden group takes no gap and no hairline, and one shown again
        // takes both.
        function test_a_hidden_group_takes_no_hairline() {
            checkDivided(list);
            compare(hairlinesOf(list).length, 2);
            hidden.visible = true;
            checkDivided(list);
            compare(hairlinesOf(list).length, 3);
        }

        function test_a_nested_list_divides_its_own_groups() {
            checkDivided(outer);
            checkDivided(inner);
            compare(hairlinesOf(outer).length, 1);
            compare(hairlinesOf(inner).length, 1);
        }

        function test_a_theme_moves_the_gap_and_the_hairline() {
            compare(UnitTheme.override({ groupList: { gap: 20, divider: "#ff000080" } }), "ok");
            compare(Theme.groupList.gap, 20);
            checkDivided(list);
            compare(String(hairlinesOf(list)[0].color), String(Qt.color("#80ff0000")));
        }

        // The lines of one group sit `field.gap` apart: the key/value row,
        // its hint, and its command's disclosure.
        function test_a_groups_own_lines_sit_close() {
            const field = warden.children.find(child => child.valueX !== undefined);
            const disclosure = warden.children.find(child => child.command !== undefined && child.toggle !== undefined);
            verify(field !== undefined && disclosure !== undefined, "the line holds its field and its disclosure");
            compare(disclosure.visible, true);
            compare(disclosure.y - (field.y + field.height), Theme.field.gap);
            compare(warden.spacing, Theme.field.gap);
            const row = field.children.find(child => child.spacing === Theme.field.labelGap);
            const hint = field.children.find(child => child.height > 0 && child.children.length === 1 && child.children[0].role === "hint");
            verify(row !== undefined && hint !== undefined, "the field holds its row and its hint");
            compare(hint.y - (row.y + row.height), Theme.field.gap);
        }
    }
}
