#!/usr/bin/env bash
set -euo pipefail

# Determine repository root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ARCH="${1:-universal}"
CONFIG="${2:-Release}"
VERSION="${3:-2.1.1}"
APP_NAME="TuneLab"
OUTPUT_DIR="$REPO_ROOT/artifacts"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

# Generate TuneLab.icns if not present
ICNS_FILE="$REPO_ROOT/tools/icons/TuneLab.icns"
if [ ! -f "$ICNS_FILE" ]; then
    echo "=== Generating $ICNS_FILE ==="
    ICONSET="$(mktemp -d)/TuneLab.iconset"
    mkdir -p "$ICONSET"
    SRC="$REPO_ROOT/tools/icons/mark.png"
    sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png" > /dev/null
    sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png" > /dev/null
    sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png" > /dev/null
    sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png" > /dev/null
    sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png" > /dev/null
    sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png" > /dev/null
    sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png" > /dev/null
    sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png" > /dev/null
    iconutil -c icns "$ICONSET" -o "$ICNS_FILE"
    rm -rf "$(dirname "$ICONSET")"
fi

build_arch() {
    local target_arch=$1
    echo "=== Building TuneLab for $target_arch ($CONFIG) ==="
    dotnet publish TuneLab/TuneLab.csproj -c "$CONFIG" -r "$target_arch" --self-contained
    dotnet publish TuneLab.Cli/TuneLab.Cli.csproj -c "$CONFIG" -r "$target_arch" --self-contained
    cp "TuneLab.Cli/bin/$CONFIG/net8.0/$target_arch/publish/tunelab" "TuneLab/bin/$CONFIG/net8.0/$target_arch/publish/" 2>/dev/null || true
}

assemble_bundle() {
    local source_dir=$1
    mkdir -p "$OUTPUT_DIR"
    rm -rf "$APP_BUNDLE"
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

    # Copy published files
    cp -R "$source_dir/"* "$MACOS_DIR/"

    # Copy icon
    cp "$ICNS_FILE" "$RESOURCES_DIR/TuneLab.icns"

    # Create Info.plist
    cat << EOF > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleName</key>
    <string>TuneLab</string>
    <key>CFBundleDisplayName</key>
    <string>TuneLab</string>
    <key>CFBundleIdentifier</key>
    <string>app.tunelab.TuneLab</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>TuneLab</string>
    <key>CFBundleIconFile</key>
    <string>TuneLab</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>TuneLab Project</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>tlp</string>
                <string>tlpx</string>
            </array>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
        </dict>
    </array>
</dict>
</plist>
EOF

    # Create PkgInfo
    echo -n "APPL????" > "$CONTENTS/PkgInfo"

    chmod +x "$MACOS_DIR/TuneLab"
    chmod +x "$MACOS_DIR/tunelab" 2>/dev/null || true
    chmod +x "$MACOS_DIR/ExtensionInstaller" 2>/dev/null || true
}

sign_bundle() {
    if command -v codesign &>/dev/null; then
        echo "=== Signing app bundle (ad-hoc) ==="
        codesign --force --deep --sign - "$APP_BUNDLE"
    fi
}

package_dist() {
    local label=$1
    echo "=== Packaging ZIP and DMG for $label ==="
    cd "$OUTPUT_DIR"
    zip -q -r "TuneLab-${label}-v${VERSION}.zip" "$APP_NAME.app"
    
    if command -v hdiutil &>/dev/null; then
        rm -f "TuneLab-${label}-v${VERSION}.dmg"
        hdiutil create -volname "TuneLab" -srcfolder "$APP_NAME.app" -ov -format UDZO "TuneLab-${label}-v${VERSION}.dmg" > /dev/null
        echo "Created TuneLab-${label}-v${VERSION}.dmg"
    fi
    cd "$REPO_ROOT"
}

if [ "$ARCH" = "universal" ]; then
    echo "=== Building macOS Universal (arm64 + x64) ==="
    build_arch "osx-arm64"
    build_arch "osx-x64"

    ARM_DIR="$REPO_ROOT/TuneLab/bin/$CONFIG/net8.0/osx-arm64/publish"
    X64_DIR="$REPO_ROOT/TuneLab/bin/$CONFIG/net8.0/osx-x64/publish"

    assemble_bundle "$ARM_DIR"

    echo "=== Merging Mach-O binaries into Universal Binary ==="
    # Find all Mach-O binaries in ARM_DIR and combine with X64_DIR
    while IFS= read -r file; do
        rel_path="${file#$MACOS_DIR/}"
        x64_file="$X64_DIR/$rel_path"
        if [ -f "$x64_file" ]; then
            file_archs=$(lipo -archs "$file" 2>/dev/null || true)
            x64_archs=$(lipo -archs "$x64_file" 2>/dev/null || true)
            if [ -n "$file_archs" ] && [ -n "$x64_archs" ]; then
                if [[ "$file_archs" != *"x86_64"* ]] && [[ "$x64_archs" == *"x86_64"* ]]; then
                    lipo -create "$file" "$x64_file" -output "$file"
                fi
            fi
        fi
    done < <(find "$MACOS_DIR" -type f)

    sign_bundle
    package_dist "osx-universal"

elif [ "$ARCH" = "osx-arm64" ]; then
    build_arch "osx-arm64"
    assemble_bundle "$REPO_ROOT/TuneLab/bin/$CONFIG/net8.0/osx-arm64/publish"
    sign_bundle
    package_dist "osx-arm64"

elif [ "$ARCH" = "osx-x64" ]; then
    build_arch "osx-x64"
    assemble_bundle "$REPO_ROOT/TuneLab/bin/$CONFIG/net8.0/osx-x64/publish"
    sign_bundle
    package_dist "osx-x64"
fi

echo "=== Packaging complete! Output files in: $OUTPUT_DIR ==="
ls -lh "$OUTPUT_DIR"/TuneLab-*.{zip,dmg} 2>/dev/null || true
