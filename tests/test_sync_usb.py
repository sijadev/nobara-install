#!/usr/bin/env python3
"""Unit tests for tools/sync-usb.sh without real USB devices."""

from __future__ import annotations

import argparse
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parent.parent
SYNC_USB = PROJECT_DIR / "tools" / "sync-usb.sh"

SYNC_ENTRIES = [
    ("scripts/fedora-provision.sh", "fedora-provision.sh"),
    ("kickstart/common-post.inc", "kickstart/common-post.inc"),
    ("kickstart/fedora-full.ks", "kickstart/fedora-full.ks"),
    ("kickstart/fedora-headless-vllm.ks", "kickstart/fedora-headless-vllm.ks"),
    ("kickstart/fedora-theme-bash.ks", "kickstart/fedora-theme-bash.ks"),
    ("scripts/first-boot.sh", "scripts/first-boot.sh"),
    ("scripts/first-login.sh", "scripts/first-login.sh"),
    ("scripts/vllm-router.py", "scripts/vllm-router.py"),
    ("scripts/welcome-dialog.sh", "scripts/welcome-dialog.sh"),
    ("scripts/fedora-provision.desktop", "scripts/fedora-provision.desktop"),
    ("systemd/fedora-first-boot.service", "systemd/fedora-first-boot.service"),
    ("systemd/vllm@.container", "systemd/vllm@.container"),
    ("systemd/vllm-router.service", "systemd/vllm-router.service"),
    ("boot/grub.cfg", "boot/grub.cfg"),
]


