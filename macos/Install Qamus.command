#!/bin/bash
# Qamus macOS One-Click Installer
# Installs Qamus.app, removes Gatekeeper quarantine, installs Ollama + RAM-matched
# local Arabic models, and sets up the CAMeL Tools Arabic parser via uv.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/Qamus.app"
APP_DST="/Applications/Qamus.app"
CAMEL_DIR="$HOME/Library/Application Support/Qamus/camel_sidecar"

BOLD='\033[1m'
DIM='\033[2m'
TEAL='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

pause_exit() {
  echo ""
  read -r -p "Press Enter to close this window…" _
  exit "${1:-0}"
}

echo ""
echo -e "${BOLD}${TEAL}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${TEAL}║             Qamus · Arabic Reading Desk              ║${NC}"
echo -e "${BOLD}${TEAL}║             Local AI & CAMeL Installer               ║${NC}"
echo -e "${BOLD}${TEAL}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# 0. Sanity checks
if [ ! -d "$APP_SRC" ]; then
  echo -e "${RED}Error:${NC} Qamus.app was not found next to this installer."
  echo "Make sure you unzipped the entire Qamus-macOS.zip folder first."
  pause_exit 1
fi

ARCH="$(uname -m)"
MACOS_VER="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VER%%.*}"
RAM_GB="$(( $(sysctl -n hw.memsize) / 1073741824 ))"

echo -e "Detected Mac: ${BOLD}${ARCH}${NC} · ${BOLD}${RAM_GB} GB RAM${NC} · macOS ${BOLD}${MACOS_VER}${NC}"

if [ "$MACOS_MAJOR" -lt 26 ] 2>/dev/null; then
  echo -e "${YELLOW}Note:${NC} Qamus.app requires macOS 26 or newer (you are on macOS ${MACOS_VER})."
fi

# Choose optimal models for this Mac's unified memory
if [ "$RAM_GB" -ge 24 ]; then
  ANALYSIS_MODEL="qwen3:30b-a3b-instruct-2507-q4_K_M"
  VISION_MODEL="gemma3:12b"
  OCR_MODE="Hybrid Visual (Vision + gemma3:12b)"
  DL_ESTIMATE="~26 GB total (Qwen3 30B MoE + Gemma 3 12B Vision)"
elif [ "$RAM_GB" -ge 16 ]; then
  ANALYSIS_MODEL="gemma3:12b"
  VISION_MODEL=""
  OCR_MODE="Hybrid Visual (Vision + gemma3:12b)"
  DL_ESTIMATE="~8.2 GB (Gemma 3 12B for both Grammar & Hybrid Visual OCR)"
else
  ANALYSIS_MODEL="qwen3:4b"
  VISION_MODEL=""
  OCR_MODE="Apple Vision (Instant)"
  DL_ESTIMATE="~2.6 GB (Qwen3 4B + instant Apple Vision OCR)"
fi

echo ""
echo -e "${BOLD}What this installer will set up:${NC}"
echo "  1. Install Qamus.app into /Applications (and clear macOS quarantine)"
echo "  2. Install/start Ollama and download local Arabic models: ${DL_ESTIMATE}"
echo "  3. Install CAMeL Tools BERT Arabic parser (~1.5 GB, isolated in Application Support)"
echo "  4. Pre-configure Qamus for your ${RAM_GB} GB Mac and launch it"
echo ""
read -r -p "Continue with full setup? [Y/n] " GO_ALL
if [[ "${GO_ALL:-Y}" =~ ^[Nn]$ ]]; then
  echo "Cancelled."
  pause_exit 0
fi

# ------------------------------------------------------------------
# Step 1/4: Install Qamus.app
# ------------------------------------------------------------------
echo ""
echo -e "${BOLD}${TEAL}[1/4] Installing Qamus.app to /Applications…${NC}"
pkill -x QamusMac 2>/dev/null || true
pkill -f "camel_sidecar/server.py" 2>/dev/null || true
sleep 0.4

