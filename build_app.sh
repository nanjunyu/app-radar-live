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

# Generate app icon (.icns) from logo.png for the Dock / Finder
echo "🎨 Generating app icon from logo.png..."
if [ -f "logo.png" ]; then
    ICONSET_DIR="AppIcon.iconset"
    rm -rf "${ICONSET_DIR}"
    mkdir -p "${ICONSET_DIR}"
    # 先把 logo 渲染成 macOS 标准图标样式（圆角 + 留白 + 透明角），再切各尺寸
    BASE_PNG="_icon_base.png"
    swift tools/make_icon.swift logo.png "${BASE_PNG}"
    # Standard macOS iconset sizes (1x + @2x)
    sips -s format png -z 16 16     "${BASE_PNG}" --out "${ICONSET_DIR}/icon_16x16.png"      >/dev/null 2>&1
    sips -s format png -z 32 32     "${BASE_PNG}" --out "${ICONSET_DIR}/icon_16x16@2x.png"   >/dev/null 2>&1
    sips -s format png -z 32 32     "${BASE_PNG}" --out "${ICONSET_DIR}/icon_32x32.png"      >/dev/null 2>&1
    sips -s format png -z 64 64     "${BASE_PNG}" --out "${ICONSET_DIR}/icon_32x32@2x.png"   >/dev/null 2>&1
    sips -s format png -z 128 128   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_128x128.png"    >/dev/null 2>&1
    sips -s format png -z 256 256   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null 2>&1
    sips -s format png -z 256 256   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_256x256.png"    >/dev/null 2>&1
    sips -s format png -z 512 512   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null 2>&1
    sips -s format png -z 512 512   "${BASE_PNG}" --out "${ICONSET_DIR}/icon_512x512.png"    >/dev/null 2>&1
    sips -s format png -z 1024 1024 "${BASE_PNG}" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "${ICONSET_DIR}" -o "${CONTENTS_DIR}/Resources/AppIcon.icns"
    rm -rf "${ICONSET_DIR}"
    # Also ship a normalized PNG so the app can set its Dock icon at runtime
    cp "${BASE_PNG}" "${CONTENTS_DIR}/Resources/logo.png"
    rm -f "${BASE_PNG}"
    
    # Generate the menu bar template icon matching the app's real logo
    python3 tools/make_menu_icon.py logo.png "${CONTENTS_DIR}/Resources/logo_menu.png" badge 36
    
    echo "✅ App icon and menu bar icons generated."
else
    echo "⚠️  logo.png not found, skipping icon generation."
fi

# Sign the app
echo "🔐 Signing the application..."
codesign --force --deep --sign - "${APP_NAME}"

echo "✅ Build complete! You can run it using: open ${APP_NAME}"
