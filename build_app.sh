#!/bin/zsh
# 构建 Maple.app 与 Intel / M 系列双版本独立安装程序 (.app)，不生成 DMG
set -e
cd "$(dirname "$0")"

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo "→ 正在编译 Release (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64 --disable-sandbox

BIN_MAPLE=".build/apple/Products/Release/QSpaceLite"
BIN_INSTALLER=".build/apple/Products/Release/MapleInstaller"
if [ ! -f "$BIN_MAPLE" ]; then
    BIN_MAPLE=".build/release/QSpaceLite"
fi
if [ ! -f "$BIN_INSTALLER" ]; then
    BIN_INSTALLER=".build/release/MapleInstaller"
fi

clean_xattrs_and_sign() {
    local target="$1"
    # 彻底清除所有文件与目录的扩展属性（包括 com.apple.FinderInfo, com.apple.provenance 等，防止 Apple Silicon 报签名损坏）
    xattr -c -r "$target" 2>/dev/null || true
    python3 -c "
import os, subprocess, sys
p = sys.argv[1]
for root, dirs, files in os.walk(p, topdown=False):
    for f in files:
        subprocess.run(['xattr', '-c', os.path.join(root, f)], stderr=subprocess.DEVNULL)
    for d in dirs:
        subprocess.run(['xattr', '-c', os.path.join(root, d)], stderr=subprocess.DEVNULL)
subprocess.run(['xattr', '-c', p], stderr=subprocess.DEVNULL)
" "$target" 2>/dev/null || true

    # 如果存在内嵌的 Maple.app，先给内嵌的 Maple.app 独立签名
    if [ -d "$target/Contents/Resources/Maple.app" ]; then
        codesign --force --sign - "$target/Contents/Resources/Maple.app"
    fi

    # 签名外层应用
    codesign --force --deep --sign - "$target"

    # 严苛校验代码签名完整性
    codesign --verify --deep --strict "$target"
}

