SHELL := /bin/sh

VENV_DIR ?= .venv
UNAME_S := $(shell uname -s 2>/dev/null || echo Unknown)

VENV_PY := $(VENV_DIR)/bin/python
VENV_PIP := $(VENV_DIR)/bin/pip

.PHONY: help check-os-prereqs venv install install-dev test build-rpm build-iso write-iso vm-gui-iso vm-gui-virtual clean

help:
	@echo "Targets:"
	@echo "  make check-os-prereqs    - OS/Python Voraussetzungen pruefen"
	@echo "  make venv                - Python venv erstellen"
	@echo "  make install             - Runtime-Abhaengigkeiten installieren"
	@echo "  make install-dev         - Dev/Test-Abhaengigkeiten installieren"
	@echo "  make test                - Unit-Tests ausfuehren"
	@echo "  make build-rpm           - fedora-autoinstall RPM bauen"
	@echo "  make build-iso           - Gepatchte ISO bauen (Kickstart + RPM eingebettet)"
	@echo "  make write-iso DEVICE=/dev/diskN - ISO auf USB schreiben"
	@echo "  make vm-gui-iso          - VM-Test mit gepatchter ISO"
	@echo "  make vm-gui-virtual      - VM-Test mit virtueller USB (Fallback)"
	@echo "  make clean               - venv entfernen"

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

test:
	@bash tests/run-all.sh

build-rpm:
	@bash tools/build-rpm.sh

build-iso: build-rpm
	@bash tools/build-iso.sh

write-iso:
	@if [ -z "$(DEVICE)" ]; then \
		echo "Fehlt: DEVICE"; \
		echo "Beispiel macOS: make write-iso DEVICE=/dev/diskN"; \
		echo "Beispiel Linux: make write-iso DEVICE=/dev/sdX"; \
		exit 2; \
	fi
	@ISO=$$(ls -t iso/fedora-autoinstall-*.iso 2>/dev/null | head -1); \
	[ -n "$$ISO" ] || { echo "Kein ISO gefunden — zuerst: make build-iso"; exit 1; }; \
	echo "Schreibe $$(basename $$ISO) → $(DEVICE)"; \
	if [ "$$(uname -s)" = "Darwin" ]; then \
		diskutil unmountDisk force "$(DEVICE)" 2>/dev/null || true; \
		RAW=$$(echo "$(DEVICE)" | sed 's|/dev/disk|/dev/rdisk|'); \
		sudo dd if="$$ISO" of="$$RAW" bs=4m; \
		sync; \
		diskutil eject "$(DEVICE)" 2>/dev/null || true; \
		echo "Fertig — Stick kann abgezogen werden."; \
	else \
		sudo dd if="$$ISO" of="$(DEVICE)" bs=4M status=progress; \
	fi

vm-gui-iso:
	@sudo "$(VENV_PY)" tests/test_anaconda_vm_usb.py --run --gui --watch-install --keep-on-fail --timeout 1200 --iso $$(ls -t iso/fedora-autoinstall-*.iso 2>/dev/null | head -1)

vm-gui-virtual:
	@sudo "$(VENV_PY)" tests/test_anaconda_vm_usb.py --run --gui --watch-install --keep-on-fail --timeout 1200

clean:
	@echo "Entferne venv: $(VENV_DIR)"
	@rm -rf "$(VENV_DIR)"

.PHONY: test-podman-rpm-pipeline
test-podman-rpm-pipeline:
	@bash tools/podman_rpm_pipeline.sh
