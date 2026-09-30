// Own reducer effects and deadlines in the daemon. Ports own their resources;
// each receives a completion function stamped with its original gen/op.
// The daemon supplies unavailable ports until audio, brain and router land.
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
    }

    dispatch(event) {
        this.queue.push({ ...event, at: this.clock.now() });
        if (this.draining) return;
        this.draining = true;
        try {
            while (this.queue.length) {
                const result = this.session.reduce(this.state, this.queue.shift());
                this.state = result.state;
                this.publish(this.state, this.session.phaseOf(this.state));
                for (const effect of result.effects) this.consume(effect);
            }
            this.schedule();
        } finally { this.draining = false; }
    }

    consume(e) {
        const done = (type, values = {}) => this.dispatch({ ...values, type, gen: e.gen, op: e.op });
        switch (e.kind) {
        case "capture-open": this.ports.capture.open(e, () => done("capture-opened")); break;
        case "capture-close": this.ports.capture.close(e, () => done("capture-closed")); break;
        case "collect": this.ports.capture.collect(e, (type, text) => done(type, { text })); break;
        case "brain-send": this.ports.brain.send(e, (type, values) => done(type, values)); break;
        case "brain-cancel":
            this.ports.brain.cancel(e, () => this.dispatch({ type: "cancelled", gen: e.gen, op: e.target }));
            break;
        case "brain-close": this.ports.brain.close(e); break;
        case "playback-start": this.ports.playback.start(e, () => done("played")); break;
        case "playback-flush": this.ports.playback.flush(e, () => done("flushed")); break;
        case "tool-start": this.ports.tools.start(e, outcome => done("tool-done", { outcome })); break;
        case "tool-cancel": this.ports.tools.cancel(e); break;
        case "tool-outcome": this.ports.brain.outcome(e); break;
        case "approval-show": this.ports.approval.show(e, () => done("shown")); break;
        case "approval-ended": this.ports.approval.end(e); break;
        default: throw new Error("jarvis: session=effect kind=" + e.kind);
        }
    }

    schedule() {
        if (this.timer !== null) this.clock.clear(this.timer);
        this.timer = null;
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

    // Lease loss also releases a deadline which could otherwise retain Node.
    close() {
        this.dispatch({ type: "stop" });
        if (this.timer !== null) this.clock.clear(this.timer);
        this.timer = null;
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
        tools: { start: refuse, cancel: refuse },
        approval: { show: refuse, end: () => {} }
    };
}

module.exports = { SessionRunner, unavailable };
