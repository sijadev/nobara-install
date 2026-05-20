"""XML-Konfiguration lesen und schreiben."""
from __future__ import annotations
import xml.etree.ElementTree as ET
from pathlib import Path

from .models import PackageResult, PackageSource


def _get(root: ET.Element, path: str, default: str = "") -> str:
    el = root.find(path)
    return (el.text or "").strip() if el is not None else default


def _set(root: ET.Element, path: str, value: str) -> None:
    """Setzt ein Element, erstellt es falls nötig."""
    parts = path.split("/")
    node = root
    for part in parts[:-1]:
        child = node.find(part)
        if child is None:
            child = ET.SubElement(node, part)
        node = child
    leaf = node.find(parts[-1])
    if leaf is None:
        leaf = ET.SubElement(node, parts[-1])
    leaf.text = value


def load_config(path: Path) -> ET.Element:
    return ET.parse(str(path)).getroot()


def save_config(root: ET.Element, path: Path) -> None:
    ET.indent(root, space="  ")
    tree = ET.ElementTree(root)
    tree.write(str(path), encoding="unicode", xml_declaration=False)


def get_all_names(root: ET.Element) -> set[str]:
    """Alle konfigurierten Paketnamen (DNF + Flatpak + COPR + Extensions) als Set."""
    names: set[str] = set()
    names.update(get_packages(root))
    names.update(get_flatpaks(root))
    names.update(get_coprs(root))
    names.update(get_extensions(root))
    return names


def remove_package(root: ET.Element, name: str) -> bool:
    """Entfernt ein Paket aus allen Sektionen. Gibt True zurück wenn gefunden."""
    removed = False
    for section_tag, item_tag in [
        ("packages",                         "package"),
        ("packages",                         "copr"),
        ("first-login/flatpaks",             "app"),
        ("first-login/gnome-extensions",     "extension"),
    ]:
        section = root.find(section_tag)
        if section is None:
            continue
        for el in list(section.findall(item_tag)):
            if (el.text or "").strip() == name:
                section.remove(el)
                removed = True
    return removed


def get_packages(root: ET.Element) -> list[str]:
    return [el.text.strip() for el in root.findall("packages/package") if el.text]


def get_groups(root: ET.Element) -> list[str]:
    return [el.text.strip() for el in root.findall("packages/group") if el.text]


def get_coprs(root: ET.Element) -> list[str]:
    return [el.text.strip() for el in root.findall("packages/copr") if el.text]


def get_flatpaks(root: ET.Element) -> list[str]:
    return [el.text.strip() for el in root.findall("first-login/flatpaks/app") if el.text]


def get_theme_config(root: ET.Element) -> dict:
    """WhiteSur Theme-Konfiguration."""
    ws = root.find("first-login/whitesur")
    if ws is None:
        return {}
    enabled = ws.get("enabled", "true").lower() != "false"
    return {
        "enabled":       enabled,
        "gtk_args":      (_get(ws, "gtk-args") or "Standard"),
        "icon_args":     (_get(ws, "icon-args") or "Standard"),
        "wallpaper_args":(_get(ws, "wallpaper-args") or "—"),
    }


def get_ohmybash_config(root: ET.Element) -> dict:
    """Oh My Bash Konfiguration."""
    omb = root.find("first-login/ohmybash")
    if omb is None:
        return {}
    return {
        "enabled": omb.get("enabled", "true").lower() != "false",
        "theme":   omb.get("theme", "modern"),
    }


def get_extensions(root: ET.Element) -> list[str]:
    """GNOME Shell Extensions aus first-login/gnome-extensions/extension."""
    return [el.text.strip() for el in root.findall("first-login/gnome-extensions/extension") if el.text]


def add_extension(root: ET.Element, ext_id: str) -> bool:
    """Fügt eine GNOME Extension hinzu."""
    fl = root.find("first-login")
    if fl is None:
        fl = ET.SubElement(root, "first-login")
    exts_node = fl.find("gnome-extensions")
    if exts_node is None:
        exts_node = ET.SubElement(fl, "gnome-extensions")
        exts_node.set("enabled", "true")
    existing = [el.text for el in exts_node.findall("extension")]
    if ext_id in existing:
        return False
    el = ET.SubElement(exts_node, "extension")
    el.text = ext_id
    return True


def add_dnf_package(root: ET.Element, name: str) -> bool:
    pkgs = root.find("packages")
    if pkgs is None:
        pkgs = ET.SubElement(root, "packages")
    existing = [el.text for el in pkgs.findall("package")]
    if name in existing:
        return False
    el = ET.SubElement(pkgs, "package")
    el.text = name
    return True


def add_flatpak(root: ET.Element, app_id: str) -> bool:
    fl = root.find("first-login/flatpaks")
    if fl is None:
        first_login = root.find("first-login")
        if first_login is None:
            first_login = ET.SubElement(root, "first-login")
        fl = ET.SubElement(first_login, "flatpaks")
    existing = [el.text for el in fl.findall("app")]
    if app_id in existing:
        return False
    el = ET.SubElement(fl, "app")
    el.text = app_id
    return True


def add_copr(root: ET.Element, repo: str) -> bool:
    pkgs = root.find("packages")
    if pkgs is None:
        pkgs = ET.SubElement(root, "packages")
    existing = [el.text for el in pkgs.findall("copr")]
    if repo in existing:
        return False
    el = ET.SubElement(pkgs, "copr")
    el.text = repo
    return True


def add_package_result(root: ET.Element, pkg: PackageResult) -> bool:
    if pkg.source == PackageSource.FLATPAK:
        return add_flatpak(root, pkg.name)
    elif pkg.source == PackageSource.COPR:
        return add_copr(root, pkg.name)
    else:
        return add_dnf_package(root, pkg.name)
