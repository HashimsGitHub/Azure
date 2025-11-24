# --------------------------------------------
# Install Tanium Client Extension on VMs
# Uses current working directory for CSV and .dat file
# VM list: vm-list.csv
# Tanium file: tanium-init.dat
# Compatible with PowerShell 7 / Cloud Shell
# --------------------------------------------

# Current working directory
$cwd = $PWD.Path

# File paths
$csvPath = Join-Path $cwd "vm-list.csv"
$taniumDatPath = Join-Path $cwd "tanium-init.dat"

# Hardcoded Tanium Server (edit if available)
$TaniumServer = "TaniumServerHostname"

# Validate CSV file
if (!(Test-Path $csvPath)) {
    Write-Error "VM list file not found: $csvPath"
    exit
}

# Validate Tanium init file
if (!(Test-Path $taniumDatPath)) {
    Write-Error "Tanium init file not found: $taniumDatPath"
    exit
}

# Read and Base64 encode the Tanium init file (PowerShell 7+)
try {
    $datBytes = Get-Content -Path $taniumDatPath -AsByteStream
    $TaniumInitDat_Base64 = [Convert]::ToBase64String($datBytes)
    Write-Host "Loaded and Base64 encoded tanium-init.dat" -ForegroundColor Green
}
catch {
    Write-Error "Failed to read or encode tanium-init.dat: $_"
    exit
}

# Import VM list CSV
try {
    $vmList = Import-Csv -Path $csvPath
    Write-Host "Loaded VM list from CSV" -ForegroundColor Green
}
catch {
    Write-Error "Failed to read CSV file: $_"
    exit
}

# Loop through each VM and install Tanium extension
foreach ($vm in $vmList) {

    $vmName = $vm.VMName
    $rgName = $vm.ResourceGroup

    # Skip invalid rows
    if ([string]::IsNullOrWhiteSpace($vmName) -or [string]::IsNullOrWhiteSpace($rgName)) {
        Write-Warning "Skipping row with missing VMName or ResourceGroup."
        continue
    }

    Write-Host "`n---- Installing Tanium Client on $vmName in $rgName ----" -ForegroundColor Cyan

    # Build protected-settings JSON
    $protectedSettings = @{
        TaniumInitDat = $TaniumInitDat_Base64
        TaniumServer  = $TaniumServer
    } | ConvertTo-Json -Compress

    # Install Tanium extension using Azure CLI
    az vm extension set `
        --name TaniumClientWindows `
        --publisher Tanium.Client `
        --vm-name $vmName `
        --resource-group $rgName `
        --protected-settings $protectedSettings

    if ($LASTEXITCODE -eq 0) {
        Write-Host "SUCCESS: Installed Tanium Client on $vmName" -ForegroundColor Green
    }
    else {
        Write-Host "ERROR: Failed installation on $vmName" -ForegroundColor Red
    }
}
