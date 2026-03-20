# Paperless-NGX + OneDrive (Proxmox LXC)

Store your Paperless-NGX documents directly on Microsoft OneDrive using rclone – live mounted into an unprivileged Proxmox LXC container.

---

## Features

- Live OneDrive mount for `media/` and `consume/` folders
- Automatic document pickup from OneDrive consume folder
- Fully automatic setup via shell script
- Works with unprivileged Proxmox LXC containers
- Tested with Paperless-NGX installed via [tteck community scripts](https://tteck.github.io/Proxmox/)

## How it works

```
OneDrive (Cloud)
      ↕  rclone mount (Proxmox Host)
/mnt/paperless-onedrive-media     /mnt/paperless-onedrive-consume
      ↕  Bind-Mount (LXC config)
/opt/paperless_data/media         /opt/paperless_data/consume
      ↕
Paperless-NGX reads/writes normally
```

---

## Quick Start

Run the setup script on your **Proxmox host** (not inside the LXC):

```bash
bash paperless-onedrive-setup.sh
```

The script will guide you through the entire setup interactively.

---

## Documentation

- 🇬🇧 [English Guide](docs/paperless-onedrive-en.md)
- 🇩🇪 [Deutsche Anleitung](docs/paperless-onedrive-de.md)

---

## Requirements

- Proxmox VE with a running Paperless-NGX LXC
- Microsoft OneDrive account (personal or business)
- A local PC with rclone installed (for the OAuth step)

---

## Important Notes

- **Do not use `apt install rclone`** – the Debian repository version (1.60.x) has a bug with OneDrive that causes I/O errors. The setup script installs the correct version automatically.
- The `data/` directory stays local – it contains lock files and database indexes incompatible with cloud storage.
- The OAuth token for OneDrive expires periodically. If rclone stops working, run `rclone config reconnect onedrive:` on the Proxmox host.

---

## License

MIT – see [LICENSE](LICENSE)
