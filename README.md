# fedora-autoinstall

Vollautomatisches Unattended-Install-Framework für **Fedora Linux** mit interaktivem CLI-Konfigurator.  
Anaconda-Kickstart + Provisioning-RPM werden direkt in die Fedora-Netinstall-ISO eingebettet — einmal `dd` auf den USB-Stick, fertig.

---

## CLI-Konfigurator — Hauptfeature

Das mitgelieferte `fedora-autoinstall` CLI-Tool ermöglicht visuelle Konfiguration ohne XML-Kenntnisse.  
Es durchsucht **DNF-Repos, Flathub und COPR gleichzeitig** und zeigt Kategorien, Beschreibungen und bereits hinzugefügte Pakete.

### Installation

```bash
git clone https://github.com/sijadev/fedora-autoinstall.git
cd fedora-autoinstall
make install                  # Python venv + Abhängigkeiten
pip install -e cli/           # CLI installieren
```

### Pakete suchen

```bash
fedora-autoinstall search "obs studio"
```

```
Suche 'obs studio'...
┌──┬─┬─────────┬──────────────┬─────────────────────────────────────┬────────────────────┐
│  │#│ Quelle  │  Kategorie   │ Name                                │ Beschreibung       │
├──┼─┼─────────┼──────────────┼─────────────────────────────────────┼────────────────────┤
│  │1│  dnf    │  Anwendung   │ obs-studio                          │ Free, open source… │
│  │2│ flatpak │  Audio/Video │ com.obsproject.Studio               │ Live streaming and…│
│  │3│  copr   │ Community-P… │ nicholasstephan/obs-studio-stable   │ OBS Studio stable  │
└──┴─┴─────────┴──────────────┴─────────────────────────────────────┴────────────────────┘
```

Quellen: **DNF** (Fedora-Repos) · **Flatpak** (Flathub) · **COPR** (Community)  
Kategorien: Anwendung · Bibliothek · Entwicklung · Plugin/Addon · System/Treiber · Audio/Video · Schriftart · Extension · Spiel · Werkzeug

### Paket hinzufügen (interaktiv)

```bash
fedora-autoinstall add "bitwig"
```

```
Suche 'bitwig'...
┌──┬─┬─────────┬──────────────┬────────────────────────┬──────────────────────────────┐
│✓ │1│  copr   │ Community-P… │ flacks/bitwig-studio   │ Bitwig Studio (flacks)       │
│  │2│ flatpak │  Audio/Video │ com.bitwig.BitwigStudio│ Professional DAW             │
└──┴─┴─────────┴──────────────┴────────────────────────┴──────────────────────────────┘

Nummer auswählen (oder q zum Abbrechen) [1]:
```

- **✓** markiert bereits hinzugefügte Pakete
- Beim erneuten Auswählen eines ✓-Pakets: Entfernen-Bestätigung
- Unterstützt DNF-Pakete, Flatpak-Apps und COPR-Repos

### Alle konfigurierten Pakete anzeigen

```bash
fedora-autoinstall list
```

```
Konfiguration: example.xml

Pakete (9)
  DNF-Pakete (7)
    • git
    • curl
    • python3  ...
  GNOME Extensions (3)
    • user-theme@gnome-shell-extensions.gcampax.github.com
    • dash-to-dock@micxgx.gmail.com
    • blur-my-shell@aunetx

Theme & Shell
  WhiteSur aktiv
    GTK:       -c Dark
    Icons:     -dark
    Wallpaper: —
  Oh My Bash aktiv  Theme: modern
```

### Paket entfernen

```bash
fedora-autoinstall remove obs-studio
# oder via add (toggle): nochmals auswählen → Entfernen-Bestätigung
```

### ISO bauen

```bash
fedora-autoinstall build        # Kickstart generieren + ISO bauen
fedora-autoinstall write /dev/diskN  # ISO auf USB schreiben
```

### Projektstatus

```bash
fedora-autoinstall status
```

