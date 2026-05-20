"""Data models für Pakete und Suchergebnisse."""
from __future__ import annotations
from enum import Enum
from pydantic import BaseModel


class PackageSource(str, Enum):
    DNF      = "dnf"
    FLATPAK  = "flatpak"
    COPR     = "copr"


def _infer_category_dnf(name: str, description: str = "") -> str:
    """Ermittelt Kategorie eines DNF-Pakets anhand des Namens."""
    n = name.lower()
    d = description.lower()
    if n.startswith(("lib", "python3-", "python-", "perl-", "ruby-",
                     "php-", "nodejs-", "golang-", "java-")):
        return "Bibliothek"
    if n.endswith(("-devel", "-dev", "-headers", "-static")):
        return "Entwicklung"
    if "font" in n or "font" in d:
        return "Schriftart"
    if "gnome-shell-extension" in n or "kde-" in n:
        return "Extension"
    if any(x in n for x in ("-plugin", "-codec", "-module")):
        return "Plugin/Addon"
    if any(x in n for x in ("kernel", "firmware", "driver", "kmod")):
        return "System/Treiber"
    if any(x in d for x in ("game", "spiel")):
        return "Spiel"
    if any(x in n for x in ("-cli", "-tools", "-utils", "-util")):
        return "Werkzeug"
    return "Anwendung"


def _infer_category_copr(name: str, description: str = "") -> str:
    d = description.lower()
    if any(x in d for x in ("kernel", "driver", "firmware")):
        return "System/Kernel"
    if any(x in d for x in ("game", "spiel")):
        return "Spiel"
    return "Community-Paket"


# Flatpak-Kategorien von Flathub auf Deutsch mappen
_FLATPAK_CAT_MAP: dict[str, str] = {
    "AudioVideo":    "Audio/Video",
    "Audio":         "Audio",
    "Video":         "Video",
    "Development":   "Entwicklung",
    "Education":     "Bildung",
    "Game":          "Spiel",
    "Graphics":      "Grafik",
    "Network":       "Netzwerk",
    "Office":        "Büro",
    "Science":       "Wissenschaft",
    "System":        "System",
    "Utility":       "Werkzeug",
    "IDE":           "Entwicklung",
    "TextEditor":    "Editor",
    "WebBrowser":    "Browser",
    "Emulator":      "Emulator",
}


class PackageResult(BaseModel):
    source:      PackageSource
    name:        str
    display:     str
    description: str = ""
    version:     str = ""
    url:         str = ""
    category:    str = ""     # App / Bibliothek / Plugin / System / etc.

    def model_post_init(self, __context) -> None:
        if not self.category:
            if self.source == PackageSource.DNF:
                self.category = _infer_category_dnf(self.name, self.description)
            elif self.source == PackageSource.COPR:
                self.category = _infer_category_copr(self.name, self.description)

    @property
    def install_name(self) -> str:
        return self.name
