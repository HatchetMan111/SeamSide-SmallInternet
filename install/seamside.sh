#!/usr/bin/env bash
# ============================================================================
# Seamside auf Proxmox LXC — Einzeiler-Installation (Community-Scripts-Stil)
#
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/SeamSide-SmallInternet/main/install/seamside.sh)"
#
# Was es tut (idempotent, set -euo pipefail):
#   1. nimmt die naechste freie CT-ID (ausser --ctid / CT_ID gesetzt),
#   2. erstellt LXC "seamside" (Debian 12, unprivilegiert, onboot=1),
#   3. installiert im Container die Seamside-AppImage (updates.seamside.com,
#      Arch x86_64/aarch64) + systemd-Unit seamside.service
#      (Restart=always, After=network-online.target),
#   4. verifiziert Service + Binary-Version + Journal, gibt Hinweis aus.
#
# BROWSER-OBERFLAECHE: Ja, es gibt sie — aber nicht als http://[LXC-IP]:[PORT].
# Geteilte Frames/Spaces oeffnen im Browser via Share-Link (Frame-Detail ->
# public sharing, Space-Settings -> public link access; kein Login/Install
# noetig). Der serve-Knoten braucht dafuer KEINE offenen Inbound-Ports
# (Outbound-P2P wie die Desktop-App). SEAMSIDE_PORT ist nur der interne Port
# aus `seamside serve --port`; die Verifikation prueft daher: Service aktiv +
# Port lauscht (ss) + HTTP-Probe (best-effort, warnt nur).
#
# Nicht-interaktiv steuerbar per Env oder Flags (Flags gewinnen):
#   CT_ID / --ctid, CORES / --cores, RAM / --memory, DISK / --disk,
#   BRIDGE / --bridge, STORAGE / --storage, TEMPLATE_STORAGE / --template-storage,
#   SEAMSIDE_MODE=sibling|new-user, SEAMSIDE_JOIN_LINK=..., SEAMSIDE_DISPLAY_NAME=...,
#   SEAMSIDE_OPERATORS=id1,id2, SEAMSIDE_PASSPHRASE=... (sonst generiert),
#   SEAMSIDE_DATA_DIR, SEAMSIDE_PORT, SEAMSIDE_INSTANCE, ACCEPT_TOS=1 / --accept-tos
# Debug: --debug  (= bash -x, maximale Fehlermeldungskette)
# ============================================================================
set -euo pipefail

# ---------------- Variablen oben (Community-Scripts-konform) ----------------
APP="seamside"
HOSTNAME="seamside"
CORES="${CORES:-2}"
RAM="${RAM:-2048}"          # MB
DISK="${DISK:-8}"           # GB
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-}"      # RootFS-Storage, leer = Auto (bevorzugt local-lvm)
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-debian-13-standard}"   # Pflicht: Seamside braucht glibc>=2.39 (Debian 13+, kein Debian 12!)
SEAMSIDE_INSTANCE="${SEAMSIDE_INSTANCE:-main}"
SEAMSIDE_MODE="${SEAMSIDE_MODE:-sibling}"   # sibling | new-user
SEAMSIDE_JOIN_LINK="${SEAMSIDE_JOIN_LINK:-}"
SEAMSIDE_DISPLAY_NAME="${SEAMSIDE_DISPLAY_NAME:-Server}"
SEAMSIDE_OPERATORS="${SEAMSIDE_OPERATORS:-}"
SEAMSIDE_PASSPHRASE="${SEAMSIDE_PASSPHRASE:-}"
SEAMSIDE_DATA_DIR="${SEAMSIDE_DATA_DIR:-}"  # leer = /var/lib/seamside/<instance>
SEAMSIDE_PORT="${SEAMSIDE_PORT:-8080}"      # nur interner serve-Port
ACCEPT_TOS="${ACCEPT_TOS:-0}"
DEBUG="${DEBUG:-0}"
CT_ID="${CT_ID:-}"

