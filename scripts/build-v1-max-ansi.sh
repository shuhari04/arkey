#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
QMK_HOME=${ARKEY_QMK_HOME:?Set ARKEY_QMK_HOME to a clean Keychron QMK checkout at bc1bdeb85f39cccd5e503f4d8f472078a8c1472a}
export QMK_HOME
TARGET="$QMK_HOME/keyboards/keychron/v1_max"
EXPECTED_QMK_COMMIT=bc1bdeb85f39cccd5e503f4d8f472078a8c1472a
PROFILE="$ROOT/profiles/keychron-v1-max-ansi-knob.json"
OUTPUT="$ROOT/build/arkey-v1-max-ansi-knob-v0.1.0.bin"

[ -d "$TARGET" ] || { echo "Missing Keychron V1 Max target: $TARGET" >&2; exit 1; }
[ "$(git -C "$QMK_HOME" rev-parse HEAD)" = "$EXPECTED_QMK_COMMIT" ] || { echo "Unexpected QMK commit; refusing non-reproducible build." >&2; exit 1; }
[ -z "$(git -C "$QMK_HOME" status --porcelain)" ] || { echo "QMK checkout is dirty; refusing to patch it." >&2; exit 1; }
grep -q '"processor": "STM32F401"' "$TARGET/info.json" &&
grep -q '"bootloader": "stm32-dfu"' "$TARGET/info.json" &&
grep -q '"vid": "0x3434"' "$TARGET/info.json" &&
grep -q '"pid": "0x0913"' "$TARGET/ansi_encoder/keyboard.json" || {
  echo "Unexpected V1 Max ANSI Knob metadata; refusing build." >&2
  exit 1
}

node "$ROOT/scripts/generate-firmware-contract.mjs" --profile "$PROFILE" --output "$ROOT/firmware/qmk/arkey_v1max_generated.h"

cleanup() {
  git -C "$QMK_HOME" checkout -- keyboards/keychron/v1_max/v1_max.c keyboards/keychron/v1_max/rules.mk
  rm -f "$TARGET/arkey.c" "$TARGET/arkey.h" "$TARGET/arkey_generated.h" "$TARGET/ansi_encoder/keymaps/keychron/rgb_matrix_user.inc"
}
trap cleanup EXIT INT TERM

cp "$ROOT/firmware/qmk/arkey.c" "$TARGET/arkey.c"
cp "$ROOT/firmware/qmk/arkey.h" "$TARGET/arkey.h"
cp "$ROOT/firmware/qmk/arkey_v1max_generated.h" "$TARGET/arkey_generated.h"
cp "$ROOT/firmware/qmk/rgb_matrix_kb.inc" "$TARGET/ansi_encoder/keymaps/keychron/rgb_matrix_user.inc"
git -C "$QMK_HOME" apply "$ROOT/firmware/keychron-v1-max-ansi.patch"

PATH="/opt/homebrew/opt/arm-none-eabi-gcc@8/bin:/opt/homebrew/opt/arm-none-eabi-binutils/bin:$PATH" \
  make -C "$QMK_HOME" keychron/v1_max/ansi_encoder:keychron
mkdir -p "$ROOT/build"
cp "$QMK_HOME/keychron_v1_max_ansi_encoder_keychron.bin" "$OUTPUT"
dfu-suffix -c "$OUTPUT"
shasum -a 256 "$OUTPUT"
echo "Built: $OUTPUT"
