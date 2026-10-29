#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
BUILD_SCRATCH_PATH="${BUILD_SCRATCH_PATH:-$ROOT/.build}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$BUILD_SCRATCH_PATH/clang-module-cache}"
BUILD_SDK_PATH="${BUILD_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
# Match the selected compiler's SDK even when Command Line Tools and Xcode
# were updated independently; SwiftPM's cached SDK choice can otherwise differ.
SDKROOT="$BUILD_SDK_PATH" swift build -c release --disable-sandbox --scratch-path "$BUILD_SCRATCH_PATH" --sdk "$BUILD_SDK_PATH"

APP="${APP_OUTPUT:-$ROOT/build/栈桥.app}"
case "$APP" in
    "$ROOT"/build/*.app|/private/tmp/*.app) ;;
    *) echo "APP_OUTPUT must point to an .app bundle inside $ROOT/build or /private/tmp." >&2; exit 2 ;;
esac
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
UPDATE_REPOSITORY="${ZHANQIAO_UPDATE_REPOSITORY:-jiliang6666/AI-shell}"
UPDATE_PUBLIC_KEY="${ZHANQIAO_UPDATE_PUBLIC_KEY:-Fd2DQDZ/nrE3xmzNRzxaITrFvy4L4cfnFf5Y/pCTY44=}"
APP_VERSION="${ZHANQIAO_APP_VERSION:-1.0.6}"
APP_BUILD="${ZHANQIAO_APP_BUILD:-106}"
UPDATE_REVISION="${ZHANQIAO_UPDATE_REVISION:-106}"
UPDATE_FEED_URL=""
case "$APP_VERSION" in ''|*[!0-9.]*) echo "Invalid ZHANQIAO_APP_VERSION." >&2; exit 2 ;; esac
case "$APP_BUILD" in ''|*[!0-9]*) echo "Invalid ZHANQIAO_APP_BUILD." >&2; exit 2 ;; esac
case "$UPDATE_REVISION" in
    ''|*[!0-9]*) echo "ZHANQIAO_UPDATE_REVISION must be a positive integer." >&2; exit 2 ;;
esac
if [ -n "$UPDATE_REPOSITORY" ]; then
    UPDATE_OWNER=${UPDATE_REPOSITORY%%/*}
    UPDATE_NAME=${UPDATE_REPOSITORY#*/}
    case "$UPDATE_OWNER" in ''|*[!A-Za-z0-9_-]*) echo "Invalid GitHub update owner." >&2; exit 2 ;; esac
    case "$UPDATE_NAME" in ''|*[!A-Za-z0-9._-]*|*/*|.|..) echo "Invalid GitHub update repository." >&2; exit 2 ;; esac
    case "$UPDATE_PUBLIC_KEY" in ''|*[!A-Za-z0-9+/=]*) echo "Invalid Sparkle update public key." >&2; exit 2 ;; esac
    UPDATE_FEED_URL="https://github.com/$UPDATE_REPOSITORY/releases/latest/download/appcast.xml"
fi
rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"
cp "$BUILD_SCRATCH_PATH/release/SwiftTerminal" "$MACOS/SwiftTerminal"
if [ -d "$BUILD_SCRATCH_PATH/release/SwiftTerm_SwiftTerm.bundle" ]; then
    cp -R "$BUILD_SCRATCH_PATH/release/SwiftTerm_SwiftTerm.bundle" "$RESOURCES/"
fi
SPARKLE_FRAMEWORK="$(find "$BUILD_SCRATCH_PATH/artifacts" -type d -name Sparkle.framework -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
    echo "Could not find Sparkle.framework in SwiftPM artifacts." >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS/Sparkle.framework"
cp "$BUILD_SCRATCH_PATH/checkouts/Sparkle/LICENSE" "$RESOURCES/Sparkle-LICENSE.txt"
chmod u+w "$RESOURCES/Sparkle-LICENSE.txt"
SPARKLE_LIBRARY="$FRAMEWORKS/Sparkle.framework/Sparkle"
SPARKLE_INSTALL_NAME="$(otool -D "$SPARKLE_LIBRARY" | tail -n 1)"
SPARKLE_LOAD_PATH="$(otool -L "$MACOS/SwiftTerminal" | awk '/Sparkle\.framework\// { print $1; exit }')"
if [ -z "$SPARKLE_INSTALL_NAME" ] || [ -z "$SPARKLE_LOAD_PATH" ]; then
    echo "Could not verify the Sparkle framework link." >&2
    exit 1
fi
if [ "$SPARKLE_LOAD_PATH" != "$SPARKLE_INSTALL_NAME" ]; then
    install_name_tool -change "$SPARKLE_LOAD_PATH" "$SPARKLE_INSTALL_NAME" "$MACOS/SwiftTerminal"
fi
if ! otool -l "$MACOS/SwiftTerminal" | grep -Fq 'path @executable_path/../Frameworks '; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$MACOS/SwiftTerminal"
fi
# Keep the distributable lean; Debug builds and the local SwiftPM build remain unstripped.
strip -S -x "$MACOS/SwiftTerminal"
swift scripts/generate-icon.swift "$ROOT/build/AppIcon.png" "$RESOURCES/AppIcon.icns"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SwiftTerminal</string>
    <key>CFBundleIdentifier</key><string>local.swiftterminal.app</string>
    <key>CFBundleName</key><string>栈桥</string>
    <key>CFBundleDisplayName</key><string>栈桥</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>$APP_BUILD</string>
    <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
    <key>SUFeedURL</key><string>$UPDATE_FEED_URL</string>
    <key>SUPublicEDKey</key><string>$UPDATE_PUBLIC_KEY</string>
    <key>ZhanqiaoUpdateRevision</key><string>$UPDATE_REVISION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>在栈桥中打开文件夹</string></dict>
            <key>NSMessage</key><string>openFolderInZhanqiao</string>
            <key>NSPortName</key><string>栈桥</string>
            <key>NSSendFileTypes</key>
            <array><string>public.folder</string></array>
            <key>NSServiceDescription</key><string>在栈桥中浏览所选文件夹，并在本机终端中进入该目录。</string>
        </dict>
    </array>
    <key>NSLocalNetworkUsageDescription</key><string>栈桥需要访问本地网络，以连接你的 NAS、挂载 SMB 共享和登录 SSH 主机。</string>
    <key>NSBonjourServices</key><array><string>_smb._tcp</string></array>
    <key>NSNetworkVolumesUsageDescription</key><string>栈桥需要访问你挂载的网络共享，以浏览和操作其中的文件。</string>
</dict>
</plist>
PLIST
# Copied/generated artifacts can inherit Finder metadata that codesign rejects.
xattr -cr "$APP"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
elif [ "${NOTARIZE:-0}" = "1" ]; then
    echo "NOTARIZE=1 requires SIGN_IDENTITY to be set." >&2
    exit 2
else
    # The linker signature predates the bundle's Info.plist and resources.
    # Seal the finished bundle so local builds have a valid ad-hoc signature.
    echo "Warning: ad-hoc signing can create a new Local Network privacy entry after rebuilds. Set SIGN_IDENTITY to an Apple-issued code-signing identity for stable SSH/NAS access." >&2
    codesign --force --sign - "$APP"
fi
codesign --verify --strict --deep "$APP"

if [ "${NOTARIZE:-0}" = "1" ]; then
    if [ -z "${NOTARY_PROFILE:-}" ]; then
        echo "NOTARIZE=1 requires NOTARY_PROFILE to name a stored notarytool keychain profile." >&2
        exit 2
    fi
    ZIP="$ROOT/build/栈桥-notarization.zip"
    rm -f "$ZIP"
    ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
fi
echo "Created $APP"
