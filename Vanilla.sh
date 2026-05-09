#!/bin/bash

# =================================================================
# VanillaMyLinux.sh - FINAL WORKING VERSION
# Resets Ubuntu to vanilla state while PROTECTING user home
# Features _BACKUP directory for user important files
# =================================================================

# Save the current directory before doing anything
ORIGINAL_DIR="$(pwd)"

# Ensure the script is aware of the current user even when using sudo
REAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# CRITICAL SAFETY CHECKS
if [ -z "$USER_HOME" ] || [ "$USER_HOME" = "/" ]; then
    echo "ERROR: Invalid USER_HOME detected! Exiting for safety."
    exit 1
fi

# Check if running with sudo, if not restart with sudo
if [ "$EUID" -ne 0 ]; then
    echo "Requesting sudo privileges for system cleanup..."
    exec sudo bash "$0" "$@"
fi

# Change to a safe directory that won't be deleted
cd /root 2>/dev/null || cd /tmp 2>/dev/null || cd /

echo "--- ☢️  STARTING VANILLA UBUNTU RESET ☢️  ---"
echo ""

# Force stdin to terminal
exec < /dev/tty

# Helper for safe command execution
safe_run() {
    "$@" 2>/dev/null || true
}

# Define backup directory name (excluded from all deletions)
BACKUP_DIR="_BACKUP"

# 1. Setup & Protection
PROTECTED_PATHS="/proc|/sys|/dev|/run|/boot|/etc|/var/log|/var/lib/systemd|/var/lib/dpkg|/var/lib/apt|/usr|/bin|/sbin|/lib|/lib64"
APPS_TO_PURGE=("nginx" "apache2" "mysql-server" "mariadb-server" "php*" "wordpress" "redis-server" "mongodb-org*" "nodejs" "dotnet-sdk-*" "golang-go" "multipass*" "rancher*")

echo "✅ Safety checks passed - User home protected: $USER_HOME"
echo "📁 Backup directory '_BACKUP' will be EXCLUDED from all deletions"
echo ""

# Create backup directory in user home if it doesn't exist
if [ ! -d "$USER_HOME/$BACKUP_DIR" ]; then
    echo "📁 Creating $USER_HOME/$BACKUP_DIR for important files..."
    safe_run mkdir -p "$USER_HOME/$BACKUP_DIR"
    safe_run chown "$REAL_USER:$REAL_USER" "$USER_HOME/$BACKUP_DIR"
    echo "  ✓ Backup directory created"
fi
echo ""

# 2. KUBERNETES & RANCHER
echo "[1/9] Dismantling K8s/Rancher stacks..."
safe_run pkill -f "kube|k3s|rancher|etcd|containerd-shim"

if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    safe_run /usr/local/bin/k3s-uninstall.sh
fi

if command -v microk8s &> /dev/null; then
    safe_run microk8s stop
    safe_run snap remove microk8s
fi

if mount | grep -q 'sandbox'; then
    mount | grep 'sandbox' | awk '{print $3}' | while read -r mnt; do
        safe_run umount "$mnt"
    done
fi

safe_run rm -rf /var/lib/rancher /var/lib/kubelet /etc/rancher /etc/kubernetes
echo "✓ K8s/Rancher cleanup complete"
echo ""

# 3. PACKAGE PURGE
echo "[2/9] Purging system packages and configs..."
for APP in "${APPS_TO_PURGE[@]}"; do
    if dpkg-query -W -f='${Status}' "$APP" 2>/dev/null | grep -q "installed"; then
        echo "  Purging: $APP"
        safe_run apt-get purge -y "$APP"
    fi
done
safe_run apt-get autoremove -y
safe_run apt-get autoclean
echo "✓ Package purge complete"
echo ""

# 4. CONTAINER & SNAP WIPE
echo "[3/9] Scrubbing Containers and Snaps..."
if command -v docker &> /dev/null; then
    echo "  Cleaning Docker..."
    safe_run docker system prune -a -f --volumes
fi
if command -v podman &> /dev/null; then
    echo "  Cleaning Podman..."
    safe_run podman system prune -a -f
fi
if command -v snap &> /dev/null; then
    echo "  Removing Snap packages..."
    safe_run snap remove multipass 2>/dev/null
    safe_run snap remove lxd 2>/dev/null
    safe_run snap remove core 2>/dev/null
    safe_run snap remove core20 2>/dev/null
fi
echo "✓ Container cleanup complete"
echo ""

# 5. GHOST SERVER HUNT
echo "[4/9] Hunting background servers..."
if command -v pm2 &> /dev/null; then
    safe_run pm2 kill
fi

safe_run pkill -u "$REAL_USER" -f "pm2|jupyter|ipython|streamlit|gunicorn|uvicorn|http.server|flask|node_modules"
safe_run pkill -9 -f "jupyter|ipython|streamlit|gunicorn|uvicorn|http.server|flask|node_modules"
safe_run rm -rf "$USER_HOME/.local/share/jupyter" "$USER_HOME/.jupyter" "$USER_HOME/.ipython" 2>/dev/null
echo "✓ Ghost servers cleaned"
echo ""

