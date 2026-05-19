#!/usr/bin/env bash
# tests/run-all.sh - Standard-Testlauf fur das Repository.
#
# Usage:
#   bash tests/run-all.sh
#   bash tests/run-all.sh -v
#   bash tests/run-all.sh --full

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

VERBOSE=0
FULL=0
E2E=0
ANACONDA_VM=0
USB_DEVICE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		-v|--verbose)
			VERBOSE=1
			shift
			;;
		--full)
			FULL=1
			shift
			;;
		--e2e)
			E2E=1
			shift
			;;
		--anaconda-vm)
			ANACONDA_VM=1
			shift
			;;
		--usb-device)
			USB_DEVICE="${2:-}"
			if [[ -z "$USB_DEVICE" ]]; then
				echo "Fehlender Wert fuer --usb-device" >&2
				exit 2
			fi
			shift 2
			;;
		-h|--help)
			echo "Usage: bash tests/run-all.sh [-v|--verbose] [--full] [--e2e] [--anaconda-vm --usb-device /dev/sdX]"
			exit 0
			;;
		*)
			echo "Unbekanntes Argument: $1" >&2
			exit 2
			;;
	esac
done

vflag=()
[[ $VERBOSE -eq 1 ]] && vflag=(-v)

cd "$PROJECT_DIR"

echo ""
echo "== Standard-Testlauf =="
echo ""

echo "[1/5] Python: install.sh"
python3 tests/test_install_sh.py "${vflag[@]+"${vflag[@]}"}"

echo "[2/5] Python: sync-usb.sh"
python3 tests/test_sync_usb.py "${vflag[@]+"${vflag[@]}"}"

echo "[3/5] Python: systemd units"
python3 tests/test_systemd_units.py "${vflag[@]+"${vflag[@]}"}"

if [[ $FULL -eq 1 ]]; then
	echo "[4/5] Python: apply_config + xml2ks"
	python3 -m unittest -v tests.test_apply_config tests.test_xml2ks

	echo "[5/5] Python: kickstart validator"
	python3 -m unittest -v tests.test_kickstart_validator
else
	echo "[4/5] Python: ubersprungen (nutze --full)"
	echo "[5/5] Validator: ubersprungen (nutze --full)"
fi

if [[ $E2E -eq 1 ]]; then
	echo "[6/6] Podman E2E: virtueller USB"
	python3 tests/test_podman_e2e_usb.py --run
else
	echo "[6/6] Podman E2E: ubersprungen (nutze --e2e)"
fi

if [[ $ANACONDA_VM -eq 1 ]]; then
	USB_DEVICE_EFFECTIVE="${USB_DEVICE:-${FEDORA_VM_USB_DEVICE:-}}"
	if [[ -z "$USB_DEVICE_EFFECTIVE" ]]; then
		echo "[7/7] Anaconda VM USB: FEHLER (nutze --usb-device /dev/sdX oder FEDORA_VM_USB_DEVICE)" >&2
		exit 2
	fi
	echo "[7/7] Anaconda VM USB: Full-Install Smoke"
	python3 tests/test_anaconda_vm_usb.py --run --usb-device "$USB_DEVICE_EFFECTIVE"
else
	echo "[7/7] Anaconda VM USB: ubersprungen (nutze --anaconda-vm)"
fi

echo ""
echo "Alle Testgruppen erfolgreich."
echo ""
