#!/usr/bin/env bash
set -euo pipefail

dnf -y install \
    gdisk dosfstools \
    cpio file xz zstd curl python3 python3-pip \
    rpm-build createrepo_c pykickstart \
    util-linux e2fsprogs xorriso rsync openssl >/dev/null

cd /src

create_target_user_from_xml() {
    local xml_path="${FEDORA_CONFIG_XML:-/src/config/example.xml}"
    local username="sija"
    local groups="wheel,video,audio"
    local gecos="sija"
    local pw_hash=""

    if [[ -f "$xml_path" ]]; then
        local parsed
        parsed="$(python3 - "$xml_path" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
root = ET.parse(xml_path).getroot()

def get(path, default=""):
    el = root.find(path)
    if el is None or el.text is None:
        return default
    return el.text.strip()

print(get("user/name", "sija"))
print(get("user/groups", "wheel,video,audio"))
print(get("user/gecos", get("user/name", "sija")))
print(get("user/password_hash", ""))
PY
)"
        username="$(printf '%s' "$parsed" | sed -n '1p')"
        groups="$(printf '%s' "$parsed" | sed -n '2p')"
        gecos="$(printf '%s' "$parsed" | sed -n '3p')"
        pw_hash="$(printf '%s' "$parsed" | sed -n '4p')"
    else
        echo "[podman-e2e][WARN] XML nicht gefunden: $xml_path (Fallback auf Standard-User)"
    fi

    IFS=',' read -r -a group_arr <<<"$groups"
    for grp in "${group_arr[@]}"; do
        grp="${grp// /}"
        [[ -z "$grp" ]] && continue
        getent group "$grp" >/dev/null 2>&1 || groupadd "$grp" >/dev/null 2>&1 || true
    done

    if id -u "$username" >/dev/null 2>&1; then
        usermod -c "$gecos" -G "$groups" "$username" >/dev/null 2>&1 || true
    else
        useradd -m -s /bin/bash -c "$gecos" -G "$groups" "$username" >/dev/null 2>&1 || true
    fi

    if [[ -n "$pw_hash" ]]; then
        usermod -p "$pw_hash" "$username" >/dev/null 2>&1 || true
    fi

    export FEDORA_TARGET_USER="$username"
    export USER="$username"
    export SUDO_USER="$username"
    echo "[podman-e2e] Zieluser im Container: ${username} (groups: ${groups})"
}

create_target_user_from_xml

# Kleine Test-ISO mit den benoetigten Pfaden erstellen.
work=/tmp/e2e-usb
mkdir -p "$work/iso/images/pxeboot"
dd if=/dev/zero of="$work/iso/images/pxeboot/vmlinuz" bs=1K count=64 status=none
dd if=/dev/zero of="$work/iso/images/pxeboot/initrd.img" bs=1K count=256 status=none
xorriso -as mkisofs -R -J -o "$work/Fedora-Everything-netinst-x86_64-43-1.6.iso" "$work/iso" >/dev/null 2>&1

mkdir -p /src/iso
cp "$work/Fedora-Everything-netinst-x86_64-43-1.6.iso" /src/iso/

# grub2-install scheitert in Containern oft auf overlayfs.
# Fuer den E2E-Test mocken wir nur diesen Schritt und pruefen den Rest des Flows.
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
mkdir -p /src/logs
INSTALL_LOG="/src/logs/podman-e2e-install.log"

