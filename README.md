# fedora-autoinstall

Vollautomatisches Unattended-Install-Framework für **Fedora Linux**.  
Anaconda-Kickstart + Provisioning-RPM werden direkt in die Fedora-Netinstall-ISO eingebettet — einmal `dd` auf den USB-Stick, fertig.

---

## Workflow

```
make build-iso          → ISO bauen  (RPM + Kickstart eingebettet)
make write-iso DEVICE=… → auf USB-Stick schreiben
                        → Stick einstecken → UEFI → Anaconda startet automatisch
```

---

## Voraussetzungen

| Was | Bedingung |
|---|---|
| Host-Betriebssystem | macOS oder Linux |
| Podman | für RPM- und ISO-Build im Container |
| Python 3 + venv | für Tests und VM-Test |
| UEFI-Zielsystem | erforderlich (Legacy-BIOS nicht unterstützt) |
| USB-Stick | ≥ 2 GB, wird komplett überschrieben |

**Fedora-Netinstall-ISO** (einmalig herunterladen und nach `iso/` legen):  
→ https://fedoraproject.org/everything/download

---

## Schnellstart

```bash
git clone https://github.com/sijadev/fedora-autoinstall.git
cd fedora-autoinstall

# Python-Umgebung
make install

# ISO bauen (baut RPM automatisch mit)
make build-iso

# USB-Stick beschreiben (macOS: /dev/diskN, Linux: /dev/sdX)
make write-iso DEVICE=/dev/diskN
```

USB-Stick einstecken → UEFI bootet → Anaconda startet direkt mit eingebettetem Kickstart.

---

## Projektstruktur

```
fedora-autoinstall/
│
├── config/
│   ├── example.xml            # Referenz-Konfiguration (Disk, User, Hostname ...)
│   └── schema.xsd             # XML-Schema
│
├── kickstart/
│   ├── fedora-full.ks         # Vollinstallation (generiert aus XML)
│   ├── fedora-headless-vllm.ks# Headless-Profil (kein GUI)
│   ├── fedora-theme-bash.ks   # GNOME + WhiteSur
│   ├── fedora-vm.ks           # VM Smoke-Test (minimale Installation)
│   └── common-post.inc        # Gemeinsamer %post-Block
│
├── lib/
│   └── xml2ks.py              # XML → Kickstart Konverter + Validator
│
├── rpm/
│   ├── fedora-autoinstall.spec
│   ├── fedora-autoinstall-*.noarch.rpm
│   └── repodata/
│
├── scripts/                   # Wird via RPM auf Zielsystem installiert
│   ├── first-boot.sh          # Systemweite Provisionierung (root, einmalig)
│   ├── first-login.sh         # User-Provisionierung (einmalig)
│   └── welcome-dialog.sh
│
├── systemd/
│   ├── fedora-first-boot.service
│   ├── vllm@.container
│   └── vllm-router.service
│
├── tools/
│   ├── build-rpm.sh           # RPM bauen (Podman)
│   ├── build-iso.sh           # ISO patchen (mkksiso + RPM einbetten)
│   └── podman_rpm_pipeline.sh # CI-Pipeline für RPM-Validierung
│
├── tests/
│   ├── run-all.sh
│   ├── test_xml2ks.py
│   ├── test_kickstart_validator.py
│   ├── test_apply_config.py
│   ├── test_anaconda_vm_usb.py# VM E2E Smoke-Test (QEMU, macOS)
│   └── test_systemd_units.py
│
└── iso/
    └── Fedora-Everything-netinst-*.iso  # manuell ablegen
```

---

## Make-Targets

| Target | Beschreibung |
|---|---|
| `make build-rpm` | `fedora-autoinstall` RPM bauen (Podman/Fedora:43) |
| `make build-iso` | ISO patchen — Kickstart + RPM einbetten |
| `make write-iso DEVICE=…` | ISO per `dd` auf USB-Stick schreiben |
| `make vm-gui-iso` | VM-Test mit gepatchter ISO (QEMU, macOS) |
| `make vm-gui-virtual` | VM-Test mit virtuellem USB (Fallback) |
| `make test` | Unit-Tests |
| `make install` | Python venv + Runtime-Abhängigkeiten |
| `make clean` | venv entfernen |

---

## Was in der ISO steckt

`make build-iso` nutzt `mkksiso` um aus der Fedora-Netinstall-ISO eine angepasste ISO zu erzeugen:

```
Fedora-Everything-netinst-x86_64-43.iso
    + kickstart/fedora-full.ks  → eingebettet als fedora-full.ks
    + rpm/                      → eingebettet als rpm/ (lokales DNF-Repo)
    + GRUB: inst.ks=... inst.addrepo=... set default="0"
    = fedora-autoinstall-x86_64-43.iso
```

Beim Boot wählt GRUB direkt "Install Fedora 43" (kein Media-Check, kein Menü-Timeout).

