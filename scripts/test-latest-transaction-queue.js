#!/usr/bin/env node

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const Queue = require("../quickshell/vshell/Common/LatestTransactionQueue.js");

// apply running, profile queued and then superseded by revert.
function queued() {
    let state = Queue.emptyState();
    state = Queue.submit(state, { id: "apply" }).state;
    state = Queue.submit(state, { id: "profile" }).state;
    return Queue.submit(state, { id: "revert" });
}

test("submissions are single-flight and only the latest waiting transaction survives", () => {
    let state = Queue.emptyState();
    let transition = Queue.submit(state, { id: "apply" });
    state = transition.state;
    assert.equal(transition.startRequest.id, "apply");

    transition = Queue.submit(state, { id: "profile" });
    state = transition.state;
    assert.equal(transition.startRequest, null, "transactions must stay single-flight");
    assert.equal(state.queuedRequest.id, "profile");

    transition = Queue.submit(state, { id: "revert" });
    state = transition.state;
    assert.equal(transition.supersededRequest.id, "profile");
    assert.equal(state.queuedRequest.id, "revert", "only the latest waiting transaction survives");
});

test("a completion for an unknown generation is ignored", () => {
    const state = queued().state;
    const transition = Queue.complete(state, state.activeRequest.generation + 100);
    assert.equal(transition.ignored, true, "unknown callbacks cannot advance the queue");
    assert.equal(transition.state, state);
});

test("the queued transaction starts only after the active one completes, and the last owns completion", () => {
    let state = queued().state;
    let transition = Queue.complete(state, state.activeRequest.generation);
    state = transition.state;
    assert.equal(transition.completedLatest, false, "the older apply completion is stale");
    assert.equal(transition.startRequest.id, "revert", "revert starts only after apply completes");
    assert.equal(state.activeRequest.id, "revert");

    transition = Queue.complete(state, state.activeRequest.generation);
    state = transition.state;
    assert.equal(transition.completedLatest, true, "the final transaction owns completion");
    assert.equal(state.activeRequest, null);
    assert.equal(state.queuedRequest, null);
});
