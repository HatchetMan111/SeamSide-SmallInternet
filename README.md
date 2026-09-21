# Seamside auf Proxmox LXC – Einzeiler-Installation

Seamside („a place you keep", local-first P2P-Workspace von [Small Craft](https://smlcrft.com))
läuft vollständig lokal als **serve-Knoten** in einem unprivilegierten LXC-Container:
offizielle AppImage von `updates.seamside.com` (x86_64/aarch64), systemd-Service mit
`Restart=always`, Container mit `onboot=1`.

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `seamside` |
| Tech-Stack | Seamside AppImage (signed release feed) + systemd, kein Docker nötig |
| Web UI im Browser | **ja – via Share-Link:** geteilte Frames/Spaces öffnen im Browser (kein Login/Install nötig). Link erzeugen in der App: Frame-Detail → *public sharing* bzw. Space-Settings → *public link access* |
| Direkter `http://<LXC-IP>:<PORT>`? | **nein** – der serve-Knoten braucht keine offenen Inbound-Ports (Outbound-P2P wie die Desktop-App); `SEAMSIDE_PORT` (Default 8080) ist nur der interne serve-Port |
| Standard-Ressourcen | 2 vCPU / 2048 MB RAM / 8 GB Disk |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-13-standard` (neuestes auf Storage `local`) – **Pflicht**: Seamside v0.2.8+ braucht glibc ≥ 2.39, Debian 12 (glibc 2.36) startet das Binary nicht |

> **Hinweis:** Dieses Paket (`install/`, `systemd/`, `README.md`) enthält **nur den
> Proxmox-Installer**. Der App-Code ist die offizielle Seamside-AppImage
> (Upstream: `https://seamside.com`, Installer-Referenz: `seamside-manager.sh`).

## 1. Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SeamSide-SmallInternet/main/install/seamside.sh)"
```

Das Script fragt interaktiv die ToS-Akzeptanz (`https://seamside.com/terms`)
sowie – je nach Modus – Pairing-Link bzw. Operator-IDs ab. Für
Non-Interactive/Automatisierung stattdessen per Env vorab setzen
(siehe unten, `ACCEPT_TOS=1` überspringt die Rückfrage):

```bash
# sibling-Modus: Server wird eines DEINER Geräte (Pairing-Link aus der App: Devices → + → Create pairing link)
SEAMSIDE_JOIN_LINK="https://…" ACCEPT_TOS=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SeamSide-SmallInternet/main/install/seamside.sh)"

# own-account-Modus: Server mit eigener Identität + Operatoren (Seamside-User-IDs, 64 Hex oder base64)
SEAMSIDE_MODE=new-user SEAMSIDE_DISPLAY_NAME="Homelab" SEAMSIDE_OPERATORS="<deine-user-id>" \
  ACCEPT_TOS=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SeamSide-SmallInternet/main/install/seamside.sh)"
```

Anpassungen (Env oder Flag, Flags gewinnen):

```bash
CT_ID=101 CORES=2 RAM=2048 DISK=8 ACCEPT_TOS=1 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SeamSide-SmallInternet/main/install/seamside.sh)"
bash seamside.sh --ctid 101 --cores 2 --memory 2048 --disk 8 --bridge vmbr0 --storage local-lvm --accept-tos
bash seamside.sh --debug   # = bash -x, maximale Fehlermeldungskette
bash seamside.sh --ctid 105 --reboot-test     # Reboot-Test erzwingen (auch auf bestehendem CT)
bash seamside.sh --ctid 105 --no-reboot-test  # Reboot-Test unterdruecken (auch bei Neu-Erstellung)
bash seamside.sh --ctid 105 --no-backup       # Auto-Backup unterdruecken
```

> **Achtung `bash -c`-Falle:** `bash -c "$(...)" --ctid 101` funktioniert
> **nicht** – alles nach dem Script-String landet in `$0`, nicht in `$@`
> (`[FEHLER] Unbekannte Option: 101`). Flags immer so übergeben:
>
> ```bash
> wget -qO /tmp/seamside.sh https://raw.githubusercontent.com/HatchetMan111/SeamSide-SmallInternet/main/install/seamside.sh
> ACCEPT_TOS=1 bash /tmp/seamside.sh --ctid 105   # Trace: bash -x /tmp/seamside.sh --ctid 105
> # oder ohne Datei:  wget -qO- <URL> | ACCEPT_TOS=1 bash -s -- --ctid 105
> ```
>
> Env-Variablen (`CT_ID=…`, `ACCEPT_TOS=…`) funktionieren dagegen auch direkt
> vor `bash -c` (Zeile darüber).

Das Skript (`set -euo pipefail`, idempotent):
1. prüft Host/Tools/ToS, nimmt die nächste freie CT-ID,
2. erkennt RootFS-Storage (bevorzugt `local-lvm`), lädt das neueste
   `debian-13-standard`-Template falls nötig,
3. erstellt den LXC `seamside` (`onboot: 1`, unprivilegiert) und prüft per
   OS-Gate, dass der Gast Debian 13+ ist (Debian 12 wird mit klarer
   Löschanleitung abgelehnt, statt ins Leere zu installieren),
4. installiert im Container Curl/CA-Certs, legt User `seamside` an,
   lädt die neueste AppImage vom offiziellen Feed nach `/opt/seamside/<instanz>/`,
   sichert Passphrase (generiert falls leer) als Upstream-Env-Format
   (`SEAMSIDE_KEY_PASSPHRASE`) unter `/etc/seamside/<instanz>.env` (600),
5. schreibt `seamside.service` (`Restart=always`, `After=network-online.target`,
   Passphrase via `EnvironmentFile` – kein `LoadCredential`, das in
   unprivilegierten LXC mit 243/CREDENTIALS scheitert), `systemctl enable --now`,
6. verifiziert `systemctl is-active seamside` + Binary-`--version` +
   `ss`-Listener auf dem serve-Port + HTTP-Probe (best-effort) und gibt den
   nächsten Schritt (Pairing-Genehmigung bzw. Operator-Einladung) aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active seamside = active).
