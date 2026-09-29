import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// One command target per plugin. Instance lifetimes own its registrations;
// removing the last function releases the target before a replacement builds.
// `call` reaches the calling plugin's own target in this process, as
// `vgsh ipc call <id> invoke` does from outside, so a panel asks the
// plugin's service for work the service owns. It registers nothing.
Scope {
    id: root
    property var ipcTargets: ({})

    function provider(ctx) {
        return {
            handle: (name, fn) => root.handleIpc(ctx, name, fn),
            call: (name, arg) => root.callIpc(ctx, name, arg)
        };
    }

    function callIpc(ctx, name, arg) {
        const refusal = Logic.ipcCallRefusal(name, arg);
        if (refusal !== "") throw new Error(refusal);
        return invokeIpc(ctx.id, name, arg);
    }

    // ipc: one IpcHandler per plugin, target named for the plugin id, with
    // one function: `invoke <name> <arg>` calls the handler the plugin
    // registered under that name and answers its return value as text.
    function handleIpc(ctx, name, fn) {
        Capabilities.checkName("ipc", name);
        if (typeof fn !== "function")
            throw new Error("refused: ipc=" + name + " handler=not-a-function");
        let target = ipcTargets[ctx.id];
        if (target !== undefined && Logic.hasOwn(target.functions, name))
            throw new Error("refused: ipc=" + ctx.id + ":" + name + " held");
        const next = Object.assign({}, ipcTargets);
        if (target === undefined)
            target = { handler: ipcComponent.createObject(root, { target: ctx.id }), functions: {} };
        target = { handler: target.handler, functions: Object.assign({}, target.functions) };
        target.functions[name] = fn;
        next[ctx.id] = target;
        ipcTargets = next;
        return ctx.onDispose(() => {
            const rest = Object.assign({}, root.ipcTargets);
            const t = { handler: rest[ctx.id].handler, functions: Object.assign({}, rest[ctx.id].functions) };
            delete t.functions[name];
            if (Object.keys(t.functions).length === 0) {
                // destroy() is deferred; clearing the target unregisters it
                // now, so a rebuilt plugin's new handler takes the target.
                t.handler.target = "";
                t.handler.destroy();
                delete rest[ctx.id];
            } else {
                rest[ctx.id] = t;
            }
            root.ipcTargets = rest;
        });
    }

    function invokeIpc(id, name, arg) {
        const answer = Logic.ipcAnswer(ipcTargets, id, name, arg);
        if (answer.error !== null) console.error("capabilities: ipc " + id + ":" + name + " threw: " + answer.error);
        return answer.reply;
    }

    Component {
        id: ipcComponent
        IpcHandler {
            function invoke(name: string, arg: string): string { return root.invokeIpc(target, name, arg); }
        }
    }

}
