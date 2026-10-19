#!/usr/bin/env bash
set -e

APP_NAME="ScreenLens"
BUNDLE_ID="com.screenlens.app"
APP_DIR="/Applications/${APP_NAME}.app"

echo "1. Terminating any existing ${APP_NAME} instance..."
pkill -f "${APP_NAME}" || true

echo "2. Building release binary with SwiftPM..."
swift build -c release

echo "3. Creating ${APP_DIR} bundle structure..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat << PLIST > "${APP_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>ScreenLens needs Accessibility access to detect the active window region.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>ScreenLens needs Screen Recording access to capture text on screen for offline OCR and translation.</string>
</dict>
</plist>
PLIST

echo "4. Signing ${APP_NAME}.app (ad-hoc signature for macOS TCC permissions)..."
codesign --force --deep --sign - "${APP_DIR}"

echo "5. Launching ${APP_NAME}.app in background..."
open "${APP_DIR}"

echo "Done! ${APP_NAME} is now running in your macOS Menu Bar (completely independent of Terminal)."
