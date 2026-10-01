#!/bin/bash
# Builds DiskSweep.app, packages it into a drag-to-install DMG in ./dist, and publishes an
# update that a running copy of DiskSweep picks up ("Update ready — Restart to update").
# Pass --install to also install it straight into /Applications when DiskSweep isn't running.
set -euo pipefail
cd "$(dirname "$0")"

APP=DiskSweep
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD_NUMBER=$(date +%Y%m%d%H%M%S)
BUILD=build
DIST="$PWD/dist"
BUNDLE="$BUILD/$APP.app"

# Universal app: Apple silicon and the Intel Macs macOS Tahoe still supports (e.g. 2019–2020 MacBook Pros).
echo "▸ Compiling (Apple silicon + Intel)"
swift build -c release --triple arm64-apple-macosx26.0
swift build -c release --triple x86_64-apple-macosx26.0
BIN="$BUILD/$APP-universal"
mkdir -p "$BUILD"
lipo -create -output "$BIN" \
    "$(swift build -c release --triple arm64-apple-macosx26.0 --show-bin-path)/$APP" \
    "$(swift build -c release --triple x86_64-apple-macosx26.0 --show-bin-path)/$APP"

echo "▸ Assembling $APP.app (build $BUILD_NUMBER)"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $BUILD_NUMBER" "$BUNDLE/Contents/Info.plist"
# Where the app looks for newer builds of itself.
/usr/libexec/PlistBuddy -c "Add DSUpdateFolder string $DIST" "$BUNDLE/Contents/Info.plist"

echo "▸ Rendering icon"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift Scripts/make_icon.swift "$BUILD/icon_1024.png" >/dev/null
for size in 16 32 128 256 512; do
    sips -z $size $size "$BUILD/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$BUILD/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

# Ad-hoc signature with a fixed identity rule. macOS remembers Full Disk Access by this rule,
# so every build counts as the same app and keeps its access after updating.
echo "▸ Signing"
codesign --force --deep --sign - -r='designated => identifier "com.kamranbharaj.DiskSweep"' "$BUNDLE"

# The DMG is for sharing with other people: its copy has no link to this Mac's update folder.
echo "▸ Creating DMG"
STAGE="$BUILD/dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE" "$DIST"
cp -R "$BUNDLE" "$STAGE/"
/usr/libexec/PlistBuddy -c "Delete DSUpdateFolder" "$STAGE/$APP.app/Contents/Info.plist"
codesign --force --deep --sign - -r='designated => identifier "com.kamranbharaj.DiskSweep"' "$STAGE/$APP.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/README.txt "$STAGE/Read Me First.txt"
DMG="$DIST/$APP-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Publish the update as a zip (not a loose .app, which Spotlight would offer as a second copy).
echo "▸ Publishing update"
ditto -c -k --keepParent "$BUNDLE" "$DIST/$APP-update.zip.tmp"
mv "$DIST/$APP-update.zip.tmp" "$DIST/$APP-update.zip"
echo "$BUILD_NUMBER" > "$DIST/update-build.txt"

if [[ "${1:-}" == "--install" ]]; then
    if pgrep -f "/Applications/$APP.app/Contents/MacOS/$APP" >/dev/null; then
        if /usr/libexec/PlistBuddy -c "Print DSUpdateFolder" "/Applications/$APP.app/Contents/Info.plist" >/dev/null 2>&1; then
            echo "• $APP is open: it will show \"Update ready\". Click Restart to update."
        else
            echo "✗ The open copy of $APP is too old to update itself. Quit it once and run ./build.sh --install again."
        fi
    else
        echo "▸ Installing to /Applications"
        rm -rf "/Applications/$APP.app"
        cp -R "$BUNDLE" "/Applications/$APP.app"
    fi
fi

rm -rf "$STAGE" "$BUNDLE"
echo "✓ Build $BUILD_NUMBER · $DMG"
