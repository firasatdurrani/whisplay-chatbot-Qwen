#!/usr/bin/env bash
set -euo pipefail

echo "==========================================="
echo "  Whisplay Pi5 AI – Install from Backup"
echo "==========================================="
echo

#-----------------------------
# 0. Sanity checks
#-----------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "Run this script as a normal user (pi/pi5ai), not as root."
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required but not installed."
  exit 1
fi

#-----------------------------
# 1. Apt packages
#-----------------------------
echo ">> Updating apt and installing base dependencies..."
sudo apt-get update

sudo apt-get install -y \
  git curl build-essential \
  python3 python3-pip python3-venv \
  ffmpeg sox alsa-utils libportaudio2 libasound2-plugins \
  python3-opencv python3-cairosvg \
  fonts-dejavu-core

# Do NOT keep Debian's 'piper' – it conflicts with piper-tts
sudo apt-get remove -y piper || true

#-----------------------------
# 2. Detect target user (pi or pi5ai)
#-----------------------------
echo
echo ">> Detecting target user (pi or pi5ai)..."

TARGET_USER=""
if id -u pi >/dev/null 2>&1; then
  TARGET_USER="pi"
elif id -u pi5ai >/dev/null 2>&1; then
  TARGET_USER="pi5ai"
else
  echo "Neither 'pi' nor 'pi5ai' user exists. Aborting."
  exit 1
fi

echo "  - Using user: $TARGET_USER"

TARGET_HOME=$(eval echo "~$TARGET_USER")
WHISPLAY_DIR="$TARGET_HOME/whisplay-chatbot-Qwen"
BACKUP_DIR="$TARGET_HOME/whisplay-backup"
NVM_DIR="$TARGET_HOME/.nvm"

# make sure HOME is correct under sudo -u
export HOME="$TARGET_HOME"

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

#-----------------------------
# 2b. Ensure HAT driver service
#-----------------------------
echo
echo ">> Ensuring wm8960-soundcard.service is enabled..."

if systemctl list-unit-files | grep -q wm8960-soundcard.service; then
  sudo systemctl enable wm8960-soundcard.service
  sudo systemctl restart wm8960-soundcard.service || true
else
  echo "  - WARNING: wm8960-soundcard.service not found. Install the HAT driver package first."
fi

#-----------------------------
# 2c. Configure Pi fan (active cooler)
#-----------------------------
echo
echo ">> Configuring Pi active cooler fan (GPIO 18)..."

CONFIG_TXT="/boot/firmware/config.txt"
if [ ! -f "$CONFIG_TXT" ] && [ -f "/boot/config.txt" ]; then
  CONFIG_TXT="/boot/config.txt"
fi

if [ -f "$CONFIG_TXT" ]; then
  if ! sudo grep -q "dtoverlay=gpio-fan" "$CONFIG_TXT"; then
    echo "  - Adding gpio-fan overlay to $CONFIG_TXT"
    sudo tee -a "$CONFIG_TXT" >/dev/null <<'EOF'
# Whisplay: keep Pi5 fan active under load
dtoverlay=gpio-fan,gpiopin=18,temp=40000
EOF
  else
    echo "  - gpio-fan overlay already present, leaving as-is."
  fi
else
  echo "  - WARNING: Could not find config.txt to configure fan."
fi

#-----------------------------
# 3. Clone Whisplay repo (if not present)
#-----------------------------
echo
echo ">> Cloning / updating Whisplay repo..."

if [ ! -d "$WHISPLAY_DIR/.git" ]; then
  sudo -u "$TARGET_USER" git clone https://github.com/PiSugar/whisplay-ai-chatbot.git "$WHISPLAY_DIR"
else
  echo "  - Repo already exists at $WHISPLAY_DIR, pulling latest..."
  sudo -u "$TARGET_USER" git -C "$WHISPLAY_DIR" pull --ff-only || true
fi

# Optional: ensure specific branch/tag if you use one
# sudo -u "$TARGET_USER" git -C "$WHISPLAY_DIR" checkout Pi5AI || true

#-----------------------------
# 4. Python venv + dependencies
#-----------------------------
echo
echo ">> Setting up Python virtualenv and dependencies..."

sudo -u "$TARGET_USER" bash <<EOF
set -e
cd "$WHISPLAY_DIR"

if [ ! -d "venv" ]; then
  python3 -m venv venv
fi

. venv/bin/activate

# Upgrade pip and install requirements with --break-system-packages
python -m pip install --upgrade --break-system-packages pip

if [ -f backend/requirements.txt ]; then
  python -m pip install --break-system-packages -r backend/requirements.txt
fi

if [ -f python/requirements.txt ]; then
  python -m pip install --break-system-packages -r python/requirements.txt
fi
EOF

