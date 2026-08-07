#!/bin/bash
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_SOURCE=${1:-"$ROOT_DIR/.build/native-wrapper/OpenWithObsidian.app"}
APP_TARGET="/Applications/OpenWithObsidian.app"
STAGED_TARGET="/Applications/.OpenWithObsidian.app.new"

if [ "$APP_SOURCE" != "$ROOT_DIR/.build/native-wrapper/OpenWithObsidian.app" ]; then
  echo "ERROR: install only accepts the repository build output: $ROOT_DIR/.build/native-wrapper/OpenWithObsidian.app" >&2
  exit 1
fi

if [ ! -d "$APP_SOURCE" ]; then
  echo "ERROR: app does not exist: $APP_SOURCE" >&2
  echo "Run ./scripts/setup-open-with-obsidian.sh first." >&2
  exit 1
fi

command -v plutil >/dev/null 2>&1 || { echo "ERROR: plutil is required." >&2; exit 1; }
command -v codesign >/dev/null 2>&1 || { echo "ERROR: codesign is required." >&2; exit 1; }
command -v lipo >/dev/null 2>&1 || { echo "ERROR: lipo is required." >&2; exit 1; }
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw -o - "$APP_SOURCE/Contents/Info.plist")
BUNDLE_EXECUTABLE=$(plutil -extract CFBundleExecutable raw -o - "$APP_SOURCE/Contents/Info.plist")
[ "$BUNDLE_ID" = "com.openwithobsidian.app" ] || { echo "ERROR: unexpected bundle identifier: $BUNDLE_ID" >&2; exit 1; }
[ "$BUNDLE_EXECUTABLE" = "OpenWithObsidian" ] || { echo "ERROR: unexpected bundle executable: $BUNDLE_EXECUTABLE" >&2; exit 1; }
codesign --verify --deep --strict "$APP_SOURCE"
ARCHES=$(lipo -archs "$APP_SOURCE/Contents/MacOS/OpenWithObsidian")
case " $ARCHES " in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) echo "ERROR: wrapper must contain arm64 and x86_64: $ARCHES" >&2; exit 1 ;;
esac

rm -rf "$STAGED_TARGET"
ditto "$APP_SOURCE" "$STAGED_TARGET"

if [ -e "$APP_TARGET" ]; then
  BACKUP="$APP_TARGET.previous.$(date +%Y%m%d%H%M%S)"
  mv "$APP_TARGET" "$BACKUP"
  printf '%s\n' "Previous app moved to: $BACKUP"
fi

mv "$STAGED_TARGET" "$APP_TARGET"

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict "$APP_TARGET"
fi

printf '%s\n' "Installed: $APP_TARGET"
printf '%s\n' "Register extensions with: duti -s com.openwithobsidian.app md all"
printf '%s\n' "Register extensions with: duti -s com.openwithobsidian.app markdown all"
