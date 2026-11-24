#!/bin/sh
# Builds a standalone, native macOS Qamus.app bundle in macos/build/Qamus.app
# without modifying any website files.
set -e

DIST_MODE=0
if [ "${1:-}" = "--dist" ]; then
  DIST_MODE=1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Qamus.app"

echo "1/5 Building fresh web bundle (dist/)…"
sh "$REPO_ROOT/scripts/build-site.sh"

echo "2/5 Compiling QamusMac (Swift 6 release)…"
cd "$SCRIPT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/QamusMac"
if [ ! -f "$BIN_PATH" ]; then
  echo "Error: compiled binary not found at $BIN_PATH" >&2
  exit 1
fi

# The Mac app's own icon is the Desk logo (macos/icon/AppIcon.png, 1024px, made by macos/icon/render-icon.js).
# The website keeps its green icon-512.png; this falls back to it only if the Mac icon is missing.
ICON_SRC="$SCRIPT_DIR/icon/AppIcon.png"
[ -f "$ICON_SRC" ] || ICON_SRC="$REPO_ROOT/icon-512.png"
echo "3/5 Generating AppIcon.icns from ${ICON_SRC#$REPO_ROOT/}…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET" "$APP_BUNDLE"
mkdir -p "$ICONSET" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

for s in 16 32 128 256 512; do
  sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "4/5 Assembling Qamus.app bundle…"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/QamusMac"
cp -R "$REPO_ROOT/dist" "$APP_BUNDLE/Contents/Resources/web"
# The Reading Desk UI ships only inside the Mac app. It is deliberately not in dist/,
# so a website deploy never picks it up. It shares engine.js and data/ with the classic UI.
mkdir -p "$APP_BUNDLE/Contents/Resources/web/redesign"
cp "$REPO_ROOT/redesign/index.html" "$REPO_ROOT/redesign/app.js" "$REPO_ROOT/redesign/style.css" \
   "$APP_BUNDLE/Contents/Resources/web/redesign/"
# Bundle the CAMeL sidecar script inside the app so any Mac can pair it with
# ~/Library/Application Support/Qamus/camel_sidecar/.venv without hardcoding local paths.
mkdir -p "$APP_BUNDLE/Contents/Resources/camel_sidecar"
cp "$SCRIPT_DIR/camel_sidecar/server.py" "$SCRIPT_DIR/camel_sidecar/setup-camel.sh" \
   "$APP_BUNDLE/Contents/Resources/camel_sidecar/"

DEV_SIDECAR_PLIST=""
if [ "$DIST_MODE" -eq 0 ]; then
  DEV_SIDECAR_PLIST="  <key>QamusCamelSidecarDir</key>
  <string>$SCRIPT_DIR/camel_sidecar</string>"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>QamusMac</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.alqamus.Qamus</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Qamus</string>
  <key>CFBundleDisplayName</key>
  <string>Qamus</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.1</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
$DEV_SIDECAR_PLIST
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

echo "5/5 Signing Qamus.app (ad-hoc local signature)…"
codesign --force --deep --sign - "$APP_BUNDLE"

echo ""
echo "✅ Built: $APP_BUNDLE ($(du -sh "$APP_BUNDLE" | cut -f1))"
echo "   Launch:  open \"$APP_BUNDLE\""
echo "   Install: cp -R \"$APP_BUNDLE\" /Applications/"
