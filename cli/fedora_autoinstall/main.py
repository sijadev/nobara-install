"""fedora-autoinstall CLI — Paket-Suche + ISO-Build."""
from __future__ import annotations
import subprocess
import sys
from pathlib import Path
from typing import Optional

import typer
from rich import print as rprint
from rich.console import Console
from rich.table import Table
from rich.prompt import Prompt, Confirm

from .models import PackageSource
from .search import search_all_sync
from . import config as cfg

app     = typer.Typer(help="Fedora unattended install configurator", add_completion=False)
console = Console()

# Projekt-Wurzel: zwei Ebenen über diesem Paket
_PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
_DEFAULT_CONFIG = _PROJECT_ROOT / "config" / "example.xml"


def _resolve_config(config_path: Optional[Path]) -> Path:
    path = config_path or _DEFAULT_CONFIG
    if not path.exists():
        console.print(f"[red]Config nicht gefunden: {path}[/red]")
        raise typer.Exit(1)
    return path


# ── search ───────────────────────────────────────────────────────────────────

_CAT_COLORS = {
    "Anwendung":      "bright_white",
    "Audio/Video":    "yellow",
    "Audio":          "yellow",
    "Video":          "yellow",
    "Entwicklung":    "cyan",
    "Bibliothek":     "dim",
    "Schriftart":     "dim",
    "Extension":      "bright_cyan",
    "Plugin/Addon":   "bright_cyan",
    "System/Treiber": "red",
    "System/Kernel":  "red",
    "Spiel":          "bright_green",
    "Werkzeug":       "white",
    "Grafik":         "bright_yellow",
    "Büro":           "white",
}
_SRC_COLORS = {
    PackageSource.DNF:     "green",
    PackageSource.FLATPAK: "blue",
    PackageSource.COPR:    "magenta",
}


@app.command()
def search(
    query:  str            = typer.Argument(..., help="Suchbegriff"),
    config: Optional[Path] = typer.Option(None, "--config", "-c"),
):
    """Sucht Pakete in DNF, Flathub und COPR. Bereits hinzugefügte werden markiert."""
    config_path = _resolve_config(config)
    root        = cfg.load_config(config_path)
    already     = cfg.get_all_names(root)

    console.print(f"\n[bold cyan]Suche '[yellow]{query}[/yellow]'...[/bold cyan]")
    with console.status("Durchsuche DNF + Flathub + COPR..."):
        results = search_all_sync(query)

    if not results:
        console.print("[yellow]Keine Ergebnisse gefunden.[/yellow]")
        return

    table = Table(show_header=True, header_style="bold", expand=True)
    table.add_column("",           width=2)           # ✓ Marker
    table.add_column("#",          width=3,  style="dim")
    table.add_column("Quelle",     width=8)
    table.add_column("Kategorie",  width=14)
    table.add_column("Name",       width=33)
    table.add_column("Anzeige",    width=20)
    table.add_column("Beschreibung")

    for i, pkg in enumerate(results, 1):
        added  = pkg.name in already
        marker = "[green]✓[/green]" if added else ""
        color  = _SRC_COLORS.get(pkg.source, "white")
        ccolor = _CAT_COLORS.get(pkg.category, "white")
        name   = f"[dim]{pkg.name}[/dim]" if added else f"[bold]{pkg.name}[/bold]"
        table.add_row(
            marker,
            str(i),
            f"[{color}]{pkg.source.value}[/{color}]",
            f"[{ccolor}]{pkg.category}[/{ccolor}]",
            name,
            pkg.display,
            pkg.description[:65] + ("…" if len(pkg.description) > 65 else ""),
        )

    console.print(table)
    added_count = sum(1 for r in results if r.name in already)
    console.print(
        f"\n[dim]{len(results)} Ergebnis(se)"
        + (f" · [green]{added_count} bereits in Config[/green]" if added_count else "")
        + "[/dim]"
    )


# ── add ──────────────────────────────────────────────────────────────────────

