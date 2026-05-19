# fedora-autoinstall - beta

Vollautomatisches Unattended-Install-Framework für **Fedora Linux** — eigener GRUB2-Bootloader + Bazzite-Kernel auf USB-Stick, kein Ventoy.

Beim Booten erscheint direkt das GRUB2-Menü mit Hotkeys — der Rest läuft ohne Eingriff durch.

---

## Systemvoraussetzungen

### Host-System für USB-Erstellung

| Was | Version / Bedingung |
|---|---|
| Host-System | Fedora Linux oder macOS (Intel/Apple Silicon) |
| USB-Stick | >= 8 GB, wird komplett neu formatiert |
| UEFI-Zielsystem | erforderlich (Legacy-BIOS wird nicht unterstützt) |
| Root-Rechte | sudo für Build/Install-Skripte |

### OS-Abhängigkeiten (USB-Build)

| Betriebssystem | Benötigte Tools |
|---|---|
| Fedora Linux | `sudo dnf install gdisk dosfstools grub2-efi-x64 grub2-tools cpio file curl python3` |
| macOS | `brew install grub python cpio file-formula curl` (plus systemweit `diskutil`, `hdiutil`) |

### Python-Umgebung (Projekt/Tests)

| Betriebssystem | Benötigt |
|---|---|
| macOS | Python 3 mit `venv` |
| Linux | Python 3 mit `venv` |

> **Ziel-Hardware:** UEFI-System mit NVIDIA GPU (Turing RTX 20xx oder neuer), AMD Ryzen CPU empfohlen.  
> Legacy-BIOS wird nicht unterstützt.

---

## Projektstruktur

```
fedora-autoinstall/

├── fedora-iso-build.sh        # Custom-ISO bauen (für dd-Flash ohne USB-Boot)
│
├── boot/
│   └── grub.cfg               # GRUB2-Menü (4 Profile: f/d/t/h)
│
├── config/
│   ├── example.xml            # Referenz-Konfiguration
│   └── schema.xsd             # XML-Schema (Validierung)
│
├── kickstart/
│   ├── fedora-full.ks         # Vollinstallation (GNOME + NVIDIA)
│   ├── fedora-theme-bash.ks   # GNOME + WhiteSur
│   ├── fedora-headless-vllm.ks# Headless-Profil (kein GUI)
│   ├── fedora-vm.ks           # VM Smoke-Test (minimale Installation)
│   └── common-post.inc        # Gemeinsamer %post-Block
│
├── lib/
│   ├── common.sh              # Logging, dry-run, Safety-Checks
│   └── xml2ks.py              # XML → Kickstart Konverter + Validator
│
├── rpm/
│   ├── fedora-autoinstall.spec# RPM-Spec für Provisioning-Scripts
│   ├── fedora-autoinstall-*.noarch.rpm  # Gebautes Paket
│   └── repodata/              # createrepo-Metadaten (lokales DNF-Repo)
│
├── scripts/                   # Wird auf Zielsystem installiert (via RPM)
│   ├── first-boot.sh          # Systemweite Provisionierung (root, einmalig)
│   ├── first-login.sh         # User-Provisionierung (einmalig)
│   ├── welcome-dialog.sh      # GNOME Welcome-Dialog
│   └── fedora-provision.desktop # GNOME App-Menü Eintrag
│
├── tools/                     # Entwickler- und Build-Werkzeuge (Dev-Rechner)
│   ├── build-usb.sh           # USB-Stick einmalig aufbauen (GRUB2 + Bazzite-Kernel)
│   ├── sync-usb.sh            # Repo → USB synchronisieren
│   ├── apply_config.py        # XML-Config auf Kickstart-Dateien anwenden
│   └── podman-run.sh          # Interaktiver Container-Start
│
├── systemd/
│   └── fedora-first-boot.service
│
├── tests/
│   ├── run-all.sh             # Test-Runner (Standard + Full + E2E)
│   ├── test_kickstart_validator.py
│   ├── test_xml2ks.py
│   └── test_anaconda_vm_usb.py# VM E2E Smoke-Test (macOS QEMU / Linux libvirt)
│
└── iso/
    ├── kernel-cache/          # Bazzite-Kernel-RPM-Cache (kein Re-Download)
    └── Fedora-Everything-netinst-*.iso  # Source-ISO (manuell ablegen)
```

