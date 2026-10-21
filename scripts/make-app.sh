#!/bin/zsh
# Собирает ScriptDeck.app (release) и, с флагом --install, кладёт его в /Applications.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

APP_NAME="ScriptDeck"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "→ swift build -c release"
swift build -c release --arch arm64

echo "→ Иконка"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "→ Бандл"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>dev.local.scriptdeck</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "✓ $APP"

if [[ "${1:-}" == "--install" ]]; then
    # Сначала гасим всё, что запущено из приложения, иначе dev-серверы останутся сиротами на портах.
    descendants() {
        local child
        for child in $(pgrep -P "$1"); do
            descendants "$child"
            echo "$child"
        done
    }
    for app_pid in $(pgrep -x "$APP_NAME"); do
        children=($(descendants "$app_pid"))
        if (( ${#children} )); then
            echo "→ Останавливаю запущенные скрипты: ${#children} процесс(ов)"
            kill -TERM "${children[@]}" 2>/dev/null || true
            sleep 1.5
            kill -KILL "${children[@]}" 2>/dev/null || true
        fi
    done
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "✓ Установлено в /Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
fi
