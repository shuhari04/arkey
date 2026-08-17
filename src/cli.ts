#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { ArkeyDaemon, observeRuntimeEvents, sendMessage, sendRpc } from "./runtime.js";
import { AgentState } from "./protocol.js";
import { installHooks, installLaunchAgent, stopLaunchAgent } from "./install.js";
import { runClaude, runCodex } from "./wrappers.js";
import { stateForHook } from "./events.js";
import { KeyboardTransport } from "./transport.js";

const [command = "help", ...args] = process.argv.slice(2);

async function main(): Promise<void> {
  switch (command) {
    case "daemon": {
      const daemon = new ArkeyDaemon(); await daemon.start();
      const stop = async () => { await daemon.stop(); process.exit(0); };
      process.on("SIGTERM", stop); process.on("SIGINT", stop); return;
    }
    case "start": installLaunchAgent(process.argv[1]); await sleep(400); console.log("Arkey background service started."); return;
    case "stop": await sendMessage({ type: "restore" }).catch(() => undefined); stopLaunchAgent(); console.log("Arkey stopped and requested lighting restore."); return;
    case "status": {
      try {
        const status = await sendMessage({ type: "status" }, true);
        console.log(JSON.stringify(status, null, 2));
      } catch {
        const transport = new KeyboardTransport(); const connection = transport.connect(); transport.close();
        console.log(connection ? `${connection.product}: ${supportMessage(connection.support)}` : "Arkey daemon is stopped; no supported USB keyboard found.");
      } return;
    }
    case "test": {
      const status = await sendMessage({ type: "status" }, true).catch(() => undefined);
      if (!status) throw new Error("Arkey daemon is not running. Run: arkey start");
      if (status.support !== "arkey") throw new Error(status.support === "via-only" ? "Keyboard supports VIA but does not have the Arkey firmware protocol." : "Arkey firmware protocol is unavailable.");
      await sendMessage({ type: "test" }); console.log("Test animation sent."); return;
    }
    case "preview": {
      const state = previewState(args[0]);
      const durationMs = Number(args[1] ?? 5000);
      await sendMessage({ type: "preview", state, durationMs });
      console.log(`Previewing ${args[0]} for ${Math.round(durationMs / 100) / 10}s.`); return;
    }
    case "text": {
      const text = args.join(" ");
      if (!text) throw new Error("Usage: arkey text <characters>");
      await sendMessage({ type: "text", source: "manual", text });
      console.log("Text lighting preview sent."); return;
    }
    case "install-hooks": {
      const paths = installHooks(process.argv[1]); console.log(`Hooks installed without replacing existing entries:\n${paths.join("\n")}`); return;
    }
    case "event": {
      const [source, event] = args as ["codex" | "claude", string];
      const input = readFileSync(0, "utf8"); let payload: unknown = {};
      try { payload = input ? JSON.parse(input) : {}; } catch { /* Never persist or echo hook payloads. */ }
      await sendMessage({ type: "event", source, state: stateForHook(event ?? "start", payload) }).catch(() => undefined); return;
    }
    case "codex": process.exitCode = await runCodex(args); return;
    case "claude": process.exitCode = await runClaude(args); return;
    case "restore": await sendMessage({ type: "restore" }); console.log("Restore requested."); return;
    case "rpc": {
      const method = args[0];
      if (!method) throw new Error("Usage: arkey rpc <method> [json-params]");
      let params: unknown = {};
      if (args[1]) {
        try { params = JSON.parse(args.slice(1).join(" ")) as unknown; }
        catch { throw new Error("RPC params must be valid JSON"); }
      }
      const result = await sendRpc(method, params);
      console.log(JSON.stringify(result, null, 2));
      return;
    }
    case "observe": {
      if (args[0] !== undefined && args[0] !== "--jsonl") throw new Error("Usage: arkey observe --jsonl");
      await new Promise<void>((resolve, reject) => {
        const socket = observeRuntimeEvents((event) => process.stdout.write(`${JSON.stringify(event)}\n`));
        socket.once("error", reject);
        socket.once("close", resolve);
        const stop = () => { socket.end(); resolve(); };
        process.once("SIGINT", stop);
        process.once("SIGTERM", stop);
      });
      return;
    }
    default: console.log(help()); return;
  }
}

function supportMessage(support: string): string {
  if (support === "arkey") return "Arkey protocol ready";
  if (support === "via-only") return "VIA detected, Arkey firmware not installed";
  return "Raw HID found, Arkey protocol unavailable";
}
function previewState(value = ""): AgentState {
  const states: Record<string, AgentState> = {
    thinking: AgentState.Thinking, tool: AgentState.Tool, streaming: AgentState.Streaming,
    complete: AgentState.Complete, error: AgentState.Error,
  };
  const state = states[value.toLowerCase()];
  if (state === undefined) throw new Error("Usage: arkey preview <thinking|tool|streaming|complete|error> [milliseconds]");
  return state;
}
function sleep(ms: number): Promise<void> { return new Promise((resolve) => setTimeout(resolve, ms)); }
function help(): string { return `Arkey 0.1.0\n\nCommands:\n  start | stop | status | test | restore\n  preview <thinking|tool|streaming|complete|error> [milliseconds]\n  text <characters>\n  rpc <method> [json-params]\n  observe --jsonl\n  install-hooks\n  codex -- <codex exec arguments>\n  claude -- <claude print arguments>`; }

main().catch((error) => { console.error(`arkey: ${error instanceof Error ? error.message : String(error)}`); process.exitCode = 1; });
