export const codexMicroTargetNames = [
  "agent-1", "agent-2", "agent-3", "agent-4", "agent-5", "agent-6",
  "command-1", "command-2", "command-3", "command-4", "command-5", "command-6",
  "encoder-press", "joystick-up", "joystick-right", "joystick-down", "joystick-left",
];

export const codexMicroTargetAliases = new Map([
  ["voice-ptt", "command-5"],
  ["ptt", "command-5"],
]);

export function resolveCodexMicroTargetName(name) {
  return codexMicroTargetAliases.get(name) ?? name;
}

// These are semantic slots observed in the Codex Micro desktop integration.
// Physical keys are deliberately absent here: Arkey supplies those at runtime.
export const arkeyActionTargets = new Map([
  ["fast", "command-1"],
  ["approve", "command-2"],
  ["decline", "command-3"],
  ["continue", "command-4"],
  ["ptt", "command-5"],
  ["send", "command-6"],
  ["reasoning", "encoder-press"],
]);

function newestFirst(left, right) {
  return String(right.updatedAt ?? "").localeCompare(String(left.updatedAt ?? ""));
}

export function deriveCodexMicroMappings(bindingDocument, taskDocument, profile) {
  const controls = new Map(profile.controls.map((control) => [control.id, control]));
  const tasks = new Map(taskDocument.tasks.map((task) => [task.taskId, task]));
  const byTarget = new Map();
  const skipped = [];
  let encoderEnabled = false;

  for (const binding of [...bindingDocument.bindings].sort(newestFirst)) {
    let target;
    if (binding.actionId === "task_agent") {
      const slot = tasks.get(binding.taskId)?.slotIndex;
      if (!Number.isInteger(slot) || slot < 0 || slot > 5) {
        skipped.push({ binding, reason: "任务不在 Codex Micro 的 1–6 槽位内" });
        continue;
      }
      target = `agent-${slot + 1}`;
    } else {
      target = arkeyActionTargets.get(binding.actionId);
      if (!target) {
        skipped.push({ binding, reason: "该 Arkey 动作没有对应的 Codex Micro 原生槽位" });
        continue;
      }
    }

    let controlId = binding.controlId;
    if (controlId === profile.encoder?.id) {
      controlId = profile.encoder.pressControlId;
      if (binding.actionId === "reasoning") encoderEnabled = true;
    }
    const control = controls.get(controlId);
    if (!control?.matrix) {
      skipped.push({ binding, reason: `控件 ${binding.controlId} 没有可写入固件的矩阵坐标` });
      continue;
    }

    // The most recently updated Arkey binding wins if a target is duplicated.
    if (!byTarget.has(target)) {
      byTarget.set(target, {
        target,
        targetIndex: codexMicroTargetNames.indexOf(target),
        controlId,
        row: control.matrix.row,
        column: control.matrix.column,
        actionId: binding.actionId,
      });
    }
  }

  return { assignments: [...byTarget.values()], encoderEnabled, skipped };
}