[OK]    Container 100 startet automatisch (onboot: 1).

════════ INSTALLATION ERFOLGREICH ════════
  App        : Seamside serve-Knoten (Instanz: main, Modus: sibling)
  Container  : CT 100 (Hostname: seamside, onboot=1)
  Ressourcen : 2 vCPU / 2048 MB RAM / 8 GB Disk
  Daten      : /var/lib/seamside/main  + Passphrase /etc/seamside/main.env (BEIDES sichern!)
  Naechster Schritt: in der Seamside-App unter Devices den Server genehmigen (Admin-Geraet).
  HINWEIS    : Keine Browser-Web-UI — Verwaltung via Seamside-App (Devices -> Connect). Kein Inbound-Port noetig.
  Service    : pct enter 100  ->  systemctl status seamside / journalctl -u seamside -f
  Update     : Script erneut laufen lassen (idempotent), ggf. mit --ctid 100
  Deinstall  : pct stop 100 && pct destroy 100
  Reboot-Test: pct reboot 100 && sleep 30 && pct exec 100 -- systemctl is-active seamside
  Log        : /tmp/seamside-install-2026-....log
═════════════════════════════════════════
```

## 2. Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 30
pct exec $CT -- systemctl is-active seamside   # muss: active
pct exec $CT -- tail -n 20 /var/log/seamside.log
pct config $CT | grep -i onboot                # muss: onboot: 1
```

Der Reboot-Test läuft **automatisch** bei jeder Neu-Erstellung
(`REBOOT_TEST=auto`) sowie per `--reboot-test` / `REBOOT_TEST=1` –
auf bestehenden Update-CTs nur auf ausdrücklichen Wunsch
(`--no-reboot-test` unterdrückt ihn überall).

## 3. Update (idempotent – einfach erneut laufen lassen)

```bash
ACCEPT_TOS=1 bash seamside.sh --ctid 100
# laedt nur bei neuer Feed-Version neu, schreibt Unit/Passphrase-Datei neu (Werte bleiben), danach restart.
```

