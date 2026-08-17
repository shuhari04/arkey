import assert from "node:assert/strict";
import test from "node:test";
import { deriveCodexMicroMappings, resolveCodexMicroTargetName } from "../scripts/codex-micro-lab-bindings.mjs";

test("existing Arkey bindings sync to Codex slots without fixed physical keys", () => {
  const profile = {
    controls: [
      { id: "key-a", matrix: { row: 1, column: 2 } },
      { id: "key-b", matrix: { row: 3, column: 4 } },
      { id: "encoder-key", matrix: { row: 0, column: 13 } },
      { id: "numpad-zero", matrix: { row: 5, column: 18 } },
    ],
    encoder: { id: "encoder-0", pressControlId: "encoder-key" },
  };
  const result = deriveCodexMicroMappings({ bindings: [
    { controlId: "key-a", actionId: "task_agent", taskId: "task-3", updatedAt: "2026-07-16T00:00:00Z" },
    { controlId: "key-b", actionId: "approve", updatedAt: "2026-07-16T00:00:01Z" },
    { controlId: "encoder-0", actionId: "reasoning", updatedAt: "2026-07-16T00:00:02Z" },
    { controlId: "key-a", actionId: "skill", updatedAt: "2026-07-16T00:00:03Z" },
    { controlId: "numpad-zero", actionId: "ptt", updatedAt: "2026-07-16T00:00:04Z" },
  ] }, { tasks: [{ taskId: "task-3", slotIndex: 2 }] }, profile);

  assert.deepEqual(result.assignments.map(({ target, controlId }) => ({ target, controlId })), [
    { target: "command-5", controlId: "numpad-zero" },
    { target: "encoder-press", controlId: "encoder-key" },
    { target: "command-2", controlId: "key-b" },
    { target: "agent-3", controlId: "key-a" },
  ]);
  assert.equal(result.encoderEnabled, true);
  assert.equal(result.skipped[0].binding.actionId, "skill");
});

test("native voice aliases preserve the ACT10 firmware target", () => {
  assert.equal(resolveCodexMicroTargetName("voice-ptt"), "command-5");
  assert.equal(resolveCodexMicroTargetName("ptt"), "command-5");
  assert.equal(resolveCodexMicroTargetName("command-5"), "command-5");
});
