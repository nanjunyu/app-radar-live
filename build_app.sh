#!/bin/bash
set -e

echo "🚀 Building app-radar-live..."

APP_NAME="app-radar-live.app"
CONTENTS_DIR="${APP_NAME}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

# Clean up previous build
rm -rf "${APP_NAME}"

# Create directories
mkdir -p "${MACOS_DIR}"
mkdir -p "${CONTENTS_DIR}/Resources"

# Compile Swift files
# Target arm64 explicitly as requested for Apple Silicon
echo "⚙️ Compiling Swift code..."
SWIFT_SOURCES=$(find Sources -name "*.swift")
swiftc ${SWIFT_SOURCES} -parse-as-library -o "${MACOS_DIR}/app-radar-live" -target arm64-apple-macosx14.0

# Copy Info.plist
cp Info.plist "${CONTENTS_DIR}/"

# Sign the app
echo "🔐 Signing the application..."
codesign --force --deep --sign - "${APP_NAME}"

echo "✅ Build complete! You can run it using: open ${APP_NAME}"
