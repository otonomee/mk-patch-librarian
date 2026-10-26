#!/bin/bash
# Wrap the SwiftPM release binary in a real .app bundle for local development.
# A bare executable launching SwiftUI has no bundle identifier, so macOS gives
# it no dock icon and it cannot become the active app.
#
# This bundle is unsandboxed and unsigned. App Store builds come from the
# Xcode project in App/ instead (see docs/APP_STORE.md); both share the
# version in App/Version.xcconfig and the icon in App/MKPatchLibrarian/AppIcon.icon.
set -e
cd "$(dirname "$0")"

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

VERSION=$(sed -n 's/^MARKETING_VERSION *= *//p' App/Version.xcconfig)
BUILD=$(sed -n 's/^CURRENT_PROJECT_VERSION *= *//p' App/Version.xcconfig)

swift build -c release --product MKSoundEditor

APP="build/MK Patch Librarian.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/Fonts"

cp "$(swift build -c release --show-bin-path)/MKSoundEditor" "$APP/Contents/MacOS/MKSoundEditor"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"

# Compiles the Icon Composer icon to Assets.car (macOS 26+) plus an
# AppIcon.icns fallback for earlier releases.
xcrun actool "$PWD/App/MKPatchLibrarian/AppIcon.icon" \
    --compile "$PWD/$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$PWD/build/actool-partial.plist" >/dev/null

# Distinct bundle ID from the App Store build so the two never share
# preferences or confuse LaunchServices on a development machine.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>MK Patch Librarian</string>
    <key>CFBundleDisplayName</key>     <string>MK Patch Librarian</string>
    <key>CFBundleIdentifier</key>      <string>local.mksoundeditor</string>
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key>      <string>MKSoundEditor</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIconName</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>ATSApplicationFontsPath</key> <string>Fonts</string>
</dict>
</plist>
PLIST

echo "Built $APP (v${VERSION} build ${BUILD})"
