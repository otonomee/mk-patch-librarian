#!/bin/bash
# Wrap the SwiftPM release binary in a real .app bundle.
# A bare executable launching SwiftUI has no bundle identifier, so macOS gives
# it no dock icon and it cannot become the active app.
set -e
cd "$(dirname "$0")"

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

swift build -c release --product MKSoundEditor

APP="build/MKSoundEditor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/Fonts"

cp "$(swift build -c release --show-bin-path)/MKSoundEditor" "$APP/Contents/MacOS/MKSoundEditor"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>MK Patch Librarian</string>
    <key>CFBundleDisplayName</key>     <string>MK Patch Librarian</string>
    <key>CFBundleIdentifier</key>      <string>local.mksoundeditor</string>
    <key>CFBundleVersion</key>         <string>0.5</string>
    <key>CFBundleShortVersionString</key><string>0.5</string>
    <key>CFBundleExecutable</key>      <string>MKSoundEditor</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>ATSApplicationFontsPath</key> <string>Fonts</string>
</dict>
</plist>
PLIST

echo "Built $APP"