LOG_FILE="/tmp/${APP}-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------- helpers ----------------
say()  { printf '%s\n' "$*"; }
ok()   { printf '[OK]    %s\n' "$*"; }
info() { printf '[INFO]  %s\n' "$*"; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
fail() { printf '[FEHLER] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 [Optionen]
  --ctid ID --cores N --memory MB --disk GB --bridge vmbr0
  --storage local-lvm --template-storage local
  --mode sibling|new-user --join-link URL --display-name NAME
  --operators id1,id2 --passphrase SECRET --data-dir /pfad --port N
  --instance NAME --accept-tos --debug --help
Env: CT_ID CORES RAM DISK BRIDGE STORAGE SEAMSIDE_MODE SEAMSIDE_JOIN_LINK
     SEAMSIDE_DISPLAY_NAME SEAMSIDE_OPERATORS SEAMSIDE_PASSPHRASE
     SEAMSIDE_DATA_DIR SEAMSIDE_PORT SEAMSIDE_INSTANCE ACCEPT_TOS DEBUG=1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) RAM="$2"; shift 2 ;;
    --disk) DISK="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --template-storage) TEMPLATE_STORAGE="$2"; shift 2 ;;
    --mode) SEAMSIDE_MODE="$2"; shift 2 ;;
    --join-link) SEAMSIDE_JOIN_LINK="$2"; shift 2 ;;
    --display-name) SEAMSIDE_DISPLAY_NAME="$2"; shift 2 ;;
    --operators) SEAMSIDE_OPERATORS="$2"; shift 2 ;;
    --passphrase) SEAMSIDE_PASSPHRASE="$2"; shift 2 ;;
    --data-dir) SEAMSIDE_DATA_DIR="$2"; shift 2 ;;
    --port) SEAMSIDE_PORT="$2"; shift 2 ;;
    --instance) SEAMSIDE_INSTANCE="$2"; shift 2 ;;
    --accept-tos) ACCEPT_TOS=1; shift ;;
    --debug) DEBUG=1; set -x; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unbekannte Option: $1 (siehe --help)" ;;
  esac
done
[[ "$DEBUG" == "1" ]] && set -x || true

# Komplette Fehlermeldungskette: Befehl, Zeile, Exit-Code, Stacktrace, Logs.
error_trap() {
  local ec=$? cmd="${BASH_COMMAND:-?}" line="${BASH_LINENO[0]:-?}"
  set +x
  say "" >&2
  say "════════ FEHLER (komplette Kette) ════════" >&2
  say "Befehl   : $cmd" >&2
  say "Zeile    : $line   Exit-Code: $ec" >&2
  say "Stacktrace (caller):" >&2
  local i=0
  while caller $i >&2; do i=$((i+1)); done
  if [[ -n "${CT:-}" ]] && command -v pct >/dev/null 2>&1 && pct status "$CT" >/dev/null 2>&1; then
    say "--- pct config $CT ---" >&2
    pct config "$CT" >&2 || true
    say "--- pct status $CT ---" >&2
    pct status "$CT" >&2 || true
    say "--- journal (letzte 50; oft leer in LXC ohne journald) ---" >&2
    pct exec "$CT" -- journalctl -u seamside --no-pager -n 50 >&2 || true
    say "--- /var/log/seamside.log im CT (letzte 60) ---" >&2
    pct exec "$CT" -- tail -n 60 /var/log/seamside.log >&2 || true
    say "--- systemctl status ---" >&2
    pct exec "$CT" -- systemctl status seamside --no-pager --full >&2 || true
  fi
  say "Logdatei : $LOG_FILE" >&2
  # HINWEIS: Bei `bash -c "$(...)" --ctid X` landet --ctid in $0, NICHT in $@!
  # Korrekt: Datei laden (s. unten) oder `wget -qO- URL | bash -s -- --ctid X`.
  say "Re-run idempotent (Datei laden, dann mit Flags laufen lassen):" >&2
  say "  wget -qO /tmp/seamside.sh https://raw.githubusercontent.com/HatchetMan111/SeamSide-SmallInternet/main/install/seamside.sh" >&2
  say "  ACCEPT_TOS=1 bash /tmp/seamside.sh --ctid ${CT:-<id>}   # Trace: bash -x ..." >&2
  say "═════════════════════════════════════════" >&2
}
trap error_trap ERR