---

## Schnellstart

### Empfohlener Workflow (genau)

1. Repository vorbereiten:

```bash
git clone https://github.com/sijadev/fedora-autoinstall.git
cd fedora-autoinstall
```

2. Python-Umgebung anlegen und Abhängigkeiten installieren:

```bash
# Nur Laufzeitpakete
make install

# Optional für Entwicklung/Tests
make install-dev
```

3. Konfiguration prüfen/anpassen:

```bash
# XML-Standardkonfiguration
cat config/example.xml

# Optional: JSON-Konfiguration für apply_config.py
cat config/install.json
```

4. Optional Tests ausführen (vor USB-Schreiben empfohlen):

```bash
bash tests/run-all.sh --full
```

5. Optional: RPM manuell bauen (Debug/Entwicklung):

```bash
# Lokaler Build (Fedora):
# rpmbuild -bb --define "_sourcedir ." rpm/fedora-autoinstall.spec

# Alternativ auf macOS per Podman/Fedora-Container bauen
# Ergebnis: rpm/fedora-autoinstall-*.noarch.rpm

# Repo-Metadaten aktualisieren
createrepo rpm/
```

Hinweis: `install.sh` erledigt RPM-Build + Repo-Metadaten inzwischen automatisch.

6. USB-Stick vollständig erstellen (empfohlen):

```bash
sudo ./install.sh /dev/sdX
# macOS: sudo ./install.sh /dev/diskN
```

7. Danach inkrementelle Updates auf bestehendem Stick:

```bash
tools/sync-usb.sh --check
tools/sync-usb.sh
```

8. Optional: Podman-E2E mit virtuellem USB-Stick:

```bash
python3 tests/test_podman_e2e_usb.py --run
# oder im Gesamtlauf:
bash tests/run-all.sh --e2e
```

### 1. USB-Stick einmalig aufbauen

```bash
# Source-ISO nach iso/ legen (einmalig):
# https://fedoraproject.org/everything/download  →  iso/

# USB-Stick aufbauen (formatiert, installiert GRUB2 + Bazzite-Kernel):
sudo tools/build-usb.sh /dev/sdX
```

Was `build-usb.sh` macht:
- GPT: Part 1 = EFI (256 MB FAT32), Part 2 = FEDORA-USB (Rest FAT32)
- GRUB2 EFI (`BOOTX64.EFI`) + `boot/grub.cfg` installieren
- Bazzite-Kernel von COPR laden (RPM-Cache in `iso/kernel-cache/`)
- Anaconda-initrd mit Bazzite-Modulen neu packen
- Kickstart, Scripts, Systemd-Units auf USB kopieren
- RPM-Repo (`rpm/`) auf USB kopieren

Bazzite-Kernel-RPMs werden in `iso/kernel-cache/` gecacht — kein Re-Download beim nächsten Mal.

### 2. USB-Stick aktuell halten

```bash
# Prüfen ob Stick aktuell ist:
tools/sync-usb.sh --check

# Synchronisieren (interaktiv mit Diff):
tools/sync-usb.sh

# Ohne Rückfrage:
tools/sync-usb.sh --force
```

> **Kernel-Update:** `build-usb.sh` erneut ausführen — `sync-usb.sh` aktualisiert nur Scripts/Kickstart/Config, nicht den Kernel.

### 3. Profil wählen und installieren

USB einstecken → UEFI Boot → GRUB2-Menü → Hotkey drücken:

| Taste | Profil | Was passiert |
|-------|--------|-------------|
| `f` | Vollinstallation | Anaconda → `fedora-full.ks` (GNOME + NVIDIA + vLLM) |
| `g` | GUI-Vollinstallation | Wie `f`, aber graphischer Modus + Serial-Log |
| `d` | Debug-Install | Text-Modus + Serial-Log (ttyS0,115200) |
| `s` | Debug Live Shell | Anaconda-Shell ohne Installation (`inst.rescue`) |
| `m` | VM-Test | Anaconda → `fedora-vm.ks` (minimale VM-Installation) |
| `1` | Minimal Args | Ohne NVIDIA/Multipath (Kompatibilitäts-Test) |