if [ -w "/Applications" ]; then
  rm -rf "$APP_DST"
  ditto "$APP_SRC" "$APP_DST"
else
  echo "Administrator password needed to copy Qamus.app into /Applications:"
  sudo rm -rf "$APP_DST"
  sudo ditto "$APP_SRC" "$APP_DST"
fi

xattr -cr "$APP_DST" 2>/dev/null || sudo xattr -cr "$APP_DST" 2>/dev/null || true
echo -e "${GREEN}✓ Installed /Applications/Qamus.app${NC}"

# ------------------------------------------------------------------
# Step 2/4: Ollama + Local Models
# ------------------------------------------------------------------
echo ""
echo -e "${BOLD}${TEAL}[2/4] Setting up Ollama & local Arabic models…${NC}"

export PATH="/opt/homebrew/bin:/usr/local/bin:/Applications/Ollama.app/Contents/Resources:$HOME/.local/bin:$PATH"

find_ollama() {
  for cand in \
    "$(command -v ollama 2>/dev/null || true)" \
    "/opt/homebrew/bin/ollama" \
    "/usr/local/bin/ollama" \
    "/Applications/Ollama.app/Contents/Resources/ollama"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
      echo "$cand"
      return 0
    fi
  done
  return 1
}

OLLAMA_BIN="$(find_ollama || true)"

if [ -z "$OLLAMA_BIN" ]; then
  echo "Ollama not found. Installing Ollama for macOS…"
  TMP_OLLAMA="$(mktemp -d)"
  curl -L --progress-bar "https://ollama.com/download/Ollama-darwin.zip" -o "$TMP_OLLAMA/Ollama-darwin.zip"
  ditto -xk "$TMP_OLLAMA/Ollama-darwin.zip" "$TMP_OLLAMA"
  if [ -d "$TMP_OLLAMA/Ollama.app" ]; then
    if [ -w "/Applications" ]; then
      rm -rf "/Applications/Ollama.app"
      mv "$TMP_OLLAMA/Ollama.app" "/Applications/Ollama.app"
    else
      sudo rm -rf "/Applications/Ollama.app"
      sudo mv "$TMP_OLLAMA/Ollama.app" "/Applications/Ollama.app"
    fi
    xattr -cr "/Applications/Ollama.app" 2>/dev/null || true
    open -a "/Applications/Ollama.app" || true
  fi
  rm -rf "$TMP_OLLAMA"
  OLLAMA_BIN="$(find_ollama || true)"
fi

if [ -z "$OLLAMA_BIN" ]; then
  echo -e "${YELLOW}! Could not locate Ollama CLI automatically.${NC}"
  echo "  Install Ollama from https://ollama.com/download and re-run this installer."
  pause_exit 1
fi

# Make sure Ollama server is running (start CLI daemon directly so first-run GUI dialogs don't block)
if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "Starting Ollama server…"
  nohup "$OLLAMA_BIN" serve >/tmp/qamus-ollama.log 2>&1 &
  for _ in $(seq 1 20); do
    sleep 1
    if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
      break
    fi
  done
  if [ -d "/Applications/Ollama.app" ]; then
    open -gj -a "/Applications/Ollama.app" 2>/dev/null || true
  fi
fi

if ! curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo -e "${YELLOW}! Ollama didn't respond on 127.0.0.1:11434 yet.${NC}"
  echo "  Try launching Ollama from /Applications, then re-run this installer."
  pause_exit 1
fi

echo "Pulling grammar analysis model: ${ANALYSIS_MODEL}…"
"$OLLAMA_BIN" pull "$ANALYSIS_MODEL"

if [ -n "$VISION_MODEL" ]; then
  echo ""
  echo "Pulling Hybrid Visual OCR model: ${VISION_MODEL}…"
  "$OLLAMA_BIN" pull "$VISION_MODEL"
fi
echo -e "${GREEN}✓ Local AI models ready${NC}"