# ---------------- preflight (Proxmox-Host) ----------------
[[ "$(id -u)" -eq 0 ]] || fail "Als root auf dem Proxmox-Host ausfuehren."
command -v pct >/dev/null 2>&1 || fail "pct nicht gefunden — auf dem Proxmox-Host (PVE) ausfuehren."
command -v pvesh >/dev/null 2>&1 || fail "pvesh nicht gefunden — auf dem Proxmox-Host (PVE) ausfuehren."
if [[ "$ACCEPT_TOS" != "1" ]]; then
  say "Seamside-ToS: https://seamside.com/terms"
  say "(Installation = Betrieb eines Seamside-serve-Knotens = Akzeptanz der ToS.)"
  if [[ -t 0 ]]; then
    read -rp "ToS akzeptieren und fortfahren? [y/N] " _tos_ans
    [[ "${_tos_ans:-}" =~ ^[Yy]([Ee][Ss])?$ ]] || fail "Abgebrochen — ToS nicht akzeptiert. Tipp: ACCEPT_TOS=1 bzw. --accept-tos fuer Non-Interactive."
    ACCEPT_TOS=1
  elif [[ -r /dev/tty && -w /dev/tty ]]; then
    # stdin ist eine Pipe (z. B. `wget -qO- URL | bash -s -- ...`), aber ein
    # Terminal existiert -> Rueckfrage direkt am TTY.
    read -rp "ToS akzeptieren und fortfahren? [y/N] " _tos_ans < /dev/tty
    [[ "${_tos_ans:-}" =~ ^[Yy]([Ee][Ss])?$ ]] || fail "Abgebrochen — ToS nicht akzeptiert. Tipp: ACCEPT_TOS=1 bzw. --accept-tos fuer Non-Interactive."
    ACCEPT_TOS=1
  else
    fail "Seamside-ToS (https://seamside.com/terms) akzeptieren: ACCEPT_TOS=1 bzw. --accept-tos (kein TTY fuer Rueckfrage)."
  fi
fi
[[ "$SEAMSIDE_MODE" == "sibling" || "$SEAMSIDE_MODE" == "new-user" ]] || fail "--mode muss sibling|new-user sein."
if [[ "$SEAMSIDE_MODE" == "sibling" && -z "$SEAMSIDE_JOIN_LINK" ]]; then
  warn "Kein SEAMSIDE_JOIN_LINK gesetzt: 'sibling'-Instanz startet ohne Pairing-Link."
  warn "Link in der Seamside-App erzeugen (Devices -> + -> Create pairing link) und Script erneut laufen lassen."
fi
if [[ "$SEAMSIDE_MODE" == "new-user" && -z "$SEAMSIDE_OPERATORS" ]]; then
  warn "Keine SEAMSIDE_OPERATORS gesetzt: niemand kann den Server remote administrieren."
fi
if [[ -z "$SEAMSIDE_PASSPHRASE" ]]; then
  SEAMSIDE_PASSPHRASE="$(head -c 33 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32)"
  info "Passphrase generiert (32 Zeichen). WICHTIG: mit Data-Dir sichern — ohne sie sind Daten unlesbar."
fi
[[ -z "$SEAMSIDE_DATA_DIR" ]] && SEAMSIDE_DATA_DIR="/var/lib/seamside/${SEAMSIDE_INSTANCE}"

# ---------------- CT-ID: immer naechste freie ----------------
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  info "Keine CT-ID vorgegeben — nehme naechste freie ID: $CT_ID"
fi
CT="$CT_ID"
[[ "$CT" =~ ^[0-9]+$ ]] || fail "CT-ID muss numerisch sein: $CT"

# RootFS-Storage automatisch erkennen (bevorzugt local-lvm).
if [[ -z "$STORAGE" ]]; then
  if pvesm status --content rootdir 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "local-lvm"; then
    STORAGE="local-lvm"
  else
    STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1{print $1}' | head -1)"
  fi
  [[ -n "$STORAGE" ]] || fail "Kein Storage mit 'rootdir'-Content gefunden."
  info "RootFS-Storage (auto): $STORAGE"
fi

# Neuestes Template sicherstellen (Default debian-13-standard: Seamside
# braucht glibc>=2.39 — Debian 12 (glibc 2.36) startet das Binary nicht).
TPL="$(pveam available --section system 2>/dev/null | grep -oE "${TEMPLATE}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -1 || true)"
if [[ -z "$TPL" ]]; then
  say "Verfuegbare Debian-Templates:" >&2
  pveam available --section system 2>/dev/null | grep -oE "debian-[0-9]+-standard[^ ]*" | sort -Vu >&2 || true
  fail "Kein ${TEMPLATE}-Template gefunden. Falls Proxmox kein Debian 13 anbietet: --template-storage pruefen bzw. pveam update, oder Ubuntu 24.04+-Template via TEMPLATE=ubuntu-24.04-standard."
fi
if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TPL"; then
  info "Lade Template $TPL nach $TEMPLATE_STORAGE ..."
  pveam download "$TEMPLATE_STORAGE" "$TPL"
fi
TPL_PATH="${TEMPLATE_STORAGE}:vztmpl/${TPL}"

# ---------------- Container erstellen oder wiederverwenden ----------------
if pct status "$CT" >/dev/null 2>&1; then
  info "CT $CT existiert bereits — idempotenter Update-Pfad (kein Neuaufbau)."
