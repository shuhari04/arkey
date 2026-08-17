# Keychron Q6 Pro and V1 Max example firmware

The repository provides source-first examples for **Keychron Q6 Pro ANSI Knob**
and **Keychron V1 Max ANSI Knob**.
It does not include an opaque precompiled binary and no script flashes a device.

## Pinned target

| Field | Expected value |
| --- | --- |
| Upstream | `https://github.com/Keychron/qmk_firmware` |
| Commit | `618127a725a1773e85f13455602cf6f72ab4de17` |
| QMK target | `keychron/q6_pro/ansi_encoder` |
| Keymap | `via` |
| MCU | STM32L432 |
| Bootloader | STM32 DFU |
| Existing keyboard USB identity | Keychron `3434:0660` |
| Raw HID usage | `FF60:0061` |

## V1 Max ANSI Knob pinned target

| Field | Expected value |
| --- | --- |
| Upstream | `https://github.com/Keychron/qmk_firmware` |
| Commit | `bc1bdeb85f39cccd5e503f4d8f472078a8c1472a` |
| QMK target | `keychron/v1_max/ansi_encoder` |
| Keymap | `keychron` |
| MCU | STM32F401 |
| Bootloader | STM32 DFU |
| Existing keyboard USB identity | Keychron `3434:0913` |
| Raw HID usage | standard `FF60:0061`; Lab `FF00:0061` |

The V1 standard build uses `ARKEY_QMK_HOME` and `scripts/build-v1-max-ansi.sh`.
The isolated Lab build uses `QMK_HOME` and
`scripts/build-codex-micro-lab-v1-max.sh --acknowledge-device-identity-test`.
Both scripts refuse a dirty or wrong-revision Keychron checkout and restore all
upstream files they change. The Lab script only compiles; it never flashes.

Arkey keeps the keyboard's existing identity. It does not substitute another
vendor's VID, PID, descriptor, or private device protocol. Provenance and
license details are recorded in `firmware/UPSTREAM.md`.

## Prepare a clean QMK tree

Install Node 20+, Git, Python, the QMK CLI, the ARM embedded toolchain, and
`dfu-util`. A Python virtual environment avoids modifying the system Python:

```bash
python3 -m venv .venv-qmk
. .venv-qmk/bin/activate
python -m pip install --upgrade pip qmk

git clone --filter=blob:none --no-checkout \
  https://github.com/Keychron/qmk_firmware.git qmk_firmware
git -C qmk_firmware checkout 618127a725a1773e85f13455602cf6f72ab4de17
git -C qmk_firmware submodule update --init --recursive
python -m pip install -r qmk_firmware/requirements.txt
qmk config user.qmk_home="$PWD/qmk_firmware"
```

Follow QMK's platform setup guide for the compiler packages on your operating
system: <https://docs.qmk.fm/newbs_getting_started>

## Build only

From the Arkey repository:

```bash
npm ci
QMK_HOME="$PWD/qmk_firmware" ./scripts/build-q6-pro.sh
shasum -a 256 build/arkey-q6-pro-ansi-v0.1.0.bin
git -C qmk_firmware status --short
```

The script verifies the exact commit and target metadata, checks the generated
profile contract, refuses dirty upstream files, copies the Arkey module, applies
the small patch, compiles, and restores every touched QMK file through a trap.
The final status command should print nothing. The output binary is intentionally
ignored by Git.

## Flashing preflight

Do not flash until every item is true:

- the label and PCB revision match Q6 Pro ANSI Knob;
- the original VIA layout has been exported;
- a matching official recovery image and its instructions are available
  offline;
- another keyboard is available for recovery work;
- the build completed at the pinned commit and its SHA-256 was recorded;
- `dfu-util -l` shows the expected STM32 DFU device `0483:df11` and alt setting
  `0` after using Keychron's documented bootloader procedure;
- the user has explicitly approved writing this exact binary to this exact
  device immediately before the command.

The repository never runs the following command. An experienced developer may
use it only after the preflight confirms the target and memory layout:

```bash
arkey stop
dfu-util -l
dfu-util -a 0 -d 0483:df11 \
  -s 0x08000000:leave \
  -D build/arkey-q6-pro-ansi-v0.1.0.bin
```

If any identifier, alt setting, board revision, or recovery fact differs, stop.
Do not guess and do not bypass the build script's metadata guard.

## Physical acceptance checklist

After a deliberate flash, verify before calling the firmware supported:

1. Ordinary input on every layer, modifiers, media keys, and encoder behavior.
2. VIA detection, saved layout, and USB reconnect.
3. `arkey start`, `arkey status`, and `arkey test` over USB.
4. Per-key binding and unbinding without changing unbound key output.
5. Thinking, tool, streaming, complete, error, task, and voice effects.
6. Stopping the daemon, unplugging USB, and the three-second watchdog restore
   the previous RGB state.
7. Bluetooth continues as ordinary keyboard input. Full Arkey control is USB
   only in the reference profile.
8. The matching official recovery image can be restored.

The initial repository release is compile-verified. Treat physical flashing and
the checklist above as downstream developer acceptance until evidence for a
specific hardware revision is published.

V1 Max ANSI Knob Lab v0.1.9 has a narrow self-owned-hardware USB acceptance for
this release. That confirmation does not apply to a different PCB revision,
wireless mode, another Desktop version, or ordinary/third-party firmware.

The 2026-07-17 release check at the pinned commit produced a 67,428-byte binary
with SHA-256
`1f2b640c2c5a6160c26fca573e65a5397fb7d581bb9063957354c9c0a561c626`.
The DFU suffix validated, and the upstream QMK worktree was clean before and
after the build. This hash records a compile-only local build; reproduce it in
your own toolchain and do not treat it as physical-hardware acceptance.