# ------------------------------------------------------------------
# Step 3/4: CAMeL Tools Sidecar via uv (zero Homebrew needed!)
# ------------------------------------------------------------------
echo ""
echo -e "${BOLD}${TEAL}[3/4] Setting up CAMeL Tools Arabic Parser…${NC}"
mkdir -p "$CAMEL_DIR"
cp "$APP_DST/Contents/Resources/camel_sidecar/server.py" "$CAMEL_DIR/server.py"

CAMEL_OK=0
UV_BIN="$(command -v uv 2>/dev/null || true)"
if [ -z "$UV_BIN" ] && [ -x "$HOME/.local/bin/uv" ]; then
  UV_BIN="$HOME/.local/bin/uv"
fi
if [ -z "$UV_BIN" ] && [ -x "$HOME/.cargo/bin/uv" ]; then
  UV_BIN="$HOME/.cargo/bin/uv"
fi

if [ -z "$UV_BIN" ]; then
  echo "Installing uv (lightweight Python manager — no Homebrew needed)…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  UV_BIN="$(command -v uv 2>/dev/null || echo "$HOME/.local/bin/uv")"
fi

if [ -x "$UV_BIN" ]; then
  echo "Creating isolated Python 3.12 environment in Application Support…"
  "$UV_BIN" venv --python 3.12 --clear "$CAMEL_DIR/.venv"
  echo "Installing camel-tools (this takes ~1–2 minutes)…"
  "$UV_BIN" pip install --python "$CAMEL_DIR/.venv/bin/python" camel-tools setuptools wheel
  echo "Downloading NYU Abu Dhabi CAMeL Arabic morphology & BERT models…"
  "$CAMEL_DIR/.venv/bin/camel_data" -i morphology-db-msa-r13
  "$CAMEL_DIR/.venv/bin/camel_data" -i disambig-bert-unfactored-msa
  CAMEL_OK=1
  echo -e "${GREEN}✓ CAMeL Arabic Parser ready${NC}"
else
  echo -e "${YELLOW}! Skipping CAMeL Tools (uv failed to install). Qamus still works with Buckwalter + Ollama.${NC}"
fi

# ------------------------------------------------------------------
# Step 4/4: Pre-configure Qamus defaults & launch
# ------------------------------------------------------------------
echo ""
echo -e "${BOLD}${TEAL}[4/4] Configuring Qamus for your ${RAM_GB} GB Mac…${NC}"
defaults write com.alqamus.Qamus qamus.mac.ui -string "desk"
defaults write com.alqamus.Qamus qamus.mac.ai.backend -string "Local MLX / Ollama"
defaults write com.alqamus.Qamus qamus.mac.ai.endpoint -string "http://127.0.0.1:11434/v1/chat/completions"
defaults write com.alqamus.Qamus qamus.mac.ai.model -string "$ANALYSIS_MODEL"
defaults write com.alqamus.Qamus qamus.mac.ai.reasoning -bool false
defaults write com.alqamus.Qamus qamus.mac.ocr.mode -string "$OCR_MODE"
defaults write com.alqamus.Qamus qamus.mac.ocr.autoExplain -bool true
if [ "$CAMEL_OK" -eq 1 ]; then
  defaults write com.alqamus.Qamus qamus.mac.camel.enabled -bool true
else
  defaults write com.alqamus.Qamus qamus.mac.camel.enabled -bool false
fi

echo ""
echo -e "${BOLD}${GREEN}✅ All done! Launching Qamus…${NC}"
echo ""
echo -e "${BOLD}Quick shortcuts inside Qamus:${NC}"
echo "  ⌘⇧V       Paste Arabic text or a PDF screenshot (runs OCR straight into the reader)"
echo "  ← / →     Step word-by-word through a text (cached words switch instantly)"
echo "  S         1-click save word + contextual meaning + highlighted sentence"
echo "  ⌘K        Quick dictionary search"
echo "  Toolbar ⚙ Switch AI model, OCR engine, or CAMeL parser anytime"
echo "  Bottom-left: Click 'Sign in to sync phone' to sync saved flashcards to alqamus.pages.dev"
echo ""

open "$APP_DST"
pause_exit 0