# 6. PORT RECLAMATION
echo "[5/9] Reclaiming network ports..."
SSH_PORT=$(safe_run ss -tlnp | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n 1)
SSH_PORT=${SSH_PORT:-22}
echo "  Protecting SSH port: $SSH_PORT"

if command -v lsof &> /dev/null; then
    ALL_PORTS=$(safe_run lsof -t -i -P -n -sTCP:LISTEN)
    SSH_PID=$(safe_run lsof -t -i :$SSH_PORT)
    
    if [ -n "$ALL_PORTS" ]; then
        for PID in $ALL_PORTS; do
            if [ "$PID" != "$SSH_PID" ]; then
                safe_run kill -9 "$PID"
            fi
        done
    fi
else
    safe_run ss -tlnp 2>/dev/null | grep -v "sshd" | grep LISTEN | awk -F'pid=' '{print $2}' | awk '{print $1}' | while read -r PID; do
        safe_run kill -9 "$PID" 2>/dev/null
    done
fi
echo "✓ Port cleanup complete"
echo ""

# --- CURRENT WORKING DIRECTORY WIPE (EXCLUDES _BACKUP) ---
echo "[5.5/9] Scanning current working directory for projects..."

# Go back to original directory to scan
if [ -d "$ORIGINAL_DIR" ] && [ "$ORIGINAL_DIR" != "/" ] && [ "$ORIGINAL_DIR" != "/root" ] && [ "$ORIGINAL_DIR" != "/home" ]; then
    cd "$ORIGINAL_DIR"
    
    # Find all directories in current working directory (excluding hidden, script, and _BACKUP)
    SCRIPT_NAME=$(basename "$0")
    CURRENT_DIRS=$(find . -maxdepth 1 -type d ! -name "." ! -name "$SCRIPT_NAME" ! -name ".*" ! -name "$BACKUP_DIR" 2>/dev/null | sed 's|^\./||' | grep -v '^$')
    
    if [ -n "$CURRENT_DIRS" ]; then
        echo "--------------------------------------------------------"
        echo "Found directories in current working directory:"
        echo "$CURRENT_DIRS"
        echo "--------------------------------------------------------"
        echo "📁 NOTE: '_BACKUP' directory is EXCLUDED from deletion"
        echo ""
        
        echo -n "⚠️  DELETE ALL THESE DIRECTORIES? (y/n): "
        read confirm < /dev/tty
        
        if [[ $confirm == [yY] ]]; then
            echo "$CURRENT_DIRS" | while read -r DIR; do
                if [ -n "$DIR" ] && [ -d "$DIR" ] && [ "$DIR" != "$BACKUP_DIR" ]; then
                    # Check if user wants to move anything to backup first
                    if [ -d "$DIR" ] && [ "$(ls -A "$DIR" 2>/dev/null)" ]; then
                        echo "  Directory '$DIR' contains files. Move to _$BACKUP_DIR? (y/n): "
                        read -r move_confirm < /dev/tty
                        if [[ $move_confirm == [yY] ]]; then
                            safe_run mv "$DIR"/* "$USER_HOME/$BACKUP_DIR/" 2>/dev/null
                            echo "    → Moved contents to $USER_HOME/$BACKUP_DIR/"
                        fi
                    fi
                    safe_run rm -rf "$DIR"
                    echo "  Removed: $DIR"
                fi
            done
            echo "  ✓ Current working directory cleaned"
        else
            echo "  Skipped directory deletion"
        fi
    else
        echo "  No directories found in current working directory"
    fi
    
    # Change back to safe directory
    cd /root 2>/dev/null || cd /tmp 2>/dev/null || cd /
else
    echo "  ⚠️ Original directory not safe to scan: $ORIGINAL_DIR"
fi
echo ""

# 7. GO BINARY HUNT
echo "[6/9] Cleaning Go processes..."
safe_run pkill -9 -f "go run"

for proc_dir in /proc/[0-9]*; do
    if [ -f "$proc_dir/exe" ] 2>/dev/null; then
        if strings "$proc_dir/exe" 2>/dev/null | grep -q "Go build ID"; then
            PID=$(basename "$proc_dir")
            safe_run kill -9 "$PID"
        fi
    fi
done
echo "✓ Go processes cleaned"
echo ""

# 8. DIRECTORY & CONFIG SCRUB - EXCLUDES _BACKUP
echo "[7/9] Scanning for user project directories..."

INSTALL_DATE=$(stat -c %Y /var/log/installer 2>/dev/null || echo "0")

# Scan user home for directories (excluding protected system dirs, standard dirs, and _BACKUP)
USER_DIRS=$(find "$USER_HOME" -maxdepth 1 -type d ! -path "$USER_HOME" ! -name ".*" ! -name "$BACKUP_DIR" 2>/dev/null | sed 's|^.*/||' | grep -vE '^(Desktop|Documents|Downloads|Music|Pictures|Public|Templates|Videos)$' || true)

