#!/usr/bin/env bash
# fedora-provision.sh — Provisioniert ein bestehendes Fedora-System
#
# Richtet das gewählte Profil auf einem bereits installierten Fedora-System ein.
# Es installiert KEIN neues OS.
#
# Nutzung:
#   sudo bash /usr/local/share/fedora-autoinstall/fedora-provision.sh --profile theme-bash
#   sudo bash /usr/local/share/fedora-autoinstall/fedora-provision.sh --profile headless-vllm
#   sudo bash /usr/local/share/fedora-autoinstall/fedora-provision.sh --profile full
#
# Optionen:
#   --profile   full | theme-bash | headless-vllm | cachyos-kernel  (erforderlich)
#   --user      Ziel-Benutzer (Standard: $SUDO_USER)
#   --run-now   first-boot sofort starten statt nur einrichten

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    RESOLVED_PATH="$(readlink -f "$SCRIPT_PATH" 2>/dev/null || true)"
    if [[ -n "$RESOLVED_PATH" ]]; then
        SCRIPT_PATH="$RESOLVED_PATH"
    fi
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# ── Farben ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; CYAN=''; BOLD=''; RESET=''
fi

log()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}══ $* ══${RESET}"; }

systemd_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -d /run/systemd/system ]] || return 1
    systemctl show-environment >/dev/null 2>&1 || return 1
}

systemctl_safe() {
    if systemd_available; then
        systemctl "$@"
    else
        warn "systemctl $* uebersprungen (kein systemd als PID 1)."
        return 0
    fi
}

# ── Argument-Parsing ──────────────────────────────────────────────────────────
PROFILE=""
TARGET_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "$TARGET_USER" ]]; then
    TARGET_USER="$(logname 2>/dev/null || id -un 2>/dev/null || echo root)"
fi
RUN_NOW=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)  PROFILE="$2";      shift 2 ;;
        --user)     TARGET_USER="$2";  shift 2 ;;
        --run-now)  RUN_NOW=1;         shift   ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Unbekannte Option: $1" ;;
    esac
done

[[ -z "$PROFILE" ]] && die "--profile fehlt. Erlaubt: full | theme-bash | headless-vllm | cachyos-kernel"
[[ "$EUID" -ne 0 ]] && die "Bitte als root ausführen: sudo bash $0 --profile $PROFILE"
id "$TARGET_USER" &>/dev/null || die "Benutzer nicht gefunden: $TARGET_USER"

USER_HOME="/home/${TARGET_USER}"
USER_ENV_DIR="${USER_HOME}/.config/fedora-provision"
USER_ENV_FILE="${USER_ENV_DIR}/env"
SYSTEM_ENV_FILE="/etc/fedora-provision.env"

# ── Profil → Umgebungsvariablen ───────────────────────────────────────────────
step "Profil: ${PROFILE}  Benutzer: ${TARGET_USER}"

case "$PROFILE" in
    full)
        cat > /etc/fedora-provision.env <<ENVEOF
FEDORA_INSTALL_PROFILE="full"
FEDORA_TARGET_USER="${TARGET_USER}"
FEDORA_OMB_THEME="modern"
FEDORA_WS_GTK_ARGS="-c Dark"
FEDORA_WS_ICON_ARGS=""
FEDORA_WS_WALL_ARGS=""
FEDORA_CUDA_SOURCE="nvidia"
FEDORA_KERNEL_SOURCE="cachyos"
FEDORA_NVIDIA_OPEN_ONLY="0"
FEDORA_AUDIO_MODEL="moonshotai/Kimi-Audio-7B-Instruct"
FEDORA_AGENT_MODEL="Qwen/Qwen3-8B"
FEDORA_VLLM_ROUTER_PORT="8000"
FEDORA_VLLM_REGISTRY="\$HOME/.config/vllm-router/models.json"
ENVEOF
        ;;
    theme-bash)
        cat > /etc/fedora-provision.env <<ENVEOF
FEDORA_INSTALL_PROFILE="theme-bash"
FEDORA_TARGET_USER="${TARGET_USER}"
FEDORA_OMB_THEME="modern"
FEDORA_WS_GTK_ARGS="-c Dark"
FEDORA_WS_ICON_ARGS=""
FEDORA_WS_WALL_ARGS=""
FEDORA_CUDA_SOURCE="fedora"
FEDORA_KERNEL_SOURCE="fedora"
FEDORA_NVIDIA_OPEN_ONLY="1"
ENVEOF
        ;;
    nvidia-cuda)
        cat > /etc/fedora-provision.env <<ENVEOF
