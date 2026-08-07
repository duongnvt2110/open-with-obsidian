#!/bin/bash
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLUGIN_SOURCE="$ROOT_DIR/src"
PLUGIN_TARGET="$HOME/Library/Application Support/OpenWithObsidian/ScratchVault/.obsidian/plugins/obsidian-scratch-cleanup"
APP_PATH="$ROOT_DIR/.build/native-wrapper/OpenWithObsidian.app"

mkdir -p "$PLUGIN_TARGET"
PLUGIN_BUNDLE=$($ROOT_DIR/scripts/build-plugin.sh)
rm -f "$PLUGIN_TARGET/reconcile.js" "$PLUGIN_TARGET/cleanup.js"
rm -f "$ROOT_DIR/src/scratch-vault-template/.obsidian/plugins/obsidian-scratch-cleanup/reconcile.js" \
  "$ROOT_DIR/src/scratch-vault-template/.obsidian/plugins/obsidian-scratch-cleanup/cleanup.js"
cp "$PLUGIN_BUNDLE" "$PLUGIN_SOURCE/manifest.json" "$PLUGIN_TARGET/"
cp "$PLUGIN_BUNDLE" "$PLUGIN_SOURCE/manifest.json" \
  "$ROOT_DIR/src/scratch-vault-template/.obsidian/plugins/obsidian-scratch-cleanup/"

if [ "${OPEN_WITH_OBSIDIAN_BUILD_APP:-1}" = "1" ]; then
  "$ROOT_DIR/scripts/build-open-with-obsidian.sh"
  printf '%s\n' "Built app: $APP_PATH"
  printf '%s\n' "Install with: '$ROOT_DIR/scripts/install-open-with-obsidian.sh' '$APP_PATH'"
else
  printf '%s\n' "Native app build skipped (OPEN_WITH_OBSIDIAN_BUILD_APP=0)."
fi

printf '%s\n' "Installed repository-owned Scratch Cleanup plugin: $PLUGIN_TARGET"
