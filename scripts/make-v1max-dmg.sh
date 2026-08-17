#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
FIRMWARE="$ROOT/build/arkey-v1-max-ansi-knob-v0.1.0.bin"
LAB_FIRMWARE="$ROOT/build/arkey-v1-max-codex-micro-lab-v0.1.9.bin"
Q6_LAB_FIRMWARE="$ROOT/build/arkey-q6-pro-codex-micro-lab-v0.1.5.bin"
OFFICIAL=${ARKEY_OFFICIAL_V1_FIRMWARE:?Set ARKEY_OFFICIAL_V1_FIRMWARE to a locally verified Keychron V1 Max ANSI Knob v1.1.1 recovery .bin.}
DFU_UTIL=${ARKEY_DFU_UTIL:-$(command -v dfu-util || true)}
LIBUSB_DYLIB=${ARKEY_LIBUSB_DYLIB:-}
VERSION="${ARKEY_APP_VERSION:-3.0.3}"
BUILD="${ARKEY_APP_BUILD:-22}"
OUT="$ROOT/build/ARkey-Codex-Micro-Lab-${VERSION}.dmg"
STAGE=$(mktemp -d /private/tmp/arkey-v1max-dmg.XXXXXX)
APP="$STAGE/ARkey.app"
PACKAGE="$ROOT/apps/ArkeyMac"
NODE_VERSION="22.23.0"
NODE_ARCH="${ARKEY_NODE_ARCH:-$(uname -m)}"
NODE_NAME="node-v${NODE_VERSION}-darwin-${NODE_ARCH}"
NODE_BASE="https://nodejs.org/dist/v${NODE_VERSION}"
NODE_CACHE="$ROOT/build/deps/${NODE_NAME}.tar.gz"
[ -f "$FIRMWARE" ] && [ -f "$LAB_FIRMWARE" ] && [ -f "$Q6_LAB_FIRMWARE" ] && [ -f "$OFFICIAL" ] || { echo "Firmware missing." >&2; exit 1; }
[ -n "$DFU_UTIL" ] && [ -f "$DFU_UTIL" ] || { echo "Set ARKEY_DFU_UTIL to a packaged dfu-util binary." >&2; exit 1; }
if [ -z "$LIBUSB_DYLIB" ]; then
  LIBUSB_DYLIB=$(otool -L "$DFU_UTIL" | awk '/libusb-1\.0.*dylib/ { print $1; exit }')
fi
[ -f "$LIBUSB_DYLIB" ] || { echo "Set ARKEY_LIBUSB_DYLIB to dfu-util's libusb-1.0 dylib." >&2; exit 1; }
[ "$(shasum -a 256 "$OFFICIAL" | awk '{print $1}')" = "0727fdce9af4dfeaaa099e6a8a0c44d30da113ce770ac4bcc15c9e502c444498" ] || { echo "Official firmware hash mismatch." >&2; exit 1; }
npm --prefix "$ROOT" run build
BIN_DIR=$(swift build --package-path "$PACKAGE" -c release --show-bin-path)
swift build --package-path "$PACKAGE" -c release
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ArkeyRuntime/build"
cp "$BIN_DIR/ArkeyMac" "$APP/Contents/MacOS/ArkeyMac"
cp -R "$BIN_DIR/ArkeyMac_ArkeyMac.bundle" "$APP/Contents/Resources/"
cp "$PACKAGE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PACKAGE/Resources/Arkey.icns" "$APP/Contents/Resources/Arkey.icns"
# Keep both physical layouts distinct. The previous V1 Max copy under the Q6
# resource name was why a connected Q6 Pro lost its numeric keypad in preview.
cp "$ROOT/profiles/keychron-q6-pro-ansi.json" "$APP/Contents/Resources/keychron-q6-pro-ansi.json"
cp "$ROOT/profiles/keychron-v1-max-ansi-knob.json" "$APP/Contents/Resources/keychron-v1-max-ansi-knob.json"
plutil -replace CFBundleDisplayName -string "ARkey" "$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "ARkey" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
cp -R "$ROOT/dist" "$APP/Contents/Resources/ArkeyRuntime/dist"
cp -R "$ROOT/profiles" "$APP/Contents/Resources/ArkeyRuntime/profiles"
cp -R "$ROOT/docs" "$APP/Contents/Resources/ArkeyRuntime/docs"
cp -R "$ROOT/node_modules" "$APP/Contents/Resources/ArkeyRuntime/node_modules"
cp "$ROOT/package.json" "$APP/Contents/Resources/ArkeyRuntime/package.json"
# The app must remain usable on a clean Mac.  Do not depend on a globally
# installed Node/npm or an ARkey CLI that happens to be in the shell PATH.
mkdir -p "$(dirname "$NODE_CACHE")"
if [ ! -f "$NODE_CACHE" ]; then
  curl -fsSL "$NODE_BASE/$NODE_NAME.tar.gz" -o "$NODE_CACHE"
