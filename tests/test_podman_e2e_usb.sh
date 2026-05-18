#!/usr/bin/env bash
# tests/test_podman_e2e_usb.sh
#
# E2E-Test: simuliert einen USB-Stick via Image-Datei in einem privilegierten
# Fedora-Container, führt install.sh aus und prüft Artefakte auf der Daten-Partition.
#
# Usage:
#   bash tests/test_podman_e2e_usb.sh --run
#   bash tests/test_podman_e2e_usb.sh          # skip (default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

if [[ "${1:-}" != "--run" ]]; then
    echo "[podman-e2e] skipped (nutze --run fuer echten E2E-Lauf)"
    exit 0
fi

command -v podman >/dev/null 2>&1 || {
    echo "[podman-e2e] skipped (podman nicht gefunden)"
    exit 0
}

if ! podman info >/dev/null 2>&1; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
        podman machine start >/dev/null
    fi
fi
podman info >/dev/null 2>&1 || {
    echo "[podman-e2e] FAIL: podman nicht bereit"
    exit 1
}

echo "[podman-e2e] starte E2E-Container..."

podman run --rm --privileged \
    -v "${PROJECT_DIR}:/src:Z" \
    fedora:latest \
    /bin/bash -lc '
        set -euo pipefail

        dnf -y install \
            gdisk dosfstools grub2-efi-x64 grub2-tools \
            cpio file xz zstd curl python3 python3-pip \
            rpm-build createrepo_c pykickstart \
            util-linux e2fsprogs xorriso >/dev/null

        cd /src

        # Kleine Test-ISO mit den benoetigten Pfaden erstellen.
        work=/tmp/e2e-usb
        mkdir -p "$work/iso/images/pxeboot"
        dd if=/dev/zero of="$work/iso/images/pxeboot/vmlinuz" bs=1K count=64 status=none
        dd if=/dev/zero of="$work/iso/images/pxeboot/initrd.img" bs=1K count=256 status=none
        xorriso -as mkisofs -R -J -o "$work/Fedora-Everything-netinst-x86_64-43-1.6.iso" "$work/iso" >/dev/null 2>&1

        mkdir -p /src/iso
        cp "$work/Fedora-Everything-netinst-x86_64-43-1.6.iso" /src/iso/

        # grub2-install scheitert in Containern oft auf overlayfs.
        # Für den E2E-Test mocken wir nur diesen Schritt und prüfen den Rest des Flows.
        mockbin=/tmp/mockbin
        mkdir -p "$mockbin"
        cat > "$mockbin/grub2-install" <<"EOF"
#!/usr/bin/env bash
set -euo pipefail
efi_dir=""
boot_dir=""
for arg in "$@"; do
    case "$arg" in
        --efi-directory=*) efi_dir="${arg#*=}" ;;
        --boot-directory=*) boot_dir="${arg#*=}" ;;
    esac
done
[[ -n "$efi_dir" ]] || { echo "mock grub2-install: missing --efi-directory" >&2; exit 1; }
[[ -n "$boot_dir" ]] || { echo "mock grub2-install: missing --boot-directory" >&2; exit 1; }
mkdir -p "$efi_dir/EFI/BOOT" "$boot_dir/grub2"
echo "MOCK-EFI" > "$efi_dir/EFI/BOOT/BOOTX64.EFI"
exit 0
EOF
        chmod +x "$mockbin/grub2-install"
        ln -sf "$mockbin/grub2-install" "$mockbin/grub-install"
        export PATH="$mockbin:$PATH"

        # Virtuellen USB-Stick als Image anlegen.
        dd if=/dev/zero of="$work/usb.img" bs=1M count=6144 status=none

        # In manchen Container-Umgebungen fehlen /dev/loop* Nodes.
        modprobe loop >/dev/null 2>&1 || true
        [[ -e /dev/loop-control ]] || mknod /dev/loop-control c 10 237 || true
        for i in $(seq 0 15); do
            [[ -e "/dev/loop${i}" ]] || mknod "/dev/loop${i}" b 7 "$i" || true
        done

        LOOP_DEV=$(losetup --show -f "$work/usb.img")

        cleanup() {
            set +e
            umount /mnt/fedora-usb >/dev/null 2>&1 || true
            losetup -d "$LOOP_DEV" >/dev/null 2>&1 || true
        }
        trap cleanup EXIT

        # Installationslauf inkl. RPM-Build auf das virtuelle Device.
        printf "j\n" | /src/install.sh "$LOOP_DEV"

        # Ergebnis pruefen: Datenpartition mounten und Kernartefakte verifizieren.
        part_suffix="2"
        if [[ "$LOOP_DEV" =~ nvme|mmcblk ]]; then
            part_suffix="p2"
        fi
        DATA_PART="${LOOP_DEV}${part_suffix}"

        mkdir -p /mnt/fedora-usb
        mount "$DATA_PART" /mnt/fedora-usb

        test -f /mnt/fedora-usb/boot/vmlinuz
        test -f /mnt/fedora-usb/boot/initrd.img
        test -f /mnt/fedora-usb/kickstart/fedora-full.ks
        ls /mnt/fedora-usb/rpm/*.rpm >/dev/null
        test -d /mnt/fedora-usb/rpm/repodata

        echo "[podman-e2e] PASS"
    '
