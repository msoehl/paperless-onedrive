#!/bin/bash
# ============================================================
# paperless-onedrive-setup.sh
# Sets up OneDrive as storage backend for Paperless-NGX on Proxmox
#
# Run this script on the Proxmox HOST (not inside the LXC)
# Usage: bash paperless-onedrive-setup.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo "========================================"
echo "  Paperless-NGX + OneDrive Setup Script"
echo "========================================"
echo ""

# ── Check running as root ────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  error "Please run as root"
fi

# ── Ask for LXC ID ──────────────────────────────────────────
echo "Available LXC containers:"
pct list
echo ""
read -p "Enter your Paperless LXC ID: " LXC_ID

if ! pct status "$LXC_ID" &>/dev/null; then
  error "LXC $LXC_ID not found"
fi

info "Using LXC ID: $LXC_ID"

# ── Detect media path inside LXC ────────────────────────────
info "Detecting Paperless data path inside LXC..."
MEDIA_ROOT=$(pct exec "$LXC_ID" -- grep -i "PAPERLESS_MEDIA_ROOT" /opt/paperless/paperless.conf 2>/dev/null | cut -d= -f2 | tr -d ' ')

if [ -z "$MEDIA_ROOT" ]; then
  warn "Could not auto-detect PAPERLESS_MEDIA_ROOT"
  read -p "Enter the media path inside LXC (e.g. /opt/paperless_data/media): " MEDIA_ROOT
fi

# Derive base and consume path
PAPERLESS_DATA_BASE=$(dirname "$MEDIA_ROOT")
CONSUME_PATH="$PAPERLESS_DATA_BASE/consume"
TRASH_PATH="$PAPERLESS_DATA_BASE/trash"
LOG_PATH="$PAPERLESS_DATA_BASE/data/log"

info "Media path:   $MEDIA_ROOT"
info "Consume path: $CONSUME_PATH"
echo ""

# ── Step 1: Install rclone ───────────────────────────────────
info "Step 1: Installing rclone (official latest version)..."

if command -v rclone &>/dev/null; then
  CURRENT_VERSION=$(rclone version | head -1 | awk '{print $2}' | sed 's/v//')
  MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
  MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
  if [ "$MAJOR" -gt 1 ] || { [ "$MAJOR" -eq 1 ] && [ "$MINOR" -ge 70 ]; }; then
    info "rclone $CURRENT_VERSION already installed and up to date"
  else
    warn "rclone $CURRENT_VERSION is too old (need 1.70+). Upgrading..."
    curl https://rclone.org/install.sh | bash
  fi
else
  curl https://rclone.org/install.sh | bash
fi

# ── Step 2: Install fuse3 ───────────────────────────────────
info "Step 2: Installing fuse3..."
apt-get install -y fuse3 > /dev/null

# ── Step 3: Configure fuse.conf ─────────────────────────────
info "Step 3: Configuring /etc/fuse.conf..."
if grep -q "^user_allow_other" /etc/fuse.conf; then
  info "user_allow_other already set"
else
  echo "user_allow_other" >> /etc/fuse.conf
  info "Added user_allow_other to /etc/fuse.conf"
fi

# ── Step 4: Configure OneDrive remote ───────────────────────
info "Step 4: Configuring OneDrive remote..."
echo ""

if rclone listremotes | grep -q "^onedrive:"; then
  warn "OneDrive remote already configured. Testing connection..."
  if rclone lsd onedrive: &>/dev/null; then
    info "OneDrive connection OK"
  else
    warn "OneDrive connection failed. Reconnecting..."
    rclone config reconnect onedrive:
  fi
else
  echo -e "${YELLOW}You need to configure the OneDrive remote.${NC}"
  echo ""
  echo "IMPORTANT: When asked for auto config, press 'n' (No)."
  echo "Then run the following on your LOCAL PC to get a token:"
  echo ""
  echo "  rclone authorize \"onedrive\""
  echo ""
  echo "Paste the token back here when prompted."
  echo ""
  read -p "Press Enter to start rclone config..."
  rclone config
fi

# ── Step 5: Create OneDrive folder structure ─────────────────
info "Step 5: Creating OneDrive folder structure..."
rclone mkdir onedrive:Paperless/media
rclone mkdir onedrive:Paperless/consume
info "OneDrive folders created"

# ── Step 6: Create local mount points ───────────────────────
info "Step 6: Creating local mount points and cache directories..."
mkdir -p /mnt/paperless-onedrive-media
mkdir -p /mnt/paperless-onedrive-consume
mkdir -p /var/cache/rclone-paperless-media
mkdir -p /var/cache/rclone-paperless-consume

