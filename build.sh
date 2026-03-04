#!/bin/bash
set -euo pipefail

APP_NAME="SimpleTonerBar"
BUNDLE_ID="com.baldwinsung.SimpleTonerBar"
DEST="/Applications/${APP_NAME}.app"

echo "Building ${APP_NAME}..."
swift build -c release

BINARY=".build/release/${APP_NAME}"
if [ ! -f "$BINARY" ]; then
    echo "Error: Build failed, binary not found at ${BINARY}"
    exit 1
fi

echo "Creating app bundle..."
STAGING="/tmp/${APP_NAME}.app"
rm -rf "$STAGING"

mkdir -p "$STAGING/Contents/MacOS"
mkdir -p "$STAGING/Contents/Resources"

cp "$BINARY" "$STAGING/Contents/MacOS/${APP_NAME}"

cat > "$STAGING/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ""http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SimpleTonerBar</string>
    <key>CFBundleDisplayName</key>
    <string>SimpleTonerBar</string>
    <key>CFBundleIdentifier</key>
    <string>com.baldwinsung.SimpleTonerBar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>SimpleTonerBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Installing to ${DEST}..."
sudo ditto "$STAGING" "$DEST"
rm -rf "$STAGING"

echo "Done. ${APP_NAME} installed to ${DEST}"
echo "You can launch it from Applications or run: open '${DEST}'"
