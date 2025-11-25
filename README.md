# whisplay-chatbot-Qwen
Set up a plug and play offline chatbot running Qwen3:1.7b

## Fresh Pi setup From Macbook

SSH into a fresh Raspberry Pi OS from a mac and run:

```bash
sudo apt update && sudo apt install -y git
cd ~
git clone https://github.com/firasatdurrani/whisplay-chatbot-Qwen.git
cd whisplay-chatbot-Qwen
./install_pi_from_backup.sh
***************************************************
Optional and better: 
sudo apt update && sudo apt install -y git
cd ~
git clone https://github.com/firasatdurrani/whisplay-chatbot-Qwen.git
cd ~/whisplay-chatbot-Qwen/whisplay-backup
chmod +x install_pi_from_backup.sh
./install_pi_from_backup.sh
