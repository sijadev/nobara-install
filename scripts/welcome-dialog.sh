#!/usr/bin/env bash
# welcome-dialog.sh — GNOME Welcome-Dialog für Fedora-Autoinstall
#
# Wird beim ersten GUI-Login automatisch gestartet (Autostart).
# Bietet die Wahl zwischen den Post-Install-Profilen an.
# Kann auch jederzeit manuell via Apps-Menü "Fedora Provisioner" gestartet werden.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVISION_SCRIPT="/usr/local/sbin/fedora-provision.sh"
AUTOSTART_FILE="$HOME/.config/autostart/fedora-welcome.desktop"
DONE_MARKER="$HOME/.local/share/fedora-provision/welcome.done"

# zenity vorhanden?
if ! command -v zenity &>/dev/null; then
    notify-send "Fedora Provisioner" "zenity nicht installiert — bitte 'sudo dnf install zenity' ausführen." 2>/dev/null || true
    exit 1
fi

# Auswahl
CHOICE=$(zenity --list \
    --title="Willkommen bei Fedora" \
    --width=560 --height=380 \
    --text="<b>Welches Profil möchten Sie einrichten?</b>\n\n<small>Die Auswahl startet sofort die Provisionierung in einem Terminal.\nSie können diesen Dialog jederzeit über das App-Menü erneut öffnen.</small>" \
    --radiolist \
    --column="" --column="Profil" --column="Beschreibung" \
    TRUE  "full"           "Empfohlen: Theme-Bash + Bitwig (Flatpak mit Audio-Launcher) + Headless-vLLM auf dem Host" \
    FALSE "theme-bash"     "Nur Host: WhiteSur Theme + Oh-My-Bash + Bitwig (Flatpak mit Audio-Launcher)" \
    FALSE "headless-vllm"  "Nur Headless: Podman + vLLM (Kimi-Audio + Qwen3, NVIDIA)" \
    FALSE "cachyos-kernel" "Nur CachyOS-Kernel installieren (ohne NVIDIA/CUDA)" \
    FALSE "skip"           "Später entscheiden — nichts ausführen" \
    2>/dev/null || true)

[[ -z "$CHOICE" || "$CHOICE" == "skip" ]] && {
    # Bei "skip" Autostart entfernen, App-Eintrag bleibt
    rm -f "$AUTOSTART_FILE"
    exit 0
}

# Bestätigung
zenity --question \
    --title="Provisionierung starten" \
    --width=480 \
    --text="Profil <b>${CHOICE}</b> jetzt einrichten?\n\nDie Installation läuft in einem Terminal-Fenster.\nSie können den Fortschritt live mitverfolgen." \
    2>/dev/null || exit 0

# Provision-Script starten — via sudo (zeigt Passwort-Prompt direkt im Terminal)
TERMINAL=""
for t in ptyxis kgx gnome-terminal konsole xterm; do
    if command -v "$t" &>/dev/null; then TERMINAL="$t"; break; fi
done
[[ -z "$TERMINAL" ]] && { zenity --error --text="Kein Terminal-Emulator gefunden."; exit 1; }

# Kommando als Datei schreiben — vermeidet Quoting-Probleme in bash -c
RUN_SCRIPT=$(mktemp /tmp/fedora-provision-XXXXXX.sh)
cat > "$RUN_SCRIPT" << RUNEOF
#!/bin/bash
echo "=== Fedora Provisioner: ${CHOICE} ==="
echo ""
sudo bash "$PROVISION_SCRIPT" --profile "${CHOICE}" --user "${USER}" --run-now
echo ""
echo "--- Provisionierung abgeschlossen ---"
read -rp "[Enter zum Schließen] " _DUMMY
rm -f "$RUN_SCRIPT"
RUNEOF
chmod +x "$RUN_SCRIPT"

case "$TERMINAL" in
    ptyxis|kgx)     "$TERMINAL" -- bash "$RUN_SCRIPT" ;;
    gnome-terminal) gnome-terminal --title="Fedora Provisioner: $CHOICE" -- bash "$RUN_SCRIPT" ;;
    konsole)        konsole --hold -e bash "$RUN_SCRIPT" ;;
    xterm)          xterm -title "Fedora Provisioner: $CHOICE" -e bash "$RUN_SCRIPT" ;;
esac

# Marker + Autostart entfernen (nicht den App-Eintrag)
mkdir -p "$(dirname "$DONE_MARKER")"
touch "$DONE_MARKER"
rm -f "$AUTOSTART_FILE"
