import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { AgentState } from "./protocol.js";
import { sendMessage } from "./runtime.js";
import { claudeTextFromEvent, codexTextFromEvent } from "./events.js";

async function emitText(source: "codex" | "claude", text: string): Promise<void> {
  process.stdout.write(text);
  await sendMessage({ type: "text", source, text }).catch(() => undefined);
}

export async function runCodex(args: string[]): Promise<number> {
  await sendMessage({ type: "event", source: "codex", state: AgentState.Thinking }).catch(() => undefined);
  const child = spawn("codex", ["exec", "--json", ...stripSeparator(args)], { stdio: ["inherit", "pipe", "inherit"] });
  const lines = createInterface({ input: child.stdout });
  for await (const line of lines) {
    try { const text = codexTextFromEvent(JSON.parse(line)); if (text) await emitText("codex", text); }
    catch { process.stderr.write(`${line}\n`); }
  }
  const code = await new Promise<number>((resolve) => child.once("close", (value) => resolve(value ?? 1)));
  await sendMessage({ type: "event", source: "codex", state: code === 0 ? AgentState.Complete : AgentState.Error }).catch(() => undefined);
  if (code === 0) process.stdout.write("\n"); return code;
}

export async function runClaude(args: string[]): Promise<number> {
  await sendMessage({ type: "event", source: "claude", state: AgentState.Thinking }).catch(() => undefined);
  const child = spawn("claude", ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages", ...stripSeparator(args)], { stdio: ["inherit", "pipe", "inherit"] });
  const lines = createInterface({ input: child.stdout });
  for await (const line of lines) {
    try { const text = claudeTextFromEvent(JSON.parse(line)); if (text) await emitText("claude", text); }
    catch { process.stderr.write(`${line}\n`); }
  }
  const code = await new Promise<number>((resolve) => child.once("close", (value) => resolve(value ?? 1)));
  await sendMessage({ type: "event", source: "claude", state: code === 0 ? AgentState.Complete : AgentState.Error }).catch(() => undefined);
  if (code === 0) process.stdout.write("\n"); return code;
}

function stripSeparator(args: string[]): string[] { return args[0] === "--" ? args.slice(1) : args; }