Stage2 (Anaconda-Installer) wird live vom Fedora Mirror geladen — keine ISO auf dem USB-Stick nötig.

### 4. Provisioner auf laufendem System

```bash
# Theme + WhiteSur + Oh-My-Bash
sudo bash /run/media/$USER/FEDORA-USB/fedora-provision.sh --profile theme-bash

# Headless-Profil, kein GUI
sudo bash /run/media/$USER/FEDORA-USB/fedora-provision.sh --profile headless-vllm
```

---

## Alternative: Custom-ISO (ohne USB-Boot)

Für `dd`-Flash direkt auf USB oder SD-Karte — kein GRUB2-Setup nötig:

```bash
sudo dnf install lorax xorriso cpio zstd

# Standard-ISO mit Kickstart (full-Profil)
sudo ./fedora-iso-build.sh --profile full

# Mit Bazzite-Kernel-Swap für Blackwell (RTX 50/9070)
sudo ./fedora-iso-build.sh --profile full --swap-kernel

# Direkt auf USB-Stick schreiben
sudo ./fedora-iso-build.sh --profile full --swap-kernel --write /dev/sdX
```

Ergebnis: `iso/Fedora-Auto-full.iso` — booten startet Anaconda automatisch mit eingebettetem Kickstart.

---

## NVIDIA Blackwell (RTX 50 / 9070)

Der **Bazzite-Kernel** im USB-Boot bringt nativen sm_120-Support — der iGPU-Workaround aus alten Ventoy-Anleitungen ist **nicht mehr nötig**.

Einfach [f] drücken und abwarten.

### Diagnose: Schwarzer Bildschirm

Falls Anaconda nach dem Boot schweigt: **mindestens 90 Sekunden warten** — stage2 wird live vom Netzwerk geladen.

Falls weiterhin schwarz, **TTY-Switch** versuchen:

| Tastenkombi | Inhalt |
|---|---|
| `Ctrl+Alt+F1` | Anaconda-UI (Hauptkonsole) |
| `Ctrl+Alt+F2` | Root-Shell — `dmesg`, `journalctl -xb` |
| `Ctrl+Alt+F3` | `anaconda.log` |
| `Ctrl+Alt+F4` | Storage-Log |
| `Ctrl+Alt+F5` | Programm-Log |

Für tiefere Diagnose: **[d] Debug-Install** — Serial-Log landet auf dem USB-Stick unter `logs/`.

---

## Profile im Detail

### `full` — Vollinstallation (USB-Boot)
Frische Neuinstallation auf leerem System. Btrfs, GNOME Desktop, NVIDIA Open Driver, CUDA, WhiteSur-Theme, Oh-My-Bash.

### `theme-bash` — Theme + Bash (Provisioner)
WhiteSur GTK/Icon/Wallpaper/Cursor-Themes, Dash-to-Dock, Blur-my-Shell, Oh-My-Bash.

---

## Dateisystem: Btrfs

Alle Profile nutzen **Btrfs** mit Ubuntu-kompatiblem Subvolume-Layout:

| Subvolume | Mountpoint | Zweck |
|-----------|-----------|-------|
| `@` | `/` | Root — Timeshift-Snapshots |
| `@home` | `/home` | Home-Verzeichnis |

Mount-Optionen: `compress=zstd:1,noatime`  
Kein Swap-Partition — **zram-generator** übernimmt (50% RAM, zstd-Kompression).

### Timeshift + GRUB-Snapshots

Beim ersten Boot werden automatisch eingerichtet:
- **Timeshift** (btrfs-Modus) — monatliche Snapshots + Boot-Snapshot
- **grub-btrfs** — Snapshots erscheinen im GRUB-Auswahlmenü

---

## System-Optimierungen

### Performance (first-boot.sh)