# Ensure cairosvg is importable even if installed system-wide
if [ -d "/usr/lib/python3/dist-packages/cairosvg" ]; then
  echo "  - Linking system cairosvg into whisplay python/ folder..."
  sudo -u "$TARGET_USER" mkdir -p "$WHISPLAY_DIR/python"
  sudo -u "$TARGET_USER" ln -sf /usr/lib/python3/dist-packages/cairosvg "$WHISPLAY_DIR/python/cairosvg_link"
fi

#-----------------------------
# 5. Piper TTS – FIXED INSTALL
#-----------------------------
echo
echo ">> Installing Piper TTS (piper-tts via pip + Amy voice)..."

# Make sure no stray old wrapper from earlier experiments
sudo -u "$TARGET_USER" rm -f "$TARGET_HOME/piper/piper.real" || true

sudo -u "$TARGET_USER" python3 -m pip install --user --break-system-packages \
  piper-tts soundfile numpy

sudo -u "$TARGET_USER" bash <<'EOS'
set -e
PIPER_ROOT="$HOME/piper"
VOICE_NAME="en_US-amy-medium"
VOICE_DIR="$PIPER_ROOT/voices"

mkdir -p "$VOICE_DIR"

# Stable wrapper that always calls user-local piper
mkdir -p "$PIPER_ROOT"
cat >"$PIPER_ROOT/piper" <<'EOF'
#!/usr/bin/env bash
exec "$HOME/.local/bin/piper" "$@"
EOF
chmod +x "$PIPER_ROOT/piper"

MODEL_PATH="$VOICE_DIR/${VOICE_NAME}.onnx"

if [ ! -f "$MODEL_PATH" ]; then
  echo "  - Downloading Piper voice: $VOICE_NAME"
  wget -q \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx" \
    -O "$VOICE_DIR/en_US-amy-medium.onnx"
  wget -q \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json" \
    -O "$VOICE_DIR/en_US-amy-medium.onnx.json"
else
  echo "  - Voice model already present, skipping download."
fi

echo "  - Running Piper self-test..."
echo "Piper test OK" | "$PIPER_ROOT/piper" \
  --model "$MODEL_PATH" \
  --output_file /tmp/piper_install_test.wav || echo "  - WARNING: Piper test failed (check manually)."
EOS

#-----------------------------
# 6. Node.js (via nvm) + yarn + build
#-----------------------------
echo
echo ">> Installing Node.js (via nvm) and building frontend..."

if [ ! -d "$NVM_DIR" ]; then
  sudo -u "$TARGET_USER" bash <<EOF
set -e
export HOME="$TARGET_HOME"
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
EOF
fi

# Load nvm inside a sudo -u shell and install Node 20 + yarn
sudo -u "$TARGET_USER" bash <<EOF
set -e
export HOME="$TARGET_HOME"
export NVM_DIR="$NVM_DIR"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"

nvm install 20
nvm alias default 20
nvm use 20

cd "$WHISPLAY_DIR"
npm install -g yarn

# Install and build frontend
yarn --cwd frontend install --frozen-lockfile
yarn --cwd frontend build
EOF

#-----------------------------
# 7. Restore from backup folder
#-----------------------------
echo
echo ">> Restoring files from backup (if present)..."

if [ -d "$BACKUP_DIR" ]; then
  echo "  - Using backup dir: $BACKUP_DIR"

  # Python files
  if [ -f "$BACKUP_DIR/whisplay_hat_nolcd.py" ]; then
    cp "$BACKUP_DIR/whisplay_hat_nolcd.py" "$WHISPLAY_DIR/python/whisplay_hat_nolcd.py"
    echo "  - Restored python/whisplay_hat_nolcd.py"
  fi

  if [ -f "$BACKUP_DIR/whisplay_hat_display_server.py" ]; then
    cp "$BACKUP_DIR/whisplay_hat_display_server.py" "$WHISPLAY_DIR/python/whisplay_hat_display_server.py"
    echo "  - Restored python/whisplay_hat_display_server.py"
  fi

  # frontend files
  if [ -f "$BACKUP_DIR/Home.tsx" ]; then
    cp "$BACKUP_DIR/Home.tsx" "$WHISPLAY_DIR/frontend/src/pages/Home.tsx"
    echo "  - Restored frontend/src/pages/Home.tsx"
  fi

  if [ -f "$BACKUP_DIR/chat.ts" ]; then
    cp "$BACKUP_DIR/chat.ts" "$WHISPLAY_DIR/frontend/src/utils/chat.ts"
    echo "  - Restored frontend/src/utils/chat.ts"
  fi

  if [ -f "$BACKUP_DIR/openai.ts" ]; then
    cp "$BACKUP_DIR/openai.ts" "$WHISPLAY_DIR/backend/app/api/openai.ts"
    echo "  - Restored backend/app/api/openai.ts"
  fi

  if [ -f "$BACKUP_DIR/constants.ts" ]; then
    cp "$BACKUP_DIR/constants.ts" "$WHISPLAY_DIR/frontend/src/utils/constants.ts"
    echo "  - Restored frontend/src/utils/constants.ts"
  fi

  # .env from backup
  if [ -f "$BACKUP_DIR/env_actual.txt" ]; then
    cp "$BACKUP_DIR/env_actual.txt" "$WHISPLAY_DIR/.env"
    echo "  - Restored .env from env_actual.txt"
  else
    echo "  - NOTE: env_actual.txt not found, you'll need to create .env manually."
  fi

  # systemd service from backup (optional)
  if [ -f "$BACKUP_DIR/whisplay.service.txt" ]; then
    sudo cp "$BACKUP_DIR/whisplay.service.txt" /etc/systemd/system/whisplay.service
    echo "  - Installed /etc/systemd/system/whisplay.service from backup"
  fi
