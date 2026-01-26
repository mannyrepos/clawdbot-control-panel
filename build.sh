#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Clawdbot Control"
BUNDLE_NAME="Clawdbot Control.app"
BUILD_DIR="$SCRIPT_DIR/build"

echo "Building $APP_NAME..."

# Create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Compile Swift source
echo "Compiling Swift source..."
swiftc -parse-as-library \
    -o "$BUILD_DIR/ClawdbotControl" \
    "$SCRIPT_DIR/src/main.swift" \
    -framework AppKit \
    -framework SwiftUI \
    -framework UserNotifications

# Create app bundle structure
echo "Creating app bundle..."
mkdir -p "$BUILD_DIR/$BUNDLE_NAME/Contents/MacOS"
mkdir -p "$BUILD_DIR/$BUNDLE_NAME/Contents/Resources"

# Copy files
cp "$BUILD_DIR/ClawdbotControl" "$BUILD_DIR/$BUNDLE_NAME/Contents/MacOS/"
cp "$SCRIPT_DIR/src/Info.plist" "$BUILD_DIR/$BUNDLE_NAME/Contents/"
cp "$SCRIPT_DIR/resources/AppIcon.icns" "$BUILD_DIR/$BUNDLE_NAME/Contents/Resources/"

# Set executable permission
chmod +x "$BUILD_DIR/$BUNDLE_NAME/Contents/MacOS/ClawdbotControl"

echo ""
echo "Build complete: $BUILD_DIR/$BUNDLE_NAME"
echo ""
echo "To install, run:"
echo "  cp -R \"$BUILD_DIR/$BUNDLE_NAME\" /Applications/"
