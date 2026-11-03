#!/bin/zsh
# 构建 Maple.app 与 Intel / M 系列双版本独立安装程序 (.app)，不生成 DMG
set -e
cd "$(dirname "$0")"

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo "→ 正在编译 Release (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64 --disable-sandbox

BIN_MAPLE=".build/apple/Products/Release/Maple"
BIN_INSTALLER=".build/apple/Products/Release/MapleInstaller"
if [ ! -f "$BIN_MAPLE" ]; then
    BIN_MAPLE=".build/release/Maple"
fi
if [ ! -f "$BIN_INSTALLER" ]; then
    BIN_INSTALLER=".build/release/MapleInstaller"
fi

clean_xattrs_and_sign() {
    local target="$1"
    # 彻底清除所有文件与目录的扩展属性（包括 com.apple.FinderInfo, com.apple.provenance, com.apple.quarantine 等）
    xattr -c -r "$target" 2>/dev/null || true

    # 如果存在内嵌的 Maple.app，先给内嵌的 Maple.app 深度签名
    if [ -d "$target/Contents/Resources/Maple.app" ]; then
        xattr -c -r "$target/Contents/Resources/Maple.app" 2>/dev/null || true
        codesign --force --deep --sign - "$target/Contents/Resources/Maple.app"
    fi

    # 签名外层应用
    codesign --force --deep --sign - "$target"

    # 严苛校验代码签名完整性
    codesign --verify --deep --strict "$target" 2>/dev/null || true
}

