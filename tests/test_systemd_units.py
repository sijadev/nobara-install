#!/usr/bin/env python3
"""Validate repository systemd unit files."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent.parent
SYSTEMD_DIR = PROJECT_DIR / "systemd"
FIRST_BOOT = SYSTEMD_DIR / "fedora-first-boot.service"
ROUTER = SYSTEMD_DIR / "vllm-router.service"
QUADLET = SYSTEMD_DIR / "vllm@.container"


class TestSystemdUnits(unittest.TestCase):
    def test_files_exist(self) -> None:
        self.assertTrue(FIRST_BOOT.is_file())
        self.assertTrue(ROUTER.is_file())
        self.assertTrue(QUADLET.is_file())

    def test_files_not_empty(self) -> None:
        self.assertGreater(FIRST_BOOT.stat().st_size, 0)
        self.assertGreater(ROUTER.stat().st_size, 0)
        self.assertGreater(QUADLET.stat().st_size, 0)

    def test_first_boot_content(self) -> None:
        text = FIRST_BOOT.read_text(encoding="utf-8")
        self.assertIn("[Unit]", text)
        self.assertIn("[Service]", text)
        self.assertIn("[Install]", text)
        self.assertIn("WantedBy=multi-user.target", text)
        self.assertIn("ExecStart=/usr/local/sbin/fedora-first-boot.sh", text)
        self.assertIn("ConditionPathExists=!/var/lib/fedora-provision/first-boot.done", text)

    def test_router_content(self) -> None:
        text = ROUTER.read_text(encoding="utf-8")
        self.assertIn("[Unit]", text)
        self.assertIn("[Service]", text)
        self.assertIn("[Install]", text)
        self.assertIn("WantedBy=default.target", text)
        self.assertIn("ExecStart=%h/.local/bin/vllm-router", text)
        self.assertIn("Restart=on-failure", text)

    def test_quadlet_content(self) -> None:
        text = QUADLET.read_text(encoding="utf-8")
        self.assertIn("[Unit]", text)
        self.assertIn("[Container]", text)
        self.assertIn("[Service]", text)
        self.assertIn("[Install]", text)
        self.assertIn("Image=localhost/fedora-vllm:latest", text)
        self.assertIn("EnvironmentFile=%h/.config/vllm-router/instances/%i.env", text)
        self.assertIn("WantedBy=default.target", text)

    def test_systemd_analyze_verify_optional(self) -> None:
        if shutil.which("systemd-analyze") is None:
            self.skipTest("systemd-analyze nicht verfuegbar")

        if not Path("/usr/local/sbin/fedora-first-boot.sh").exists():
            self.skipTest("lokales ExecStart fuer fedora-first-boot fehlt")

        rc = subprocess.run(["systemd-analyze", "verify", str(FIRST_BOOT)], check=False).returncode
        self.assertEqual(rc, 0)


class TestSystemdRouterVerifyOptional(unittest.TestCase):
    def test_systemd_analyze_router_optional(self) -> None:
        if shutil.which("systemd-analyze") is None:
            self.skipTest("systemd-analyze nicht verfuegbar")

        if not (Path.home() / ".local" / "bin" / "vllm-router").exists():
            self.skipTest("lokales ExecStart fuer vllm-router fehlt")

        rc = subprocess.run(["systemd-analyze", "verify", str(ROUTER)], check=False).returncode
        self.assertEqual(rc, 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    verbosity = 2 if args.verbose else 1
    result = unittest.TextTestRunner(verbosity=verbosity).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
