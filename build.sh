#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/../outputs/RTL Fixer.app"
CONTENTS="$OUT/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
BUILD="$ROOT/.build"
ICON_PNG="$BUILD/RTLViewerIcon.png"
ICONSET="$BUILD/RTLViewerIcon.iconset"

rm -rf "$OUT"
mkdir -p "$MACOS" "$RESOURCES" "$BUILD"

swiftc \
  "$ROOT/Sources/RTLUniversalFixer/main.swift" \
  -o "$MACOS/RTL Fixer" \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  -framework NaturalLanguage \
  -framework Vision

swiftc "$ROOT/Sources/MakeIcon.swift" -o "$BUILD/make-icon" -framework AppKit
"$BUILD/make-icon" "$ICON_PNG"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$ICON_PNG" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$RESOURCES/RTLViewerIcon.icns"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>RTL Fixer</string>
  <key>CFBundleIdentifier</key>
  <string>com.local.rtl-fixer</string>
  <key>CFBundleName</key>
  <string>RTL Fixer</string>
  <key>CFBundleDisplayName</key>
  <string>RTL Fixer</string>
  <key>CFBundleIconFile</key>
  <string>RTLViewerIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Local utility</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$OUT" >/dev/null
echo "$OUT"