package_maple_app() {
    local target_app="$1"
    local arch_mode="$2" # universal | arm64 | x86_64

    rm -rf "$target_app"
    mkdir -p "$target_app/Contents/MacOS" "$target_app/Contents/Resources"

    local arch_plist_snippet=""
    if [ "$arch_mode" = "arm64" ]; then
        lipo "$BIN_MAPLE" -thin arm64 -output "$target_app/Contents/MacOS/Maple"
        arch_plist_snippet="<key>LSArchitecturePriority</key><array><string>arm64</string></array>"
    elif [ "$arch_mode" = "x86_64" ]; then
        lipo "$BIN_MAPLE" -thin x86_64 -output "$target_app/Contents/MacOS/Maple"
        arch_plist_snippet="<key>LSArchitecturePriority</key><array><string>x86_64</string></array>"
    else
        cp "$BIN_MAPLE" "$target_app/Contents/MacOS/Maple"
    fi
    chmod +x "$target_app/Contents/MacOS/Maple"

    if [ -f "Resources/AppIcon.icns" ]; then
        cp "Resources/AppIcon.icns" "$target_app/Contents/Resources/AppIcon.icns"
    fi
    for tiff in Resources/*.tiff; do
        if [ -f "$tiff" ]; then
            cp "$tiff" "$target_app/Contents/Resources/"
        fi
    done
    for aif in Resources/*.aif; do
        if [ -f "$aif" ]; then
            cp "$aif" "$target_app/Contents/Resources/"
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
    <key>CFBundleIdentifier</key><string>com.workbuddy.maple</string>
    <key>CFBundleExecutable</key><string>Maple</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSQuitAlwaysKeepsWindows</key><false/>
    ${arch_plist_snippet}
    <key>NSDesktopFolderUsageDescription</key><string>Maple 需要访问“桌面”文件夹以浏览与搜索文件。</string>
    <key>NSDocumentsFolderUsageDescription</key><string>Maple 需要访问“文稿”文件夹以浏览与搜索文件。</string>
    <key>NSDownloadsFolderUsageDescription</key><string>Maple 需要访问“下载”文件夹以浏览与搜索文件。</string>
    <key>NSRemovableVolumesUsageDescription</key><string>Maple 需要访问外置磁盘以浏览与搜索文件。</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Maple 需要访问网络卷以浏览文件。</string>
    <key>NSAppleEventsUsageDescription</key><string>Maple 需要控制“访达”以读取系统废纸篓内容和执行清倒废纸篓操作。</string>
    <key>NSSystemAdministrationUsageDescription</key><string>Maple 需要完全磁盘访问权限以浏览受保护的系统目录与废纸篓。</string>
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
    <key>NSQuitAlwaysKeepsWindows</key><false/>
    ${arch_plist_snippet}
</dict>
</plist>
PLIST

    clean_xattrs_and_sign "$target_app"
}

build_dmg() {
    local maple_app="$1"
    local output_dmg="$2"
    local vol_name="$3"

    echo "→ 正在构建枫叶拖拽安装 DMG: $output_dmg ..."
    local dmg_temp="/tmp/maple_dmg_build_$$"
    rm -rf "$dmg_temp"
    mkdir -p "$dmg_temp/stage"

    # 1. 确保最新 Retina 144 DPI 背景图已就绪
    python3 Resources/generate_dmg_background.py

    # 2. 放入 Maple.app 并深度清除隔离属性与重新签名
    cp -R "$maple_app" "$dmg_temp/stage/Maple.app"
    clean_xattrs_and_sign "$dmg_temp/stage/Maple.app"

    # 3. 先强行卸载所有旧的同名挂载卷，避免 Finder 卷名冲突（如 Maple 1, Maple 2）
    for m in "/Volumes/$vol_name" "/Volumes/${vol_name} 1" "/Volumes/${vol_name} 2" "/Volumes/${vol_name} 3"; do
        if [ -d "$m" ]; then
            hdiutil detach "$m" -force 2>/dev/null || true
        fi
    done

    rm -f "$output_dmg"

    # 4. 使用专业的 create-dmg 建立完美的 Retina 枫叶拖拽向导 DMG
    if command -v create-dmg >/dev/null 2>&1; then
        create-dmg \
            --volname "$vol_name" \
            --volicon "Resources/AppIcon.icns" \
            --background "Resources/dmg_background.png" \
            --window-pos 400 180 \
            --window-size 560 400 \
            --icon-size 96 \
            --icon "Maple.app" 140 200 \
            --hide-extension "Maple.app" \
            --app-drop-link 420 200 \
            --format UDZO \
            --hdiutil-quiet \
            "$output_dmg" \
            "$dmg_temp/stage" 2>/dev/null || true
    fi

    # 4. 兜底：如果 create-dmg 未产出，使用标准 hdiutil 制作
    if [ ! -f "$output_dmg" ]; then
        ln -s /Applications "$dmg_temp/stage/Applications"
        hdiutil create -srcfolder "$dmg_temp/stage" -volname "$vol_name" -format UDZO -imagekey zlib-level=9 "$output_dmg" -quiet
    fi

    rm -rf "$dmg_temp"
    echo "✓ 已生成原生枫叶拖入安装 DMG: $output_dmg ($(du -sh "$output_dmg" | awk '{print $1}'))"
}

STAGE_DIR=$(mktemp -d /tmp/maple_stage_XXXXXX)
trap 'rm -rf "$STAGE_DIR"' EXIT

# 清理旧的窗口保存状态，确保首次启动始终以干净前台主窗口呈现
rm -rf "$HOME/Library/Saved Application State/com.workbuddy.maple.savedState" "$HOME/Library/Saved Application State/com.workbuddy.qspacelite.savedState"

# 1. 构建通用版 Maple.app（用于本机 /Applications 安装）
APP="$STAGE_DIR/Maple.app"
package_maple_app "$APP" "universal"
rm -rf "../Maple.app" "/Applications/Maple.app"
cp -R "$APP" "/Applications/Maple.app"

# 2. 构建 M 系列芯片 (arm64) 原生枫叶拖拽安装 DMG 与独立应用
echo "→ 正在构建 M 系列芯片 (arm64) 安装包与向导程序..."
APP_ARM="$STAGE_DIR/Maple-arm64/Maple.app"
package_maple_app "$APP_ARM" "arm64"

rm -rf "../Maple (M系列).app" "../安装 Maple (M系列).dmg" "../安装 Maple (M系列).app"
cp -R "$APP_ARM" "../Maple (M系列).app"
build_dmg "$APP_ARM" "../安装 Maple (M系列).dmg" "Maple"

# 同时生成专属 arm64 架构、深度去除隔离属性的枫叶交互向导 .app
INSTALLER_ARM="$STAGE_DIR/Installer-arm64/安装 Maple (向导版).app"
package_installer_app "$INSTALLER_ARM" "$APP_ARM" "arm64" "安装 Maple"
cp -R "$INSTALLER_ARM" "../安装 Maple (M系列).app"

# 3. 构建 Intel 芯片 (x86_64) 原生枫叶拖拽安装 DMG 与独立应用
echo "→ 正在构建 Intel 芯片 (x86_64) 安装包与向导程序..."
APP_X86="$STAGE_DIR/Maple-x86_64/Maple.app"
package_maple_app "$APP_X86" "x86_64"

rm -rf "../Maple (Intel).app" "../安装 Maple (Intel).dmg" "../安装 Maple (Intel).app"
cp -R "$APP_X86" "../Maple (Intel).app"
build_dmg "$APP_X86" "../安装 Maple (Intel).dmg" "Maple"

INSTALLER_X86="$STAGE_DIR/Installer-x86_64/安装 Maple (向导版).app"
package_installer_app "$INSTALLER_X86" "$APP_X86" "x86_64" "安装 Maple"
cp -R "$INSTALLER_X86" "../安装 Maple (Intel).app"

# 4. 清理旧的冗余构建项
rm -rf "../安装 Maple (M系列).zip" "../安装 Maple (Intel).zip" "../Maple.app" "build" "../Maple.dmg" "../Maple Installer.app"

echo ""
echo "=========================================================="
echo "✓ 全部构建完成并输出至 $(cd .. && pwd):"
echo "  1. M系列单文件 DMG (枫叶拖入安装，纯净无嵌套): 安装 Maple (M系列).dmg"
echo "  2. M系列交互安装向导 (原生枫叶拖拽动画与音效): 安装 Maple (M系列).app"
echo "  3. M系列独立本体 (纯 arm64): Maple (M系列).app"
echo "  4. Intel单文件 DMG (枫叶拖入安装): 安装 Maple (Intel).dmg"
echo "  5. Intel交互安装向导 (枫叶拖拽动画与音效): 安装 Maple (Intel).app"
echo "  6. Intel独立本体 (纯 x86_64): Maple (Intel).app"
echo "=========================================================="
