#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TARGET=${ARKEY_RELEASE_TARGET:?Set ARKEY_RELEASE_TARGET to the SSH host alias.}
SIGNING_KEY=${ARKEY_RELEASE_SIGNING_KEY:?Set ARKEY_RELEASE_SIGNING_KEY to the local Ed25519 private key path.}
REMOTE_ROOT=${ARKEY_RELEASE_ROOT:?Set ARKEY_RELEASE_ROOT to the remote release root.}
BASE_URL=${ARKEY_RELEASE_BASE_URL:?Set ARKEY_RELEASE_BASE_URL to the HTTPS release origin, without a trailing slash.}
VERSION=""
DMG=""
FIRMWARE=""
NOTE=""

usage() {
  echo "usage: $0 --version <version> --dmg <ARkey.dmg> [--firmware name[,name]] [--note text]" >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) VERSION=${2-}; shift 2 ;;
    --dmg) DMG=${2-}; shift 2 ;;
    --firmware) FIRMWARE=${2-}; shift 2 ;;
    --note) NOTE=${2-}; shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$VERSION" ] && [ -f "$DMG" ] && [ -f "$SIGNING_KEY" ] || usage
case "$VERSION" in *[!0-9A-Za-z._-]*|'') echo "Invalid release version" >&2; exit 64 ;; esac

TMPDIR=$(mktemp -d /private/tmp/arkey-release.XXXXXX)
cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

FILENAME="ARkey-${VERSION}.dmg"
REMOTE_RELEASE="$REMOTE_ROOT/releases/$VERSION"
# A fixed, non-public staging path lets rsync safely resume a large DMG after
# an interrupted network transfer. It is never served or linked as `current`.
REMOTE_STAGE="$REMOTE_ROOT/.incoming/$VERSION.upload"
REMOTE_DMG="$REMOTE_STAGE/$FILENAME"
DMG_URL="$BASE_URL/releases/$VERSION/$FILENAME"
LOCAL_SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
LOCAL_SIZE=$(stat -f '%z' "$DMG")

echo "Checking SSH target and immutable release path…"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TARGET" "test ! -e '$REMOTE_RELEASE'; install -d -m 0755 '$REMOTE_ROOT/.incoming' '$REMOTE_STAGE/v1'"

if ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TARGET" "test -f '$REMOTE_ROOT/current/v1/releases.json'"; then
  scp -q "$TARGET:$REMOTE_ROOT/current/v1/releases.json" "$TMPDIR/existing-releases.json"
fi

echo "Uploading and checking ${FILENAME} (resumable)…"
# macOS ships rsync 2.6, which lacks --append-verify. The final remote SHA-256
# comparison below is mandatory, so a bad resumed suffix is rejected before
# anything can become public.
rsync -a --partial --append "$DMG" "$TARGET:$REMOTE_STAGE/.${FILENAME}.upload"
REMOTE_SHA=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TARGET" "shasum -a 256 '$REMOTE_STAGE/.${FILENAME}.upload' | awk '{print \$1}'")
[ "$LOCAL_SHA" = "$REMOTE_SHA" ] || { echo "Remote DMG checksum mismatch" >&2; exit 1; }
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TARGET" "mv '$REMOTE_STAGE/.${FILENAME}.upload' '$REMOTE_DMG'; chmod 0444 '$REMOTE_DMG'"

if [ -f "$TMPDIR/existing-releases.json" ]; then
  if [ -n "$FIRMWARE" ] && [ -n "$NOTE" ]; then
    node "$ROOT/scripts/build-release-manifest.mjs" --version "$VERSION" --dmg-url "$DMG_URL" --sha256 "$LOCAL_SHA" --size "$LOCAL_SIZE" --payload-out "$TMPDIR/payload.json" --existing "$TMPDIR/existing-releases.json" --firmware "$FIRMWARE" --note "$NOTE"
  elif [ -n "$FIRMWARE" ]; then
    node "$ROOT/scripts/build-release-manifest.mjs" --version "$VERSION" --dmg-url "$DMG_URL" --sha256 "$LOCAL_SHA" --size "$LOCAL_SIZE" --payload-out "$TMPDIR/payload.json" --existing "$TMPDIR/existing-releases.json" --firmware "$FIRMWARE"
  elif [ -n "$NOTE" ]; then
    node "$ROOT/scripts/build-release-manifest.mjs" --version "$VERSION" --dmg-url "$DMG_URL" --sha256 "$LOCAL_SHA" --size "$LOCAL_SIZE" --payload-out "$TMPDIR/payload.json" --existing "$TMPDIR/existing-releases.json" --note "$NOTE"
  else
    node "$ROOT/scripts/build-release-manifest.mjs" --version "$VERSION" --dmg-url "$DMG_URL" --sha256 "$LOCAL_SHA" --size "$LOCAL_SIZE" --payload-out "$TMPDIR/payload.json" --existing "$TMPDIR/existing-releases.json"
  fi
else
  if [ -n "$FIRMWARE" ] && [ -n "$NOTE" ]; then
    node "$ROOT/scripts/build-release-manifest.mjs" --version "$VERSION" --dmg-url "$DMG_URL" --sha256 "$LOCAL_SHA" --size "$LOCAL_SIZE" --payload-out "$TMPDIR/payload.json" --firmware "$FIRMWARE" --note "$NOTE"
  elif [ -n "$FIRMWARE" ]; then
    node "$ROOT/scripts/build-release-manifest.mjs" --version "$VERSION" --dmg-url "$DMG_URL" --sha256 "$LOCAL_SHA" --size "$LOCAL_SIZE" --payload-out "$TMPDIR/payload.json" --firmware "$FIRMWARE"
  elif [ -n "$NOTE" ]; then
    node "$ROOT/scripts/build-release-manifest.mjs" --version "$VERSION" --dmg-url "$DMG_URL" --sha256 "$LOCAL_SHA" --size "$LOCAL_SIZE" --payload-out "$TMPDIR/payload.json" --note "$NOTE"
  else
    node "$ROOT/scripts/build-release-manifest.mjs" --version "$VERSION" --dmg-url "$DMG_URL" --sha256 "$LOCAL_SHA" --size "$LOCAL_SIZE" --payload-out "$TMPDIR/payload.json"
  fi
fi

openssl pkeyutl -sign -rawin -inkey "$SIGNING_KEY" -in "$TMPDIR/payload.json" -out "$TMPDIR/signature.bin"
node "$ROOT/scripts/seal-release-manifest.mjs" "$TMPDIR/payload.json" "$TMPDIR/signature.bin" "$TMPDIR/releases.json"

scp -q "$TMPDIR/releases.json" "$TARGET:$REMOTE_STAGE/v1/.releases.json.upload"
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$TARGET" "mv '$REMOTE_STAGE/v1/.releases.json.upload' '$REMOTE_STAGE/v1/releases.json'; chmod 0444 '$REMOTE_STAGE/v1/releases.json'; test ! -e '$REMOTE_RELEASE'; mv '$REMOTE_STAGE' '$REMOTE_RELEASE'; ln -sfnT '$REMOTE_RELEASE' '$REMOTE_ROOT/current'; test -f '$REMOTE_ROOT/current/v1/releases.json'"
echo "Published ARkey $VERSION"
