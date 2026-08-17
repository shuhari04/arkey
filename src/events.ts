import { AgentState } from "./protocol.js";

export function stateForHook(event: string, payload: unknown): AgentState {
  const normalized = event.toLowerCase();
  if (normalized.includes("error") || JSON.stringify(payload).toLowerCase().includes('"error"')) return AgentState.Error;
  if (normalized === "stop" || normalized.includes("completed") || normalized.includes("subagentstop")) return AgentState.Complete;
  if (normalized.includes("pretool") || normalized.includes("tooluse")) return AgentState.Tool;
  if (normalized.includes("prompt") || normalized.includes("start")) return AgentState.Thinking;
  return AgentState.Thinking;
}

export function codexTextFromEvent(event: unknown): string | undefined {
  if (!event || typeof event !== "object") return undefined;
  const value = event as Record<string, unknown>;
  if (value.type === "item.completed" && value.item && typeof value.item === "object") {
    const item = value.item as Record<string, unknown>;
    if (item.type === "agent_message" && typeof item.text === "string") return item.text;
  }
  if ((value.type === "agent_message_delta" || value.type === "item.agent_message.delta") && typeof value.delta === "string") return value.delta;
  return undefined;
}

export function claudeTextFromEvent(event: unknown): string | undefined {
  if (!event || typeof event !== "object") return undefined;
  const value = event as Record<string, unknown>;
  if (value.type === "stream_event" && value.event && typeof value.event === "object") {
    const stream = value.event as Record<string, unknown>;
    if (stream.type === "content_block_delta" && stream.delta && typeof stream.delta === "object") {
      const delta = stream.delta as Record<string, unknown>;
      if (delta.type === "text_delta" && typeof delta.text === "string") return delta.text;
    }
  }
  return undefined;
}
