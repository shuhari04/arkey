#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
QMK_HOME=${QMK_HOME:?Set QMK_HOME to the pinned Keychron QMK checkout.}
TARGET="$QMK_HOME/keyboards/keychron/v1_max"
EXPECTED_QMK_COMMIT=bc1bdeb85f39cccd5e503f4d8f472078a8c1472a

if [ "${1:-}" != "--acknowledge-device-identity-test" ]; then
  echo "This lab build presents the local Codex Micro test USB identity." >&2
  echo "Build only for a keyboard you own and local interoperability testing." >&2
  exit 2
fi

[ -d "$TARGET" ] || { echo "V1 Max source not found under QMK_HOME=$QMK_HOME" >&2; exit 1; }
git -C "$QMK_HOME" diff --quiet || { echo "Refusing a dirty QMK checkout." >&2; exit 1; }
[ "$(git -C "$QMK_HOME" rev-parse HEAD)" = "$EXPECTED_QMK_COMMIT" ] || { echo "Unexpected QMK revision." >&2; exit 1; }

for file in \
  keyboards/keychron/v1_max/v1_max.c \
  keyboards/keychron/v1_max/rules.mk \
  keyboards/keychron/v1_max/info.json \
  keyboards/keychron/v1_max/ansi_encoder/keyboard.json \
  keyboards/keychron/common/keychron_raw_hid.c \
  tmk_core/protocol/usb_descriptor.h \
  tmk_core/protocol/usb_descriptor_common.h \
  tmk_core/protocol/usb_descriptor.c \
  quantum/encoder.h quantum/encoder.c; do
  git -C "$QMK_HOME" diff --quiet -- "$file" || { echo "Refusing dirty QMK file: $file" >&2; exit 1; }
done

cleanup() {
  git -C "$QMK_HOME" restore -- \
    keyboards/keychron/v1_max/v1_max.c keyboards/keychron/v1_max/rules.mk \
    keyboards/keychron/v1_max/info.json keyboards/keychron/v1_max/ansi_encoder/keyboard.json \
    keyboards/keychron/common/keychron_raw_hid.c tmk_core/protocol/usb_descriptor.h \
    tmk_core/protocol/usb_descriptor_common.h tmk_core/protocol/usb_descriptor.c quantum/encoder.h quantum/encoder.c
  rm -f "$TARGET/codex_micro_lab.c" "$TARGET/codex_micro_lab.h"
}
trap cleanup EXIT INT TERM

cp "$ROOT/firmware/qmk/codex_micro_lab.c" "$TARGET/codex_micro_lab.c"
cp "$ROOT/firmware/qmk/codex_micro_lab.h" "$TARGET/codex_micro_lab.h"
git -C "$QMK_HOME" apply "$ROOT/firmware/codex-micro-lab-v1-max.patch"
git -C "$QMK_HOME" apply "$ROOT/firmware/codex-micro-lab-v1-max-hid.patch"
git -C "$QMK_HOME" apply "$ROOT/firmware/codex-micro-lab-v1-max-encoder.patch"
make -C "$QMK_HOME" keychron/v1_max/ansi_encoder:keychron
mkdir -p "$ROOT/build"
OUTPUT="$ROOT/build/arkey-v1-max-codex-micro-lab-v0.1.9.bin"
cp "$QMK_HOME/keychron_v1_max_ansi_encoder_keychron.bin" "$OUTPUT"
dfu-suffix -c "$OUTPUT"
echo "Built: $OUTPUT"
