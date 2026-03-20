# Paperless-NGX with OneDrive Storage (Proxmox LXC)

This guide explains how to mount OneDrive as the storage backend for a Paperless-NGX instance running in an unprivileged Proxmox LXC container. Documents are stored directly on OneDrive and the consume folder is also synced live.

---

## Architecture

```
OneDrive (Cloud)
      ↕  rclone mount (on Proxmox Host)
/mnt/paperless-onedrive-media     /mnt/paperless-onedrive-consume
      ↕  Bind-Mount (LXC config)
/opt/paperless_data/media         /opt/paperless_data/consume
      ↕
Paperless-NGX reads/writes normally
```

**What stays local:**
- `data/` – contains lock files, database index, logs – incompatible with cloud storage
- PostgreSQL database – managed separately by Paperless

---

## Prerequisites

- Proxmox VE with a running Paperless-NGX LXC (e.g. installed via tteck community script)
- A Microsoft OneDrive account (personal or business)
- Internet access from the Proxmox host
- A Windows/Linux/macOS PC with rclone installed for the OAuth step

---

## Step 1 – Install rclone on the Proxmox Host

> ⚠️ **Critical:** Do NOT use `apt install rclone`. The Debian repository version (1.60.x) has a bug with OneDrive token handling that causes I/O errors when reading files. Always install the latest version via the official install script.

```bash
curl https://rclone.org/install.sh | bash
rclone version
# Should show v1.70+ or higher
```

Also install fuse3:

```bash
apt install fuse3
```

Allow other users to access FUSE mounts:

```bash
echo "user_allow_other" >> /etc/fuse.conf
```

---

## Step 2 – Configure OneDrive Remote

Run the interactive config:

```bash
rclone config
```

- Press `n` for a new remote
- Name it `onedrive`
- Select `Microsoft OneDrive` as the storage type
- Leave Client ID and Client Secret empty (press Enter)
- Select `global` for the region
- Press `n` for No for advanced config
- Press `n` for No for auto config (since you are on a headless server)

On your **local PC**, run:

```bash
rclone authorize "onedrive"
```

This opens a browser window. Log in with your Microsoft account, then copy the token back into the Proxmox terminal.

Select your OneDrive drive (usually `OneDrive (personal)`) and confirm with `y`.

Test the connection:

```bash
rclone lsd onedrive:
```

---

## Step 3 – Create Folder Structure on OneDrive

```bash
rclone mkdir onedrive:Paperless/media
rclone mkdir onedrive:Paperless/consume
```

---

## Step 4 – Create Mount Points and Cache Directories on the Host

```bash
mkdir -p /mnt/paperless-onedrive-media
mkdir -p /mnt/paperless-onedrive-consume
mkdir -p /var/cache/rclone-paperless-media
mkdir -p /var/cache/rclone-paperless-consume
```

---

## Step 5 – Create Systemd Services

### Media mount

Create `/etc/systemd/system/rclone-paperless.service`:

```ini
[Unit]
Description=rclone OneDrive Mount for Paperless Media
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount onedrive:Paperless/media /mnt/paperless-onedrive-media \
  --vfs-cache-mode full \
  --allow-other \
  --dir-cache-time 30s \
  --poll-interval 15s \
  --cache-dir /var/cache/rclone-paperless-media \
  --vfs-cache-max-size 2G \
  --vfs-cache-max-age 24h \
  --file-perms 0777 \
  --dir-perms 0777
ExecStop=/bin/fusermount3 -uz /mnt/paperless-onedrive-media
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### Consume mount

Create `/etc/systemd/system/rclone-paperless-consume.service`:

```ini
[Unit]
Description=rclone OneDrive Mount for Paperless Consume
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount onedrive:Paperless/consume /mnt/paperless-onedrive-consume \
  --vfs-cache-mode full \
  --allow-other \
  --dir-cache-time 30s \
  --poll-interval 15s \
  --cache-dir /var/cache/rclone-paperless-consume \
  --vfs-cache-max-size 500M \
  --vfs-cache-max-age 1h \
  --file-perms 0777 \
  --dir-perms 0777
ExecStop=/bin/fusermount3 -uz /mnt/paperless-onedrive-consume
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable and start both services:

```bash
systemctl daemon-reload
systemctl enable --now rclone-paperless
systemctl enable --now rclone-paperless-consume
```

Verify both are running:

```bash
systemctl status rclone-paperless
systemctl status rclone-paperless-consume
```

---

## Step 6 – Bind Mounts into the LXC

Find your Paperless LXC ID:

```bash
pct list
```

Check the actual data path inside your container:

```bash
pct exec <ID> -- grep -i media /opt/paperless/paperless.conf
# Example output: PAPERLESS_MEDIA_ROOT=/opt/paperless_data/media
```

Edit `/etc/pve/lxc/<ID>.conf` and add:

```
mp0: /mnt/paperless-onedrive-media,mp=/opt/paperless_data/media
mp1: /mnt/paperless-onedrive-consume,mp=/opt/paperless_data/consume
```

> Adjust the path after `mp=` to match `PAPERLESS_MEDIA_ROOT` from the previous command.

---

## Step 7 – Create Required Directories inside the LXC

```bash
pct exec <ID> -- mkdir -p /opt/paperless_data/data/log
pct exec <ID> -- mkdir -p /opt/paperless_data/trash
```

---

## Step 8 – Enable Polling in Paperless

inotify does not work on FUSE mounts. Enable polling instead:

```bash
pct exec <ID> -- nano /opt/paperless/paperless.conf
```

Add or uncomment:

```
PAPERLESS_CONSUMER_POLLING=30
```

---

## Step 9 – Restart the LXC

```bash
pct stop <ID> && pct start <ID>
```

Verify mounts are working:

```bash
pct exec <ID> -- ls /opt/paperless_data/media
pct exec <ID> -- ls /opt/paperless_data/consume
```

---

## Step 10 – Add Proxmox LXC Start Delay (Recommended)

In the Proxmox web UI, go to your LXC → **Options → Start/Shutdown order** and set a startup delay of `30` seconds. This ensures rclone mounts are ready before Paperless starts after a reboot.

---

## Verification

Check that Paperless is consuming documents correctly:

```bash
pct exec <ID> -- journalctl -u paperless-consumer -f
```

Drop a PDF into `OneDrive/Paperless/consume` and watch Paperless pick it up within 30 seconds.

---

## Troubleshooting

### I/O errors when reading files
Make sure rclone was installed via `curl https://rclone.org/install.sh | bash` and not via `apt`. Check version with `rclone version` – must be 1.70+.

### "Transport endpoint is not connected" in LXC
The rclone mount has crashed. Run:
```bash
systemctl restart rclone-paperless rclone-paperless-consume
pct stop <ID> && pct start <ID>
```

### "Unauthenticated" errors in rclone logs
The OAuth token has expired. Reconnect:
```bash
rclone config reconnect onedrive:
systemctl restart rclone-paperless rclone-paperless-consume
```

### Paperless not picking up files from consume
Make sure polling is enabled in `paperless.conf` and the consumer service is running:
```bash
pct exec <ID> -- systemctl status paperless-consumer
```

---

## Important Notes

- **`data/` must stay local** – do not mount the `data` directory to OneDrive. It contains lock files and a database index that are incompatible with cloud storage.
- **Cache** – rclone caches files locally before uploading. This makes Paperless fast but means there is a short delay before files appear on OneDrive.
- **Token refresh** – The OneDrive OAuth token expires periodically. If rclone stops working, run `rclone config reconnect onedrive:` on the host.
- **Performance** – Saving documents will be slightly slower than local storage due to the cloud upload. This is expected behavior.