# ── Step 7: Create systemd services ─────────────────────────
info "Step 7: Creating systemd services..."

cat > /etc/systemd/system/rclone-paperless.service << EOF
[Unit]
Description=rclone OneDrive Mount for Paperless Media
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount onedrive:Paperless/media /mnt/paperless-onedrive-media \\
  --vfs-cache-mode full \\
  --allow-other \\
  --dir-cache-time 30s \\
  --poll-interval 15s \\
  --cache-dir /var/cache/rclone-paperless-media \\
  --vfs-cache-max-size 2G \\
  --vfs-cache-max-age 24h \\
  --file-perms 0777 \\
  --dir-perms 0777
ExecStop=/bin/fusermount3 -uz /mnt/paperless-onedrive-media
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/rclone-paperless-consume.service << EOF
[Unit]
Description=rclone OneDrive Mount for Paperless Consume
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount onedrive:Paperless/consume /mnt/paperless-onedrive-consume \\
  --vfs-cache-mode full \\
  --allow-other \\
  --dir-cache-time 30s \\
  --poll-interval 15s \\
  --cache-dir /var/cache/rclone-paperless-consume \\
  --vfs-cache-max-size 500M \\
  --vfs-cache-max-age 1h \\
  --file-perms 0777 \\
  --dir-perms 0777
ExecStop=/bin/fusermount3 -uz /mnt/paperless-onedrive-consume
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now rclone-paperless
systemctl enable --now rclone-paperless-consume
info "Services created and started"

# ── Step 8: Add bind mounts to LXC config ───────────────────
info "Step 8: Adding bind mounts to LXC config..."

LXC_CONF="/etc/pve/lxc/${LXC_ID}.conf"

# Find next free mp index
MP_INDEX=0
while grep -q "^mp${MP_INDEX}:" "$LXC_CONF" 2>/dev/null; do
  MP_INDEX=$((MP_INDEX + 1))
done

echo "mp${MP_INDEX}: /mnt/paperless-onedrive-media,mp=${MEDIA_ROOT}" >> "$LXC_CONF"
MP_INDEX=$((MP_INDEX + 1))
echo "mp${MP_INDEX}: /mnt/paperless-onedrive-consume,mp=${CONSUME_PATH}" >> "$LXC_CONF"

info "Bind mounts added to $LXC_CONF"

# ── Step 9: Create required directories inside LXC ──────────
info "Step 9: Creating required directories inside LXC..."
pct exec "$LXC_ID" -- mkdir -p "$LOG_PATH"
pct exec "$LXC_ID" -- mkdir -p "$TRASH_PATH"

# ── Step 10: Enable polling in Paperless ────────────────────
info "Step 10: Enabling polling in Paperless config..."
PAPERLESS_CONF="/opt/paperless/paperless.conf"

if pct exec "$LXC_ID" -- grep -q "PAPERLESS_CONSUMER_POLLING" "$PAPERLESS_CONF" 2>/dev/null; then
  pct exec "$LXC_ID" -- sed -i 's/.*PAPERLESS_CONSUMER_POLLING.*/PAPERLESS_CONSUMER_POLLING=30/' "$PAPERLESS_CONF"
else
  pct exec "$LXC_ID" -- bash -c "echo 'PAPERLESS_CONSUMER_POLLING=30' >> $PAPERLESS_CONF"
fi

info "Polling set to 30 seconds"

# ── Step 11: Restart LXC ────────────────────────────────────
info "Step 11: Restarting LXC $LXC_ID..."
pct stop "$LXC_ID"
sleep 3
pct start "$LXC_ID"
sleep 5

# ── Verify ──────────────────────────────────────────────────
info "Verifying mounts..."
if pct exec "$LXC_ID" -- ls "$MEDIA_ROOT" &>/dev/null; then
  info "✓ Media mount OK"
else
  warn "✗ Media mount not accessible - check manually"
fi

if pct exec "$LXC_ID" -- ls "$CONSUME_PATH" &>/dev/null; then
  info "✓ Consume mount OK"
else
  warn "✗ Consume mount not accessible - check manually"
fi

echo ""
echo "========================================"
echo -e "${GREEN}  Setup complete!${NC}"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. In Proxmox UI: set LXC $LXC_ID startup delay to 30s"
echo "     (Options → Start/Shutdown order → Startup delay: 30)"
echo ""
echo "  2. Drop a PDF into OneDrive/Paperless/consume to test"
echo ""
echo "  3. Watch logs with:"
echo "     pct exec $LXC_ID -- journalctl -u paperless-consumer -f"
echo ""
