#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
QMK_HOME=${QMK_HOME:-$(qmk config user.qmk_home 2>/dev/null | sed 's/^user.qmk_home=//')}
TARGET="$QMK_HOME/keyboards/keychron/q6_pro"
EXPECTED_QMK_COMMIT=618127a725a1773e85f13455602cf6f72ab4de17

if [ "${1:-}" != "--acknowledge-device-identity-test" ]; then
  echo "This laboratory build temporarily reports the Codex Micro USB identity." >&2
  echo "Build it only for a keyboard you own and local interoperability testing." >&2
  echo "Usage: $0 --acknowledge-device-identity-test" >&2
  exit 2
fi

if [ ! -d "$TARGET" ]; then
  echo "Keychron q6_pro source not found under QMK_HOME=$QMK_HOME" >&2
  exit 1
fi

grep -q '"processor": "STM32L432"' "$TARGET/info.json" &&
grep -q '"bootloader": "stm32-dfu"' "$TARGET/info.json" &&
grep -q '"vid": "0x3434"' "$TARGET/info.json" &&
grep -q '"pid": "0x0660"' "$TARGET/ansi_encoder/info.json" || {
  echo "Refusing unexpected target; expected stock Q6 Pro ANSI Knob 3434:0660." >&2
  exit 1
}

ACTUAL_QMK_COMMIT=$(git -C "$QMK_HOME" rev-parse HEAD)
if [ "$ACTUAL_QMK_COMMIT" != "$EXPECTED_QMK_COMMIT" ] && [ "${ARKEY_ALLOW_UNTESTED_QMK:-0}" != "1" ]; then
  echo "Refusing untested Keychron source commit: $ACTUAL_QMK_COMMIT" >&2
  echo "Expected: $EXPECTED_QMK_COMMIT" >&2
  exit 1
fi

PATCHED_FILES="
keyboards/keychron/q6_pro/q6_pro.c
keyboards/keychron/q6_pro/rules.mk
keyboards/keychron/q6_pro/info.json
keyboards/keychron/q6_pro/ansi_encoder/info.json
tmk_core/protocol/usb_descriptor.h
tmk_core/protocol/usb_descriptor_common.h
tmk_core/protocol/usb_descriptor.c
quantum/encoder.h
quantum/encoder.c
"

for file in $PATCHED_FILES; do
  git -C "$QMK_HOME" diff --quiet HEAD -- "$file" || {
    echo "Refusing to alter dirty QMK file: $file" >&2
    exit 1
  }
done

for file in codex_micro_lab.c codex_micro_lab.h; do
  if [ -e "$TARGET/$file" ]; then
    echo "Refusing to overwrite existing QMK file: keyboards/keychron/q6_pro/$file" >&2
    exit 1
  fi
done

BACKUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/arkey-codex-micro-lab.XXXXXX")
index=0
for file in $PATCHED_FILES; do
  index=$((index + 1))
  cp -f "$QMK_HOME/$file" "$BACKUP_DIR/$index"
done

restore_qmk() {
  index=0
  for file in $PATCHED_FILES; do
    index=$((index + 1))
    cp -f "$BACKUP_DIR/$index" "$QMK_HOME/$file"
  done
  find "$BACKUP_DIR" -type f -delete 2>/dev/null || true
  rmdir "$BACKUP_DIR" 2>/dev/null || true
  find "$TARGET" -maxdepth 1 -type f \( -name 'codex_micro_lab.c' -o -name 'codex_micro_lab.h' \) -delete
}
trap restore_qmk EXIT INT TERM

cp -f "$ROOT/firmware/qmk/codex_micro_lab.c" "$TARGET/codex_micro_lab.c"
cp -f "$ROOT/firmware/qmk/codex_micro_lab.h" "$TARGET/codex_micro_lab.h"
git -C "$QMK_HOME" apply "$ROOT/firmware/codex-micro-lab-q6-pro.patch"
git -C "$QMK_HOME" apply "$ROOT/firmware/codex-micro-lab-qmk-hid.patch"
git -C "$QMK_HOME" apply "$ROOT/firmware/codex-micro-lab-qmk-encoder.patch"

PATH="/opt/homebrew/opt/arm-none-eabi-gcc@8/bin:/opt/homebrew/opt/arm-none-eabi-binutils/bin:$PATH" \
  qmk compile -kb keychron/q6_pro/ansi_encoder -km via

mkdir -p "$ROOT/build"
OUTPUT="$ROOT/build/arkey-q6-pro-codex-micro-lab-v0.1.5.bin"
cp -f "$QMK_HOME/keychron_q6_pro_ansi_encoder_via.bin" "$OUTPUT"
if command -v dfu-suffix >/dev/null 2>&1; then
  dfu-suffix -c "$OUTPUT"
else
  echo "Warning: dfu-suffix unavailable; compiler succeeded but suffix was not independently checked." >&2
fi

echo "Built: $OUTPUT"
echo "This script did not flash the keyboard. Configure mappings after flashing with:"
echo "  node $ROOT/scripts/codex-micro-lab-config.mjs configure"
