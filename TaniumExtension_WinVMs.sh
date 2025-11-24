#!/bin/bash

CSV_FILE="./vm-list.csv"
TANIUM_INIT_DAT_FILE="./tanium-init.dat"

TANIUM_SERVER="tanium.local"        # Required placeholder
_base64_tanium_init_dat=$(base64 -w0 "$TANIUM_INIT_DAT_FILE")

# Read CSV - Skip header using tail
tail -n +2 "$CSV_FILE" | while IFS=',' read -r vm rg; do

    # Trim whitespace and BOM
    vm=$(echo "$vm" | tr -d '\r' | sed 's/^\xef\xbb\xbf//g' | xargs)
    rg=$(echo "$rg" | tr -d '\r' | sed 's/^\xef\xbb\xbf//g' | xargs)

    # Skip empty rows
    [ -z "$vm" ] && continue
    [ -z "$rg" ] && { echo "❌ ERROR: Missing ResourceGroup for VM '$vm'"; continue; }

    echo "--------------------------------------------------"
    echo "Installing TaniumClientWindows on VM: $vm in RG: $rg"
    echo "--------------------------------------------------"

    az vm extension set \
        --name TaniumClientWindows \
        --publisher Tanium.Client \
        --vm-name "$vm" \
        --resource-group "$rg" \
        --protected-settings "{\"TaniumInitDat\":\"$_base64_tanium_init_dat\",\"TaniumServer\":\"$TANIUM_SERVER\"}"

    if [ $? -eq 0 ]; then
        echo "✔ SUCCESS: Installed Tanium extension on $vm"
    else
        echo "❌ FAILED: Could not install extension on $vm"
    fi

    echo ""
done
