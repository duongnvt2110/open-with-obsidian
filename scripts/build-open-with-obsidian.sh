#!/bin/bash
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR="$ROOT_DIR/.build/native-wrapper"
APP_PATH="$BUILD_DIR/OpenWithObsidian.app"
SWIFT_DIR="$ROOT_DIR/src/swift"
WRAPPER_BINARY="$ROOT_DIR/src/OpenWithObsidian"
WRAPPER_PLIST="$ROOT_DIR/src/OpenWithObsidian.plist"
SCRATCH_TEMPLATE="$ROOT_DIR/src/scratch-vault-template"

if [ ! -f "$WRAPPER_PLIST" ] || [ ! -d "$SCRATCH_TEMPLATE" ]; then
  echo "ERROR: native wrapper resources are incomplete." >&2
  exit 1
fi

DEVELOPER_DIR_VALUE=""

BIN_PATH=""
if [ "${OPEN_WITH_OBSIDIAN_USE_PREBUILT:-0}" != "1" ]; then
  DEVELOPER_DIR_VALUE=$($ROOT_DIR/scripts/resolve-xcode.sh)
  export DEVELOPER_DIR="$DEVELOPER_DIR_VALUE"
  SWIFT_BIN=$(xcrun --find swift)
  LIPO_BIN=$(xcrun --find lipo)
  ARM_BUILD_DIR="$BUILD_DIR/swift-arm64"
  INTEL_BUILD_DIR="$BUILD_DIR/swift-x86_64"
  echo "==> swift build (arm64) using $DEVELOPER_DIR"
  "$SWIFT_BIN" build -c release --package-path "$SWIFT_DIR" \
    --build-path "$ARM_BUILD_DIR" \
    -Xswiftc -target -Xswiftc arm64-apple-macosx13.0
  echo "==> swift build (x86_64) using $DEVELOPER_DIR"
  "$SWIFT_BIN" build -c release --package-path "$SWIFT_DIR" \
    --build-path "$INTEL_BUILD_DIR" \
    -Xswiftc -target -Xswiftc x86_64-apple-macosx13.0
  ARM_BIN="$ARM_BUILD_DIR/release/OpenWithObsidian"
  INTEL_BIN="$INTEL_BUILD_DIR/release/OpenWithObsidian"
  BIN_PATH="$BUILD_DIR/OpenWithObsidian-universal"
  "$LIPO_BIN" -create "$ARM_BIN" "$INTEL_BIN" -output "$BIN_PATH"
  cp "$BIN_PATH" "$WRAPPER_BINARY"
  chmod 755 "$WRAPPER_BINARY"
  shasum -a 256 "$WRAPPER_BINARY" | sed 's#  .*#  OpenWithObsidian#' > "$ROOT_DIR/src/OpenWithObsidian.sha256"
elif [ "${OPEN_WITH_OBSIDIAN_USE_PREBUILT:-0}" = "1" ]; then
  echo "==> using repository prebuilt Swift wrapper"
  (CDPATH= cd -- "$ROOT_DIR/src" && shasum -a 256 -c OpenWithObsidian.sha256 >/dev/null) || {
    echo "ERROR: prebuilt Swift wrapper hash does not match src/OpenWithObsidian.sha256" >&2
    exit 1
  }
  BIN_PATH="$WRAPPER_BINARY"
else
  echo "ERROR: unreachable build mode." >&2
  exit 1
fi

if [ ! -f "$BIN_PATH" ]; then
  echo "ERROR: built binary not found: $BIN_PATH" >&2
  exit 1
fi

echo "==> assembling $APP_PATH"
mkdir -p "$BUILD_DIR"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/OpenWithObsidian"
cp "$WRAPPER_PLIST" "$APP_PATH/Contents/Info.plist"
cp -R "$SCRATCH_TEMPLATE" "$APP_PATH/Contents/Resources/"
chmod 755 "$APP_PATH/Contents/MacOS/OpenWithObsidian"
plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null

codesign --force --deep --sign - "$APP_PATH" >/dev/null
codesign --verify --deep --strict "$APP_PATH"

printf '%s\n' "Built: $APP_PATH"
