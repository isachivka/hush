#!/usr/bin/env bash
# Builds build/Hush.app (menu bar only, ad-hoc signed, arm64 + x86_64).
#   --install   copy it to ~/Applications and launch it
#   --zip       also write build/Hush.zip (what a release ships)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.0.0}"
APP="build/Hush.app"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Hush"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Hush"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.isachivka.hush</string>
    <key>CFBundleName</key><string>Hush</string>
    <key>CFBundleExecutable</key><string>Hush</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>Hush finds your LG TV on the local network and plays its sound on this Mac.</string>
    <key>NSBonjourServices</key><array><string>_airplay._tcp</string></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP ($VERSION)"
for arg in "$@"; do
    case "$arg" in
    --zip)
        (cd build && rm -f Hush.zip && ditto -c -k --keepParent Hush.app Hush.zip)
        echo "zipped build/Hush.zip" ;;
    --install)
        DEST="$HOME/Applications/Hush.app"
        pkill -x Hush 2>/dev/null || true
        mkdir -p "$HOME/Applications"
        rm -rf "$DEST"
        cp -R "$APP" "$DEST"
        open "$DEST"
        echo "installed $DEST" ;;
    esac
done
