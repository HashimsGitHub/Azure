sudo apt install python3 -y
sudo apt install python3-pip -y
sudo apt install python3.10-venv -y

python3 -m venv labenv
source labenv/bin/activate

# Confirm virtual environment is active
echo "Using Python: $(which python3)"
echo "Using pip: $(which pip)"
python3 --version
pip --version

curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# The following installs are inside the virtual environment
pip install azure-identity agent-framework
pip install python-dotenv
pip install openai

if [ -d "ai-agents" ]; then
    rm -rf ai-agents
fi
git clone https://github.com/MicrosoftLearning/mslearn-ai-agents ai-agents

cd ai-agents/Labfiles/05-agent-orchestration/Python

python3 azurelogin.py