FEDORA_INSTALL_PROFILE="nvidia-cuda"
FEDORA_TARGET_USER="${TARGET_USER}"
FEDORA_KERNEL_SOURCE="cachyos"
ENVEOF
        ;;
    vllm-only)
        die "Profil 'vllm-only' wurde entfernt (keine GPU-Unterstützung ohne NVIDIA). Verwende 'headless-vllm'."
        ;;
    headless-vllm)
        cat > /etc/fedora-provision.env <<ENVEOF
FEDORA_INSTALL_PROFILE="headless-vllm"
FEDORA_TARGET_USER="${TARGET_USER}"
FEDORA_AUDIO_MODEL="moonshotai/Kimi-Audio-7B-Instruct"
FEDORA_AGENT_MODEL="Qwen/Qwen3-8B"
FEDORA_VLLM_ROUTER_PORT="8000"
FEDORA_VLLM_REGISTRY="\$HOME/.config/vllm-router/models.json"
FEDORA_OMB_THEME="modern"
FEDORA_CUDA_SOURCE="nvidia"
FEDORA_KERNEL_SOURCE="cachyos"
FEDORA_NVIDIA_OPEN_ONLY="0"
ENVEOF
        ;;
    cachyos-kernel)
    cat > /etc/fedora-provision.env <<ENVEOF
FEDORA_INSTALL_PROFILE="cachyos-kernel"
FEDORA_TARGET_USER="${TARGET_USER}"
FEDORA_KERNEL_SOURCE="cachyos"
FEDORA_NVIDIA_OPEN_ONLY="1"
ENVEOF
    ;;
    *)
    die "Unbekanntes Profil: '${PROFILE}'. Erlaubt: full | theme-bash | headless-vllm | cachyos-kernel"
        ;;
esac

install -d -m 0755 "$USER_ENV_DIR"
cp "$SYSTEM_ENV_FILE" "$USER_ENV_FILE"
chmod 0644 "$SYSTEM_ENV_FILE" "$USER_ENV_FILE"
chown -R "${TARGET_USER}:${TARGET_USER}" "$USER_ENV_DIR" 2>/dev/null || true
log "${SYSTEM_ENV_FILE} geschrieben"
log "${USER_ENV_FILE} geschrieben"

# ── Scripts installieren (RPM/USB/Repo robust) ───────────────────────────────
step "Scripts installieren"

SCRIPTS_SRC=""
SYSTEMD_SRC=""

for base in \
    "$SCRIPT_DIR" \
    "/usr/local/share/fedora-autoinstall" \
    "/usr/local/share/fedora-autoinstall/scripts/.." \
    "$PWD"; do
    [[ -f "$base/scripts/first-boot.sh" ]] && SCRIPTS_SRC="$base/scripts"
    [[ -f "$base/systemd/fedora-first-boot.service" ]] && SYSTEMD_SRC="$base/systemd"
done

if [[ -z "$SCRIPTS_SRC" ]]; then
    warn "Konnte Scripts-Quelle nicht automatisch finden (erwartet: */scripts/first-boot.sh)."
fi
if [[ -z "$SYSTEMD_SRC" ]]; then
    warn "Konnte Systemd-Quelle nicht automatisch finden (erwartet: */systemd/fedora-first-boot.service)."
fi

install_file() {
    local src="$1" dest="$2" mode="$3"
    if [[ -f "$src" ]]; then
        cp "$src" "$dest"
        chmod "$mode" "$dest"
        log "  $(basename "$dest")"
    else
        warn "  Nicht gefunden: $src"
    fi
}

install_file "${SCRIPTS_SRC}/first-boot.sh"  /usr/local/sbin/fedora-first-boot.sh  0750
install_file "${SCRIPTS_SRC}/first-login.sh" /usr/local/bin/fedora-first-login.sh  0755

# ── Systemd First-Boot Service ────────────────────────────────────────────────
step "Systemd Service"

if [[ -f "${SYSTEMD_SRC}/fedora-first-boot.service" ]]; then
    cp "${SYSTEMD_SRC}/fedora-first-boot.service" /etc/systemd/system/
else
    cat > /etc/systemd/system/fedora-first-boot.service <<'UNITEOF'