---

## Boot-Ablauf

```
USB-Stick (ISO) → UEFI → GRUB → Anaconda
    │
    ├─ inst.ks=hd:LABEL=...:/fedora-full.ks   (Kickstart eingebettet)
    ├─ inst.addrepo=...,file:///run/install/repo/rpm  (lokales RPM-Repo)
    │
    ├─ %pre:     Ziel-Disk automatisch erkennen (NVMe/SATA/BIOS+GPT)
    ├─ Btrfs:    EFI + /boot + @ + @home Subvolumes
    ├─ %packages: fedora-autoinstall RPM aus lokalem Repo
    └─ %post:    provision.env + GNOME-Autostart schreiben
```

Nach der Installation: System bootet → `fedora-first-boot.service` läuft einmalig.

---

## Erster Boot (root, automatisch)

`fedora-first-boot.service` führt `scripts/first-boot.sh` aus:

1. DNF-Optimierungen (`max_parallel_downloads=10`, `fastestmirror`)
2. RPM Fusion + System-Update
3. CachyOS-Kernel (BORE-Scheduler, optional `FEDORA_KERNEL_SOURCE=fedora`)
4. NVIDIA Open Driver + CUDA (`nvidia-cuda` Profil)
5. Podman + NVIDIA Container Toolkit
6. CPU-Tuning: `tuned`, `scx_bpfland`, `sysctl`, Hugepages
7. WhiteSur GRUB-Theme
8. Timeshift + grub-btrfs
9. zram, irqbalance, ananicy-cpp
10. AMD Ryzen P-State

### CPU-Profile

| Profil | Tuned | Governor | Aktivierung |
|---|---|---|---|
| Default (Boot) | `throughput-performance` | `schedutil` | systemd-Service |
| Bitwig (DAW) | `latency-performance` | `performance` | automatisch bei Bitwig-Start |

---

## Erster Login (User, automatisch)

`scripts/first-login.sh` führt aus:

1. Flathub + Extension Manager
2. GNOME Extensions (Dash-to-Dock, Blur-my-Shell, Caffeine, AppIndicator)
3. WhiteSur GTK/Icons/Wallpaper/Cursor
4. Oh My Bash
5. Bitwig Studio (Flatpak) + Audio-optimierter Launcher
6. vLLM Quadlet-Konfiguration

---

## Konfiguration

Kickstart-Dateien **nicht manuell editieren** — aus XML generieren:

```bash
python3 lib/xml2ks.py --config config/example.xml --output kickstart/fedora-full.ks
```

Danach `make build-iso` ausführen damit die neue Kickstart-Version in die ISO eingebettet wird.

### Passwort-Hash erzeugen

```bash
openssl passwd -6 meinPasswort
# → in config/example.xml unter <user/password_hash> eintragen
```

---

## Tests

```bash
# Unit-Tests (xml2ks, Kickstart, apply_config, systemd)
make test

# VM Smoke-Test — Anaconda startet und installiert aus ISO
make vm-gui-iso
```

Der VM-Test bootet QEMU mit `-kernel`/`-initrd` direkt, liest den Kickstart aus der gepatchten ISO und verifiziert die vollständige Installation (Partitionierung, RPM-Install, dracut, %post).

---

## Troubleshooting

### Graphischer Installer startet ohne Kickstart

**Ursache:** ISO auf USB mit `dd` geschrieben, aber alter Bootcode oder abgelaufener Media-Check stört.  
**Fix:** USB-Stick mit `diskutil unmountDisk` aushängen, dann neu mit `make write-iso` beschreiben.

### `[!] Softwareauswahl` in Anaconda

`fedora-autoinstall` RPM nicht gefunden. `rpm/repodata/` fehlt oder ist veraltet.  
**Fix:** `make build-iso` neu ausführen — RPM und Repodata werden dabei aktualisiert.

### Disk nicht erkannt (`DISK`-Variable leer)

Bei `inst.disk=` fehlt: `%pre` erkennt Disk automatisch via `lsblk`.  
**Fix (GRUB-Menü `e`):** An `linux`-Zeile anhängen: `inst.disk=nvme0n1`

### NVIDIA — Kernel Panic nach erstem Boot

**Ursache:** `akmods` scheiterte, CachyOS-Kernel bootet ohne NVIDIA-Modul.  
**Fix:** `first-boot.sh` erkennt das automatisch und fällt auf Fedora-Standardkernel zurück.  
Danach: `sudo akmods --force && sudo dracut --regenerate-all --force`

---

## Unterstützte Hardware

| Komponente | Details |
|---|---|
| CPU | AMD Ryzen (optimiert) oder Intel |
| GPU | NVIDIA Turing (RTX 20xx) oder neuer inkl. Blackwell (RTX 50xx) |
| Boot | UEFI (kein Legacy-BIOS) |
| Dateisystem | Btrfs mit `@` / `@home` Subvolumes |