@app.command()
def add(
    query:  str          = typer.Argument(..., help="Paketname oder Suchbegriff"),
    config: Optional[Path] = typer.Option(None, "--config", "-c", help="XML-Config Pfad"),
    yes:    bool         = typer.Option(False, "--yes", "-y", help="Erstes Ergebnis ohne Nachfrage hinzufügen"),
):
    """Sucht ein Paket und fügt es zur Config hinzu."""
    config_path = _resolve_config(config)
    root = cfg.load_config(config_path)

    console.print(f"\n[bold cyan]Suche '[yellow]{query}[/yellow]'...[/bold cyan]")
    with console.status("Suche läuft..."):
        results = search_all_sync(query)

    if not results:
        console.print("[yellow]Keine Ergebnisse. Paket direkt hinzufügen?[/yellow]")
        if Confirm.ask(f"'{query}' als DNF-Paket hinzufügen?"):
            from .models import PackageResult, PackageSource
            pkg = PackageResult(source=PackageSource.DNF, name=query, display=query)
            _add_and_save(root, pkg, config_path)
        return

    # Auswahl anzeigen
    already = cfg.get_all_names(root)

    table = Table(show_header=True, header_style="bold")
    table.add_column("",          width=2)
    table.add_column("#",         width=3)
    table.add_column("Quelle",    width=8)
    table.add_column("Kategorie", width=14)
    table.add_column("Name",      width=36)
    table.add_column("Beschreibung")

    for i, pkg in enumerate(results, 1):
        added  = pkg.name in already
        marker = "[green]✓[/green]" if added else ""
        color  = _SRC_COLORS.get(pkg.source, "white")
        name   = f"[dim]{pkg.name}[/dim]" if added else f"[bold]{pkg.name}[/bold]"
        table.add_row(
            marker,
            str(i),
            f"[{color}]{pkg.source.value}[/{color}]",
            pkg.category,
            name,
            pkg.description[:55],
        )

    console.print(table)

    if yes:
        chosen = results[0]
    else:
        choice = Prompt.ask(
            "\nNummer auswählen (oder [bold]q[/bold] zum Abbrechen)",
            default="1",
        )
        if choice.lower() == "q":
            raise typer.Exit(0)
        try:
            idx = int(choice) - 1
            chosen = results[idx]
        except (ValueError, IndexError):
            console.print("[red]Ungültige Auswahl.[/red]")
            raise typer.Exit(1)

    _add_and_save(root, chosen, config_path)


def _add_and_save(root, pkg, config_path: Path) -> None:
    """Fügt hinzu — oder entfernt wenn bereits vorhanden (Toggle)."""
    already = cfg.get_all_names(root)
    source_label = {
        PackageSource.DNF:     "DNF-Paket",
        PackageSource.FLATPAK: "Flatpak",
        PackageSource.COPR:    "COPR-Repo",
    }.get(pkg.source, "Paket")

    if pkg.name in already:
        if Confirm.ask(f"\n[yellow]⚠[/yellow] [bold]{pkg.name}[/bold] ist bereits in der Config. Entfernen?"):
            cfg.remove_package(root, pkg.name)
            cfg.save_config(root, config_path)
            console.print(f"[red]✗[/red] {source_label} [bold]{pkg.name}[/bold] entfernt.")
    else:
        cfg.add_package_result(root, pkg)
        cfg.save_config(root, config_path)
        console.print(f"\n[green]✓[/green] {source_label} [bold]{pkg.name}[/bold] hinzugefügt → {config_path.name}")


# ── list ─────────────────────────────────────────────────────────────────────

@app.command(name="list")
def list_packages(
    config: Optional[Path] = typer.Option(None, "--config", "-c"),
):
    """Zeigt alle konfigurierten Pakete."""
    config_path = _resolve_config(config)
    root = cfg.load_config(config_path)

    packages   = cfg.get_packages(root)
    flatpaks   = cfg.get_flatpaks(root)
    coprs      = cfg.get_coprs(root)
    groups     = cfg.get_groups(root)
    extensions = cfg.get_extensions(root)
    theme      = cfg.get_theme_config(root)
    omb        = cfg.get_ohmybash_config(root)

    total = len(packages) + len(flatpaks) + len(coprs) + len(groups) + len(extensions)
    console.print(f"\n[bold]Konfiguration: {config_path.name}[/bold]\n")

    # ── Pakete ────────────────────────────────────────────────────────────────
    pkg_sections = [
        (packages,   "green",   "DNF-Pakete",       lambda p: p),
        (flatpaks,   "blue",    "Flatpak",           lambda p: p),
        (coprs,      "magenta", "COPR-Repos",        lambda p: p),
        (groups,     "cyan",    "Paket-Gruppen",     lambda p: f"@{p}"),
        (extensions, "yellow",  "GNOME Extensions",  lambda p: p),
    ]
    console.print(f"[bold]Pakete[/bold] [dim]({total})[/dim]")
    has_pkgs = False
    for items, color, label, fmt in pkg_sections:
        if items:
            console.print(f"  [{color}]{label} ({len(items)})[/{color}]")
            for item in items:
                console.print(f"    [dim]•[/dim] {fmt(item)}")
            has_pkgs = True
    if not has_pkgs:
        console.print("  [dim]keine[/dim]")

    # ── Theme ─────────────────────────────────────────────────────────────────
    console.print()
    console.print("[bold]Theme & Shell[/bold]")
    if theme:
        status = "[green]aktiv[/green]" if theme["enabled"] else "[dim]deaktiviert[/dim]"
        console.print(f"  [bright_white]WhiteSur[/bright_white] {status}")
        console.print(f"    GTK:       {theme['gtk_args']}")
        console.print(f"    Icons:     {theme['icon_args']}")
        console.print(f"    Wallpaper: {theme['wallpaper_args']}")
    else:
        console.print("  [dim]WhiteSur: nicht konfiguriert[/dim]")

    if omb:
        status = "[green]aktiv[/green]" if omb["enabled"] else "[dim]deaktiviert[/dim]"
        console.print(f"  [bright_white]Oh My Bash[/bright_white] {status}  Theme: [yellow]{omb['theme']}[/yellow]")
    else:
        console.print("  [dim]Oh My Bash: nicht konfiguriert[/dim]")


