#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
LAB="$ROOT/build/arkey-v1-max-codex-micro-lab-v0.1.9.bin"
ARKEY="$ROOT/build/arkey-v1-max-ansi-knob-v0.1.0.bin"
OFFICIAL=${ARKEY_OFFICIAL_V1_FIRMWARE:?Set ARKEY_OFFICIAL_V1_FIRMWARE to a locally verified Keychron V1 Max ANSI Knob v1.1.1 recovery .bin.}
DFU_UTIL=${ARKEY_DFU_UTIL:-$(command -v dfu-util || true)}
LIBUSB_DYLIB=${ARKEY_LIBUSB_DYLIB:-}
VERSION="${ARKEY_FIRMWARE_UTILITY_VERSION:-3.0.3}"
OUT="$ROOT/build/ARkey-V1-Max-Standalone-Flasher-${VERSION}.dmg"
STAGE=$(mktemp -d /private/tmp/arkey-v1max-firmware.XXXXXX)

[ -f "$LAB" ] && [ -f "$ARKEY" ] && [ -f "$OFFICIAL" ] || { echo "Firmware missing." >&2; exit 1; }
[ -n "$DFU_UTIL" ] && [ -f "$DFU_UTIL" ] || { echo "Set ARKEY_DFU_UTIL to a packaged dfu-util binary." >&2; exit 1; }
if [ -z "$LIBUSB_DYLIB" ]; then
  LIBUSB_DYLIB=$(otool -L "$DFU_UTIL" | awk '/libusb-1\.0.*dylib/ { print $1; exit }')
fi
[ -f "$LIBUSB_DYLIB" ] || { echo "Set ARKEY_LIBUSB_DYLIB to dfu-util's libusb-1.0 dylib." >&2; exit 1; }
mkdir -p "$STAGE/Firmware" "$STAGE/Tools"
xcrun swiftc "$ROOT/scripts/v1max-hid-probe.swift" -framework IOKit -framework CoreFoundation -o "$STAGE/Tools/arkey-v1max-hid-probe"
cp "$LAB" "$STAGE/Firmware/arkey-v1-max-codex-micro-lab-v0.1.9.bin"
cp "$ARKEY" "$STAGE/Firmware/arkey-v1-max-ansi-knob-v0.1.0.bin"
cp "$OFFICIAL" "$STAGE/Firmware/keychron-v1-max-ansi-knob-v1.1.1.bin"
cp "$DFU_UTIL" "$STAGE/Tools/dfu-util"
cp "$LIBUSB_DYLIB" "$STAGE/Tools/libusb-1.0.0.dylib"
install_name_tool -change "$LIBUSB_DYLIB" @executable_path/libusb-1.0.0.dylib "$STAGE/Tools/dfu-util"
codesign --force --sign - "$STAGE/Tools/dfu-util" "$STAGE/Tools/libusb-1.0.0.dylib"
codesign --force --sign - "$STAGE/Tools/arkey-v1max-hid-probe"
cp "$ROOT/scripts/v1max-firmware-utility.command" "$STAGE/ARkey V1 Max Standalone Flasher.command"
chmod +x "$STAGE/ARkey V1 Max Standalone Flasher.command"
hdiutil create -volname "ARkey V1 Max Standalone Flasher" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
echo "Built: $OUT"
