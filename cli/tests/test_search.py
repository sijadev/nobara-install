"""Tests für die Paket-Suche und Kategorie-Erkennung."""
import asyncio
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

from fedora_autoinstall.models import (
    PackageResult,
    PackageSource,
    _infer_category_dnf,
    _infer_category_copr,
    _FLATPAK_CAT_MAP,
)
from fedora_autoinstall.search import (
    search_flathub,
    search_fedora_dnf,
    search_copr,
    search_all_sync,
)
from fedora_autoinstall.config import (
    add_dnf_package,
    add_flatpak,
    add_copr,
    add_package_result,
    get_packages,
    get_flatpaks,
    get_coprs,
    get_all_names,
    remove_package,
)
import xml.etree.ElementTree as ET


# ── Kategorie-Erkennung ───────────────────────────────────────────────────────

class TestCategoryInference(unittest.TestCase):

    def test_library_prefix(self):
        self.assertEqual(_infer_category_dnf("libsoundfile"), "Bibliothek")
        self.assertEqual(_infer_category_dnf("python3-httpx"), "Bibliothek")
        self.assertEqual(_infer_category_dnf("perl-JSON"), "Bibliothek")

    def test_devel_suffix(self):
        self.assertEqual(_infer_category_dnf("openssl-devel"), "Entwicklung")
        self.assertEqual(_infer_category_dnf("gtk3-devel"), "Entwicklung")

    def test_font(self):
        self.assertEqual(_infer_category_dnf("lobster-fonts"), "Schriftart")
        self.assertEqual(_infer_category_dnf("google-noto-fonts-common"), "Schriftart")

    def test_extension(self):
        self.assertEqual(_infer_category_dnf("gnome-shell-extension-caffeine"), "Extension")

    def test_plugin(self):
        self.assertEqual(_infer_category_dnf("gstreamer1-plugin-vaapi"), "Plugin/Addon")
        self.assertEqual(_infer_category_dnf("vim-plugin-nerdtree"), "Plugin/Addon")

    def test_kernel(self):
        self.assertEqual(_infer_category_dnf("kernel"), "System/Treiber")
        self.assertEqual(_infer_category_dnf("kernel-cachyos"), "System/Treiber")

    def test_tools(self):
        self.assertEqual(_infer_category_dnf("git-utils"), "Werkzeug")

    def test_generic_app(self):
        self.assertEqual(_infer_category_dnf("obs-studio"), "Anwendung")
        self.assertEqual(_infer_category_dnf("gimp"), "Anwendung")

    def test_copr_kernel(self):
        self.assertEqual(_infer_category_copr("x/y", "Linux kernel patches"), "System/Kernel")

    def test_copr_generic(self):
        self.assertEqual(_infer_category_copr("x/y", ""), "Community-Paket")

    def test_flatpak_cat_map_coverage(self):
        self.assertIn("AudioVideo", _FLATPAK_CAT_MAP)
        self.assertIn("Development", _FLATPAK_CAT_MAP)
        self.assertIn("Game", _FLATPAK_CAT_MAP)
        self.assertEqual(_FLATPAK_CAT_MAP["AudioVideo"], "Audio/Video")


# ── PackageResult Model ───────────────────────────────────────────────────────

class TestPackageResult(unittest.TestCase):

    def test_category_auto_inferred_dnf(self):
        pkg = PackageResult(source=PackageSource.DNF, name="libssl", display="libssl")
        self.assertEqual(pkg.category, "Bibliothek")

    def test_category_auto_inferred_copr(self):
        pkg = PackageResult(source=PackageSource.COPR, name="foo/bar", display="bar")
        self.assertEqual(pkg.category, "Community-Paket")

    def test_category_explicit_flatpak(self):
        pkg = PackageResult(
            source=PackageSource.FLATPAK,
            name="com.valvesoftware.Steam",
            display="Steam",
            category="Spiel",
        )
        self.assertEqual(pkg.category, "Spiel")

    def test_install_name(self):
        pkg = PackageResult(source=PackageSource.DNF, name="vim-enhanced", display="vim")
        self.assertEqual(pkg.install_name, "vim-enhanced")


# ── Config-Management ─────────────────────────────────────────────────────────

def _empty_config() -> ET.Element:
    return ET.fromstring("<fedora-install/>")


