#!/bin/bash
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEVELOPER_DIR_VALUE="${OPEN_WITH_OBSIDIAN_DEVELOPER_DIR:-}"
if [ -z "$DEVELOPER_DIR_VALUE" ] && [ -d "$ROOT_DIR/Xcode.app/Contents/Developer" ]; then
  DEVELOPER_DIR_VALUE="$ROOT_DIR/Xcode.app/Contents/Developer"
fi
if [ -z "$DEVELOPER_DIR_VALUE" ] && [ -d "/Applications/Xcode-15.2.app/Contents/Developer" ]; then
  DEVELOPER_DIR_VALUE="/Applications/Xcode-15.2.app/Contents/Developer"
fi
if [ -z "$DEVELOPER_DIR_VALUE" ] || [ ! -d "$DEVELOPER_DIR_VALUE" ]; then
  echo "ERROR: trusted Xcode developer directory not found." >&2
  exit 1
fi

XCODE_APP=$(CDPATH= cd -- "$DEVELOPER_DIR_VALUE/../.." && pwd)
command -v codesign >/dev/null 2>&1 || {
  echo "ERROR: codesign is required to validate Xcode." >&2
  exit 1
}
codesign --verify --deep --strict "$XCODE_APP" >/dev/null 2>&1 || {
  echo "ERROR: Xcode signature validation failed: $XCODE_APP" >&2
  exit 1
}
codesign -dvvv "$XCODE_APP" 2>&1 | grep -q 'Authority=Apple' || {
  echo "ERROR: Xcode is not signed by Apple: $XCODE_APP" >&2
  exit 1
}

printf '%s\n' "$DEVELOPER_DIR_VALUE"
