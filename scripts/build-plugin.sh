#!/bin/bash
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ESBUILD="$ROOT_DIR/node_modules/.bin/esbuild"
OUTPUT_DIR="$ROOT_DIR/.build/obsidian-plugin"
OUTPUT_FILE="$OUTPUT_DIR/main.js"

if [ ! -x "$ESBUILD" ]; then
  echo "ERROR: esbuild is missing. Run npm install first." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
"$ESBUILD" "$ROOT_DIR/src/main.js" \
  --bundle \
  --platform=node \
  --format=cjs \
  --external:obsidian \
  --outfile="$OUTPUT_FILE" \
  --log-level=warning
node --check "$OUTPUT_FILE"
printf '%s\n' "$OUTPUT_FILE"
