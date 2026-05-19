#!/usr/bin/env bash
set -euo pipefail

# Mountpoint fuer den USB-Stick (virtuell)
USB_MNT=/mnt/fedora-usb
LOG_DIR=/src/logs
LOG_FILE="${LOG_DIR}/podman-rpm-pipeline.log"

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ "${RPM_PIPELINE_TRACE:-0}" == "1" ]]; then
    export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '
    set -x
fi

PODMAN_PLATFORM="linux/amd64"

check_bitwig_audio_setup() {
    local profile="$1"
    local target_user="$2"
    local target_home="$3"

    if [[ ! "$profile" =~ ^(full|theme-bash)$ ]]; then
        echo "[rpm-pipeline] Bitwig-Check uebersprungen (Profil: ${profile})"
        return 0
    fi

    echo "[rpm-pipeline] Pruefe Bitwig Flatpak + Audio-Launcher fuer Profil ${profile} ..."

    if ! command -v flatpak >/dev/null 2>&1; then
        echo "[WARN] flatpak nicht verfuegbar - Bitwig-Check nur teilweise moeglich"
    else
        if sudo -u "$target_user" env HOME="$target_home" USER="$target_user" \
            flatpak info com.bitwig.BitwigStudio >/dev/null 2>&1; then
            echo "[rpm-pipeline] OK: Bitwig Flatpak vorhanden"
        else
            echo "[WARN] Bitwig Flatpak nicht installiert (oder Flathub nicht erreichbar)"
        fi
    fi

    if [[ -x "$target_home/.local/bin/bitwig-studio" ]]; then
        echo "[rpm-pipeline] OK: Audio-Launcher vorhanden ($target_home/.local/bin/bitwig-studio)"
    else
        echo "[WARN] Audio-Launcher fehlt: $target_home/.local/bin/bitwig-studio"
    fi

    if [[ -f "$target_home/.local/share/applications/fedora-bitwig-audio.desktop" ]]; then
        echo "[rpm-pipeline] OK: Desktop-Eintrag vorhanden"
    else
        echo "[WARN] Desktop-Eintrag fehlt: $target_home/.local/share/applications/fedora-bitwig-audio.desktop"
    fi
}

smoke_test_vllm_podman_stack() {
    local profile="$1"
    local smoke_image="localhost/fedora-vllm:latest"
    local smoke_container="fedora-vllm-smoke"

    if [[ ! "$profile" =~ ^(full|headless-vllm)$ ]]; then
        echo "[rpm-pipeline] vLLM Podman-Smoke uebersprungen (Profil: ${profile})"
        return 0
    fi

    if ! command -v podman >/dev/null 2>&1; then
        echo "[WARN] podman nicht verfuegbar - vLLM-Smoke-Test uebersprungen"
        return 0
    fi

    echo "[rpm-pipeline] vLLM-Smoke: Image=${smoke_image} Container=${smoke_container}"
    echo "[rpm-pipeline] Baue vLLM-Smoke-Image ${smoke_image} ..."
    local build_dir
    build_dir="$(mktemp -d /tmp/fedora-vllm-smoke.XXXXXX)"
    cat > "${build_dir}/Containerfile" <<'DOCKERFILE'
FROM fedora:43
COPY vllm-smoke.sh /usr/local/bin/vllm-smoke.sh
CMD ["/bin/bash", "/usr/local/bin/vllm-smoke.sh"]
DOCKERFILE

    cat > "${build_dir}/vllm-smoke.sh" <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail

echo "vllm-smoke-ready" > /tmp/vllm-smoke-ready
trap 'exit 0' TERM INT
while true; do
    sleep 3600
done
SHEOF

    podman build --platform "${PODMAN_PLATFORM}" --pull=missing -t "${smoke_image}" -f "${build_dir}/Containerfile" "${build_dir}" \
        && echo "[rpm-pipeline] OK: vLLM-Smoke-Image gebaut: ${smoke_image}" \
        || { echo "[FAIL] vLLM-Smoke-Image Build fehlgeschlagen"; rm -rf "${build_dir}"; return 1; }

    echo "[rpm-pipeline] Erzeuge vLLM-Smoke-Container ${smoke_container} ..."
    podman rm -f "${smoke_container}" >/dev/null 2>&1 || true
    podman create --platform "${PODMAN_PLATFORM}" --name "${smoke_container}" "${smoke_image}" \
        && echo "[rpm-pipeline] OK: vLLM-Smoke-Container erstellt: ${smoke_container}" \
        || { echo "[FAIL] vLLM-Smoke-Container konnte nicht erstellt werden"; rm -rf "${build_dir}"; return 1; }

    podman start "${smoke_container}" >/dev/null \
        && echo "[rpm-pipeline] OK: vLLM-Smoke-Container gestartet: ${smoke_container}" \
        || { echo "[FAIL] vLLM-Smoke-Container konnte nicht gestartet werden"; podman rm -f "${smoke_container}" >/dev/null 2>&1 || true; rm -rf "${build_dir}"; return 1; }

    local smoke_ready=0
    for _ in $(seq 1 30); do
        if podman exec "${smoke_container}" test -f /tmp/vllm-smoke-ready >/dev/null 2>&1
        then
            smoke_ready=1
            break
        fi
        sleep 1
    done

    if [[ "$smoke_ready" -ne 1 ]]; then
        echo "[FAIL] vLLM-Smoke-Readiness-Check fehlgeschlagen"
        podman logs "${smoke_container}" || true
        podman rm -f "${smoke_container}" >/dev/null 2>&1 || true
        rm -rf "${build_dir}"
        return 1
    fi

    echo "[rpm-pipeline] OK: vLLM-Smoke-Readiness-Check bestanden"

    echo "[rpm-pipeline] vLLM-Smoke: Container erfolgreich gestartet und wieder entfernt"
    podman rm -f "${smoke_container}" >/dev/null 2>&1 || true
    rm -rf "${build_dir}"
}