[Unit]
Description=Fedora First-Boot Provisioning (one-shot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/fedora-provision/first-boot.done

[Service]
Type=simple
ExecStart=/usr/local/sbin/fedora-first-boot.sh
EnvironmentFile=-/etc/fedora-provision.env
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=3600
User=root

[Install]
WantedBy=multi-user.target
UNITEOF
fi

# Marker zurücksetzen damit first-boot für dieses Profil erneut läuft
rm -f /var/lib/fedora-provision/first-boot.done

systemctl_safe daemon-reload
systemctl_safe enable fedora-first-boot.service
log "fedora-first-boot.service aktiviert"

# ── First-Login: GUI vs. Headless ─────────────────────────────────────────────
step "First-Login einrichten"

# Alten first-login-Marker zurücksetzen
rm -f "${USER_HOME}/.local/share/fedora-provision/first-login.done"

if [[ "$PROFILE" =~ ^(theme-bash|full)$ ]]; then
    # GUI-Profile: GNOME-Autostart
    AUTOSTART_DIR="${USER_HOME}/.config/autostart"
    mkdir -p "$AUTOSTART_DIR"
    cat > "${AUTOSTART_DIR}/fedora-first-login.desktop" <<DESKTOPEOF
[Desktop Entry]
Type=Application
Name=Fedora First-Login Setup
Exec=/usr/local/bin/fedora-first-login.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOPEOF
    chown -R "${TARGET_USER}:${TARGET_USER}" "$AUTOSTART_DIR"
    log "GNOME-Autostart für '${TARGET_USER}' eingerichtet"
elif [[ "$PROFILE" == "cachyos-kernel" ]]; then
    log "First-Login für Profil 'cachyos-kernel' übersprungen (nur Kernel-Setup)."
else
    # Headless-Profile: systemd User-Service
    cat > /etc/systemd/system/fedora-provision-user.service <<USRUNITEOF
[Unit]
Description=Fedora User Provisioning (${PROFILE})
After=fedora-first-boot.service network-online.target
Requires=fedora-first-boot.service
ConditionPathExists=!${USER_HOME}/.local/share/fedora-provision/first-login.done

[Service]
Type=oneshot
RemainAfterExit=yes
User=${TARGET_USER}
Group=${TARGET_USER}
Environment=HOME=${USER_HOME}
EnvironmentFile=-${USER_ENV_FILE}
EnvironmentFile=-${SYSTEM_ENV_FILE}
ExecStart=/usr/local/bin/fedora-first-login.sh
StandardOutput=journal
StandardError=journal
TimeoutStartSec=7200

[Install]
WantedBy=multi-user.target
USRUNITEOF
    systemctl_safe enable fedora-provision-user.service
    log "fedora-provision-user.service aktiviert"
fi

# ── Flatpak Flathub (GUI-Profile) ─────────────────────────────────────────────
if [[ "$PROFILE" =~ ^(theme-bash|full)$ ]]; then
    flatpak remote-add --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
fi

# ── Sofort starten (optional) ─────────────────────────────────────────────────
if [[ "$RUN_NOW" == "1" ]]; then
    step "First-Boot läuft — Ausgabe direkt im Terminal"
    echo ""

    # Direkt ausführen statt via systemctl — Ausgabe sofort sichtbar.
    # first-boot.sh tee'd bereits in LOG_FILE + stdout.
    FIRST_BOOT_SCRIPT="/usr/local/sbin/fedora-first-boot.sh"
    [[ -x "$FIRST_BOOT_SCRIPT" ]] || FIRST_BOOT_SCRIPT="/usr/local/share/fedora-autoinstall/scripts/first-boot.sh"

    "$FIRST_BOOT_SCRIPT"
    BOOT_RC=$?

    echo ""
    if [[ $BOOT_RC -eq 0 ]]; then
        log "First-Boot erfolgreich abgeschlossen."
    else
        warn "First-Boot mit Exit-Code ${BOOT_RC} beendet."
    fi

    # Headless-Profile: first-login als Ziel-User direkt starten
    if [[ ! "$PROFILE" =~ ^(theme-bash|full|cachyos-kernel)$ ]] && [[ $BOOT_RC -eq 0 ]]; then
        FIRST_LOGIN_SCRIPT="/usr/local/bin/fedora-first-login.sh"
        if [[ -x "$FIRST_LOGIN_SCRIPT" ]]; then
            step "First-Login läuft (User: ${TARGET_USER})"
            echo ""
            sudo -u "$TARGET_USER" \
                env HOME="/home/${TARGET_USER}" \
                    FEDORA_TARGET_USER="$TARGET_USER" \
                    $(cat /etc/fedora-provision.env 2>/dev/null | tr '\n' ' ') \
                "$FIRST_LOGIN_SCRIPT" || warn "first-login mit Fehler beendet (non-fatal)."
        fi
    fi
else
    echo ""
    log "Einrichtung abgeschlossen."
    echo ""
    echo -e "  ${BOLD}Nächster Schritt:${RESET}"
    echo -e "    Neu starten  →  Provisionierung startet automatisch"
    echo ""
    echo -e "  ${BOLD}Oder sofort starten:${RESET}"
    echo -e "    sudo systemctl start fedora-first-boot.service"
    echo -e "    journalctl -fu fedora-first-boot.service"
fi
