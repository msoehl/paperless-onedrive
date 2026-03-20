# Paperless-NGX mit OneDrive-Speicher (Proxmox LXC)

Diese Anleitung erklärt, wie OneDrive als Speicher-Backend für eine Paperless-NGX Instanz eingerichtet wird, die in einem unprivilegierten Proxmox LXC-Container läuft. Dokumente werden direkt auf OneDrive gespeichert und der Consume-Ordner wird ebenfalls live synchronisiert.

---

## Architektur

```
OneDrive (Cloud)
      ↕  rclone mount (auf dem Proxmox-Host)
/mnt/paperless-onedrive-media     /mnt/paperless-onedrive-consume
      ↕  Bind-Mount (LXC-Konfiguration)
/opt/paperless_data/media         /opt/paperless_data/consume
      ↕
Paperless-NGX liest/schreibt ganz normal
```

**Was lokal bleibt:**
- `data/` – enthält Lock-Dateien, Datenbankindex, Logs – nicht kompatibel mit Cloud-Speicher
- PostgreSQL-Datenbank – wird separat von Paperless verwaltet

---

## Voraussetzungen

- Proxmox VE mit einer laufenden Paperless-NGX LXC (z.B. per tteck Community Script installiert)
- Ein Microsoft OneDrive-Konto (privat oder geschäftlich)
- Internetzugang vom Proxmox-Host
- Ein Windows/Linux/macOS PC mit installiertem rclone für den OAuth-Schritt

---

## Schritt 1 – rclone auf dem Proxmox-Host installieren

> ⚠️ **Wichtig:** NICHT `apt install rclone` verwenden. Die Debian-Repository-Version (1.60.x) hat einen Bug beim OneDrive-Token-Handling, der I/O-Fehler beim Lesen von Dateien verursacht. Immer die aktuelle Version über das offizielle Install-Script installieren.

```bash
curl https://rclone.org/install.sh | bash
rclone version
# Sollte v1.70+ oder höher anzeigen
```

Außerdem fuse3 installieren:

```bash
apt install fuse3
```

Anderen Benutzern den Zugriff auf FUSE-Mounts erlauben:

```bash
echo "user_allow_other" >> /etc/fuse.conf
```

---

## Schritt 2 – OneDrive-Remote konfigurieren

Interaktive Konfiguration starten:

```bash
rclone config
```

- `n` drücken für ein neues Remote
- Name: `onedrive`
- Speichertyp: `Microsoft OneDrive` auswählen
- Client ID und Client Secret leer lassen (Enter drücken)
- Region: `global` auswählen
- `n` für kein Advanced Config
- `n` für kein Auto Config (da Server ohne Browser)

Auf dem **lokalen PC** ausführen:

```bash
rclone authorize "onedrive"
```

Es öffnet sich ein Browser-Fenster. Mit dem Microsoft-Konto anmelden, dann den Token in das Proxmox-Terminal kopieren.

Das OneDrive-Laufwerk auswählen (normalerweise `OneDrive (personal)`) und mit `y` bestätigen.

Verbindung testen:

```bash
rclone lsd onedrive:
```

---

## Schritt 3 – Ordnerstruktur auf OneDrive anlegen

```bash
rclone mkdir onedrive:Paperless/media
rclone mkdir onedrive:Paperless/consume
```

---

## Schritt 4 – Mountpunkte und Cache-Verzeichnisse auf dem Host anlegen

```bash
mkdir -p /mnt/paperless-onedrive-media
mkdir -p /mnt/paperless-onedrive-consume
mkdir -p /var/cache/rclone-paperless-media
mkdir -p /var/cache/rclone-paperless-consume
```

---

## Schritt 5 – Systemd-Services erstellen

### Media-Mount

Datei `/etc/systemd/system/rclone-paperless.service` erstellen:

```ini
[Unit]
Description=rclone OneDrive Mount für Paperless Media
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

### Consume-Mount

Datei `/etc/systemd/system/rclone-paperless-consume.service` erstellen:

```ini
[Unit]
Description=rclone OneDrive Mount für Paperless Consume
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

Beide Services aktivieren und starten:

```bash
systemctl daemon-reload
systemctl enable --now rclone-paperless
systemctl enable --now rclone-paperless-consume
```

Status prüfen:

