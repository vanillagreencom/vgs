#!/usr/bin/env node

"use strict";

const test = require("node:test");
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

test("the first request starts at once and later ones wait, the latest replacing the intermediate", () => {
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
});

test("a superseded completion starts the latest request and discards its outcome; a terminal one refreshes and announces", () => {
    const latest = request(30);
    let state = Queue.submit(Queue.emptyState(), request(10)).state;
    state = Queue.submit(state, latest).state;

    for (const [success, why] of [[false, "failure"], [true, "success"]]) {
        const transition = Queue.complete(state, success);
        assert.equal(transition.startRequest, latest, `the latest request starts after active completion (${why})`);
        assert.equal(Queue.isBusy(transition.state), true, "busy stays true across the queued handoff");
        assert.equal(transition.superseded, true);
        assert.equal(transition.refresh, false, `a superseded ${why} does not refresh`);
        assert.equal(transition.announce, false, `a superseded ${why} is not announced`);
        assert.equal(transition.success, null, "a superseded outcome is discarded");
    }

    for (const [success, expected] of [[false, false], [true, true]]) {
        const handoff = Queue.complete(state, success).state;
        const terminal = Queue.complete(handoff, success);
        assert.equal(Queue.isBusy(terminal.state), false, "a terminal completion settles the queue");
        assert.equal(terminal.superseded, false);
        assert.equal(terminal.refresh, true, "a terminal completion refreshes authoritative state");
        assert.equal(terminal.announce, true, "a terminal completion is announced");
        assert.equal(terminal.success, expected, "with its own outcome");
    }
});

test("a reset request completes as a terminal success", () => {
    const state = Queue.submit(Queue.emptyState(), { reset: true }).state;
    const transition = Queue.complete(state, true);
    assert.equal(Queue.isBusy(transition.state), false);
    assert.equal(transition.refresh, true);
    assert.equal(transition.announce, true);
    assert.equal(transition.success, true, "a terminal success is announced as successful");
});

test("a commit queued behind a preview runs and refreshes; a preview behind a commit is dropped", () => {
    const previewState = Queue.submit(Queue.emptyState(), { id: "preview", preview: true }).state;
    const queuedCommit = Queue.submit(previewState, { id: "commit", preview: false });
    assert.equal(queuedCommit.dropped, false);
    assert.equal(queuedCommit.state.queuedRequest.id, "commit");
    const startCommit = Queue.complete(queuedCommit.state, true);
    assert.equal(startCommit.startRequest.id, "commit");
    const finishCommit = Queue.complete(startCommit.state, true);
    assert.equal(finishCommit.refresh, true, "a commit after preview refreshes authoritative state");
    assert.equal(finishCommit.announce, true);

    const commitState = Queue.submit(Queue.emptyState(), { id: "commit", preview: false }).state;
    const droppedPreview = Queue.submit(commitState, { id: "preview", preview: true });
    assert.equal(droppedPreview.dropped, true);
    assert.equal(droppedPreview.state, commitState);
    const completedCommit = Queue.complete(droppedPreview.state, true);
    assert.equal(completedCommit.refresh, true, "a preview cannot suppress commit refresh");
    assert.equal(completedCommit.announce, true);
});
