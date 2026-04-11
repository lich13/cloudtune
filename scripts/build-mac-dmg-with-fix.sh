#!/bin/bash
set -euo pipefail

TARGET_TRIPLE="${1:-aarch64-apple-darwin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

APP_NAME="$(node -p "JSON.parse(require('fs').readFileSync('src-tauri/tauri.conf.json', 'utf8')).productName")"
VERSION="$(node -p "require('./package.json').version")"
APP_BUNDLE_DIR="$REPO_ROOT/src-tauri/target/$TARGET_TRIPLE/release/bundle/macos"
APP_PATH="$APP_BUNDLE_DIR/$APP_NAME.app"
DMG_DIR="$REPO_ROOT/src-tauri/target/$TARGET_TRIPLE/release/bundle/dmg"
STAGING_DIR="$DMG_DIR/${APP_NAME}-dmg-root"
DMG_PATH="$DMG_DIR/${APP_NAME}_${VERSION}_${TARGET_TRIPLE}.dmg"
FIX_SCRIPT_SOURCE="$REPO_ROOT/scripts/macos-permission-fix.command"
FIX_SCRIPT_NAME="Fix CloudTune.command"

echo "Building $APP_NAME.app for $TARGET_TRIPLE..."
npm exec tauri build -- --target "$TARGET_TRIPLE" --bundles app

if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(find "$APP_BUNDLE_DIR" -maxdepth 1 -name '*.app' | head -n 1)"
fi

if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "No macOS app bundle was produced." >&2
  exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$DMG_DIR"
rm -f "$DMG_PATH"

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
cp "$FIX_SCRIPT_SOURCE" "$STAGING_DIR/$FIX_SCRIPT_NAME"
chmod +x "$STAGING_DIR/$FIX_SCRIPT_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Packing custom DMG with repair script..."
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo "Created $DMG_PATH"
