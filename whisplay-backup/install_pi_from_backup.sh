#!/usr/bin/env bash
set -euo pipefail

echo "=== Whisplay Pi bootstrap (from backup) ==="

#-----------------------------
# 0. Basic sanity checks
#-----------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as a normal non-root user (e.g. 'pi')."
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "This script assumes 'sudo' is available."
  exit 1
fi

# Normalize user + home for all paths
PI_USER="${PI_USER:-${SUDO_USER:-$(whoami)}}"
PI_HOME="${PI_HOME:-$HOME}"

WHISPLAY_DIR="$PI_HOME/whisplay-ai-chatbot"
WHISPLAY_BACKUP_DIR="$PI_HOME/whisplay-chatbot-Qwen/whisplay-backup"

PIPER_DIR="$PI_HOME/piper"
PIPER_BIN="$PIPER_DIR/piper"
PIPER_VOICES_DIR="$PIPER_DIR/voices"

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
  libportaudio2 libasound2-plugins \
  python3-opencv python3-cairosvg \
  fonts-dejavu-core
  
# Do NOT keep Debian's 'piper' – it conflicts with piper-tts
sudo apt-get remove -y piper || true

#-----------------------------
# 1.B. Whisplay HAT audio driver (WM8960)
#-----------------------------
echo
echo ">> Installing / updating Whisplay HAT audio driver (WM8960)..."

WHISPLAY_HAT_DIR="$HOME/Whisplay"

# Clone or update the HAT driver repo
if [ ! -d "$WHISPLAY_HAT_DIR" ]; then
  git clone https://github.com/PiSugar/Whisplay.git --depth 1 "$WHISPLAY_HAT_DIR"
else
  cd "$WHISPLAY_HAT_DIR"
  git pull --rebase || true
fi

cd "$WHISPLAY_HAT_DIR/Driver"

if [ -f install_wm8960_drive.sh ]; then
  sudo bash install_wm8960_drive.sh
else
  echo "  - WARNING: install_wm8960_drive.sh not found in $WHISPLAY_HAT_DIR/Driver"
fi

cd "$HOME"
echo "  - Whisplay HAT driver install complete (reboot required for card to appear)."


#-----------------------------
# 1.C Install Ollama + model
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

#-----------------------------
# 2a. ALSA + HAT default sound card
#-----------------------------
echo
echo ">> Configuring ALSA to use Whisplay HAT (card 2) as default..."

sudo -u "$TARGET_USER" aplay -l || true

if aplay -l | grep -q "card 2: wm8960soundcard"; then
  echo "  - Detected Whisplay HAT as card 2, writing /etc/asound.conf..."

  sudo tee /etc/asound.conf >/dev/null <<EOF
defaults.pcm.card 2
defaults.ctl.card 2

pcm.!default {
    type hw
    card 2
}

ctl.!default {
    type hw
    card 2
}
EOF
else
  echo "  - WARNING: Whisplay HAT not detected as card 2."
  echo "  - Please run 'aplay -l' and adjust /etc/asound.conf manually if needed."
fi




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
# Ensure cairosvg is importable (fallback to pip if Debian package missing)
if ! python3 -c "import cairosvg" >/dev/null 2>&1; then
    echo ">> cairosvg not found in system packages, installing via pip..."
    python3 -m pip install --break-system-packages cairosvg
fi

#-----------------------------
# 5.B. Piper CLI + voice model
#-----------------------------
echo
echo ">> Installing Piper TTS binary and voice model..."
sudo apt update
sudo apt install -y piper

rm -f /home/pi/piper/piper.real

# Use the current user's home directory (works for 'pi', 'pi5ai', etc.)
PIPER_DIR="$HOME/piper"
PIPER_VOICE_DIR="$PIPER_DIR/voices"

# Ensure Piper directories exist and are owned by the current user
mkdir -p "$PIPER_VOICE_DIR"

# Symlink the piper binary from wherever it's installed (apt or pip)
if command -v piper >/dev/null 2>&1; then
  #mkdir -p "$PIPER_DIR"
   mkdir -p /home/pi/piper/voices
  #ln -sf "$(command -v piper)" "$PIPER_DIR/piper"
   ln -sf /home/pi/.local/bin/piper /home/pi/piper/piper
else
  echo "  - WARNING: 'piper' binary not found on PATH even after apt install."
  echo "    You may need to install it manually or ensure ~/.local/bin is on PATH."
fi

# Download the Amy voice model only if missing
if [ ! -f "$PIPER_VOICE_DIR/en_US-amy-medium.onnx" ]; then
  echo "  - Downloading Piper voice model (Amy, en_US-medium)..."
  wget -O "$PIPER_VOICE_DIR/en_US-amy-medium.onnx" \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx"

  wget -O "$PIPER_VOICE_DIR/en_US-amy-medium.onnx.json" \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json"
else
  echo "  - Piper voice model already present, skipping download."
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

  # Normalize user and paths inside the service file
  sudo sed -i \
    -e "s#/home/pi/whisplay-ai-chatbot#$WHISPLAY_DIR#g" \
    -e "s#/home/pi/#$PI_HOME/#g" \
    -e "s/User=pi/User=$PI_USER/g" \
    /etc/systemd/system/whisplay.service

  echo "  - Installed /etc/systemd/system/whisplay.service (user=$PI_USER, dir=$WHISPLAY_DIR)"
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



#-----------------------------
# X. Ensure UI font NotoSansSC-Bold.ttf exists
#-----------------------------
echo
echo ">> Ensuring NotoSansSC-Bold.ttf font for Python UI..."

FONT_SRC="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_DST="$WHISPLAY_DIR/python/NotoSansSC-Bold.ttf"

if [ -f "$FONT_SRC" ]; then
  if [ ! -f "$FONT_DST" ]; then
     cp "$FONT_SRC" "$FONT_DST"
    chown "$PI_USER:$PI_USER" "$FONT_DST"
    echo "  - Copied $FONT_SRC -> $FONT_DST"
  else
    echo "  - Font already present at $FONT_DST, skipping copy."
  fi
else
  echo "  - WARNING: Source font $FONT_SRC not found; UI may complain about NotoSansSC-Bold.ttf."
fi

