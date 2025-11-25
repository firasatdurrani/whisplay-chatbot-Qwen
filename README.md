# 📟 Whisplay-Chatbot-Qwen
Runs locally with Ollama + Qwen 3.1:7B + Whisper ASR + Piper TTS on a Raspberry Pi 5 with zero cloud dependency.

## Overview

This project turns a Raspberry Pi 5 into a fully offline voice chatbot device powered by:
	•	Local LLM: Qwen 3.1 7B via Ollama
	•	Speech-to-Text: OpenAI Whisper (local)
	•	Text-to-Speech: Piper (local) with high-quality English voices
	•	Hardware Frontend: PiSugar Whisplay HAT (microphone, speaker, RGB display, button)
	•	Cooler Fan Control
	•	Automatic Service Setup (systemd) for always-on operation

After installation, the Pi boots straight into a hands-free voice AI device with:
	•	LED display animations
	•	Push-to-talk button
	•	Offline, private processing
	•	Stable audio in/out
	•	Multilingual speech support

It is designed to be run as a plug & play service

##🧰 Hardware Requirements

Raspberry Pi 5 (8GB or 16GB) - Required for LLM runtime performance
Raspberry Pi 5 Active Cooler - Required (installer auto-configures fan)
PiSugar Whisplay HAT - Microphone, speaker, RGB display, button
PiSugar WM8960 Soundcard Driver - Installed automatically
USB-C 27W+ Power Supply - Recommended
MicroSD card (32–64GB+, Class A2) - Faster model loading
Optional: PiSugar battery pack - For portable usage

##🧪 Software Stack

Runtime
	•	Debian Trixie (64-bit) – Raspberry Pi OS
	•	Node.js 20 – Display and control logic
	•	Python 3.13 venv – Whisper + DSP pipelines
	•	Piper-TTS (local) – Fast, high-quality TTS
	•	Whisper (local) – ASR
	•	Ollama – Local LLM server

Services Installed
	•	/etc/systemd/system/whisplay.service – Runs the chatbot on boot
	•	WM8960 soundcard systemd service
	•	Fan overlay activation


Install Instructions:
***************************************************

*IMPORTANT* Before you Install:

1. Set up a raspberry Pi 5 device with the raspberry Pi Imager [https://www.raspberrypi.com/software/]
2. Ensure that your raspberry username is pi
3. SSH into a fresh Raspberry Pi 5 OS running Debian Trixie OS using terminal
4. Enter Username & Password


Just Paste This Command

```
sudo apt update && sudo apt install -y git
cd ~
git clone https://github.com/firasatdurrani/whisplay-chatbot-Qwen.git
cd ~/whisplay-chatbot-Qwen/whisplay-backup
chmod +x install_pi_from_backup.sh
./install_pi_from_backup.sh
```

##▶️ Using the Device

`	•	Press the Whisplay button → it listens
	•	Release → it sends audio to Whisper
	•	Qwen generates a reply
	•	Piper speaks the response
	•	RGB display shows emoji state