class SyncUsbHarness:
    def __init__(self) -> None:
        self.tmpdir_obj = tempfile.TemporaryDirectory(prefix="sync-usb-test-")
        self.tmp = Path(self.tmpdir_obj.name)
        self.fake_project = self.tmp / "project"
        self.fake_usb = self.tmp / "usb"
        self.fake_bin = self.tmp / "bin"
        self.wrapper = self.tmp / "run-sync-usb.sh"
        self._prepare()

    def _prepare(self) -> None:
        for p in [
            self.fake_project / "kickstart",
            self.fake_project / "scripts",
            self.fake_project / "systemd",
            self.fake_project / "boot",
            self.fake_usb / "kickstart",
            self.fake_usb / "scripts",
            self.fake_usb / "systemd",
            self.fake_usb / "boot",
            self.fake_bin,
        ]:
            p.mkdir(parents=True, exist_ok=True)

        required = [
            "scripts/fedora-provision.sh",
            "kickstart/common-post.inc",
            "kickstart/fedora-full.ks",
            "kickstart/fedora-headless-vllm.ks",
            "kickstart/fedora-theme-bash.ks",
            "scripts/first-boot.sh",
            "scripts/first-login.sh",
            "scripts/vllm-router.py",
            "scripts/welcome-dialog.sh",
            "scripts/fedora-provision.desktop",
            "systemd/fedora-first-boot.service",
            "systemd/vllm@.container",
            "systemd/vllm-router.service",
            "boot/grub.cfg",
        ]
        for rel in required:
            dst = self.fake_project / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text("x\n", encoding="utf-8")

        (self.fake_usb / "boot" / "vmlinuz").write_text("x\n", encoding="utf-8")

        (self.fake_bin / "findmnt").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        (self.fake_bin / "mount").write_text(
            "#!/bin/bash\necho 'fake on /Volumes/FEDORA-USB type msdos'\nexit 0\n",
            encoding="utf-8",
        )
        for cmd in ["lsblk", "udisksctl", "diskutil", "sync"]:
            (self.fake_bin / cmd).write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")

        for cmd in self.fake_bin.iterdir():
            mode = cmd.stat().st_mode
            cmd.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        script_text = SYNC_USB.read_text(encoding="utf-8")
        script_text = re.sub(r"PROJECT_DIR=.*", f'PROJECT_DIR="{self.fake_project}"', script_text, count=1)
        script_text = re.sub(r"HOST_OS=.*", 'HOST_OS="Linux"', script_text, count=1)
        script_text = re.sub(r'USB_MNT="/run/media[^\n]*', f'USB_MNT="{self.fake_usb}"', script_text, count=1)

        patched = self.tmp / "sync-usb.patched.sh"
        patched.write_text(script_text, encoding="utf-8")
        patched.chmod(0o755)

        self.wrapper.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            f'export PATH="{self.fake_bin}:$PATH"\n'
            f'bash "{patched}" "$@"\n',
            encoding="utf-8",
        )
        self.wrapper.chmod(0o755)

    def mirror_all_entries(self) -> None:
        for src, dst in SYNC_ENTRIES:
            src_path = self.fake_project / src
            dst_path = self.fake_usb / dst
            dst_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_path, dst_path)

    def run_sync(self, *args: str) -> tuple[int, str]:
        proc = subprocess.run(
            ["bash", str(self.wrapper), *args],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        return proc.returncode, proc.stdout

    def cleanup(self) -> None:
        self.tmpdir_obj.cleanup()


class TestSyncUsb(unittest.TestCase):
    def test_invalid_argument_exit_2(self) -> None:
        rc = subprocess.run(["bash", str(SYNC_USB), "--unknown"], check=False).returncode
        self.assertEqual(rc, 2)

    def test_check_current_exit_0_and_output(self) -> None:
        h = SyncUsbHarness()
        try:
            h.mirror_all_entries()
            rc, out = h.run_sync("--check")
            self.assertEqual(rc, 0)
            self.assertIn("aktuell", out)
        finally:
            h.cleanup()

    def test_check_drift_exit_1(self) -> None:
        h = SyncUsbHarness()
        try:
            (h.fake_project / "kickstart" / "fedora-full.ks").write_text("neue version\n", encoding="utf-8")
            rc, _ = h.run_sync("--check")
            self.assertEqual(rc, 1)
        finally:
            h.cleanup()

    def test_check_missing_usb_file_detected(self) -> None:
        h = SyncUsbHarness()
        try:
            rc, out = h.run_sync("--check")
            self.assertEqual(rc, 1)
            self.assertIn("fedora-full.ks", out)
        finally:
            h.cleanup()

    def test_force_copies_files(self) -> None:
        h = SyncUsbHarness()
        try:
            (h.fake_project / "kickstart" / "fedora-full.ks").write_text("v2\n", encoding="utf-8")
            h.run_sync("--force")
            self.assertTrue((h.fake_usb / "kickstart" / "fedora-full.ks").is_file())
            self.assertEqual(
                (h.fake_project / "kickstart" / "fedora-full.ks").read_text(encoding="utf-8"),
                (h.fake_usb / "kickstart" / "fedora-full.ks").read_text(encoding="utf-8"),
            )
        finally:
            h.cleanup()

    def test_force_removes_obsolete_file(self) -> None:
        h = SyncUsbHarness()
        try:
            ventoy = h.fake_usb / "ventoy"
            ventoy.mkdir(parents=True, exist_ok=True)
            (ventoy / "ventoy_grub.cfg").write_text("old\n", encoding="utf-8")
            h.run_sync("--force")
            self.assertFalse((ventoy / "ventoy_grub.cfg").exists())
        finally:
            h.cleanup()

    def test_force_missing_source_warns(self) -> None:
        h = SyncUsbHarness()
        try:
            (h.fake_project / "scripts" / "vllm-router.py").unlink()
            rc, out = h.run_sync("--force")
            self.assertEqual(rc, 0)
            self.assertRegex(out, r"uebersprungen|Quelle fehlt|übersprungen")
        finally:
            h.cleanup()

    def test_check_synced_exit_0(self) -> None:
        h = SyncUsbHarness()
        try:
            h.mirror_all_entries()
            rc, _ = h.run_sync("--check")
            self.assertEqual(rc, 0)
        finally:
            h.cleanup()

    def test_force_no_copy_message_for_identical(self) -> None:
        h = SyncUsbHarness()
        try:
            (h.fake_project / "boot" / "grub.cfg").write_text("gleichinhalt\n", encoding="utf-8")
            (h.fake_usb / "boot" / "grub.cfg").write_text("gleichinhalt\n", encoding="utf-8")
            _, out = h.run_sync("--force")
            self.assertNotIn("Kopiert: boot/grub.cfg", out)
        finally:
            h.cleanup()

    def test_sync_usb_syntax(self) -> None:
        rc = subprocess.run(["bash", "-n", str(SYNC_USB)], check=False).returncode
        self.assertEqual(rc, 0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TestSyncUsb)
    verbosity = 2 if args.verbose else 1
    result = unittest.TextTestRunner(verbosity=verbosity).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
