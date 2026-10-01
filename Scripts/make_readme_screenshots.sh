#!/bin/bash
# Regenerates docs/screenshots/*.png for the README without showing anyone's real files:
# builds a made-up home folder, points DiskSweep at it (CFFIXED_USER_HOME) in snapshot mode,
# tidies the captures with polish_screenshot.swift, then deletes the made-up folder.
set -euo pipefail
cd "$(dirname "$0")/.."

DEMO_ROOT="$HOME/DSDemo"          # not under /tmp: Foundation rewrites /private/tmp paths, which breaks matching
DEMO="$DEMO_ROOT/Home"            # the folder name shows in Space Lens, so keep it neutral
RAW="$(mktemp -d)"
OUT=docs/screenshots
trap 'rm -rf "$DEMO_ROOT" "$RAW"' EXIT

mk() { mkdir -p "$(dirname "$DEMO/$1")"; head -c $(( $2 * 1048576 )) /dev/urandom > "$DEMO/$1"; }
old() { touch -a -m -t "$2" "$DEMO/$1"; }

echo "▸ Building a made-up home folder"
rm -rf "$DEMO_ROOT"; mkdir -p "$DEMO"; touch "$DEMO_ROOT/.metadata_never_index"
mk "Library/Caches/com.spotify.client/Data/cache.bin" 140
mk "Library/Caches/com.google.Chrome/Default/Cache/data_1" 85
mk "Library/Caches/com.microsoft.teams2/blob" 60
mk "Library/Caches/com.apple.Safari/WebKitCache" 30
mk "Library/Caches/Homebrew/downloads/node.bottle.tar.gz" 150
mk "Library/Caches/pip/http/wheels.bin" 45
mk "Library/Caches/com.figma.Desktop/cache" 70
mk "Library/Caches/us.zoom.xos/cache" 25
mk "Library/Logs/DiagnosticReports/crash.ips" 12
mk "Library/Logs/Zoom/zoom.log" 6
mk ".npm/_cacache/content" 95
mk ".cache/huggingface/hub/model.safetensors" 320
mk ".cache/torch/hub/resnet.pth" 90
mkdir -p "$DEMO/Projects/website" "$DEMO/Projects/rust-app"
echo '{}' > "$DEMO/Projects/website/package.json"; mk "Projects/website/node_modules/react/index.js" 210
echo '[package]' > "$DEMO/Projects/rust-app/Cargo.toml"; mk "Projects/rust-app/target/release/app.rlib" 160
mk "Downloads/Zoom.pkg" 40
mk "Downloads/Figma.dmg" 120
mk "Downloads/Holiday-Photos.zip" 60; mk "Downloads/Holiday-Photos/IMG_0001.jpg" 58
mk "Downloads/Invoice March.pdf" 2
cp "$DEMO/Downloads/Invoice March.pdf" "$DEMO/Downloads/Invoice March (1).pdf"
cp "$DEMO/Downloads/Invoice March.pdf" "$DEMO/Downloads/Invoice March (2).pdf"
mk "Downloads/Course Handbook.pdf" 4
cp "$DEMO/Downloads/Course Handbook.pdf" "$DEMO/Downloads/Course Handbook (1).pdf"
mk "Downloads/Lecture Recording.mp4" 260; old "Downloads/Lecture Recording.mp4" 202411100900
mk "Downloads/movie.mkv.crdownload" 150; old "Downloads/movie.mkv.crdownload" 202509010900
mk "Downloads/Wallpaper.png" 8
mk "Downloads/Beat Draft v2.wav" 45
mk "Music/Projects/Summer Anthem - Master.wav" 62
mk "Music/Projects/Summer Anthem - Unmastered.wav" 61
mk "Music/Projects/Hook Vocals Take 3.wav" 38
mk "Music/Projects/808 Bass Loop.wav" 12
mk "Music/Projects/Drum Loop 140bpm.wav" 14
mk "Music/Projects/Summer Anthem Stems.zip" 180
mk "Music/Projects/Late Night.flp" 3
mk "Music/Projects/Piano Chords Idea.wav" 22
mk "Music/Projects/Late Night (Remix).wav" 55
mk "Movies/Holiday 2023.mov" 420; old "Movies/Holiday 2023.mov" 202308150900
mk "Documents/Old Laptop Backup.zip" 310; old "Documents/Old Laptop Backup.zip" 202301050900
mk "Desktop/Screen Recording 2025-03-01.mov" 180; old "Desktop/Screen Recording 2025-03-01.mov" 202503010900
cp "$DEMO/Desktop/Screen Recording 2025-03-01.mov" "$DEMO/Documents/Screen Recording 2025-03-01.mov"
mk "Documents/Thesis Final.pdf" 6
mkdir -p "$DEMO/Applications/Old Game.app/Contents/MacOS"
cat > "$DEMO/Applications/Old Game.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.oldgame</string><key>CFBundleShortVersionString</key><string>2.1</string><key>CFBundleExecutable</key><string>OldGame</string></dict></plist>
EOF
mk "Applications/Old Game.app/Contents/MacOS/OldGame" 230
mk "Library/Application Support/Old Game/saves.dat" 15
mk "Library/Application Support/RetiredEditor/media-cache.bin" 85
mk ".Trash/old-export.mov" 90
mk ".Trash/notes.txt" 1

echo "▸ Capturing pages"
swift build -c release --triple arm64-apple-macosx26.0
DISKSWEEP_DEMO_SCREENSHOTS=1 CFFIXED_USER_HOME="$DEMO" DISKSWEEP_SNAPSHOT_DIR="$RAW" \
DISKSWEEP_SNAPSHOT_PAGES=dashboard,memory,speedSettings,downloads,music,spaceLens,duplicates,uninstaller,systemJunk,menubar \
    .build/arm64-apple-macosx/release/DiskSweep >/dev/null 2>&1

echo "▸ Polishing"
mkdir -p "$OUT"
for pair in 00-start:start 02-dashboard:smart-care 03-memory:memory 05-speedSettings:speed-settings \
            06-systemJunk:system-junk 10-downloads:downloads 14-duplicates:duplicates 15-spaceLens:space-lens \
            16-music:music 17-uninstaller:uninstaller; do
    swift Scripts/polish_screenshot.swift "$RAW/${pair%%:*}.png" "$OUT/${pair##*:}.png" 1600
done
sips -Z 380 "$RAW/99-menubar.png" --out "$OUT/menu-bar.png" >/dev/null
echo "✓ Screenshots in $OUT"