else
  ROOTPW="$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n' | head -c 20)"
  export ROOTPW
  info "Erstelle LXC $CT (Hostname: $HOSTNAME, ${CORES} vCPU / ${RAM} MB / ${DISK} GB, onboot=1) ..."
  pct create "$CT" "$TPL_PATH" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" --memory "$RAM" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged 1 \
    --onboot 1 \
    --password "$ROOTPW"
  say "Root-Passwort (nur jetzt angezeigt — sicher ablegen!): $ROOTPW"
  unset ROOTPW
fi
pct set "$CT" --onboot 1 || true

pct start "$CT" 2>/dev/null || true
info "Warte auf Container-Start ..."
for _ in $(seq 1 30); do pct exec "$CT" -- true 2>/dev/null && break; sleep 2; done
pct exec "$CT" -- true || fail "Container $CT antwortet nicht auf pct exec."

# OS-Gate: Seamside braucht glibc>=2.39 -> Debian 13+ (Debian 12 = glibc 2.36
# startet das Binary nicht). Frueh abbrechen statt 20 Min. ins Leere zu laden.
GUEST_ID="$(pct exec "$CT" -- cat /etc/os-release 2>/dev/null | grep -E "^ID=" | cut -d= -f2 | tr -d '"' || true)"
GUEST_VER="$(pct exec "$CT" -- cat /etc/os-release 2>/dev/null | grep -E "^VERSION_ID=" | cut -d= -f2 | tr -d '"' || true)"
info "Gast-OS in CT $CT: ${GUEST_ID:-?} ${GUEST_VER:-?}"
if [[ "$GUEST_ID" == "debian" && -n "$GUEST_VER" && "${GUEST_VER%%.*}" -lt 13 ]]; then
  fail "CT $CT ist Debian $GUEST_VER (glibc 2.36) — Seamside braucht Debian 13+ (glibc>=2.39). Loesung: pct stop $CT && pct destroy $CT, dann Script OHNE --ctid erneut laufen lassen (erstellt Debian-13-LXC). Betrifft auch alte CTs (105/147)."
fi

CT_IP="$(pct exec "$CT" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
[[ -n "$CT_IP" ]] || CT_IP="<LXC-IP>"

# ---------------- Setup im Container (idempotent) ----------------
info "Installiere Seamside in CT $CT (Instanz: $SEAMSIDE_INSTANCE, Modus: $SEAMSIDE_MODE) ..."
pct push "$CT" /dev/stdin /tmp/seamside-setup.sh <<SETUP_EOF
set -euo pipefail
INSTANCE="$SEAMSIDE_INSTANCE"
MODE="$SEAMSIDE_MODE"
JOIN_LINK="$SEAMSIDE_JOIN_LINK"
DISPLAY_NAME="$SEAMSIDE_DISPLAY_NAME"
OPERATORS="$SEAMSIDE_OPERATORS"
PASSPHRASE="$SEAMSIDE_PASSPHRASE"
DATA_DIR="$SEAMSIDE_DATA_DIR"
PORT="$SEAMSIDE_PORT"
APP_DIR="/opt/seamside/\$INSTANCE"
APPIMAGE="\$APP_DIR/Seamside.AppImage"
SERVICE_USER="seamside"
UNIT="seamside.service"
PASS_DIR="/etc/seamside"
PASS_FILE="\$PASS_DIR/\$INSTANCE.passphrase"
ENV_FILE="\$PASS_DIR/\$INSTANCE.env"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates file iproute2 systemd-sysv 2>&1 | tail -2

ARCH="\$(uname -m)"
case "\$ARCH" in
  x86_64|amd64) ARCH="x86_64" ;;
  aarch64|arm64) ARCH="aarch64" ;;
  *) echo "[FEHLER] Architektur nicht unterstuetzt: \$ARCH" >&2; exit 1 ;;
esac

id -u "\$SERVICE_USER" >/dev/null 2>&1 || useradd --system --shell /usr/sbin/nologin --home-dir /var/lib/seamside --create-home "\$SERVICE_USER"
mkdir -p "\$DATA_DIR" "\$APP_DIR" "\$PASS_DIR"
chmod 700 "\$PASS_DIR" "\$DATA_DIR"
( umask 077; printf '%s\n' "\$PASSPHRASE" > "\$PASS_FILE" )
chmod 600 "\$PASS_FILE"
# Upstream-Env-Format (SEAMSIDE_KEY_PASSPHRASE) als EnvironmentFile fuer die
# Unit — LoadCredential scheitert in unprivilegierten LXC (243/CREDENTIALS).
# Single-Quote-Maskierung rein per Bash-Expansion (kein sed: GNU-sed
# schluckt \' im Replacement). ' -> '\'' .
ENV_Q="\${PASSPHRASE//\\'/\\'\\\\\\'\\'}"
( umask 077; printf "SEAMSIDE_KEY_PASSPHRASE='%s'\n" "\$ENV_Q" > "\$ENV_FILE" )
chmod 600 "\$ENV_FILE"
rm -f "\$PASS_FILE" 2>/dev/null || true
[ -s "\$ENV_FILE" ] || { echo "[FEHLER] Konnte \$ENV_FILE nicht schreiben." >&2; exit 1; }
chown -R "\$SERVICE_USER:\$SERVICE_USER" "\$DATA_DIR" "\$APP_DIR"