```bash
systemctl status rclone-paperless
systemctl status rclone-paperless-consume
```

---

## Schritt 6 – Bind-Mounts in den LXC einbinden

LXC-ID ermitteln:

```bash
pct list
```

Tatsächlichen Datenpfad im Container prüfen:

```bash
pct exec <ID> -- grep -i media /opt/paperless/paperless.conf
# Beispielausgabe: PAPERLESS_MEDIA_ROOT=/opt/paperless_data/media
```

Datei `/etc/pve/lxc/<ID>.conf` bearbeiten und folgende Zeilen hinzufügen:

```
mp0: /mnt/paperless-onedrive-media,mp=/opt/paperless_data/media
mp1: /mnt/paperless-onedrive-consume,mp=/opt/paperless_data/consume
```

> Den Pfad nach `mp=` entsprechend `PAPERLESS_MEDIA_ROOT` anpassen.

---

## Schritt 7 – Benötigte Verzeichnisse im LXC anlegen

```bash
pct exec <ID> -- mkdir -p /opt/paperless_data/data/log
pct exec <ID> -- mkdir -p /opt/paperless_data/trash
```

---

## Schritt 8 – Polling in Paperless aktivieren

inotify funktioniert nicht auf FUSE-Mounts. Stattdessen Polling aktivieren:

```bash
pct exec <ID> -- nano /opt/paperless/paperless.conf
```

Folgende Zeile hinzufügen:

```
PAPERLESS_CONSUMER_POLLING=30
```

---

## Schritt 9 – LXC neu starten

```bash
pct stop <ID> && pct start <ID>
```

Mounts überprüfen:

```bash
pct exec <ID> -- ls /opt/paperless_data/media
pct exec <ID> -- ls /opt/paperless_data/consume
```

---

## Schritt 10 – Startverzögerung für LXC setzen (empfohlen)

In der Proxmox-Weboberfläche beim LXC unter **Optionen → Start/Shutdown-Reihenfolge** eine Startverzögerung von `30` Sekunden eintragen. So sind die rclone-Mounts bereit bevor Paperless nach einem Neustart startet.

---

## Überprüfung

Prüfen ob Paperless Dokumente korrekt verarbeitet:

```bash
pct exec <ID> -- journalctl -u paperless-consumer -f
```

Eine PDF in `OneDrive/Paperless/consume` ablegen und beobachten wie Paperless sie innerhalb von 30 Sekunden verarbeitet.

---

## Fehlerbehebung

### I/O-Fehler beim Lesen von Dateien
Sicherstellen dass rclone per `curl https://rclone.org/install.sh | bash` installiert wurde und nicht per `apt`. Version prüfen mit `rclone version` – muss 1.70+ sein.

### "Transport endpoint is not connected" im LXC
Der rclone-Mount ist abgestürzt. Ausführen:
```bash
systemctl restart rclone-paperless rclone-paperless-consume
pct stop <ID> && pct start <ID>
```

### "Unauthenticated"-Fehler in rclone-Logs
Der OAuth-Token ist abgelaufen. Neu verbinden:
```bash
rclone config reconnect onedrive:
systemctl restart rclone-paperless rclone-paperless-consume
```

### Paperless erkennt keine Dateien im Consume-Ordner
Sicherstellen dass Polling in `paperless.conf` aktiviert ist und der Consumer-Service läuft:
```bash
pct exec <ID> -- systemctl status paperless-consumer
```

---

## Wichtige Hinweise

- **`data/` muss lokal bleiben** – das `data`-Verzeichnis darf nicht auf OneDrive gemountet werden. Es enthält Lock-Dateien und einen Datenbankindex, die nicht mit Cloud-Speicher kompatibel sind.
- **Cache** – rclone speichert Dateien lokal zwischen bevor sie hochgeladen werden. Das macht Paperless schnell, bedeutet aber eine kurze Verzögerung bis Dateien auf OneDrive erscheinen.
- **Token-Erneuerung** – Der OneDrive OAuth-Token läuft periodisch ab. Falls rclone aufhört zu funktionieren: `rclone config reconnect onedrive:` auf dem Host ausführen.
- **Performance** – Das Speichern von Dokumenten ist etwas langsamer als bei lokalem Speicher. Das ist erwartetes Verhalten.
