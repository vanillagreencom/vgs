#!/usr/bin/env node

"use strict";

const assert = require("node:assert/strict");
const Queue = require("../quickshell/vshell/Services/RestyleQueue.js");

function request(value) {
    return {
        reset: false,
        adjustments: {
            brightness: value
        }
    };
}

let state = Queue.emptyState();
assert.equal(Queue.isBusy(state), false, "an empty queue is idle");

const first = request(10);
let transition = Queue.submit(state, first);
state = transition.state;
assert.equal(transition.startRequest, first, "the first request starts immediately");
assert.equal(Queue.isBusy(state), true, "the queue is busy while the first request runs");

const intermediate = request(20);
transition = Queue.submit(state, intermediate);
state = transition.state;
assert.equal(transition.startRequest, null, "a request does not start alongside the active request");
assert.equal(state.queuedRequest, intermediate, "the intermediate request waits");

const latest = request(30);
transition = Queue.submit(state, latest);
state = transition.state;
assert.equal(state.queuedRequest, latest, "the latest request replaces the intermediate request");

transition = Queue.complete(state, false);
state = transition.state;
assert.equal(transition.startRequest, latest, "the latest request starts after active completion");
assert.equal(Queue.isBusy(state), true, "busy stays true across the queued handoff");
assert.equal(transition.superseded, true);
assert.equal(transition.refresh, false, "a superseded completion does not refresh");
assert.equal(transition.announce, false, "a superseded failure is not announced");
assert.equal(transition.success, null, "a superseded outcome is discarded");

transition = Queue.complete(state, false);
state = transition.state;
assert.equal(Queue.isBusy(state), false, "a terminal completion settles the queue");
assert.equal(transition.superseded, false);
assert.equal(transition.refresh, true, "a terminal failure refreshes authoritative state");
assert.equal(transition.announce, true, "a terminal failure is announced");
assert.equal(transition.success, false);

const completed = request(40);
const superseding = request(50);
state = Queue.submit(Queue.emptyState(), completed).state;
state = Queue.submit(state, superseding).state;
transition = Queue.complete(state, true);
assert.equal(transition.startRequest, superseding);
assert.equal(transition.refresh, false, "a superseded success does not refresh");
assert.equal(transition.announce, false, "a superseded success is not announced");

state = transition.state;
transition = Queue.complete(state, true);
assert.equal(transition.success, true);
state = transition.state;

state = Queue.submit(state, { reset: true }).state;
transition = Queue.complete(state, true);
assert.equal(Queue.isBusy(transition.state), false);
assert.equal(transition.refresh, true);
assert.equal(transition.announce, true);
assert.equal(transition.success, true, "a terminal success is announced as successful");

let previewState = Queue.submit(Queue.emptyState(), { id: "preview", preview: true }).state;
let queuedCommit = Queue.submit(previewState, { id: "commit", preview: false });
assert.equal(queuedCommit.dropped, false);
assert.equal(queuedCommit.state.queuedRequest.id, "commit");
let startCommit = Queue.complete(queuedCommit.state, true);
assert.equal(startCommit.startRequest.id, "commit");
let finishCommit = Queue.complete(startCommit.state, true);
assert.equal(finishCommit.refresh, true, "a commit after preview refreshes authoritative state");
assert.equal(finishCommit.announce, true);

let commitState = Queue.submit(Queue.emptyState(), { id: "commit", preview: false }).state;
let droppedPreview = Queue.submit(commitState, { id: "preview", preview: true });
assert.equal(droppedPreview.dropped, true);
assert.equal(droppedPreview.state, commitState);
let completedCommit = Queue.complete(droppedPreview.state, true);
assert.equal(completedCommit.refresh, true, "a preview cannot suppress commit refresh");
assert.equal(completedCommit.announce, true);

console.log("restyle queue checks passed");
