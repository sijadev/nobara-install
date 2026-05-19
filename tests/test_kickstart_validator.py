import shutil
import subprocess
import unittest
from pathlib import Path
from typing import cast


PROJECT = Path(__file__).parent.parent
KICKSTART_DIR = PROJECT / "kickstart"
KSVALIDATOR = shutil.which("ksvalidator")


@unittest.skipUnless(KSVALIDATOR, "ksvalidator nicht gefunden (dnf install pykickstart)")
class KickstartValidatorTests(unittest.TestCase):
    """Validiert statische Kickstart-Profile mit dem externen ksvalidator-Tool."""

    def _validate(self, filename: str) -> None:
        proc = subprocess.run(
            [cast(str, KSVALIDATOR), filename],
            cwd=KICKSTART_DIR,
            text=True,
            capture_output=True,
            check=False,
        )
        msg = (
            f"ksvalidator fehlgeschlagen für {filename}\n"
            f"exit={proc.returncode}\n"
            f"stdout:\n{proc.stdout}\n"
            f"stderr:\n{proc.stderr}"
        )
        self.assertEqual(proc.returncode, 0, msg)

    def test_profiles_validate_cleanly(self):
        for ks in ("fedora-full.ks", "fedora-theme-bash.ks", "fedora-headless-vllm.ks"):
            with self.subTest(kickstart=ks):
                self._validate(ks)


class KickstartRepoFallbackTests(unittest.TestCase):
    """Regression-Checks fuer lokale RPM-Repo-Direktive in statischen Profilen."""

    def test_full_profile_has_no_kickstart_repo_directive(self):
        """Repo ist jetzt via inst.addrepo in grub.cfg — darf nicht mehr im Kickstart stehen."""
        ks_path = KICKSTART_DIR / "fedora-full.ks"
        content = ks_path.read_text(encoding="utf-8")
        self.assertNotIn("repo --name=fedora-autoinstall", content)
        self.assertNotIn("fedora-autoinstall-stage2", content)


if __name__ == "__main__":
    unittest.main()
