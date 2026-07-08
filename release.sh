#!/bin/bash
set -e

# ============================================================
# release.sh - 构建 Intel & Apple Silicon 版本并发布到 GitHub
# 同时生成自动更新所需的 .zip + Ed25519 签名 + latest.json
# 用法: ./release.sh [版本号]
# 示例: ./release.sh 1.1.0
# ============================================================

VERSION="${1:-1.0.0}"
TAG="v${VERSION}"
APP_NAME="AppRadar Live"
BUNDLE_NAME="app-radar-live"
RELEASE_DIR="release"
PRIVATE_KEY="update_private_key.pem"
REPO="nanjunyu/app-radar-live"

echo "🚀 开始构建 ${APP_NAME} ${TAG}..."
echo ""

# 检查自动更新私钥是否存在
if [ ! -f "${PRIVATE_KEY}" ]; then
    echo "❌ 未找到自动更新私钥 ${PRIVATE_KEY}"
    echo "   请先运行: swift tools/gen_update_key.swift"
    exit 1
fi

# 把版本号写进 Info.plist（保证 App 内能正确比对版本）
echo "📝 更新 Info.plist 版本号为 ${VERSION}..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" Info.plist

# 清理之前的构建产物
rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"

# ============================================================
# 构建函数
# ============================================================
build_for_arch() {
    local ARCH=$1        # arm64 or x86_64
    local LABEL=$2       # Apple Silicon or Intel
    local TARGET="${ARCH}-apple-macosx14.0"
    local BUILD_DIR="${RELEASE_DIR}/${ARCH}"
    local APP_BUNDLE="${BUILD_DIR}/${BUNDLE_NAME}.app"
    local CONTENTS_DIR="${APP_BUNDLE}/Contents"
    local MACOS_DIR="${CONTENTS_DIR}/MacOS"

    echo "⚙️  构建 ${LABEL} (${ARCH}) 版本..."

    mkdir -p "${MACOS_DIR}"
    mkdir -p "${CONTENTS_DIR}/Resources"

    SWIFT_SOURCES=$(find Sources -name "*.swift")
    swiftc ${SWIFT_SOURCES} -parse-as-library -o "${MACOS_DIR}/${BUNDLE_NAME}" -target "${TARGET}" -O

    cp Info.plist "${CONTENTS_DIR}/"

    # 打包 CHANGELOG.md（更新记录数据源）
    if [ -f "CHANGELOG.md" ]; then
        cp CHANGELOG.md "${CONTENTS_DIR}/Resources/CHANGELOG.md"
    fi

    if [ -f "logo.png" ]; then
        ICONSET_DIR="${BUILD_DIR}/AppIcon.iconset"
        rm -rf "${ICONSET_DIR}"
        mkdir -p "${ICONSET_DIR}"

        BASE_PNG="${BUILD_DIR}/_icon_base.png"
        swift tools/make_icon.swift logo.png "${BASE_PNG}"

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

        cp "${BASE_PNG}" "${CONTENTS_DIR}/Resources/logo.png"
        rm -f "${BASE_PNG}"

        python3 tools/make_menu_icon.py logo.png "${CONTENTS_DIR}/Resources/logo_menu.png" badge 36
    fi

    codesign --force --deep --sign - "${APP_BUNDLE}"

    echo "✅ ${LABEL} 版本构建完成"
}

# ============================================================
# 打包 DMG（供手动下载）
# ============================================================
create_dmg() {
    local ARCH=$1
    local LABEL=$2
    local BUILD_DIR="${RELEASE_DIR}/${ARCH}"
    local APP_BUNDLE="${BUILD_DIR}/${BUNDLE_NAME}.app"
    local DMG_NAME="${APP_NAME}-${VERSION}-${ARCH}.dmg"
    local DMG_PATH="${RELEASE_DIR}/${DMG_NAME}"
    local DMG_TEMP="${RELEASE_DIR}/tmp_${ARCH}"

    echo "📦 打包 ${LABEL} DMG..."

    mkdir -p "${DMG_TEMP}"
    cp -R "${APP_BUNDLE}" "${DMG_TEMP}/"
    ln -s /Applications "${DMG_TEMP}/Applications"

    hdiutil create -volname "${APP_NAME}" \
        -srcfolder "${DMG_TEMP}" \
        -ov -format UDZO \
        "${DMG_PATH}" >/dev/null 2>&1

    rm -rf "${DMG_TEMP}"

    echo "✅ ${DMG_NAME} 创建完成 ($(du -h "${DMG_PATH}" | cut -f1))"
}