Manuell im Container:

```bash
pct enter 100
/opt/seamside/main/Seamside.AppImage --appimage-extract-and-run --version
systemctl restart seamside && systemctl status seamside --no-pager --full
```

## 4. Deinstallation

```bash
pct stop 100 && pct destroy 100
# Achtung: damit sind auch /var/lib/seamside/* und die Passphrase weg — vorher sichern!
```

## 5. Backup & Restore (automatisch)

Nach jeder Installation zieht das Script Data-Dir + Passphrase-Datei per
`pct pull` auf den Host: `/var/backups/seamside/seamside-ct<CT>-<Datum>.tar.gz`
(rotierend, neueste 3 pro CT; `--no-backup` / `SKIP_BACKUP=1` schaltet ab,
`BACKUP_DIR=` verlegt das Ziel). Restore:

```bash
tar -tzf /var/backups/seamside/seamside-ct100-<Datum>.tar.gz   # Inhalt pruefen
pct push 100 /var/backups/seamside/seamside-ct100-<Datum>.tar.gz /tmp/restore.tar.gz
pct exec 100 -- tar -xzf /tmp/restore.tar.gz -C /
pct exec 100 -- systemctl restart seamside
```

## 6. Debugging (komplette Fehlermeldungskette)

- Jeder Lauf loggt **stdout+stderr vollständig** nach `/tmp/seamside-install-<Datum>.log`.
- Bei Fehlern druckt das Skript: Befehl, Zeile, Exit-Code, Stacktrace
  (`caller`), `pct config`/`pct status`, `journalctl`, `systemctl status` – niemals nur die letzte Zeile.
- Re-run mit Trace:

```bash
bash -x seamside.sh --ctid 100 --accept-tos
DEBUG=1 bash seamside.sh --ctid 100 --accept-tos
# Log mitschicken:
tail -n 200 /tmp/seamside-install-*.log
pct exec 100 -- tail -n 100 /var/log/seamside.log   # App-stdout/stderr (journald fehlt in vielen LXC)
pct exec 100 -- systemctl status seamside --no-pager --full
```

## 7. Dateien in diesem Paket

```text
seamside-proxmox/
├── install/seamside.sh        # Proxmox-Install-Script (Community-Scripts-konform, Variablen oben)
├── systemd/seamside.service   # Unit-Vorlage (wird vom Script mit Instanz-Werten geschrieben)
└── README.md                  # diese Datei
```

`install/seamside.sh` bettet die Unit-Vorlage ein, damit der Einzeiler
ohne weitere Dateien auskommt.

## 8. Hinweise

- **Warum LXC statt VM:** kein eigener Kernel nötig – AppImage mit
  `--appimage-extract-and-run` braucht weder FUSE noch GPU. Keine VM nötig.
- **Warum 2 GB / 8 GB:** Upstream läuft schon auf 512 MB; 2 GB geben dem
  Startup-Peak (DBs + Sync + Deno-Arbiter) Luft. Swap-Tipp aus
  `seamside-manager.sh` gilt für Mini-VPS, im LXC per `--memory` anpassbar.
- **Passphrase + Data-Dir gehören zusammen:** ohne `/etc/seamside/*.env`
  sind die Daten in `/var/lib/seamside/*` unlesbar – beides sichern.
- **Pairing-Link (sibling):** Single-Use, 7 Tage gültig, muss `t=pairing`
  sein (kein Kontakt-Invite `t=invitation`), auf einem Admin-Gerät minten.
- **Firewall:** keine Inbound-Ports nötig (Outbound-P2P wie Desktop-App).
- **Verifikation zum Browser-Zugriff:** Das Script prüft `systemctl is-active` +
  Binary-`--version` + `ss -ltn`-Listener auf dem internen serve-Port, dazu eine
  HTTP-Probe (best-effort, warnt nur – der Port spricht Seamside-P2P, kein HTTP).
  End-to-End-Beleg im Browser: nach dem Pairing in der App einen Frame öffentlich
  teilen (*public sharing*) und den Link im Browser öffnen.