fi
EXPECTED_NODE_SHA=$(curl -fsSL "$NODE_BASE/SHASUMS256.txt" | awk -v name="$NODE_NAME.tar.gz" '$2 == name { print $1 }')
ACTUAL_NODE_SHA=$(shasum -a 256 "$NODE_CACHE" | awk '{print $1}')
[ -n "$EXPECTED_NODE_SHA" ] && [ "$EXPECTED_NODE_SHA" = "$ACTUAL_NODE_SHA" ] || { echo "Bundled Node checksum mismatch." >&2; exit 1; }
NODE_STAGE="$STAGE/.node"
mkdir -p "$NODE_STAGE"
tar -xzf "$NODE_CACHE" -C "$NODE_STAGE"
cp -R "$NODE_STAGE/$NODE_NAME" "$APP/Contents/Resources/ArkeyRuntime/node"
cp "$FIRMWARE" "$APP/Contents/Resources/ArkeyRuntime/build/arkey-v1-max-ansi-knob-v0.1.0.bin"

# The graphical Firmware Tool runs only these bundled components. It never
# depends on Homebrew or a shell-installed dfu-util on the user's Mac.
mkdir -p "$APP/Contents/Resources/Firmware" "$APP/Contents/Resources/FirmwareTools"
cp "$LAB_FIRMWARE" "$APP/Contents/Resources/Firmware/arkey-v1-max-codex-micro-lab-v0.1.9.bin"
cp "$Q6_LAB_FIRMWARE" "$APP/Contents/Resources/Firmware/arkey-q6-pro-codex-micro-lab-v0.1.5.bin"
cp "$DFU_UTIL" "$APP/Contents/Resources/FirmwareTools/dfu-util"
cp "$LIBUSB_DYLIB" "$APP/Contents/Resources/FirmwareTools/libusb-1.0.0.dylib"
install_name_tool -change "$LIBUSB_DYLIB" @executable_path/libusb-1.0.0.dylib "$APP/Contents/Resources/FirmwareTools/dfu-util"
codesign --force --sign - "$APP/Contents/Resources/FirmwareTools/dfu-util" "$APP/Contents/Resources/FirmwareTools/libusb-1.0.0.dylib"
codesign --deep --force --sign - "$APP"
mkdir -p "$STAGE/Firmware" "$STAGE/Tools"
xcrun swiftc "$ROOT/scripts/v1max-hid-probe.swift" -framework IOKit -framework CoreFoundation -o "$STAGE/Tools/arkey-v1max-hid-probe"
cp "$FIRMWARE" "$STAGE/Firmware/arkey-v1-max-ansi-knob-v0.1.0.bin"
cp "$LAB_FIRMWARE" "$STAGE/Firmware/arkey-v1-max-codex-micro-lab-v0.1.9.bin"
cp "$Q6_LAB_FIRMWARE" "$STAGE/Firmware/arkey-q6-pro-codex-micro-lab-v0.1.5.bin"
cp "$OFFICIAL" "$STAGE/Firmware/keychron-v1-max-ansi-knob-v1.1.1.bin"
cp "$DFU_UTIL" "$STAGE/Tools/dfu-util"
cp "$LIBUSB_DYLIB" "$STAGE/Tools/libusb-1.0.0.dylib"
install_name_tool -change "$LIBUSB_DYLIB" @executable_path/libusb-1.0.0.dylib "$STAGE/Tools/dfu-util"
codesign --force --sign - "$STAGE/Tools/dfu-util" "$STAGE/Tools/libusb-1.0.0.dylib"
codesign --force --sign - "$STAGE/Tools/arkey-v1max-hid-probe"
cp "$ROOT/scripts/v1max-firmware-utility.command" "$STAGE/ARkey V1 Max Firmware Utility.command"
chmod +x "$STAGE/ARkey V1 Max Firmware Utility.command"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ARkey Codex Micro Lab" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
codesign --verify --deep --strict "$APP"
echo "Built: $OUT"
