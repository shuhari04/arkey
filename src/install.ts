import { cpSync, existsSync, mkdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

function readJson(path: string): Record<string, unknown> {
  if (!existsSync(path)) return {};
  return JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
}

function writeJson(path: string, value: unknown): void {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
}

function addHook(settings: Record<string, unknown>, event: string, command: string): void {
  const hooks = (settings.hooks ??= {}) as Record<string, unknown[]>;
  const entries = (hooks[event] ??= []);
  hooks[event] = entries.filter((entry) => {
    const serialized = JSON.stringify(entry);
    const isArkey = (serialized.includes("arkey") || serialized.includes("/.arkey/app/")) && serialized.includes(" event ");
    return !isArkey;
  });
  hooks[event].push({ hooks: [{ type: "command", command, timeout: 5 }] });
}

const runtimeApp = join(homedir(), ".arkey", "app");

function deployRuntime(cliPath: string): string {
  let root = dirname(realpathSync(cliPath));
  while (dirname(root) !== root && !existsSync(join(root, "package.json"))) root = dirname(root);
  if (!existsSync(join(root, "package.json"))) throw new Error("Cannot locate Arkey package root");
  rmSync(runtimeApp, { recursive: true, force: true });
  mkdirSync(runtimeApp, { recursive: true, mode: 0o700 });
  for (const name of ["dist", "profiles", "node_modules", "package.json"]) cpSync(join(root, name), join(runtimeApp, name), { recursive: true });
  const firmwareBinary = join(root, "build", "arkey-q6-pro-ansi-v0.1.0.bin");
  if (existsSync(firmwareBinary)) {
    mkdirSync(join(runtimeApp, "build"), { recursive: true, mode: 0o700 });
    cpSync(firmwareBinary, join(runtimeApp, "build", "arkey-q6-pro-ansi-v0.1.0.bin"));
  }
  return join(runtimeApp, "dist", "src", "cli.js");
}

export function installHooks(cliPath: string): string[] {
  const runtimeEntrypoint = deployRuntime(cliPath);
  const escaped = `${JSON.stringify(process.execPath)} ${JSON.stringify(runtimeEntrypoint)}`;
  const installed: string[] = [];

  const codexPath = join(homedir(), ".codex", "hooks.json");
  const codex = readJson(codexPath);
  for (const event of ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SubagentStart", "SubagentStop"]) {
    addHook(codex, event, `${escaped} event codex ${event}`);
  }
  writeJson(codexPath, codex); installed.push(codexPath);

  const claudePath = join(homedir(), ".claude", "settings.json");
  const claude = readJson(claudePath);
  for (const event of ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SubagentStart", "SubagentStop", "Notification"]) {
    addHook(claude, event, `${escaped} event claude ${event}`);
  }
  writeJson(claudePath, claude); installed.push(claudePath);
  return installed;
}

export const launchAgentPath = join(homedir(), "Library", "LaunchAgents", "io.arkey.daemon.plist");

export function installLaunchAgent(cliPath: string): void {
  mkdirSync(dirname(launchAgentPath), { recursive: true });
  const logDir = join(homedir(), ".arkey"); mkdirSync(logDir, { recursive: true, mode: 0o700 });
  writeFileSync(join(logDir, "daemon.log"), "", { mode: 0o644 });
  writeFileSync(join(logDir, "daemon-error.log"), "", { mode: 0o644 });
  const entrypoint = deployRuntime(cliPath);
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.arkey.daemon</string>
<key>ProgramArguments</key><array><string>${process.execPath}</string><string>${entrypoint}</string><string>daemon</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
<key>StandardOutPath</key><string>${join(logDir, "daemon.log")}</string>
<key>StandardErrorPath</key><string>${join(logDir, "daemon-error.log")}</string>
</dict></plist>\n`;
  writeFileSync(launchAgentPath, xml, { mode: 0o644 });
  const domain = `gui/${process.getuid?.() ?? 501}`;
  spawnSync("launchctl", ["bootout", domain, launchAgentPath], { stdio: "ignore" });
  const result = spawnSync("launchctl", ["bootstrap", domain, launchAgentPath], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr || "launchctl bootstrap failed");
}

export function stopLaunchAgent(): void {
  const domain = `gui/${process.getuid?.() ?? 501}`;
  spawnSync("launchctl", ["bootout", domain, launchAgentPath], { stdio: "ignore" });
}