| Bereich | Was |
|---------|-----|
| **DNF** | `max_parallel_downloads=10`, `fastestmirror`, `deltarpm` |
| **Kernel/Sysctl** | `vm.swappiness=10`, `vfs_cache_pressure=50`, `net.core.somaxconn=1024` |
| **Hugepages** | `madvise` via tmpfiles.d |
| **CPU** | `tuned throughput-performance` + `schedutil` Governor |
| **scx_bpfland** | Cache-aware Scheduler für AMD Ryzen CCDs (COPR bieszczaders) |
| **NVIDIA** | Persistence Mode als systemd-Service |
| **zram** | 50% RAM, zstd — ersetzt Swap-Partition |
| **irqbalance** | IRQ-Verteilung auf alle CPU-Kerne |
| **ananicy-cpp** | Prozess-Priorisierung (COPR eriknguyen) |
| **AMD Ryzen** | P-State EPP=performance, `amd_pstate=active`, `amd_iommu=on` im GRUB |
| **fstrim** | Wöchentlicher SSD TRIM |

### GNOME (first-login.sh)

| Bereich | Was |
|---------|-----|
| **Theme** | WhiteSur GTK/Icons/Wallpaper/Cursor (macOS-Stil) |
| **Dock** | Dash-to-Dock: unten, autohide, Apps-Button links |
| **Extensions** | blur-my-shell, caffeine, AppIndicator, user-theme |
| **Schrift** | `font-antialiasing=rgba`, `font-hinting=slight` |
| **Night Light** | 20:00–07:00, 3500K |
| **GRUB Theme** | WhiteSur (passend zum Desktop) |

---

## Tests

```bash
# Standard-Testlauf (stabil, inkl. systemd Unit-Tests)
make test

# Verbose
make run-all-verbose

# Voller Lauf (inkl. Python + Kickstart-Validator)
make run-all-full
```

### VM Smoke-Test (macOS / Linux)

Bootet den Fedora-Installer-Kernel direkt in QEMU, liest `fedora-vm.ks` vom USB-Stick
und prüft ob Anaconda startet — kein GRUB, kein EFI-Binary nötig.

```bash
# USB-Stick eingesteckt lassen, Gerätepfad angeben:
make vm-gui DEVICE=/dev/diskN        # macOS
make vm-gui DEVICE=/dev/sdX          # Linux
```

Was passiert:
1. `boot/vmlinuz` + `boot/initrd.img` werden vom gemounteten USB ins Temp-Dir kopiert
2. USB wird ausgehängt (`diskutil unmountDisk`)
3. QEMU startet mit `-kernel`/`-initrd` (direkter Kernel-Boot, kein OVMF)
4. Anaconda bootet mit `fedora-vm.ks` → minimale Installation auf virtuellem Zieldisk
5. Fenster bleibt offen bis Installation abgeschlossen oder `Ctrl+C`

> **Hinweis macOS/Apple Silicon:** QEMU emuliert x86\_64 via TCG (kein HVF).
> Der Stage2-Download dauert 10–15 Minuten — das ist normal.

---

## Boot-Ablauf

```
FEDORA-USB (GRUB2 + Bazzite-Kernel)
  └─ GRUB2-Menü (boot/grub.cfg)
       └─ Anaconda — stage2 vom Fedora Mirror (Netzwerk)
            ├─ %pre: Disk automatisch erkennen
            ├─ Btrfs partitionieren (@ + @home Subvolumes)
            ├─ %packages: fedora-autoinstall RPM vom lokalen USB-Repo
            └─ %post: provision.env + GNOME-Autostart
```

### Erster Boot (root, einmalig)

`fedora-first-boot.service` führt aus:
1. System-Update
2. NVIDIA Open Driver + akmods
3. CUDA (Fedora-Repo oder NVIDIA-Repo)
4. Kernel-Tuning: sysctl, hugepages, tuned, scx_bpfland
5. NVIDIA Persistence Mode
6. WhiteSur GRUB Theme
7. Timeshift + grub-btrfs
8. zram, irqbalance, ananicy-cpp
9. AMD Ryzen P-State + GRUB-Parameter

### Erster Login (User, einmalig)

`fedora-first-login.sh` führt aus:
1. Flathub + Flatpak Extension Manager
2. GNOME Extensions (dash-to-dock, blur-my-shell, caffeine, appindicator)
3. WhiteSur Themes + Dash-to-Dock Konfiguration
4. GNOME Tweaks + Night Light
5. Oh My Bash

---

## Disk-Erkennung

