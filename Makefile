SHELL := /bin/sh

VENV_DIR ?= .venv
UNAME_S := $(shell uname -s 2>/dev/null || echo Unknown)

VENV_PY := $(VENV_DIR)/bin/python
VENV_PIP := $(VENV_DIR)/bin/pip

.PHONY: help check-os-prereqs venv install install-dev test run-all run-all-verbose run-all-full run-all-e2e run-all-full-e2e install-usb install-podman install-podman-debug install-fedora-podman e2e test-full-e2e vm-gui vm-gui-virtual podman-machine-setup clean

help:
	@echo "Targets:"
	@echo "  make check-os-prereqs - OS/Python Voraussetzungen pruefen"
	@echo "  make venv        - Python venv unter $(VENV_DIR) erstellen"
	@echo "  make install     - Runtime-Abhangigkeiten installieren"
	@echo "  make install-dev - Dev/Test-Abhangigkeiten installieren"
	@echo "  make test        - Standard-Testlauf ohne Full/E2E"
	@echo "  make run-all     - tests/run-all.sh"
	@echo "  make run-all-verbose - tests/run-all.sh -v"
	@echo "  make run-all-full - tests/run-all.sh --full"
	@echo "  make run-all-e2e - tests/run-all.sh --e2e"
	@echo "  make run-all-full-e2e - tests/run-all.sh --full --e2e"
	@echo "  make install-usb DEVICE=/dev/sdX - Echte USB-Installation starten"
	@echo "  make install-fedora-podman - Fedora-Installation in Podman starten"
	@echo "  make install-podman - Installation in Podman mit virtuellem USB"
	@echo "  make install-podman-debug - Podman-Install, Container bei Fehler behalten"
	@echo "  make vm-gui      - Graphische VM-Full-Installation auf macOS mit USB verfolgen"
	@echo "  make vm-gui-virtual - VM-Test mit virtueller USB (kein Stick noetig, nach make install-podman)"
	@echo "  make podman-machine-setup - Podman-Machine einmalig auf 8 GB RAM / 6 CPUs konfigurieren (macOS)"
	@echo "  make e2e         - Alias fur install-podman"
	@echo "  make test-full-e2e - Voller Testlauf inkl. Podman E2E"
	@echo "  make clean       - venv entfernen"

check-os-prereqs:
	@echo "Pruefe OS Voraussetzungen..."
	@if [ "$(UNAME_S)" = "Darwin" ]; then \
		command -v python3 >/dev/null 2>&1 || { \
			echo "Fehlt: python3"; \
			echo "Install (macOS): brew install python"; \
			exit 1; \
		}; \
		python3 -c "import venv" >/dev/null 2>&1 || { \
			echo "Fehlt: Python venv Modul"; \
			exit 1; \
		}; \
		echo "OK: macOS Voraussetzungen erfuellt"; \
	else \
		command -v python3 >/dev/null 2>&1 || { \
			echo "Fehlt: python3"; \
			echo "Install (Fedora): sudo dnf install python3"; \
			echo "Install (Debian/Ubuntu): sudo apt install python3 python3-venv"; \
			echo "Install (Arch): sudo pacman -S python"; \
			exit 1; \
		}; \
		python3 -c "import venv" >/dev/null 2>&1 || { \
			echo "Fehlt: python3-venv Modul"; \
			echo "Install (Debian/Ubuntu): sudo apt install python3-venv"; \
			exit 1; \
		}; \
		echo "OK: Linux Voraussetzungen erfuellt"; \
	fi

venv: check-os-prereqs
	@if [ -x "$(VENV_PY)" ]; then \
		echo "Venv existiert bereits: $(VENV_DIR)"; \
	else \
		echo "Erstelle venv: $(VENV_DIR)"; \
		python3 -m venv "$(VENV_DIR)"; \
	fi
	@"$(VENV_PIP)" install --upgrade pip

install: venv
	@"$(VENV_PIP)" install -r requirements.txt

install-dev: venv
	@"$(VENV_PIP)" install -r requirements-dev.txt

run-all:
	@bash tests/run-all.sh

run-all-verbose:
	@bash tests/run-all.sh -v

run-all-full:
	@bash tests/run-all.sh --full

run-all-e2e:
	@bash tests/run-all.sh --e2e

run-all-full-e2e:
	@bash tests/run-all.sh --full --e2e

test: run-all

install-usb:
	@if [ -z "$(DEVICE)" ]; then \
		echo "Fehlt: DEVICE"; \
		echo "Beispiel Linux: make install-usb DEVICE=/dev/sdX"; \
		echo "Beispiel macOS: make install-usb DEVICE=/dev/diskN"; \
		exit 2; \
	fi
	@sudo ./install.sh "$(DEVICE)"

install-podman:
	@"$(VENV_PY)" tests/test_podman_e2e_usb.py --run

install-podman-debug:
	@"$(VENV_PY)" tests/test_podman_e2e_usb.py --run --keep-on-fail

install-fedora-podman: install-podman

e2e: install-podman

test-full-e2e: run-all-full-e2e

vm-gui:
	@if [ -z "$(DEVICE)" ]; then \
		echo "Fehlt: DEVICE"; \
		echo "Beispiel macOS: make vm-gui DEVICE=/dev/diskN"; \
		exit 2; \
	fi
	@sudo "$(VENV_PY)" tests/test_anaconda_vm_usb.py --run --gui --watch-install --keep-on-fail --timeout 1200 --usb-device "$(DEVICE)"

vm-gui-virtual:
	@sudo "$(VENV_PY)" tests/test_anaconda_vm_usb.py --run --gui --watch-install --keep-on-fail --timeout 1200

podman-machine-setup:
	@echo "Konfiguriere Podman-Machine fuer Pipeline (einmalig)..."
	@podman machine stop || true
	@podman machine set --memory 8192 --cpus 6
	@podman machine start
	@echo "Podman-Machine bereit (8 GB RAM, 6 CPUs)."

clean:
	@echo "Entferne venv: $(VENV_DIR)"
	@rm -rf "$(VENV_DIR)"

.PHONY: test-podman-rpm-pipeline
test-podman-rpm-pipeline:
	@bash tools/podman_rpm_pipeline.sh
