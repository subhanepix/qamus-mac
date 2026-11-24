#!/bin/sh
# Builds a clean, portable Qamus-macOS.zip release bundle containing:
#   - Qamus.app (self-contained, no personal local paths in Info.plist)
#   - Install Qamus.command (double-clickable installer for Ollama, models & CAMeL)
#   - README.txt (quick-start instructions)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
STAGE_DIR="$BUILD_DIR/Qamus-macOS"
ZIP_OUT="$BUILD_DIR/Qamus-macOS.zip"

# 1. Build clean distributable Qamus.app (--dist omits local dev sidecar path)
sh "$SCRIPT_DIR/build-app.sh" --dist

# 2. Assemble release folder
echo ""
echo "Packaging Qamus-macOS.zip…"
rm -rf "$STAGE_DIR" "$ZIP_OUT"
mkdir -p "$STAGE_DIR"

ditto "$BUILD_DIR/Qamus.app" "$STAGE_DIR/Qamus.app"
cp "$SCRIPT_DIR/Install Qamus.command" "$STAGE_DIR/Install Qamus.command"
chmod +x "$STAGE_DIR/Install Qamus.command"

cat > "$STAGE_DIR/README.txt" << 'EOF'
Qamus · Native Arabic Reading Desk & On-Device Grammar AI (macOS)
=================================================================

Requirements
------------
- Apple Silicon Mac (M1 / M2 / M3 / M4) running macOS 26+
- 16 GB+ RAM recommended (24 GB+ gets the full Qwen3 30B + Gemma 3 12B Hybrid OCR setup)

Quick Install (Recommended)
---------------------------
1. Double-click "Install Qamus.command".
   (If macOS says it's from an unidentified developer: right-click "Install Qamus.command"
    -> Open -> Open.)
2. Press Enter when prompted. The installer automatically:
   - Moves Qamus.app to /Applications and clears macOS Gatekeeper quarantine
   - Installs/starts Ollama and pulls the best local Arabic models for your Mac's RAM
   - Installs CAMeL Tools (NYU Abu Dhabi BERT Arabic diacritizer) in ~/Library/Application Support/Qamus
   - Pre-configures Qamus and launches it

Shortcuts
---------
- Cmd+Shift+V : Paste Arabic text or a PDF screenshot (runs OCR straight into the reader)
- Left / Right: Step through words in a passage
- S           : 1-click save word + contextual meaning + highlighted sentence
- Cmd+K       : Instant dictionary search
- Toolbar ⚙   : Switch local AI models, OCR engine, CAMeL parser, or Auto-analyze
- Bottom-left : Click "Sign in to sync phone" to sync saved vocabulary with alqamus.pages.dev
EOF

# 3. Create macOS-safe zip preserving bundles, executable bits & signatures
ditto -c -k --sequesterRsrc --keepParent "$STAGE_DIR" "$ZIP_OUT"

echo ""
echo "✅ Release package ready:"
echo "   Zip:    $ZIP_OUT ($(du -sh "$ZIP_OUT" | cut -f1))"
echo "   Folder: $STAGE_DIR"
