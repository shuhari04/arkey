import assert from "node:assert/strict";
import test from "node:test";
import { claudeTextFromEvent, codexTextFromEvent, stateForHook } from "../src/events.js";
import { AgentState } from "../src/protocol.js";

test("maps hook lifecycle to lighting states", () => {
  assert.equal(stateForHook("UserPromptSubmit", {}), AgentState.Thinking);
  assert.equal(stateForHook("PreToolUse", {}), AgentState.Tool);
  assert.equal(stateForHook("Stop", {}), AgentState.Complete);
  assert.equal(stateForHook("PostToolUse", { error: "failed" }), AgentState.Error);
});

test("extracts Codex agent messages", () => {
  assert.equal(codexTextFromEvent({ type: "item.completed", item: { type: "agent_message", text: "done" } }), "done");
});

test("extracts Claude partial text deltas", () => {
  const event = { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "const" } } };
  assert.equal(claudeTextFromEvent(event), "const");
});
