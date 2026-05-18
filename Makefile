SHELL := /bin/sh

VENV_DIR ?= .venv
UNAME_S := $(shell uname -s 2>/dev/null || echo Unknown)

ifeq ($(OS),Windows_NT)
	VENV_PY := $(VENV_DIR)/Scripts/python.exe
	VENV_PIP := $(VENV_DIR)/Scripts/pip.exe
else
	VENV_PY := $(VENV_DIR)/bin/python
	VENV_PIP := $(VENV_DIR)/bin/pip
endif

.PHONY: help check-os-prereqs venv install install-dev test install-usb install-podman e2e test-full-e2e clean

help:
	@echo "Targets:"
	@echo "  make check-os-prereqs - OS/Python Voraussetzungen pruefen"
	@echo "  make venv        - Python venv unter $(VENV_DIR) erstellen"
	@echo "  make install     - Runtime-Abhangigkeiten installieren"
	@echo "  make install-dev - Dev/Test-Abhangigkeiten installieren"
	@echo "  make test        - Standard-Testlauf ohne Full/E2E"
	@echo "  make install-usb DEVICE=/dev/sdX - Echte USB-Installation starten"
	@echo "  make install-podman - Installation in Podman mit virtuellem USB"
	@echo "  make e2e         - Alias fur install-podman"
	@echo "  make test-full-e2e - Voller Testlauf inkl. Podman E2E"
	@echo "  make clean       - venv entfernen"

check-os-prereqs:
	@echo "Pruefe OS Voraussetzungen..."
	@if [ "$(OS)" = "Windows_NT" ]; then \
		if command -v python >/dev/null 2>&1; then \
			PY_CMD=python; \
		elif command -v py >/dev/null 2>&1; then \
			PY_CMD="py -3"; \
		else \
			echo "Fehlt: Python 3"; \
			echo "Install (Windows): winget install Python.Python.3.12"; \
			exit 1; \
		fi; \
		$$PY_CMD -c "import venv" >/dev/null 2>&1 || { \
			echo "Fehlt: Python venv Modul"; \
			echo "Bitte Python 3 mit venv-Unterstuetzung installieren."; \
			exit 1; \
		}; \
		echo "OK: Windows Voraussetzungen erfuellt"; \
	elif [ "$(UNAME_S)" = "Darwin" ]; then \
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
		if [ "$(OS)" = "Windows_NT" ]; then \
			if command -v python >/dev/null 2>&1; then \
				python -m venv "$(VENV_DIR)"; \
			else \
				py -3 -m venv "$(VENV_DIR)"; \
			fi; \
		else \
			python3 -m venv "$(VENV_DIR)"; \
		fi; \
	fi
	@"$(VENV_PIP)" install --upgrade pip

install: venv
	@"$(VENV_PIP)" install -r requirements.txt

install-dev: venv
	@"$(VENV_PIP)" install -r requirements-dev.txt

test:
	@bash tests/run-all.sh

install-usb:
	@if [ -z "$(DEVICE)" ]; then \
		echo "Fehlt: DEVICE"; \
		echo "Beispiel Linux: make install-usb DEVICE=/dev/sdX"; \
		echo "Beispiel macOS: make install-usb DEVICE=/dev/diskN"; \
		exit 2; \
	fi
	@sudo ./install.sh "$(DEVICE)"

install-podman:
	@bash tests/test_podman_e2e_usb.sh --run

e2e: install-podman

test-full-e2e:
	@bash tests/run-all.sh --full --e2e

clean:
	@echo "Entferne venv: $(VENV_DIR)"
	@rm -rf "$(VENV_DIR)"
