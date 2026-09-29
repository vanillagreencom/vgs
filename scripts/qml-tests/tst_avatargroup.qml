import QtQuick
import QtTest
import qs.Commons
import qs.Ui
import qs.Unit

// AvatarGroup: one person fills the box with no ring; two, three and four
// sit clockwise from the top left on the diagonal, as a triangle and as a
// 2 by 2 cluster, each `avatarGroup.face` of the box across, ringed, and
// each over the one before; past four, three faces and a chip counting
// the rest take the four places. A face shows its initials on its tint,
// or the tint token when it names none, and its image cut to a circle
// once the image loads.
Item {
    id: root
    width: 400
    height: 300

    // The image a face loads: a 4 by 4 opaque red PNG.
    readonly property string red: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP4z8DwHxkzkC4AADxAH+HggXe0AAAAAElFTkSuQmCC"
    property string photo: ""

    function person(initials, tint) { return { image: "", initials: initials, tint: tint }; }

    AvatarGroup { id: one; y: 20; people: [root.person("AL", "#336699")] }
    AvatarGroup { id: two; x: 60; y: 20; people: [root.person("AL", "#336699"), root.person("GH", "#993366")] }
    AvatarGroup { id: three; x: 120; y: 20; people: [root.person("A", ""), root.person("B", ""), root.person("C", "")] }
    AvatarGroup { id: four; x: 180; y: 20; people: [root.person("A", ""), root.person("B", ""), root.person("C", ""), root.person("D", "")] }
    AvatarGroup { id: seven; x: 240; y: 20; people: [root.person("A", ""), root.person("B", ""), root.person("C", ""), root.person("D", "")]; more: 3 }
    AvatarGroup { id: pictured; y: 100; size: 48; people: [{ image: root.photo, initials: "P", tint: "#000000" }] }

    TestCase {
        name: "avatargroup"
        when: windowShown

        function init() { UnitTheme.reset(); }

        function facesOf(group) { return group.children.filter(c => c.isChip !== undefined).sort((a, b) => a.z - b.z); }
        function placesOf(group) { return facesOf(group).map(f => [f.x, f.y, f.width]); }
        function near(a, b) { return Math.abs(a - b) <= 0.01; }

        function test_one_person_fills_the_box() {
            const size = Theme.avatarGroup.size;
            compare(one.width, size);
            const faces = facesOf(one);
            compare(faces.length, 1);
            compare([faces[0].x, faces[0].y, faces[0].width, faces[0].height], [0, 0, size, size]);
            compare(faces[0].ringWidth, 0, "a lone face has no ring");
            compare(faces[0].initials, "AL");
            verify(Qt.colorEqual(faces[0].tint, "#336699"), "the face takes its tint: " + faces[0].tint);
        }

        function test_clusters_sit_clockwise_from_the_top_left() {
            const size = Theme.avatarGroup.size;
            const face = size * Theme.avatarGroup.face;
            const room = size - face;
            const cases = [
                [two, [[0, 0], [room, room]], "two on the diagonal"],
                [three, [[room / 2, 0], [room, room], [0, room]], "three as a triangle, point up"],
                [four, [[0, 0], [room, 0], [room, room], [0, room]], "four as a 2 by 2 cluster"],
                [seven, [[0, 0], [room, 0], [room, room], [0, room]], "past four, the four places"]
            ];
            for (const [group, want, what] of cases) {
                const got = placesOf(group);
                compare(got.length, want.length, what + ": places");
                for (let i = 0; i < want.length; i++) {
                    verify(near(got[i][0], want[i][0]) && near(got[i][1], want[i][1]), what + ": place " + i + " at " + got[i] + ", want " + want[i]);
                    verify(near(got[i][2], face), what + ": face " + i + " is " + got[i][2] + " across, want " + face);
                    verify(got[i][0] >= 0 && got[i][1] >= 0 && got[i][0] + got[i][2] <= size + 0.01 && got[i][1] + got[i][2] <= size + 0.01, what + ": face " + i + " inside the box");
                }
                for (const f of facesOf(group)) compare(f.ringWidth, Theme.avatarGroup.ringWidth, what + ": ringed");
            }
        }

        function test_each_face_lies_over_the_one_before() {
            const faces = four.children.filter(c => c.isChip !== undefined).sort((a, b) => a.index - b.index);
            for (let i = 1; i < faces.length; i++) verify(faces[i].z > faces[i - 1].z, "face " + i + " over face " + (i - 1));
        }

        function test_past_four_a_chip_counts_the_rest() {
            const faces = facesOf(seven);
            compare(faces.map(f => f.isChip), [false, false, false, true]);
            compare(faces[3].initials, "+4");
            verify(Qt.colorEqual(faces[3].tint, Theme.avatarGroup.chip), "the chip takes its token: " + faces[3].tint);
            compare(facesOf(four).filter(f => f.isChip).length, 0, "four people take no chip");
        }

        function test_a_face_without_a_tint_takes_the_token() {
            verify(Qt.colorEqual(facesOf(three)[0].tint, Theme.avatarGroup.tint), "the face takes the token: " + facesOf(three)[0].tint);
        }

        // The unit runner draws in software, where no shader effect draws,
        // so the cut is read from the layer that makes it: the image sits
        // in a layer masked by a full-radius shape the face's size. The
        // drawn cut is read in the sandbox, scripts/smoke/rows/notifications.sh.
        function test_an_image_shows_cut_to_a_circle() {
            const face = facesOf(pictured)[0];
            verify(!face.photoShown);
            root.photo = root.red;
            tryVerify(() => face.photoShown, 2000, "the image loaded");
            const initials = face.children.find(c => c.text === "P");
            verify(!initials.visible, "the initials give way to the image");
            const layer = face.children.find(c => c.layer.effect !== null && c.layer.enabled);
            verify(layer !== undefined && layer.visible, "the image's layer shows");
            const effect = layer.layer.effect.createObject(null);
            verify(effect.maskEnabled, "the layer is masked");
            effect.destroy();
            const mask = face.children.find(c => c.radius !== undefined && !c.visible && c.layer.enabled);
            verify(mask !== undefined, "the mask is a hidden layer");
            compare([mask.width, mask.height, mask.radius], [face.width, face.height, Theme.radius.full]);
        }
    }
}