```
Config:    ✓ config/example.xml
Kickstart: ✓ kickstart/fedora-full.ks
ISO:       ✓ fedora-autoinstall-x86_64-43-1.6.iso (1118 MB)
RPM:       ✓ fedora-autoinstall-1.0-1.fc43.noarch.rpm
```

### Alle CLI-Befehle

| Befehl | Beschreibung |
|---|---|
| `search <query>` | Pakete in DNF + Flathub + COPR suchen |
| `add <query>` | Suchen, auswählen und zur Config hinzufügen (Toggle) |
| `list` | Alle konfigurierten Pakete + Theme anzeigen |
| `remove <name>` | Paket aus der Config entfernen |
| `build` | Kickstart generieren + ISO bauen |
| `write <device>` | ISO auf USB schreiben |
| `status` | Projektstatus anzeigen |

---

## Workflow (Makefile)

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
| Python 3.11+ | für CLI und Tests |
| UEFI-Zielsystem | erforderlich (Legacy-BIOS nicht unterstützt) |
| USB-Stick | ≥ 2 GB, wird komplett überschrieben |

**Fedora-Netinstall-ISO** (einmalig herunterladen und nach `iso/` legen):  
→ https://fedoraproject.org/everything/download

---

## Projektstruktur

```
fedora-autoinstall/
│
├── cli/                           # Python CLI-Paket
│   ├── fedora_autoinstall/
│   │   ├── main.py                # CLI-Befehle (search, add, list, ...)
│   │   ├── search.py              # Paketsuche: DNF + Flathub + COPR
│   │   ├── config.py              # XML-Config lesen/schreiben
│   │   └── models.py              # Datenmodelle + Kategorie-Erkennung
│   ├── tests/
│   │   └── test_search.py         # 32 Unit-Tests
│   └── pyproject.toml
│
├── config/
│   ├── example.xml                # Referenz-Konfiguration
│   └── schema.xsd                 # XML-Schema
│
├── kickstart/
│   ├── fedora-full.ks             # Vollinstallation (aus XML generiert)
│   ├── fedora-headless-vllm.ks
│   ├── fedora-theme-bash.ks
│   └── fedora-vm.ks               # VM Smoke-Test
│
├── lib/
│   └── xml2ks.py                  # XML → Kickstart Konverter
│
├── rpm/
│   ├── fedora-autoinstall.spec
│   └── repodata/
│
├── scripts/
│   ├── first-boot.sh              # Systemweite Provisionierung (root)
│   ├── first-login.sh             # User-Provisionierung
│   ├── welcome-dialog.sh          # GNOME Profil-Auswahl-Dialog
│   ├── fedora-provision.sh        # Profil nachträglich anwenden
│   └── music-analyzer.py          # MIDI/MP3-Analyse mit Qwen3 + Qwen2.5-Omni
│
├── tools/
│   ├── build-rpm.sh               # RPM bauen (Podman)
│   ├── build-iso.sh               # ISO patchen (mkksiso + EFI-Fix)
│   └── patch_iso.py               # EFI-FAT-Partition patchen
│
└── tests/
    ├── test_xml2ks.py
    ├── test_kickstart_validator.py
    ├── test_anaconda_vm.py         # VM E2E Smoke-Test (QEMU)
    └── test_systemd_units.py
```

---

## Was in der ISO steckt

`make build-iso` nutzt `mkksiso` um aus der Fedora-Netinstall-ISO eine angepasste ISO zu erzeugen:

```
Fedora-Everything-netinst-x86_64-43.iso
    + kickstart/fedora-full.ks  → eingebettet (automatisch geladen beim Boot)
    + rpm/                      → eingebettet als lokales DNF-Repo
    + GRUB: inst.ks=... inst.addrepo=... set default="0"
    + EFI-FAT-Partition gepatcht (inst.ks auch für UEFI-Boot)
    = fedora-autoinstall-x86_64-43.iso
```

---

## Boot-Ablauf

