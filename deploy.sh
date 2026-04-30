#!/bin/bash
set -euo pipefail

if ! command -v gh &>/dev/null; then
  echo "error: GitHub CLI not found. Install with: brew install gh"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(grep -m1 'MARKETING_VERSION' "$SCRIPT_DIR/bigbro.xcodeproj/project.pbxproj" | tr -d ' ;' | cut -d= -f2)"
echo "==> Version: $VERSION"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ARCHIVE_PATH="$WORK_DIR/bigbro.xcarchive"
EXPORT_PATH="$WORK_DIR/export"
APP_PATH="$EXPORT_PATH/bigbro.app"
DMG_PATH="$WORK_DIR/bigbro-$VERSION.dmg"

echo "==> Archiving..."
xcodebuild archive \
  -project "$SCRIPT_DIR/bigbro.xcodeproj" \
  -scheme bigbro \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -quiet

echo "==> Exporting (Developer ID)..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
  -quiet

echo "==> Notarizing..."
ZIP_PATH="$WORK_DIR/bigbro-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
  --keychain-profile "bigbro-notarization" \
  --wait
xcrun stapler staple "$APP_PATH"

echo "==> Creating DMG..."
STAGING="$WORK_DIR/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create \
  -volname "bigbro" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH" \
  -quiet

echo "==> Creating GitHub release v$VERSION..."
gh release create "v$VERSION" "$DMG_PATH" \
  --title "bigbro v$VERSION" \
  --generate-notes

echo "==> Done! https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/v$VERSION"
