#!/usr/bin/env bash
# tools/build-iso.sh — Patcht die Fedora-Netinstall-ISO mit Kickstart + RPM-Repo.
#
# Eingebettet in die ISO:
#   - kickstart/fedora-full.ks  (automatisch beim Boot geladen)
#   - rpm/                       (fedora-autoinstall + repodata)
#
# Läuft in einem Fedora:43 Podman-Container (mkksiso nicht auf macOS verfügbar).
#
# Usage:
#   tools/build-iso.sh
#   make build-iso

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOST_OS="$(uname -s)"
PODMAN_PLATFORM="linux/amd64"

if [[ -t 1 ]]; then
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=""; YELLOW=""; RED=""; CYAN=""; BOLD=""; RESET=""
fi
log()  { echo -e "${GREEN}[build-iso]${RESET} $*"; }
warn() { echo -e "${YELLOW}[build-iso]${RESET} $*" >&2; }
die()  { echo -e "${RED}[build-iso] $*${RESET}" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}══ $* ══${RESET}"; }

podman_exec() {
    if [[ "$HOST_OS" == "Darwin" && "${EUID:-0}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
        # macOS: sudo-Kontext → als ursprünglichen User ausführen
        sudo -u "$SUDO_USER" podman "$@"
    elif [[ "$HOST_OS" == "Linux" && "${EUID:-0}" -ne 0 ]]; then
        # Linux ohne Root (z.B. GitHub Actions runner) → sudo podman
        sudo podman "$@"
    else
        podman "$@"
    fi
}

# ── Voraussetzungen ───────────────────────────────────────────────────────────
step "Voraussetzungen"

SRC_ISO=$(ls -t "${PROJECT_DIR}"/iso/Fedora-Everything-netinst-*.iso 2>/dev/null | head -1 || true)
[[ -n "$SRC_ISO" ]] || die "Keine Fedora netinstall ISO unter iso/ — z.B. Fedora-Everything-netinst-x86_64-43-1.6.iso"
log "Quell-ISO:  $(basename "$SRC_ISO")"

ls "${PROJECT_DIR}"/rpm/*.rpm &>/dev/null \
    || die "Kein RPM unter rpm/ — zuerst ausführen: make build-rpm"
log "RPM:        $(ls "${PROJECT_DIR}"/rpm/*.rpm | xargs -n1 basename | tr '\n' ' ')"

[[ -f "${PROJECT_DIR}/kickstart/fedora-full.ks" ]] \
    || die "kickstart/fedora-full.ks fehlt — zuerst ausführen: make generate-ks"
log "Kickstart:  kickstart/fedora-full.ks"

# Ausgabe-ISO: Fedora-Everything-netinst-x86_64-43-1.6.iso → fedora-autoinstall-x86_64-43-1.6.iso
ISO_SUFFIX=$(basename "$SRC_ISO" | sed 's/Fedora-Everything-netinst-//')
OUT_ISO="${PROJECT_DIR}/iso/fedora-autoinstall-${ISO_SUFFIX}"
SRC_ISO_REL="iso/$(basename "$SRC_ISO")"
OUT_ISO_REL="iso/$(basename "$OUT_ISO")"
log "Ausgabe:    $(basename "$OUT_ISO")"

# ── Podman starten ────────────────────────────────────────────────────────────
step "Podman"
if [[ "$HOST_OS" == "Darwin" ]]; then
    podman_exec machine start 2>/dev/null || true
fi
podman_exec info >/dev/null 2>&1 || die "Podman nicht bereit."
log "Podman bereit."

# ── ISO bauen ─────────────────────────────────────────────────────────────────
step "ISO bauen (mkksiso)"

podman_exec run --rm \
    --privileged \
    --platform "${PODMAN_PLATFORM}" \
    -v "${PROJECT_DIR}:/src:Z" \
    fedora:43 /bin/bash -c "
set -euo pipefail

echo '[build-iso] Installiere Build-Tools...'
dnf install -y lorax xorriso createrepo_c bsdtar mtools >/dev/null

echo '[build-iso] Repo-Metadaten aktualisieren...'
createrepo_c --update /src/rpm >/dev/null

echo '[build-iso] RPM-Verzeichnis vorbereiten...'
mkdir -p /tmp/iso_add
cp -r /src/rpm /tmp/iso_add/rpm

rm -f /src/${OUT_ISO_REL}

echo '[build-iso] mkksiso läuft...'
mkksiso \
    --ks /src/kickstart/fedora-full.ks \
    -a /tmp/iso_add/rpm \
    -c 'inst.addrepo=fedora-autoinstall,file:///run/install/repo/rpm' \
    --skip-mkefiboot \
    /src/${SRC_ISO_REL} \
    /src/${OUT_ISO_REL}

echo '[build-iso] Patche EFI-FAT + default=0...'
python3 /src/tools/patch_iso.py /src/${OUT_ISO_REL}

echo '[build-iso] Fertig.'
"

SIZE=$(du -h "$OUT_ISO" | cut -f1)
log "ISO fertig: $(basename "$OUT_ISO") (${SIZE})"

echo ""
echo -e "  ${BOLD}USB beschreiben:${RESET}"
echo -e "    macOS: sudo dd if=${OUT_ISO} of=/dev/rdiskN bs=4m status=progress"
echo -e "    Linux: sudo dd if=${OUT_ISO} of=/dev/sdX   bs=4M  status=progress"
echo ""
echo -e "  ${BOLD}Oder mit Makefile:${RESET}"
echo -e "    make write-iso DEVICE=/dev/diskN"
