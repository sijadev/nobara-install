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

if [[ "$(uname -s)" == "Darwin" ]]; then
    podman machine start >/dev/null 2>&1 || true
    echo "[podman-e2e] starte E2E via podman machine (rootful container)..."
    podman machine ssh "sudo podman run --rm --privileged -v '${PROJECT_DIR}:/src:Z' fedora:latest /bin/bash /src/tests/podman_e2e_inner.sh"
else
    echo "[podman-e2e] starte E2E-Container..."
    podman run --rm --privileged \
        -v "${PROJECT_DIR}:/src:Z" \
        fedora:latest \
        /bin/bash /src/tests/podman_e2e_inner.sh
fi
