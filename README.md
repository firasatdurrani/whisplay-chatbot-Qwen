# whisplay-chatbot-Qwen
Set up a plug and play offline chatbot running Qwen3:1.7b

## Plug & Play Pi 5 Chatbot setup


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
