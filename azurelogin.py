import os
from dotenv import load_dotenv

# Load the .env file
load_dotenv()

# Access the AZURE_TENANT_ID variable
azure_tenant_id = os.getenv("AZURE_TENANT_ID")

# Use the variable in a command
if azure_tenant_id:
    os.system(f"az login --tenant {azure_tenant_id}")
else:
    print("AZURE_TENANT_ID is not set in the .env file.")
