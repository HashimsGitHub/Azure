sudo apt install python3 -y
sudo apt install python3-pip -y
sudo apt install python3.10-venv -y
python3 -m venv labenv
source labenv/bin/activate

curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

pip install azure-identity agent-framework
pip install python-dotenv
pip install openai

rm -r ai-agents -f
git clone https://github.com/MicrosoftLearning/mslearn-ai-agents ai-agents

cd ai-agents/Labfiles/05-agent-orchestration/Python

python3 azurelogin.py
