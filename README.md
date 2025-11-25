# whisplay-chatbot-Qwen
Set up a plug and play offline chatbot running Qwen3:1.7b

## Fresh Pi 5 Chatbot setup

*IMPORTANT*

Ensure that your raspberry username is pi

SSH into a fresh Raspberry Pi 5 OS running Debian Trixie OS

Install Instructions:
***************************************************

Just Paste This Command

```
sudo apt update && sudo apt install -y git
cd ~
git clone https://github.com/firasatdurrani/whisplay-chatbot-Qwen.git
cd ~/whisplay-chatbot-Qwen/whisplay-backup
chmod +x install_pi_from_backup.sh
./install_pi_from_backup.sh