FEED="https://updates.seamside.com/v1/00000000000000000000/linux/\$ARCH/0.0.1"
MANIFEST="\$(curl -fsSL --max-time 30 "\$FEED")" || { echo "[FEHLER] updates.seamside.com nicht erreichbar" >&2; exit 1; }
PLATFORM_KEY="linux-\$ARCH"
PLATFORM_BLOB="\$(printf '%s' "\$MANIFEST" | grep -oE "\"\$PLATFORM_KEY\"[[:space:]]*:[[:space:]]*\\{[^}]*\\}" | head -1)"
VERSION="\$(printf '%s' "\$MANIFEST" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 | sed -E 's/.*"([^"]+)"\$/\\1/')"
URL="\$(printf '%s' "\$PLATFORM_BLOB" | grep -oE '"url"[[:space:]]*:[[:space:]]*"https[^"]+"' | head -1 | sed -E 's/.*"(https[^"]+)"\$/\\1/')"
URL="\${URL/\/r\//\/d\//}"
URL="\$(printf '%s' "\$URL" | sed -E 's#([^:])//+#\\1/#g')"
[ -n "\$VERSION" ] && [ -n "\$URL" ] || { echo "[FEHLER] Kein Release in Manifest (Plattform: \$PLATFORM_KEY). Manifest-Keys: \$(printf '%s' "\$MANIFEST" | grep -oE '"[a-z]+-[a-z0-9_]+"[[:space:]]*:' | head -10 | tr '\n' ' ')" >&2; exit 1; }
case "\$URL" in
  *.AppImage) ;;
  *) echo "[FEHLER] Feed-URL fuer \$PLATFORM_KEY ist keine AppImage: \$URL" >&2; exit 1 ;;
esac
echo "Latest: v\$VERSION (\$PLATFORM_KEY)"

# apt_install_for_soname <soname>: fehlende .so.0-Lib per apt nachinstallieren.
# Der Paketname leitet sich meist aus dem Soname-Stamm ab (libfoo.so.0 ->
# libfoo0), Fallback: apt-cache pkgnames mit gleichem Stamm.
apt_install_for_soname() {
  local lib="\$1" base ver base_re cand_list cand
  base="\${lib%%.so*}"; base="\${base,,}"; base="\${base//_/-}"
  ver=""; [[ "\$lib" == *.so.* ]] && ver="\${lib##*.so.}"
  base_re="\$(sed 's/[.+]/\\\\&/g' <<<"\$base")"
  cand_list="\$( { printf '%s\n' "\${base}\${ver}" "\${base}-\${ver}" "\$base"
    apt-cache pkgnames "\$base" 2>/dev/null | grep -E "^\${base_re}[0-9.-]*\${ver}[a-z]?\$" || true
  } | awk 'NF && !seen[\$0]++' )"
  for cand in \$cand_list; do
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "\$cand" >/dev/null 2>&1; then
      echo "Lib \$lib installiert (Paket: \$cand)."
      return 0
    fi
  done
  return 1
}

