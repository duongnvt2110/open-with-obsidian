#!/bin/bash
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEVELOPER_DIR_VALUE=$($ROOT_DIR/scripts/resolve-xcode.sh)
export DEVELOPER_DIR="$DEVELOPER_DIR_VALUE"
SWIFT_BIN=$(xcrun --find swift)
exec "$SWIFT_BIN" test -c release --package-path "$ROOT_DIR/src/swift"
