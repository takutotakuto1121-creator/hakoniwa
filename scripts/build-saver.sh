#!/bin/bash
# Builds build/Hakoniwa.saver (macOS screen saver) with swiftc, since SwiftPM cannot make .saver bundles.
#
#   scripts/build-saver.sh            build/Hakoniwa.saver
#   scripts/build-saver.sh --preview  also build/saver-preview (runs the saver view in a window
#                                     and saves screenshots; see scripts/saver-preview.swift)
#
# The bundle links HakoniwaCore (compiled here as a static library) with the app's renderer and
# simulation controller, compiled from Sources/Hakoniwa as-is, plus Sources/HakoniwaSaver.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PREVIEW=0
[ "${1:-}" = "--preview" ] && PREVIEW=1

ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos15.0"
OBJ="build/saver-obj"
SAVER="build/Hakoniwa.saver"
mkdir -p "$OBJ"

COMMON=(-target "$TARGET" -swift-version 5 -parse-as-library -wmo)

# 1. HakoniwaCore as a static library + module (same flags as the release build in Package.swift).
CORE_SRC=(Sources/HakoniwaCore/*.swift)
CORE_LIB="$OBJ/libHakoniwaCore.a"
newest_core="$(ls -t "${CORE_SRC[@]}" | head -1)"
if [ ! -f "$CORE_LIB" ] || [ "$newest_core" -nt "$CORE_LIB" ] || [ "$0" -nt "$CORE_LIB" ]; then
    echo "==> swiftc HakoniwaCore"
    swiftc "${COMMON[@]}" -Ounchecked -enforce-exclusivity=unchecked \
        -module-name HakoniwaCore -emit-module -emit-module-path "$OBJ/HakoniwaCore.swiftmodule" \
        -emit-library -static -o "$CORE_LIB" "${CORE_SRC[@]}"
fi

# 2. The app's Metal renderer and simulation thread, shared verbatim, plus the saver itself.
APP_SRC=(
    Sources/Hakoniwa/Render/Renderer.swift
    Sources/Hakoniwa/Render/Camera.swift
    Sources/Hakoniwa/Render/Shaders.swift
    Sources/Hakoniwa/Render/GodLayer.swift
    Sources/Hakoniwa/Render/GodShaders.swift
    Sources/Hakoniwa/Render/VisionOverlay.swift
    Sources/Hakoniwa/Render/VideoRecorder.swift
    Sources/Hakoniwa/Simulation/SimulationController.swift
    Sources/Hakoniwa/Simulation/GodBridge.swift
)
SAVER_SRC=(Sources/HakoniwaSaver/*.swift)
LINK=(-I "$OBJ" -L "$OBJ" -lHakoniwaCore
      -framework ScreenSaver -framework AppKit -framework Metal -framework MetalKit
      -framework QuartzCore -framework AVFoundation -framework CoreVideo)

echo "==> swiftc Hakoniwa.saver"
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
swiftc "${COMMON[@]}" -O -module-name HakoniwaSaver "${LINK[@]}" \
    -emit-executable -Xlinker -bundle -o "$SAVER/Contents/MacOS/Hakoniwa" \
    "${APP_SRC[@]}" "${SAVER_SRC[@]}"

if [ -f "Resources/showcase.hkw" ]; then
    cp "Resources/showcase.hkw" "$SAVER/Contents/Resources/showcase.hkw"
    echo "==> bundled Resources/showcase.hkw"
fi
if [ -f "build/AppIcon.icns" ]; then
    cp "build/AppIcon.icns" "$SAVER/Contents/Resources/AppIcon.icns"
fi

cat > "$SAVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>ja</string>
    <key>CFBundleExecutable</key><string>Hakoniwa</string>
    <key>CFBundleIdentifier</key><string>app.hakoniwa.Hakoniwa.saver</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>箱庭</string>
    <key>CFBundleDisplayName</key><string>箱庭</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSPrincipalClass</key><string>HakoniwaSaverView</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature (Apple Silicon refuses to load unsigned code).
codesign --force --deep --sign - "$SAVER" > /dev/null 2>&1
echo "==> built $SAVER"

if [ "$PREVIEW" = 1 ]; then
    echo "==> swiftc saver-preview"
    swiftc "${COMMON[@]}" -O -module-name HakoniwaSaver "${LINK[@]}" \
        -o build/saver-preview "${APP_SRC[@]}" "${SAVER_SRC[@]}" scripts/saver-preview.swift
    codesign --force --sign - build/saver-preview > /dev/null 2>&1
    echo "==> built build/saver-preview"
fi
