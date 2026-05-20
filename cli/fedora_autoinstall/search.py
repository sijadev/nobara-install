"""Paket-Suche über DNF, Flathub und COPR APIs."""
from __future__ import annotations
import asyncio
from typing import AsyncIterator

import httpx

from .models import PackageResult, PackageSource, _FLATPAK_CAT_MAP

# Timeouts für API-Aufrufe
_TIMEOUT = httpx.Timeout(8.0)


# ── Flathub ──────────────────────────────────────────────────────────────────

async def search_flathub(query: str, client: httpx.AsyncClient) -> list[PackageResult]:
    """Sucht Flatpak-Apps auf Flathub."""
    try:
        resp = await client.get(
            "https://flathub.org/api/v2/search",
            params={"query": query},
            timeout=_TIMEOUT,
        )
        resp.raise_for_status()
        data = resp.json()
        results = []
        for hit in data.get("hits", [])[:8]:
            cats = hit.get("categories") or []
            cat_de = next(
                (_FLATPAK_CAT_MAP[c] for c in cats if c in _FLATPAK_CAT_MAP),
                "Anwendung"
            )
            results.append(PackageResult(
                source      = PackageSource.FLATPAK,
                name        = hit.get("id", ""),
                display     = hit.get("name", hit.get("id", "")),
                description = hit.get("summary", ""),
                url         = f"https://flathub.org/apps/{hit.get('id','')}",
                category    = cat_de,
            ))
        return results
    except Exception:
        return []


# ── Fedora Packages (DNF) ────────────────────────────────────────────────────

async def search_fedora_dnf(query: str, client: httpx.AsyncClient) -> list[PackageResult]:
    """Sucht RPM-Pakete im Fedora Repository via src.fedoraproject.org."""
    try:
        resp = await client.get(
            "https://src.fedoraproject.org/api/0/projects",
            params={"pattern": f"*{query}*", "fork": False, "short": True, "per_page": 10},
            timeout=_TIMEOUT,
        )
        resp.raise_for_status()
        data = resp.json()
        results = []
        for proj in data.get("projects", []):
            name = proj.get("name", "")
            desc = proj.get("description") or ""
            results.append(PackageResult(
                source      = PackageSource.DNF,
                name        = name,
                display     = name,
                description = desc[:120],
                url         = proj.get("full_url", f"https://packages.fedoraproject.org/pkgs/{name}/"),
            ))
        return results
    except Exception:
        return []


# ── COPR ─────────────────────────────────────────────────────────────────────

async def search_copr(query: str, client: httpx.AsyncClient) -> list[PackageResult]:
    """Sucht Projekte auf COPR."""
    try:
        resp = await client.get(
            "https://copr.fedorainfracloud.org/api_3/project/search",
            params={"query": query, "limit": 6},
            timeout=_TIMEOUT,
        )
        resp.raise_for_status()
        data = resp.json()
        results = []
        for proj in data.get("items", []):
            owner = proj.get("ownername", "")
            name  = proj.get("name", "")
            full  = f"{owner}/{name}"
            results.append(PackageResult(
                source      = PackageSource.COPR,
                name        = full,
                display     = f"{name} ({owner})",
                description = (proj.get("description") or "")[:120],
                url         = f"https://copr.fedorainfracloud.org/coprs/{full}/",
            ))
        return results
    except Exception:
        return []


# ── Kombinierte Suche ─────────────────────────────────────────────────────────

async def search_all(query: str) -> list[PackageResult]:
    """Durchsucht Flathub, DNF und COPR gleichzeitig."""
    async with httpx.AsyncClient(follow_redirects=True) as client:
        dnf_task     = search_fedora_dnf(query, client)
        flatpak_task = search_flathub(query, client)
        copr_task    = search_copr(query, client)
        dnf, flatpak, copr = await asyncio.gather(dnf_task, flatpak_task, copr_task)

    # Reihenfolge: DNF zuerst (meistgenutzt), dann Flatpak, dann COPR
    return dnf + flatpak + copr


def search_all_sync(query: str) -> list[PackageResult]:
    """Synchrone Wrapper-Funktion für search_all."""
    return asyncio.run(search_all(query))
