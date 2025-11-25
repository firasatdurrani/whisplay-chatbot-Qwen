#!/usr/bin/env bash
set -euo pipefail

echo "=== Whisplay Pi bootstrap (from backup) ==="

#-----------------------------
# 0. Basic sanity checks
#-----------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as the 'pi' user, not as root."
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "This script assumes 'sudo' is available."
  exit 1
fi

#-----------------------------
# 1. System packages
#-----------------------------
echo
echo ">> Updating APT and installing base packages..."
sudo apt update
sudo apt install -y \
  git curl build-essential \
  python3 python3-pip python3-venv \
  ffmpeg sox alsa-utils \
 libportaudio2 libasound2-plugins


#-----------------------------
# 1.B Install Ollama + model
#-----------------------------
echo
echo ">> Installing Ollama (ARM64) if missing..."

if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
else
  echo "  - Ollama already installed, skipping."
fi

echo
echo ">> Ensuring Qwen model is downloaded..."

# Change qwen2:1.5b to whatever tag you actually use
if ! ollama list | awk '{print $1}' | grep -q '^qwen3:1.7b$'; then
  ollama pull qwen3:1.7b
fi


#-----------------------------
# 2. Install nvm + Node 20.19.5
#-----------------------------
echo
echo ">> Ensuring nvm + Node 20.19.5..."

if [ ! -d "$HOME/.nvm" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi

export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1090
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

if ! nvm ls 20.19.5 >/dev/null 2>&1; then
  nvm install 20.19.5
fi
nvm alias default 20.19.5
nvm use 20.19.5

#------------------------------
# 3. Clone official Whisplay repo
#------------------------------
echo
echo ">> Cloning / updating official whisplay-ai-chatbot repo..."

WHISPLAY_DIR="/home/pi/whisplay-ai-chatbot"

cd "$HOME"

# If the directory exists but is empty or not a git repo, remove it first
if [ -d "$WHISPLAY_DIR" ] && [ ! -d "$WHISPLAY_DIR/.git" ]; then
    rm -rf "$WHISPLAY_DIR"
fi

# Clone if missing, otherwise update
if [ ! -d "$WHISPLAY_DIR" ]; then
    git clone https://github.com/PiSugar/whisplay-ai-chatbot.git "$WHISPLAY_DIR"
else
    cd "$WHISPLAY_DIR"
    git fetch --all
    git reset --hard origin/main
fi

cd "$WHISPLAY_DIR"

#------------------------------
# 4. Node dependencies (yarn)
#------------------------------
echo
echo ">> Installing Node dependencies (yarn)..."

if ! command -v corepack >/dev/null 2>&1; then
    npm install -g corepack
fi

corepack enable || true

if ! command -v yarn >/dev/null 2>&1; then
    npm install -g yarn
fi

# run inside /home/pi/whisplay-ai-chatbot
yarn install
yarn build


#------------------------------------
# 5. Python dependencies
#------------------------------------

echo
echo ">> Installing Python deps (whisper, TTS, etc.)..."

# Install globally, bypassing the Debian guard (Bookworm)
python3 -m pip install --upgrade pip --break-system-packages

# Core packages: STT (whisper) + TTS (piper-tts) + audio I/O (soundfile)
python3 -m pip install --break-system-packages openai-whisper piper-tts soundfile

# If the official project has a requirements file, install that too
if [ -f requirements.txt ]; then
    python3 -m pip install --break-system-packages -r requirements.txt
fi


#-----------------------------
# 5.B. Piper CLI + voice model
#-----------------------------
echo
echo ">> Installing Piper TTS binary and voice model..."

# Install piper CLI from APT if not already present
if ! command -v piper >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y piper
else
  echo "  - Piper CLI already installed, skipping apt install."
fi

# Ensure expected directory layout
mkdir -p /home/pi/piper/voices

# Symlink the piper binary to the hard-coded path Whisplay expects
if [ ! -e /home/pi/piper/piper ]; then
  ln -sf "$(command -v piper)" /home/pi/piper/piper
  echo "  - Symlinked piper -> $(command -v piper)"
fi

# Download the Amy voice model only if missing
cd /home/pi/piper/voices

if [ ! -f en_US-amy-medium.onnx ]; then
  wget -O en_US-amy-medium.onnx \
    https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx
fi

if [ ! -f en_US-amy-medium.onnx.json ]; then
  wget -O en_US-amy-medium.onnx.json \
    https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json
fi



#-----------------------------
# 6. Restore your backed-up config from GitHub repo
#-----------------------------
echo
echo ">> Restoring backup config (.env, service file, etc.)..."

BACKUP_DIR="$HOME/whisplay-chatbot-Qwen/whisplay-backup"

# .env – contains your current working environment
if [ -f "$BACKUP_DIR/env_actual.txt" ]; then
  cp "$BACKUP_DIR/env_actual.txt" "$HOME/whisplay-ai-chatbot/.env"
  echo "  - Restored .env from env_actual.txt"
else
  echo "  - NOTE: env_actual.txt not found, you'll need to create .env manually."
fi

# systemd service
if [ -f "$BACKUP_DIR/whisplay.service.txt" ]; then
  sudo cp "$BACKUP_DIR/whisplay.service.txt" /etc/systemd/system/whisplay.service
  echo "  - Installed /etc/systemd/system/whisplay.service"
fi

# (Optional) piper model path info lands where you want it
if [ -f "$BACKUP_DIR/piper_models.txt" ]; then
  mkdir -p "$HOME/whisplay-ai-chatbot/backup-notes"
  cp "$BACKUP_DIR/piper_models.txt" "$HOME/whisplay-ai-chatbot/backup-notes/"
fi

#-----------------------------
# 7. systemd reload + enable
#-----------------------------
echo
echo ">> Enabling whisplay.service..."
sudo systemctl daemon-reload
sudo systemctl enable whisplay.service
sudo systemctl restart whisplay.service || true

echo
echo "=== Done. ==="
echo "Check status with:"
echo "  sudo systemctl status whisplay.service"
echo
echo "If .env has API keys, open it once to confirm they're correct:"
echo "  nano ~/whisplay-ai-chatbot/.env"