# check_system_libs: die AppImage buendelt fast alles, erwartet aber ein paar
# Basis-Display-Libs vom OS schon beim Prozessstart (sonst Exit 127,
# z. B. libwayland-server.so.0 auf minimalem Debian). Extrahieren, per ldd
# gegen gebuendelte Libs pruefen, Fehlendes per apt nachinstallieren.
check_system_libs() {
  local APPIMAGE="\$1"
  echo "Pruefe System-Bibliotheken (AppImage braucht Basis-Libs schon beim Start) ..."
  local LIBCHECK_DIR=""; LIBCHECK_DIR="\$(mktemp -d)"; local MAIN_BIN=""
  if (cd "\$LIBCHECK_DIR" && "\$APPIMAGE" --appimage-extract >/dev/null 2>&1); then
    MAIN_BIN="\$(find "\$LIBCHECK_DIR/squashfs-root/usr/bin" -maxdepth 1 -type f -perm -u+x 2>/dev/null | head -1)"
  fi
  if [ -n "\$MAIN_BIN" ] && command -v ldd >/dev/null 2>&1; then
    local BUNDLED_LIB_PATH MISSING
    BUNDLED_LIB_PATH="\$(find "\$LIBCHECK_DIR/squashfs-root" -maxdepth 4 -type d -name 'lib*' 2>/dev/null | paste -sd: -)"
    MISSING="\$(LD_LIBRARY_PATH="\$BUNDLED_LIB_PATH" ldd "\$MAIN_BIN" 2>/dev/null | awk '/not found/{print \$1}' | sort -u || true)"
    if [ -n "\$MISSING" ]; then
      echo "Fehlende Libs: \$(printf '%s' "\$MISSING" | tr '\n' ' ')"
      apt-get update -qq >/dev/null 2>&1 || true
      local lib
      for lib in \$MISSING; do
        apt_install_for_soname "\$lib" || echo "[WARN] Kein apt-Paket fuer \$lib gefunden." >&2
      done
      MISSING="\$(LD_LIBRARY_PATH="\$BUNDLED_LIB_PATH" ldd "\$MAIN_BIN" 2>/dev/null | awk '/not found/{print \$1}' | sort -u || true)"
    fi
    if [ -n "\$MISSING" ]; then
      echo "[FEHLER] Diese System-Libs fehlen weiterhin:" >&2
      printf '%s\n' "\$MISSING" >&2
      rm -rf "\$LIBCHECK_DIR"
      return 1
    fi
    echo "Alle System-Libs vorhanden."
  else
    echo "[WARN] Lib-Check nicht moeglich (--appimage-extract/ldd) — weiter."
  fi
  rm -rf "\$LIBCHECK_DIR"
}

# binary_ok: ein Smoke-Versuch (--version). Schreibt alles nach SMOKE_LOG
# (globale Temp-Datei, damit die Resolve-Schleife die Ausgabe parsen kann).
binary_ok() {
  [ -x "\$1" ] || return 1
  if command -v file >/dev/null 2>&1; then
    file -b "\$1" | grep -q "ELF 64-bit" || { echo "file-Check: \$1 ist kein 64-bit-ELF: \$(file -b "\$1" | head -c 120)" >&2; return 1; }
  fi
  timeout 120 "\$1" --appimage-extract-and-run --version >"\$SMOKE_LOG" 2>&1
}
CUR=""
[ -s "\$APP_DIR/.version" ] && CUR="\$(tr -d '[:space:]' < "\$APP_DIR/.version")"
if [ ! -x "\$APPIMAGE" ] || [ "\$CUR" != "\$VERSION" ]; then
  [ -x "\$APPIMAGE" ] && echo "Update \$CUR -> \$VERSION ..."
  systemctl stop "\$UNIT" 2>/dev/null || true
  curl -fL --max-time 1800 -o "\$APPIMAGE.part" "\$URL"
  mv "\$APPIMAGE.part" "\$APPIMAGE"
  chmod 755 "\$APPIMAGE"
  printf '%s\n' "\$VERSION" > "\$APP_DIR/.version"
  CUR="\$VERSION"
fi
chown "\$SERVICE_USER:\$SERVICE_USER" "\$APPIMAGE" "\$APP_DIR/.version"
check_system_libs "\$APPIMAGE" || exit 1
# Smoke-Resolve-Schleife: ldd sieht nur statisch gelinkte Libs. Per dlopen
# nachgeladene (Font-Stack: libfribidi u. a.) knallen erst zur Laufzeit mit
# "error while loading shared libraries: X". Die Meldung nennt den exakten
# Soname -> installieren -> Retry, max. 8 Runden, kein endlos-Loop.
# Pre-Seed: diese dlopen-Libs sind auf Debian 13 minimal BELEGT noetig
# (Hauptlauf CT 105). Ein apt-Schritt statt 8 einzelne Extract-Runden.
# Sonames (nicht Paketnamen), damit apt_install_for_soname portabel aufloest.
PRESEED_SONAMES="libfribidi.so.0 libfontconfig.so.1 libwayland-client.so.0 libwayland-cursor.so.0 libwayland-egl.so.1 libX11.so.6 libharfbuzz.so.0 libgpg-error.so.0"
apt-get update -qq >/dev/null 2>&1 || true
for _lib in \$PRESEED_SONAMES; do apt_install_for_soname "\$_lib" >/dev/null 2>&1 || true; done
SMOKE_LOG="\$(mktemp)"
SMOKE_OK=0
TRIED_LIBS=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if binary_ok "\$APPIMAGE"; then SMOKE_OK=1; break; fi
  echo "Smoke-Test (--version) fehlgeschlagen, Ausgabe:" >&2
  tail -n 8 "\$SMOKE_LOG" >&2
  MISSING_SONAME="\$(grep -oE 'error while loading shared libraries: [^ :]+' "\$SMOKE_LOG" | head -1 | awk '{print \$NF}' || true)"
  [ -n "\$MISSING_SONAME" ] || break
  case " \$TRIED_LIBS " in
    *" \$MISSING_SONAME "*) echo "[FEHLER] \$MISSING_SONAME schon installiert, startet trotzdem nicht." >&2; break ;;
  esac
  TRIED_LIBS="\$TRIED_LIBS \$MISSING_SONAME"
  echo "Laufzeit-Lib fehlt (dlopen, fuer ldd unsichtbar): \$MISSING_SONAME — installiere ..."
  apt-get update -qq >/dev/null 2>&1 || true
  apt_install_for_soname "\$MISSING_SONAME" || { echo "[FEHLER] Kein apt-Paket fuer \$MISSING_SONAME gefunden." >&2; break; }
