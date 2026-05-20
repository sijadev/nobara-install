#!/usr/bin/env python3
"""Patcht die Fedora-ISO: EFI-FAT grub.cfg via mtools + default=0."""
import os, struct, subprocess, sys

iso = sys.argv[1]

# 1. default="1" -> default="0" im ganzen ISO
with open(iso, "r+b") as fh:
    data = fh.read()
    count = data.count(b'set default="1"')
    fh.seek(0)
    fh.write(data.replace(b'set default="1"', b'set default="0"'))
print(f"[build-iso] default=0: {count}x ersetzt.")

# 2. EFI-FAT-Partition finden (GPT)
with open(iso, "rb") as fh:
    fh.seek(512)
    gpt = fh.read(92)
    if gpt[:8] != b"EFI PART":
        print("[build-iso] WARN: Kein GPT"); sys.exit(0)
    pl  = struct.unpack_from("<Q", gpt, 72)[0]
    np2 = struct.unpack_from("<I", gpt, 80)[0]
    ps  = struct.unpack_from("<I", gpt, 84)[0]
    fh.seek(pl * 512)
    efi_lba = efi_end = 0
    for _ in range(np2):
        ent = fh.read(ps)
        if len(ent) < 128:
            break
        s   = struct.unpack_from("<Q", ent, 32)[0]
        end = struct.unpack_from("<Q", ent, 40)[0]
        if s and 10 < (end - s + 1) * 512 / 1024 / 1024 < 20:
            efi_lba, efi_end = s, end
            break
    if not efi_lba:
        print("[build-iso] WARN: EFI-Partition nicht gefunden"); sys.exit(0)
    fh.seek(efi_lba * 512)
    efi_bytes = fh.read((efi_end - efi_lba + 1) * 512)

efi_img = "/tmp/efi_part.img"
with open(efi_img, "wb") as fh:
    fh.write(efi_bytes)
print(f"[build-iso] EFI extrahiert: LBA {efi_lba}, {len(efi_bytes)//1024} KB")

# 3. grub.cfg aus ISO-9660 extrahieren
os.makedirs("/tmp/efi_patch/EFI/BOOT", exist_ok=True)
subprocess.run(
    ["bsdtar", "-xf", iso, "-C", "/tmp/efi_patch", "EFI/BOOT/grub.cfg"],
    capture_output=True
)

# 4. mtools: grub.cfg in FAT einschreiben (aktualisiert Dateigröße korrekt)
os.environ["MTOOLS_SKIP_CHECK"] = "1"
r = subprocess.run(
    ["mcopy", "-o", "-i", efi_img,
     "/tmp/efi_patch/EFI/BOOT/grub.cfg", "::/EFI/BOOT/grub.cfg"],
    capture_output=True
)
if r.returncode != 0:
    print(f"[build-iso] WARN: mcopy fehlgeschlagen: {r.stderr.decode()[:100]}")
    sys.exit(0)

# 5. EFI-Partition zurückschreiben
with open(efi_img, "rb") as fh:
    new_efi = fh.read()
with open(iso, "r+b") as fh:
    fh.seek(efi_lba * 512)
    fh.write(new_efi)

# 6. Verifizieren
with open(iso, "rb") as fh:
    fh.seek(efi_lba * 512)
    check = fh.read((efi_end - efi_lba + 1) * 512)
ok_ks      = b"inst.ks" in check
ok_addrepo = b"inst.addrepo" in check
ok_default = b'set default="0"' in check
print(f"[build-iso] EFI-FAT: inst.ks={'OK' if ok_ks else 'FEHLT'} "
      f"inst.addrepo={'OK' if ok_addrepo else 'FEHLT'} "
      f"default=0={'OK' if ok_default else 'FEHLT'}")
if not (ok_ks and ok_addrepo and ok_default):
    sys.exit(1)
