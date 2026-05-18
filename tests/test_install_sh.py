#!/usr/bin/env python3
"""Unit tests for install.sh."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent.parent
INSTALL_SH = PROJECT_DIR / "install.sh"
KICKSTART_FULL = PROJECT_DIR / "kickstart" / "fedora-full.ks"


class TestInstallSh(unittest.TestCase):
    def test_bash_syntax(self) -> None:
        rc = subprocess.run(["bash", "-n", str(INSTALL_SH)], check=False).returncode
        self.assertEqual(rc, 0)

    def test_install_has_xml2ks_flags(self) -> None:
        text = INSTALL_SH.read_text(encoding="utf-8")
        self.assertIn("--first-boot-script", text)
        self.assertIn("--first-login-script", text)
        self.assertIn("--systemd-unit", text)

    def test_required_files_exist(self) -> None:
        self.assertTrue((PROJECT_DIR / "scripts" / "first-boot.sh").is_file())
        self.assertTrue((PROJECT_DIR / "scripts" / "first-login.sh").is_file())
        self.assertTrue((PROJECT_DIR / "systemd" / "fedora-first-boot.service").is_file())

    def test_required_files_not_empty(self) -> None:
        self.assertGreater((PROJECT_DIR / "scripts" / "first-boot.sh").stat().st_size, 0)
        self.assertGreater((PROJECT_DIR / "scripts" / "first-login.sh").stat().st_size, 0)
        self.assertGreater((PROJECT_DIR / "systemd" / "fedora-first-boot.service").stat().st_size, 0)

    def test_no_empty_heredoc_in_kickstart(self) -> None:
        text = KICKSTART_FULL.read_text(encoding="utf-8")
        self.assertIsNone(re.search(r"<<'FBEOF'\n\nFBEOF", text))
        self.assertIsNone(re.search(r"<<'UNITEOF'\n\nUNITEOF", text))

    def test_install_custom_mode_reference(self) -> None:
        text = INSTALL_SH.read_text(encoding="utf-8")
        self.assertIn("apply_config.py", text)
        self.assertIn("--custom", text)

    def test_kickstart_package_group(self) -> None:
        text = KICKSTART_FULL.read_text(encoding="utf-8")
        self.assertIn("workstation-product-environment", text)
        self.assertNotIn("@^fedora-desktop", text)

    def test_install_invokes_build_rpm(self) -> None:
        text = INSTALL_SH.read_text(encoding="utf-8")
        self.assertIn("tools/build-rpm.sh", text)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestInstallSh)
    verbosity = 2 if args.verbose else 1
    result = unittest.TextTestRunner(verbosity=verbosity).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
