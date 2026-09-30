import QtQuick
import Quickshell
import Quickshell.Io
import "PluginLogic.js" as Logic

// Owns every libsecret write the core makes for a plugin (D061): one
// `secret-tool store` or `secret-tool clear` at a time, from the argv
// PluginLogic.secretRequest builds for the `manager` capability's
// storeSecret and clearSecret. A store hands the secret to secret-tool on
// stdin, never on an argv, then closes stdin, since secret-tool reads a
// stdin that is no terminal to its end and keeps every byte. No secret
// enters a log line, a property of this owner or a status value: it lives
// only in the closure that writes it once the process has started.
// `revisions` counts, per plugin id, the writes that ended, however they
// ended, and the `secrets` capability lends it as `revision`, so the
// plugin probes its store again. Each write's `done` belongs to the
// lifetime of the instance that asked, and is dropped with it.
Scope {
    id: root

    // Plugin id -> the writes ended for it. Replaced whole on every change,
    // so a binding on revisionOf follows it.
    property var revisions: ({})
    // The write running, { id, account, verb, done, feed }, or null.
    property var current: null

    function revisionOf(id) {
        return Logic.hasOwn(revisions, id) ? revisions[id] : 0;
    }

    function provider(ctx) {
        return {
            get revision() { return root.revisionOf(ctx.id); }
        };
    }

    // Start one write for plugin ID's ACCOUNT: REQUEST is
    // PluginLogic.secretRequest's ok answer for VERB, CTX the asking
    // instance, DONE, when given, called once with { ok, reason } as the
    // write ends: `ok` true on exit 0, else `reason` `start-failed` or
    // `exit=<code>`. Answers `ok` once started, or
    // `refused: secret=<account> reason=busy` while another write runs.
    function write(ctx, id, account, verb, request, done) {
        if (current !== null) return Logic.secretRefusal(account, "busy");
        const record = { id: id, account: account, verb: verb, done: done === undefined ? null : done, feed: null, release: null };
        if (request.input !== null) {
            const secret = request.input;
            record.feed = () => {
                writer.write(secret);
                writer.stdinEnabled = false;
            };
        }
        record.release = ctx.onDispose(() => { record.done = null; });
        current = record;
        writer.exitCode = null;
        writer.stdinEnabled = record.feed !== null;
        // Assigned after the record: a list handed to a property crosses a
        // QVariant conversion (runtime-qml.md), and nothing here holds the
        // secret.
        writer.command = request.argv;
        writer.running = true;
        return "ok";
    }

    function finish() {
        const record = current;
        if (record === null) return;
        current = null;
        const code = writer.exitCode;
        const result = code === 0 ? { ok: true, reason: null } : { ok: false, reason: code === null ? "start-failed" : "exit=" + code };
        const line = "secrets: " + record.verb + "=" + record.id + "/" + record.account + (result.ok ? " ok" : " failed " + result.reason) + (errors.text.trim() !== "" ? " stderr=" + errors.text.trim().split("\n")[0] : "");
        if (result.ok) console.info(line);
        else console.warn(line);
        const next = Object.assign({}, revisions);
        next[record.id] = revisionOf(record.id) + 1;
        revisions = next;
        const done = record.done;
        record.release();
        if (done !== null) done(result);
    }

    Process {
        id: writer
        // The exit code of the run that ended, null for one that never
        // started, since a failed start emits only runningChanged.
        property var exitCode: null
        stdout: StdioCollector {}
        stderr: StdioCollector { id: errors }
        onStarted: {
            if (root.current !== null && root.current.feed !== null) {
                const feed = root.current.feed;
                root.current.feed = null;
                feed();
            }
        }
        onExited: code => { exitCode = code; }
        onRunningChanged: if (!running) root.finish()
    }
}
