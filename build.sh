#!/bin/zsh
# Compila y empaqueta "Arranque Limpio.app". Uso: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Arranque Limpio.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ArranqueLimpio "$APP/Contents/MacOS/ArranqueLimpio"
swift Tools/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Arranque Limpio</string>
    <key>CFBundleDisplayName</key><string>Arranque Limpio</string>
    <key>CFBundleIdentifier</key><string>io.github.fbamedina.arranquelimpio</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>ArranqueLimpio</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>es</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "✔ Creado: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x ArranqueLimpio 2>/dev/null && sleep 1 || true
    rm -rf "/Applications/Arranque Limpio.app"
    cp -R "$APP" /Applications/
    open "/Applications/Arranque Limpio.app"
    echo "✔ Instalado en /Applications y abierto"
fi
