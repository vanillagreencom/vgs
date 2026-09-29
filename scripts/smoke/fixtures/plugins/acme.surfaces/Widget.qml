import QtQuick
import qs.Ui
BarWidget {
    id: root
    implicitWidth: 30
    implicitHeight: barSize
    function summonHere() { return shell.surfaces.summon("panel", "{\"from\":\"widget\"}", root); }
    function menuHere(payload) { return shell.surfaces.summon("menu", payload || "{}", root); }
    function windowHere(payload) { return shell.surfaces.summon("window", payload || "{}", root); }
    function geometry() { const p = mapToGlobal(0, 0); return JSON.stringify([p.x, p.y, width, height]); }
}