class TestConfigManagement(unittest.TestCase):

    def test_add_dnf_package(self):
        root = _empty_config()
        self.assertTrue(add_dnf_package(root, "vim-enhanced"))
        self.assertIn("vim-enhanced", get_packages(root))

    def test_add_dnf_package_duplicate(self):
        root = _empty_config()
        add_dnf_package(root, "vim-enhanced")
        self.assertFalse(add_dnf_package(root, "vim-enhanced"))
        self.assertEqual(get_packages(root).count("vim-enhanced"), 1)

    def test_add_flatpak(self):
        root = _empty_config()
        self.assertTrue(add_flatpak(root, "com.bitwig.BitwigStudio"))
        self.assertIn("com.bitwig.BitwigStudio", get_flatpaks(root))

    def test_add_flatpak_duplicate(self):
        root = _empty_config()
        add_flatpak(root, "com.bitwig.BitwigStudio")
        self.assertFalse(add_flatpak(root, "com.bitwig.BitwigStudio"))

    def test_add_copr(self):
        root = _empty_config()
        self.assertTrue(add_copr(root, "bieszczaders/kernel-cachyos"))
        self.assertIn("bieszczaders/kernel-cachyos", get_coprs(root))

    def test_add_package_result_dnf(self):
        root = _empty_config()
        pkg = PackageResult(source=PackageSource.DNF, name="htop", display="htop")
        self.assertTrue(add_package_result(root, pkg))
        self.assertIn("htop", get_packages(root))

    def test_add_package_result_flatpak(self):
        root = _empty_config()
        pkg = PackageResult(
            source=PackageSource.FLATPAK,
            name="org.gimp.GIMP",
            display="GIMP",
            category="Grafik",
        )
        self.assertTrue(add_package_result(root, pkg))
        self.assertIn("org.gimp.GIMP", get_flatpaks(root))

    def test_add_package_result_copr(self):
        root = _empty_config()
        pkg = PackageResult(
            source=PackageSource.COPR,
            name="tschmitz/ananicy-cpp",
            display="ananicy-cpp",
        )
        self.assertTrue(add_package_result(root, pkg))
        self.assertIn("tschmitz/ananicy-cpp", get_coprs(root))

    def test_get_all_names_includes_all_sources(self):
        root = _empty_config()
        add_dnf_package(root, "vim")
        add_flatpak(root, "org.gimp.GIMP")
        add_copr(root, "foo/bar")
        names = get_all_names(root)
        self.assertIn("vim", names)
        self.assertIn("org.gimp.GIMP", names)
        self.assertIn("foo/bar", names)
        self.assertEqual(len(names), 3)

    def test_remove_dnf_package(self):
        root = _empty_config()
        add_dnf_package(root, "vim")
        self.assertTrue(remove_package(root, "vim"))
        self.assertNotIn("vim", get_packages(root))

    def test_remove_flatpak(self):
        root = _empty_config()
        add_flatpak(root, "org.gimp.GIMP")
        self.assertTrue(remove_package(root, "org.gimp.GIMP"))
        self.assertNotIn("org.gimp.GIMP", get_flatpaks(root))

    def test_remove_nonexistent_returns_false(self):
        root = _empty_config()
        self.assertFalse(remove_package(root, "nonexistent-pkg"))

    def test_already_added_visible_in_all_names(self):
        root = _empty_config()
        add_dnf_package(root, "htop")
        names = get_all_names(root)
        self.assertIn("htop", names)


# ── API-Suche (gemockt) ───────────────────────────────────────────────────────

class TestSearchMocked(unittest.IsolatedAsyncioTestCase):

    async def test_search_flathub_returns_results(self):
        mock_response = MagicMock()
        mock_response.raise_for_status = MagicMock()
        mock_response.json.return_value = {
            "hits": [
                {
                    "id": "com.bitwig.BitwigStudio",
                    "name": "Bitwig Studio",
                    "summary": "Professional DAW",
                    "categories": ["AudioVideo"],
                }
            ]
        }
        mock_client = AsyncMock()
        mock_client.get.return_value = mock_response

        results = await search_flathub("bitwig", mock_client)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0].name, "com.bitwig.BitwigStudio")
        self.assertEqual(results[0].source, PackageSource.FLATPAK)
        self.assertEqual(results[0].category, "Audio/Video")

    async def test_search_flathub_api_error_returns_empty(self):
        mock_client = AsyncMock()
        mock_client.get.side_effect = Exception("Network error")
        results = await search_flathub("bitwig", mock_client)
        self.assertEqual(results, [])

    async def test_search_copr_returns_results(self):
        mock_response = MagicMock()
        mock_response.raise_for_status = MagicMock()
        mock_response.json.return_value = {
            "items": [
                {
                    "ownername": "bieszczaders",
                    "name": "kernel-cachyos",
                    "description": "CachyOS kernel with BORE scheduler",
                }
            ]
        }
        mock_client = AsyncMock()
        mock_client.get.return_value = mock_response

        results = await search_copr("cachyos", mock_client)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0].name, "bieszczaders/kernel-cachyos")
        self.assertEqual(results[0].source, PackageSource.COPR)

    async def test_search_dnf_returns_results(self):
        mock_response = MagicMock()
        mock_response.raise_for_status = MagicMock()
        mock_response.json.return_value = {
            "projects": [
                {"name": "vim", "description": "Vi IMproved"},
                {"name": "vim-enhanced", "description": "Enhanced vi editor"},
            ]
        }
        mock_client = AsyncMock()
        mock_client.get.return_value = mock_response

        results = await search_fedora_dnf("vim", mock_client)
        self.assertEqual(len(results), 2)
        self.assertTrue(all(r.source == PackageSource.DNF for r in results))
        self.assertEqual(results[0].name, "vim")


if __name__ == "__main__":
    unittest.main()