done
rm -f "\$SMOKE_LOG"
if [ "\$SMOKE_OK" != "1" ]; then
  echo "[FEHLER] AppImage v\$VERSION startet nicht (Details oben). URL: \$URL" >&2
  echo "Hinweis bei 'glibc'-Meldung: Gast-OS zu alt — Debian 13+ (oder Ubuntu 24.04+) noetig." >&2
  exit 1
fi
echo "AppImage v\$VERSION verifiziert (Libs + --version OK)."

# systemd-Unit (Restart=always, After=network-online.target, Passphrase via Credential)
FIRST_RUN_ARGS=""
if [ "\$MODE" = "sibling" ]; then
  [ -n "\$JOIN_LINK" ] && FIRST_RUN_ARGS="--join-user \$JOIN_LINK"
else
  FIRST_RUN_ARGS="--new-user \$DISPLAY_NAME"
  [ -n "\$OPERATORS" ] && FIRST_RUN_ARGS="\$FIRST_RUN_ARGS --control-by-users \$OPERATORS"
fi
# shellcheck disable=SC2086
cat > "/etc/systemd/system/\$UNIT" <<UNIT_EOF
[Unit]
Description=Seamside server (\$INSTANCE)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=\$SERVICE_USER
Group=\$SERVICE_USER
WorkingDirectory=\$DATA_DIR
# Passphrase via EnvironmentFile (root-only 600), nie in argv/Unit sichtbar.
# KEIN LoadCredential: scheitert in unprivilegierten LXC (243/CREDENTIALS).
EnvironmentFile=\$ENV_FILE
ExecStart=\$APPIMAGE --appimage-extract-and-run serve --data-dir \$DATA_DIR --port \$PORT --accept-terms-of-service \$FIRST_RUN_ARGS
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=\$DATA_DIR \$APP_DIR
# Datei-Log: journald existiert in vielen LXC nicht ("No journal files") —
# ohne das landet stderr der App im Nichts. FD wird von PID1 geoeffnet.
StandardOutput=append:/var/log/seamside.log
StandardError=inherit
Environment=SEAMSIDE_DISABLE_MDNS=0

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemd-analyze verify "/etc/systemd/system/\$UNIT" 2>&1 | head -5 || true
systemctl daemon-reload
systemctl enable "\$UNIT"
systemctl restart "\$UNIT" 2>/dev/null || systemctl start "\$UNIT"
# Start-Warteschleife: der Erststart extrahiert die 191-MB-AppImage und
# initialisiert DBs/Keystore — sleep 6 war zu kurz und traf ggf. ein
# Restart-Fenster. Poll bis 180s; "stabil aktiv" = 2x active im Abstand
# (entlarvt Crash-Loops, die kurz auf active blinken).
echo "Warte auf stabil aktiven Service (max. 180s, Erststart dauert) ..."
READY=0
for _ in \$(seq 1 36); do
  ST="\$(systemctl is-active "\$UNIT" 2>/dev/null || true)"
  if [ "\$ST" = "active" ]; then
    sleep 5
    ST2="\$(systemctl is-active "\$UNIT" 2>/dev/null || true)"
    if [ "\$ST2" = "active" ]; then READY=1; break; fi
    echo "Service flackert (\$ST -> \$ST2) — warte weiter ..."
  fi
  sleep 5