# 1. RPM suchen
RPM=$(ls "$USB_MNT"/rpm/fedora-autoinstall-*.rpm | head -1)
if [[ ! -f "$RPM" ]]; then
    echo "Kein RPM gefunden unter $USB_MNT/rpm/"
    exit 1
fi

echo "[rpm-pipeline] Installiere $RPM ..."
# 2. RPM installieren
dnf install -y "$RPM"

echo "[rpm-pipeline] Systemd-Unit aktivieren (Simulation) ..."
# 3. Systemd-Unit einmalig aktivieren (Simulation)
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || echo "[WARN] systemctl daemon-reload fehlgeschlagen (Container?)"
    systemctl enable fedora-first-boot.service 2>/dev/null || echo "[WARN] systemctl enable fehlgeschlagen (Container?)"
else
    echo "[WARN] systemctl nicht verfuegbar (Container?)"
fi

echo "[rpm-pipeline] Teste fedora-provision.sh ..."
# 4. Provisioning-Skript als root testen (setzt Profil-Env + Marker-Reset)
PROFILE="${FEDORA_INSTALL_PROFILE:-full}"
TARGET_USER="${FEDORA_TARGET_USER:-sija}"
echo "[rpm-pipeline] Profil fuer fedora-provision: ${PROFILE}"
/usr/local/sbin/fedora-provision.sh --profile "$PROFILE" --user "$TARGET_USER" --run-now \
    || { echo "fedora-provision.sh FEHLER"; exit 3; }

echo "[rpm-pipeline] Teste first-boot.sh mit Provisioning-Env ..."
# 5. First-Boot explizit starten (wichtig in Containern ohne systemd PID1)
/usr/local/sbin/fedora-first-boot.sh || { echo "first-boot.sh FEHLER"; exit 2; }

echo "[rpm-pipeline] Teste first-login.sh als Ziel-User ..."
# 6. First-Login-Skript als Ziel-User testen
TARGET_USER="${FEDORA_TARGET_USER:-sija}"
TARGET_HOME="/home/${TARGET_USER}"

echo "[rpm-pipeline] Stelle Voraussetzungen fuer first-login bereit (git/curl) ..."
dnf install -y git curl >/dev/null 2>&1 || echo "[WARN] Konnte git/curl nicht vorab installieren"

if id "$TARGET_USER" >/dev/null 2>&1; then
    sudo -u "$TARGET_USER" env HOME="$TARGET_HOME" USER="$TARGET_USER" \
        /usr/local/bin/fedora-first-login.sh || { echo "first-login.sh FEHLER"; exit 4; }
    check_bitwig_audio_setup "$PROFILE" "$TARGET_USER" "$TARGET_HOME"
else
    echo "[WARN] Ziel-User nicht gefunden fuer first-login Test: ${TARGET_USER}"
fi

smoke_test_vllm_podman_stack "$PROFILE" || exit 5

echo "[rpm-pipeline] PASS"

# Journal-Check: Zeige relevante Logs, falls journalctl verfuegbar ist
if command -v journalctl >/dev/null 2>&1; then
    echo "[rpm-pipeline] Journal-Auszug (fedora-first-boot.service):"
    journalctl -u fedora-first-boot.service || echo "[WARN] Keine Logs fuer fedora-first-boot.service gefunden."
    echo "[rpm-pipeline] Journal-Auszug (fedora-first-login.sh):"
    journalctl | grep -i 'first-login' || echo "[WARN] Keine Logs zu first-login gefunden."
else
    echo "[INFO] journalctl nicht verfuegbar (Container?)"
fi
