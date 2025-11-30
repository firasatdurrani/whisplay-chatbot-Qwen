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

# Check network connectivity
echo ">> Checking network connectivity..."
if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
  echo "  - Network connectivity OK"
else
  echo "  - WARNING: Cannot reach internet. Installation may fail."
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

# Normalize user + home for all paths
PI_USER="${PI_USER:-${SUDO_USER:-$(whoami)}}"
PI_HOME="${PI_HOME:-$HOME}"

WHISPLAY_DIR="$PI_HOME/whisplay-ai-chatbot"
WHISPLAY_BACKUP_DIR="$PI_HOME/whisplay-chatbot-Qwen/whisplay-backup"

PIPER_DIR="$PI_HOME/piper"
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
  
# Do NOT keep Debian's 'piper' — it conflicts with piper-tts
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
echo "  - Whisplay HAT driver install complete."
echo "  - NOTE: A reboot is required for the audio card to appear."

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

# Wait for Ollama service to be ready
echo ">> Waiting for Ollama service to start..."
for i in {1..30}; do
  if curl -s http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    echo "  - Ollama service is ready."
    break
  fi
  if [ $i -eq 30 ]; then
    echo "  - WARNING: Ollama service did not start within 30 seconds."
    echo "  - You may need to run 'ollama pull qwen3:1.7b' manually after installation."
  fi
  sleep 1
done

echo
echo ">> Ensuring Qwen model is downloaded..."

# Download the model - change qwen3:1.7b to your preferred model
if ! ollama list 2>/dev/null | awk '{print $1}' | grep -q '^qwen3:1.7b$'; then
  ollama pull qwen3:1.7b || echo "  - WARNING: Failed to pull model. Run 'ollama pull qwen3:1.7b' manually."
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
# 2a. ALSA + HAT default sound card - configured now, works after reboot
#-----------------------------
echo
echo ">> Pre-configuring ALSA for Whisplay HAT (will work after reboot)..."

# Check if card 2 exists (it won't until after reboot, but we check anyway)
aplay -l || true

if aplay -l 2>/dev/null | grep -q "card 2: wm8960soundcard"; then
  echo "  - Detected Whisplay HAT as card 2"
else
  echo "  - Whisplay HAT not yet visible (expected before reboot)"
fi

echo "  - Writing /etc/asound.conf for card 2..."
sudo tee /etc/asound.conf >/dev/null <<'EOF'
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

#------------------------------
# 3. Clone official Whisplay repo
#------------------------------
echo
echo ">> Cloning / updating official whisplay-ai-chatbot repo..."

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
# 4. Restore your backed-up config FIRST (before npm install)
#------------------------------
echo
echo ">> Restoring backup config (.env, service file, etc.)..."

BACKUP_DIR="$HOME/whisplay-chatbot-Qwen/whisplay-backup"

# .env — contains your current working environment
if [ -f "$BACKUP_DIR/env_actual.txt" ]; then
  cp "$BACKUP_DIR/env_actual.txt" "$WHISPLAY_DIR/.env"
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

# (Optional) piper model path info
if [ -f "$BACKUP_DIR/piper_models.txt" ]; then
  mkdir -p "$WHISPLAY_DIR/backup-notes"
  cp "$BACKUP_DIR/piper_models.txt" "$WHISPLAY_DIR/backup-notes/"
fi

#------------------------------
# 5. Node dependencies - FIX for obsolete zlib package
#------------------------------
echo
echo ">> Installing Node dependencies..."

# Configure npm for better reliability
npm config set registry https://registry.npmjs.org/
npm config set fetch-timeout 300000
npm config set fetch-retries 5

# Add ~/.local/bin to PATH for piper and other tools
if ! grep -q '.local/bin' "$HOME/.bashrc"; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"

# Install TypeScript globally first (needed for build)
echo "  - Installing TypeScript globally..."
npm install -g typescript --fetch-timeout=300000 || {
  echo "  - WARNING: Failed to install TypeScript globally"
}

