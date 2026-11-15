#!/bin/bash
# Builds build/Hakoniwa.app (release) with icon, Info.plist and the bundled showcase world.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build (release)"
swift build -c release --product Hakoniwa
BIN="$(swift build -c release --show-bin-path)/Hakoniwa"

APP="build/Hakoniwa.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hakoniwa"

# App icon (regenerated when the generator changes).
ICNS="build/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "scripts/make-icon.swift" -nt "$ICNS" ]; then
    echo "==> rendering icon"
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    swift scripts/make-icon.swift "build/icon-1024.png" > /dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s "build/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null
        d=$((s * 2))
        sips -z $d $d "build/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

if [ -f "Resources/showcase.hkw" ]; then
    cp "Resources/showcase.hkw" "$APP/Contents/Resources/showcase.hkw"
    echo "==> bundled Resources/showcase.hkw"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleExecutable</key><string>Hakoniwa</string>
    <key>CFBundleIdentifier</key><string>app.hakoniwa.Hakoniwa</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Hakoniwa</string>
    <key>CFBundleDisplayName</key><string>箱庭</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>箱庭の世界</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>app.hakoniwa.world</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>app.hakoniwa.world</string>
            <key>UTTypeDescription</key><string>箱庭の世界</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>hkw</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so the bundle launches cleanly on Apple Silicon.
codesign --force --deep --sign - "$APP" > /dev/null 2>&1 || true

echo "==> built $APP"
