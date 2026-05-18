#!/usr/bin/env bash
set -euo pipefail

# Mountpoint fuer den USB-Stick (virtuell)
USB_MNT=/mnt/fedora-usb

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

echo "[rpm-pipeline] Teste first-boot.sh ..."
# 4. First-Boot-Skript als root testen
/usr/local/sbin/fedora-first-boot.sh || { echo "first-boot.sh FEHLER"; exit 2; }

echo "[rpm-pipeline] Teste fedora-provision.sh ..."
# 5. Provisioning-Skript als root testen
/usr/local/sbin/fedora-provision.sh || { echo "fedora-provision.sh FEHLER"; exit 3; }

echo "[rpm-pipeline] Teste first-login.sh als nobody ..."
# 6. First-Login-Skript als normaler User testen (hier: nobody)
sudo -u nobody /usr/local/bin/fedora-first-login.sh || { echo "first-login.sh FEHLER"; exit 4; }

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