cd "$WHISPLAY_DIR"

# CRITICAL FIX: Remove obsolete zlib package that breaks on Node 20+
if [ -f package.json ]; then
  if grep -q '"zlib"' package.json; then
    echo "  - Removing obsolete zlib package from package.json..."
    cp package.json package.json.backup
    # Use Python to safely remove zlib from dependencies
    python3 -c "
import sys, json
try:
    with open('package.json', 'r') as f:
        data = json.load(f)
    if 'dependencies' in data and 'zlib' in data['dependencies']:
        del data['dependencies']['zlib']
        print('  - Removed zlib from dependencies')
    with open('package.json', 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
except Exception as e:
    print(f'  - ERROR removing zlib: {e}', file=sys.stderr)
    sys.exit(1)
"
  fi
fi

# Clean any partial installs
rm -rf node_modules package-lock.json yarn.lock 2>/dev/null || true

# Configure for legacy compatibility
cat > .npmrc << 'EOF'
legacy-peer-deps=true
EOF

# Install Node packages with npm (more reliable than yarn)
echo "  - Installing Node packages with npm (this may take several minutes)..."
if npm install --legacy-peer-deps --fetch-timeout=300000; then
  echo "  - npm install successful"
  
  # Ensure TypeScript is installed locally if not already
  if ! [ -f "node_modules/.bin/tsc" ]; then
    echo "  - Installing TypeScript locally..."
    npm install --save-dev typescript @types/node --fetch-timeout=300000
  fi
  
  # Build the project
  echo "  - Building project..."
  if npm run build; then
    echo "  - Build successful"
  else
    echo "  - WARNING: Build failed. Check for errors above."
    echo "  - You may need to run 'npm run build' manually after fixing issues."
  fi
else
  echo "  - ERROR: npm install failed."
  echo "  - This may be due to network issues or package conflicts."
  echo "  - You can retry manually with:"
  echo "    cd ~/whisplay-ai-chatbot"
  echo "    npm install --legacy-peer-deps"
  echo "  - Continuing with rest of installation..."
fi

#------------------------------------
# 6. Python dependencies
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
# 7. Piper CLI + voice model
#-----------------------------
echo
echo ">> Installing Piper TTS binary and voice model..."

# Use the current user's home directory
PIPER_DIR="$HOME/piper"
PIPER_VOICE_DIR="$PIPER_DIR/voices"

# Ensure Piper directories exist
mkdir -p "$PIPER_VOICE_DIR"

# Create symlink to piper binary (installed via pip above)
if [ -f "$HOME/.local/bin/piper" ]; then
  ln -sf "$HOME/.local/bin/piper" "$PIPER_DIR/piper"
  echo "  - Linked piper binary from ~/.local/bin"
elif command -v piper >/dev/null 2>&1; then
  ln -sf "$(command -v piper)" "$PIPER_DIR/piper"
  echo "  - Linked piper binary from system PATH"
else
  echo "  - WARNING: 'piper' binary not found. It should be installed via pip."
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
# 8. Ensure UI font NotoSansSC-Bold.ttf exists
#-----------------------------
echo
echo ">> Ensuring NotoSansSC-Bold.ttf font for Python UI..."

FONT_SRC="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_DST="$WHISPLAY_DIR/python/NotoSansSC-Bold.ttf"

if [ -f "$FONT_SRC" ]; then
  if [ ! -f "$FONT_DST" ]; then
    mkdir -p "$(dirname "$FONT_DST")"
    cp "$FONT_SRC" "$FONT_DST"
    chown "$PI_USER:$PI_USER" "$FONT_DST"
    echo "  - Copied $FONT_SRC -> $FONT_DST"
  else
    echo "  - Font already present at $FONT_DST, skipping copy."
  fi
else
  echo "  - WARNING: Source font $FONT_SRC not found; UI may complain about NotoSansSC-Bold.ttf."
fi

#-----------------------------
# 9. Boot + Ready chimes (Whisplay HAT, card 2)
#-----------------------------
echo
echo ">> Setting up boot and ready chimes..."

BOOT_SOUNDS_DIR="$HOME/boot-sounds"
mkdir -p "$BOOT_SOUNDS_DIR"

# Generate simple stereo WAVs for boot and ready chimes
python3 - << 'EOF'
import os, math, struct, wave

base = os.path.expanduser("~/boot-sounds")
os.makedirs(base, exist_ok=True)

def make_beep(path, rate=48000, duration=0.4, freqs=(987.8,)):
    nframes = int(rate * duration)
    with wave.open(path, "w") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        for i in range(nframes):
            t = i / rate
            sample = sum(math.sin(2 * math.pi * f * t) for f in freqs) / len(freqs)
            edge = int(rate * 0.01)
            if i < edge:
                sample *= i / edge
            if i > nframes - edge:
                sample *= (nframes - i) / edge
            sample = max(-0.9, min(0.9, sample))
            val = int(sample * 32767)
            data = struct.pack("<hh", val, val)
            wf.writeframesraw(data)

def make_ready(path, rate=48000, duration=0.8, freq1=987.8, freq2=1318.5):
    nframes = int(rate * duration)
    half = nframes // 2
    with wave.open(path, "w") as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        for i in range(nframes):
            t = i / rate
            f = freq1 if i < half else freq2
            s = math.sin(2 * math.pi * f * t)
            edge = int(rate * 0.01)
            if i < edge:
                s *= i / edge
            if i > nframes - edge:
                s *= (nframes - i) / edge
            s = max(-0.9, min(0.9, s))
            val = int(s * 32767)
            data = struct.pack("<hh", val, val)
            wf.writeframesraw(data)

make_beep(os.path.join(base, "boot-chime.wav"))
make_ready(os.path.join(base, "ready-chime.wav"))
EOF

# Boot chime service
sudo tee /etc/systemd/system/boot-chime.service >/dev/null << EOF
[Unit]
Description=Boot Chime
After=sound.target

[Service]
Type=oneshot
ExecStart=/usr/bin/aplay -D plughw:2,0 $HOME/boot-sounds/boot-chime.wav

[Install]
WantedBy=multi-user.target
EOF

# Ready chime service
sudo tee /etc/systemd/system/ready-chime.service >/dev/null << EOF
[Unit]
Description=Ready Chime after Whisplay startup
After=whisplay.service sound.target

[Service]
Type=oneshot
ExecStart=/bin/bash -lc 'sleep 15; /usr/bin/aplay -D plughw:2,0 $HOME/boot-sounds/ready-chime.wav || true'

[Install]
WantedBy=multi-user.target
EOF

# Enable chime services
sudo systemctl daemon-reload
sudo systemctl enable boot-chime.service ready-chime.service

#-----------------------------
# 10. Enable whisplay service (but don't start until after reboot)
#-----------------------------
echo
echo ">> Enabling whisplay.service (will start after reboot)..."
sudo systemctl daemon-reload
sudo systemctl enable whisplay.service

echo
echo "==================================================================="
echo "=== Installation Complete - REBOOT REQUIRED ==="
echo "==================================================================="
echo
echo "IMPORTANT: The Whisplay HAT audio driver requires a reboot to take effect."
echo
echo "After rebooting:"
echo "  1. The audio card will appear as card 2 (wm8960soundcard)"
echo "  2. The whisplay service will start automatically"
echo "  3. You can check status with: sudo systemctl status whisplay.service"
echo
echo "To reboot now, run: sudo reboot"
echo
echo "If you need to verify the .env file has correct API keys:"
echo "  nano ~/whisplay-ai-chatbot/.env"
echo
echo "==================================================================="
