pragma Singleton
import QtQuick
import Quickshell
import "PluginLogic.js" as Logic

// Plugin status: the runtime values each plugin publishes through its
// `status` capability, held once per plugin id so every instance of the
// plugin reads the same record, D037. A record lives while the plugin is
// enabled at the source revision that wrote it: disabling the plugin, or a
// rescan that gives it a new revision, drops the record, so a rebuilt
// service publishes again from nothing. PluginLogic.statusWrite judges every
// value; the manifest's `status` key declares what may be written.
Singleton {
    id: root

    // Plugin id -> { revision, serial, values, bytes }: the source revision
    // that wrote the record, the serial of its last write, the published
    // values and their size. `values` never leaves this file: valuesOf
    // hands out copies. Replaced whole on every change,
    // so a binding on a plugin's values re-evaluates once per write.
    property var records: ({})
    // Rises by one on every accepted write, across plugins, so no two
    // writes share a serial and a dropped record's serial never returns.
    property int serial: 0

    readonly property var empty: Object.freeze({})

    // Publish `value` under `key` for the instance `ctx` belongs to. The
    // reply is one keyed line: `ok`, statusWrite's refusal, or
    // `refused: status=<key> reason=retired` from an instance whose plugin is
    // no longer enabled at its revision, which the core is about to
    // destroy, so its write cannot bring back a dropped record.
    function set(ctx, key, value) {
        const revision = ctx.manifest.__revision;
        if (!Registry.isEnabled(ctx.id) || Registry.manifests[ctx.id].__revision !== revision)
            return Logic.statusRefusal(key, "retired");
        // A record another revision wrote is the replaced revision's: a
        // rebuilt instance can write before the registry's change signal
        // prunes it, since the new slot keys rebuild inside the manifest
        // map's assignment.
        const current = Logic.hasOwn(records, ctx.id) && records[ctx.id].revision === revision ? records[ctx.id] : null;
        const result = Logic.statusWrite(ctx.manifest, current === null ? {} : current.values, key, value);
        if (!result.ok) return result.error;
        serial += 1;
        const next = Object.assign({}, records);
        next[ctx.id] = Object.freeze({ revision: revision, serial: serial, values: result.values, bytes: result.bytes });
        records = next;
        return "ok";
    }

    // The values plugin `id` published, or an empty frozen object: a
    // deep-frozen copy made for this read, since the engine lets a frozen
    // array be written in place (runtime-qml.md), so a reader that changes
    // an array changes only its own copy. A binding that calls this
    // re-evaluates on every write.
    function valuesOf(id) {
        return Logic.hasOwn(records, id) ? Logic.frozenJson(records[id].values) : empty;
    }

    // The serial of plugin `id`'s last write, 0 while it has none.
    function revisionOf(id) {
        return Logic.hasOwn(records, id) ? records[id].serial : 0;
    }

    // Drop every record whose plugin is gone, disabled, or at another source
    // revision than the one that wrote it.
    function prune() {
        const kept = {};
        let dropped = false;
        for (const id of Object.keys(records)) {
            if (Registry.isEnabled(id) && Registry.manifests[id].__revision === records[id].revision) kept[id] = records[id];
            else dropped = true;
        }
        if (dropped) records = kept;
    }

    Connections {
        target: Registry
        function onChanged() { root.prune(); }
    }
    Connections {
        target: Config
        function onEffectiveChanged() { root.prune(); }
    }

    // Every record by plugin id, for the lending record: its keys, sorted,
    // the serial of its last write and its size in bytes.
    function record() {
        const out = {};
        for (const id of Object.keys(records).sort())
            out[id] = { keys: Object.keys(records[id].values).sort(), revision: records[id].serial, bytes: records[id].bytes };
        return out;
    }
}