cleanup() {
    set +e
    umount /mnt/fedora-usb >/dev/null 2>&1 || true
    losetup -d "$LOOP_DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Installationslauf inkl. RPM-Build auf das virtuelle Device.
set +e
printf "j\n" | /src/install.sh "$LOOP_DEV" 2>&1 | tee "$INSTALL_LOG"
install_rc=${PIPESTATUS[1]}
set -e

status=0
if [[ "$install_rc" -ne 0 ]]; then
    echo "[podman-e2e][FAIL] install.sh ist mit Exit-Code ${install_rc} fehlgeschlagen."
    status=1
fi

# Ergebnis pruefen: Datenpartition mounten und Kernartefakte verifizieren.
part_suffix="2"
if [[ "$LOOP_DEV" =~ nvme|mmcblk|loop ]]; then
    part_suffix="p2"
fi
DATA_PART="${LOOP_DEV}${part_suffix}"

mounted=0
mkdir -p /mnt/fedora-usb
if [[ -b "$DATA_PART" ]]; then
    if mount "$DATA_PART" /mnt/fedora-usb; then
        mounted=1
    else
        echo "[podman-e2e][WARN] Datenpartition konnte nicht gemountet werden: $DATA_PART"
        status=1
    fi
else
    echo "[podman-e2e][WARN] Datenpartition nicht gefunden: $DATA_PART"
    status=1
fi

check_artifact() {
    local path="$1"
    if [[ -e "$path" ]]; then
        echo "[podman-e2e][OK] Artefakt vorhanden: $path"
    else
        echo "[podman-e2e][FAIL] Artefakt fehlt: $path"
        status=1
    fi
}

scan_log_patterns() {
    local src="$1"
    local name="$2"
    local copy_dest="/src/logs/${name}"

    if [[ -f "$src" ]]; then
        if [[ "$src" != "$copy_dest" ]]; then
            cp "$src" "$copy_dest"
        fi
    elif [[ -f "$copy_dest" ]]; then
        :
    else
        echo "[podman-e2e][WARN] Datei nicht gefunden: $name"
        return 0
    fi

    if grep -Ei '\[ERROR\]|\[FAIL\]|\[FATAL\]|\[EXCEPTION\]|\b(error|failed|fatal|exception)\b' "$copy_dest" >/dev/null; then
        echo "[podman-e2e][FAIL] Fehlerhafte Eintraege in $name"
        grep -Ein '\[ERROR\]|\[FAIL\]|\[FATAL\]|\[EXCEPTION\]|\b(error|failed|fatal|exception)\b' "$copy_dest" || true
        status=1
    elif grep -Ei '\[WARN\]|\bwarning\b' "$copy_dest" >/dev/null; then
        echo "[podman-e2e][WARN] Warnungen in $name"
        grep -Ein '\[WARN\]|\bwarning\b' "$copy_dest" || true
    else
        echo "[podman-e2e][OK] Keine Warnungen/Fehler in $name"
    fi
}

if [[ "$mounted" -eq 1 ]]; then
    check_artifact /mnt/fedora-usb/boot/vmlinuz
    check_artifact /mnt/fedora-usb/boot/initrd.img
    check_artifact /mnt/fedora-usb/kickstart/fedora-full.ks
    if ls /mnt/fedora-usb/rpm/*.rpm >/dev/null 2>&1; then
        echo "[podman-e2e][OK] RPM-Artefakte vorhanden"
    else
        echo "[podman-e2e][FAIL] Keine RPM-Artefakte auf dem USB gefunden"
        status=1
    fi
    check_artifact /mnt/fedora-usb/rpm/repodata

    # Wichtige Marker/Logs vom gemounteten USB pruefen.
    scan_log_patterns /mnt/fedora-usb/var/log/fedora-first-boot.log fedora-first-boot.log
    scan_log_patterns /mnt/fedora-usb/var/lib/fedora-provision/first-boot.done first-boot.done
    scan_log_patterns /mnt/fedora-usb/var/log/fedora-provision.log fedora-provision.log
    scan_log_patterns /mnt/fedora-usb/var/lib/fedora-provision/provision.done provision.done
fi

# Installationslog wird immer geprueft, auch bei fruehem Fehler.
scan_log_patterns "$INSTALL_LOG" podman-e2e-install.log

if [[ "$status" -eq 0 ]]; then
    echo "[podman-e2e][LOGCHECK] Alle Pruefungen OK."
else
    echo "[podman-e2e][LOGCHECK] Es wurden Probleme gefunden. Siehe Auswertung oben und Dateien unter /src/logs/."
fi

# RPM-Pipeline-Test auf gemountetem USB ausfuehren
if [[ "$status" -eq 0 ]] && [ -f /src/tools/podman_rpm_pipeline.sh ]; then
    bash /src/tools/podman_rpm_pipeline.sh
elif [[ "$status" -eq 0 ]]; then
    echo "[WARN] podman_rpm_pipeline.sh nicht gefunden!"
fi

if [[ "$status" -eq 0 ]]; then
    echo "[podman-e2e] PASS"
else
    echo "[podman-e2e] FAIL"
fi

exit "$status"
