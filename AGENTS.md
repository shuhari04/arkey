# Instructions for coding agents

This repository is intentionally narrow: an unofficial Codex App Server client,
an Arkey host daemon, AgentGlow lighting, board-specific QMK examples, and
isolated, development-only Codex Micro Lab experiments for the Q6 Pro and
V1 Max ANSI Knob.

## Read before changing code

1. Read `README.md`, `CONTRIBUTING.md`, and the relevant document under `docs/`.
2. Treat the live source, profile JSON, effect catalog, and pinned QMK commit as
   the sources of truth. Do not infer hardware facts from a product name alone.
3. Preserve the boundary between the official Codex App Server transport and
   the independent Arkey-to-QMK Raw HID bridge.

## Hard boundaries

- Standard Arkey builds and new board ports must never use a third-party USB
  identity or native-facing Micro compatibility behavior.
- The sole exception is the explicitly named `codex-micro-lab` Q6 Pro and V1 Max
  ANSI Knob experiments documented in `docs/CODEX_MICRO_LAB.md`. Keep
  identity/protocol material in
  its release-audited Lab paths; do not add a private SDK, vendor source/assets,
  production claim, commercial workflow, or automatic enablement.
- Do not map App Server-only Skill/Cancel actions onto joystick directions.
- Never flash hardware automatically. Building is allowed; writing firmware
  requires a recovery preflight and a fresh, explicit confirmation immediately
  before the write.
- Never patch a dirty upstream QMK worktree. A build script must restore every
  touched upstream file on success, failure, and interruption.
- Do not call a compile-only result hardware-verified.
- Do not commit `node_modules`, `dist`, `build`, `.build`, firmware binaries,
  local paths, screenshots, logs, research reports, or agent handoff notes.

## Adding a keyboard

A board is not supported until one change set includes all of the following:

- exact model and PCB revision, MCU, bootloader, QMK target, and recovery path;
- a pinned upstream repository and commit;
- profile, layout hash, matrix and LED mapping, and transport identity;
- reversible firmware integration and a build-only script;
- host registry/runtime changes for the new profile;
- Node, Swift, firmware, and release-audit tests;
- CI coverage and documented physical acceptance evidence.

Keep the board's normal unbound key behavior intact. Preserve the three-second
fail-open/watchdog behavior unless a documented design change replaces it.

## Required verification

Run the checks relevant to the files changed:

```bash
npm ci
npm run check
./scripts/check-codex-app-server.sh
swift test --package-path apps/ArkeyMac
./scripts/build-macos-app.sh
codesign --verify --deep --strict --verbose=2 build/Arkey.app
```

For firmware changes, also run the board's pinned build script and confirm the
upstream QMK worktree is clean afterward. Report which checks ran, which were
skipped, and whether hardware was physically tested.