done
if [ "\$READY" != "1" ]; then
  echo "[FEHLER] Unit \$UNIT wurde in 180s nicht stabil aktiv." >&2
  journalctl -u "\$UNIT" --no-pager -n 50 >&2 || true
  systemctl status "\$UNIT" --no-pager --full >&2 || true
  exit 1
fi
echo "Service stabil aktiv."
BIN_VER="\$("\$APPIMAGE" --appimage-extract-and-run --version 2>/dev/null | tail -n1 | tr -d '[:space:]')"
echo "Service aktiv. Binary-Version: \${BIN_VER:-unbekannt} (Feed: v\$VERSION)"
# Port-Verifikation: internes serve-Interface muss lauschen (ss); HTTP-Probe
# ist best-effort — der Port spricht Seamside-P2P, der Browser-Zugriff laeuft
# ueber Share-Links aus der App, nicht ueber http://IP:PORT direkt.
if ss -ltn 2>/dev/null | grep -qE ":\$PORT\\b"; then
  echo "Port \$PORT lauscht (ss -ltn) — interne serve-Schnittstelle erreichbar."
else
  echo "[WARN] Kein Listener auf Port \$PORT (ss -ltn) — Service laeuft trotzdem, weiter." >&2
  ss -ltn 2>/dev/null >&2 || true
fi
if curl -fs -m 5 "http://127.0.0.1:\$PORT/" >/dev/null 2>&1; then
  echo "HTTP-Probe auf localhost:\$PORT erfolgreich."
else
  echo "[WARN] HTTP-Probe auf localhost:\$PORT ohne Antwort — erwartet: dort laeuft das Seamside-Protokoll, kein HTTP. Browser-Zugriff via Share-Link aus der App." >&2
fi
SETUP_EOF
info "Setup-Script in Container uebertragen."

pct exec "$CT" -- bash /tmp/seamside-setup.sh
rm -f /tmp/seamside-setup.sh 2>/dev/null || true

# ---------------- Verifikation vom Host ----------------
info "Verifiziere ..."
pct exec "$CT" -- systemctl is-active seamside || fail "Service seamside in CT $CT nicht aktiv."
pct config "$CT" | grep -qi "onboot: 1" || fail "onboot: 1 fehlt in CT-Config."
if pct exec "$CT" -- ss -ltn 2>/dev/null | grep -qE ":${SEAMSIDE_PORT}\\b"; then
  ok "Interner serve-Port ${SEAMSIDE_PORT} lauscht im Container (ss -ltn)."
else
  warn "Kein Listener auf Port ${SEAMSIDE_PORT} im Container (ss) — Service ist aktiv, Details: pct exec $CT -- ss -ltn"
fi
CT_IP="$(pct exec "$CT" -- ip -4 -o addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
[[ -n "$CT_IP" ]] || CT_IP="<LXC-IP>"
ok "Service laeuft (systemctl is-active seamside = active)."
ok "Container $CT startet automatisch (onboot: 1)."

say ""
say "════════ INSTALLATION ERFOLGREICH ════════"
say "  App        : Seamside serve-Knoten (Instanz: $SEAMSIDE_INSTANCE, Modus: $SEAMSIDE_MODE)"
say "  Container  : CT $CT (Hostname: $HOSTNAME, onboot=1)"
say "  Ressourcen : $CORES vCPU / ${RAM} MB RAM / ${DISK} GB Disk"
  say "  Daten      : $SEAMSIDE_DATA_DIR  + Passphrase /etc/seamside/${SEAMSIDE_INSTANCE}.env (BEIDES sichern!)"
if [[ "$SEAMSIDE_MODE" == "sibling" ]]; then
  say "  Naechster Schritt: in der Seamside-App unter Devices den Server genehmigen (Admin-Geraet)."
else
  say "  Naechster Schritt: Operator-Einladungslinks aus 'journalctl -u seamside' holen, in der App annehmen."
fi
  say "  HINWEIS    : Browser-Zugriff via Share-Link aus der Seamside-App"
  say "               (Frame-Detail -> public sharing / Space-Settings -> public link"
  say "               access) — Besucher oeffnen den Link im Browser, kein Login noetig."
  say "               Kein direkter http://[LXC-IP]:[PORT]-Zugriff, keine Inbound-Ports noetig."
say "  Service    : pct enter $CT  ->  systemctl status seamside / journalctl -u seamside -f"
say "  Update     : Script erneut laufen lassen (idempotent), ggf. mit --ctid $CT"
say "  Deinstall  : pct stop $CT && pct destroy $CT"
say "  Reboot-Test: pct reboot $CT && sleep 30 && pct exec $CT -- systemctl is-active seamside"
say "  Log        : $LOG_FILE"
say "═════════════════════════════════════════"