# ── remove ───────────────────────────────────────────────────────────────────

@app.command()
def remove(
    name:   str          = typer.Argument(..., help="Paketname"),
    config: Optional[Path] = typer.Option(None, "--config", "-c"),
):
    """Entfernt ein Paket aus der Config."""
    config_path = _resolve_config(config)
    root = cfg.load_config(config_path)

    removed = cfg.remove_package(root, name)
    if removed:
        cfg.save_config(root, config_path)
        console.print(f"[red]✗[/red] [bold]{name}[/bold] entfernt.")
    else:
        all_names = cfg.get_all_names(root)
        console.print(f"[yellow]'{name}' nicht in Config gefunden.[/yellow]")
        if all_names:
            console.print(f"[dim]Konfiguriert: {', '.join(sorted(all_names)[:5])}...[/dim]")


# ── build ────────────────────────────────────────────────────────────────────

@app.command()
def build(
    config: Optional[Path] = typer.Option(None, "--config", "-c"),
):
    """Generiert Kickstart aus Config und baut die ISO."""
    config_path = _resolve_config(config)
    root_dir = _PROJECT_ROOT

    console.print("\n[bold cyan]1/2 Kickstart generieren...[/bold cyan]")
    ks_out = root_dir / "kickstart" / "fedora-full.ks"
    result = subprocess.run(
        [sys.executable, str(root_dir / "lib" / "xml2ks.py"),
         "--config", str(config_path), "--output", str(ks_out)],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        console.print(f"[red]Kickstart-Fehler:[/red]\n{result.stderr}")
        raise typer.Exit(1)
    console.print(f"[green]✓[/green] {ks_out.name}")

    console.print("\n[bold cyan]2/2 ISO bauen (Podman)...[/bold cyan]")
    result = subprocess.run(
        ["bash", str(root_dir / "tools" / "build-iso.sh")],
        cwd=str(root_dir),
    )
    if result.returncode != 0:
        console.print("[red]ISO-Build fehlgeschlagen.[/red]")
        raise typer.Exit(1)

    isos = sorted((root_dir / "iso").glob("fedora-autoinstall-*.iso"))
    if isos:
        console.print(f"\n[green bold]✓ ISO fertig:[/green bold] {isos[-1].name}")


# ── write ────────────────────────────────────────────────────────────────────

@app.command()
def write(
    device: str = typer.Argument(..., help="USB-Device (z.B. /dev/disk4 oder /dev/sdX)"),
):
    """Schreibt die ISO auf einen USB-Stick."""
    isos = sorted((_PROJECT_ROOT / "iso").glob("fedora-autoinstall-*.iso"))
    if not isos:
        console.print("[red]Kein ISO gefunden — zuerst: fedora-autoinstall build[/red]")
        raise typer.Exit(1)

    iso = isos[-1]
    console.print(f"\nISO:    [bold]{iso.name}[/bold]")
    console.print(f"Device: [bold]{device}[/bold]")

    if not Confirm.ask("\n[red]USB-Stick wird komplett überschrieben![/red] Fortfahren?"):
        raise typer.Exit(0)

    result = subprocess.run(
        ["make", "write-iso", f"DEVICE={device}"],
        cwd=str(_PROJECT_ROOT),
    )
    if result.returncode == 0:
        console.print("\n[green bold]✓ USB-Stick fertig.[/green bold]")
    else:
        console.print("[red]Schreiben fehlgeschlagen.[/red]")
        raise typer.Exit(1)


# ── status ───────────────────────────────────────────────────────────────────

@app.command()
def status():
    """Zeigt den aktuellen Projekt-Status."""
    root = _PROJECT_ROOT
    console.print("\n[bold]fedora-autoinstall Status[/bold]\n")

    # Config
    cfg_file = root / "config" / "example.xml"
    console.print(f"Config:    {'[green]✓[/green]' if cfg_file.exists() else '[red]✗[/red]'} {cfg_file}")

    # Kickstart
    ks_file = root / "kickstart" / "fedora-full.ks"
    console.print(f"Kickstart: {'[green]✓[/green]' if ks_file.exists() else '[yellow]—[/yellow]'} {ks_file}")

    # ISO
    isos = sorted((root / "iso").glob("fedora-autoinstall-*.iso"))
    if isos:
        import os
        size = os.path.getsize(isos[-1]) // (1024*1024)
        console.print(f"ISO:       [green]✓[/green] {isos[-1].name} ({size} MB)")
    else:
        console.print("ISO:       [yellow]—[/yellow] nicht gebaut")

    # RPM
    rpms = list((root / "rpm").glob("*.rpm"))
    console.print(f"RPM:       {'[green]✓[/green]' if rpms else '[yellow]—[/yellow]'} "
                  f"{rpms[0].name if rpms else 'nicht gebaut'}")