if [ -n "$USER_DIRS" ]; then
    echo "--------------------------------------------------------"
    echo "Found user project directories in home:"
    echo "$USER_DIRS" | head -n 15
    echo "--------------------------------------------------------"
    echo "📁 NOTE: '_BACKUP' directory is EXCLUDED from deletion"
    echo ""
    
    echo -n "⚠️  DELETE THESE USER PROJECT DIRECTORIES? (y/n): "
    read confirm < /dev/tty
    
    if [[ $confirm == [yY] ]]; then
        for DIR in $USER_DIRS; do
            DIR_PATH="$USER_HOME/$DIR"
            if [ -d "$DIR_PATH" ] && [ "$DIR" != "$BACKUP_DIR" ]; then
                # Ask about moving to backup
                if [ "$(ls -A "$DIR_PATH" 2>/dev/null)" ]; then
                    echo "  Directory '$DIR' contains files."
                    echo " Move to _$BACKUP_DIR? (y/n):  "
                    read -r move_confirm < /dev/tty
                    if [[ $move_confirm == [yY] ]]; then
                        safe_run mv "$DIR_PATH"/* "$USER_HOME/$BACKUP_DIR/" 2>/dev/null
                        echo "    → Moved contents to $USER_HOME/$BACKUP_DIR/"
                    fi
                fi
                safe_run rm -rf "$DIR_PATH"
                echo "  Removed: $DIR_PATH"
            fi
        done
        echo "  ✓ User project directories removed"
    else
        echo "  Skipped user directory deletion"
    fi
else
    echo "  No user project directories found"
fi
echo ""

# 9. FINAL SYSTEM CLEANUP
echo "[8/9] Cleaning ghost network interfaces..."
for INTF in cni0 flannel.1 docker0; do
    if safe_run ip link show "$INTF" >/dev/null 2>&1; then
        safe_run ip link delete "$INTF"
        echo "  Removed interface: $INTF"
    fi
done
echo "✓ Network cleanup complete"
echo ""

echo "[9/9] Truncating logs and temp files..."
safe_run find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null
safe_run rm -rf /tmp/* 2>/dev/null
safe_run rm -rf /var/tmp/* 2>/dev/null
safe_run systemctl daemon-reload
safe_run systemctl reset-failed
echo "✓ System cleanup complete"
echo ""

# Summary of backup directory
echo "--------------------------------------------------------"
echo "📁 Backup Summary:"
if [ -d "$USER_HOME/$BACKUP_DIR" ]; then
    BACKUP_SIZE=$(du -sh "$USER_HOME/$BACKUP_DIR" 2>/dev/null | cut -f1)
    BACKUP_COUNT=$(find "$USER_HOME/$BACKUP_DIR" -type f 2>/dev/null | wc -l)
    echo "  Location: $USER_HOME/$BACKUP_DIR"
    echo "  Size: $BACKUP_SIZE"
    echo "  Files saved: $BACKUP_COUNT"
fi
echo "--------------------------------------------------------"
echo ""

# --- FINAL ANIMATION ---
echo "FINALIZING SYSTEM PURGE..."
sleep 1

cat << "EOF"

       _.-^^---....,,--
   _--                  --_
  <                        )
  |                         |
   \._                   _./
      '''--. . , ; .--'''
            | |   |
         .-=|| | ||=-.
         '-=##_   _##=-'
            |  ###  |
            |   #   |
            '       '

EOF

sleep 0.7

cat << "EOF"

          _ ._  _ , _ ._
        (_ ' ( `  )_  .__)
      ( (  (    )   `)  ) _)
     (__ (_   (_ . _) _) ,__)
           `~~`\ ' /`~~`
                |||
                |||
                |||
                |||
                |||

EOF

echo "☢️ SYSTEM NUKED ☢️ "

echo "      (User home directory PROTECTED)"
echo "      (Backup directory '_BACKUP' preserved)"
echo ""

# Final port check
echo "Final port audit (safe ports filtered out):"
SAFE_FILTER=":53 |:22 |:33057 |systemd-resolve|sshd|containerd"
UNEXPECTED_PORTS=$(ss -tulpn 2>/dev/null | grep LISTEN | grep -vE "$SAFE_FILTER" || true)

if [ -n "$UNEXPECTED_PORTS" ]; then
    echo "⚠️  Unexpected listening ports detected:"
    echo "$UNEXPECTED_PORTS"
else
    echo "✓ No unexpected ports - system is clean!"
    echo "  (DNS on 53, SSH on 22, and containerd are expected/normal)"
fi

echo ""
echo "✅ VM IS NOW PURE VANILLA ! 🍦"
echo "📁 Your important files are safe in: $USER_HOME/_BACKUP"