```
USB-Stick (ISO) → UEFI → GRUB → Anaconda
    │
    ├─ inst.ks=hd:LABEL=...:/fedora-full.ks   (Kickstart eingebettet)
    ├─ inst.addrepo=...,file:///run/install/repo/rpm
    │
    ├─ %pre:      Ziel-Disk automatisch erkennen (NVMe/SATA/BIOS+GPT)
    ├─ Btrfs:     EFI + /boot + @ + @home Subvolumes
    ├─ %packages: fedora-autoinstall RPM aus lokalem Repo
    └─ %post:     provision.env + GNOME-Autostart schreiben
```

Nach der Installation: System bootet → `fedora-first-boot.service` läuft → GNOME startet.

---

## Erster Boot (root, automatisch)

`fedora-first-boot.service` führt `scripts/first-boot.sh` aus:

1. DNF-Optimierungen + System-Update
2. CachyOS-Kernel (BORE-Scheduler)
3. NVIDIA Open Driver + CUDA
4. Podman + NVIDIA Container Toolkit + vLLM Quadlet
5. CPU-Tuning: `tuned`, `scx_bpfland`, `sysctl`, Hugepages
6. WhiteSur GRUB-Theme
7. Timeshift + btrfs-assistant
8. zram, irqbalance, ananicy-cpp
9. AMD Ryzen P-State

### CPU-Profile

| Profil | Tuned | Governor | Aktivierung |
|---|---|---|---|
| Default | `throughput-performance` | `schedutil` | systemd-Service |
| Bitwig | `latency-performance` | `performance` | automatisch bei Start |

---

## Erster Login (User, automatisch)

`scripts/first-login.sh` führt aus:

1. Flathub + Extension Manager
2. GNOME Extensions (Dash-to-Dock, Blur-my-Shell, Caffeine, AppIndicator)
3. WhiteSur GTK/Icons/Wallpaper/Cursor
4. Oh My Bash
5. Bitwig Studio (Flatpak) + Audio-optimierter Launcher

---

## Konfiguration

Kickstart **nicht manuell editieren** — über CLI oder XML:

```bash
# Via CLI (empfohlen)
fedora-autoinstall add "neovim"
fedora-autoinstall add "com.obsproject.Studio"

# Via XML direkt
python3 lib/xml2ks.py --config config/example.xml --output kickstart/fedora-full.ks
```

### Passwort-Hash erzeugen

```bash
openssl passwd -6 meinPasswort
# → in config/example.xml unter <user/password_hash> eintragen
```

---

## Tests

```bash
make test           # Unit-Tests (xml2ks, Kickstart, CLI-Suche, systemd)
make vm-gui-iso     # VM Smoke-Test — vollständige Installation in QEMU
```

---

## Troubleshooting

### Graphischer Installer ohne Kickstart

**Ursache:** ISO nicht korrekt auf USB geschrieben (EFI-FAT nicht gepatcht).  
**Fix:** `make write-iso DEVICE=/dev/diskN` erneut ausführen.  
macOS: Terminal braucht **Full Disk Access** (Systemeinstellungen → Datenschutz).

### `[!] Softwareauswahl` in Anaconda

**Fix:** `make build-iso` → RPM und Repodata werden aktualisiert.

### Disk nicht erkannt

**Fix:** Im GRUB-Menü `e` → `linux`-Zeile: `inst.disk=nvme0n1` anhängen.

### NVIDIA — Kernel Panic nach erstem Boot

`first-boot.sh` fällt automatisch auf Fedora-Standardkernel zurück.  
Manuell: `sudo akmods --force && sudo dracut --regenerate-all --force`

---

## Unterstützte Hardware

| Komponente | Details |
|---|---|
| CPU | AMD Ryzen (optimiert) oder Intel |
| GPU | NVIDIA Turing (RTX 20xx)+ inkl. Blackwell (RTX 50xx) |
| Boot | UEFI |
| Dateisystem | Btrfs mit `@` / `@home` Subvolumes |
