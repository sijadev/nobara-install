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
		-h|--help)
			echo "Usage: bash tests/run-all.sh [-v|--verbose] [--full]"
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

echo "[1/3] Python: systemd units"
python3 tests/test_systemd_units.py "${vflag[@]+"${vflag[@]}"}"

echo "[2/3] Python: apply_config + xml2ks"
python3 -m unittest "${vflag[@]+"${vflag[@]}"}" tests.test_apply_config tests.test_xml2ks

echo "[3/3] Python: kickstart validator"
python3 -m unittest "${vflag[@]+"${vflag[@]}"}" tests.test_kickstart_validator

echo ""
echo "Alle Testgruppen erfolgreich."
echo ""