# ============================================================
# 打包 ZIP + 签名（供 App 内自动更新）
# ============================================================
# 返回签名值写入全局变量 SIG_arm64 / SIG_x86_64
create_zip_and_sign() {
    local ARCH=$1
    local BUILD_DIR="${RELEASE_DIR}/${ARCH}"
    local APP_BUNDLE="${BUILD_DIR}/${BUNDLE_NAME}.app"
    local ZIP_NAME="${BUNDLE_NAME}-${VERSION}-${ARCH}.zip"
    local ZIP_PATH="${RELEASE_DIR}/${ZIP_NAME}"

    echo "📦 打包 ${ARCH} 自动更新 ZIP..."

    # 用 ditto 保留 .app 元数据打成 zip
    ditto -c -k --sequesterRsrc --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

    # Ed25519 签名
    local SIG
    SIG=$(swift tools/sign_update.swift "${PRIVATE_KEY}" "${ZIP_PATH}")

    if [ "${ARCH}" == "arm64" ]; then
        SIG_arm64="${SIG}"
    else
        SIG_x86_64="${SIG}"
    fi

    echo "✅ ${ZIP_NAME} 创建并签名完成 ($(du -h "${ZIP_PATH}" | cut -f1))"
}

# ============================================================
# 执行构建
# ============================================================
build_for_arch "arm64" "Apple Silicon"
echo ""
build_for_arch "x86_64" "Intel"
echo ""

# ============================================================
# 打包 DMG + ZIP
# ============================================================
create_dmg "arm64" "Apple Silicon"
create_dmg "x86_64" "Intel"
echo ""
create_zip_and_sign "arm64"
create_zip_and_sign "x86_64"
echo ""

# ============================================================
# 生成 latest.json（自动更新 manifest）
# ============================================================
echo "📄 生成 latest.json..."
PUB_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

# 读取更新说明：优先 RELEASE_NOTES.md，否则用默认文案
if [ -f "RELEASE_NOTES.md" ]; then
    NOTES=$(cat RELEASE_NOTES.md)
else
    NOTES="本次更新包含若干功能优化与问题修复。"
fi

# 用 python 安全生成 JSON（正确转义 notes 里的换行/引号）
export NOTES
python3 - "$VERSION" "$PUB_DATE" "$BASE_URL" "$BUNDLE_NAME" "$SIG_arm64" "$SIG_x86_64" > "${RELEASE_DIR}/latest.json" <<'PYEOF'
import json, sys, os
version, pub_date, base_url, bundle, sig_arm, sig_x64 = sys.argv[1:7]
notes = os.environ.get("NOTES", "")
manifest = {
    "version": version,
    "notes": notes,
    "pubDate": pub_date,
    "platforms": {
        "darwin-arm64": {
            "url": f"{base_url}/{bundle}-{version}-arm64.zip",
            "signature": sig_arm
        },
        "darwin-x86_64": {
            "url": f"{base_url}/{bundle}-{version}-x86_64.zip",
            "signature": sig_x64
        }
    }
}
print(json.dumps(manifest, ensure_ascii=False, indent=2))
PYEOF

echo "✅ latest.json 生成完成"
echo ""

# ============================================================
# 发布到 GitHub
# ============================================================
ARM_DMG="${RELEASE_DIR}/${APP_NAME}-${VERSION}-arm64.dmg"
INTEL_DMG="${RELEASE_DIR}/${APP_NAME}-${VERSION}-x86_64.dmg"
ARM_ZIP="${RELEASE_DIR}/${BUNDLE_NAME}-${VERSION}-arm64.zip"
INTEL_ZIP="${RELEASE_DIR}/${BUNDLE_NAME}-${VERSION}-x86_64.zip"
MANIFEST="${RELEASE_DIR}/latest.json"

echo "🏷️  创建 GitHub Release ${TAG}..."

RELEASE_NOTES="## ${APP_NAME} ${TAG}

${NOTES}

### 下载

| 芯片架构 | 文件 |
|---------|------|
| Apple Silicon (M1/M2/M3/M4) | ${APP_NAME}-${VERSION}-arm64.dmg |
| Intel | ${APP_NAME}-${VERSION}-x86_64.dmg |

### 安装方法
1. 下载对应芯片架构的 .dmg 文件
2. 双击打开 .dmg 文件，将 app-radar-live 拖入 Applications 文件夹
3. 首次打开时右键选择「打开」以绕过 Gatekeeper

> 已安装的用户无需手动下载，应用会自动检测新版本并一键更新。
"

gh release create "${TAG}" \
    "${ARM_DMG}" \
    "${INTEL_DMG}" \
    "${ARM_ZIP}" \
    "${INTEL_ZIP}" \
    "${MANIFEST}" \
    --title "${APP_NAME} ${TAG}" \
    --notes "${RELEASE_NOTES}" \
    --latest

echo ""
echo "🎉 发布完成！"
echo "   Release 页面: https://github.com/${REPO}/releases/tag/${TAG}"
