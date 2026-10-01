// Own reducer effects and deadlines in the daemon. Ports own their resources;
// each receives a completion function stamped with its original gen/op.
// Audio, the action router and the chained engine supply production ports.
// unavailable() covers a port no owner has installed yet.
// A speech port's callbacks are stamped with the speech-open effect's identity.
"use strict";

class SessionRunner {
    constructor(session, ports, clock, publish) {
        this.session = session;
        this.ports = ports;
        this.clock = clock;
        this.publish = publish;
        this.state = session.initial();
        this.timer = null;
        this.queue = [];
        this.draining = false;
        this.lifetime = { kind: "open" };
    }

    dispatch(event) {
        this.queue.push({ ...event, at: this.clock.now() });
        if (this.draining) return;
        this.draining = true;
        try {
            while (this.queue.length) {
                const result = this.session.reduce(this.state, this.queue.shift());
                this.state = result.state;
                this.ports.tools.sync(this.state);
                // A published mute value must already survive a daemon restart.
                let persistence = { kind: "stored" };
                try {
                    for (const effect of result.effects)
                        if (effect.kind === "mute-store") this.consume(effect);
                } catch (error) { persistence = { kind: "failed", error }; }
                if (persistence.kind === "stored")
                    this.publish(this.state, this.session.phaseOf(this.state));
                for (const effect of result.effects)
                    if (effect.kind !== "mute-store") this.consume(effect);
                if (persistence.kind === "failed") throw persistence.error;
            }
            this.schedule();
        } finally { this.draining = false; }
    }

    consume(e) {
        const done = (type, values = {}) => this.dispatch({ ...values, type, gen: e.gen, op: e.op });
        switch (e.kind) {
        case "capture-open": this.ports.capture.open(e, () => done("capture-opened"),
            reason => done("capture-failed", { reason })); break;
        case "capture-close": this.ports.capture.close(e, () => done("capture-closed")); break;
        case "collect": this.ports.capture.collect(e, (type, text) => done(type, { text })); break;
        case "brain-send": this.ports.brain.send(e, (type, values) => done(type, values)); break;
        case "brain-cancel":
            this.ports.brain.cancel(e, () => this.dispatch({ type: "cancelled", gen: e.gen, op: e.target }));
            break;
        case "brain-close": this.ports.brain.close(e); break;
        case "playback-start": this.ports.playback.start(e, () => done("played"),
            reason => done("playback-failed", { reason })); break;
        case "playback-flush": this.ports.playback.flush(e, () => done("flushed")); break;
        case "tool-start": this.ports.tools.start(e, outcome => done("tool-done", { outcome })); break;
        case "tool-cancel": this.ports.tools.cancel(e); break;
        case "tool-outcome": this.ports.tools.outcome(e); break;
        case "approval-show": this.ports.approval.show(e); break;
        case "approval-ended": this.ports.approval.end(e); break;
        case "confirm-refused": this.ports.approval.refused(e); break;
        case "mute-store": this.ports.mute.store(e.muted); break;
        case "speech-open": this.ports.speech.open(e, {
            speak: () => done("speak"),
            transcript: record => done("transcript", record),
            idle: () => done("speech-idle"),
            failed: reason => done("speech-failed", { reason })
        }); break;
        case "speech-close": this.ports.speech.close(e); break;
        case "speech-flush": this.ports.speech.flush(e); break;
        case "transcript": this.ports.transcript(e); break;
        default: throw new Error("jarvis: session=effect kind=" + e.kind);
        }
    }

    schedule() {
        if (this.timer !== null) this.clock.clear(this.timer);
        this.timer = null;
        if (this.lifetime.kind === "closed") return;
        const action = this.state.action;
        const toolDeadline = action.kind === "running" && action.limit.kind === "pending"
            ? { gen: action.gen, op: action.op, deadline: action.limit.deadline } : {};
        const owners = [this.state.turn, this.state.approval, toolDeadline]
            .filter(owner => Object.hasOwn(owner, "deadline"));
        if (owners.length === 0) return;
        const owner = owners.reduce((a, b) => a.deadline <= b.deadline ? a : b);
        this.timer = this.clock.set(() => {
            this.timer = null;
            this.dispatch({ type: "deadline", gen: owner.gen, op: owner.op });
        }, Math.max(0, owner.deadline - this.clock.now()));
    }

    // Lease loss also releases a deadline which could otherwise retain Node,
    // and every speech session: lease-ended aborts only the open one, and
    // sessions already closing still hold a socket and a timer.
    close() {
        if (this.lifetime.kind !== "open") return;
        this.lifetime = { kind: "closed" };
        this.dispatch({ type: "lease-ended" });
        this.ports.tools.close();
        this.ports.speech.release();
    }
}

// No stub reports that audio or a tool ran. The skeleton never raises its
// unconfigured gate, so an acquisition here is an invariant violation.
function unavailable() {
    function refuse() { throw new Error("jarvis: session=adapter-unavailable"); }
    return {
        capture: { open: refuse, close: (e, done) => done(), collect: refuse },
        brain: { send: refuse, cancel: (e, done) => done(), close: () => {}, outcome: refuse },
        playback: { start: refuse, flush: (e, done) => done() },
        tools: { start: refuse, cancel: refuse, outcome: refuse, sync: () => {}, close: () => {} },
        approval: { show: refuse, end: () => {}, refused: refuse },
        speech: { open: refuse, close: () => {}, flush: () => {}, release: () => {} },
        transcript: refuse
    };
}

module.exports = { SessionRunner, unavailable };
