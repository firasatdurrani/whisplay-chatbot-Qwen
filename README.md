# whisplay-chatbot-Qwen
Set up a plug and play offline chatbot running Qwen3:1.7b

## Fresh Pi setup

SSH into a fresh Raspberry Pi OS and run:

```bash
sudo apt update && sudo apt install -y git
cd ~
git clone https://github.com/firasatdurrani/whisplay-chatbot-Qwen.git
cd whisplay-chatbot-Qwen
./install_pi_from_backup.sh