package_maple_app() {
    local target_app="$1"
    local arch_mode="$2" # universal | arm64 | x86_64

    rm -rf "$target_app"
    mkdir -p "$target_app/Contents/MacOS" "$target_app/Contents/Resources"

    local arch_plist_snippet=""
    if [ "$arch_mode" = "arm64" ]; then
        lipo "$BIN_MAPLE" -thin arm64 -output "$target_app/Contents/MacOS/QSpaceLite"
        arch_plist_snippet="<key>LSArchitecturePriority</key><array><string>arm64</string></array>"
    elif [ "$arch_mode" = "x86_64" ]; then
        lipo "$BIN_MAPLE" -thin x86_64 -output "$target_app/Contents/MacOS/QSpaceLite"
        arch_plist_snippet="<key>LSArchitecturePriority</key><array><string>x86_64</string></array>"
    else
        cp "$BIN_MAPLE" "$target_app/Contents/MacOS/QSpaceLite"
    fi
    chmod +x "$target_app/Contents/MacOS/QSpaceLite"

    if [ -f "Resources/AppIcon.icns" ]; then
        cp "Resources/AppIcon.icns" "$target_app/Contents/Resources/AppIcon.icns"
    fi
    for tiff in Resources/*.tiff; do
        if [ -f "$tiff" ]; then
            cp "$tiff" "$target_app/Contents/Resources/"
        fi
    done

    cat > "$target_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
    <key>CFBundleName</key><string>Maple</string>
    <key>CFBundleDisplayName</key><string>Maple</string>
    <key>CFBundleIdentifier</key><string>com.workbuddy.qspacelite</string>
    <key>CFBundleExecutable</key><string>QSpaceLite</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    ${arch_plist_snippet}
    <key>NSDesktopFolderUsageDescription</key><string>Maple 需要访问“桌面”文件夹以浏览与搜索文件。</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Maple 需要访问“文稿”文件夹以浏览与搜索文件。</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Maple 需要访问“下载”文件夹以浏览与搜索文件。</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Maple 需要访问外置磁盘以浏览与搜索文件。</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Maple 需要访问网络卷以浏览文件。</string>
</dict>
</plist>
PLIST

    clean_xattrs_and_sign "$target_app"
}

package_installer_app() {
    local target_app="$1"
    local source_maple_app="$2"
    local arch_mode="$3" # universal | arm64 | x86_64
    local display_name="${4:-安装 Maple}"

    rm -rf "$target_app"
    mkdir -p "$target_app/Contents/MacOS" "$target_app/Contents/Resources"

    local arch_plist_snippet=""
    if [ "$arch_mode" = "arm64" ]; then
        lipo "$BIN_INSTALLER" -thin arm64 -output "$target_app/Contents/MacOS/MapleInstaller"
        arch_plist_snippet="<key>LSArchitecturePriority</key><array><string>arm64</string></array>"
    elif [ "$arch_mode" = "x86_64" ]; then
        lipo "$BIN_INSTALLER" -thin x86_64 -output "$target_app/Contents/MacOS/MapleInstaller"
        arch_plist_snippet="<key>LSArchitecturePriority</key><array><string>x86_64</string></array>"
    else
        cp "$BIN_INSTALLER" "$target_app/Contents/MacOS/MapleInstaller"
    fi
    chmod +x "$target_app/Contents/MacOS/MapleInstaller"

    if [ -f "Resources/AppIcon.icns" ]; then
        cp "Resources/AppIcon.icns" "$target_app/Contents/Resources/AppIcon.icns"
    fi
    for png in Resources/installer_*.png; do
        if [ -f "$png" ]; then
            cp "$png" "$target_app/Contents/Resources/"
        fi
    done

    # 将对应架构优化后的 Maple.app 嵌入安装器
    cp -R "$source_maple_app" "$target_app/Contents/Resources/Maple.app"

    cat > "$target_app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
    <key>CFBundleName</key><string>${display_name}</string>
    <key>CFBundleDisplayName</key><string>${display_name}</string>
    <key>CFBundleIdentifier</key><string>com.maple.installer.${arch_mode}</string>
    <key>CFBundleExecutable</key><string>MapleInstaller</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    ${arch_plist_snippet}
</dict>
</plist>
PLIST

    clean_xattrs_and_sign "$target_app"
}

build_dmg() {
    local dmg_stage="$1"
    local installer_app="$2"
    local maple_app="$3"
    local output_dmg="$4"
    local vol_name="$5"

    rm -rf "$dmg_stage"
    mkdir -p "$dmg_stage"
    cp -R "$installer_app" "$dmg_stage/安装 Maple.app"
    cp -R "$maple_app" "$dmg_stage/Maple.app"
    ln -s /Applications "$dmg_stage/Applications"

    # 清除内部所有扩展属性并重新严苛签名
    clean_xattrs_and_sign "$dmg_stage/Maple.app"
    clean_xattrs_and_sign "$dmg_stage/安装 Maple.app"

    rm -f "$output_dmg"
    hdiutil create -srcfolder "$dmg_stage" -volname "$vol_name" -fs HFS+ -format UDZO -imagekey zlib-level=9 -o "$output_dmg" -quiet
    echo "✓ 已生成独立单文件 DMG: $output_dmg ($(du -sh "$output_dmg" | awk '{print $1}'))"
}

STAGE_DIR=$(mktemp -d /tmp/maple_stage_XXXXXX)
trap 'rm -rf "$STAGE_DIR"' EXIT

# 1. 构建通用版 Maple.app（用于本机 /Applications 安装）
APP="$STAGE_DIR/Maple.app"
package_maple_app "$APP" "universal"
rm -rf "../Maple.app" "/Applications/Maple.app"
cp -R "$APP" "/Applications/Maple.app"

# 2. 构建 M 系列芯片 (arm64) 单文件 DMG 与安装程序
echo "→ 正在构建 M 系列芯片 (arm64) 安装包..."
APP_ARM="$STAGE_DIR/Maple-arm64/Maple.app"
package_maple_app "$APP_ARM" "arm64"
INSTALLER_M="$STAGE_DIR/安装 Maple (M系列).app"
package_installer_app "$INSTALLER_M" "$APP_ARM" "arm64" "安装 Maple (M系列)"

rm -rf "../安装 Maple (M系列).app" "../Maple (M系列).app" "../Maple安装程序-M系列.app" "../Maple安装程序-AppleSilicon.app" "../Maple安装程序-AppleSilicon.zip" "../Maple安装程序-M系列.zip" "../Maple-AppleSilicon.dmg"
cp -R "$INSTALLER_M" "../安装 Maple (M系列).app"
cp -R "$APP_ARM" "../Maple (M系列).app"
xattr -d com.apple.FinderInfo "../安装 Maple (M系列).app" "../Maple (M系列).app" 2>/dev/null || true
build_dmg "$STAGE_DIR/dmg_arm" "$INSTALLER_M" "$APP_ARM" "../安装 Maple (M系列).dmg" "Maple (M系列)"

# 3. 构建 Intel 芯片 (x86_64) 单文件 DMG 与安装程序
echo "→ 正在构建 Intel 芯片 (x86_64) 安装包..."
APP_X86="$STAGE_DIR/Maple-x86_64/Maple.app"
package_maple_app "$APP_X86" "x86_64"
INSTALLER_INTEL="$STAGE_DIR/安装 Maple (Intel).app"
package_installer_app "$INSTALLER_INTEL" "$APP_X86" "x86_64" "安装 Maple (Intel)"

rm -rf "../安装 Maple (Intel).app" "../Maple (Intel).app" "../Maple安装程序-Intel.app" "../Maple安装程序-Intel.zip" "../Maple-Intel.dmg"
cp -R "$INSTALLER_INTEL" "../安装 Maple (Intel).app"
cp -R "$APP_X86" "../Maple (Intel).app"
xattr -d com.apple.FinderInfo "../安装 Maple (Intel).app" "../Maple (Intel).app" 2>/dev/null || true
build_dmg "$STAGE_DIR/dmg_intel" "$INSTALLER_INTEL" "$APP_X86" "../安装 Maple (Intel).dmg" "Maple (Intel)"

# 4. 清理旧的临时文件与冗余项（彻底清理桌面多余的未区分架构的 Maple.app）
rm -rf "../Maple.app" "build" "../Maple.dmg" "../Maple Installer.app"

echo ""
echo "=========================================================="
echo "✓ 全部构建完成并输出至 $(cd .. && pwd):"
echo "  1. M系列单文件 DMG (微信发给M芯片朋友): 安装 Maple (M系列).dmg"
echo "  2. Intel单文件 DMG (发给Intel电脑): 安装 Maple (Intel).dmg"
echo "  3. M系列独立本体 (纯 arm64): Maple (M系列).app"
echo "  4. Intel独立本体 (纯 x86_64): Maple (Intel).app"
echo "  5. M系列独立安装器 (纯 arm64): 安装 Maple (M系列).app"
echo "  6. Intel独立安装器 (纯 x86_64): 安装 Maple (Intel).app"
echo "  （已清理重复的未分类 Maple.app，本机应用已同步至 /Applications/Maple.app）"
echo "=========================================================="