Alle Profile erkennen die Ziel-Disk automatisch:

```bash
DISK=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1; exit}')
```

Funktioniert für SATA (`sda`) und NVMe (`nvme0n1`).

Override: Im GRUB `e` drücken, an die `linux`-Zeile anhängen:
```
inst.disk=nvme1n1
```

---

## XML-Konfiguration

Die Kickstart-Dateien werden **nicht manuell editiert** — immer über `lib/xml2ks.py` aus `config/example.xml` generieren:

```bash
python3 lib/xml2ks.py --config config/example.xml --output kickstart/fedora-full.ks
```

### Wichtige XML-Felder

| Element | Beschreibung | Beispiel |
|---|---|---|
| `<local-repo>` | `baseurl` für das lokale RPM-Repo auf dem USB-Stick | `file:///run/install/repo/rpm` |
| `<disk>` | Ziel-Disk (wird automatisch erkannt wenn `<partitioning><scheme>auto</scheme>`) | `/dev/nvme0n1` |
| `<user/password_hash>` | crypt-Hash (`openssl passwd -6 Passwort`) | `$6$...` |
| `<first-boot/kernel source="">` | Kernel nach Installation: `cachyos` oder `fedora` | `cachyos` |

### RPM-Repo Pfad (`<local-repo>`)

Anaconda mountet den USB-Stick (Quelle von `inst.ks=hd:LABEL=FEDORA-USB`) unter `/run/install/repo`.
Das `rpm/`-Verzeichnis auf dem Stick ist damit als `file:///run/install/repo/rpm` erreichbar.

```xml
<local-repo>file:///run/install/repo/rpm</local-repo>
```

Das `rpm/`-Verzeichnis muss auf dem Stick vorhanden sein und gültige `repodata/` enthalten:

```bash
# RPM bauen (auf Fedora):
rpmbuild -bb --define "_sourcedir ." rpm/fedora-autoinstall.spec

# Repo-Metadaten erzeugen:
createrepo rpm/

# Auf USB synchronisieren:
tools/sync-usb.sh
```

---

## Troubleshooting

### `[!] Softwareauswahl` — Warnung in Anaconda

Das `fedora-autoinstall` Paket kann nicht gefunden werden. Ursache: `rpm/`-Verzeichnis fehlt auf dem USB-Stick oder enthält kein gültiges Repo.

**Fix:**
```bash
# Prüfen ob rpm/ auf dem Stick vorhanden ist:
ls /run/media/$USER/FEDORA-USB/rpm/

# Fehlt es, USB neu synchronisieren:
tools/sync-usb.sh
```

### PC schaltet sich während `initqueue` aus

Tritt auf bevor Anaconda startet — dracut enumeriert Hardware. Typische Ursache: PCIe-AER-Interaktion mit NVIDIA Blackwell / neuem AMD Chipsatz.

**Diagnose:** Im GRUB `[e]` drücken, an die `linux`-Zeile anhängen:

```
pci=nommconf pci=nomsi
```

Weitere Kandidaten:

| Symptom | Kernel-Arg |
|---|---|
| Shutdown exakt nach ~30 s | `rd.retry=60` (USB-Label wird nicht rechtzeitig erkannt) |
| NVMe-Enumeration triggert Shutdown | `nvme_core.default_ps_max_latency_us=0` |
| AMD ACPI-Problem | `amd_iommu=off` |

Für detaillierten Log: **`[d]` Debug-Install** booten — Serial-Output landet auf `ttyS0,115200`.

---

## Hinweise

- **NVIDIA-Treiber:** Wird erst beim ersten Boot via `akmod-nvidia-open` gebaut — nicht während der Installation.
- **UEFI erforderlich:** Legacy-BIOS/MBR nicht unterstützt.
- **Passwort-Hash:** `openssl passwd -6 meinPasswort` — in `config/example.xml` unter `<user/password_hash>` eintragen.
- **Kernel-Cache:** `iso/kernel-cache/` — Bazzite-RPMs werden gecacht, kein Re-Download bei `build-usb.sh`.
- **Kickstart nie manuell editieren** — immer `lib/xml2ks.py` verwenden, sonst gehen Änderungen beim nächsten Generieren verloren.

