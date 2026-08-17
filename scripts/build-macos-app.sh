#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PACKAGE="$ROOT/apps/ArkeyMac"
APP="$ROOT/build/Arkey.app"
VERSION="${ARKEY_APP_VERSION:-3.0.3}"
BUILD="${ARKEY_APP_BUILD:-22}"
npm --prefix "$ROOT" run build
BIN_DIR=$(swift build --package-path "$PACKAGE" -c release --show-bin-path)

swift build --package-path "$PACKAGE" -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ArkeyMac" "$APP/Contents/MacOS/ArkeyMac"
RESOURCE_BUNDLE="$BIN_DIR/ArkeyMac_ArkeyMac.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "Missing Swift package resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
cp "$PACKAGE/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$APP/Contents/Info.plist"
cp "$PACKAGE/Resources/Arkey.icns" "$APP/Contents/Resources/Arkey.icns"
cp "$ROOT/profiles/keychron-q6-pro-ansi.json" "$APP/Contents/Resources/keychron-q6-pro-ansi.json"
cp "$ROOT/profiles/keychron-v1-max-ansi-knob.json" "$APP/Contents/Resources/keychron-v1-max-ansi-knob.json"
if [ -f "$ROOT/profiles/effects-v1.json" ]; then
    cp "$ROOT/profiles/effects-v1.json" "$APP/Contents/Resources/effects-v1.json"
fi
mkdir -p "$APP/Contents/Resources/ArkeyRuntime"
cp -R "$ROOT/dist" "$APP/Contents/Resources/ArkeyRuntime/dist"
cp -R "$ROOT/profiles" "$APP/Contents/Resources/ArkeyRuntime/profiles"
cp -R "$ROOT/docs" "$APP/Contents/Resources/ArkeyRuntime/docs"
if [ -f "$ROOT/build/arkey-q6-pro-ansi-v0.1.0.bin" ]; then
    mkdir -p "$APP/Contents/Resources/ArkeyRuntime/build"
    cp "$ROOT/build/arkey-q6-pro-ansi-v0.1.0.bin" "$APP/Contents/Resources/ArkeyRuntime/build/"
fi
if [ -f "$ROOT/build/arkey-q6-pro-codex-micro-lab-v0.1.5.bin" ]; then
    mkdir -p "$APP/Contents/Resources/ArkeyRuntime/build"
    cp "$ROOT/build/arkey-q6-pro-codex-micro-lab-v0.1.5.bin" "$APP/Contents/Resources/ArkeyRuntime/build/"
fi
cp -R "$ROOT/node_modules" "$APP/Contents/Resources/ArkeyRuntime/node_modules"
cp "$ROOT/package.json" "$APP/Contents/Resources/ArkeyRuntime/package.json"
codesign --deep --force --sign - "$APP"
echo "Built: $APP"