else
  echo "  - No backup dir at $BACKUP_DIR – skipping backup restore."
fi

#-----------------------------
# 7b. Patch .env for Piper paths
#-----------------------------
echo
echo ">> Ensuring .env has correct Piper configuration..."

ENV_PATH="$WHISPLAY_DIR/.env"
if [ -f "$ENV_PATH" ]; then
  sudo -u "$TARGET_USER" bash <<EOF
set -e
ENV_PATH="$ENV_PATH"

# Replace existing keys if they exist
sed -i 's/^TTS_SERVER=.*/TTS_SERVER=PIPER/' "\$ENV_PATH" || true
sed -i 's|^PIPER_EXE=.*|PIPER_EXE=$TARGET_HOME/piper/piper|' "\$ENV_PATH" || true
sed -i 's|^PIPER_VOICES_DIR=.*|PIPER_VOICES_DIR=$TARGET_HOME/piper/voices|' "\$ENV_PATH" || true
sed -i 's/^PIPER_VOICE=.*/PIPER_VOICE=en_US-amy-medium/' "\$ENV_PATH" || true

# Append if missing
grep -q '^TTS_SERVER=' "\$ENV_PATH" || echo 'TTS_SERVER=PIPER' >>"\$ENV_PATH"
grep -q '^PIPER_EXE=' "\$ENV_PATH" || echo 'PIPER_EXE='"$TARGET_HOME"'/piper/piper' >>"\$ENV_PATH"
grep -q '^PIPER_VOICES_DIR=' "\$ENV_PATH" || echo 'PIPER_VOICES_DIR='"$TARGET_HOME"'/piper/voices' >>"\$ENV_PATH"
grep -q '^PIPER_VOICE=' "\$ENV_PATH" || echo 'PIPER_VOICE=en_US-amy-medium' >>"\$ENV_PATH"
EOF
  echo "  - .env Piper config patched."
else
  echo "  - WARNING: .env not found at $ENV_PATH – Piper ENV not patched."
fi

#-----------------------------
# 8. systemd service for Whisplay
#-----------------------------
echo
echo ">> Ensuring systemd service for Whisplay..."

if [ ! -f /etc/systemd/system/whisplay.service ]; then
  echo "  - Creating /etc/systemd/system/whisplay.service"

  sudo tee /etc/systemd/system/whisplay.service >/dev/null <<EOF
[Unit]
Description=Whisplay AI Chatbot
After=network-online.target sound.target

[Service]
Type=simple
User=$TARGET_USER
WorkingDirectory=$WHISPLAY_DIR
Environment=HOME=$TARGET_HOME
Environment=NVM_DIR=$NVM_DIR
ExecStart=/usr/bin/env bash -lc '
  export NVM_DIR="$NVM_DIR"
  [ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
  nvm use 20 >/dev/null 2>&1 || true
  cd "$WHISPLAY_DIR"
  . venv/bin/activate
  node -r ts-node/register/transpile-only -r tsconfig-paths/register dist/index.js
'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
fi

sudo systemctl daemon-reload
sudo systemctl enable whisplay.service
sudo systemctl restart whisplay.service || true

echo
echo "Whisplay service started (or restarting)."
echo "Check status with:"
echo "  sudo systemctl status whisplay.service"
echo
echo "If .env has API keys, you can confirm them with:"
echo "  nano $WHISPLAY_DIR/.env"

#-----------------------------
# 9. Ensure UI font exists
#-----------------------------
echo
echo ">> Ensuring NotoSansSC-Bold.ttf font for Python UI..."

FONT_SRC="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_DST_DIR="$WHISPLAY_DIR/python/ui"
FONT_DST="$FONT_DST_DIR/NotoSansSC-Bold.ttf"

if [ -f "$FONT_SRC" ]; then
  sudo -u "$TARGET_USER" mkdir -p "$FONT_DST_DIR"
  sudo -u "$TARGET_USER" cp "$FONT_SRC" "$FONT_DST"
  echo "  - Copied $FONT_SRC -> $FONT_DST"
else
  echo "  - WARNING: $FONT_SRC not found, UI may fall back to default font."
fi

echo
echo "==========================================="
echo "  Install complete."
echo "  Voice, fan, ALSA, and service are wired."
echo "==========================================="
